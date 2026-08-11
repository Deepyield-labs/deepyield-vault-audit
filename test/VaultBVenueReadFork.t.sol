// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @notice Fork proof for Vault B's on-chain NAV-read discovery path against a
/// REAL staked PancakeV3 position. Proves the inputs the venue NAV needs are all
/// readable on-chain for a live MasterchefV3-staked NFT (the highest-risk-to-
/// hand-wave part of R0's NAV design):
///   masterchef.balanceOf / tokenOfOwnerByIndex  → staked tokenId discovery
///   NFPM.positions(tokenId)                       → token0/1, fee, ticks, liquidity, tokensOwed
///   pool.slot0 + token ordering                   → price for valuation
///
/// Read-only; no funds, no deploy, no state change. Uses the bot's live Main
/// (0x7DAAD2) and its staked position purely as a real-world fixture to prove the
/// reads — Vault B itself is independent (own Main/adapter/vault).
///
/// NOT proven here (documented NEEDS in docs/specs/vault-b-real-venue-readproof.md):
/// the final amounts-from-(liquidity,ticks,sqrtPrice) computation needs the
/// audited Uniswap/Pancake V3 math libs (TickMath + LiquidityAmounts + FullMath),
/// which are NOT in this repo. Hand-rolling them would be unsafe → out of scope.
interface IMasterchefV3Read {
    function balanceOf(address) external view returns (uint256);
    function tokenOfOwnerByIndex(address, uint256) external view returns (uint256);
    function v3PoolAddressPid(address) external view returns (uint256);
}
interface INFPMRead {
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0, address token1, uint24 fee,
        int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    );
}
interface IPoolRead {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint32, bool);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

contract VaultBVenueReadForkTest is Test {
    address constant LIVE_MAIN = 0x7DAAD20615F8870Bbd22C2fFbe9e07aB59073Fb3; // bot's live Main on 0.01% pool
    address constant POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;       // USDT/WBNB 0.01%
    address constant NFPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address constant MASTERCHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    bool forkAvailable;

    function setUp() public {
        try this._fork() {} catch { forkAvailable = false; emit log("VaultBVenueReadFork: no BSC fork - skip"); return; }
        forkAvailable = MASTERCHEF.code.length > 0 && NFPM.code.length > 0 && POOL.code.length > 0;
    }
    function _fork() external {
        require(msg.sender == address(this), "internal");
        string memory rpc = vm.envOr("BSC_FORK_RPC", vm.rpcUrl("bsc"));
        uint256 pin = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc); else vm.createSelectFork(rpc, pin);
    }
    modifier whenFork() { if (!forkAvailable) { emit log("skip: no fork"); return; } _; }

    /// @notice Pool is farmed (Masterchef pid != 0) → staked NFTs live in Masterchef.
    function test_PoolIsFarmed() public whenFork {
        uint256 pid = IMasterchefV3Read(MASTERCHEF).v3PoolAddressPid(POOL);
        assertGt(pid, 0, "0.01% pool must be a Masterchef farm (NFT staked there)");
        emit log_named_uint("masterchef pid", pid);
    }

    /// @notice Staked tokenId discovery + full NFPM.positions read for a staked NFT.
    /// STRICT: when a staked NFT exists, all reads are asserted (no vacuous pass).
    /// When none exists (live Main idle / closed) this is explicitly SKIPPED via
    /// `vm.skip` — never a silent pass. A deterministic, non-vacuous proof of the
    /// same logic runs in `VaultBVenueReadLogic.t.sol` (mock-based, no fork).
    /// Reproducible live-pinned proof needs an ARCHIVE RPC (BSC_FORK_BLOCK) at a
    /// block where LIVE_MAIN had a stake — the free dataseed is non-archive
    /// ("missing trie node"), and token 6900340 is now burned. See readproof doc.
    function test_StakedPositionReadable() public whenFork {
        uint256 staked = IMasterchefV3Read(MASTERCHEF).balanceOf(LIVE_MAIN);
        if (staked == 0) {
            emit log("SKIP: LIVE_MAIN has no staked NFT at this head (closed). For a strict live proof, set BSC_FORK_RPC=<archive> + BSC_FORK_BLOCK=<block-with-stake>. Deterministic logic proof: VaultBVenueReadLogic.t.sol");
            vm.skip(true);
            return;
        }
        assertLe(staked, 1, "Vault B invariant: at most one active NFT (live Main may differ)");

        uint256 tokenId = IMasterchefV3Read(MASTERCHEF).tokenOfOwnerByIndex(LIVE_MAIN, 0);
        emit log_named_uint("discovered staked tokenId", tokenId);

        (, , address t0, address t1, uint24 fee, int24 tl, int24 tu, uint128 liq, , , uint128 owed0, uint128 owed1)
            = INFPMRead(NFPM).positions(tokenId);

        // the NAV inputs the venue needs are all readable while staked:
        assertEq(t0, USDT, "token0 == USDT");
        assertEq(t1, WBNB, "token1 == WBNB");
        assertEq(fee, 100, "fee tier 0.01%");
        assertTrue(tl < tu, "valid tick range");
        assertGt(uint256(liq), 0, "non-zero liquidity readable while staked");
        emit log_named_int("tickLower", tl);
        emit log_named_int("tickUpper", tu);
        emit log_named_uint("liquidity", uint256(liq));
        emit log_named_uint("tokensOwed0", uint256(owed0));
        emit log_named_uint("tokensOwed1", uint256(owed1));
        // range width in ticks (bot runs a tight directional range)
        emit log_named_int("range width (ticks)", tu - tl);
    }

    /// @notice slot0 + ordering readable → price input for valuation is available.
    function test_PoolPriceReadable() public whenFork {
        (uint160 sp, int24 tick, , , , , ) = IPoolRead(POOL).slot0();
        assertGt(uint256(sp), 0, "sqrtPriceX96 readable");
        assertEq(IPoolRead(POOL).token0(), USDT, "pool token0 USDT");
        assertEq(IPoolRead(POOL).token1(), WBNB, "pool token1 WBNB");
        assertEq(IPoolRead(POOL).fee(), 100, "pool fee 0.01%");
        emit log_named_uint("sqrtPriceX96", uint256(sp));
        emit log_named_int("current tick", tick);
    }
}
