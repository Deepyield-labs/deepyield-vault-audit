// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IPancakeV3Pool} from "./interfaces/IPancakeSwapV3.sol";
import {IChainlinkAggregatorV3, IVaultBRewardPriceGuard} from "./interfaces/IVaultBExecutionV2.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @notice On-chain lower bound for Vault B CAKE-to-USDT liquidation.
/// It cross-checks a direct CAKE/USDT TWAP against an independent
/// CAKE/WBNB TWAP converted through Chainlink BNB/USD and USDT/USD.
contract VaultBCakePriceGuard is AccessControl, IVaultBRewardPriceGuard {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 internal constant BPS = 10_000;

    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant CAKE_USDT_ORACLE_POOL = 0x7f51c8AaA6B0599aBd16674e2b17FEc7a9f674A1;
    address public constant CAKE_WBNB_ORACLE_POOL = 0xAfB2Da14056725E3BA3a30dD846B6BBbd7886c56;
    address public constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address public constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    uint24 public constant DIRECT_ORACLE_FEE = 2_500;
    uint24 public constant CROSS_ORACLE_FEE = 500;

    IPancakeV3Pool public constant directPool = IPancakeV3Pool(CAKE_USDT_ORACLE_POOL);
    IPancakeV3Pool public constant crossPool = IPancakeV3Pool(CAKE_WBNB_ORACLE_POOL);
    IChainlinkAggregatorV3 public constant bnbUsdFeed = IChainlinkAggregatorV3(BNB_USD_FEED);
    IChainlinkAggregatorV3 public constant usdtUsdFeed = IChainlinkAggregatorV3(USDT_USD_FEED);

    uint16 public immutable normalLossBps;
    uint16 public immutable maxEmergencyLossBps;
    uint16 public immutable maxOracleDeviationBps;
    uint256 public immutable maxNormalNotional;
    uint256 public immutable maxEmergencyNotional;
    uint32 public immutable twapWindow;
    uint32 public immutable maxBnbFeedAge;
    uint32 public immutable maxUsdtFeedAge;
    uint32 public immutable maxEmergencyDuration;

    uint16 public emergencyLossBps;
    uint64 public emergencyExpiresAt;

    error WrongChain(uint256 actual);
    error ZeroAddress();
    error InvalidPool(address pool);
    error InvalidConfiguration();
    error InvalidAmount();
    error InvalidOracleAnswer(address feed);
    error StaleOracle(address feed, uint256 age);
    error FutureOracleTimestamp(address feed, uint256 timestamp);
    error IncompleteOracleRound(address feed, uint80 roundId, uint80 answeredInRound);
    error UnsupportedOracleDecimals(address feed, uint8 decimals);
    error OracleDeviation(uint256 directOut, uint256 compositeOut, uint256 deviationBps);
    error CapacityExceeded(uint256 notional, uint256 cap);
    error TwapUnavailable(address pool);
    error EmergencyBudgetInactive();
    error InvalidEmergencyBudget();

    event EmergencyBudgetActivated(uint16 lossBps, uint64 expiresAt);
    event EmergencyBudgetCleared();

    struct Quote {
        uint256 directTwapOut;
        uint256 compositeTwapOut;
        uint256 fairOut;
        uint256 minOut;
        uint256 deviationBps;
        uint16 lossBps;
    }

    constructor(
        uint16 normalLossBps_,
        uint16 maxEmergencyLossBps_,
        uint16 maxOracleDeviationBps_,
        uint256 maxNormalNotional_,
        uint256 maxEmergencyNotional_,
        uint32 twapWindow_,
        uint32 maxBnbFeedAge_,
        uint32 maxUsdtFeedAge_,
        uint32 maxEmergencyDuration_,
        address admin_,
        address guardian_
    ) {
        if (block.chainid != 56) revert WrongChain(block.chainid);
        if (admin_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        if (
            normalLossBps_ == 0 || normalLossBps_ >= BPS || maxEmergencyLossBps_ < normalLossBps_
                || maxEmergencyLossBps_ >= BPS || maxOracleDeviationBps_ == 0 || maxOracleDeviationBps_ >= BPS
                || maxNormalNotional_ == 0 || maxEmergencyNotional_ < maxNormalNotional_ || twapWindow_ < 60
                || maxBnbFeedAge_ == 0 || maxUsdtFeedAge_ == 0 || maxEmergencyDuration_ == 0
        ) revert InvalidConfiguration();

        _validatePool(directPool, USDT, DIRECT_ORACLE_FEE);
        _validatePool(crossPool, WBNB, CROSS_ORACLE_FEE);

        normalLossBps = normalLossBps_;
        maxEmergencyLossBps = maxEmergencyLossBps_;
        maxOracleDeviationBps = maxOracleDeviationBps_;
        maxNormalNotional = maxNormalNotional_;
        maxEmergencyNotional = maxEmergencyNotional_;
        twapWindow = twapWindow_;
        maxBnbFeedAge = maxBnbFeedAge_;
        maxUsdtFeedAge = maxUsdtFeedAge_;
        maxEmergencyDuration = maxEmergencyDuration_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(GUARDIAN_ROLE, guardian_);
    }

    function activateEmergencyBudget(uint16 lossBps, uint64 expiresAt) external onlyRole(GUARDIAN_ROLE) {
        if (
            lossBps < normalLossBps || lossBps > maxEmergencyLossBps || expiresAt <= block.timestamp
                || expiresAt > block.timestamp + maxEmergencyDuration
        ) revert InvalidEmergencyBudget();
        emergencyLossBps = lossBps;
        emergencyExpiresAt = expiresAt;
        emit EmergencyBudgetActivated(lossBps, expiresAt);
    }

    function clearEmergencyBudget() external onlyRole(GUARDIAN_ROLE) {
        emergencyLossBps = 0;
        emergencyExpiresAt = 0;
        emit EmergencyBudgetCleared();
    }

    function minimumOut(uint256 amountIn, bool emergency) external view returns (uint256) {
        return quote(amountIn, emergency).minOut;
    }

    function fairValue(uint256 amountIn) external view returns (uint256) {
        return _sourceQuote(amountIn).fairOut;
    }

    function quote(uint256 amountIn, bool emergency) public view returns (Quote memory q) {
        q = _sourceQuote(amountIn);
        uint256 cap = emergency ? maxEmergencyNotional : maxNormalNotional;
        if (q.fairOut > cap) revert CapacityExceeded(q.fairOut, cap);

        q.lossBps = _lossBudget(emergency);
        q.minOut = FullMath.mulDiv(q.fairOut, BPS - q.lossBps, BPS);
        if (q.minOut == 0) revert InvalidAmount();
    }

    function _sourceQuote(uint256 amountIn) internal view returns (Quote memory q) {
        if (amountIn == 0) revert InvalidAmount();

        q.directTwapOut = _twapQuote(directPool, amountIn, CAKE, USDT);
        uint256 wbnbOut = _twapQuote(crossPool, amountIn, CAKE, WBNB);
        uint256 bnbUsd = _readFeed(bnbUsdFeed, maxBnbFeedAge);
        uint256 usdtUsd = _readFeed(usdtUsdFeed, maxUsdtFeedAge);
        q.compositeTwapOut = FullMath.mulDiv(wbnbOut, bnbUsd, usdtUsd);
        if (q.directTwapOut == 0 || q.compositeTwapOut == 0) revert InvalidAmount();

        uint256 lower = q.directTwapOut < q.compositeTwapOut ? q.directTwapOut : q.compositeTwapOut;
        uint256 upper = q.directTwapOut > q.compositeTwapOut ? q.directTwapOut : q.compositeTwapOut;
        q.deviationBps = FullMath.mulDiv(upper - lower, BPS, lower);
        if (q.deviationBps > maxOracleDeviationBps) {
            revert OracleDeviation(q.directTwapOut, q.compositeTwapOut, q.deviationBps);
        }

        q.fairOut = lower;
    }

    function _validatePool(IPancakeV3Pool candidate, address quoteToken, uint24 expectedFee) internal view {
        if (candidate.token0() != CAKE || candidate.token1() != quoteToken || candidate.fee() != expectedFee) {
            revert InvalidPool(address(candidate));
        }
    }

    function _lossBudget(bool emergency) internal view returns (uint16) {
        if (!emergency) return normalLossBps;
        if (emergencyLossBps == 0 || emergencyExpiresAt <= block.timestamp || emergencyLossBps > maxEmergencyLossBps) {
            revert EmergencyBudgetInactive();
        }
        return emergencyLossBps;
    }

    function _readFeed(IChainlinkAggregatorV3 feed, uint32 maxAge) internal view returns (uint256 answerWad) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0) revert InvalidOracleAnswer(address(feed));
        if (updatedAt > block.timestamp) revert FutureOracleTimestamp(address(feed), updatedAt);
        if (answeredInRound < roundId) revert IncompleteOracleRound(address(feed), roundId, answeredInRound);
        uint256 age = block.timestamp - updatedAt;
        if (age > maxAge) revert StaleOracle(address(feed), age);

        uint8 decimals = feed.decimals();
        if (decimals > 36) revert UnsupportedOracleDecimals(address(feed), decimals);
        // `answer > 0` above proves this signed-to-unsigned cast preserves the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 unsigned = uint256(answer);
        if (decimals == 18) return unsigned;
        if (decimals < 18) return unsigned * (10 ** (18 - decimals));
        return unsigned / (10 ** (decimals - 18));
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
