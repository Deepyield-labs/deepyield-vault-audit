// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDedicatedVenue, IAssetQuoter, IPairedSwapper, IRewardSwapper, IPairedSwapIn} from "./interfaces/IDedicatedVenue.sol";

/// @title DedicatedVaultMain (PROTOTYPE — no funds, not deployed/wired)
/// @notice Holds ONE pool's assets + at most one active venue position, funded
/// ONLY by the vault adapter. Security model from
/// `docs/specs/vault-dedicated-main-contract-changes.md`:
///   - vault-ONLY egress: every token-out path sends to the immutable `vault`.
///     There is NO arbitrary-recipient transfer and NO `rescueTokens(.,.,to)`.
///   - role separation: ADMIN (Safe/Timelock) / KEEPER (open/close/harvest) /
///     GUARDIAN (pause/emergencyClose). None of them can move funds to a
///     non-vault address.
///   - full-close lifecycle; no participant ledger; no commingling.
contract DedicatedVaultMain is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    IERC20 public immutable asset;        // USDT
    IERC20 public immutable pairedToken;  // WBNB
    /// @dev The DedicatedVaultStrategyAdapter — the SOLE funder/withdrawer of this Main.
    /// (Naming: this `vault` is the ADAPTER, not the ERC-4626 vault. Prod rename →
    /// `adapterVault`. Part of the standalone Vault B set — see
    /// docs/specs/vault-b-standalone-architecture.md. Vault A / Beefy is untouched.)
    address public immutable vault;
    IDedicatedVenue public immutable venue;
    IAssetQuoter public immutable quoter;
    /// @dev bounded WBNB→USDT swapper (keeper/guardian-driven, minOut). Realizes
    /// idle paired so redeem is USDT-coherent. Sends only to this Main.
    IPairedSwapper public immutable swapper;
    /// @dev bounded USDT→WBNB swap-IN for two-sided open. Keeper supplies how much
    /// USDT to convert (`swapAssetIn`) sized off-chain to the pool ratio; on-chain we
    /// only enforce minOut/deadline. Output (WBNB) stays in this Main.
    IPairedSwapIn public immutable swapperIn;
    /// @dev reward token (CAKE) + bounded reward→USDT swapper. address(0) when the
    /// venue is not farmed. CAKE is NOT counted in NAV (excluded until converted).
    IERC20 public immutable rewardToken;
    IRewardSwapper public immutable rewardSwapper;
    /// @dev fixed (not caller-supplied) staleness window — see closeIfStale.
    uint256 public immutable staleThreshold;

    uint256 public activePositionId;       // 0 = no active position
    uint256 public lastKeeperAt;           // heartbeat for closeIfStale

    error NotVault();
    error PositionActive();
    error InsufficientIdle();
    error NoActivePosition();
    error NotStale();
    error ZeroAddress();
    error PairedIdleNeedsConversion();
    error ZeroSlippageNotAllowed();
    error RewardConfigMissing();
    error OpenNotTwoSided();
    error SwapInRequired();

    event Funded(uint256 amount);
    event WithdrawnToVault(uint256 amount);
    event SweptToVault(address indexed token, uint256 amount);
    event PositionOpened(uint256 indexed positionId, int24 tickLower, int24 tickUpper, uint256 assetIn);
    event PositionClosed(uint256 indexed positionId, string reason);
    event Harvested(uint256 indexed positionId, uint256 assetCollected);

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(
        IERC20 asset_,
        IERC20 pairedToken_,
        address vault_,
        IDedicatedVenue venue_,
        IAssetQuoter quoter_,
        IPairedSwapper swapper_,
        IPairedSwapIn swapperIn_,
        IERC20 rewardToken_,
        IRewardSwapper rewardSwapper_,
        uint256 staleThreshold_,
        address admin_,
        address keeper_,
        address guardian_
    ) {
        if (
            address(asset_) == address(0) || address(pairedToken_) == address(0) ||
            vault_ == address(0) || address(venue_) == address(0) || address(quoter_) == address(0) ||
            address(swapper_) == address(0) || address(swapperIn_) == address(0) ||
            admin_ == address(0) || keeper_ == address(0) || guardian_ == address(0)
        ) revert ZeroAddress();
        asset = asset_;
        pairedToken = pairedToken_;
        vault = vault_;
        venue = venue_;
        quoter = quoter_;
        swapper = swapper_;
        swapperIn = swapperIn_;
        rewardToken = rewardToken_;     // address(0) if not farmed (optional, no zero-check)
        rewardSwapper = rewardSwapper_;
        staleThreshold = staleThreshold_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(KEEPER_ROLE, keeper_);
        _grantRole(GUARDIAN_ROLE, guardian_);
    }

    // ───────────────────────── vault-only money path ─────────────────────────

    /// @notice Pull USDT from the vault adapter into idle. Vault-only.
    function fundFromVault(uint256 amount) external onlyVault nonReentrant {
        asset.safeTransferFrom(vault, address(this), amount);
        emit Funded(amount);
    }

    /// @notice Send idle USDT back to the vault adapter. Vault-only. Fails CLOSED
    /// when an active position would be needed to satisfy the amount.
    function withdrawToVault(uint256 amount) external onlyVault nonReentrant returns (uint256) {
        uint256 idle = asset.balanceOf(address(this));
        if (idle < amount) {
            // distinguish the blocking causes (fail CLOSED, never overstate):
            if (activePositionId != 0) revert PositionActive();
            // idle WBNB exists but isn't redeemable as USDT until converted →
            // signal the keeper to call convertIdlePairedToAsset first.
            if (pairedToken.balanceOf(address(this)) > 0) revert PairedIdleNeedsConversion();
            revert InsufficientIdle();
        }
        asset.safeTransfer(vault, amount);
        emit WithdrawnToVault(amount);
        return amount;
    }

    /// @notice Realize idle WBNB → USDT via the bounded swapper (minOut). Keeper/
    /// guardian only; output stays in this Main (the swapper sends to the caller).
    /// Closes the "NAV counts WBNB but withdraw only sends USDT" mismatch.
    function convertIdlePairedToAsset(uint256 minOut, uint256 deadline)
        external nonReentrant returns (uint256 assetOut)
    {
        if (!hasRole(KEEPER_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) revert NotVault();
        uint256 bal = pairedToken.balanceOf(address(this));
        if (bal == 0) return 0;
        pairedToken.forceApprove(address(swapper), bal);
        assetOut = swapper.swapPairedToAsset(bal, minOut, deadline); // USDT → this Main
        pairedToken.forceApprove(address(swapper), 0);
    }

    /// @notice Realize idle reward (CAKE) → USDT via the bounded reward swapper
    /// (minOut). Keeper/guardian only; output stays in this Main. CAKE is excluded
    /// from NAV until converted (so share price never includes un-realized CAKE).
    function convertIdleRewardToAsset(uint256 minOut, uint256 deadline)
        external nonReentrant returns (uint256 assetOut)
    {
        if (!hasRole(KEEPER_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) revert NotVault();
        if (address(rewardToken) == address(0) || address(rewardSwapper) == address(0)) revert RewardConfigMissing();
        uint256 bal = rewardToken.balanceOf(address(this));
        if (bal == 0) return 0;
        rewardToken.forceApprove(address(rewardSwapper), bal);
        assetOut = rewardSwapper.swapRewardToAsset(bal, minOut, deadline); // USDT → this Main
        rewardToken.forceApprove(address(rewardSwapper), 0);
    }

    /// @notice Sweep a stray token to the vault. Destination is HARDCODED to
    /// `vault` — there is no arbitrary-recipient variant. Keeper or guardian.
    function sweepToVault(address token) external nonReentrant {
        if (!hasRole(KEEPER_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert NotVault(); // reuse: caller not authorised
        }
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(vault, bal); // ALWAYS to vault
            emit SweptToVault(token, bal);
        }
    }

    // ───────────────────────── keeper lifecycle ─────────────────────────

    /// @notice Open a two-sided LP. The keeper sizes `swapAssetIn` (USDT to convert to
    /// WBNB) off-chain from the pool ratio; we pre-swap it via the bounded `swapperIn`
    /// (minOut/deadline enforced), then deposit ALL remaining idle USDT + idle WBNB into
    /// the venue. Single-sided open was removed — proven to revert in-range on the live
    /// pool. Mint mins must be slippage-bounded (zero-min reserved for emergency paths).
    /// @dev Two-sided open params. `deadline` bounds BOTH the pre-swap and the mint
    /// (single keeper tx). `swapAssetIn` is keeper-sized off-chain to the pool ratio.
    /// (Struct groups the 7 open inputs for call-site clarity; the two-sided open path
    /// requires `via_ir` — see foundry.toml.)
    struct OpenParams {
        int24 tickLower;
        int24 tickUpper;
        uint256 swapAssetIn;
        uint256 pairedMinOut;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Open a GENUINELY two-sided LP. Every normal open performs a FRESH bounded
    /// USDT→WBNB swap-in (`swapAssetIn > 0`, `pairedMinOut > 0`) in the same keeper tx —
    /// so the WBNB leg is always priced now, never relying on pre-existing/leftover/
    /// donated idle WBNB. Both mint mins must be > 0 so neither leg can be left near-unused
    /// by the mint. After the swap, BOTH legs must be funded (`OpenNotTwoSided` otherwise —
    /// e.g. if `swapAssetIn` consumed all USDT). Single-sided is proven to revert in-range.
    function openPosition(OpenParams calldata p)
        external onlyRole(KEEPER_ROLE) whenNotPaused nonReentrant
    {
        if (activePositionId != 0) revert PositionActive();
        // BOTH legs must be slippage-bounded — a zero on either leg would let the mint
        // consume ~none of that token (nominal "two-sided", actually single-sided).
        if (p.amount0Min == 0 || p.amount1Min == 0) revert ZeroSlippageNotAllowed();
        // every normal open must do a fresh, bounded swap-in (no relying on idle WBNB).
        if (p.swapAssetIn == 0) revert SwapInRequired();
        if (p.pairedMinOut == 0) revert ZeroSlippageNotAllowed();
        if (p.swapAssetIn > asset.balanceOf(address(this))) revert InsufficientIdle();

        // 1) bounded pre-swap USDT → WBNB (output lands in this Main)
        asset.forceApprove(address(swapperIn), p.swapAssetIn);
        swapperIn.swapAssetToPaired(p.swapAssetIn, p.pairedMinOut, p.deadline);
        asset.forceApprove(address(swapperIn), 0);

        // 2) require BOTH legs funded, then deposit all idle (USDT + WBNB) two-sided;
        // venue returns any leftover. Reject single-sided explicitly (don't rely on the
        // venue/NFPM to revert) — e.g. swapAssetIn == all idle USDT → no USDT leg.
        uint256 assetForMint = asset.balanceOf(address(this));
        uint256 pairedForMint = pairedToken.balanceOf(address(this));
        if (assetForMint == 0 || pairedForMint == 0) revert OpenNotTwoSided();

        asset.forceApprove(address(venue), assetForMint);
        pairedToken.forceApprove(address(venue), pairedForMint);
        uint256 id = venue.open(IDedicatedVenue.OpenArgs({
            assetAmount: assetForMint, pairedAmount: pairedForMint,
            tickLower: p.tickLower, tickUpper: p.tickUpper,
            amount0Min: p.amount0Min, amount1Min: p.amount1Min, deadline: p.deadline
        }));
        asset.forceApprove(address(venue), 0);
        pairedToken.forceApprove(address(venue), 0);

        activePositionId = id;
        lastKeeperAt = block.timestamp;
        emit PositionOpened(id, p.tickLower, p.tickUpper, assetForMint);
    }

    function closePosition(uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external onlyRole(KEEPER_ROLE) nonReentrant
    {
        // Both legs must be slippage-bounded — single-sided zero-min would
        // allow MEV sandwich on the unprotected leg even when position is
        // skewed. Zero-min only via emergencyClose / closeIfStale.
        if (amount0Min == 0 || amount1Min == 0) revert ZeroSlippageNotAllowed();
        _close("keeper", amount0Min, amount1Min, deadline);
        lastKeeperAt = block.timestamp;
    }

    /// @notice Production normal-close: full-close + realize ALL returned WBNB/CAKE into
    /// USDT atomically, so the vault ends redeem-ready in USDT (not USDT+WBNB+CAKE awaiting
    /// follow-up calls). Any bounded conversion failing its minOut reverts the WHOLE tx
    /// (position not left half-realized). Bounded throughout; zero-min reserved for emergency.
    function closePositionAndRealize(
        uint256 amount0Min, uint256 amount1Min, uint256 closeDeadline,
        uint256 pairedMinOut, uint256 rewardMinOut, uint256 swapDeadline
    ) external onlyRole(KEEPER_ROLE) nonReentrant {
        // Both close legs must be bounded (same rationale as closePosition).
        if (amount0Min == 0 || amount1Min == 0) revert ZeroSlippageNotAllowed();
        _close("keeper", amount0Min, amount1Min, closeDeadline);
        lastKeeperAt = block.timestamp;

        uint256 pBal = pairedToken.balanceOf(address(this));
        if (pBal > 0) {
            if (pairedMinOut == 0) revert ZeroSlippageNotAllowed();
            pairedToken.forceApprove(address(swapper), pBal);
            swapper.swapPairedToAsset(pBal, pairedMinOut, swapDeadline);
            pairedToken.forceApprove(address(swapper), 0);
        }
        if (address(rewardToken) != address(0)) {
            uint256 rBal = rewardToken.balanceOf(address(this));
            if (rBal > 0) {
                if (rewardMinOut == 0) revert ZeroSlippageNotAllowed();
                if (address(rewardSwapper) == address(0)) revert RewardConfigMissing();
                rewardToken.forceApprove(address(rewardSwapper), rBal);
                rewardSwapper.swapRewardToAsset(rBal, rewardMinOut, swapDeadline);
                rewardToken.forceApprove(address(rewardSwapper), 0);
            }
        }
        // final state: redeem-ready idle USDT; WBNB/CAKE == 0
    }

    function harvest() external onlyRole(KEEPER_ROLE) nonReentrant returns (uint256 collected) {
        if (activePositionId != 0) {
            collected = venue.harvest(activePositionId); // proceeds land in this Main only
            emit Harvested(activePositionId, collected);
        }
        lastKeeperAt = block.timestamp;
    }

    // ───────────────────────── guardian / stale ─────────────────────────

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency: close to idle (if any) and pause. Funds stay in Main →
    /// vault pulls via withdrawToVault. Never transfers to a third party.
    /// @dev Emergency semantics: closes with zero min-amounts (accepts any output)
    /// to guarantee an exit even under adverse price — explicitly unsafe-by-design,
    /// distinct from the slippage-bounded keeper `closePosition`.
    function emergencyClose() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        if (activePositionId != 0) _close("emergency", 0, 0, block.timestamp);
        _pause();
    }

    /// @notice Anti-hostage: if the keeper has been silent past the FIXED
    /// `staleThreshold`, anyone may close the position to idle. The threshold is
    /// NOT caller-supplied (a caller-supplied maxAge=0 would be a griefing/MEV
    /// backdoor — deliberate deviation from the spec's `closeIfStale(maxAge)`
    /// signature). Closes to idle only; no arbitrary transfer.
    function closeIfStale() external nonReentrant {
        if (activePositionId == 0) revert NoActivePosition();
        if (block.timestamp < lastKeeperAt + staleThreshold) revert NotStale();
        _close("stale", 0, 0, block.timestamp); // emergency-style: guarantee the exit
    }

    function _close(string memory reason, uint256 amount0Min, uint256 amount1Min, uint256 deadline) internal {
        uint256 id = activePositionId;
        if (id == 0) revert NoActivePosition();
        activePositionId = 0;            // effects before interaction (reentrancy-safe)
        venue.close(id, amount0Min, amount1Min, deadline); // returns asset(+paired+reward) to this Main
        emit PositionClosed(id, reason);
    }

    // ───────────────────────── NAV views (on-chain) ─────────────────────────

    function idleAsset() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function idlePairedQuoted() public view returns (uint256) {
        uint256 b = pairedToken.balanceOf(address(this));
        return b == 0 ? 0 : quoter.quotePairedToAsset(b);
    }

    function positionValue() public view returns (uint256) {
        return activePositionId == 0 ? 0 : venue.positionValueAsset(activePositionId);
    }

    /// @notice On-chain total assets in USDT (conservative). Drives the adapter's
    /// estimatedTotalAssets() → ERC-4626 share price. Never exceeds realizable.
    function totalAssetsUsdt() external view returns (uint256) {
        return idleAsset() + idlePairedQuoted() + positionValue();
    }

    function hasActivePosition() external view returns (bool) {
        return activePositionId != 0;
    }
}
