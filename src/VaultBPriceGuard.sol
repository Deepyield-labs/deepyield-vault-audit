// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

import {IPancakeV3Pool} from "./interfaces/IPancakeSwapV3.sol";
import {IChainlinkAggregatorV3, IVaultBPriceGuard} from "./interfaces/IVaultBExecutionV2.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @dev Circuit-breaker bounds of a Chainlink OCR feed. Standard BSC feeds are
/// EACAggregatorProxy -> AccessControlledOffchainAggregator, which exposes these;
/// read defensively so a proxy that does not is simply not bound-checked.
interface IChainlinkBounds {
    function aggregator() external view returns (address);
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}

/// @notice On-chain lower bound for Vault B's canonical USDT/WBNB swaps.
/// Keeper-supplied minima can only make execution stricter; they can never
/// relax this Chainlink + Pancake TWAP floor.
contract VaultBPriceGuard is AccessControlDefaultAdminRules, IVaultBPriceGuard {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EMERGENCY_CONSUMER_ROLE = keccak256("EMERGENCY_CONSUMER_ROLE");
    uint48 public constant DEFAULT_ADMIN_TRANSFER_DELAY = 2 days;

    uint256 internal constant BPS = 10_000;
    uint24 public constant override POOL_FEE = 100;

    /// @notice Economic ceilings on configuration, mirroring Main's HARD_MAX_*:
    /// 10% is already an extreme loss/deviation for a WBNB/USDT swap, so anything
    /// above it is a misconfiguration (e.g. a param from the wrong category).
    uint16 public constant HARD_MAX_LOSS_BPS = 1_000; // 10%
    uint16 public constant HARD_MAX_DEVIATION_BPS = 1_000; // 10%

    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant VAULT_B_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address public constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address public constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    IPancakeV3Pool public constant pool = IPancakeV3Pool(VAULT_B_POOL);
    IChainlinkAggregatorV3 public constant bnbUsdFeed = IChainlinkAggregatorV3(BNB_USD_FEED);
    IChainlinkAggregatorV3 public constant usdtUsdFeed = IChainlinkAggregatorV3(USDT_USD_FEED);

    uint16 public immutable normalLossBps;
    uint16 public immutable maxEmergencyLossBps;
    uint16 public immutable maxOracleDeviationBps;
    /// @notice Wider Chainlink-vs-TWAP deviation tolerated ONLY in emergency, so a
    /// real market gap (TWAP lagging while the oracle has moved) does not kill the
    /// emergency exit. It is also the hard ceiling: beyond it even an emergency
    /// refuses to quote, rather than swapping against a fully broken oracle.
    uint16 public immutable maxEmergencyOracleDeviationBps;
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
    error InvalidPool();
    error InvalidConfiguration();
    error UnsupportedPair(address tokenIn, address tokenOut);
    error InvalidAmount();
    error InvalidOracleAnswer(address feed);
    error StaleOracle(address feed, uint256 age);
    error FutureOracleTimestamp(address feed, uint256 timestamp);
    error UnsupportedOracleDecimals(address feed, uint8 decimals);
    error OracleDeviation(uint256 chainlinkOut, uint256 twapOut, uint256 deviationBps);
    error OracleAtBound(address feed, int256 answer, int192 minAnswer, int192 maxAnswer);
    error TwapUnavailable();
    error EmergencyBudgetInactive();
    error InvalidEmergencyBudget();
    error EmergencyNotionalMismatch(uint256 requested, uint256 remaining);

    event EmergencyBudgetActivated(uint16 lossBps, uint64 expiresAt, uint256 notionalLimit);
    event EmergencyNotionalConsumed(address indexed consumer, uint256 notional, uint256 totalConsumed);
    event EmergencyBudgetCleared();

    struct Quote {
        uint256 chainlinkOut;
        uint256 twapOut;
        uint256 fairOut;
        uint256 minOut;
        uint256 deviationBps;
        uint256 emergencyNotional;
        uint16 lossBps;
        bool emergencyBudgetUsed;
    }

    constructor(
        uint16 normalLossBps_,
        uint16 maxEmergencyLossBps_,
        uint16 maxOracleDeviationBps_,
        uint16 maxEmergencyOracleDeviationBps_,
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
                || maxEmergencyOracleDeviationBps_ > HARD_MAX_DEVIATION_BPS || twapWindow_ < 60 || maxBnbFeedAge_ == 0
                || maxUsdtFeedAge_ == 0 || maxEmergencyDuration_ == 0
        ) revert InvalidConfiguration();

        address token0 = pool.token0();
        address token1 = pool.token1();
        if (token0 != USDT || token1 != WBNB || pool.fee() != POOL_FEE) revert InvalidPool();

        normalLossBps = normalLossBps_;
        maxEmergencyLossBps = maxEmergencyLossBps_;
        maxOracleDeviationBps = maxOracleDeviationBps_;
        maxEmergencyOracleDeviationBps = maxEmergencyOracleDeviationBps_;
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
        ) revert InvalidEmergencyBudget();
        emergencyLossBps = lossBps;
        emergencyExpiresAt = expiresAt;
        emergencyNotionalLimit = notionalLimit;
        emergencyNotionalConsumed = 0;
        emit EmergencyBudgetActivated(lossBps, expiresAt, notionalLimit);
    }

    function clearEmergencyBudget() external onlyRole(GUARDIAN_ROLE) {
        emergencyLossBps = 0;
        emergencyExpiresAt = 0;
        emergencyNotionalLimit = 0;
        emergencyNotionalConsumed = 0;
        emit EmergencyBudgetCleared();
    }

    function minimumOut(address tokenIn, address tokenOut, uint256 amountIn, bool emergency)
        external
        view
        returns (uint256 minOut)
    {
        return quote(tokenIn, tokenOut, amountIn, emergency).minOut;
    }

    function minimumOutAndBudget(address tokenIn, address tokenOut, uint256 amountIn, bool emergency)
        external
        view
        returns (uint256 minOut, uint256 emergencyNotional, bool emergencyBudgetUsed)
    {
        Quote memory q = quote(tokenIn, tokenOut, amountIn, emergency);
        return (q.minOut, q.emergencyNotional, q.emergencyBudgetUsed);
    }

    /// @notice Called by the pinned execution adapter only after all router and
    /// balance-delta checks pass. A later revert rolls the swap and this debit
    /// back atomically, so failed attempts never consume the window.
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

    function fairValue(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut) {
        return quote(tokenIn, tokenOut, amountIn, false).fairOut;
    }

    function twapSqrtPriceX96() external view returns (uint160) {
        return TickMath.getSqrtRatioAtTick(_twapTick());
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn, bool emergency)
        public
        view
        returns (Quote memory q)
    {
        _validatePair(tokenIn, tokenOut);
        if (amountIn == 0) revert InvalidAmount();

        q.chainlinkOut = _chainlinkQuote(tokenIn, amountIn);
        q.twapOut = _twapQuote(tokenIn, tokenOut, amountIn);
        if (q.chainlinkOut == 0 || q.twapOut == 0) revert InvalidAmount();

        uint256 lower = q.chainlinkOut < q.twapOut ? q.chainlinkOut : q.twapOut;
        uint256 upper = q.chainlinkOut > q.twapOut ? q.chainlinkOut : q.twapOut;
        q.deviationBps = FullMath.mulDivRoundingUp(upper - lower, BPS, lower);
        q.emergencyNotional = tokenIn == USDT ? amountIn : upper;
        (q.lossBps, q.emergencyBudgetUsed) = _lossBudget(emergency, q.emergencyNotional);
        // The deviation ceiling is mode-dependent: emergencies tolerate a wider
        // Chainlink-vs-TWAP gap (a real market move the TWAP has not caught up to)
        // so the emergency exit is not killed by the very condition it exists for.
        // The normal ceiling is NOT relaxed. The wider band still binds, so a fully
        // broken oracle is refused even in emergency. `_lossBudget` below still
        // requires an active guardian budget, so the wider band is unreachable
        // without one.
        uint256 deviationLimit = q.emergencyBudgetUsed ? maxEmergencyOracleDeviationBps : maxOracleDeviationBps;
        if (q.deviationBps > deviationLimit) {
            revert OracleDeviation(q.chainlinkOut, q.twapOut, q.deviationBps);
        }

        q.fairOut = lower;
        q.minOut = FullMath.mulDivRoundingUp(lower, BPS - q.lossBps, BPS);
        if (q.minOut == 0) revert InvalidAmount();
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

    function _validatePair(address tokenIn, address tokenOut) internal pure {
        bool assetToPaired = tokenIn == USDT && tokenOut == WBNB;
        bool pairedToAsset = tokenIn == WBNB && tokenOut == USDT;
        if (!assetToPaired && !pairedToAsset) revert UnsupportedPair(tokenIn, tokenOut);
    }

    function _chainlinkQuote(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        uint256 bnbUsd = _readFeed(bnbUsdFeed, maxBnbFeedAge);
        uint256 usdtUsd = _readFeed(usdtUsdFeed, maxUsdtFeedAge);
        if (tokenIn == USDT) return FullMath.mulDiv(amountIn, usdtUsd, bnbUsd);
        return FullMath.mulDiv(amountIn, bnbUsd, usdtUsd);
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
        return unsigned / (10 ** (decimals - 18));
    }

    /// @notice Reject an answer pinned to the aggregator's min/maxAnswer circuit
    /// breaker — a crashed feed clamps to the bound and otherwise looks fresh,
    /// positive and complete. Bounds are read defensively: a proxy that does not
    /// expose them is simply not bound-checked (see report — a configurable
    /// corridor is the backstop if any of our feeds ever lacked them; the BSC
    /// OCR feeds we use do expose them).
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

    function _twapQuote(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        return _quoteAtTick(_twapTick(), amountIn, tokenIn, tokenOut);
    }

    function _twapTick() internal view returns (int24 meanTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            if (tickCumulatives.length != 2) revert TwapUnavailable();
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 window = int56(uint56(twapWindow));
            // A V3 cumulative-tick average remains inside the protocol's int24 tick domain.
            // forge-lint: disable-next-line(unsafe-typecast)
            meanTick = int24(delta / window);
            if (delta < 0 && delta % window != 0) meanTick--;
        } catch {
            revert TwapUnavailable();
        }
    }

    function _quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        }

        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return baseToken < quoteToken
            ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
            : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
    }
}
