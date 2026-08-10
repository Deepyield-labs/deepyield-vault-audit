// SPDX-License-Identifier: MIT
pragma solidity =0.8.24 >=0.4.16 >=0.8.4 ^0.8.20 ^0.8.24;

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

// src/interfaces/IPancakeSwapV3.sol

/// @notice Minimal subset of PancakeSwap V3 SmartRouter required by the
/// production swap adapter. Matches the on-chain SmartRouter ABI at
/// 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4 on BSC mainnet (Uniswap V3
/// style, no `deadline` field).
interface IPancakeSwapV3SmartRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Minimal subset of a PancakeSwap V3 pool used for view-friendly
/// quoting. Quoter V2 cannot be used from a Solidity `view` context because
/// its body executes a real swap callback that performs SSTOREs; under the
/// EVM's strict `staticcall` rules those SSTOREs revert (even though RPC-
/// level `eth_call` tolerates them). Reading `slot0()` directly works in any
/// view context and is exact-enough for the small swap sizes the vault
/// exercises against deep pools.
interface IPancakeV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint32 feeProtocol,
        bool unlocked
    );

    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);

    /// @notice Returns cumulative tick and liquidity values as of each
    /// timestamp `secondsAgo` from the current block timestamp. Used to
    /// derive a TWAP that is not flash-manipulable like slot0.
    ///
    /// Reverts if any `secondsAgo` falls outside the pool's observation
    /// buffer (i.e. the pool's `observationCardinality` does not cover the
    /// requested window). Callers must size the TWAP window or increase the
    /// pool's cardinality accordingly.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
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

// src/VaultBCakePriceGuard.sol

