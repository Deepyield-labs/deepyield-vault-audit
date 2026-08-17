// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IDedicatedVenue, IDedicatedVenueV2} from "./interfaces/IDedicatedVenue.sol";
import {V3PositionValuer} from "./libraries/V3PositionValuer.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @dev Minimal PancakeV3 NonfungiblePositionManager surface used by the venue.
interface INfpmVenue {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function decreaseLiquidity(DecreaseLiquidityParams calldata p) external returns (uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata p) external returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external;
    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128);
    function ownerOf(uint256 tokenId) external view returns (address);
    function factory() external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev Minimal MasterchefV3 surface (staking of the LP NFT for CAKE rewards).
/// A STAKED NFT is owned by the masterchef, so LP trading fees must be collected via
/// `masterchef.collect` (NOT `nfpm.collect`, which reverts "Not approved" while staked).
interface IMasterchefVenue {
    function withdraw(uint256 tokenId, address to) external returns (uint256 reward);
    function harvest(uint256 tokenId, address to) external returns (uint256 reward);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata p) external returns (uint256 amount0, uint256 amount1);
    function CAKE() external view returns (address);
    /// @dev MasterChefV3 pool -> pid registry; 0 means the pool is not farmed here.
    function v3PoolAddressPid(address pool) external view returns (uint256 pid);
}

interface IV3PoolVenue {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint32, bool);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function factory() external view returns (address);
}

/// @dev Read-only identity surface of the V2 Main migration graph. It lets the
/// Venue authenticate current-Main governance and validate a halted replacement
/// Main without giving either Main a generic call-forwarding hook.
interface IVenueControllerIdentity {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function venue() external view returns (address);
    function activePositionId() external view returns (uint256);
    function vault() external view returns (address);
    function asset() external view returns (address);
    function pairedToken() external view returns (address);
    function rewardToken() external view returns (address);
    function mode() external view returns (uint8);
    function paused() external view returns (bool);
}

interface IVenueStrategyAdapterIdentity {
    function main() external view returns (address);
    function vault() external view returns (address);
    function asset() external view returns (address);
}

