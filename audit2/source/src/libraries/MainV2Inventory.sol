// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDedicatedVenueV2} from "../interfaces/IDedicatedVenue.sol";
import {IVaultBPriceGuard} from "../interfaces/IVaultBExecutionV2.sol";
import {MainV2Geometry} from "./MainV2Geometry.sol";
import {MainV2Valuation} from "./MainV2Valuation.sol";

interface IMainV2VenueRecovery {
    function closeUnstake(uint256 positionId) external;
    function closeDecrease(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) external;
    function closeCollect(uint256 positionId) external;
    function closeBurn(uint256 positionId) external;
    function writeOffStrandedPosition() external returns (uint256 strandedId);
}

struct CloseInventoryCall {
    uint256 positionId;
    uint256 deadline;
    bool emergency;
    uint16 normalCloseLossBps;
    uint16 emergencyCloseLossBps;
    uint16 maxSpotOracleDeviationBps;
    uint16 emergencySpotOracleDeviationBps;
    uint256 accountedPaired;
    uint256 accountedReward;
}

struct CloseInventoryResult {
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 expectedFairValue;
    uint256 actualFairValue;
    uint256 assetReceived;
    uint256 pairedReceived;
    uint256 nextAccountedPaired;
    uint256 nextAccountedReward;
}

