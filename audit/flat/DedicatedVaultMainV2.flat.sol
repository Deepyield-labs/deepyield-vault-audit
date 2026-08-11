// SPDX-License-Identifier: MIT
pragma solidity =0.8.24 >=0.4.16 >=0.5.0 >=0.6.2 >=0.8.4 ^0.8.20 ^0.8.24;

// lib/openzeppelin-contracts/contracts/utils/Context.sol

// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

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

// lib/openzeppelin-contracts/contracts/access/IAccessControl.sol

// OpenZeppelin Contracts (last updated v5.4.0) (access/IAccessControl.sol)

/**
 * @dev External interface of AccessControl declared to support ERC-165 detection.
 */
interface IAccessControl {
    /**
     * @dev The `account` is missing a role.
     */
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    /**
     * @dev The caller of a function is not the expected one.
     *
     * NOTE: Don't confuse with {AccessControlUnauthorizedAccount}.
     */
    error AccessControlBadConfirmation();

    /**
     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`
     *
     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite
     * {RoleAdminChanged} not being emitted to signal this.
     */
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    /**
     * @dev Emitted when `account` is granted `role`.
     *
     * `sender` is the account that originated the contract call. This account bears the admin role (for the granted role).
     * Expected in cases where the role was granted using the internal {AccessControl-_grantRole}.
     */
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Emitted when `account` is revoked `role`.
     *
     * `sender` is the account that originated the contract call:
     *   - if using `revokeRole`, it is the admin role bearer
     *   - if using `renounceRole`, it is the role bearer (i.e. `account`)
     */
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {AccessControl-_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     */
    function renounceRole(bytes32 role, address callerConfirmation) external;
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

// src/interfaces/IVaultBExecutionV2.sol

interface IChainlinkAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IVaultBPriceGuard {
    function minimumOut(address tokenIn, address tokenOut, uint256 amountIn, bool emergency)
        external
        view
        returns (uint256 minOut);

    function fairValue(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);

    function twapSqrtPriceX96() external view returns (uint160);
}

interface IVaultBExecutionAdapterV2 {
    function main() external view returns (address);

    function priceGuard() external view returns (IVaultBPriceGuard);

    function swapAssetToPaired(uint256 amountIn, uint256 keeperMinOut, uint256 deadline, bool emergency)
        external
        returns (uint256 amountOut);

    function swapPairedToAsset(uint256 amountIn, uint256 keeperMinOut, uint256 deadline, bool emergency)
        external
        returns (uint256 amountOut);
}

interface IVaultBRewardPriceGuard {
    function minimumOut(uint256 amountIn, bool emergency) external view returns (uint256 minOut);

    function fairValue(uint256 amountIn) external view returns (uint256 amountOut);
}

interface IVaultBRewardExecutionAdapterV2 {
    function main() external view returns (address);

    function priceGuard() external view returns (IVaultBRewardPriceGuard);

    function rewardToken() external view returns (address);

    function asset() external view returns (address);

    function swapRewardToAsset(uint256 amountIn, uint256 keeperMinOut, uint256 deadline, bool emergency)
        external
        returns (uint256 amountOut);
}

interface IPancakeV3SwapRouterWithDeadline {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/StorageSlot.sol)
// This file was procedurally generated from scripts/generate/templates/StorageSlot.js.

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC-1967 implementation slot:
 * ```solidity
 * contract ERC1967 {
 *     // Define the slot. Alternatively, use the SlotDerivation library to derive the slot.
 *     bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
 *
 *     function _getImplementation() internal view returns (address) {
 *         return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
 *     }
 *
 *     function _setImplementation(address newImplementation) internal {
 *         require(newImplementation.code.length > 0);
 *         StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {SlotDerivation}.
 */
library StorageSlot {
    struct AddressSlot {
        address value;
    }

    struct BooleanSlot {
        bool value;
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    struct Uint256Slot {
        uint256 value;
    }

    struct Int256Slot {
        int256 value;
    }

    struct StringSlot {
        string value;
    }

    struct BytesSlot {
        bytes value;
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Int256Slot` with member `value` located at `slot`.
     */
    function getInt256Slot(bytes32 slot) internal pure returns (Int256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `StringSlot` with member `value` located at `slot`.
     */
    function getStringSlot(bytes32 slot) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `StringSlot` representation of the string storage pointer `store`.
     */
    function getStringSlot(string storage store) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }

    /**
     * @dev Returns a `BytesSlot` with member `value` located at `slot`.
     */
    function getBytesSlot(bytes32 slot) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BytesSlot` representation of the bytes storage pointer `store`.
     */
    function getBytesSlot(bytes storage store) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }
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

// lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol

// OpenZeppelin Contracts (last updated v5.4.0) (utils/introspection/ERC165.sol)

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC-165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 */
abstract contract ERC165 is IERC165 {
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
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
/// Main) and `close`/`harvest` return ALL proceeds (asset, paired, AND reward
/// token) back to the Main. The venue never sends funds to any third party.
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

    /// @dev Conservative current value of `positionId` in asset (USDT) units —
    /// must not exceed what a close would realize (no phantom NAV).
    function positionValueAsset(uint256 positionId) external view returns (uint256);
}

/// @notice V2 extension used by MainV2 to derive close minima from the LP's
/// current geometry. A leg may legitimately be zero when the position is fully
/// out of range; that fact comes from this on-chain preview, never the keeper.
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

// lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol

// OpenZeppelin Contracts (last updated v5.5.0) (utils/ReentrancyGuard.sol)

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 *
 * IMPORTANT: Deprecated. This storage-based reentrancy guard will be removed and replaced
 * by the {ReentrancyGuardTransient} variant in v6.0.
 *
 * @custom:stateless
 */
abstract contract ReentrancyGuard {
    using StorageSlot for bytes32;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _reentrancyGuardStorageSlot().getUint256Slot().value = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    /**
     * @dev A `view` only version of {nonReentrant}. Use to block view functions
     * from being called, preventing reading from inconsistent contract state.
     *
     * CAUTION: This is a "view" modifier and does not change the reentrancy
     * status. Use it only on view functions. For payable or non-payable functions,
     * use the standard {nonReentrant} modifier instead.
     */
    modifier nonReentrantView() {
        _nonReentrantBeforeView();
        _;
    }

    function _nonReentrantBeforeView() private view {
        if (_reentrancyGuardEntered()) {
            revert ReentrancyGuardReentrantCall();
        }
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        _nonReentrantBeforeView();

        // Any calls to nonReentrant after this point will fail
        _reentrancyGuardStorageSlot().getUint256Slot().value = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _reentrancyGuardStorageSlot().getUint256Slot().value = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _reentrancyGuardStorageSlot().getUint256Slot().value == ENTERED;
    }

    function _reentrancyGuardStorageSlot() internal pure virtual returns (bytes32) {
        return REENTRANCY_GUARD_STORAGE;
    }
}

// lib/openzeppelin-contracts/contracts/access/AccessControl.sol

// OpenZeppelin Contracts (last updated v5.6.0) (access/AccessControl.sol)

/**
 * @dev Contract module that allows children to implement role-based access
 * control mechanisms. This is a lightweight version that doesn't allow enumerating role
 * members except through off-chain means by accessing the contract event logs. Some
 * applications may benefit from on-chain enumerability, for those cases see
 * {AccessControlEnumerable}.
 *
 * Roles are referred to by their `bytes32` identifier. These should be exposed
 * in the external API and be unique. The best way to achieve this is by
 * using `public constant` hash digests:
 *
 * ```solidity
 * bytes32 public constant MY_ROLE = keccak256("MY_ROLE");
 * ```
 *
 * Roles can be used to represent a set of permissions. To restrict access to a
 * function call, use {hasRole}:
 *
 * ```solidity
 * function foo() public {
 *     require(hasRole(MY_ROLE, msg.sender));
 *     ...
 * }
 * ```
 *
 * Roles can be granted and revoked dynamically via the {grantRole} and
 * {revokeRole} functions. Each role has an associated admin role, and only
 * accounts that have a role's admin role can call {grantRole} and {revokeRole}.
 *
 * By default, the admin role for all roles is `DEFAULT_ADMIN_ROLE`, which means
 * that only accounts with this role will be able to grant or revoke other
 * roles. More complex role relationships can be created by using
 * {_setRoleAdmin}.
 *
 * WARNING: The `DEFAULT_ADMIN_ROLE` is also its own admin: it has permission to
 * grant and revoke this role. Extra precautions should be taken to secure
 * accounts that have been granted it. We recommend using {AccessControlDefaultAdminRules}
 * to enforce additional security measures for this role.
 */
abstract contract AccessControl is Context, IAccessControl, ERC165 {
    struct RoleData {
        mapping(address account => bool) hasRole;
        bytes32 adminRole;
    }

    mapping(bytes32 role => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with an {AccessControlUnauthorizedAccount} error including the required role.
     */
    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view virtual returns (bool) {
        return _roles[role].hasRole[account];
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `_msgSender()`
     * is missing `role`. Overriding this function changes the behavior of the {onlyRole} modifier.
     */
    function _checkRole(bytes32 role) internal view virtual {
        _checkRole(role, _msgSender());
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `account`
     * is missing `role`.
     */
    function _checkRole(bytes32 role, address account) internal view virtual {
        if (!hasRole(role, account)) {
            revert AccessControlUnauthorizedAccount(account, role);
        }
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view virtual returns (bytes32) {
        return _roles[role].adminRole;
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleGranted} event.
     */
    function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleRevoked} event.
     */
    function revokeRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been revoked `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     *
     * May emit a {RoleRevoked} event.
     */
    function renounceRole(bytes32 role, address callerConfirmation) public virtual {
        if (callerConfirmation != _msgSender()) {
            revert AccessControlBadConfirmation();
        }

        _revokeRole(role, callerConfirmation);
    }

    /**
     * @dev Sets `adminRole` as ``role``'s admin role.
     *
     * Emits a {RoleAdminChanged} event.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        bytes32 previousAdminRole = getRoleAdmin(role);
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previousAdminRole, adminRole);
    }

    /**
     * @dev Attempts to grant `role` to `account` and returns a boolean indicating if `role` was granted.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleGranted} event.
     */
    function _grantRole(bytes32 role, address account) internal virtual returns (bool) {
        if (!hasRole(role, account)) {
            _roles[role].hasRole[account] = true;
            emit RoleGranted(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Attempts to revoke `role` from `account` and returns a boolean indicating if `role` was revoked.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleRevoked} event.
     */
    function _revokeRole(bytes32 role, address account) internal virtual returns (bool) {
        if (hasRole(role, account)) {
            _roles[role].hasRole[account] = false;
            emit RoleRevoked(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
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

// src/DedicatedVaultMainV2.sol

/// @dev Recovery surface added to the venue by B4-T1 (staged, resumable close and
/// stranded-position write-off). Declared here so Main can drive it without
/// changing the venue or its shared interface; `venue` is the sole caller the
/// venue trusts (`onlyController`).
interface IVenueRecovery {
    function closeUnstake(uint256 positionId) external;
    function closeDecrease(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) external;
    function closeCollect(uint256 positionId) external;
    function closeBurn(uint256 positionId) external;
    function writeOffStrandedPosition() external returns (uint256 strandedId);
}

/// @dev Minimal pool surface used to read the live spot price for the
/// spot-vs-oracle coherence gate. Reached via `venue.poolAddress()` so Main need
/// not be extended into the venue.
interface IV3PoolSpot {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint32, bool);
}

/// @notice Vault B MainV2 prototype. It is intentionally deployed halted and
/// direct-Pancake-only. Aggregator calldata is outside this contract's first
/// rollout; temporal slicing of paired/reward liquidation is supported (see
/// `liquidateAllWbnb` / `liquidateAllReward`).
contract DedicatedVaultMainV2 is AccessControl, ReentrancyGuard, ERC721Holder {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96
    uint24 internal constant POOL_FEE = 100;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant VAULT_B_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;

    IERC20 public constant asset = IERC20(USDT);
    IERC20 public constant pairedToken = IERC20(WBNB);

    enum Mode {
        HALTED,
        OPERATING,
        CLOSED_TO_INVENTORY
    }
    enum JobKind {
        NONE,
        OPEN,
        CLOSE_TO_INVENTORY,
        LIQUIDATE_WBNB,
        LIQUIDATE_REWARD
    }
    enum JobStatus {
        NONE,
        ACTIVE,
        COMPLETED
    }
    enum WithdrawalStatus {
        NONE,
        REQUESTED,
        CLAIMED,
        CANCELED
    }

    struct Job {
        JobKind kind;
        JobStatus status;
        uint64 createdAt;
        uint64 completedAt;
        uint32 chunks;
        uint256 cumulativeInput;
        uint256 cumulativeOutput;
        uint256 cumulativeNotionalAsset;
    }

    struct WithdrawalRequest {
        uint256 assets;
        WithdrawalStatus status;
    }

    struct OpenParams {
        bytes32 jobId;
        int24 tickLower;
        int24 tickUpper;
        uint256 assetBudget;
        uint256 swapAssetIn;
        uint256 keeperPairedMinOut;
        uint256 deadline;
    }

    address public immutable vault;
    IDedicatedVenueV2 public immutable venue;
    IVaultBExecutionAdapterV2 public immutable executionAdapter;
    IVaultBPriceGuard public immutable priceGuard;
    IVaultBRewardExecutionAdapterV2 public immutable rewardExecutionAdapter;
    IVaultBRewardPriceGuard public immutable rewardPriceGuard;
    IERC20 public immutable rewardToken;

    uint16 public immutable mintLossBps;
    uint16 public immutable normalCloseLossBps;
    uint16 public immutable emergencyCloseLossBps;
    uint256 public immutable hardMaxActiveAssets;
    uint256 public immutable hardMaxSwapPerJob;
    uint256 public immutable hardDailySwapLimit;

    uint256 public canaryOpenCap;
    uint256 public swapPerJobCap;
    uint256 public dailySwapLimit;

    /// @notice Max allowed deviation of the live pool spot price from the oracle
    /// (Chainlink) price before a close is rejected. This is the missing guard: a
    /// flash swap moves spot but not the oracle, so |spot - oracle| catches
    /// manipulation while an honestly lagging TWAP (spot ~= oracle) passes. Never
    /// zero, capped hard. The emergency threshold is wider for guardian recovery.
    uint16 public constant HARD_MAX_SPOT_ORACLE_DEVIATION_BPS = 2_000;
    uint16 public maxSpotOracleDeviationBps;
    uint16 public emergencySpotOracleDeviationBps;
    /// @notice Allowed width (in ticks) of an opened position. A too-narrow range
    /// is trivially pushed out of range by a small spot move; there is also a hard
    /// ceiling so admin can never widen it without bound. Defaults are set in the
    /// constructor so the deploy signature is unchanged.
    int24 public constant HARD_MAX_TICK_WIDTH = 200_000;
    int24 public minTickWidth;
    int24 public maxTickWidth;

    /// @notice Residual paired-token (WBNB, 18 decimals) balance tolerated by
    /// `isWithdrawalReady()` and by `sweepPairedDust()`. WBNB and USDT are both
    /// plain BEP-20: anyone can raise this contract's balance with an ordinary
    /// `transfer`, so gating readiness on an exact-zero balance lets an outsider
    /// freeze all withdrawals for the cost of a 1-wei transfer. Derived from a
    /// ~$0.05 notional target at ~$600/BNB (this repo's own fork-time quote for
    /// the same WBNB/USDT pool is ~$640/BNB, see docs/launch-runbook.md):
    /// 0.05 / 600 ~= 8.33e-5 BNB, rounded to a clean 1e14 wei (0.0001 BNB, ~$0.06
    /// at $600/BNB). That is far below the smallest amount this contract ever
    /// moves on purpose (canaryOpenCap / swapPerJobCap are hundreds to
    /// thousands of USDT, see script/DeployVaultBV2.config.example.json) and
    /// far above typical BSC transfer gas cost (~$0.05-$0.30), so it cannot be
    /// used to write off a meaningful amount either.
    uint256 public constant PAIRED_DUST_TOLERANCE = 1e14; // 0.0001 WBNB (~$0.06 @ $600/BNB)

    /// @notice Residual reward-token (CAKE, 18 decimals) balance tolerated the
    /// same way. Derived from the same ~$0.05 notional target at ~$1.50/CAKE
    /// (current market price ~$1.43 rounded up): 0.05 / 1.5 ~= 0.0333 CAKE,
    /// rounded to a clean 3e16 wei (0.03 CAKE, ~$0.045 @ $1.50/CAKE).
    uint256 public constant REWARD_DUST_TOLERANCE = 3e16; // 0.03 CAKE (~$0.045 @ $1.50/CAKE)

    Mode public mode = Mode.HALTED;
    uint256 public activePositionId;
    /// @notice Live count of DEFAULT_ADMIN_ROLE holders, so the last one cannot
    /// renounce/revoke themselves and brick the vault (enableOperations is the
    /// only path back to OPERATING and it is admin-only).
    uint256 private _adminCount;
    /// @notice Sum of request-time asset hints. Informational only: queued
    /// redeemers remain exposed to NAV until claim, so the claim amount is
    /// supplied by the immutable strategy adapter at settlement time.
    uint256 public queuedWithdrawalAssets;
    uint256 public queuedWithdrawalCount;
    bool public withdrawalCycleCommitted;
    bool public withdrawalCycleBatchCommitted;
    uint256 public withdrawalCycleExecutionLoss;

    mapping(bytes32 => Job) public jobs;
    mapping(bytes32 => mapping(uint32 => bool)) public usedChunks;
    mapping(uint64 => uint256) public dailySwapNotional;
    mapping(bytes32 => WithdrawalRequest) public withdrawals;

    error WrongChain(uint256 actual);
    error ZeroAddress();
    error InvalidConfiguration();
    error NotVault();
    error OpensDisabled(Mode mode);
    error AdapterNotBound();
    error InvalidExecutionAdapter();
    error InvalidVenueIdentity();
    error PositionActive();
    error NoActivePosition();
    error InventoryPresent(uint256 pairedBalance);
    error RewardInventoryPresent(uint256 rewardBalance);
    error InventoryRemaining(uint256 pairedBalance);
    error RewardInventoryRemaining(uint256 rewardBalance);
    error SwapBelowFloor(uint256 floor, uint256 amountOut);
    error InvalidAmount();
    error InvalidDeadline();
    error CapitalCapExceeded(uint256 requested, uint256 cap);
    error SwapCapExceeded(uint256 requested, uint256 cap);
    error DailySwapCapExceeded(uint256 requested, uint256 cap);
    error InvalidJobId();
    error JobKindMismatch(JobKind expected, JobKind actual);
    error JobAlreadyCompleted();
    error DuplicateChunk(uint32 chunkIndex);
    error InvalidPositionId();
    error OpenNotTwoSided();
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    error TwapOutsideTickRange();
    error MintValueBelowFloor(uint256 expectedMinimum, uint256 actualValue);
    error InvalidTickWidthBounds();
    error CloseValueBelowFloor(uint256 expectedMinimum, uint256 actualValue);
    error SpotDivergedFromOracle(uint256 spotUsdtPerWbnb, uint256 oracleUsdtPerWbnb);
    error InvalidSpotOracleDeviation();
    error HaltedKeeperPath();
    error LastAdminCannotBeRemoved();
    error WithdrawalExists();
    error WithdrawalUnknown();
    error WithdrawalNotReady();
    error OutstandingWithdrawals(uint256 requests);
    error WithdrawalBatchCommitted();
    error WithdrawalBatchEmpty();
    error DustAboveTolerance(uint256 amount, uint256 tolerance);

    event ModeChanged(Mode indexed oldMode, Mode indexed newMode);
    event OperationalCapsUpdated(uint256 canaryOpenCap, uint256 swapPerJobCap, uint256 dailySwapLimit);
    event SpotOracleDeviationUpdated(uint16 maxBps, uint16 emergencyBps);
    event TickWidthBoundsUpdated(int24 minTickWidth, int24 maxTickWidth);
    event Funded(uint256 assets);
    event PositionOpened(bytes32 indexed jobId, uint256 indexed positionId, uint256 assetBudget, uint256 pairedOut);
    event PositionClosedToInventory(
        bytes32 indexed jobId,
        uint256 indexed positionId,
        uint256 assetReceived,
        uint256 pairedReceived,
        uint256 amount0Min,
        uint256 amount1Min,
        bool emergency
    );
    event WbnbLiquidated(bytes32 indexed jobId, uint256 amountIn, uint256 amountOut, bool emergency);
    event RewardLiquidated(bytes32 indexed jobId, uint256 amountIn, uint256 amountOut, bool emergency);
    event PositionForceUnstaked(uint256 indexed positionId);
    event VenueCloseStageRecovered(uint256 indexed positionId, uint8 stage);
    event VenuePositionWrittenOff(uint256 indexed positionId, uint256 strandedTokenId, bool inventoryReturned);
    event WithdrawalRequested(bytes32 indexed requestId, uint256 assets);
    event WithdrawalCycleCommitted(uint256 requests);
    event WithdrawalExecutionLossRecorded(uint256 incrementalLoss, uint256 cumulativeLoss);
    event WithdrawalCycleCleared();
    event WithdrawalClaimed(bytes32 indexed requestId, uint256 assets);
    event WithdrawalCanceled(bytes32 indexed requestId);
    event IdleWithdrawnToVault(uint256 assets);
    event DustSwept(address indexed token, uint256 amount);

    constructor(
        address vault_,
        IDedicatedVenueV2 venue_,
        IVaultBExecutionAdapterV2 executionAdapter_,
        IVaultBPriceGuard priceGuard_,
        IVaultBRewardExecutionAdapterV2 rewardExecutionAdapter_,
        IVaultBRewardPriceGuard rewardPriceGuard_,
        IERC20 rewardToken_,
        uint16 mintLossBps_,
        uint16 normalCloseLossBps_,
        uint16 emergencyCloseLossBps_,
        uint256 hardMaxActiveAssets_,
        uint256 hardMaxSwapPerJob_,
        uint256 hardDailySwapLimit_,
        uint256 initialCanaryOpenCap_,
        uint256 initialSwapPerJobCap_,
        uint256 initialDailySwapLimit_,
        address admin_,
        address keeper_,
        address guardian_
    ) {
        if (block.chainid != 56) revert WrongChain(block.chainid);
        if (
            vault_ == address(0) || address(venue_) == address(0) || address(executionAdapter_) == address(0)
                || address(priceGuard_) == address(0) || address(rewardExecutionAdapter_) == address(0)
                || address(rewardPriceGuard_) == address(0) || admin_ == address(0) || keeper_ == address(0)
                || guardian_ == address(0)
        ) revert ZeroAddress();
        if (
            address(rewardToken_) != CAKE || mintLossBps_ == 0 || mintLossBps_ >= BPS || normalCloseLossBps_ == 0
                || normalCloseLossBps_ >= BPS || emergencyCloseLossBps_ < normalCloseLossBps_
                || emergencyCloseLossBps_ >= BPS || hardMaxActiveAssets_ == 0 || hardMaxSwapPerJob_ == 0
                || hardDailySwapLimit_ == 0 || initialCanaryOpenCap_ == 0
                || initialCanaryOpenCap_ > hardMaxActiveAssets_ || initialSwapPerJobCap_ == 0
                || initialSwapPerJobCap_ > hardMaxSwapPerJob_ || initialDailySwapLimit_ == 0
                || initialDailySwapLimit_ > hardDailySwapLimit_
        ) revert InvalidConfiguration();

        vault = vault_;
        venue = venue_;
        executionAdapter = executionAdapter_;
        priceGuard = priceGuard_;
        rewardExecutionAdapter = rewardExecutionAdapter_;
        rewardPriceGuard = rewardPriceGuard_;
        rewardToken = rewardToken_;
        mintLossBps = mintLossBps_;
        normalCloseLossBps = normalCloseLossBps_;
        emergencyCloseLossBps = emergencyCloseLossBps_;
        hardMaxActiveAssets = hardMaxActiveAssets_;
        hardMaxSwapPerJob = hardMaxSwapPerJob_;
        hardDailySwapLimit = hardDailySwapLimit_;
        canaryOpenCap = initialCanaryOpenCap_;
        swapPerJobCap = initialSwapPerJobCap_;
        dailySwapLimit = initialDailySwapLimit_;
        maxSpotOracleDeviationBps = 200; // 2%
        emergencySpotOracleDeviationBps = 1_000; // 10% for guardian recovery
        minTickWidth = 2;
        maxTickWidth = 20_000;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(KEEPER_ROLE, keeper_);
        _grantRole(GUARDIAN_ROLE, guardian_);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    function setOperationalCaps(uint256 openCap, uint256 perJobCap, uint256 perDayCap)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (
            openCap == 0 || openCap > hardMaxActiveAssets || perJobCap == 0 || perJobCap > hardMaxSwapPerJob
                || perDayCap == 0 || perDayCap > hardDailySwapLimit
        ) revert InvalidConfiguration();
        canaryOpenCap = openCap;
        swapPerJobCap = perJobCap;
        dailySwapLimit = perDayCap;
        emit OperationalCapsUpdated(openCap, perJobCap, perDayCap);
    }

    function setSpotOracleDeviationBps(uint16 maxBps, uint16 emergencyBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            maxBps == 0 || emergencyBps < maxBps || emergencyBps > HARD_MAX_SPOT_ORACLE_DEVIATION_BPS
        ) revert InvalidSpotOracleDeviation();
        maxSpotOracleDeviationBps = maxBps;
        emergencySpotOracleDeviationBps = emergencyBps;
        emit SpotOracleDeviationUpdated(maxBps, emergencyBps);
    }

    function setTickWidthBounds(int24 minWidth, int24 maxWidth) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (minWidth < 1 || maxWidth < minWidth || maxWidth > HARD_MAX_TICK_WIDTH) revert InvalidTickWidthBounds();
        minTickWidth = minWidth;
        maxTickWidth = maxWidth;
        emit TickWidthBoundsUpdated(minWidth, maxWidth);
    }

    function enableOperations() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            executionAdapter.main() != address(this) || rewardExecutionAdapter.main() != address(this)
                || venue.controller() != address(this)
        ) {
            revert AdapterNotBound();
        }
        if (address(executionAdapter.priceGuard()) != address(priceGuard)) revert InvalidExecutionAdapter();
        if (
            address(rewardExecutionAdapter.priceGuard()) != address(rewardPriceGuard)
                || rewardExecutionAdapter.rewardToken() != CAKE || rewardExecutionAdapter.asset() != USDT
        ) revert InvalidExecutionAdapter();
        if (
            address(venue.asset()) != USDT || address(venue.paired()) != WBNB || venue.fee() != POOL_FEE
                || venue.poolAddress() != VAULT_B_POOL
        ) revert InvalidVenueIdentity();
        if (activePositionId != 0) revert PositionActive();
        uint256 inventory = pairedToken.balanceOf(address(this));
        if (inventory != 0) revert InventoryPresent(inventory);
        if (address(rewardToken) != address(0)) {
            uint256 rewards = rewardToken.balanceOf(address(this));
            if (rewards != 0) revert RewardInventoryPresent(rewards);
        }
        if (queuedWithdrawalCount != 0) revert OutstandingWithdrawals(queuedWithdrawalCount);
        _setMode(Mode.OPERATING);
    }

    function halt() external onlyRole(GUARDIAN_ROLE) {
        _setMode(Mode.HALTED);
    }

    /// @dev Track admin count and forbid removing the last admin. renounceRole and
    /// revokeRole both route through _revokeRole, so this covers both.
    function _grantRole(bytes32 role, address account) internal override returns (bool granted) {
        granted = super._grantRole(role, account);
        if (granted && role == DEFAULT_ADMIN_ROLE) _adminCount++;
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool revoked) {
        if (role == DEFAULT_ADMIN_ROLE && _adminCount <= 1 && hasRole(DEFAULT_ADMIN_ROLE, account)) {
            revert LastAdminCannotBeRemoved();
        }
        revoked = super._revokeRole(role, account);
        if (revoked && role == DEFAULT_ADMIN_ROLE) _adminCount--;
    }

    function fundFromVault(uint256 amount) external onlyVault nonReentrant {
        if (mode != Mode.OPERATING) revert OpensDisabled(mode);
        if (amount == 0) revert InvalidAmount();
        // The capital ceiling limits EXPOSURE, so it must not be fed the
        // revenue-conservative NAV (minimumOut haircut + B1-T5 min(twap,spot)),
        // which understates exposure and lets more in the more the position skews
        // out of USDT. Value the exposure at fair mid, taking the HIGHER of the
        // TWAP/spot geometry so the ceiling cannot be gamed by under-valuation.
        uint256 postFundAssets = _fundingExposureUsdt() + amount;
        if (postFundAssets > hardMaxActiveAssets) {
            revert CapitalCapExceeded(postFundAssets, hardMaxActiveAssets);
        }
        asset.safeTransferFrom(vault, address(this), amount);
        emit Funded(amount);
    }

    function requestWithdrawal(bytes32 requestId, uint256 amount) external onlyVault nonReentrant {
        if (requestId == bytes32(0)) revert InvalidAmount();
        if (withdrawalCycleCommitted) revert WithdrawalBatchCommitted();
        if (withdrawals[requestId].status != WithdrawalStatus.NONE) revert WithdrawalExists();
        withdrawals[requestId] = WithdrawalRequest(amount, WithdrawalStatus.REQUESTED);
        queuedWithdrawalAssets += amount;
        queuedWithdrawalCount += 1;
        emit WithdrawalRequested(requestId, amount);
    }

    /// @notice Irreversibly commits the current request batch to an inventory
    /// close. Request admission and commit are separate so a dust request cannot
    /// force an immediate vault-wide LP unwind.
    function commitWithdrawalCycle() external onlyVault nonReentrant {
        if (queuedWithdrawalCount == 0) revert WithdrawalBatchEmpty();
        if (withdrawalCycleCommitted) revert WithdrawalBatchCommitted();
        withdrawalCycleCommitted = true;
        withdrawalCycleBatchCommitted = true;
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        emit WithdrawalCycleCommitted(queuedWithdrawalCount);
    }

    /// @notice Settle a queued withdrawal at its claim-time ERC-4626 NAV.
    /// `amount` may differ from the request-time hint because the queued shares
    /// remain exposed to gains/losses until claim. Egress remains hard-bound to
    /// the immutable adapter (`vault`).
    function claimWithdrawal(bytes32 requestId, uint256 amount) external onlyVault nonReentrant returns (uint256) {
        WithdrawalRequest storage request = withdrawals[requestId];
        if (request.status == WithdrawalStatus.NONE) revert WithdrawalUnknown();
        if (request.status != WithdrawalStatus.REQUESTED) revert WithdrawalNotReady();
        if (!isWithdrawalReady()) revert WithdrawalNotReady();
        if (asset.balanceOf(address(this)) < amount) revert WithdrawalNotReady();
        request.status = WithdrawalStatus.CLAIMED;
        queuedWithdrawalAssets -= request.assets;
        queuedWithdrawalCount -= 1;
        if (queuedWithdrawalCount == 0 && withdrawalCycleCommitted) {
            withdrawalCycleCommitted = false;
            withdrawalCycleBatchCommitted = false;
            withdrawalCycleExecutionLoss = 0;
            emit WithdrawalCycleCleared();
        }
        if (amount != 0) asset.safeTransfer(vault, amount);
        emit WithdrawalClaimed(requestId, amount);
        return amount;
    }

    function cancelWithdrawal(bytes32 requestId) external onlyVault nonReentrant {
        if (withdrawalCycleCommitted) revert WithdrawalBatchCommitted();
        WithdrawalRequest storage request = withdrawals[requestId];
        if (request.status == WithdrawalStatus.NONE) revert WithdrawalUnknown();
        if (request.status != WithdrawalStatus.REQUESTED) revert WithdrawalNotReady();
        request.status = WithdrawalStatus.CANCELED;
        queuedWithdrawalAssets -= request.assets;
        queuedWithdrawalCount -= 1;
        emit WithdrawalCanceled(requestId);
    }

    /// @notice Synchronous ERC-4626 liquidity path. It is available only when
    /// inventory is fully USDT and no older async request can be bypassed.
    function withdrawIdleToVault(uint256 amount) external onlyVault nonReentrant returns (uint256) {
        if (amount == 0) revert InvalidAmount();
        if (queuedWithdrawalCount != 0) revert OutstandingWithdrawals(queuedWithdrawalCount);
        if (!isWithdrawalReady() || asset.balanceOf(address(this)) < amount) revert WithdrawalNotReady();
        asset.safeTransfer(vault, amount);
        emit IdleWithdrawnToVault(amount);
        return amount;
    }

    function isWithdrawalReady() public view returns (bool) {
        if (activePositionId != 0 || pairedToken.balanceOf(address(this)) > PAIRED_DUST_TOLERANCE) return false;
        return address(rewardToken) == address(0) || rewardToken.balanceOf(address(this)) <= REWARD_DUST_TOLERANCE;
    }

    /// @notice Guardian-only sweep of a paired-token remainder at or below
    /// `PAIRED_DUST_TOLERANCE`. Recipient is hardcoded to `vault` — there is no
    /// address parameter, so this cannot be used to route funds anywhere else.
    /// Reverts above tolerance so it can never double as a limit-bypass path;
    /// a remainder above tolerance must go through `liquidateAllWbnb` instead.
    function sweepPairedDust() external onlyRole(GUARDIAN_ROLE) nonReentrant returns (uint256 amount) {
        amount = pairedToken.balanceOf(address(this));
        if (amount == 0) revert InvalidAmount();
        if (amount > PAIRED_DUST_TOLERANCE) revert DustAboveTolerance(amount, PAIRED_DUST_TOLERANCE);
        pairedToken.safeTransfer(vault, amount);
        emit DustSwept(address(pairedToken), amount);
    }

    /// @notice Guardian-only sweep of a reward-token remainder at or below
    /// `REWARD_DUST_TOLERANCE`. Same hardcoded-recipient and above-tolerance
    /// revert guarantees as `sweepPairedDust()`.
    function sweepRewardDust() external onlyRole(GUARDIAN_ROLE) nonReentrant returns (uint256 amount) {
        amount = rewardToken.balanceOf(address(this));
        if (amount == 0) revert InvalidAmount();
        if (amount > REWARD_DUST_TOLERANCE) revert DustAboveTolerance(amount, REWARD_DUST_TOLERANCE);
        rewardToken.safeTransfer(vault, amount);
        emit DustSwept(address(rewardToken), amount);
    }

    function openPosition(OpenParams calldata p)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (uint256 positionId)
    {
        Job storage job = _beginChunk(p.jobId, JobKind.OPEN, 0);
        if (mode != Mode.OPERATING) revert OpensDisabled(mode);
        if (executionAdapter.main() != address(this)) revert AdapterNotBound();
        if (activePositionId != 0) revert PositionActive();
        uint256 inventory = pairedToken.balanceOf(address(this));
        if (inventory != 0) revert InventoryPresent(inventory);
        if (address(rewardToken) != address(0)) {
            uint256 rewards = rewardToken.balanceOf(address(this));
            if (rewards != 0) revert RewardInventoryPresent(rewards);
        }
        if (
            p.assetBudget == 0 || p.swapAssetIn == 0 || p.swapAssetIn >= p.assetBudget
                || p.assetBudget > asset.balanceOf(address(this))
        ) revert InvalidAmount();
        if (p.assetBudget > canaryOpenCap) revert CapitalCapExceeded(p.assetBudget, canaryOpenCap);

        // Bound the tick range and require it to straddle the TWAP price (not just
        // the manipulable spot) before spending anything.
        uint160 twapSqrt = _validateOpenTicks(p.tickLower, p.tickUpper);

        _reserveSwapNotional(job, p.swapAssetIn, false);

        asset.forceApprove(address(executionAdapter), p.swapAssetIn);
        uint256 pairedOut = executionAdapter.swapAssetToPaired(p.swapAssetIn, p.keeperPairedMinOut, p.deadline, false);
        asset.forceApprove(address(executionAdapter), 0);

        uint256 assetForMint = p.assetBudget - p.swapAssetIn;
        // Expected mint geometry at the TWAP price, NOT the spot preview minted
        // against the same block's spot (which is tautological — it holds at any
        // price). A leg that rounds to zero at TWAP is not genuinely two-sided.
        (uint256 assetExpected, uint256 pairedExpected) =
            _expectedMintAmountsAtTwap(assetForMint, pairedOut, p.tickLower, p.tickUpper, twapSqrt);
        if (assetExpected == 0 || pairedExpected == 0) revert OpenNotTwoSided();
        uint256 amount0Min = _boundedLpMinimum(assetExpected, mintLossBps);
        uint256 amount1Min = _boundedLpMinimum(pairedExpected, mintLossBps);

        // Aggregate mint floor, one basis for both sides (priceGuard.fairValue):
        // what the position actually consumes must be worth at least the TWAP-fair
        // value of the intended deposit less the mint-loss budget. A spot pushed to
        // the range edge makes the mint consume a skewed, lower-value ratio and
        // trips this. Both legs valued the same way — no second basis to diverge.
        uint256 mintFloor = FullMath.mulDiv(_fairInventoryValue(assetExpected, pairedExpected), BPS - mintLossBps, BPS);
        uint256 assetBeforeMint = asset.balanceOf(address(this));
        uint256 pairedBeforeMint = pairedToken.balanceOf(address(this));

        asset.forceApprove(address(venue), assetForMint);
        pairedToken.forceApprove(address(venue), pairedOut);
        positionId = venue.open(
            IDedicatedVenue.OpenArgs({
                assetAmount: assetForMint,
                pairedAmount: pairedOut,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: p.deadline
            })
        );
        asset.forceApprove(address(venue), 0);
        pairedToken.forceApprove(address(venue), 0);
        if (positionId == 0) revert InvalidPositionId();

        // Net decrease of each token across the mint = what the position consumed
        // (the venue returns any leftover to this contract during open()).
        uint256 assetConsumed = assetBeforeMint - asset.balanceOf(address(this));
        uint256 pairedConsumed = pairedBeforeMint - pairedToken.balanceOf(address(this));
        uint256 deployedValue = _fairInventoryValue(assetConsumed, pairedConsumed);
        if (deployedValue < mintFloor) revert MintValueBelowFloor(mintFloor, deployedValue);

        activePositionId = positionId;
        job.cumulativeInput = p.swapAssetIn;
        job.cumulativeOutput = pairedOut;
        _completeJob(job);
        emit PositionOpened(p.jobId, positionId, p.assetBudget, pairedOut);
    }

    function closeToInventory(bytes32 jobId, uint256 deadline, bool emergency) external nonReentrant {
        if (emergency) _checkRole(GUARDIAN_ROLE, msg.sender);
        else _checkRole(KEEPER_ROLE, msg.sender);
        // A halt must stop routine keeper activity. The guardian emergency branch
        // and the B4-T2 recovery entrypoints stay open on purpose.
        if (!emergency && mode == Mode.HALTED) revert HaltedKeeperPath();
        Job storage job = _beginChunk(jobId, JobKind.CLOSE_TO_INVENTORY, 0);
        if (deadline < block.timestamp || deadline > block.timestamp + 600) revert InvalidDeadline();

        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();

        // Validate Chainlink/TWAP coherence even when LP geometry is 100% USDT
        // and later inventory valuation has no WBNB leg. For emergency closes
        // this also proves the finite, expiring guardian budget is active.
        priceGuard.minimumOut(WBNB, USDT, 1e18, emergency);

        // The missing guard: reject the close if the live pool spot price has been
        // pushed away from the oracle (a flash swap moves spot, not Chainlink). An
        // honestly lagging TWAP leaves spot ~= oracle and passes. Runs before any
        // minimum is computed.
        _requireSpotOracleCoherence(emergency);

        // Value the floor on ONE basis: the spot composition (what the close will
        // realize) valued at the oracle. Comparing this to the actual proceeds
        // (also spot composition, oracle-valued) measures execution slippage, not
        // the TWAP-vs-oracle drift the old TWAP-composition floor conflated it with.
        (uint256 spotAssetExpected, uint256 spotPairedExpected) = venue.previewCloseAmounts(positionId);

        uint16 lossBps = emergency ? emergencyCloseLossBps : normalCloseLossBps;
        uint256 amount0Min = _boundedLpMinimum(spotAssetExpected, lossBps);
        uint256 amount1Min = _boundedLpMinimum(spotPairedExpected, lossBps);
        uint256 expectedFairValue = _fairInventoryValue(spotAssetExpected, spotPairedExpected);
        uint256 expectedExecutionValue =
            emergency ? _inventoryValue(spotAssetExpected, spotPairedExpected, true) : expectedFairValue;
        uint256 aggregateFloor = FullMath.mulDiv(expectedExecutionValue, BPS - lossBps, BPS);

        uint256 assetBefore = asset.balanceOf(address(this));
        uint256 pairedBefore = pairedToken.balanceOf(address(this));
        _commitWithdrawalCycleIfQueued();
        _setMode(Mode.CLOSED_TO_INVENTORY);
        activePositionId = 0;
        venue.close(positionId, amount0Min, amount1Min, deadline);
        uint256 assetReceived = asset.balanceOf(address(this)) - assetBefore;
        uint256 pairedReceived = pairedToken.balanceOf(address(this)) - pairedBefore;
        uint256 actualFairValue = _fairInventoryValue(assetReceived, pairedReceived);
        uint256 actualExecutionValue =
            emergency ? _inventoryValue(assetReceived, pairedReceived, true) : actualFairValue;
        if (actualExecutionValue < aggregateFloor) {
            revert CloseValueBelowFloor(aggregateFloor, actualExecutionValue);
        }
        _recordWithdrawalExecutionLoss(expectedFairValue, actualFairValue);

        job.cumulativeInput = expectedFairValue;
        job.cumulativeOutput = actualFairValue;
        _completeJob(job);
        emit PositionClosedToInventory(
            jobId, positionId, assetReceived, pairedReceived, amount0Min, amount1Min, emergency
        );
    }

    /// @notice Guardian recovery when Masterchef harvest is broken. This only
    /// recovers the NFT to the venue; bounded LP close and WBNB liquidation
    /// remain separate subsequent operations.
    function forceUnstakeSkipHarvest() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        _commitWithdrawalCycleIfQueued();
        venue.forceUnstakeSkipHarvest(positionId);
        emit PositionForceUnstaked(positionId);
    }

    // ── Emergency venue-close recovery (B4-T2) ───────────────────────────────
    // Thin guardian-only pass-throughs that make the venue's staged close and
    // stranded-position write-off (B4-T1) reachable in production. They do NOT
    // gate on mode: a stuck position typically coincides with a halt, and an
    // emergency path that switches off exactly when it is needed is no path at
    // all. They recompute nothing — Main's only bookkeeping is `activePositionId`
    // and the mode, reconciled explicitly where the position actually goes away
    // (burn and write-off), so NAV never counts a phantom position.

    function recoverCloseUnstake() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        // Pause the vault for the manual close, mirroring closeToInventory; never
        // weaken an existing HALTED.
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        IVenueRecovery(address(venue)).closeUnstake(positionId);
        emit VenueCloseStageRecovered(positionId, 1);
    }

