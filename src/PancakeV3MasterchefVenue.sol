// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
}

interface IV3PoolVenue {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint32, bool);
}

/// @title PancakeV3MasterchefVenue (PROTOTYPE — no funds / not deployed)
/// @notice `IDedicatedVenue` for Vault B: one tight V3 position on USDT/WBNB 0.01%,
/// optionally Masterchef-staked. Callable ONLY by the controller (`DedicatedVaultMain`);
/// every token-out (asset, paired, AND reward/CAKE) goes to that controller only — no
/// arbitrary recipient. Implements `ERC721Holder` so a Masterchef `safeTransferFrom`
/// unstake is received. NAV via the audited `V3PositionValuer` (conservative).
///
/// @dev Hardening (Codex QA on 7dd0b4c): ERC721 receiver ✓, reward-token sweep ✓,
/// slippage/deadline on open/close ✓, idle-paired returned to controller (Main realizes
/// it to USDT before redeem). `open()` is now TWO-SIDED (USDT+WBNB; Main pre-swaps the
/// WBNB leg) — the proven fork finding (test/VaultBLifecycleFork.t.sol) showed single-sided
/// in-range mint reverts. LIVE PancakeV3 in-range mint/stake/close correctness on real
/// funds remains NEEDS_FORK_PROOF (fundable/archive fork). Mocks prove control-flow +
/// security + NAV wiring + reward/ERC721 handling, NOT real mint behavior.
contract PancakeV3MasterchefVenue is IDedicatedVenueV2, ERC721Holder {
    using SafeERC20 for IERC20;

    address public immutable controller; // the DedicatedVaultMain — sole caller + sole fund recipient
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

    error OnlyController();
    error PositionActive();
    error NoActivePosition();
    error RewardTokenRequired();
    error ForceUnstakeUnavailable();

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
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
        controller = controller_;
        asset = asset_;
        paired = paired_;
        fee = fee_;
        pool = pool_;
        nfpm = nfpm_;
        masterchef = masterchef_;
        rewardToken = rewardToken_;
        farmed = address(masterchef_) != address(0);
        // farmed venues MUST declare the reward token, else CAKE handling is silently skipped
        if (farmed && address(rewardToken_) == address(0)) revert RewardTokenRequired();
    }

    /// @notice Two-sided mint from `assetAmount` USDT + `pairedAmount` WBNB pulled from the
    /// controller (the Main pre-swaps to size the WBNB leg), stake if farmed. Whatever the
    /// mint does not consume is returned to the controller (which realizes it to USDT).
    /// `amount0Min/amount1Min/deadline` bound the mint (no zero-min in normal use).
    /// The canonical farmed open/close and force-unstake recovery paths are
    /// exercised by `VaultBMainV2Fork.t.sol` on a BSC fork.
    function open(OpenArgs calldata a) external onlyController returns (uint256 tokenId) {
        if (activeTokenId != 0) revert PositionActive();
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
        if (farmed) {
            nfpm.safeTransferFrom(address(this), address(masterchef), tokenId);
            activeStaked = true;
        }
        activeTokenId = tokenId;
        _returnAllToController();
    }

    /// @notice Full-close: unstake (+harvest), remove all liquidity (bounded), collect,
    /// burn, return ALL (asset/paired/reward) to controller.
    function close(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        onlyController
    {
        if (positionId == 0 || positionId != activeTokenId) revert NoActivePosition();
        if (activeStaked) {
            masterchef.harvest(positionId, address(this));
            masterchef.withdraw(positionId, address(this)); // NFT back to venue (ERC721Holder receives)
            activeStaked = false;
        }
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
        nfpm.collect(
            INfpmVenue.CollectParams({
                tokenId: positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        nfpm.burn(positionId);
        activeTokenId = 0;
        _returnAllToController();
    }

    /// @notice Collect fees (+ CAKE if farmed) to the controller. Returns asset collected.
    /// While farmed the NFT is STAKED (owned by the masterchef), so LP trading fees are
    /// collected via `masterchef.collect` — `nfpm.collect` would revert "Not approved".
    /// (Proven by the wired fork test; mocks couldn't catch the ownership gate.)
    function harvest(uint256 positionId) external onlyController returns (uint256 assetCollected) {
        if (positionId == 0 || positionId != activeTokenId) revert NoActivePosition();
        if (activeStaked) {
            masterchef.harvest(positionId, address(this)); // CAKE
            masterchef.collect(
                IMasterchefVenue.CollectParams({ // LP fees (staked NFT)
                    tokenId: positionId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        } else {
            nfpm.collect(
                INfpmVenue.CollectParams({
                    tokenId: positionId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        }
        uint256 before = asset.balanceOf(controller);
        _returnAllToController();
        assetCollected = asset.balanceOf(controller) - before;
    }

    /// @notice EMERGENCY ONLY. Forces unstake from masterchef WITHOUT harvest
    /// when masterchef is broken (paused, upgraded, etc) and the regular
    /// close() reverts. Skips CAKE rewards. Controller-only.
    /// @dev Calls masterchef.withdraw via try; if that also reverts, position
    /// is genuinely stuck and admin must wait for masterchef to recover.
    function forceUnstakeSkipHarvest(uint256 positionId) external onlyController {
        if (positionId == 0 || positionId != activeTokenId) revert NoActivePosition();
        if (!activeStaked) revert ForceUnstakeUnavailable();
        // try harvest the canonical way; on revert, skip CAKE
        try masterchef.harvest(positionId, address(this)) {} catch {}
        // try bare withdraw; if that also reverts, position truly stuck
        try masterchef.withdraw(positionId, address(this)) {
            activeStaked = false;
        } catch {
            revert ForceUnstakeUnavailable();
        }
    }

    /// @notice Conservative USDT value of the position via the audited valuer.
    function positionValueAsset(uint256 positionId) external view returns (uint256) {
        if (positionId == 0) return 0;
        (,,,,, int24 tl, int24 tu, uint128 liq,,, uint128 owed0, uint128 owed1) = nfpm.positions(positionId);
        (uint160 sqrtP,,,,,,) = pool.slot0();
        return V3PositionValuer.valueInAssetToken0(sqrtP, tl, tu, liq, owed0, owed1);
    }

    /// @notice Liquidity-only close geometry at the current pool price. These
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
    /// current slot0. MainV2 derives mint minima from this geometry, not from
    /// the full desired balances (which can include legitimate leftovers).
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
        if (positionId == 0 || positionId != activeTokenId) revert NoActivePosition();
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
}