interface IVenueRootVaultIdentity {
    function strategy() external view returns (address);
    function pendingStrategy() external view returns (address);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title PancakeV3MasterchefVenue (PROTOTYPE — no funds / not deployed)
/// @notice `IDedicatedVenue` for Vault B: one tight V3 position on USDT/WBNB 0.01%,
/// optionally Masterchef-staked. Callable ONLY by the controller (`DedicatedVaultMain`);
/// every fungible managed-token outflow (asset, paired, reward/CAKE) goes to that
/// controller only, while protected active/written-off LP NFTs have no rescue outflow.
/// Governance may choose a recipient only for unrelated accidental ERC20/ERC721
/// deposits. Implements `ERC721Holder` so a Masterchef
/// `safeTransferFrom` unstake is received. `V3PositionValuer` is rounding-conservative
/// for a supplied price, but the raw Venue views use manipulable `slot0` and are
/// simulations — not oracle-safe NAV. MainV2 applies its own TWAP/Chainlink/spot policy.
///
/// @dev Prior hardening: ERC721 receiver, reward-token sweep,
/// slippage/deadline on open/close ✓, idle-paired returned to controller (Main realizes
/// it to USDT before redeem). `open()` is now TWO-SIDED (USDT+WBNB; Main pre-swaps the
/// WBNB leg) — the proven fork finding (test/VaultBLifecycleFork.t.sol) showed single-sided
/// in-range mint reverts. LIVE PancakeV3 in-range mint/stake/close correctness on real
/// funds remains NEEDS_FORK_PROOF (fundable/archive fork). Mocks prove control-flow +
/// security + NAV wiring + reward/ERC721 handling, NOT real mint behavior.
contract PancakeV3MasterchefVenue is IDedicatedVenueV2, ERC721Holder {
    using SafeERC20 for IERC20;

    bytes32 private constant ROOT_ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint48 public constant CONTROLLER_TIMELOCK = 2 days;
    uint256 public constant MAX_DEADLINE_DELAY = 600;
    uint160 public constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 public constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    /// @notice Current DedicatedVaultMain — the sole lifecycle caller and sole
    /// recipient for managed protocol assets. A replacement is activated in one
    /// atomic write after a two-day delay and only while both sides are idle.
    address public controller;
    address public pendingController;
    uint64 public pendingControllerReadyAt;

    IERC20 public immutable asset; // token0 = USDT
    IERC20 public immutable paired; // token1 = WBNB
    IERC20 public immutable rewardToken; // CAKE (address(0) if not farmed)
    uint24 public immutable fee; // 100 (0.01%)
    IV3PoolVenue public immutable pool;
    INfpmVenue public immutable nfpm;
    IMasterchefVenue public immutable masterchef; // address(0) => not farmed
    bool public immutable farmed;

    uint256 public activeTokenId; // 0 = none
    bool public activeStaked;

    /// @notice How far a (possibly interrupted) close has progressed. `close()`
    /// is a chain of six external calls; a revert on any one used to roll back the
    /// whole thing while `activeTokenId` stayed set, permanently blocking `open()`.
    /// This marker persists progress so the close can resume stage-by-stage from
    /// where it failed instead of restarting and hitting the same wall.
    enum CloseStage {
        NONE, // nothing started (fresh position) or reset after burn
        UNSTAKED, // masterchef unstake done (NFT at venue, activeStaked=false)
        DECREASED, // liquidity removed
        COLLECTED // tokens/fees collected; only burn remains
    }

    CloseStage public closeStage;

    /// @notice Last position deliberately written off because its close could not
    /// complete (e.g. masterchef reward path permanently broken, so even
    /// `withdraw()` reverts — verified: PancakeSwap MasterChefV3.withdraw settles
    /// pending CAKE before releasing the NFT). Recorded so a stranded NFT is never
    /// lost from accounting even though the venue is freed to open a new position.
    uint256 public strandedTokenId;
    bool public strandedWasStaked; // true = still owned by Masterchef pending service recovery
    /// @notice Every position ever written off remains protected if its NFT is
    /// later returned to the Venue. The single `strandedTokenId` slot is retained
    /// for compatibility, while this mapping prevents an older written-off LP
    /// from becoming generically rescuable after a later write-off overwrites it.
    mapping(uint256 => bool) public protectedStrandedTokenIds;
    mapping(uint256 => bool) public protectedStrandedWasStaked;

    struct ControllerIdentity {
        bool valid;
        bool isV2;
        bool stopped;
        address linkedVenue;
        uint256 activePosition;
        address adapter;
        address rootVault;
        address linkedAsset;
        address linkedPaired;
        address linkedReward;
        uint256 lifecycleState;
    }

    error OnlyController();
    error OnlyControllerGovernance();
    error PositionActive();
    error NoActivePosition();
    error RewardTokenRequired();
    error ForceUnstakeUnavailable();
    error ZeroAddress();
    error NotContract(address account);
    error PoolTokenMismatch(address expectedToken0, address expectedToken1, address actualToken0, address actualToken1);
    error PoolFeeMismatch(uint24 expected, uint24 actual);
    error FactoryMismatch(address expected, address actual);
    error MasterchefPoolUnknown(address pool);
    error MasterchefRewardMismatch(address expected, address actual);
    error CloseStageMismatch(uint8 expected, uint8 actual);
    error InvalidRecipient();
    error ManagedTokenProtected(address token);
    error PositionTokenProtected(uint256 tokenId);
    error InvalidControllerCandidate(address candidate);
    error NoPendingController();
    error ControllerTimelockNotElapsed(uint64 readyAt);
    error ControllerRotationUnsafe();
    error InvalidDeadline();
    error ZeroSlippageNotAllowed();
    error InvalidMinimum();
    error InvalidSqrtPrice();
    error MintedPositionMismatch(uint256 tokenId);
    error PositionCustodyMismatch(uint256 tokenId, address expectedOwner, address actualOwner);
    error ControllerRotationPending(address pendingController);
    error PositionCollectionIncomplete(uint8 failedMask);

    event CloseStageAdvanced(uint256 indexed tokenId, uint8 stage);
    event PositionClosed(uint256 indexed tokenId);
    event PositionStranded(uint256 indexed tokenId, bool wasStaked, address custody);
    event ERC20Rescued(address indexed token, address indexed recipient, uint256 amount);
    event ERC721Rescued(address indexed token, uint256 indexed tokenId, address indexed recipient);
    event StrandedPositionNFTReturnedToVenue(uint256 indexed tokenId);
    event ManagedTokensSwept(address indexed controller);
    event ControllerProposed(address indexed currentController, address indexed pendingController, uint64 readyAt);
    event ControllerProposalCanceled(address indexed pendingController);
    event ControllerUpdated(address indexed oldController, address indexed newController);
    event ManagedTokenTransferDeferred(address indexed token, address indexed controller, uint256 amount);
    event PositionCollectionRerouted(uint256 indexed tokenId, address indexed recipient);
    event PositionCollectionDeferred(uint256 indexed tokenId, uint8 failedMask);
    event HarvestDegraded(uint256 indexed tokenId, uint8 failedMask);
    event StrandedPositionRealized(uint256 indexed tokenId);

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    /// @dev The current Main cannot forward arbitrary calls, so an
    /// `onlyController` rescue/rotation API would be unreachable in the real
    /// graph. Governance is authenticated through the current Main's
    /// DEFAULT_ADMIN_ROLE or the linked root Vault's ADMIN_ROLE. The latter is
    /// the recovery authority when the old Main admin key is unavailable and is
    /// already trusted to replace the Vault strategy. Exact-controller access is
    /// retained for compatible future controllers, but lifecycle functions
    /// remain `onlyController`.
    modifier onlyControllerGovernance() {
        address current = controller;
        if (msg.sender != current && !_hasDefaultAdmin(current, msg.sender) && !_isCurrentRootAdmin(msg.sender)) {
            revert OnlyControllerGovernance();
        }
        _;
    }

    constructor(
        address controller_,
        IERC20 asset_,
        IERC20 paired_,
        uint24 fee_,
        IV3PoolVenue pool_,
        INfpmVenue nfpm_,
        IMasterchefVenue masterchef_,
        IERC20 rewardToken_
    ) {
        bool farmed_ = address(masterchef_) != address(0);
        // farmed venues MUST declare the reward token, else CAKE handling is silently skipped
        if (farmed_ && address(rewardToken_) == address(0)) revert RewardTokenRequired();

        // Non-zero required for every dependency. `controller_` is the Main, whose
        // address is CREATE-predicted and deployed AFTER this venue, so it has no
        // code yet here — check its address is set but NOT its code.
        if (
            controller_ == address(0) || address(asset_) == address(0) || address(paired_) == address(0)
                || address(pool_) == address(0) || address(nfpm_) == address(0)
        ) revert ZeroAddress();

        // The external integration contracts we actually call must be contracts.
        _requireContract(address(pool_));
        _requireContract(address(nfpm_));

        // token0/token1 order underpins the entire price math (asset == token0);
        // a swapped pool would silently value everything wrong instead of reverting.
        address t0 = pool_.token0();
        address t1 = pool_.token1();
        if (t0 != address(asset_) || t1 != address(paired_)) {
            revert PoolTokenMismatch(address(asset_), address(paired_), t0, t1);
        }
        uint24 poolFee = pool_.fee();
        if (poolFee != fee_) revert PoolFeeMismatch(fee_, poolFee);
        address poolFactory = pool_.factory();
        address nfpmFactory = nfpm_.factory();
        if (poolFactory == address(0) || nfpmFactory != poolFactory) {
            revert FactoryMismatch(poolFactory, nfpmFactory);
        }

        if (farmed_) {
            _requireContract(address(masterchef_));
            address masterchefReward = masterchef_.CAKE();
            if (masterchefReward != address(rewardToken_)) {
                revert MasterchefRewardMismatch(address(rewardToken_), masterchefReward);
            }
            // The masterchef must actually farm this pool, else staking is misdirected.
            if (masterchef_.v3PoolAddressPid(address(pool_)) == 0) revert MasterchefPoolUnknown(address(pool_));
        }

        controller = controller_;
        asset = asset_;
        paired = paired_;
        fee = fee_;
        pool = pool_;
        nfpm = nfpm_;
        masterchef = masterchef_;
        rewardToken = rewardToken_;
        farmed = farmed_;
    }

    function _requireContract(address account) private view {
        if (account.code.length == 0) revert NotContract(account);
    }

    function _hasRole(address account, bytes32 role, address candidate) private view returns (bool) {
        (bool ok, bytes memory result) =
            account.staticcall(abi.encodeWithSelector(IVenueControllerIdentity.hasRole.selector, role, candidate));
        return ok && result.length >= 32 && abi.decode(result, (bool));
    }

    function _hasDefaultAdmin(address account, address candidateAdmin) private view returns (bool) {
        return _hasRole(account, bytes32(0), candidateAdmin);
    }

    function _isCurrentRootAdmin(address candidateAdmin) private view returns (bool) {
        ControllerIdentity memory current = _controllerIdentity(controller);
        return current.valid && _hasRole(current.rootVault, ROOT_ADMIN_ROLE, candidateAdmin);
    }

    function _controllerIdentity(address candidate) private view returns (ControllerIdentity memory identity) {
        if (candidate.code.length == 0) return identity;
        (bool venueOk, bytes memory venueResult) =
            candidate.staticcall(abi.encodeWithSelector(IVenueControllerIdentity.venue.selector));
        (bool positionOk, bytes memory positionResult) =
            candidate.staticcall(abi.encodeWithSelector(IVenueControllerIdentity.activePositionId.selector));
        (bool adapterOk, bytes memory adapterResult) =
            candidate.staticcall(abi.encodeWithSelector(IVenueControllerIdentity.vault.selector));
        (bool assetOk, bytes memory assetResult) =
            candidate.staticcall(abi.encodeWithSelector(IVenueControllerIdentity.asset.selector));
        (bool pairedOk, bytes memory pairedResult) =
            candidate.staticcall(abi.encodeWithSelector(IVenueControllerIdentity.pairedToken.selector));
        (bool rewardOk, bytes memory rewardResult) =
            candidate.staticcall(abi.encodeWithSelector(IVenueControllerIdentity.rewardToken.selector));
        (bool modeOk, bytes memory modeResult) =
            candidate.staticcall(abi.encodeWithSelector(IVenueControllerIdentity.mode.selector));
        if (
            !venueOk || venueResult.length < 32 || !positionOk || positionResult.length < 32 || !adapterOk
                || adapterResult.length < 32 || !assetOk || assetResult.length < 32 || !pairedOk
                || pairedResult.length < 32 || !rewardOk || rewardResult.length < 32
        ) return identity;

        identity.linkedVenue = abi.decode(venueResult, (address));
        identity.activePosition = abi.decode(positionResult, (uint256));
        identity.adapter = abi.decode(adapterResult, (address));
        identity.linkedAsset = abi.decode(assetResult, (address));
        identity.linkedPaired = abi.decode(pairedResult, (address));
        identity.linkedReward = abi.decode(rewardResult, (address));
        if (modeOk && modeResult.length >= 32) {
            uint256 modeValue = abi.decode(modeResult, (uint256));
            if (modeValue > 2) return identity;
            identity.isV2 = true;
            identity.lifecycleState = modeValue;
            identity.stopped = modeValue == 0; // MainV2 must be HALTED, not merely outside OPERATING.
        } else {
            (bool pausedOk, bytes memory pausedResult) =
                candidate.staticcall(abi.encodeWithSelector(IVenueControllerIdentity.paused.selector));
            if (!pausedOk || pausedResult.length < 32) return identity;
            uint256 pausedValue = abi.decode(pausedResult, (uint256));
            if (pausedValue > 1) return identity;
            identity.stopped = pausedValue == 1;
        }
        if (identity.adapter.code.length == 0) return identity;

        (bool mainOk, bytes memory mainResult) =
            identity.adapter.staticcall(abi.encodeWithSelector(IVenueStrategyAdapterIdentity.main.selector));
        (bool rootOk, bytes memory rootResult) =
            identity.adapter.staticcall(abi.encodeWithSelector(IVenueStrategyAdapterIdentity.vault.selector));
        (bool adapterAssetOk, bytes memory adapterAssetResult) =
            identity.adapter.staticcall(abi.encodeWithSelector(IVenueStrategyAdapterIdentity.asset.selector));
        if (
            !mainOk || mainResult.length < 32 || abi.decode(mainResult, (address)) != candidate || !rootOk
                || rootResult.length < 32 || !adapterAssetOk || adapterAssetResult.length < 32
                || abi.decode(adapterAssetResult, (address)) != address(asset)
        ) return identity;
        identity.rootVault = abi.decode(rootResult, (address));
        if (identity.rootVault.code.length == 0) return identity;
        identity.valid = true;
    }

    function _requireControllerCandidate(address candidate, address governance) private view {
        ControllerIdentity memory next = _controllerIdentity(candidate);
        ControllerIdentity memory current = _controllerIdentity(controller);
        (bool currentStrategyOk, bytes memory currentStrategyResult) =
            current.rootVault.staticcall(abi.encodeWithSelector(IVenueRootVaultIdentity.strategy.selector));
        (bool pendingStrategyOk, bytes memory pendingStrategyResult) =
            current.rootVault.staticcall(abi.encodeWithSelector(IVenueRootVaultIdentity.pendingStrategy.selector));
        bool candidateStopped = next.isV2 ? next.lifecycleState == 0 : next.stopped;
        bool pendingGraphValid = !current.isV2
            || (pendingStrategyOk
                && pendingStrategyResult.length >= 32
                && abi.decode(pendingStrategyResult, (address)) == next.adapter);
        if (
            candidate == address(0) || candidate == controller || !next.valid || !current.valid
                || next.linkedVenue != address(this) || next.activePosition != 0 || next.rootVault != current.rootVault
                || next.linkedAsset != address(asset) || next.linkedPaired != address(paired)
                || next.linkedReward != address(rewardToken) || next.isV2 != current.isV2 || !candidateStopped
                || !currentStrategyOk || currentStrategyResult.length < 32
                || abi.decode(currentStrategyResult, (address)) != current.adapter || !pendingGraphValid
                || !_hasDefaultAdmin(candidate, governance) || !_hasRole(current.rootVault, ROOT_ADMIN_ROLE, governance)
        ) revert InvalidControllerCandidate(candidate);
    }

    /// @notice Announce a replacement Main. The pending Main has no lifecycle
    /// authority during the delay; the current Main remains the unique caller.
    function proposeController(address candidate) external onlyControllerGovernance {
        _requireControllerCandidate(candidate, msg.sender);
        pendingController = candidate;
        // forge-lint: disable-next-line(unsafe-typecast)
        pendingControllerReadyAt = uint64(block.timestamp + CONTROLLER_TIMELOCK);
        emit ControllerProposed(controller, candidate, pendingControllerReadyAt);
    }

    /// @notice Atomically replace the sole controller after the delay. Rotation
    /// is deliberately idle-only: neither current Main nor Venue may account an
    /// active position, because existing Mains have no safe position-adoption API.
    function applyController() external onlyControllerGovernance {
        address next = pendingController;
        if (next == address(0)) revert NoPendingController();
        uint64 readyAt = pendingControllerReadyAt;
        if (block.timestamp < readyAt) revert ControllerTimelockNotElapsed(readyAt);
        if (activeTokenId != 0 || closeStage != CloseStage.NONE) revert ControllerRotationUnsafe();
        ControllerIdentity memory current = _controllerIdentity(controller);
        if (!current.valid || current.activePosition != 0 || !current.stopped) {
            revert ControllerRotationUnsafe();
        }
        _requireControllerCandidate(next, msg.sender);

        address old = controller;
        controller = next;
        pendingController = address(0);
        pendingControllerReadyAt = 0;
        emit ControllerUpdated(old, next);
    }

    function cancelControllerProposal() external onlyControllerGovernance {
        if (!_isCurrentRootAdmin(msg.sender)) revert OnlyControllerGovernance();
        address canceled = pendingController;
        pendingController = address(0);
        pendingControllerReadyAt = 0;
        emit ControllerProposalCanceled(canceled);
    }

    /// @notice Recover an unrelated ERC20 accidentally sent to this Venue.
    /// Managed asset/paired/reward balances are never allowed to take an
    /// arbitrary-recipient path; only Main-mediated accounting paths may move
    /// those balances.
    function rescueERC20(IERC20 token, address recipient) external onlyControllerGovernance returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidRecipient();
        address tokenAddress = address(token);
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (tokenAddress == address(asset) || tokenAddress == address(paired) || tokenAddress == address(rewardToken)) {
            revert ManagedTokenProtected(tokenAddress);
        }
        amount = token.balanceOf(address(this));
        if (amount > 0) token.safeTransfer(recipient, amount);
        emit ERC20Rescued(tokenAddress, recipient, amount);
    }

