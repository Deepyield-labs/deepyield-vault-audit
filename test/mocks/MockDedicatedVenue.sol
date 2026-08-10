// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDedicatedVenue, IAssetQuoter, IPairedSwapper, IRewardSwapper, IPairedSwapIn} from "../../src/interfaces/IDedicatedVenue.sol";

/// @dev Controllable stand-in for the PancakeV3+Masterchef venue. Honours the
/// invariant: open pulls idle asset from the caller (the Main); close/harvest
/// return all proceeds to the caller. Never sends to a third party.
contract MockDedicatedVenue is IDedicatedVenue {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    IERC20 public immutable paired;
    uint256 public nextId = 1;

    mapping(uint256 => uint256) public principal;     // asset pulled in
    mapping(uint256 => uint256) public valueOverride;  // 0 ⇒ value = principal
    mapping(uint256 => uint256) public realizeAsset;   // asset returned on close (default principal)
    mapping(uint256 => uint256) public realizePaired;  // paired returned on close (default 0)
    uint256 public harvestAmount;                      // asset minted to caller on harvest
    IERC20 public reward;                              // optional reward token (CAKE)
    uint256 public rewardOnClose;                      // reward returned to caller on close

    constructor(IERC20 asset_, IERC20 paired_) {
        asset = asset_;
        paired = paired_;
    }

    // ── test knobs ──
    function setValue(uint256 id, uint256 v) external { valueOverride[id] = v; }
    function setRealize(uint256 id, uint256 a, uint256 p) external { realizeAsset[id] = a; realizePaired[id] = p; }
    function setHarvest(uint256 a) external { harvestAmount = a; }
    function setReward(IERC20 r, uint256 a) external { reward = r; rewardOnClose = a; }

    uint256 public lastAssetIn;   // last USDT leg pulled on open (two-sided assertions)
    uint256 public lastPairedIn;  // last WBNB leg pulled on open
    uint256 public pairedValueRate = 1000e18; // asset per 1e18 paired (USDT-equiv NAV; test-consistent with swap-in)
    function setPairedValueRate(uint256 r) external { pairedValueRate = r; }

    function open(OpenArgs calldata a) external returns (uint256 id) {
        if (a.assetAmount > 0) asset.safeTransferFrom(msg.sender, address(this), a.assetAmount);
        if (a.pairedAmount > 0) paired.safeTransferFrom(msg.sender, address(this), a.pairedAmount);
        lastAssetIn = a.assetAmount;
        lastPairedIn = a.pairedAmount;
        id = nextId++;
        // NAV principal in USDT-equivalent: USDT leg + WBNB leg valued at pairedValueRate.
        // (Tests can still override via setValue / setRealize.)
        principal[id] = a.assetAmount + a.pairedAmount * pairedValueRate / 1e18;
    }

    function close(uint256 id, uint256, uint256, uint256) external {
        uint256 a = realizeAsset[id] == 0 ? principal[id] : realizeAsset[id];
        uint256 p = realizePaired[id];
        principal[id] = 0;
        if (a > 0) asset.safeTransfer(msg.sender, a);
        if (p > 0) paired.safeTransfer(msg.sender, p);
        if (address(reward) != address(0) && rewardOnClose > 0) reward.safeTransfer(msg.sender, rewardOnClose);
    }

    function harvest(uint256) external returns (uint256) {
        if (harvestAmount > 0) asset.safeTransfer(msg.sender, harvestAmount);
        return harvestAmount;
    }

    function positionValueAsset(uint256 id) external view returns (uint256) {
        return valueOverride[id] == 0 ? principal[id] : valueOverride[id];
    }
}

/// @dev Fixed-rate bounded WBNB→USDT swapper. Pulls paired from caller, returns
/// asset (≥ minOut) to the caller only. Must be funded with asset.
contract MockPairedSwapper is IPairedSwapper {
    using SafeERC20 for IERC20;
    IERC20 public immutable asset;
    IERC20 public immutable paired;
    uint256 public rate; // asset per 1e18 paired
    constructor(IERC20 asset_, IERC20 paired_, uint256 rate_) { asset = asset_; paired = paired_; rate = rate_; }
    function swapPairedToAsset(uint256 pairedAmount, uint256 minOut, uint256) external returns (uint256 out) {
        paired.safeTransferFrom(msg.sender, address(this), pairedAmount);
        out = pairedAmount * rate / 1e18;
        require(out >= minOut, "slippage");
        asset.safeTransfer(msg.sender, out); // caller only
    }
}

/// @dev Fixed-rate bounded reward(CAKE)→asset(USDT) swapper. Caller-only output.
contract MockRewardSwapper is IRewardSwapper {
    using SafeERC20 for IERC20;
    IERC20 public immutable asset;
    IERC20 public immutable reward;
    uint256 public rate; // asset per 1e18 reward
    constructor(IERC20 asset_, IERC20 reward_, uint256 rate_) { asset = asset_; reward = reward_; rate = rate_; }
    function swapRewardToAsset(uint256 rewardAmount, uint256 minOut, uint256) external returns (uint256 out) {
        reward.safeTransferFrom(msg.sender, address(this), rewardAmount);
        out = rewardAmount * rate / 1e18;
        require(out >= minOut, "slippage");
        asset.safeTransfer(msg.sender, out);
    }
}

/// @dev Fixed-rate bounded USDT→WBNB swap-in. Pulls asset from caller, returns paired
/// (≥ minOut) to the caller only. Must be funded with paired.
contract MockPairedSwapIn is IPairedSwapIn {
    using SafeERC20 for IERC20;
    IERC20 public immutable asset;
    IERC20 public immutable paired;
    uint256 public rate; // paired per 1e18 asset
    constructor(IERC20 asset_, IERC20 paired_, uint256 rate_) { asset = asset_; paired = paired_; rate = rate_; }
    function swapAssetToPaired(uint256 assetAmount, uint256 minOut, uint256) external returns (uint256 out) {
        asset.safeTransferFrom(msg.sender, address(this), assetAmount);
        out = assetAmount * rate / 1e18;
        require(out >= minOut, "slippage");
        paired.safeTransfer(msg.sender, out); // caller only
    }
}

/// @dev Fixed-rate conservative paired→asset quoter.
contract MockAssetQuoter is IAssetQuoter {
    uint256 public rate; // asset per 1e18 paired
    constructor(uint256 rate_) { rate = rate_; }
    function setRate(uint256 r) external { rate = r; }
    function quotePairedToAsset(uint256 p) external view returns (uint256) { return p * rate / 1e18; }
}