/// @notice On-chain lower bound for Vault B CAKE-to-USDT liquidation.
/// It cross-checks a direct CAKE/USDT TWAP against an independent
/// CAKE/WBNB TWAP converted through Chainlink BNB/USD and USDT/USD.
contract VaultBCakePriceGuard is AccessControl, IVaultBRewardPriceGuard {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 internal constant BPS = 10_000;

    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant CAKE_USDT_ORACLE_POOL = 0x7f51c8AaA6B0599aBd16674e2b17FEc7a9f674A1;
    address public constant CAKE_WBNB_ORACLE_POOL = 0xAfB2Da14056725E3BA3a30dD846B6BBbd7886c56;
    address public constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address public constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    uint24 public constant DIRECT_ORACLE_FEE = 2_500;
    uint24 public constant CROSS_ORACLE_FEE = 500;

    IPancakeV3Pool public constant directPool = IPancakeV3Pool(CAKE_USDT_ORACLE_POOL);
    IPancakeV3Pool public constant crossPool = IPancakeV3Pool(CAKE_WBNB_ORACLE_POOL);
    IChainlinkAggregatorV3 public constant bnbUsdFeed = IChainlinkAggregatorV3(BNB_USD_FEED);
    IChainlinkAggregatorV3 public constant usdtUsdFeed = IChainlinkAggregatorV3(USDT_USD_FEED);

    uint16 public immutable normalLossBps;
    uint16 public immutable maxEmergencyLossBps;
    uint16 public immutable maxOracleDeviationBps;
    uint256 public immutable maxNormalNotional;
    uint256 public immutable maxEmergencyNotional;
    uint32 public immutable twapWindow;
    uint32 public immutable maxBnbFeedAge;
    uint32 public immutable maxUsdtFeedAge;
    uint32 public immutable maxEmergencyDuration;

    uint16 public emergencyLossBps;
    uint64 public emergencyExpiresAt;

    error WrongChain(uint256 actual);
    error ZeroAddress();
    error InvalidPool(address pool);
    error InvalidConfiguration();
    error InvalidAmount();
    error InvalidOracleAnswer(address feed);
    error StaleOracle(address feed, uint256 age);
    error FutureOracleTimestamp(address feed, uint256 timestamp);
    error IncompleteOracleRound(address feed, uint80 roundId, uint80 answeredInRound);
    error UnsupportedOracleDecimals(address feed, uint8 decimals);
    error OracleDeviation(uint256 directOut, uint256 compositeOut, uint256 deviationBps);
    error CapacityExceeded(uint256 notional, uint256 cap);
    error TwapUnavailable(address pool);
    error EmergencyBudgetInactive();
    error InvalidEmergencyBudget();

    event EmergencyBudgetActivated(uint16 lossBps, uint64 expiresAt);
    event EmergencyBudgetCleared();

    struct Quote {
        uint256 directTwapOut;
        uint256 compositeTwapOut;
        uint256 fairOut;
        uint256 minOut;
        uint256 deviationBps;
        uint16 lossBps;
    }

    constructor(
        uint16 normalLossBps_,
        uint16 maxEmergencyLossBps_,
        uint16 maxOracleDeviationBps_,
        uint256 maxNormalNotional_,
        uint256 maxEmergencyNotional_,
        uint32 twapWindow_,
        uint32 maxBnbFeedAge_,
        uint32 maxUsdtFeedAge_,
        uint32 maxEmergencyDuration_,
        address admin_,
        address guardian_
    ) {
        if (block.chainid != 56) revert WrongChain(block.chainid);
        if (admin_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        if (
            normalLossBps_ == 0 || normalLossBps_ >= BPS || maxEmergencyLossBps_ < normalLossBps_
                || maxEmergencyLossBps_ >= BPS || maxOracleDeviationBps_ == 0 || maxOracleDeviationBps_ >= BPS
                || maxNormalNotional_ == 0 || maxEmergencyNotional_ < maxNormalNotional_ || twapWindow_ < 60
                || maxBnbFeedAge_ == 0 || maxUsdtFeedAge_ == 0 || maxEmergencyDuration_ == 0
        ) revert InvalidConfiguration();

        _validatePool(directPool, USDT, DIRECT_ORACLE_FEE);
        _validatePool(crossPool, WBNB, CROSS_ORACLE_FEE);

        normalLossBps = normalLossBps_;
        maxEmergencyLossBps = maxEmergencyLossBps_;
        maxOracleDeviationBps = maxOracleDeviationBps_;
        maxNormalNotional = maxNormalNotional_;
        maxEmergencyNotional = maxEmergencyNotional_;
        twapWindow = twapWindow_;
        maxBnbFeedAge = maxBnbFeedAge_;
        maxUsdtFeedAge = maxUsdtFeedAge_;
        maxEmergencyDuration = maxEmergencyDuration_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(GUARDIAN_ROLE, guardian_);
    }

    function activateEmergencyBudget(uint16 lossBps, uint64 expiresAt) external onlyRole(GUARDIAN_ROLE) {
        if (
            lossBps < normalLossBps || lossBps > maxEmergencyLossBps || expiresAt <= block.timestamp
                || expiresAt > block.timestamp + maxEmergencyDuration
        ) revert InvalidEmergencyBudget();
        emergencyLossBps = lossBps;
        emergencyExpiresAt = expiresAt;
        emit EmergencyBudgetActivated(lossBps, expiresAt);
    }

    function clearEmergencyBudget() external onlyRole(GUARDIAN_ROLE) {
        emergencyLossBps = 0;
        emergencyExpiresAt = 0;
        emit EmergencyBudgetCleared();
    }

    function minimumOut(uint256 amountIn, bool emergency) external view returns (uint256) {
        return quote(amountIn, emergency).minOut;
    }

    function fairValue(uint256 amountIn) external view returns (uint256) {
        return _sourceQuote(amountIn).fairOut;
    }

    function quote(uint256 amountIn, bool emergency) public view returns (Quote memory q) {
        q = _sourceQuote(amountIn);
        uint256 cap = emergency ? maxEmergencyNotional : maxNormalNotional;
        if (q.fairOut > cap) revert CapacityExceeded(q.fairOut, cap);

        q.lossBps = _lossBudget(emergency);
        q.minOut = FullMath.mulDiv(q.fairOut, BPS - q.lossBps, BPS);
        if (q.minOut == 0) revert InvalidAmount();
    }

    function _sourceQuote(uint256 amountIn) internal view returns (Quote memory q) {
        if (amountIn == 0) revert InvalidAmount();

        q.directTwapOut = _twapQuote(directPool, amountIn, CAKE, USDT);
        uint256 wbnbOut = _twapQuote(crossPool, amountIn, CAKE, WBNB);
        uint256 bnbUsd = _readFeed(bnbUsdFeed, maxBnbFeedAge);
        uint256 usdtUsd = _readFeed(usdtUsdFeed, maxUsdtFeedAge);
        q.compositeTwapOut = FullMath.mulDiv(wbnbOut, bnbUsd, usdtUsd);
        if (q.directTwapOut == 0 || q.compositeTwapOut == 0) revert InvalidAmount();

        uint256 lower = q.directTwapOut < q.compositeTwapOut ? q.directTwapOut : q.compositeTwapOut;
        uint256 upper = q.directTwapOut > q.compositeTwapOut ? q.directTwapOut : q.compositeTwapOut;
        q.deviationBps = FullMath.mulDiv(upper - lower, BPS, lower);
        if (q.deviationBps > maxOracleDeviationBps) {
            revert OracleDeviation(q.directTwapOut, q.compositeTwapOut, q.deviationBps);
        }

        q.fairOut = lower;
    }

    function _validatePool(IPancakeV3Pool candidate, address quoteToken, uint24 expectedFee) internal view {
        if (candidate.token0() != CAKE || candidate.token1() != quoteToken || candidate.fee() != expectedFee) {
            revert InvalidPool(address(candidate));
        }
    }

    function _lossBudget(bool emergency) internal view returns (uint16) {
        if (!emergency) return normalLossBps;
        if (emergencyLossBps == 0 || emergencyExpiresAt <= block.timestamp || emergencyLossBps > maxEmergencyLossBps) {
            revert EmergencyBudgetInactive();
        }
        return emergencyLossBps;
    }

    function _readFeed(IChainlinkAggregatorV3 feed, uint32 maxAge) internal view returns (uint256 answerWad) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0) revert InvalidOracleAnswer(address(feed));
        if (updatedAt > block.timestamp) revert FutureOracleTimestamp(address(feed), updatedAt);
        if (answeredInRound < roundId) revert IncompleteOracleRound(address(feed), roundId, answeredInRound);
        uint256 age = block.timestamp - updatedAt;
        if (age > maxAge) revert StaleOracle(address(feed), age);

        uint8 decimals = feed.decimals();
        if (decimals > 36) revert UnsupportedOracleDecimals(address(feed), decimals);
        // `answer > 0` above proves this signed-to-unsigned cast preserves the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 unsigned = uint256(answer);
        if (decimals == 18) return unsigned;
        if (decimals < 18) return unsigned * (10 ** (18 - decimals));
        return unsigned / (10 ** (decimals - 18));
    }

    function _twapQuote(IPancakeV3Pool sourcePool, uint256 amountIn, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256)
    {
        int24 tick = _twapTick(sourcePool);
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return tokenIn < tokenOut
                ? FullMath.mulDiv(ratioX192, amountIn, 1 << 192)
                : FullMath.mulDiv(1 << 192, amountIn, ratioX192);
        }

        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return tokenIn < tokenOut
            ? FullMath.mulDiv(ratioX128, amountIn, 1 << 128)
            : FullMath.mulDiv(1 << 128, amountIn, ratioX128);
    }

    function _twapTick(IPancakeV3Pool sourcePool) internal view returns (int24 meanTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        try sourcePool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            if (tickCumulatives.length != 2) revert TwapUnavailable(address(sourcePool));
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 window = int56(uint56(twapWindow));
            // A V3 cumulative-tick average remains inside the protocol's int24 tick domain.
            // forge-lint: disable-next-line(unsafe-typecast)
            meanTick = int24(delta / window);
            if (delta < 0 && delta % window != 0) meanTick--;
        } catch {
            revert TwapUnavailable(address(sourcePool));
        }
    }
}