    /// @notice Recover an unrelated NFT. The active LP and every historical
    /// written-off LP stay protected even if their NFPM NFT is later returned.
    function rescueERC721(IERC721 token, uint256 tokenId, address recipient) external onlyControllerGovernance {
        if (recipient == address(0)) revert InvalidRecipient();
        if (address(token) == address(0)) revert ZeroAddress();
        if (address(token) == address(nfpm) && (tokenId == activeTokenId || protectedStrandedTokenIds[tokenId])) {
            revert PositionTokenProtected(tokenId);
        }
        token.safeTransferFrom(address(this), recipient, tokenId);
        emit ERC721Rescued(address(token), tokenId, recipient);
    }

    /// @notice Controller-only custody step retained for interface compatibility.
    /// Canonical Main deliberately exposes no unaccounted forwarding entrypoint;
    /// its guardian uses the atomic realization path below instead.
    function recoverStrandedPositionFromMasterchef(uint256 tokenId) external onlyController {
        _recoverProtectedPositionFromMasterchef(tokenId);
    }

    /// @notice Controller-only compatibility surface. With canonical Main this
    /// can be reached only from code that wraps the call in balance snapshots;
    /// root governance can no longer bypass Main's inventory accounting.
    function sweepManagedTokensToController() external onlyController {
        _returnAllToController();
        emit ManagedTokensSwept(controller);
    }

