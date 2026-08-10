// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IVaultBAsyncStrategy} from "./interfaces/IVaultBAsyncStrategy.sol";

/// @notice Standalone Vault B ERC-4626 with an explicit asynchronous redeem
/// surface. Standard ERC-4626 withdraw/redeem remain synchronous and never
/// return a fake partial result.
contract DeepYieldVaultB is ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    enum RedeemStatus {
        NONE,
        PENDING,
        CLAIMED,
        CANCELED
    }

    struct RedeemRequest {
        address owner;
        address receiver;
        uint128 shares;
        uint64 requestedAt;
        RedeemStatus status;
        bytes32 strategyRequestId;
    }

    IVaultBAsyncStrategy public strategy;
    address public treasury;
    uint256 public depositCap;
    uint256 public immutable MIN_DEPOSIT;
    uint256 public immutable MIN_REDEEM_SHARES;
    uint256 public constant MAX_PENDING_REDEEMS = 64;
    uint16 public constant MIN_BATCH_COMMIT_BPS = 500;
    uint16 public constant MAX_BATCH_EXECUTION_LOSS_BPS = 200;
    uint256 internal constant BPS = 10_000;

    uint256 public nextRequestId;
    uint256 public outstandingRedeemShares;
    uint256 public outstandingRedeemCount;
    uint256 public redeemCycleSupplySnapshot;
    uint256 public redeemCycleAssetsSnapshot;
    uint256 public redeemCycleCommittedShares;
    uint256 public redeemCyclePayoutAssets;
    uint256 public redeemCyclePayoutClaimed;
    uint256 public redeemCycleProtocolCredit;
    bool internal _redeemCycleCommitted;
    bool public redeemCycleSettlementInitialized;
    mapping(uint256 => RedeemRequest) public redeemRequests;
    mapping(address => uint256) public pendingRequestPlusOne;

    error ZeroAddress();
    error ZeroAmount();
    error DepositCapExceeded();
    error DepositBelowMinimum(uint256 assets, uint256 required);
    error StrategyShortfall(uint256 requested, uint256 received);
    error StrategyNotEmpty();
    error StrategyUnset();
    error StrategyWiringMismatch();
    error RedeemQueueActive(uint256 shares);
    error RedeemQueueFull();
    error RedeemBelowMinimum(uint256 shares, uint256 required);
    error PendingRequestExists(uint256 requestId);
    error RedeemRequestUnknown();
    error RedeemNotReady();
    error NotRedeemOwner();
    error NotTreasury();
    error RedeemCycleLocked();
    error RedeemCycleNotReady(uint256 queuedShares, uint256 thresholdShares);
    error RedeemCycleExecutionLossExceeded(uint256 effectiveLoss, uint256 maximumLoss, uint256 requiredTopUp);
    error RedeemCyclePayoutUnderfunded(uint256 payoutBeforeCharge, uint256 executionLossCharge);
    error TooManyShares();

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event DepositCapUpdated(uint256 oldCap, uint256 newCap);
    event RedeemRequested(
        uint256 indexed requestId,
        bytes32 indexed strategyRequestId,
        address indexed owner,
        address receiver,
        uint256 shares
    );
    event RedeemCycleOpened(uint256 supply);
    event RedeemCycleCommittedEvent(
        uint256 queuedShares, uint256 thresholdShares, uint256 supplySnapshot, uint256 assetsSnapshot
    );
    event RedeemCycleSettlementInitialized(
        uint256 payoutAssets, uint256 measuredExecutionLoss, uint256 protocolCredit, uint256 chargedExecutionLoss
    );
    event RedeemCycleDeficitFunded(address indexed treasury, uint256 assets, uint256 cumulativeCredit);
    event RedeemCycleCleared();
    event RedeemClaimed(uint256 indexed requestId, address indexed receiver, uint256 shares, uint256 assets);
    event RedeemReceiverUpdated(uint256 indexed requestId, address indexed oldReceiver, address indexed newReceiver);
    event RedeemCanceled(uint256 indexed requestId, address indexed owner, uint256 shares);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address guardian_,
        address treasury_,
        uint256 depositCap_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        if (address(asset_) == address(0) || admin_ == address(0) || guardian_ == address(0) || treasury_ == address(0))
        {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(GUARDIAN_ROLE, guardian_);
        treasury = treasury_;
        depositCap = depositCap_;
        MIN_DEPOSIT = 10 ** IERC20Metadata(address(asset_)).decimals();
        MIN_REDEEM_SHARES = MIN_DEPOSIT * 1e6;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 deployed = address(strategy) == address(0) ? 0 : strategy.estimatedTotalAssets();
        return idle + deployed;
    }

    function setStrategy(address newStrategy) external onlyRole(ADMIN_ROLE) {
        if (newStrategy == address(0)) revert ZeroAddress();
        if (outstandingRedeemShares != 0) revert RedeemQueueActive(outstandingRedeemShares);
        address oldStrategy = address(strategy);
        if (oldStrategy != address(0)) {
            if (strategy.estimatedTotalAssets() != 0) revert StrategyNotEmpty();
            IERC20(asset()).forceApprove(oldStrategy, 0);
        }
        IVaultBAsyncStrategy candidate = IVaultBAsyncStrategy(newStrategy);
        if (address(candidate.asset()) != asset() || candidate.vault() != address(this)) {
            revert StrategyWiringMismatch();
        }
        strategy = candidate;
        IERC20(asset()).forceApprove(newStrategy, type(uint256).max);
        emit StrategyUpdated(oldStrategy, newStrategy);
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function setDepositCap(uint256 newCap) external onlyRole(ADMIN_ROLE) {
        uint256 old = depositCap;
        depositCap = newCap;
        emit DepositCapUpdated(old, newCap);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (paused() || redeemCycleCommitted()) return 0;
        if (address(strategy) != address(0) && !strategy.depositsAllowed()) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 managed = totalAssets();
        return managed >= depositCap ? 0 : depositCap - managed;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 assets = maxDeposit(receiver);
        return assets == type(uint256).max ? type(uint256).max : convertToShares(assets);
    }

    function availableImmediateLiquidity() public view returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return address(strategy) == address(0) ? idle : idle + strategy.availableWithdrawLimit();
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (redeemCycleCommitted()) return 0;
        uint256 ownerAssets = super.maxWithdraw(owner);
        uint256 liquid = availableImmediateLiquidity();
        return ownerAssets < liquid ? ownerAssets : liquid;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (redeemCycleCommitted()) return 0;
        uint256 ownerShares = super.maxRedeem(owner);
        uint256 liquid = availableImmediateLiquidity();
        if (liquid == 0) return 0;
        if (liquid >= totalAssets()) return ownerShares;
        uint256 liquidShares = convertToShares(liquid);
        return ownerShares < liquidShares ? ownerShares : liquidShares;
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (redeemCycleCommitted()) revert RedeemQueueActive(outstandingRedeemShares);
        if (assets == 0) revert ZeroAmount();
        if (assets < MIN_DEPOSIT) revert DepositBelowMinimum(assets, MIN_DEPOSIT);
        if (assets > maxDeposit(receiver)) revert DepositCapExceeded();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (redeemCycleCommitted()) revert RedeemQueueActive(outstandingRedeemShares);
        if (shares == 0) revert ZeroAmount();
        assets = previewMint(shares);
        if (assets < MIN_DEPOSIT) revert DepositBelowMinimum(assets, MIN_DEPOSIT);
        if (shares > maxMint(receiver)) revert DepositCapExceeded();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (redeemCycleCommitted()) revert RedeemQueueActive(outstandingRedeemShares);
        if (assets == 0) revert ZeroAmount();
        if (assets > maxWithdraw(owner)) revert RedeemNotReady();
        _ensureLiquidity(assets);
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        if (redeemCycleCommitted()) revert RedeemQueueActive(outstandingRedeemShares);
        if (shares == 0) revert ZeroAmount();
        if (shares > maxRedeem(owner)) revert RedeemNotReady();
        assets = previewRedeem(shares);
        _ensureLiquidity(assets);
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Queue an asynchronous redeem without reading NAV. Shares are
    /// escrowed, not burned, so the requester participates in gains/losses until
    /// claim-time settlement. Claims become order-independent after MainV2 has
    /// realized all strategy inventory into the accounting asset.
    function requestRedeem(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroAmount();
        if (shares > type(uint128).max) revert TooManyShares();
        if (shares < MIN_REDEEM_SHARES) revert RedeemBelowMinimum(shares, MIN_REDEEM_SHARES);
        if (outstandingRedeemCount >= MAX_PENDING_REDEEMS) revert RedeemQueueFull();
        if (redeemCycleCommitted()) revert RedeemCycleLocked();
        if (receiver == address(0) || owner == address(0)) revert ZeroAddress();
        uint256 pendingPlusOne = pendingRequestPlusOne[owner];
        if (pendingPlusOne != 0) revert PendingRequestExists(pendingPlusOne - 1);
        IVaultBAsyncStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0)) revert StrategyUnset();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        if (outstandingRedeemCount == 0) {
            emit RedeemCycleOpened(totalSupply());
        }

        _transfer(owner, address(this), shares);
        requestId = nextRequestId++;
        bytes32 strategyId = strategyRequestId(requestId);
        redeemRequests[requestId] = RedeemRequest({
            owner: owner,
            receiver: receiver,
            // Bounded by the explicit type(uint128).max check above.
            // forge-lint: disable-next-line(unsafe-typecast)
            shares: uint128(shares),
            requestedAt: uint64(block.timestamp),
            status: RedeemStatus.PENDING,
            strategyRequestId: strategyId
        });
        outstandingRedeemShares += shares;
        outstandingRedeemCount += 1;
        pendingRequestPlusOne[owner] = requestId + 1;
        activeStrategy.requestWithdrawal(strategyId, 0);
        emit RedeemRequested(requestId, strategyId, owner, receiver, shares);
    }

    /// @notice Commit a batch only after it reaches 5% of current supply. There
    /// is deliberately no time-only path: small exits use the contract-enforced
    /// idle reserve and cannot trigger a vault-wide inventory cycle.
    function commitRedeemCycle() external nonReentrant {
        if (outstandingRedeemCount == 0) revert RedeemRequestUnknown();
        if (_redeemCycleCommitted) revert RedeemCycleLocked();
        IVaultBAsyncStrategy activeStrategy = strategy;
        uint256 threshold = commitThresholdShares();
        if (outstandingRedeemShares < threshold) revert RedeemCycleNotReady(outstandingRedeemShares, threshold);
        if (activeStrategy.withdrawalCycleCommitted()) revert RedeemCycleLocked();

        redeemCycleSupplySnapshot = totalSupply();
        redeemCycleAssetsSnapshot = totalAssets();
        redeemCycleCommittedShares = outstandingRedeemShares;
        _redeemCycleCommitted = true;
        activeStrategy.commitWithdrawalCycle();
        emit RedeemCycleCommittedEvent(
            redeemCycleCommittedShares, threshold, redeemCycleSupplySnapshot, redeemCycleAssetsSnapshot
        );
    }

    /// @notice Effective commitment includes a Main-side automatic commit made
    /// atomically when a keeper begins an LP close with requests outstanding.
    function redeemCycleCommitted() public view returns (bool) {
        IVaultBAsyncStrategy activeStrategy = strategy;
        return
            _redeemCycleCommitted
                || (address(activeStrategy) != address(0) && activeStrategy.withdrawalCycleCommitted());
    }

    function commitThresholdShares() public view returns (uint256 threshold) {
        if (outstandingRedeemCount == 0) return 0;
        threshold = Math.mulDiv(totalSupply(), MIN_BATCH_COMMIT_BPS, BPS, Math.Rounding.Ceil);
        if (threshold < MIN_REDEEM_SHARES) threshold = MIN_REDEEM_SHARES;
    }

    /// @notice Permissionless settlement to the receiver fixed at request.
    /// Claims are order-independent after Main is fully USDT: every request
    /// burns escrowed shares at the same live PPS, so a bad receiver cannot
    /// block unrelated users.
    function claimRedeem(uint256 requestId) external nonReentrant returns (uint256 assets) {
        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemStatus.PENDING) revert RedeemRequestUnknown();
        IVaultBAsyncStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0)) revert StrategyUnset();
        if (!activeStrategy.withdrawalReady(request.strategyRequestId)) revert RedeemNotReady();

        uint256 shares = request.shares;
        if (_redeemCycleCommitted) {
            if (!redeemCycleSettlementInitialized) _initializeRedeemCycleSettlement(activeStrategy);
            assets = shares == outstandingRedeemShares
                ? redeemCyclePayoutAssets - redeemCyclePayoutClaimed
                : Math.mulDiv(redeemCyclePayoutAssets, shares, redeemCycleCommittedShares);
            redeemCyclePayoutClaimed += assets;
        } else {
            assets = previewRedeem(shares);
        }
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 missing = assets > idle ? assets - idle : 0;

        request.status = RedeemStatus.CLAIMED;
        outstandingRedeemShares -= shares;
        outstandingRedeemCount -= 1;
        pendingRequestPlusOne[request.owner] = 0;

        uint256 withdrawn = activeStrategy.claimWithdrawal(request.strategyRequestId, missing);
        if (withdrawn != missing) revert StrategyShortfall(missing, withdrawn);
        if (IERC20(asset()).balanceOf(address(this)) < assets) {
            revert StrategyShortfall(assets, IERC20(asset()).balanceOf(address(this)));
        }

        _burn(address(this), shares);
        if (assets != 0) IERC20(asset()).safeTransfer(request.receiver, assets);
        if (outstandingRedeemCount == 0) _clearRedeemCycle();
        emit Withdraw(msg.sender, request.receiver, request.owner, assets, shares);
        emit RedeemClaimed(requestId, request.receiver, shares, assets);
    }

    function updateRedeemReceiver(uint256 requestId, address newReceiver) external nonReentrant {
        if (newReceiver == address(0)) revert ZeroAddress();
        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemStatus.PENDING || msg.sender != request.owner) {
            revert RedeemRequestUnknown();
        }
        address oldReceiver = request.receiver;
        request.receiver = newReceiver;
        emit RedeemReceiverUpdated(requestId, oldReceiver, newReceiver);
    }

    /// @notice The owner may cancel only before the batch is committed. A
    /// committed request must settle so the requester cannot retain all shares
    /// after imposing an irreversible vault-wide unwind.
    function cancelRedeem(uint256 requestId) external nonReentrant {
        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemStatus.PENDING) revert RedeemRequestUnknown();
        if (msg.sender != request.owner) revert NotRedeemOwner();
        if (redeemCycleCommitted()) revert RedeemCycleLocked();

        uint256 shares = request.shares;
        request.status = RedeemStatus.CANCELED;
        outstandingRedeemShares -= shares;
        outstandingRedeemCount -= 1;
        pendingRequestPlusOne[request.owner] = 0;
        strategy.cancelWithdrawal(request.strategyRequestId);
        _transfer(address(this), request.owner, shares);
        if (outstandingRedeemCount == 0) _clearRedeemCycle();
        emit RedeemCanceled(requestId, request.owner, shares);
    }

    function pendingRedeemRequest(uint256 requestId) external view returns (uint256 shares) {
        RedeemRequest storage request = redeemRequests[requestId];
        return request.status == RedeemStatus.PENDING ? request.shares : 0;
    }

    function claimableRedeemRequest(uint256 requestId) external view returns (uint256 assets) {
        RedeemRequest storage request = redeemRequests[requestId];
        IVaultBAsyncStrategy activeStrategy = strategy;
        if (
            request.status != RedeemStatus.PENDING || address(activeStrategy) == address(0)
                || !activeStrategy.withdrawalReady(request.strategyRequestId)
        ) return 0;
        if (_redeemCycleCommitted) {
            uint256 payout = redeemCyclePayoutAssets;
            if (!redeemCycleSettlementInitialized) {
                (bool valid, uint256 previewPayout) = _previewRedeemCycleSettlement(activeStrategy);
                if (!valid) return 0;
                payout = previewPayout;
            }
            if (request.shares == outstandingRedeemShares && redeemCycleSettlementInitialized) {
                return payout - redeemCyclePayoutClaimed;
            }
            return Math.mulDiv(payout, request.shares, redeemCycleCommittedShares);
        }
        return previewRedeem(request.shares);
    }

    /// @notice Protocol treasury funding for an over-budget committed cycle.
    /// The credit both enters NAV and offsets measured execution loss; it does
    /// not authorize a wider loss budget.
    function fundRedeemCycleDeficit(uint256 assets) external nonReentrant {
        if (msg.sender != treasury) revert NotTreasury();
        if (!_redeemCycleCommitted || redeemCycleSettlementInitialized) revert RedeemCycleLocked();
        if (assets == 0) revert ZeroAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        redeemCycleProtocolCredit += assets;
        emit RedeemCycleDeficitFunded(msg.sender, assets, redeemCycleProtocolCredit);
    }

    function strategyRequestId(uint256 requestId) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), requestId));
    }

    function _ensureLiquidity(uint256 assetsNeeded) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= assetsNeeded) return;
        IVaultBAsyncStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0)) revert StrategyUnset();
        uint256 missing = assetsNeeded - idle;
        uint256 withdrawn = activeStrategy.withdrawToVault(missing);
        if (withdrawn < missing) revert StrategyShortfall(missing, withdrawn);
    }

    function _initializeRedeemCycleSettlement(IVaultBAsyncStrategy activeStrategy) internal {
        if (!activeStrategy.withdrawalCycleBatchCommitted()) revert StrategyWiringMismatch();
        uint256 measured = activeStrategy.withdrawalCycleExecutionLoss();
        uint256 chargeable = activeStrategy.withdrawalCycleChargeableExecutionLoss();
        if (chargeable > measured) revert StrategyWiringMismatch();
        uint256 effective = measured > redeemCycleProtocolCredit ? measured - redeemCycleProtocolCredit : 0;
        uint256 charged = chargeable > redeemCycleProtocolCredit ? chargeable - redeemCycleProtocolCredit : 0;
        uint256 maximum = Math.mulDiv(redeemCycleAssetsSnapshot, MAX_BATCH_EXECUTION_LOSS_BPS, BPS);
        if (effective > maximum) {
            revert RedeemCycleExecutionLossExceeded(effective, maximum, effective - maximum);
        }

        (bool valid, uint256 payout) = _previewRedeemCycleSettlement(activeStrategy);
        if (!valid) {
            uint256 currentAssets = totalAssets();
            uint256 basePayout = Math.mulDiv(currentAssets, redeemCycleCommittedShares, redeemCycleSupplySnapshot);
            uint256 charge = Math.mulDiv(
                charged,
                redeemCycleSupplySnapshot - redeemCycleCommittedShares,
                redeemCycleSupplySnapshot,
                Math.Rounding.Ceil
            );
            revert RedeemCyclePayoutUnderfunded(basePayout, charge);
        }

        redeemCyclePayoutAssets = payout;
        redeemCycleSettlementInitialized = true;
        emit RedeemCycleSettlementInitialized(payout, measured, redeemCycleProtocolCredit, charged);
    }

    function _previewRedeemCycleSettlement(IVaultBAsyncStrategy activeStrategy)
        internal
        view
        returns (bool valid, uint256 payout)
    {
        uint256 supply = redeemCycleSupplySnapshot;
        uint256 batchShares = redeemCycleCommittedShares;
        if (supply == 0 || batchShares == 0 || batchShares > supply) return (false, 0);

        uint256 currentAssets = totalAssets();
        if (batchShares == supply) return (true, currentAssets);

        uint256 measured = activeStrategy.withdrawalCycleExecutionLoss();
        uint256 chargeable = activeStrategy.withdrawalCycleChargeableExecutionLoss();
        if (chargeable > measured) return (false, 0);
        uint256 effective = measured > redeemCycleProtocolCredit ? measured - redeemCycleProtocolCredit : 0;
        uint256 charged = chargeable > redeemCycleProtocolCredit ? chargeable - redeemCycleProtocolCredit : 0;
        uint256 maximum = Math.mulDiv(redeemCycleAssetsSnapshot, MAX_BATCH_EXECUTION_LOSS_BPS, BPS);
        if (effective > maximum) return (false, 0);

        uint256 basePayout = Math.mulDiv(currentAssets, batchShares, supply);
        uint256 charge = Math.mulDiv(charged, supply - batchShares, supply, Math.Rounding.Ceil);
        if (charge > basePayout) return (false, 0);
        return (true, basePayout - charge);
    }

    function _clearRedeemCycle() internal {
        _redeemCycleCommitted = false;
        redeemCycleSupplySnapshot = 0;
        redeemCycleAssetsSnapshot = 0;
        redeemCycleCommittedShares = 0;
        redeemCyclePayoutAssets = 0;
        redeemCyclePayoutClaimed = 0;
        redeemCycleProtocolCredit = 0;
        redeemCycleSettlementInitialized = false;
        emit RedeemCycleCleared();
    }
}