    function recoverCloseDecrease(uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        onlyRole(GUARDIAN_ROLE)
        nonReentrant
    {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        IVenueRecovery(address(venue)).closeDecrease(positionId, amount0Min, amount1Min, deadline);
        emit VenueCloseStageRecovered(positionId, 2);
    }

    function recoverCloseCollect() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        IVenueRecovery(address(venue)).closeCollect(positionId);
        emit VenueCloseStageRecovered(positionId, 3);
    }

    /// @notice Final stage: the position is burned and its proceeds are now Main
    /// inventory (identical end-state to a normal close), so `activePositionId` is
    /// cleared here — after this `totalAssetsUsdt()` values only real inventory.
    function recoverCloseBurn() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        IVenueRecovery(address(venue)).closeBurn(positionId);
        activePositionId = 0;
        emit VenueCloseStageRecovered(positionId, 4);
    }

    /// @notice Abandon a position whose close cannot complete. The venue frees its
    /// slot (returning the NFT to this contract if it was unstaked, or recording
    /// it as stranded-in-masterchef otherwise); Main drops it from its books so
    /// `totalAssetsUsdt()` stops valuing it — a written-off position is not counted
    /// as NAV, phantom or otherwise. Any LP value still trapped in a returned NFT
    /// is deliberately excluded until an admin realizes it, never over-counted.
    /// Forces HALTED: a write-off is a serious abnormal event and must require an
    /// explicit admin review (enableOperations) before trading resumes.
    function writeOffStrandedPosition() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        uint256 pairedBefore = pairedToken.balanceOf(address(this));
        uint256 stranded = IVenueRecovery(address(venue)).writeOffStrandedPosition();
        activePositionId = 0;
        _setMode(Mode.HALTED);
        bool inventoryReturned = pairedToken.balanceOf(address(this)) != pairedBefore;
        emit VenuePositionWrittenOff(positionId, stranded, inventoryReturned);
    }

    /// @notice Direct-Pancake liquidation of paired-token inventory. `chunkIndex`
    /// and `finalChunk` support draining a remainder whose notional exceeds this
    /// job's per-job cap headroom over several calls: when the current balance
    /// does not fit under the remaining headroom, this call swaps only the
    /// slice that does and leaves the rest for a later chunk (same job while
    /// headroom remains, a fresh jobId once it is exhausted). `finalChunk`
    /// asserts the balance has been driven down to `PAIRED_DUST_TOLERANCE` and
    /// completes the job. `_reserveSwapNotional`'s per-job and per-day caps are
    /// evaluated exactly as before on every call, so a chunk series only
    /// changes how a job's notional is split across calls, never the caps
    /// themselves — in particular the daily cap still accumulates across every
    /// chunk of every job, so a series of small calls cannot exceed it.
    function liquidateAllWbnb(
        bytes32 jobId,
        uint32 chunkIndex,
        uint256 keeperMinOut,
        uint256 deadline,
        bool finalChunk,
        bool emergency
    ) external nonReentrant returns (uint256 amountOut) {
        if (emergency) _checkRole(GUARDIAN_ROLE, msg.sender);
        else _checkRole(KEEPER_ROLE, msg.sender);
        if (!emergency && mode == Mode.HALTED) revert HaltedKeeperPath();
        Job storage job = _beginChunk(jobId, JobKind.LIQUIDATE_WBNB, chunkIndex);

        uint256 balance = pairedToken.balanceOf(address(this));
        if (balance == 0) revert InvalidAmount();

        uint256 jobCap = emergency ? hardMaxActiveAssets : swapPerJobCap;
        uint256 used = job.cumulativeNotionalAsset;
        uint256 headroom = used >= jobCap ? 0 : jobCap - used;
        uint256 notional = priceGuard.fairValue(WBNB, USDT, balance);
        uint256 amountIn = balance;
        // Slice down to per-job headroom only on a non-final chunk. A final
        // chunk whose notional exceeds the cap still reverts SwapCapExceeded in
        // `_reserveSwapNotional` (single-call cap semantics unchanged); an
        // oversized residual is drained by issuing one or more non-final chunks
        // first, then a final chunk once the remainder fits under the cap.
        if (notional > headroom && !finalChunk) {
            if (headroom == 0) revert SwapCapExceeded(notional, jobCap);
            // fairValue is linear in amountIn, so scaling amountIn down by
            // headroom/notional scales the resulting notional down to fit.
            amountIn = FullMath.mulDiv(balance, headroom, notional);
            if (amountIn == 0) revert SwapCapExceeded(notional, jobCap);
            notional = priceGuard.fairValue(WBNB, USDT, amountIn);
        }
        _reserveSwapNotional(job, notional, emergency);

        pairedToken.forceApprove(address(executionAdapter), amountIn);
        amountOut = executionAdapter.swapPairedToAsset(amountIn, keeperMinOut, deadline, emergency);
        pairedToken.forceApprove(address(executionAdapter), 0);
        // Oracle floor on the realized output, computed from the price guard's
        // own swap budget for the amount actually swapped THIS chunk (post-slice
        // amountIn) — the same rule the execution adapter enforces, so the two
        // floors cannot diverge (a wider guard budget no longer DoS's a
        // legitimate liquidation, and an expired/unarmed emergency budget makes
        // the guard revert here too).
        uint256 floor = priceGuard.minimumOut(WBNB, USDT, amountIn, emergency);
        if (amountOut < floor) revert SwapBelowFloor(floor, amountOut);

        if (finalChunk) {
            uint256 remaining = pairedToken.balanceOf(address(this));
            if (remaining > PAIRED_DUST_TOLERANCE) revert InventoryRemaining(remaining);
            _completeJob(job);
        }
        _recordWithdrawalExecutionLoss(notional, amountOut);

        job.cumulativeInput += amountIn;
        job.cumulativeOutput += amountOut;
        emit WbnbLiquidated(jobId, amountIn, amountOut, emergency);
    }

    /// @notice Direct-Pancake liquidation of all canonical CAKE reward inventory.
    /// It is a separate durable job so reward failures cannot block LP close or
    /// WBNB realization. Chunking follows the same headroom-based slicing as
    /// `liquidateAllWbnb`; see that function's NatSpec for the mechanics and the
    /// daily-cap preservation argument.
    function liquidateAllReward(
        bytes32 jobId,
        uint32 chunkIndex,
        uint256 keeperMinOut,
        uint256 deadline,
        bool finalChunk,
        bool emergency
    ) external nonReentrant returns (uint256 amountOut) {
        if (emergency) _checkRole(GUARDIAN_ROLE, msg.sender);
        else _checkRole(KEEPER_ROLE, msg.sender);
        if (!emergency && mode == Mode.HALTED) revert HaltedKeeperPath();
        Job storage job = _beginChunk(jobId, JobKind.LIQUIDATE_REWARD, chunkIndex);

        uint256 balance = rewardToken.balanceOf(address(this));
        if (balance == 0) revert InvalidAmount();

        uint256 jobCap = emergency ? hardMaxActiveAssets : swapPerJobCap;
        uint256 used = job.cumulativeNotionalAsset;
        uint256 headroom = used >= jobCap ? 0 : jobCap - used;
        uint256 notional = rewardPriceGuard.fairValue(balance);
        uint256 amountIn = balance;
        // Slice only on a non-final chunk; a final chunk over the cap still
        // reverts SwapCapExceeded (see liquidateAllWbnb for the rationale).
        if (notional > headroom && !finalChunk) {
            if (headroom == 0) revert SwapCapExceeded(notional, jobCap);
            amountIn = FullMath.mulDiv(balance, headroom, notional);
            if (amountIn == 0) revert SwapCapExceeded(notional, jobCap);
            notional = rewardPriceGuard.fairValue(amountIn);
        }
        _reserveSwapNotional(job, notional, emergency);

        rewardToken.forceApprove(address(rewardExecutionAdapter), amountIn);
        amountOut = rewardExecutionAdapter.swapRewardToAsset(amountIn, keeperMinOut, deadline, emergency);
        rewardToken.forceApprove(address(rewardExecutionAdapter), 0);
        // Oracle floor from the reward guard's own swap budget for the amount
        // swapped THIS chunk (post-slice amountIn); see liquidateAllWbnb.
        uint256 floor = rewardPriceGuard.minimumOut(amountIn, emergency);
        if (amountOut < floor) revert SwapBelowFloor(floor, amountOut);

        if (finalChunk) {
            uint256 remaining = rewardToken.balanceOf(address(this));
            if (remaining > REWARD_DUST_TOLERANCE) revert RewardInventoryRemaining(remaining);
            _completeJob(job);
        }
        _recordWithdrawalExecutionLoss(notional, amountOut);

        job.cumulativeInput += amountIn;
        job.cumulativeOutput += amountOut;
        emit RewardLiquidated(jobId, amountIn, amountOut, emergency);
    }

    function totalAssetsUsdt() public view returns (uint256 total) {
        total = asset.balanceOf(address(this));
        uint256 paired = pairedToken.balanceOf(address(this));
        if (paired != 0) total += priceGuard.minimumOut(WBNB, USDT, paired, false);
        if (activePositionId != 0) {
            // A one-sided-USDT position would otherwise bypass the oracle
            // cross-check because there is no WBNB amount to value below.
            priceGuard.minimumOut(WBNB, USDT, 1e18, false);
            // Value the position on both the TWAP and the spot composition (each
            // at the oracle) and take the LOWER. A spot manipulation inflates one
            // composition; min() takes the other, so NAV never inflates in either
            // direction. NOTE: min() can UNDER-value NAV on an honest TWAP/spot
            // divergence — that dilutes incoming depositors rather than exiting
            // holders, the opposite of the risk we guard, and deposits are frozen
            // while a redeem cycle is committed. Deliberate and accepted.
            uint160 twapSqrtPrice = priceGuard.twapSqrtPriceX96();
            (uint256 twapAsset, uint256 twapPaired) =
                venue.previewCloseAmountsAtSqrtPrice(activePositionId, twapSqrtPrice);
            (uint256 spotAsset, uint256 spotPaired) = venue.previewCloseAmounts(activePositionId);
            uint256 twapValue = twapAsset + (twapPaired != 0 ? priceGuard.minimumOut(WBNB, USDT, twapPaired, false) : 0);
            uint256 spotValue = spotAsset + (spotPaired != 0 ? priceGuard.minimumOut(WBNB, USDT, spotPaired, false) : 0);
            total += twapValue < spotValue ? twapValue : spotValue;
        }
        uint256 rewards = rewardToken.balanceOf(address(this));
        if (rewards != 0) total += rewardPriceGuard.minimumOut(rewards, false);
    }

    function rewardInventory() external view returns (uint256) {
        return rewardToken.balanceOf(address(this));
    }

    /// @notice Exposure of the strategy in USDT for the capital ceiling: fair-mid
    /// valued (no minimumOut haircut) and, for the active position, the HIGHER of
    /// the TWAP/spot geometry. Both choices point the same way — never understate
    /// exposure — the opposite of the revenue-conservative `totalAssetsUsdt`.
    function _fundingExposureUsdt() internal view returns (uint256 total) {
        total = asset.balanceOf(address(this));
        uint256 paired = pairedToken.balanceOf(address(this));
        if (paired != 0) total += priceGuard.fairValue(WBNB, USDT, paired);
        if (activePositionId != 0) {
            priceGuard.minimumOut(WBNB, USDT, 1e18, false); // oracle coherence, as in NAV
            uint160 twapSqrtPrice = priceGuard.twapSqrtPriceX96();
            (uint256 twapAsset, uint256 twapPaired) =
                venue.previewCloseAmountsAtSqrtPrice(activePositionId, twapSqrtPrice);
            (uint256 spotAsset, uint256 spotPaired) = venue.previewCloseAmounts(activePositionId);
            uint256 twapValue = _fairInventoryValue(twapAsset, twapPaired);
            uint256 spotValue = _fairInventoryValue(spotAsset, spotPaired);
            total += twapValue > spotValue ? twapValue : spotValue;
        }
        uint256 rewards = rewardToken.balanceOf(address(this));
        if (rewards != 0) total += rewardPriceGuard.fairValue(rewards);
    }

    function _inventoryValue(uint256 assetAmount, uint256 pairedAmount, bool emergency)
        internal
        view
        returns (uint256 value)
    {
        value = assetAmount;
        if (pairedAmount != 0) {
            value += emergency
                ? priceGuard.minimumOut(WBNB, USDT, pairedAmount, true)
                : priceGuard.fairValue(WBNB, USDT, pairedAmount);
        }
    }

    function _fairInventoryValue(uint256 assetAmount, uint256 pairedAmount) internal view returns (uint256 value) {
        value = assetAmount;
        if (pairedAmount != 0) value += priceGuard.fairValue(WBNB, USDT, pairedAmount);
    }

    /// @notice Revert if the live pool spot price deviates from the oracle price
    /// by more than the allowed band. Reads spot from the pool via the venue;
    /// oracle price is the guard's fair USDT value of 1 WBNB.
    function _requireSpotOracleCoherence(bool emergency) internal view {
        uint256 oracleUsdtPerWbnb = priceGuard.fairValue(WBNB, USDT, 1e18);
        if (oracleUsdtPerWbnb == 0) revert SpotDivergedFromOracle(0, 0);
        (uint160 spotSqrt,,,,,,) = IV3PoolSpot(venue.poolAddress()).slot0();
        uint256 spotUsdtPerWbnb = _usdtPerWbnbFromSqrt(spotSqrt);
        uint256 diff =
            spotUsdtPerWbnb > oracleUsdtPerWbnb ? spotUsdtPerWbnb - oracleUsdtPerWbnb : oracleUsdtPerWbnb - spotUsdtPerWbnb;
        uint16 tol = emergency ? emergencySpotOracleDeviationBps : maxSpotOracleDeviationBps;
        if (FullMath.mulDiv(diff, BPS, oracleUsdtPerWbnb) > tol) {
            revert SpotDivergedFromOracle(spotUsdtPerWbnb, oracleUsdtPerWbnb);
        }
    }

    /// @notice USDT (18 dec) per 1e18 WBNB implied by a pool sqrtPriceX96. The
    /// pool is USDT(token0)/WBNB(token1), so price(token1/token0)=(sqrt/2^96)^2 is
    /// WBNB per USDT; its inverse, scaled by 1e18, is USDT per WBNB.
    function _usdtPerWbnbFromSqrt(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 tmp = FullMath.mulDiv(Q96, Q96, sqrtPriceX96); // 2^192 / sqrt
        return FullMath.mulDiv(tmp, 1e18, sqrtPriceX96); // (2^192/sqrt) * 1e18 / sqrt
    }

    function _boundedLpMinimum(uint256 expected, uint16 lossBps) internal pure returns (uint256) {
        if (expected == 0) return 0;
        uint256 minimum = FullMath.mulDiv(expected, BPS - lossBps, BPS);
        return minimum == 0 ? 1 : minimum;
    }

    /// @notice Validate the requested tick range and return the TWAP sqrt price.
    /// The range must have a bounded width and strictly straddle the TWAP price,
    /// so a manipulated spot cannot steer the keeper into a degenerate or
    /// out-of-range mint.
    function _validateOpenTicks(int24 tickLower, int24 tickUpper) internal view returns (uint160 twapSqrt) {
        if (tickLower >= tickUpper) revert InvalidTickRange(tickLower, tickUpper);
        int24 width = tickUpper - tickLower;
        if (width < minTickWidth || width > maxTickWidth) revert InvalidTickRange(tickLower, tickUpper);
        twapSqrt = priceGuard.twapSqrtPriceX96();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        if (twapSqrt <= sqrtLower || twapSqrt >= sqrtUpper) revert TwapOutsideTickRange();
    }

    /// @notice Amounts the mint would consume for `assetDesired`/`pairedDesired`
    /// evaluated at the TWAP price. Same geometry the venue previews, but anchored
    /// to TWAP rather than the current spot.
    function _expectedMintAmountsAtTwap(
        uint256 assetDesired,
        uint256 pairedDesired,
        int24 tickLower,
        int24 tickUpper,
        uint160 twapSqrt
    ) internal pure returns (uint256 assetExpected, uint256 pairedExpected) {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(twapSqrt, sqrtA, sqrtB, assetDesired, pairedDesired);
        (assetExpected, pairedExpected) = LiquidityAmounts.getAmountsForLiquidity(twapSqrt, sqrtA, sqrtB, liquidity);
    }

    function _beginChunk(bytes32 jobId, JobKind kind, uint32 chunkIndex) internal returns (Job storage job) {
        if (jobId == bytes32(0)) revert InvalidJobId();
        job = jobs[jobId];
        if (job.status == JobStatus.NONE) {
            job.kind = kind;
            job.status = JobStatus.ACTIVE;
            job.createdAt = uint64(block.timestamp);
        } else {
            if (job.kind != kind) revert JobKindMismatch(job.kind, kind);
            if (job.status == JobStatus.COMPLETED) revert JobAlreadyCompleted();
        }
        if (usedChunks[jobId][chunkIndex]) revert DuplicateChunk(chunkIndex);
        usedChunks[jobId][chunkIndex] = true;
        job.chunks += 1;
    }

    function _completeJob(Job storage job) internal {
        job.status = JobStatus.COMPLETED;
        job.completedAt = uint64(block.timestamp);
    }

    function _reserveSwapNotional(Job storage job, uint256 notional, bool emergency) internal {
        uint256 jobTotal = job.cumulativeNotionalAsset + notional;
        uint256 jobCap = emergency ? hardMaxActiveAssets : swapPerJobCap;
        if (jobTotal > jobCap) revert SwapCapExceeded(jobTotal, jobCap);
        job.cumulativeNotionalAsset = jobTotal;

        // Always ACCOUNT the day's turnover, including emergency volume, so a
        // subsequent normal swap sees what the emergency already spent. Only the
        // daily-LIMIT check is skipped for emergencies (a deliberate relief); the
        // accounting blindness was not deliberate.
        uint64 day = uint64(block.timestamp / 1 days);
        uint256 dayTotal = dailySwapNotional[day] + notional;
        if (!emergency && dayTotal > dailySwapLimit) revert DailySwapCapExceeded(dayTotal, dailySwapLimit);
        dailySwapNotional[day] = dayTotal;
    }

    function _setMode(Mode newMode) internal {
        Mode oldMode = mode;
        mode = newMode;
        emit ModeChanged(oldMode, newMode);
    }

    /// @notice Auto-commit the queued batch when a keeper begins an inventory
    /// close with requests outstanding. This mirrors the explicit
    /// `commitWithdrawalCycle`: both the commit flag AND the batch flag are set
    /// together. Setting only the commit flag would leave the batch flag false,
    /// which (a) silently disables the execution-loss journal for the very close
    /// that motivates the cycle and (b) bricks a later `commitWithdrawalCycle`
    /// (it reverts forever on the one-way commit guard). The vault's batch
    /// settlement also requires the batch flag, so the two flags must move
    /// together on every commit path.
    function _commitWithdrawalCycleIfQueued() internal {
        if (queuedWithdrawalCount == 0 || withdrawalCycleCommitted) return;
        withdrawalCycleCommitted = true;
        withdrawalCycleBatchCommitted = true;
        emit WithdrawalCycleCommitted(queuedWithdrawalCount);
    }

    function _recordWithdrawalExecutionLoss(uint256 expected, uint256 actual) internal {
        if (!withdrawalCycleBatchCommitted || actual >= expected) return;
        uint256 incremental = expected - actual;
        withdrawalCycleExecutionLoss += incremental;
        emit WithdrawalExecutionLossRecorded(incremental, withdrawalCycleExecutionLoss);
    }
}