    /// @notice Preview full-liquidity geometry for a protected historical NFT.
    /// Main owns the oracle policy; this is only the same raw V3 simulation as
    /// `previewCloseAmounts`, available because the NFT is not active anymore.
    function previewStrandedCloseAmounts(uint256 tokenId)
        external
        view
        returns (uint256 assetExpected, uint256 pairedExpected)
    {
        if (tokenId == activeTokenId || !protectedStrandedTokenIds[tokenId]) {
            revert PositionTokenProtected(tokenId);
        }
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = nfpm.positions(tokenId);
        (uint160 sqrtP,,,,,,) = pool.slot0();
        return V3PositionValuer.amounts(sqrtP, tl, tu, liq);
    }

    /// @notice Realize one protected NFT only to the current authenticated
    /// controller. This cannot be called by governance directly: Main snapshots
    /// and credits every returned fungible balance delta around this call.
    function realizeStrandedPosition(uint256 tokenId, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        onlyController
    {
        if (tokenId == activeTokenId || !protectedStrandedTokenIds[tokenId]) {
            revert PositionTokenProtected(tokenId);
        }
        _requireDeadline(deadline);

        if (protectedStrandedWasStaked[tokenId]) {
            // This entire call is wrapped by Main's balance snapshot, so either
            // direct-to-controller or Venue-fallback reward delivery is credited.
            _tryHarvestReward(tokenId);
            _recoverProtectedPositionFromMasterchef(tokenId);
        } else {
            _requireNfpmOwner(tokenId, address(this));
        }

        (,,,,,,, uint128 liq,,,,) = nfpm.positions(tokenId);
        if (liq > 0) {
            nfpm.decreaseLiquidity(
                INfpmVenue.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liq, amount0Min: amount0Min, amount1Min: amount1Min, deadline: deadline
                })
            );
        }
        // Strict controller delivery is intentional: this call runs inside
        // Main's balance snapshot, so a blocklisted recipient must roll back
        // rather than burn/eject value into an unaccounted Venue balance.
        nfpm.collect(
            INfpmVenue.CollectParams({
                tokenId: tokenId, recipient: controller, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        // MasterChef may pay reward to Venue during withdraw. Any such reward,
        // plus pre-existing managed balances, is transferred strictly inside
        // Main's accounting snapshot. Failure rolls back NFT realization.
        _returnAllToController();
        nfpm.burn(tokenId);
        delete protectedStrandedTokenIds[tokenId];
        delete protectedStrandedWasStaked[tokenId];
        if (tokenId == strandedTokenId) {
            strandedTokenId = 0;
            strandedWasStaked = false;
        }
        emit StrandedPositionRealized(tokenId);
    }

    function _recoverProtectedPositionFromMasterchef(uint256 tokenId) private {
        if (
            !farmed || tokenId == activeTokenId || !protectedStrandedTokenIds[tokenId]
                || !protectedStrandedWasStaked[tokenId]
        ) revert PositionTokenProtected(tokenId);
        masterchef.withdraw(tokenId, address(this));
        _requireNfpmOwner(tokenId, address(this));
        protectedStrandedWasStaked[tokenId] = false;
        if (tokenId == strandedTokenId) strandedWasStaked = false;
        emit StrandedPositionNFTReturnedToVenue(tokenId);
    }

    function _requireDeadline(uint256 deadline) private view {
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_DEADLINE_DELAY) {
            revert InvalidDeadline();
        }
    }

    /// @notice Two-sided mint from `assetAmount` USDT + `pairedAmount` WBNB pulled from the
    /// controller (the Main pre-swaps to size the WBNB leg), stake if farmed. Whatever the
    /// mint does not consume is returned to the controller (which realizes it to USDT).
    /// `amount0Min/amount1Min/deadline` bound the mint (no zero-min in normal use).
    /// The canonical farmed open/close and force-unstake recovery paths are
    /// exercised by `VaultBMainV2Fork.t.sol` on a BSC fork.
    function open(OpenArgs calldata a) external onlyController returns (uint256 tokenId) {
        if (activeTokenId != 0) revert PositionActive();
        if (pendingController != address(0)) revert ControllerRotationPending(pendingController);
        _requireDeadline(a.deadline);
        if (a.amount0Min == 0 || a.amount1Min == 0) revert ZeroSlippageNotAllowed();
        if (a.amount0Min > a.assetAmount || a.amount1Min > a.pairedAmount) revert InvalidMinimum();
        if (a.assetAmount > 0) asset.safeTransferFrom(controller, address(this), a.assetAmount);
        if (a.pairedAmount > 0) paired.safeTransferFrom(controller, address(this), a.pairedAmount);
        asset.forceApprove(address(nfpm), a.assetAmount);
        paired.forceApprove(address(nfpm), a.pairedAmount);
        (tokenId,,,) = nfpm.mint(
            INfpmVenue.MintParams({
                token0: address(asset),
                token1: address(paired),
                fee: fee,
                tickLower: a.tickLower,
                tickUpper: a.tickUpper,
                amount0Desired: a.assetAmount,
                amount1Desired: a.pairedAmount,
                amount0Min: a.amount0Min,
                amount1Min: a.amount1Min,
                recipient: address(this),
                deadline: a.deadline
            })
        );
        asset.forceApprove(address(nfpm), 0);
        paired.forceApprove(address(nfpm), 0);
        if (tokenId == 0) revert MintedPositionMismatch(tokenId);
        (
            ,,
            address mintedToken0,
            address mintedToken1,
            uint24 mintedFee,
            int24 mintedTickLower,
            int24 mintedTickUpper,,,,,
        ) = nfpm.positions(tokenId);
        if (
            mintedToken0 != address(asset) || mintedToken1 != address(paired) || mintedFee != fee
                || mintedTickLower != a.tickLower || mintedTickUpper != a.tickUpper
                || nfpm.ownerOf(tokenId) != address(this)
        ) revert MintedPositionMismatch(tokenId);
        if (farmed) {
            nfpm.safeTransferFrom(address(this), address(masterchef), tokenId);
            _requireNfpmOwner(tokenId, address(masterchef));
            activeStaked = true;
        }
        activeTokenId = tokenId;
        _returnAllToController();
    }

    /// @notice Full-close in one call: unstake (+harvest), remove all liquidity
    /// (bounded), collect, burn, return ALL (asset/paired/reward) to controller.
    /// Resumable: it advances only the stages not yet done, so a call after a
    /// partial staged close (below) finishes the remainder rather than replaying —
    /// and a fresh call from `NONE` behaves exactly as the original full close.
    function close(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        onlyController
    {
        _requireActive(positionId);
        if (uint8(closeStage) < uint8(CloseStage.DECREASED)) _requireDeadline(deadline);
        if (uint8(closeStage) < uint8(CloseStage.UNSTAKED)) _unstakeStage(positionId);
        if (uint8(closeStage) < uint8(CloseStage.DECREASED)) {
            _decreaseStage(positionId, amount0Min, amount1Min, deadline);
        }
        if (uint8(closeStage) < uint8(CloseStage.COLLECTED)) {
            uint8 failedMask = _collectStage(positionId);
            // A full close is atomic from Main's perspective. If either token leg
            // could not be collected, revert the whole call so Main cannot clear
            // its position while Venue remains partially closed. The staged API
            // below intentionally persists successful legs for later recovery.
            if (failedMask != 0) revert PositionCollectionIncomplete(failedMask);
        }
        _burnStage(positionId);
    }

    /// @notice Resumable close, one stage per call, driven by the controller.
    /// Each stage commits its progress to storage in its own transaction, so a
    /// revert on a later stage never undoes an earlier one: a retry continues from
    /// the failed stage instead of restarting the whole chain. Ordering is enforced
    /// by `closeStage`; the stages are unstake → decrease → collect → burn.
    function closeUnstake(uint256 positionId) external onlyController {
        _requireActive(positionId);
        _requireStage(CloseStage.NONE);
        _unstakeStage(positionId);
    }

    function closeDecrease(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        onlyController
    {
        _requireActive(positionId);
        _requireStage(CloseStage.UNSTAKED);
        _requireDeadline(deadline);
        _decreaseStage(positionId, amount0Min, amount1Min, deadline);
    }

    function closeCollect(uint256 positionId) external onlyController {
        _requireActive(positionId);
        _requireStage(CloseStage.DECREASED);
        _collectStage(positionId);
    }

    function closeBurn(uint256 positionId) external onlyController {
        _requireActive(positionId);
        _requireStage(CloseStage.COLLECTED);
        _burnStage(positionId);
    }

    /// @notice Deliberately abandon a position whose close cannot complete, so one
    /// stuck NFT cannot block the venue from ever opening again. The NFT is NOT
    /// discarded: if it is already back at the Venue it stays here under
    /// protected-id tracking until an accounted realization. If it is still staked
    /// in a broken Masterchef (where `withdraw` reverts), it stays there until the
    /// narrow recovery path can withdraw it. Either way the id is retained in
    /// `strandedTokenId` and surfaced
    /// via `PositionStranded`, and the Venue is freed. Controller-only; the controller
    /// enforces the narrower guardian gate for this most dangerous primitive.
    function writeOffStrandedPosition() external onlyController returns (uint256 strandedId) {
        strandedId = activeTokenId;
        if (strandedId == 0) revert NoActivePosition();
        bool wasStaked = activeStaked;

        // A blocked managed token must not stop the write-off escape hatch or
        // recovery of the other legs. Anything that cannot reach this controller
        // remains at the Venue and can be retried (or swept after an idle rotation).
        _tryReturnAllToController();

        // Record before freeing the slot so the position never leaves accounting.
        strandedTokenId = strandedId;
        strandedWasStaked = wasStaked;
        protectedStrandedTokenIds[strandedId] = true;
        protectedStrandedWasStaked[strandedId] = wasStaked;

        address custody;
        if (wasStaked) {
            // NFT is owned by the (broken) masterchef and cannot be moved here;
            // leave it there, tracked, for later manual recovery.
            custody = address(masterchef);
        } else {
            // Keep the protected LP in Venue custody. Current Main V1/V2 cannot
            // adopt or realize an ERC721 position, so transferring it there would
            // only move the lock and would make a later Venue rotation useless.
            custody = address(this);
        }

        activeTokenId = 0;
        activeStaked = false;
        closeStage = CloseStage.NONE;
        emit PositionStranded(strandedId, wasStaked, custody);
    }

    function _requireActive(uint256 positionId) internal view {
        if (positionId == 0 || positionId != activeTokenId) revert NoActivePosition();
    }

    function _requireStage(CloseStage expected) internal view {
        if (closeStage != expected) revert CloseStageMismatch(uint8(expected), uint8(closeStage));
    }

    function _requireNfpmOwner(uint256 tokenId, address expectedOwner) private view {
        address actualOwner = nfpm.ownerOf(tokenId);
        if (actualOwner != expectedOwner) revert PositionCustodyMismatch(tokenId, expectedOwner, actualOwner);
    }

    function _unstakeStage(uint256 positionId) internal {
        if (activeStaked) {
            // Clear rewards to the controller first. Canonical MasterChef's
            // withdraw harvests again to its NFT recipient; after this call that
            // second amount is normally zero, so a reward-token block on Venue
            // does not prevent an otherwise healthy NFT exit.
            _tryHarvestReward(positionId);
            masterchef.withdraw(positionId, address(this)); // NFT back to venue (ERC721Holder receives)
            _requireNfpmOwner(positionId, address(this));
            activeStaked = false;
        }
        closeStage = CloseStage.UNSTAKED;
        emit CloseStageAdvanced(positionId, uint8(CloseStage.UNSTAKED));
    }

    function _decreaseStage(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) internal {
        (,,,,,,, uint128 liq,,,,) = nfpm.positions(positionId);
        if (liq > 0) {
            nfpm.decreaseLiquidity(
                INfpmVenue.DecreaseLiquidityParams({
                    tokenId: positionId,
                    liquidity: liq,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: deadline
                })
            );
        }
        closeStage = CloseStage.DECREASED;
        emit CloseStageAdvanced(positionId, uint8(CloseStage.DECREASED));
    }

    function _collectStage(uint256 positionId) internal returns (uint8 failedMask) {
        // Collect independently per token leg. A blocked Main must leave that
        // leg owed by the NFT rather than park it at Venue: final burn is strict
        // specifically so Main cannot clear its accounting around an
        // undelivered balance. The unaffected leg can still be collected and is
        // credited by Main's staged-recovery snapshot.
        bool assetCollected = _tryCollectNfpmLegToController(positionId, type(uint128).max, 0);
        bool pairedCollected = _tryCollectNfpmLegToController(positionId, 0, type(uint128).max);
        if (!assetCollected) failedMask |= 1;
        if (!pairedCollected) failedMask |= 2;

        if (failedMask == 0) {
            closeStage = CloseStage.COLLECTED;
            emit CloseStageAdvanced(positionId, uint8(CloseStage.COLLECTED));
        } else {
            // Stay DECREASED so closeCollect can retry only the still-owed leg;
            // an already-collected leg safely returns zero on the retry.
            emit PositionCollectionDeferred(positionId, failedMask);
        }
    }

    function _tryCollectNfpmLegToController(uint256 positionId, uint128 amount0Max, uint128 amount1Max)
        private
        returns (bool collected)
    {
        try nfpm.collect(
            INfpmVenue.CollectParams({
                tokenId: positionId, recipient: controller, amount0Max: amount0Max, amount1Max: amount1Max
            })
        ) returns (
            uint256, uint256
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _burnStage(uint256 positionId) internal {
        nfpm.burn(positionId);
        activeTokenId = 0;
        activeStaked = false;
        closeStage = CloseStage.NONE;
        _returnAllToController();
        emit PositionClosed(positionId);
    }

    /// @notice Collect fees (+ CAKE if farmed) to the controller. Returns asset collected.
    /// While farmed the NFT is STAKED (owned by the masterchef), so LP trading fees are
    /// collected via `masterchef.collect` — `nfpm.collect` would revert "Not approved".
    /// (Proven by the wired fork test; mocks couldn't catch the ownership gate.)
    function harvest(uint256 positionId) external onlyController returns (uint256 assetCollected) {
        if (positionId == 0 || positionId != activeTokenId) revert NoActivePosition();
        _requireStage(CloseStage.NONE);
        uint8 failedMask;
        bool assetHeldAtVenue;
        if (activeStaked) {
            if (!_tryHarvestReward(positionId)) failedMask |= 1;
            bool assetFeesCollected;
            bool pairedFeesCollected;
            (assetFeesCollected, assetCollected, assetHeldAtVenue) =
                _tryCollectMasterchefLeg(positionId, type(uint128).max, 0, asset);
            (pairedFeesCollected,,) = _tryCollectMasterchefLeg(positionId, 0, type(uint128).max, paired);
            if (!assetFeesCollected) failedMask |= 2;
            if (!pairedFeesCollected) failedMask |= 4;
        } else {
            bool assetFeesCollected;
            bool pairedFeesCollected;
            (assetFeesCollected, assetCollected, assetHeldAtVenue) =
                _tryCollectNfpmLeg(positionId, type(uint128).max, 0, asset);
            (pairedFeesCollected,,) = _tryCollectNfpmLeg(positionId, 0, type(uint128).max, paired);
            if (!assetFeesCollected) failedMask |= 2;
            if (!pairedFeesCollected) failedMask |= 4;
        }
        bool assetTransferred = _tryReturnAllToController();
        // Report only newly collected asset that actually reached Main. Existing
        // Venue/controller donations are excluded by the per-call baselines, and
        // a deferred issuer-blocked balance is not misreported as realized yield.
        if (assetHeldAtVenue && !assetTransferred) assetCollected = 0;
        if (failedMask != 0) emit HarvestDegraded(positionId, failedMask);
    }

    function _tryHarvestReward(uint256 positionId) private returns (bool) {
        try masterchef.harvest(positionId, controller) returns (uint256) {
            return true;
        } catch {
            try masterchef.harvest(positionId, address(this)) returns (uint256) {
                return true;
            } catch {
                return false;
            }
        }
    }

    function _tryCollectMasterchefLeg(uint256 positionId, uint128 amount0Max, uint128 amount1Max, IERC20 measuredToken)
        private
        returns (bool collected, uint256 measuredAmount, bool heldAtVenue)
    {
        uint256 beforeBalance = measuredToken.balanceOf(controller);
        try masterchef.collect(
            IMasterchefVenue.CollectParams({
                tokenId: positionId, recipient: controller, amount0Max: amount0Max, amount1Max: amount1Max
            })
        ) returns (
            uint256, uint256
        ) {
            return (true, measuredToken.balanceOf(controller) - beforeBalance, false);
        } catch {
            beforeBalance = measuredToken.balanceOf(address(this));
            try masterchef.collect(
                IMasterchefVenue.CollectParams({
                    tokenId: positionId, recipient: address(this), amount0Max: amount0Max, amount1Max: amount1Max
                })
            ) returns (
                uint256, uint256
            ) {
                emit PositionCollectionRerouted(positionId, address(this));
                return (true, measuredToken.balanceOf(address(this)) - beforeBalance, true);
            } catch {
                return (false, 0, false);
            }
        }
    }

    function _tryCollectNfpmLeg(uint256 positionId, uint128 amount0Max, uint128 amount1Max, IERC20 measuredToken)
        private
        returns (bool collected, uint256 measuredAmount, bool heldAtVenue)
    {
        uint256 beforeBalance = measuredToken.balanceOf(controller);
        try nfpm.collect(
            INfpmVenue.CollectParams({
                tokenId: positionId, recipient: controller, amount0Max: amount0Max, amount1Max: amount1Max
            })
        ) returns (
            uint256, uint256
        ) {
            return (true, measuredToken.balanceOf(controller) - beforeBalance, false);
        } catch {
            beforeBalance = measuredToken.balanceOf(address(this));
            try nfpm.collect(
                INfpmVenue.CollectParams({
                    tokenId: positionId, recipient: address(this), amount0Max: amount0Max, amount1Max: amount1Max
                })
            ) returns (
                uint256, uint256
            ) {
                emit PositionCollectionRerouted(positionId, address(this));
                return (true, measuredToken.balanceOf(address(this)) - beforeBalance, true);
            } catch {
                return (false, 0, false);
            }
        }
    }

    /// @notice EMERGENCY ONLY. Best-effort reward clearing followed by a forced
    /// Masterchef withdrawal when the regular close path cannot progress.
    /// Controller-only.
    /// @dev Reward failure is tolerated, but canonical MasterChef may repeat its
    /// reward-accounting path inside `withdraw`. If withdrawal also reverts, the
    /// position stays tracked and recovery must wait for Masterchef or use write-off.
    function forceUnstakeSkipHarvest(uint256 positionId) external onlyController {
        if (positionId == 0 || positionId != activeTokenId) revert NoActivePosition();
        if (!activeStaked) revert ForceUnstakeUnavailable();
        // Clear reward to controller first where possible; otherwise skip it.
        _tryHarvestReward(positionId);
        // try bare withdraw; if that also reverts, position truly stuck
        try masterchef.withdraw(positionId, address(this)) {
            _requireNfpmOwner(positionId, address(this));
            activeStaked = false;
        } catch {
            revert ForceUnstakeUnavailable();
        }
    }

    /// @notice Spot-marked USDT simulation for the one active position. This is
    /// NOT an oracle: raw `slot0` is manipulable. A value-bearing consumer must
    /// independently validate spot against its TWAP/oracle policy (MainV2 does).
    function positionValueAsset(uint256 positionId) external view returns (uint256) {
        _requireActive(positionId);
        (,,,,, int24 tl, int24 tu, uint128 liq,,, uint128 owed0, uint128 owed1) = nfpm.positions(positionId);
        (uint160 sqrtP,,,,,,) = pool.slot0();
        return V3PositionValuer.valueInAssetToken0(sqrtP, tl, tu, liq, owed0, owed1);
    }

    /// @notice Liquidity-only close geometry at the current spot pool price.
    /// This is an execution simulation, not an oracle; consumers must validate
    /// spot independently. These
    /// amounts correspond to `decreaseLiquidity` minima; uncollected fees are
    /// deliberately excluded because they are collected after the decrease.
    function previewCloseAmounts(uint256 positionId)
        external
        view
        returns (uint256 assetExpected, uint256 pairedExpected)
    {
        if (positionId == 0 || positionId != activeTokenId) revert NoActivePosition();
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = nfpm.positions(positionId);
        (uint160 sqrtP,,,,,,) = pool.slot0();
        return V3PositionValuer.amounts(sqrtP, tl, tu, liq);
    }

    /// @notice Expected amounts the NFPM will consume from the desired pair at
    /// current spot `slot0`. This is an execution simulation, not an oracle.
    /// MainV2 instead derives mint minima from independently validated TWAP
    /// geometry, not from the full desired balances (which can include leftovers).
    function previewOpenAmounts(uint256 assetDesired, uint256 pairedDesired, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 assetExpected, uint256 pairedExpected)
    {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, assetDesired, pairedDesired);
        return LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);
    }

    function poolAddress() external view returns (address) {
        return address(pool);
    }

    function previewCloseAmountsAtSqrtPrice(uint256 positionId, uint160 sqrtPriceX96)
        external
        view
        returns (uint256 assetExpected, uint256 pairedExpected)
    {
        _requireActive(positionId);
        // Canonical V3 sqrt-price domain. Deliberately do not compare this
        // caller-supplied simulation price with slot0: MainV2 supplies an
        // independently validated TWAP specifically to remain safe when spot
        // diverges. The caller remains responsible for authenticating its source.
        if (sqrtPriceX96 < MIN_SQRT_RATIO || sqrtPriceX96 >= MAX_SQRT_RATIO) revert InvalidSqrtPrice();
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = nfpm.positions(positionId);
        return V3PositionValuer.amounts(sqrtPriceX96, tl, tu, liq);
    }

    /// @dev Send any held asset / paired / reward to the controller ONLY. No arbitrary
    /// recipient, no swap here — the Main realizes paired/reward to USDT under bounded
    /// keeper/guardian control (vault-only egress everywhere).
    function _returnAllToController() internal {
        uint256 a = asset.balanceOf(address(this));
        if (a > 0) asset.safeTransfer(controller, a);
        uint256 p = paired.balanceOf(address(this));
        if (p > 0) paired.safeTransfer(controller, p);
        if (address(rewardToken) != address(0)) {
            uint256 r = rewardToken.balanceOf(address(this));
            if (r > 0) rewardToken.safeTransfer(controller, r); // CAKE → controller only
        }
    }

    /// @dev Independent, non-reverting managed-token delivery for recovery and
    /// harvest paths. A blocked token stays at the Venue with an event while the
    /// other legs continue. `open` and final burn intentionally use the strict
    /// variant above, so accounting can never clear around undelivered proceeds.
    function _tryReturnAllToController() internal returns (bool assetTransferred) {
        assetTransferred = _tryReturnToken(asset);
        _tryReturnToken(paired);
        if (address(rewardToken) != address(0)) _tryReturnToken(rewardToken);
    }

    function _tryReturnToken(IERC20 token) private returns (bool) {
        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) return true;
        if (token.trySafeTransfer(controller, amount)) return true;
        emit ManagedTokenTransferDeferred(address(token), controller, amount);
        return false;
    }
}
