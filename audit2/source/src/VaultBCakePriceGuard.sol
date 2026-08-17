// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

import {IPancakeV3Pool} from "./interfaces/IPancakeSwapV3.sol";
import {IChainlinkAggregatorV3, IVaultBRewardPriceGuard} from "./interfaces/IVaultBExecutionV2.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @dev Circuit-breaker bounds of a Chainlink OCR feed (see VaultBPriceGuard).
interface IChainlinkBounds {
    function aggregator() external view returns (address);
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}

/// @notice On-chain lower bound for Vault B CAKE-to-USDT liquidation.
/// It cross-checks a direct CAKE/USDT TWAP, a CAKE/WBNB TWAP converted through
/// Chainlink BNB/USD and USDT/USD, and the independent Chainlink CAKE/USD
/// reference. A disagreement fails closed rather than accepting a floor from
/// two correlated PancakeSwap pools.
contract VaultBCakePriceGuard is AccessControlDefaultAdminRules, IVaultBRewardPriceGuard {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EMERGENCY_CONSUMER_ROLE = keccak256("EMERGENCY_CONSUMER_ROLE");
    uint48 public constant DEFAULT_ADMIN_TRANSFER_DELAY = 2 days;

    uint256 internal constant BPS = 10_000;
    uint16 public constant HARD_MAX_LOSS_BPS = 1_000; // 10%
    uint16 public constant HARD_MAX_DEVIATION_BPS = 1_000; // 10%

    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant CAKE_USDT_ORACLE_POOL = 0x7f51c8AaA6B0599aBd16674e2b17FEc7a9f674A1;
    address public constant CAKE_WBNB_ORACLE_POOL = 0xAfB2Da14056725E3BA3a30dD846B6BBbd7886c56;
    address public constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address public constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    address public constant CAKE_USD_FEED = 0xB6064eD41d4f67e353768aA239cA86f4F73665a1;
    /// @dev The official BNB-chain catalog currently specifies a 60-second
    /// heartbeat for CAKE/USD. Five heartbeats allow normal propagation but
    /// fail closed on an unavailable or migrated feed.
    uint32 public constant MAX_CAKE_USD_FEED_AGE = 300;

    uint24 public constant override DIRECT_ORACLE_FEE = 2_500;
    uint24 public constant CROSS_ORACLE_FEE = 500;

    IPancakeV3Pool public constant directPool = IPancakeV3Pool(CAKE_USDT_ORACLE_POOL);
    IPancakeV3Pool public constant crossPool = IPancakeV3Pool(CAKE_WBNB_ORACLE_POOL);
    IChainlinkAggregatorV3 public constant bnbUsdFeed = IChainlinkAggregatorV3(BNB_USD_FEED);
    IChainlinkAggregatorV3 public constant usdtUsdFeed = IChainlinkAggregatorV3(USDT_USD_FEED);
    IChainlinkAggregatorV3 public constant cakeUsdFeed = IChainlinkAggregatorV3(CAKE_USD_FEED);

    uint16 public immutable normalLossBps;
    uint16 public immutable maxEmergencyLossBps;
    uint16 public immutable maxOracleDeviationBps;
    uint16 public immutable maxEmergencyOracleDeviationBps;
    uint256 public immutable maxNormalNotional;
    uint256 public immutable maxEmergencyNotional;
    uint32 public immutable twapWindow;
    uint32 public immutable maxBnbFeedAge;
    uint32 public immutable maxUsdtFeedAge;
    uint32 public immutable maxEmergencyDuration;

    uint16 public emergencyLossBps;
    uint64 public emergencyExpiresAt;
    uint256 public emergencyNotionalLimit;
    uint256 public emergencyNotionalConsumed;

    error WrongChain(uint256 actual);
    error ZeroAddress();
    error InvalidPool(address pool);
    error InvalidConfiguration();
    error InvalidAmount();
    error InvalidOracleAnswer(address feed);
    error StaleOracle(address feed, uint256 age);
    error FutureOracleTimestamp(address feed, uint256 timestamp);
    error UnsupportedOracleDecimals(address feed, uint8 decimals);
    error OracleDeviation(uint256 directOut, uint256 compositeOut, uint256 deviationBps);
    error ExternalReferenceDeviation(uint256 poolReferenceOut, uint256 cakeFeedOut, uint256 deviationBps);
    error OracleAtBound(address feed, int256 answer, int192 minAnswer, int192 maxAnswer);
    error CapacityExceeded(uint256 notional, uint256 cap);
    error TwapUnavailable(address pool);
    error EmergencyBudgetInactive();
    error InvalidEmergencyBudget();
    error EmergencyNotionalMismatch(uint256 requested, uint256 remaining);

    event EmergencyBudgetActivated(uint16 lossBps, uint64 expiresAt, uint256 notionalLimit);
    event EmergencyNotionalConsumed(address indexed consumer, uint256 notional, uint256 totalConsumed);
    event EmergencyBudgetCleared();

    struct Quote {
        uint256 directTwapOut;
        uint256 compositeTwapOut;
        uint256 fairOut;
        uint256 floorReferenceOut;
        uint256 minOut;
        uint256 deviationBps;
        uint256 emergencyNotional;
        uint16 lossBps;
        bool emergencyBudgetUsed;
    }

    /// @dev Internal source data that keeps the existing public `Quote` ABI
    /// stable while allowing a capacity-free preflight to validate every
    /// source before Main chooses a bounded slice.
    struct RawQuote {
        Quote quote;
        uint256 poolUpper;
        uint256 cakeFeedOutLower;
        uint256 poolDeviationBps;
    }

    constructor(
        uint16 normalLossBps_,
        uint16 maxEmergencyLossBps_,
        uint16 maxOracleDeviationBps_,
        uint16 maxEmergencyOracleDeviationBps_,
        uint256 maxNormalNotional_,
        uint256 maxEmergencyNotional_,
        uint32 twapWindow_,
        uint32 maxBnbFeedAge_,
        uint32 maxUsdtFeedAge_,
        uint32 maxEmergencyDuration_,
        address admin_,
        address guardian_
    ) AccessControlDefaultAdminRules(DEFAULT_ADMIN_TRANSFER_DELAY, admin_) {
        if (block.chainid != 56) revert WrongChain(block.chainid);
        if (admin_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        if (
            normalLossBps_ == 0 || normalLossBps_ > HARD_MAX_LOSS_BPS || maxEmergencyLossBps_ < normalLossBps_
                || maxEmergencyLossBps_ > HARD_MAX_LOSS_BPS || maxOracleDeviationBps_ == 0
                || maxOracleDeviationBps_ > HARD_MAX_DEVIATION_BPS
                || maxEmergencyOracleDeviationBps_ < maxOracleDeviationBps_
                || maxEmergencyOracleDeviationBps_ > HARD_MAX_DEVIATION_BPS || maxNormalNotional_ == 0
                || maxEmergencyNotional_ < maxNormalNotional_ || twapWindow_ < 60 || maxBnbFeedAge_ == 0
                || maxUsdtFeedAge_ == 0 || maxEmergencyDuration_ == 0
        ) revert InvalidConfiguration();

        _validatePool(directPool, USDT, DIRECT_ORACLE_FEE);
        _validatePool(crossPool, WBNB, CROSS_ORACLE_FEE);

        normalLossBps = normalLossBps_;
        maxEmergencyLossBps = maxEmergencyLossBps_;
        maxOracleDeviationBps = maxOracleDeviationBps_;
        maxEmergencyOracleDeviationBps = maxEmergencyOracleDeviationBps_;
        maxNormalNotional = maxNormalNotional_;
        maxEmergencyNotional = maxEmergencyNotional_;
        twapWindow = twapWindow_;
        maxBnbFeedAge = maxBnbFeedAge_;
        maxUsdtFeedAge = maxUsdtFeedAge_;
        maxEmergencyDuration = maxEmergencyDuration_;

        _grantRole(GUARDIAN_ROLE, guardian_);
    }

    function activateEmergencyBudget(uint16 lossBps, uint64 expiresAt, uint256 notionalLimit)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        if (
            lossBps < normalLossBps || lossBps > maxEmergencyLossBps || expiresAt <= block.timestamp
                || expiresAt > block.timestamp + maxEmergencyDuration || notionalLimit == 0
                || notionalLimit > maxEmergencyNotional
        ) revert InvalidEmergencyBudget();
        bool active =
            emergencyLossBps != 0 && emergencyLossBps <= maxEmergencyLossBps && emergencyExpiresAt > block.timestamp;
        uint256 consumed = active ? emergencyNotionalConsumed : 0;
        if (notionalLimit < consumed) revert InvalidEmergencyBudget();
        emergencyLossBps = lossBps;
        emergencyExpiresAt = expiresAt;
        emergencyNotionalLimit = notionalLimit;
        emergencyNotionalConsumed = consumed;
        emit EmergencyBudgetActivated(lossBps, expiresAt, notionalLimit);
    }

    /// @notice Explicitly terminates the current incident and resets its budget.
    /// A guardian that intends to retain consumed notional must reactivate while
    /// the window is still active instead of clearing it first.
    function clearEmergencyBudget() external onlyRole(GUARDIAN_ROLE) {
        emergencyLossBps = 0;
        emergencyExpiresAt = 0;
        emergencyNotionalLimit = 0;
        emergencyNotionalConsumed = 0;
        emit EmergencyBudgetCleared();
    }

    function minimumOut(uint256 amountIn, bool emergency) external view returns (uint256) {
        return quote(amountIn, emergency).minOut;
    }

    function minimumOutAndBudget(uint256 amountIn, bool emergency)
        external
        view
        returns (uint256 minOut, uint256 emergencyNotional, bool emergencyBudgetUsed)
    {
        Quote memory q = quote(amountIn, emergency);
        return (q.minOut, q.emergencyNotional, q.emergencyBudgetUsed);
    }

    function consumeEmergencyNotional(uint256 notional) external onlyRole(EMERGENCY_CONSUMER_ROLE) {
        uint256 consumed = emergencyNotionalConsumed;
        uint256 limit = emergencyNotionalLimit;
        if (
            notional == 0 || emergencyLossBps == 0 || emergencyExpiresAt <= block.timestamp || consumed >= limit
                || notional > limit - consumed
        ) revert EmergencyNotionalMismatch(notional, consumed < limit ? limit - consumed : 0);
        consumed += notional;
        emergencyNotionalConsumed = consumed;
        emit EmergencyNotionalConsumed(msg.sender, notional, consumed);
    }

    function fairValue(uint256 amountIn) external view returns (uint256) {
        return _sourceQuote(amountIn, false).fairOut;
    }

    /// @notice Capacity-free source snapshot for Main's reward-liquidation
    /// slicing. It deliberately does not apply a loss haircut, reserve a
    /// budget, or require the unsliced balance to fit a per-call cap.
    function liquidationSnapshot(uint256 amountIn, bool requestedEmergency)
        external
        view
        returns (uint256 fairNotional, uint256 capNotional, uint256 normalCapacity, uint256 emergencyCapacity)
    {
        RawQuote memory raw = _rawSourceQuote(amountIn);
        if (!requestedEmergency) {
            _validateSourceDeviation(raw, false);
            return (raw.quote.fairOut, raw.quote.floorReferenceOut, maxNormalNotional, 0);
        }

        // Keep the same active-window/configuration requirement as a true
        // emergency quote, but do not let an insufficient *unsliced* amount
        // select normal policy before Main has a chance to make a bounded
        // emergency slice.
        _lossBudget(true, 1);
        _validateSourceDeviation(raw, true);

        uint256 consumed = emergencyNotionalConsumed;
        uint256 remaining = consumed >= emergencyNotionalLimit ? 0 : emergencyNotionalLimit - consumed;
        emergencyCapacity = remaining < maxEmergencyNotional ? remaining : maxEmergencyNotional;
        normalCapacity = _sourceDeviationWithin(raw, false) ? maxNormalNotional : 0;
        return (raw.quote.fairOut, raw.quote.floorReferenceOut, normalCapacity, emergencyCapacity);
    }

    function quote(uint256 amountIn, bool emergency) public view returns (Quote memory q) {
        q = _sourceQuote(amountIn, emergency);
        (q.lossBps, q.emergencyBudgetUsed) = _lossBudget(emergency, q.emergencyNotional);
        uint256 cap = q.emergencyBudgetUsed ? maxEmergencyNotional : maxNormalNotional;
        if (q.floorReferenceOut > cap) revert CapacityExceeded(q.floorReferenceOut, cap);

        q.minOut = FullMath.mulDivRoundingUp(q.floorReferenceOut, BPS - q.lossBps, BPS);
        if (q.minOut == 0) revert InvalidAmount();
    }

    function _sourceQuote(uint256 amountIn, bool emergency) internal view returns (Quote memory q) {
        RawQuote memory raw = _rawSourceQuote(amountIn);
        q = raw.quote;
        (, q.emergencyBudgetUsed) = _lossBudget(emergency, q.emergencyNotional);
        _validateSourceDeviation(raw, q.emergencyBudgetUsed);
    }

    function _rawSourceQuote(uint256 amountIn) internal view returns (RawQuote memory raw) {
        if (amountIn == 0) revert InvalidAmount();

        Quote memory q = raw.quote;
        q.directTwapOut = _twapQuote(directPool, amountIn, CAKE, USDT);
        uint256 wbnbOut = _twapQuote(crossPool, amountIn, CAKE, WBNB);
        uint256 bnbUsd = _readFeed(bnbUsdFeed, maxBnbFeedAge);
        uint256 usdtUsd = _readFeed(usdtUsdFeed, maxUsdtFeedAge);
        q.compositeTwapOut = FullMath.mulDiv(wbnbOut, bnbUsd, usdtUsd);
        uint256 cakeUsd = _readFeed(cakeUsdFeed, MAX_CAKE_USD_FEED_AGE);
        raw.cakeFeedOutLower = FullMath.mulDiv(amountIn, cakeUsd, usdtUsd);
        uint256 cakeFeedOutUpper = FullMath.mulDivRoundingUp(amountIn, cakeUsd, usdtUsd);
        if (q.directTwapOut == 0 || q.compositeTwapOut == 0 || raw.cakeFeedOutLower == 0) revert InvalidAmount();

        uint256 poolLower = q.directTwapOut < q.compositeTwapOut ? q.directTwapOut : q.compositeTwapOut;
        raw.poolUpper = q.directTwapOut > q.compositeTwapOut ? q.directTwapOut : q.compositeTwapOut;
        raw.poolDeviationBps = FullMath.mulDivRoundingUp(raw.poolUpper - poolLower, BPS, poolLower);
        // The lower value remains conservative for accounting, while floor,
        // capacity and emergency-notional accounting round against the caller.
        uint256 lower = poolLower < raw.cakeFeedOutLower ? poolLower : raw.cakeFeedOutLower;
        uint256 upper = raw.poolUpper > cakeFeedOutUpper ? raw.poolUpper : cakeFeedOutUpper;
        q.emergencyNotional = upper;
        q.deviationBps = FullMath.mulDivRoundingUp(upper - lower, BPS, lower);
        q.fairOut = lower;
        q.floorReferenceOut = upper;
        raw.quote = q;
    }

    function _validateSourceDeviation(RawQuote memory raw, bool emergencyBandAvailable) internal view {
        uint256 deviationLimit = emergencyBandAvailable ? maxEmergencyOracleDeviationBps : maxOracleDeviationBps;
        // Mode-dependent ceiling: emergencies tolerate a wider gap so the reward
        // emergency exit is not killed by a real market move; normal is unchanged;
        // an active guardian budget is still required by `_lossBudget`.
        if (raw.poolDeviationBps > deviationLimit) {
            revert OracleDeviation(raw.quote.directTwapOut, raw.quote.compositeTwapOut, raw.poolDeviationBps);
        }
        if (raw.quote.deviationBps > deviationLimit) {
            revert ExternalReferenceDeviation(raw.poolUpper, raw.cakeFeedOutLower, raw.quote.deviationBps);
        }
    }

    function _sourceDeviationWithin(RawQuote memory raw, bool emergencyBandAvailable) internal view returns (bool) {
        uint256 deviationLimit = emergencyBandAvailable ? maxEmergencyOracleDeviationBps : maxOracleDeviationBps;
        return raw.poolDeviationBps <= deviationLimit && raw.quote.deviationBps <= deviationLimit;
    }

    function _validatePool(IPancakeV3Pool candidate, address quoteToken, uint24 expectedFee) internal view {
        if (candidate.token0() != CAKE || candidate.token1() != quoteToken || candidate.fee() != expectedFee) {
            revert InvalidPool(address(candidate));
        }
    }

    function _lossBudget(bool emergency, uint256 notional) internal view returns (uint16 lossBps, bool used) {
        if (!emergency) return (normalLossBps, false);
        if (emergencyLossBps == 0 || emergencyExpiresAt <= block.timestamp || emergencyLossBps > maxEmergencyLossBps) {
            revert EmergencyBudgetInactive();
        }
        uint256 consumed = emergencyNotionalConsumed;
        uint256 limit = emergencyNotionalLimit;
        if (consumed >= limit || notional > limit - consumed) return (normalLossBps, false);
        return (emergencyLossBps, true);
    }

    function _readFeed(IChainlinkAggregatorV3 feed, uint32 maxAge) internal view returns (uint256 answerWad) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0) revert InvalidOracleAnswer(address(feed));
        if (updatedAt > block.timestamp) revert FutureOracleTimestamp(address(feed), updatedAt);
        uint256 age = block.timestamp - updatedAt;
        if (age > maxAge) revert StaleOracle(address(feed), age);

        _checkAggregatorBounds(feed, answer);

        uint8 decimals = feed.decimals();
        if (decimals > 36) revert UnsupportedOracleDecimals(address(feed), decimals);
        // `answer > 0` above proves this signed-to-unsigned cast preserves the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 unsigned = uint256(answer);
        if (decimals == 18) return unsigned;
        if (decimals < 18) return unsigned * (10 ** (18 - decimals));
        answerWad = unsigned / (10 ** (decimals - 18));
        if (answerWad == 0) revert InvalidOracleAnswer(address(feed));
    }

    /// @notice Reject a Chainlink answer pinned to its aggregator's min/maxAnswer
    /// circuit breaker; read defensively (see VaultBPriceGuard).
    function _checkAggregatorBounds(IChainlinkAggregatorV3 feed, int256 answer) internal view {
        try IChainlinkBounds(address(feed)).aggregator() returns (address agg) {
            try IChainlinkBounds(agg).minAnswer() returns (int192 mn) {
                try IChainlinkBounds(agg).maxAnswer() returns (int192 mx) {
                    if (mx > mn && (answer <= int256(mn) || answer >= int256(mx))) {
                        revert OracleAtBound(address(feed), answer, mn, mx);
                    }
                } catch {}
            } catch {}
        } catch {}
    }

    function _twapQuote(IPancakeV3Pool sourcePool, uint256 amountIn, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256)
    {
        int24 tick = _twapTick(sourcePool);
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return tokenIn < tokenOut
                ? FullMath.mulDiv(ratioX192, amountIn, 1 << 192)
                : FullMath.mulDiv(1 << 192, amountIn, ratioX192);
        }

        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return tokenIn < tokenOut
            ? FullMath.mulDiv(ratioX128, amountIn, 1 << 128)
            : FullMath.mulDiv(1 << 128, amountIn, ratioX128);
    }

    function _twapTick(IPancakeV3Pool sourcePool) internal view returns (int24 meanTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        try sourcePool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            if (tickCumulatives.length != 2) revert TwapUnavailable(address(sourcePool));
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 window = int56(uint56(twapWindow));
            // A V3 cumulative-tick average remains inside the protocol's int24 tick domain.
            // forge-lint: disable-next-line(unsafe-typecast)
            meanTick = int24(delta / window);
            if (delta < 0 && delta % window != 0) meanTick--;
        } catch {
            revert TwapUnavailable(address(sourcePool));
        }
    }
}
