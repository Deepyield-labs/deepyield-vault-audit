// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFeeSink} from "./interfaces/IFeeSink.sol";

/// @title FixedFeeSink
/// @notice Non-custodial fee sink for deployments whose partner attribution is
///         performed off-chain. Successful fees move directly from the payer to
///         the project treasury; the sink does not retain normal fee inventory.
contract FixedFeeSink is AccessControlDefaultAdminRules, ReentrancyGuard, IFeeSink {
    using SafeERC20 for IERC20;

    uint48 public constant DEFAULT_ADMIN_TRANSFER_DELAY = 2 days;
    uint64 public constant TREASURY_CHANGE_DELAY = 2 days;

    IERC20 public immutable asset;
    address public projectTreasury;
    address public pendingProjectTreasury;
    uint64 public pendingProjectTreasuryReadyAt;
    uint256 public cumulativeReceived;

    error ZeroAddress();
    error InvalidTreasury();
    error NoPendingTreasury();
    error TreasuryTimelockNotElapsed(uint64 readyAt);
    error TransferMismatch(uint256 expected, uint256 payerDelta, uint256 treasuryDelta);

    event FeeRecorded(address indexed payer, address indexed treasury, uint256 amount);
    event ProjectTreasuryProposed(address indexed treasury, uint64 readyAt);
    event ProjectTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProjectTreasuryProposalCancelled(address indexed treasury);
    event UnrecordedRecovered(address indexed treasury, uint256 amount);

    constructor(IERC20 asset_, address projectTreasury_, address admin_)
        AccessControlDefaultAdminRules(DEFAULT_ADMIN_TRANSFER_DELAY, admin_)
    {
        if (address(asset_) == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (projectTreasury_ == address(0) || projectTreasury_ == address(this) || projectTreasury_ == address(asset_)) revert InvalidTreasury();
        asset = asset_;
        projectTreasury = projectTreasury_;
    }

    function recordFee(uint256 amount) external override nonReentrant {
        if (amount == 0) return;

        address treasury = projectTreasury;
        uint256 payerBefore = asset.balanceOf(msg.sender);
        uint256 treasuryBefore = asset.balanceOf(treasury);
        asset.safeTransferFrom(msg.sender, treasury, amount);
        uint256 payerAfter = asset.balanceOf(msg.sender);
        uint256 treasuryAfter = asset.balanceOf(treasury);
        uint256 payerDelta = payerBefore >= payerAfter ? payerBefore - payerAfter : 0;
        uint256 treasuryDelta = treasuryAfter >= treasuryBefore ? treasuryAfter - treasuryBefore : 0;
        if (payerDelta != amount || treasuryDelta != amount) {
            revert TransferMismatch(amount, payerDelta, treasuryDelta);
        }

        cumulativeReceived += amount;
        emit FeeRecorded(msg.sender, treasury, amount);
    }

    function proposeProjectTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0) || newTreasury == address(this) || newTreasury == address(asset)) {
            revert InvalidTreasury();
        }
        pendingProjectTreasury = newTreasury;
        pendingProjectTreasuryReadyAt = uint64(block.timestamp + TREASURY_CHANGE_DELAY);
        emit ProjectTreasuryProposed(newTreasury, pendingProjectTreasuryReadyAt);
    }

    function cancelProjectTreasuryProposal() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address pending = pendingProjectTreasury;
        if (pending == address(0)) revert NoPendingTreasury();
        pendingProjectTreasury = address(0);
        pendingProjectTreasuryReadyAt = 0;
        emit ProjectTreasuryProposalCancelled(pending);
    }

    function applyProjectTreasury() external {
        address next = pendingProjectTreasury;
        if (next == address(0)) revert NoPendingTreasury();
        uint64 readyAt = pendingProjectTreasuryReadyAt;
        if (block.timestamp < readyAt) revert TreasuryTimelockNotElapsed(readyAt);

        address old = projectTreasury;
        projectTreasury = next;
        pendingProjectTreasury = address(0);
        pendingProjectTreasuryReadyAt = 0;
        emit ProjectTreasuryUpdated(old, next);
    }

    /// @notice Recover tokens sent directly to this non-custodial sink. Normal
    ///         fee recording never uses this balance.
    function recoverUnrecorded() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (uint256 recovered) {
        recovered = asset.balanceOf(address(this));
        if (recovered == 0) return 0;
        address treasury = projectTreasury;
        uint256 treasuryBefore = asset.balanceOf(treasury);
        asset.safeTransfer(treasury, recovered);
        uint256 sinkAfter = asset.balanceOf(address(this));
        uint256 treasuryAfter = asset.balanceOf(treasury);
        uint256 sinkDelta = recovered >= sinkAfter ? recovered - sinkAfter : 0;
        uint256 treasuryDelta = treasuryAfter >= treasuryBefore ? treasuryAfter - treasuryBefore : 0;
        if (sinkDelta != recovered || treasuryDelta != recovered) {
            revert TransferMismatch(recovered, sinkDelta, treasuryDelta);
        }
        emit UnrecordedRecovered(treasury, recovered);
    }
}
