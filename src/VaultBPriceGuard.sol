// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IPancakeV3Pool} from "./interfaces/IPancakeSwapV3.sol";
import {IChainlinkAggregatorV3, IVaultBPriceGuard} from "./interfaces/IVaultBExecutionV2.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @notice On-chain lower bound for Vault B's canonical USDT/WBNB swaps.
/// Keeper-supplied minima can only make execution stricter; they can never
/// relax this Chainlink + Pancake TWAP floor.
contract VaultBPriceGuard is AccessControl, IVaultBPriceGuard {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 internal constant BPS = 10_000;
    uint24 public constant POOL_FEE = 100;

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
    uint32 public immutable twapWindow;
    uint32 public immutable maxBnbFeedAge;
    uint32 public immutable maxUsdtFeedAge;
    uint32 public immutable maxEmergencyDuration;

    uint16 public emergencyLossBps;
    uint64 public emergencyExpiresAt;

    error WrongChain(uint256 actual);
    error ZeroAddress();
    error InvalidPool();
    error InvalidConfiguration();
    error UnsupportedPair(address tokenIn, address tokenOut);
    error InvalidAmount();
    error InvalidOracleAnswer(address feed);
    error StaleOracle(address feed, uint256 age);
    error FutureOracleTimestamp(address feed, uint256 timestamp);
    error IncompleteOracleRound(address feed, uint80 roundId, uint80 answeredInRound);
    error UnsupportedOracleDecimals(address feed, uint8 decimals);
    error OracleDeviation(uint256 chainlinkOut, uint256 twapOut, uint256 deviationBps);
    error TwapUnavailable();
    error EmergencyBudgetInactive();
    error InvalidEmergencyBudget();

    event EmergencyBudgetActivated(uint16 lossBps, uint64 expiresAt);
    event EmergencyBudgetCleared();

    struct Quote {
        uint256 chainlinkOut;
        uint256 twapOut;
        uint256 fairOut;
        uint256 minOut;
        uint256 deviationBps;
        uint16 lossBps;
    }

    constructor(
        uint16 normalLossBps_,
        uint16 maxEmergencyLossBps_,
        uint16 maxOracleDeviationBps_,
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
                || twapWindow_ < 60 || maxBnbFeedAge_ == 0 || maxUsdtFeedAge_ == 0 || maxEmergencyDuration_ == 0
        ) revert InvalidConfiguration();

        address token0 = pool.token0();
        address token1 = pool.token1();
        if (token0 != USDT || token1 != WBNB || pool.fee() != POOL_FEE) revert InvalidPool();

        normalLossBps = normalLossBps_;
        maxEmergencyLossBps = maxEmergencyLossBps_;
        maxOracleDeviationBps = maxOracleDeviationBps_;
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

    function minimumOut(address tokenIn, address tokenOut, uint256 amountIn, bool emergency)
        external
        view
        returns (uint256 minOut)
    {
        return quote(tokenIn, tokenOut, amountIn, emergency).minOut;
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
        q.deviationBps = FullMath.mulDiv(upper - lower, BPS, lower);
        if (q.deviationBps > maxOracleDeviationBps) {
            revert OracleDeviation(q.chainlinkOut, q.twapOut, q.deviationBps);
        }

        q.lossBps = _lossBudget(emergency);
        q.fairOut = lower;
        q.minOut = FullMath.mulDiv(lower, BPS - q.lossBps, BPS);
        if (q.minOut == 0) revert InvalidAmount();
    }

    function _lossBudget(bool emergency) internal view returns (uint16) {
        if (!emergency) return normalLossBps;
        if (emergencyLossBps == 0 || emergencyExpiresAt <= block.timestamp || emergencyLossBps > maxEmergencyLossBps) {
            revert EmergencyBudgetInactive();
        }
        return emergencyLossBps;
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
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0) revert InvalidOracleAnswer(address(feed));
        if (updatedAt > block.timestamp) revert FutureOracleTimestamp(address(feed), updatedAt);
        if (answeredInRound < roundId) {
            revert IncompleteOracleRound(address(feed), roundId, answeredInRound);
        }
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
