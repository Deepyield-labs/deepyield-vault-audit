// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IPartnerRegistry} from "../interfaces/IPartnerRegistry.sol";
import {IWrapperFactory} from "../interfaces/IWrapperFactory.sol";

/// @title PartnerRegistry - single source of truth for the multi-partner
///        wrapper graph.
/// @notice Per Task 1.37e (Option F v5) design. Two structurally distinct
///         sets:
///           1. `activeWrapperList` (bounded, len <= `MAX_ACTIVE_WRAPPERS`):
///              the iteration target for `PartnerAttributedSplitter.recordFee`.
///              Active + PausedDeposits wrappers only; Retired removed.
///           2. `wrappersOfPartner` (append-only history per partner):
///              never iterated on-chain by accrual or settlement.
///
///         Onboarding is factory-only. The factory address is bound via
///         a one-shot `setFactory(...)` admin call: the registry is
///         deployed first, the factory is deployed pointing at it, and
///         the admin then calls `setFactory(factoryAddr)` exactly once.
///         A second invocation reverts `FactoryAlreadySet`, and the
///         candidate is cross-validated end-to-end (code-present,
///         `IWrapperFactory.registry() == address(this)`,
///         `IWrapperFactory.vault() == vault`) so a typo cannot brick
///         onboarding. After the one-shot binding, `factory()` is
///         effectively immutable.
contract PartnerRegistry is AccessControl, IPartnerRegistry {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev Sized per design doc §4.B — ~4x the steady-state footprint of
    ///      ~30 partners, providing structural buffer for triple-generation
    ///      pile-up + new-partner onboarding + emergency parallel wrappers,
    ///      with explicit gas-budget check at the cap.
    uint256 public constant override MAX_ACTIVE_WRAPPERS = 128;

    /// @notice The vault the registry's wrappers wrap. Used only by
    ///         `retireWrapper(...)` to enforce the drained precondition.
    address public immutable override vault;

    /// @notice Atomic-onboarding entry point. Set ONCE via `setFactory`
    ///         immediately after construction (registry + factory have a
    ///         mutual constructor dependency that we resolve with a
    ///         one-shot setter). After the first set, further calls
    ///         revert `FactoryAlreadySet`.
    address public override factory;

    // ── per-partner state ──

    mapping(bytes32 => address) public override currentWrapperOf;
    mapping(bytes32 => address) public override payoutTreasury;
    mapping(bytes32 => address[]) private _wrappersOfPartner;

    // ── F-6: timelocked partner-payout-treasury change ──
    /// @dev Changing a partner's payout treasury is proposed, then applied after
    /// PARTNER_TREASURY_TIMELOCK, so the partner can `claimWrapper` what is
    /// already accrued to the old address before payouts move. The initial
    /// treasury is still set instantly at registration (bootstrap).
    uint256 public constant PARTNER_TREASURY_TIMELOCK = 2 days;
    mapping(bytes32 => address) public pendingPartnerTreasury;
    mapping(bytes32 => uint64)  public pendingPartnerTreasuryReadyAt;

    event PartnerTreasuryProposed(bytes32 indexed partnerId, address indexed newTreasury, uint64 readyAt);

    error NoPendingPartnerTreasury();
    error PartnerTreasuryTimelockNotElapsed(uint64 readyAt);

    // ── per-wrapper state ──

    mapping(address => bytes32) public override partnerOfWrapper;
    mapping(address => bool) public override isRegisteredWrapper;
    mapping(address => bool) public override isWrapperDepositsPaused;
    mapping(address => bool) public override isRetiredWrapper;

    // ── active iterable set ──

    address[] private _activeWrapperList;
    /// @dev `_activeIndexPlusOne[W] = i+1` ⇒ W is at index `i` in
    ///      `_activeWrapperList`. 0 means "not in the list" (used by retire's
    ///      swap-and-pop).
    mapping(address => uint256) private _activeIndexPlusOne;

    constructor(address vault_, address admin_) {
        if (vault_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        vault = vault_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    /// @notice One-shot factory setter. Admin must call this exactly once
    /// after deploying the `WrapperFactory`. After the first call, further
    /// invocations revert `FactoryAlreadySet`. From the perspective of
    /// every callsite that reads `factory()`, the value is immutable once
    /// the system is fully wired.
    ///
    /// Hardening (Task 1.38a): rather than accept any non-zero address,
    /// the candidate is cross-validated end-to-end so a typo or wrong
    /// contract address cannot brick onboarding:
    ///   - candidate must be a deployed contract (`code.length > 0`)
    ///   - `IWrapperFactory(factory_).registry() == address(this)` — the
    ///     candidate must point back at THIS registry
    ///   - `IWrapperFactory(factory_).vault() == vault` — the candidate
    ///     must be wired to the same vault this registry guards
    /// On any failure, reverts `InvalidFactory()`.
    function setFactory(address factory_) external override onlyRole(ADMIN_ROLE) {
        if (factory_ == address(0)) revert ZeroAddress();
        if (factory != address(0)) revert FactoryAlreadySet();
        if (factory_.code.length == 0) revert InvalidFactory();

        // Defensive try/catch so a non-conforming contract reverts with
        // our typed error rather than bubbling up an opaque revert.
        try IWrapperFactory(factory_).registry() returns (address r) {
            if (r != address(this)) revert InvalidFactory();
        } catch {
            revert InvalidFactory();
        }
        try IWrapperFactory(factory_).vault() returns (address v) {
            if (v != vault) revert InvalidFactory();
        } catch {
            revert InvalidFactory();
        }

        factory = factory_;
    }

    // ──────────────────────────────────────────────────────────────────
    // views
    // ──────────────────────────────────────────────────────────────────

    function wrappersOfPartner(bytes32 partnerId)
        external
        view
        override
        returns (address[] memory)
    {
        return _wrappersOfPartner[partnerId];
    }

    function activeWrapperList() external view override returns (address[] memory) {
        return _activeWrapperList;
    }

    function activeWrapperCount() external view override returns (uint256) {
        return _activeWrapperList.length;
    }

    function activeWrapperAt(uint256 index) external view override returns (address) {
        return _activeWrapperList[index];
    }

    function canAcceptDeposits(address wrapper) external view override returns (bool) {
        return
            isRegisteredWrapper[wrapper] &&
            !isWrapperDepositsPaused[wrapper] &&
            !isRetiredWrapper[wrapper];
    }

    // ──────────────────────────────────────────────────────────────────
    // factory-only entry points
    // ──────────────────────────────────────────────────────────────────

    modifier onlyFactory() {
        if (msg.sender != factory) revert CallerNotFactory();
        _;
    }

    function registerPartner(
        bytes32 partnerId,
        address wrapper,
        address payoutTreasury_
    ) external override onlyFactory {
        if (partnerId == bytes32(0)) revert ZeroPartnerId();
        if (wrapper == address(0) || payoutTreasury_ == address(0)) revert ZeroAddress();
        if (currentWrapperOf[partnerId] != address(0)) revert PartnerAlreadyRegistered();
        if (partnerOfWrapper[wrapper] != bytes32(0) || isRegisteredWrapper[wrapper]) {
            revert WrapperAlreadyRegistered();
        }
        if (_activeWrapperList.length == MAX_ACTIVE_WRAPPERS) revert ActiveWrapperListFull();

        partnerOfWrapper[wrapper] = partnerId;
        currentWrapperOf[partnerId] = wrapper;
        _wrappersOfPartner[partnerId].push(wrapper);
        payoutTreasury[partnerId] = payoutTreasury_;
        isRegisteredWrapper[wrapper] = true;
        // isWrapperDepositsPaused[wrapper] = false (default)
        // isRetiredWrapper[wrapper] = false (default)

        _appendActive(wrapper);

        emit PartnerRegistered(partnerId, wrapper, payoutTreasury_);
    }

    function addReplacementWrapper(bytes32 partnerId, address newWrapper)
        external
        override
        onlyFactory
    {
        if (partnerId == bytes32(0)) revert ZeroPartnerId();
        if (newWrapper == address(0)) revert ZeroAddress();
        address oldCurrent = currentWrapperOf[partnerId];
        if (oldCurrent == address(0)) revert PartnerNotRegistered();
        if (partnerOfWrapper[newWrapper] != bytes32(0) || isRegisteredWrapper[newWrapper]) {
            revert WrapperAlreadyRegistered();
        }
        if (_activeWrapperList.length == MAX_ACTIVE_WRAPPERS) revert ActiveWrapperListFull();

        // Pause old current.
        isWrapperDepositsPaused[oldCurrent] = true;
        emit WrapperDepositsPaused(partnerId, oldCurrent);

        // Promote new wrapper.
        partnerOfWrapper[newWrapper] = partnerId;
        currentWrapperOf[partnerId] = newWrapper;
        _wrappersOfPartner[partnerId].push(newWrapper);
        isRegisteredWrapper[newWrapper] = true;

        _appendActive(newWrapper);

        emit WrapperReplaced(partnerId, oldCurrent, newWrapper);
    }

    // ──────────────────────────────────────────────────────────────────
    // admin-only
    // ──────────────────────────────────────────────────────────────────

    /// @notice F-6: propose a partner payout-treasury change. It does NOT take
    /// effect immediately — `applyPartnerTreasury` commits it after
    /// PARTNER_TREASURY_TIMELOCK, so the partner can `claimWrapper` what is
    /// already accrued to the old address before payouts move. Re-proposing
    /// overwrites the pending target and restarts the clock.
    function updatePartnerTreasury(bytes32 partnerId, address newTreasury)
        external
        override
        onlyRole(ADMIN_ROLE)
    {
        if (newTreasury == address(0)) revert ZeroAddress();
        if (currentWrapperOf[partnerId] == address(0)) revert PartnerNotRegistered();
        pendingPartnerTreasury[partnerId] = newTreasury;
        uint64 readyAt = uint64(block.timestamp + PARTNER_TREASURY_TIMELOCK);
        pendingPartnerTreasuryReadyAt[partnerId] = readyAt;
        emit PartnerTreasuryProposed(partnerId, newTreasury, readyAt);
    }

    /// @notice F-6: commit a previously proposed partner payout-treasury change
    /// once the timelock has elapsed.
    function applyPartnerTreasury(bytes32 partnerId) external onlyRole(ADMIN_ROLE) {
        address next = pendingPartnerTreasury[partnerId];
        if (next == address(0)) revert NoPendingPartnerTreasury();
        uint64 readyAt = pendingPartnerTreasuryReadyAt[partnerId];
        if (block.timestamp < readyAt) revert PartnerTreasuryTimelockNotElapsed(readyAt);
        address old = payoutTreasury[partnerId];
        payoutTreasury[partnerId] = next;
        pendingPartnerTreasury[partnerId] = address(0);
        pendingPartnerTreasuryReadyAt[partnerId] = 0;
        emit PartnerTreasuryUpdated(partnerId, old, next);
    }

    function pauseDepositsForWrapper(address wrapper) external override onlyRole(ADMIN_ROLE) {
        if (!isRegisteredWrapper[wrapper]) revert WrapperNotRegistered();
        if (isRetiredWrapper[wrapper]) revert WrapperRetiredAlready();
        if (isWrapperDepositsPaused[wrapper]) return;
        isWrapperDepositsPaused[wrapper] = true;
        emit WrapperDepositsPaused(partnerOfWrapper[wrapper], wrapper);
    }

    function unpauseDepositsForWrapper(address wrapper) external override onlyRole(ADMIN_ROLE) {
        if (!isRegisteredWrapper[wrapper]) revert WrapperNotRegistered();
        if (isRetiredWrapper[wrapper]) revert WrapperRetiredAlready();
        // Only the CURRENT wrapper of its partner may be unpaused. This
        // structurally prevents two simultaneous deposit-active wrappers
        // for the same partner.
        bytes32 pid = partnerOfWrapper[wrapper];
        if (currentWrapperOf[pid] != wrapper) revert CannotUnpauseLegacy();
        if (!isWrapperDepositsPaused[wrapper]) return;
        isWrapperDepositsPaused[wrapper] = false;
        emit WrapperDepositsUnpaused(pid, wrapper);
    }

    function retireWrapper(address wrapper) external override onlyRole(ADMIN_ROLE) {
        if (!isRegisteredWrapper[wrapper]) revert WrapperNotRegistered();
        if (isRetiredWrapper[wrapper]) revert WrapperRetiredAlready();
        bytes32 pid = partnerOfWrapper[wrapper];
        if (currentWrapperOf[pid] == wrapper) revert CannotRetireCurrent();
        if (IERC20(vault).balanceOf(wrapper) != 0) revert WrapperHasShares();

        isRetiredWrapper[wrapper] = true;
        _removeActive(wrapper);

        emit WrapperRetired(pid, wrapper);
    }

    // ──────────────────────────────────────────────────────────────────
    // internal: active-set bookkeeping
    // ──────────────────────────────────────────────────────────────────

    function _appendActive(address wrapper) internal {
        _activeWrapperList.push(wrapper);
        _activeIndexPlusOne[wrapper] = _activeWrapperList.length; // i+1
    }

    function _removeActive(address wrapper) internal {
        uint256 ip1 = _activeIndexPlusOne[wrapper];
        if (ip1 == 0) return;
        uint256 i = ip1 - 1;
        uint256 lastIdx = _activeWrapperList.length - 1;
        if (i != lastIdx) {
            address last = _activeWrapperList[lastIdx];
            _activeWrapperList[i] = last;
            _activeIndexPlusOne[last] = i + 1;
        }
        _activeWrapperList.pop();
        delete _activeIndexPlusOne[wrapper];
    }
}
