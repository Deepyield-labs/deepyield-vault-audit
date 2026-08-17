// SPDX-License-Identifier: MIT
pragma solidity =0.8.24 >=0.4.16 >=0.5.0 >=0.6.2 ^0.8.20 ^0.8.24;

// src/libraries/FullMath.sol

library FullMath {
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        uint256 prod0; // Least significant 256 bits of the product
        uint256 prod1; // Most significant 256 bits of the product
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 == 0) {
            require(denominator > 0);
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }

        require(denominator > prod1);

        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // The 512-bit path relies on wrapping (mod 2**256) arithmetic that is
        // canonical under pre-0.8 Solidity; under ^0.8 it must be `unchecked`, or
        // the intended overflows revert. The two require()s above stay outside as
        // real reverts (they must not be silenced).
        unchecked {
            uint256 twos = (~denominator + 1) & denominator;
            assembly {
                denominator := div(denominator, twos)
            }

            assembly {
                prod0 := div(prod0, twos)
            }
            assembly {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            result = prod0 * inv;
            return result;
        }
    }

    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            require(result < type(uint256).max);
            result++;
        }
    }
}

// lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol

// OpenZeppelin Contracts (last updated v5.4.0) (utils/introspection/IERC165.sol)

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol

// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC721/IERC721Receiver.sol)

/**
 * @title ERC-721 token receiver interface
 * @dev Interface for any contract that wants to support safeTransfers
 * from ERC-721 asset contracts.
 */
