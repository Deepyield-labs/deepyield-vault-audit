// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "./FullMath.sol";
import {MainV2Geometry} from "./MainV2Geometry.sol";
import {IDedicatedVenueV2} from "../interfaces/IDedicatedVenue.sol";
import {IVaultBPriceGuard, IVaultBRewardPriceGuard} from "../interfaces/IVaultBExecutionV2.sol";

interface IV3PoolSpotV {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint32, bool);
}

/// @title MainV2Valuation
/// @notice NAV / exposure / spot-oracle-coherence view logic extracted from
/// `DedicatedVaultMainV2` so its orchestration deploys once and links (EIP-170).
/// These are the exact computations that were internal to `Main`
/// (B1-T5/B1-T13), moved verbatim; every state/balance read stays on the caller
/// side and is passed in, so the `external`, `view`, no-storage-write linkage
/// carries no state risk. The `SpotDivergedFromOracle` signature matches
/// `Main`'s, so its selector is identical for existing `expectRevert` tests.
library MainV2Valuation {
    uint256 internal constant BPS = 10_000;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    error SpotDivergedFromOracle(uint256 spotUsdtPerWbnb, uint256 oracleUsdtPerWbnb);
    error CloseValueBelowFloor(uint256 minimumValue, uint256 actualValue);

    /// @notice Revenue-conservative NAV in USDT: minimumOut haircut on paired and
    /// reward inventory, and for the active position the LOWER of the TWAP/spot
    /// geometry (each oracle-valued) so a spot manipulation cannot inflate NAV.
    function totalAssetsUsdt(
        IDedicatedVenueV2 venue,
        IVaultBPriceGuard priceGuard,
        IVaultBRewardPriceGuard rewardPriceGuard,
        uint256 assetBalance,
        uint256 pairedBalance,
        uint256 rewardBalance,
        uint256 activePositionId
    ) external view returns (uint256 total) {
        total = assetBalance;
        if (pairedBalance != 0) total += priceGuard.minimumOut(WBNB, USDT, pairedBalance, false);
        if (activePositionId != 0) {
            priceGuard.minimumOut(WBNB, USDT, 1e18, false); // oracle cross-check even for one-sided USDT
            uint160 twapSqrtPrice = priceGuard.twapSqrtPriceX96();
            (uint256 twapAsset, uint256 twapPaired) =
                venue.previewCloseAmountsAtSqrtPrice(activePositionId, twapSqrtPrice);
            (uint256 spotAsset, uint256 spotPaired) = venue.previewCloseAmounts(activePositionId);
            uint256 twapValue = twapAsset + (twapPaired != 0 ? priceGuard.minimumOut(WBNB, USDT, twapPaired, false) : 0);
            uint256 spotValue = spotAsset + (spotPaired != 0 ? priceGuard.minimumOut(WBNB, USDT, spotPaired, false) : 0);
            total += twapValue < spotValue ? twapValue : spotValue;
        }
        if (rewardBalance != 0) total += rewardPriceGuard.minimumOut(rewardBalance, false);
    }

    /// @notice Deposit-conservative NAV in USDT (B10-T2): identical to
    /// `totalAssetsUsdt` — same oracle-valued (`minimumOut`) paired/reward legs —
    /// EXCEPT the active position uses the HIGHER of the TWAP/spot geometry. NAV is
    /// directional: redemptions must not OVER-value (that dilutes remaining holders,
    /// so `totalAssetsUsdt` takes the min), but deposits must not UNDER-value (that
    /// dilutes existing holders by minting too many shares). A downward spot push
    /// lowers `spotValue`; `min` would pick it and hand a depositor cheap shares.
    /// Taking the max here removes that direction of the manipulation; the paired
    /// legs are still oracle-priced, so only the position geometry — not the price —
    /// is affected. Griefer symmetric to the redeem side under `min`: pushing spot
    /// UP before someone else's deposit mints them fewer shares, which costs the
    /// attacker and does not pay. Used only for the deposit/mint path.
    function totalAssetsUsdtUpper(
        IDedicatedVenueV2 venue,
        IVaultBPriceGuard priceGuard,
        IVaultBRewardPriceGuard rewardPriceGuard,
        uint256 assetBalance,
        uint256 pairedBalance,
        uint256 rewardBalance,
        uint256 activePositionId
    ) external view returns (uint256 total) {
        total = assetBalance;
        if (pairedBalance != 0) total += priceGuard.minimumOut(WBNB, USDT, pairedBalance, false);
        if (activePositionId != 0) {
            priceGuard.minimumOut(WBNB, USDT, 1e18, false); // oracle cross-check even for one-sided USDT
            uint160 twapSqrtPrice = priceGuard.twapSqrtPriceX96();
            (uint256 twapAsset, uint256 twapPaired) =
                venue.previewCloseAmountsAtSqrtPrice(activePositionId, twapSqrtPrice);
            (uint256 spotAsset, uint256 spotPaired) = venue.previewCloseAmounts(activePositionId);
            uint256 twapValue = twapAsset + (twapPaired != 0 ? priceGuard.minimumOut(WBNB, USDT, twapPaired, false) : 0);
            uint256 spotValue = spotAsset + (spotPaired != 0 ? priceGuard.minimumOut(WBNB, USDT, spotPaired, false) : 0);
            total += twapValue > spotValue ? twapValue : spotValue;
        }
        if (rewardBalance != 0) total += rewardPriceGuard.minimumOut(rewardBalance, false);
    }

    /// @notice Exposure of the strategy in USDT for the capital ceiling: fair-mid
    /// valued (no haircut) and, for the active position, the HIGHER of the
    /// TWAP/spot geometry — the opposite direction of the conservative NAV.
    function fundingExposureUsdt(
        IDedicatedVenueV2 venue,
        IVaultBPriceGuard priceGuard,
        IVaultBRewardPriceGuard rewardPriceGuard,
        uint256 assetBalance,
        uint256 pairedBalance,
        uint256 rewardBalance,
        uint256 activePositionId
    ) external view returns (uint256 total) {
        total = assetBalance;
        if (pairedBalance != 0) total += priceGuard.fairValue(WBNB, USDT, pairedBalance);
        if (activePositionId != 0) {
            priceGuard.minimumOut(WBNB, USDT, 1e18, false); // oracle coherence, as in NAV
            uint160 twapSqrtPrice = priceGuard.twapSqrtPriceX96();
            (uint256 twapAsset, uint256 twapPaired) =
                venue.previewCloseAmountsAtSqrtPrice(activePositionId, twapSqrtPrice);
            (uint256 spotAsset, uint256 spotPaired) = venue.previewCloseAmounts(activePositionId);
            uint256 twapValue = twapAsset + (twapPaired != 0 ? priceGuard.fairValue(WBNB, USDT, twapPaired) : 0);
            uint256 spotValue = spotAsset + (spotPaired != 0 ? priceGuard.fairValue(WBNB, USDT, spotPaired) : 0);
            total += twapValue > spotValue ? twapValue : spotValue;
        }
        if (rewardBalance != 0) total += rewardPriceGuard.fairValue(rewardBalance);
    }

    /// @notice Build the bounded close plan on one valuation basis.
    function closePlan(
        IVaultBPriceGuard priceGuard,
        uint256 assetExpected,
        uint256 pairedExpected,
        uint16 lossBps,
        bool emergency
    )
        external
        view
        returns (uint256 amount0Min, uint256 amount1Min, uint256 expectedFairValue, uint256 aggregateFloor)
    {
        amount0Min = MainV2Geometry.boundedLpMinimum(assetExpected, lossBps);
        amount1Min = MainV2Geometry.boundedLpMinimum(pairedExpected, lossBps);
        uint256 expectedExecutionValue;
        (expectedFairValue, expectedExecutionValue) =
            _closeInventoryValues(priceGuard, assetExpected, pairedExpected, emergency);
        aggregateFloor = FullMath.mulDiv(expectedExecutionValue, BPS - lossBps, BPS);
    }

    /// @notice Validate realized inventory against the precomputed aggregate floor.
    function validateCloseProceeds(
        IVaultBPriceGuard priceGuard,
        uint256 assetReceived,
        uint256 pairedReceived,
        bool emergency,
        uint256 aggregateFloor
    ) external view returns (uint256 actualFairValue) {
        uint256 actualExecutionValue;
        (actualFairValue, actualExecutionValue) =
            _closeInventoryValues(priceGuard, assetReceived, pairedReceived, emergency);
        if (actualExecutionValue < aggregateFloor) {
            revert CloseValueBelowFloor(aggregateFloor, actualExecutionValue);
        }
    }

    function _closeInventoryValues(
        IVaultBPriceGuard priceGuard,
        uint256 assetAmount,
        uint256 pairedAmount,
        bool emergency
    ) private view returns (uint256 fairValue, uint256 executionValue) {
        fairValue = assetAmount;
        if (pairedAmount != 0) fairValue += priceGuard.fairValue(WBNB, USDT, pairedAmount);
        executionValue = fairValue;
        if (emergency && pairedAmount != 0) {
            executionValue = assetAmount + priceGuard.minimumOut(WBNB, USDT, pairedAmount, true);
        }
    }

    /// @notice Revert if the live pool spot price deviates from the oracle by more
    /// than the allowed band. Spot comes from the pool via the venue; oracle price
    /// is the guard's fair USDT value of 1 WBNB.
    function requireSpotOracleCoherence(
        IDedicatedVenueV2 venue,
        IVaultBPriceGuard priceGuard,
        uint16 maxDeviationBps,
        uint16 emergencyDeviationBps,
        bool emergency
    ) external view {
        uint256 oracleUsdtPerWbnb = priceGuard.fairValue(WBNB, USDT, 1e18);
        if (oracleUsdtPerWbnb == 0) revert SpotDivergedFromOracle(0, 0);
        (uint160 spotSqrt,,,,,,) = IV3PoolSpotV(venue.poolAddress()).slot0();
        uint256 tmp = FullMath.mulDiv(Q96, Q96, spotSqrt);
        uint256 spotUsdtPerWbnb = FullMath.mulDiv(tmp, 1e18, spotSqrt);
        uint256 diff = spotUsdtPerWbnb > oracleUsdtPerWbnb
            ? spotUsdtPerWbnb - oracleUsdtPerWbnb
            : oracleUsdtPerWbnb - spotUsdtPerWbnb;
        uint16 tol = emergency ? emergencyDeviationBps : maxDeviationBps;
        if (FullMath.mulDiv(diff, BPS, oracleUsdtPerWbnb) > tol) {
            revert SpotDivergedFromOracle(spotUsdtPerWbnb, oracleUsdtPerWbnb);
        }
    }
}
