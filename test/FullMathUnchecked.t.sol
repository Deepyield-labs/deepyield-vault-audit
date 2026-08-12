// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Exposes the internal library functions and an audited reference
/// (OpenZeppelin Math.mulDiv) so tests can call them externally and catch
/// reverts.
contract FullMathHarness {
    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDiv(a, b, d);
    }

    function mulDivRoundingUp(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDivRoundingUp(a, b, d);
    }

    function refMulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return Math.mulDiv(a, b, d);
    }

    function refMulDivUp(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return Math.mulDiv(a, b, d, Math.Rounding.Ceil);
    }
}

/// @notice B1-T3: the 512-bit branch of FullMath.mulDiv relies on wrapping
/// arithmetic that reverts under ^0.8 without `unchecked`. These inputs enter
/// that branch; on the pre-fix code tests 1/2/5 revert.
contract FullMathUncheckedTest is Test {
    FullMathHarness internal h;

    function setUp() public {
        h = new FullMathHarness();
    }

    // 1. Inputs that hit the 512-bit branch return the correct result.
    function testFiveTwelveBitBranchComputesInsteadOfReverting() public view {
        assertEq(h.mulDiv(2 ** 255, 2 ** 255, 2 ** 255), 2 ** 255);
        assertEq(h.mulDiv(2 ** 255, 4, 8), 2 ** 254);
    }

    // 2. Boundary: max * max / max == max (deep in the 512-bit branch).
    function testBoundaryMaxMaxMax() public view {
        uint256 m = type(uint256).max;
        assertEq(h.mulDiv(m, m, m), m);
    }

    // 3. denominator == 0 still reverts (both branches).
    function testDenominatorZeroReverts() public {
        vm.expectRevert();
        h.mulDiv(1, 1, 0);
        vm.expectRevert();
        h.mulDiv(2 ** 255, 2 ** 255, 0);
    }

    // 4. denominator <= prod1 (result would overflow uint256) still reverts.
    function testResultOverflowReverts() public {
        // a*b = 2**510 -> prod1 = 2**254; denominator 2**254 is not > prod1.
        vm.expectRevert();
        h.mulDiv(2 ** 255, 2 ** 255, 2 ** 254);
    }

    // 5. Fuzz against the audited OZ reference across the full domain: when the
    //    reference succeeds our result matches; when it reverts (overflow) ours
    //    reverts too.
    function testFuzzMulDivMatchesReference(uint256 a, uint256 b, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        try h.refMulDiv(a, b, d) returns (uint256 expected) {
            assertEq(h.mulDiv(a, b, d), expected);
        } catch {
            vm.expectRevert();
            h.mulDiv(a, b, d);
        }
    }

    // 6. mulDivRoundingUp: rounds up, exact stays exact, and round-up does not
    //    overflow at max (the require(result < max) guard holds).
    function testMulDivRoundingUp() public view {
        assertEq(h.mulDivRoundingUp(5, 2, 3), 4); // 10/3 -> ceil 4
        assertEq(h.mulDivRoundingUp(6, 2, 3), 4); // 12/3 -> exact 4
        uint256 m = type(uint256).max;
        assertEq(h.mulDivRoundingUp(m, m, m), m); // exact, no increment, no overflow
    }

    function testFuzzMulDivRoundingUpMatchesReference(uint256 a, uint256 b, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        try h.refMulDivUp(a, b, d) returns (uint256 expected) {
            assertEq(h.mulDivRoundingUp(a, b, d), expected);
        } catch {
            vm.expectRevert();
            h.mulDivRoundingUp(a, b, d);
        }
    }
}