interface IERC721Receiver {
    /**
     * @dev Whenever an {IERC721} `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
     * by `operator` from `from`, this function is called.
     *
     * It must return its Solidity selector to confirm the token transfer.
     * If any other value is returned or the interface is not implemented by the recipient, the transfer will be
     * reverted.
     *
     * The selector can be obtained in Solidity with `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

// src/libraries/TickMath.sol

/// @title Math library for computing sqrt prices from ticks and vice versa
/// @notice Vendored from Uniswap V3 (BSD-2-Clause). Computes sqrt price for
///         ticks of size 1.0001, i.e. sqrt(1.0001^tick) * 2^96 as a Q64.96.
///         Supports prices between 2^-128 and 2^128.
///
///         Used here only for the `getSqrtRatioAtTick` direction, to convert
///         a TWAP arithmetic-mean-tick (derived from pool.observe()) into a
///         sqrtPriceX96 that the adapter's amount-conversion routine consumes
///         in place of the manipulable slot0 spot read.
library TickMath {
    /// @dev The minimum tick that may be passed to #getSqrtRatioAtTick.
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtRatioAtTick.
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @notice Calculates sqrt(1.0001^tick) * 2^96
    /// @dev Throws if |tick| > max tick
    /// @param tick The input tick for the above formula
    /// @return sqrtPriceX96 A Fixed point Q64.96 number representing the sqrt of the ratio of the two assets (token1/token0)
    /// at the given tick
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2     != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4     != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8     != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10    != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20    != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40    != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80    != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100   != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200   != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400   != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800   != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000  != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000  != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000  != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000  != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9)   >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604)    >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98)      >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2)           >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
        // we then downcast because we know the result always fits within 160 bits
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}

// lib/openzeppelin-contracts/contracts/token/ERC721/utils/ERC721Holder.sol

// OpenZeppelin Contracts (last updated v5.5.0) (token/ERC721/utils/ERC721Holder.sol)

/**
 * @dev Implementation of the {IERC721Receiver} interface.
 *
 * Accepts all token transfers.
 * Make sure the contract is able to use its token with {IERC721-safeTransferFrom}, {IERC721-approve} or
 * {IERC721-setApprovalForAll}.
 *
 * @custom:stateless
 */
abstract contract ERC721Holder is IERC721Receiver {
    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     *
     * Always returns `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(address, address, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// src/interfaces/IDedicatedVenue.sol

/// @notice Minimal venue abstraction for the dedicated-vault prototype. In
/// production this is implemented by a PancakeSwap-V3 + MasterchefV3 integration
/// (mint/stake/decrease/collect/burn). For the no-funds prototype a mock
/// implements it so the SECURITY MODEL (roles, vault-only egress, lifecycle,
/// NAV, stale-close) is provable deterministically.
///
/// Invariant the venue MUST honour: `open` pulls idle asset from the caller (the
/// Main) and `close`/`harvest` return ALL managed proceeds (asset, paired, AND
/// reward token) back to the Main. Managed protocol assets never reach a third
/// party; an implementation may separately rescue unrelated accidental tokens.
///
/// Slippage/deadline are explicit on open/close (no zero-min in normal paths);
/// emergency paths may pass 0 with documented emergency semantics.
interface IDedicatedVenue {
    /// @dev Two-sided open args. The Main pre-swaps USDT→WBNB and approves BOTH legs, then
    /// calls open(). The single-sided open was removed — a proven fork finding
    /// (test/VaultBLifecycleFork.t.sol) shows single-sided in-range mint reverts, so a
    /// single-arg open could not mint the intended in-range LP. (Struct groups the open
    /// inputs for call-site clarity; the two-sided open path requires `via_ir` — see
    /// foundry.toml.)
    struct OpenArgs {
        uint256 assetAmount;
        uint256 pairedAmount;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function open(OpenArgs calldata a) external returns (uint256 positionId);

    function close(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) external;

    /// @dev Collect fees/rewards for `positionId` to the caller (asset terms returned).
    function harvest(uint256 positionId) external returns (uint256 assetCollected);

    /// @dev Current-SPOT value simulation of the active `positionId` in asset
    /// units. This raw Venue view is not an oracle: value-bearing consumers must
    /// independently validate/anchor the pool price before relying on it.
    function positionValueAsset(uint256 positionId) external view returns (uint256);
}

/// @notice V2 extension used by MainV2 to derive close minima from the LP's
/// current execution geometry. Raw previews are spot simulations, not oracles;
/// MainV2 validates spot/TWAP/oracle coherence around value-bearing actions. A
/// leg may legitimately be zero when the position is fully out of range; that
/// fact comes from this on-chain preview, never the keeper.
interface IDedicatedVenueV2 is IDedicatedVenue {
    function controller() external view returns (address);

    function asset() external view returns (IERC20);

    function paired() external view returns (IERC20);

    function fee() external view returns (uint24);

    function poolAddress() external view returns (address);

    function forceUnstakeSkipHarvest(uint256 positionId) external;

    function previewOpenAmounts(uint256 assetDesired, uint256 pairedDesired, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 assetExpected, uint256 pairedExpected);

    function previewCloseAmounts(uint256 positionId)
        external
        view
        returns (uint256 assetExpected, uint256 pairedExpected);

    /// @dev Simulation at a caller-supplied, valid-domain V3 price. The Venue
    /// does not authenticate that price; the consumer must validate its source.
    function previewCloseAmountsAtSqrtPrice(uint256 positionId, uint160 sqrtPriceX96)
        external
        view
        returns (uint256 assetExpected, uint256 pairedExpected);
}

/// @notice Conservative paired(WBNB)→asset(USDT) quote (never above realizable).
interface IAssetQuoter {
    function quotePairedToAsset(uint256 pairedAmount) external view returns (uint256 assetAmount);
}

/// @notice Bounded paired(WBNB)→asset(USDT) swap. Pulls `pairedAmount` from the
/// caller, returns ≥ `minOut` asset TO the caller. Destination is always the
/// caller — no arbitrary recipient.
interface IPairedSwapper {
    function swapPairedToAsset(uint256 pairedAmount, uint256 minOut, uint256 deadline)
        external
        returns (uint256 assetOut);
}

/// @notice Bounded reward(CAKE)→asset(USDT) swap. Pulls `rewardAmount` from the
/// caller, returns ≥ `minOut` asset TO the caller. Caller-only destination.
interface IRewardSwapper {
    function swapRewardToAsset(uint256 rewardAmount, uint256 minOut, uint256 deadline)
        external
        returns (uint256 assetOut);
}

/// @notice Bounded asset(USDT)→paired(WBNB) swap-in for two-sided mint. Pulls
/// `assetAmount` from the caller, returns ≥ `minOut` paired TO the caller.
interface IPairedSwapIn {
    function swapAssetToPaired(uint256 assetAmount, uint256 minOut, uint256 deadline)
        external
        returns (uint256 pairedOut);
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol

// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/IERC165.sol)

// lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol

// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/IERC20.sol)

// lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol

// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC721/IERC721.sol)

/**
 * @dev Required interface of an ERC-721 compliant contract.
 */
interface IERC721 is IERC165 {
    /**
     * @dev Emitted when `tokenId` token is transferred from `from` to `to`.
     */
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables `approved` to manage the `tokenId` token.
     */
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables or disables (`approved`) `operator` to manage all of its assets.
     */
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /**
     * @dev Returns the number of tokens in ``owner``'s account.
     */
    function balanceOf(address owner) external view returns (uint256 balance);

    /**
     * @dev Returns the owner of the `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon
     *   a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC-721 protocol to prevent tokens from being forever locked.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must have been allowed to move this token by either {approve} or
     *   {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon
     *   a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /**
     * @dev Transfers `tokenId` token from `from` to `to`.
     *
     * WARNING: Note that the caller is responsible to confirm that the recipient is capable of receiving ERC-721
     * or else they may be permanently lost. Usage of {safeTransferFrom} prevents loss, though the caller must
     * understand this adds an external call which potentially creates a reentrancy vulnerability.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 tokenId) external;

    /**
     * @dev Gives permission to `to` to transfer `tokenId` token to another account.
     * The approval is cleared when the token is transferred.
     *
     * Only a single account can be approved at a time, so approving the zero address clears previous approvals.
     *
     * Requirements:
     *
     * - The caller must own the token or be an approved operator.
     * - `tokenId` must exist.
     *
     * Emits an {Approval} event.
     */
    function approve(address to, uint256 tokenId) external;

    /**
     * @dev Approve or remove `operator` as an operator for the caller.
     * Operators can call {transferFrom} or {safeTransferFrom} for any token owned by the caller.
     *
     * Requirements:
     *
     * - The `operator` cannot be the address zero.
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAll(address operator, bool approved) external;

    /**
     * @dev Returns the account approved for `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function getApproved(uint256 tokenId) external view returns (address operator);

    /**
     * @dev Returns if the `operator` is allowed to manage all of the assets of `owner`.
     *
     * See {setApprovalForAll}
     */
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

// src/libraries/LiquidityAmounts.sol

/// @title LiquidityAmounts — canonical Uniswap V3 (v3-periphery) liquidity↔amounts math.
/// @notice Verbatim canonical formulas (Uniswap/v3-periphery `LiquidityAmounts.sol`),
/// 0.8-compatible (no overflow tricks — uses audited `FullMath.mulDiv`). NOT hand-rolled
/// novel math: this is the standard, audited algorithm used across V3 integrations.
/// Q96 = 2**96. All results truncate down (FullMath.mulDiv) → conservative for NAV.
library LiquidityAmounts {
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    function getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        return _toUint128(FullMath.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return _toUint128(FullMath.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    /// @dev Maximum liquidity mintable from both desired token amounts at the
    /// current price. Canonical Uniswap V3 periphery formula.
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            return getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        }
        if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);
            return liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
        return getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
    }

    /// @dev amount0 for a given liquidity over [sqrtA, sqrtB].
    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return FullMath.mulDiv(uint256(liquidity) << 96, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96) / sqrtRatioAX96;
    }

    /// @dev amount1 for a given liquidity over [sqrtA, sqrtB].
    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }

    /// @dev (amount0, amount1) currently represented by `liquidity` at price `sqrtRatioX96`.
    /// Below range → all token0; in range → both; above range → all token1.
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        require(value <= type(uint128).max, "LA");
        // The explicit bound above makes this narrowing cast lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }
}

// src/libraries/V3PositionValuer.sol

/// @title V3PositionValuer — conservative on-chain USDT value of a Pancake/Uniswap V3 position.
/// @notice Composes audited primitives only:
///   - `TickMath.getSqrtRatioAtTick` (already in repo, used by the router adapter),
///   - canonical `LiquidityAmounts.getAmountsForLiquidity`,
///   - audited `FullMath.mulDiv`.
/// No novel/hand-rolled crypto math. Assumes asset == token0 (USDT) and paired == token1
/// (WBNB) — the live 0.01% pool ordering (token0=USDT, token1=WBNB), both 18 decimals.
/// All conversions truncate DOWN (FullMath.mulDiv) ⇒ conservative (never overstates NAV).
library V3PositionValuer {
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @dev (amount0, amount1) currently held by `liquidity` at `sqrtPriceX96`.
    function amounts(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal pure returns (uint256 amount0, uint256 amount1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
    }

    /// @dev Value `amount1` (token1/WBNB) in token0 (USDT) at `sqrtPriceX96`, floored.
    /// token0-per-token1 = (Q96 / sqrtP)^2, applied via two flooring mulDivs (conservative).
    function token1ToToken0(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (amount1 == 0) return 0;
        return FullMath.mulDiv(FullMath.mulDiv(amount1, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }

    /// @dev Conservative USDT (token0) value of a position: liquidity-implied amounts +
    /// fees owed, with the WBNB side floored into USDT at the current price.
    function valueInAssetToken0(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) internal pure returns (uint256 valueToken0) {
        (uint256 a0, uint256 a1) = amounts(sqrtPriceX96, tickLower, tickUpper, liquidity);
        uint256 total1 = a1 + tokensOwed1;
        valueToken0 = a0 + tokensOwed0 + token1ToToken0(total1, sqrtPriceX96);
    }
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol

// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/IERC1363.sol)

/**
 * @title IERC1363
 * @dev Interface of the ERC-1363 standard as defined in the https://eips.ethereum.org/EIPS/eip-1363[ERC-1363].
 *
 * Defines an extension interface for ERC-20 tokens that supports executing code on a recipient contract
 * after `transfer` or `transferFrom`, or code on a spender contract after `approve`, in a single transaction.
 */
interface IERC1363 is IERC20, IERC165 {
    /*
     * Note: the ERC-165 identifier for this interface is 0xb0202a11.
     * 0xb0202a11 ===
     *   bytes4(keccak256('transferAndCall(address,uint256)')) ^
     *   bytes4(keccak256('transferAndCall(address,uint256,bytes)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256,bytes)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256,bytes)'))
     */

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Additional data with no specified format, sent in call to `spender`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol

// OpenZeppelin Contracts (last updated v5.5.0) (token/ERC20/utils/SafeERC20.sol)

/**
 * @title SafeERC20
 * @dev Wrappers around ERC-20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    /**
     * @dev An operation with an ERC-20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        if (!_safeTransfer(token, to, value, true)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        if (!_safeTransferFrom(token, from, to, value, true)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Variant of {safeTransfer} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransfer(IERC20 token, address to, uint256 value) internal returns (bool) {
        return _safeTransfer(token, to, value, false);
    }

    /**
     * @dev Variant of {safeTransferFrom} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransferFrom(IERC20 token, address from, address to, uint256 value) internal returns (bool) {
        return _safeTransferFrom(token, from, to, value, false);
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     *
     * NOTE: If the token implements ERC-7674, this function will not modify any temporary allowance. This function
     * only sets the "standard" allowance. Any temporary allowance will remain active, in addition to the value being
     * set here.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        if (!_safeApprove(token, spender, value, false)) {
            if (!_safeApprove(token, spender, 0, true)) revert SafeERC20FailedOperation(address(token));
            if (!_safeApprove(token, spender, value, true)) revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferAndCall, with a fallback to the simple {ERC20} transfer if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that relies on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            safeTransfer(token, to, value);
        } else if (!token.transferAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferFromAndCall, with a fallback to the simple {ERC20} transferFrom if the target
     * has no code. This can be used to implement an {ERC721}-like safe transfer that relies on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferFromAndCallRelaxed(
        IERC1363 token,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        if (to.code.length == 0) {
            safeTransferFrom(token, from, to, value);
        } else if (!token.transferFromAndCall(from, to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} approveAndCall, with a fallback to the simple {ERC20} approve if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * NOTE: When the recipient address (`to`) has no code (i.e. is an EOA), this function behaves as {forceApprove}.
     * Oppositely, when the recipient address (`to`) has code, this function only attempts to call {ERC1363-approveAndCall}
     * once without retrying, and relies on the returned value to be true.
     *
     * Reverts if the returned value is other than `true`.
     */
    function approveAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            forceApprove(token, to, value);
        } else if (!token.approveAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity `token.transfer(to, value)` call, relaxing the requirement on the return value: the
     * return value is optional (but if data is returned, it must not be false).
     *
     * @param token The token targeted by the call.
     * @param to The recipient of the tokens
     * @param value The amount of token to transfer
     * @param bubble Behavior switch if the transfer call reverts: bubble the revert reason or return a false boolean.
     */
    function _safeTransfer(IERC20 token, address to, uint256 value, bool bubble) private returns (bool success) {
        bytes4 selector = IERC20.transfer.selector;

        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(0x00, selector)
            mstore(0x04, and(to, shr(96, not(0))))
            mstore(0x24, value)
            success := call(gas(), token, 0, 0x00, 0x44, 0x00, 0x20)
            // if call success and return is true, all is good.
            // otherwise (not success or return is not true), we need to perform further checks
            if iszero(and(success, eq(mload(0x00), 1))) {
                // if the call was a failure and bubble is enabled, bubble the error
                if and(iszero(success), bubble) {
                    returndatacopy(fmp, 0x00, returndatasize())
                    revert(fmp, returndatasize())
                }
                // if the return value is not true, then the call is only successful if:
                // - the token address has code
                // - the returndata is empty
                success := and(success, and(iszero(returndatasize()), gt(extcodesize(token), 0)))
            }
            mstore(0x40, fmp)
        }
    }

    /**
     * @dev Imitates a Solidity `token.transferFrom(from, to, value)` call, relaxing the requirement on the return
     * value: the return value is optional (but if data is returned, it must not be false).
     *
     * @param token The token targeted by the call.
     * @param from The sender of the tokens
     * @param to The recipient of the tokens
     * @param value The amount of token to transfer
     * @param bubble Behavior switch if the transfer call reverts: bubble the revert reason or return a false boolean.
     */
    function _safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value,
        bool bubble
    ) private returns (bool success) {
        bytes4 selector = IERC20.transferFrom.selector;

        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(0x00, selector)
            mstore(0x04, and(from, shr(96, not(0))))
            mstore(0x24, and(to, shr(96, not(0))))
            mstore(0x44, value)
            success := call(gas(), token, 0, 0x00, 0x64, 0x00, 0x20)
            // if call success and return is true, all is good.
            // otherwise (not success or return is not true), we need to perform further checks
            if iszero(and(success, eq(mload(0x00), 1))) {
                // if the call was a failure and bubble is enabled, bubble the error
                if and(iszero(success), bubble) {
                    returndatacopy(fmp, 0x00, returndatasize())
                    revert(fmp, returndatasize())
                }
                // if the return value is not true, then the call is only successful if:
                // - the token address has code
                // - the returndata is empty
                success := and(success, and(iszero(returndatasize()), gt(extcodesize(token), 0)))
            }
            mstore(0x40, fmp)
            mstore(0x60, 0)
        }
    }

    /**
     * @dev Imitates a Solidity `token.approve(spender, value)` call, relaxing the requirement on the return value:
     * the return value is optional (but if data is returned, it must not be false).
     *
     * @param token The token targeted by the call.
     * @param spender The spender of the tokens
     * @param value The amount of token to transfer
     * @param bubble Behavior switch if the transfer call reverts: bubble the revert reason or return a false boolean.
     */
    function _safeApprove(IERC20 token, address spender, uint256 value, bool bubble) private returns (bool success) {
        bytes4 selector = IERC20.approve.selector;

        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(0x00, selector)
            mstore(0x04, and(spender, shr(96, not(0))))
            mstore(0x24, value)
            success := call(gas(), token, 0, 0x00, 0x44, 0x00, 0x20)
            // if call success and return is true, all is good.
            // otherwise (not success or return is not true), we need to perform further checks
            if iszero(and(success, eq(mload(0x00), 1))) {
                // if the call was a failure and bubble is enabled, bubble the error
                if and(iszero(success), bubble) {
                    returndatacopy(fmp, 0x00, returndatasize())
                    revert(fmp, returndatasize())
                }
                // if the return value is not true, then the call is only successful if:
                // - the token address has code
                // - the returndata is empty
                success := and(success, and(iszero(returndatasize()), gt(extcodesize(token), 0)))
            }
            mstore(0x40, fmp)
        }
    }
}

// src/PancakeV3MasterchefVenue.sol

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