/// @notice Inventory-accounting primitives for DedicatedVaultMainV2. The
/// library is deliberately stateless: Main owns the two accounted balances and
/// passes observed token-balance deltas in and out of these functions.
library MainV2Inventory {
    error InventoryBalanceDecreased(uint256 beforeBalance, uint256 afterBalance);

    /// @notice Credit only an observed inbound balance delta. A canonical venue
    /// action is never allowed to lower an inventory token balance; rejecting a
    /// negative delta keeps an accounted amount from getting ahead of reality.
    function creditObserved(uint256 accounted, uint256 beforeBalance, uint256 afterBalance)
        external
        pure
        returns (uint256 nextAccounted)
    {
        return _creditObserved(accounted, beforeBalance, afterBalance);
    }

    /// @notice Decrease an accounted balance by tokens actually consumed. The
    /// saturating form is intentional: a stale under-account cannot prevent the
    /// raw-balance liquidation path from reconciling and draining real tokens.
    function debitConsumed(uint256 accounted, uint256 consumed) external pure returns (uint256 nextAccounted) {
        return consumed >= accounted ? 0 : accounted - consumed;
    }

    /// @notice Execute and account a normal/emergency LP close. The Main keeps
    /// role, mode and job lifecycle ownership; this library owns only the
    /// balance-heavy valuation/venue section so Main stays under EIP-170.
    function closeAndCredit(
        IDedicatedVenueV2 venue,
        IVaultBPriceGuard priceGuard,
        IERC20 asset,
        IERC20 pairedToken,
        IERC20 rewardToken,
        CloseInventoryCall memory c
    ) external returns (CloseInventoryResult memory r) {
        priceGuard.minimumOut(address(pairedToken), address(asset), 1e18, c.emergency);
        MainV2Valuation.requireSpotOracleCoherence(
            venue, priceGuard, c.maxSpotOracleDeviationBps, c.emergencySpotOracleDeviationBps, c.emergency
        );

        (uint256 spotAssetExpected, uint256 spotPairedExpected) = venue.previewCloseAmounts(c.positionId);
        uint16 lossBps = c.emergency ? c.emergencyCloseLossBps : c.normalCloseLossBps;
        uint256 aggregateFloor;
        (r.amount0Min, r.amount1Min, r.expectedFairValue, aggregateFloor) =
            MainV2Valuation.closePlan(priceGuard, spotAssetExpected, spotPairedExpected, lossBps, c.emergency);

        uint256 assetBefore = asset.balanceOf(address(this));
        uint256 pairedBefore = pairedToken.balanceOf(address(this));
        uint256 rewardBefore = rewardToken.balanceOf(address(this));
        venue.close(c.positionId, r.amount0Min, r.amount1Min, c.deadline);
        r.assetReceived = asset.balanceOf(address(this)) - assetBefore;
        uint256 pairedAfter = pairedToken.balanceOf(address(this));
        r.nextAccountedPaired = _creditObserved(c.accountedPaired, pairedBefore, pairedAfter);
        r.pairedReceived = pairedAfter - pairedBefore;
        r.nextAccountedReward = _creditObserved(c.accountedReward, rewardBefore, rewardToken.balanceOf(address(this)));
        r.actualFairValue = MainV2Valuation.validateCloseProceeds(
            priceGuard, r.assetReceived, r.pairedReceived, c.emergency, aggregateFloor
        );
    }

    /// @dev Each recovery wrapper observes token balances around exactly one
    /// canonical venue action. Running as a linked library preserves Main's
    /// storage/balances while keeping this rare-path machinery out of Main.
    function forceUnstakeAndCredit(
        IDedicatedVenueV2 venue,
        IERC20 pairedToken,
        IERC20 rewardToken,
        uint256 positionId,
        uint256 accountedPaired,
        uint256 accountedReward
    ) external returns (uint256 nextPaired, uint256 nextReward) {
        (uint256 pairedBefore, uint256 rewardBefore) = _snapshot(pairedToken, rewardToken);
        venue.forceUnstakeSkipHarvest(positionId);
        return _creditAfter(pairedToken, rewardToken, accountedPaired, accountedReward, pairedBefore, rewardBefore);
    }

    function closeUnstakeAndCredit(
        address venue,
        IERC20 pairedToken,
        IERC20 rewardToken,
        uint256 positionId,
        uint256 accountedPaired,
        uint256 accountedReward
    ) external returns (uint256 nextPaired, uint256 nextReward) {
        (uint256 pairedBefore, uint256 rewardBefore) = _snapshot(pairedToken, rewardToken);
        IMainV2VenueRecovery(venue).closeUnstake(positionId);
        return _creditAfter(pairedToken, rewardToken, accountedPaired, accountedReward, pairedBefore, rewardBefore);
    }

    function closeDecreaseAndCredit(
        address venue,
        IERC20 pairedToken,
        IERC20 rewardToken,
        uint256 positionId,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        uint256 accountedPaired,
        uint256 accountedReward
    ) external returns (uint256 nextPaired, uint256 nextReward) {
        (uint256 pairedBefore, uint256 rewardBefore) = _snapshot(pairedToken, rewardToken);
        IMainV2VenueRecovery(venue).closeDecrease(positionId, amount0Min, amount1Min, deadline);
        return _creditAfter(pairedToken, rewardToken, accountedPaired, accountedReward, pairedBefore, rewardBefore);
    }

    /// @notice Build recovery decrease minima from one Venue preview and one
    /// PriceGuard policy snapshot. The guard selects the dynamic loss/deviation
    /// branch for the full LP notional; Main's immutable values remain stricter
    /// ceilings. Guardian calldata is applied by Main only after this floor.
    function recoveryDecreaseMinimums(
        IDedicatedVenueV2 venue,
        IVaultBPriceGuard priceGuard,
        uint256 positionId,
        uint16 normalCloseLossBps,
        uint16 emergencyCloseLossBps,
        uint16 maxSpotOracleDeviationBps,
        uint16 emergencySpotOracleDeviationBps
    ) external view returns (uint256 amount0Min, uint256 amount1Min) {
        (uint256 assetExpected, uint256 pairedExpected) = venue.previewCloseAmounts(positionId);
        uint256 referenceUsdtPerWbnb;
        uint16 guardLossBps;
        bool emergencyBudgetAvailable;
        (referenceUsdtPerWbnb,, guardLossBps, emergencyBudgetAvailable) =
            priceGuard.recoveryClosePolicy(assetExpected, pairedExpected);

        uint16 mainLossCeiling = emergencyBudgetAvailable ? emergencyCloseLossBps : normalCloseLossBps;
        uint16 effectiveLossBps = guardLossBps < mainLossCeiling ? guardLossBps : mainLossCeiling;
        if (assetExpected != 0 || pairedExpected != 0) {
            MainV2Valuation.requireSpotReferenceCoherence(
                venue,
                referenceUsdtPerWbnb,
                emergencyBudgetAvailable ? emergencySpotOracleDeviationBps : maxSpotOracleDeviationBps
            );
        }
        (amount0Min, amount1Min) = _recoveryMinimums(assetExpected, pairedExpected, effectiveLossBps);
    }

    function closeCollectAndCredit(
        address venue,
        IERC20 pairedToken,
        IERC20 rewardToken,
        uint256 positionId,
        uint256 accountedPaired,
        uint256 accountedReward
    ) external returns (uint256 nextPaired, uint256 nextReward) {
        (uint256 pairedBefore, uint256 rewardBefore) = _snapshot(pairedToken, rewardToken);
        IMainV2VenueRecovery(venue).closeCollect(positionId);
        return _creditAfter(pairedToken, rewardToken, accountedPaired, accountedReward, pairedBefore, rewardBefore);
    }

    function closeBurnAndCredit(
        address venue,
        IERC20 pairedToken,
        IERC20 rewardToken,
        uint256 positionId,
        uint256 accountedPaired,
        uint256 accountedReward
    ) external returns (uint256 nextPaired, uint256 nextReward) {
        (uint256 pairedBefore, uint256 rewardBefore) = _snapshot(pairedToken, rewardToken);
        IMainV2VenueRecovery(venue).closeBurn(positionId);
        return _creditAfter(pairedToken, rewardToken, accountedPaired, accountedReward, pairedBefore, rewardBefore);
    }

    function writeOffAndCredit(
        address venue,
        IERC20 pairedToken,
        IERC20 rewardToken,
        uint256 accountedPaired,
        uint256 accountedReward
    ) external returns (uint256 stranded, uint256 nextPaired, uint256 nextReward, uint256 pairedBefore) {
        uint256 rewardBefore;
        (pairedBefore, rewardBefore) = _snapshot(pairedToken, rewardToken);
        stranded = IMainV2VenueRecovery(venue).writeOffStrandedPosition();
        (nextPaired, nextReward) =
            _creditAfter(pairedToken, rewardToken, accountedPaired, accountedReward, pairedBefore, rewardBefore);
    }

    /// @notice Inventory value recognized by NAV/exposure. Any external token
    /// transfer above Main's canonical accounting is deliberately excluded until
    /// a later bounded liquidation turns it into USDT.
    function recognizedBalances(
        IERC20 pairedToken,
        IERC20 rewardToken,
        uint256 accountedPaired,
        uint256 accountedReward
    ) external view returns (uint256 paired, uint256 reward) {
        uint256 pairedRaw = pairedToken.balanceOf(address(this));
        paired = pairedRaw < accountedPaired ? pairedRaw : accountedPaired;
        uint256 rewardRaw = rewardToken.balanceOf(address(this));
        reward = rewardRaw < accountedReward ? rewardRaw : accountedReward;
    }

    function _snapshot(IERC20 pairedToken, IERC20 rewardToken)
        private
        view
        returns (uint256 pairedBefore, uint256 rewardBefore)
    {
        pairedBefore = pairedToken.balanceOf(address(this));
        rewardBefore = rewardToken.balanceOf(address(this));
    }

    function _creditAfter(
        IERC20 pairedToken,
        IERC20 rewardToken,
        uint256 accountedPaired,
        uint256 accountedReward,
        uint256 pairedBefore,
        uint256 rewardBefore
    ) private view returns (uint256 nextPaired, uint256 nextReward) {
        nextPaired = _creditObserved(accountedPaired, pairedBefore, pairedToken.balanceOf(address(this)));
        nextReward = _creditObserved(accountedReward, rewardBefore, rewardToken.balanceOf(address(this)));
    }

    function _creditObserved(uint256 accounted, uint256 beforeBalance, uint256 afterBalance)
        private
        pure
        returns (uint256 nextAccounted)
    {
        if (afterBalance < beforeBalance) revert InventoryBalanceDecreased(beforeBalance, afterBalance);
        return accounted + (afterBalance - beforeBalance);
    }

    function _recoveryMinimums(uint256 assetExpected, uint256 pairedExpected, uint16 lossBps)
        private
        pure
        returns (uint256 amount0Min, uint256 amount1Min)
    {
        amount0Min = MainV2Geometry.boundedLpMinimum(assetExpected, lossBps);
        amount1Min = MainV2Geometry.boundedLpMinimum(pairedExpected, lossBps);
    }
}
