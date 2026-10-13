// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CrawlHiveToken} from "../src/CrawlHiveToken.sol";

/// @title CrawlHiveTokenEdgesTest
/// @notice Inputs the implementation was not written with in mind: zero, one wei, the maximum, the
///         same call twice, the zero address in every argument position, a deployer that is not a
///         wallet, and the allowance edges around the infinite value. Pinned beside fuzzed versions.
/// forge-config: default.fuzz.runs = 1000
contract CrawlHiveTokenEdgesTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 ether;

    CrawlHiveToken token;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address spender = makeAddr("spender");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new CrawlHiveToken();
    }

    // ---------------------------------------------------------------- supply literal & deployment

    /// @dev The manifest states the supply in minor units as a decimal literal; the constant must be
    ///      that exact number, not merely "a billion ether".
    function test_supplyMatchesManifestLiteral() public view {
        assertEq(token.totalSupply(), 1000000000000000000000000000);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.totalSupply() / 10 ** token.decimals(), 1_000_000_000);
    }

    function test_defaultsAreZero() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.allowance(address(0), address(0)), 0);
    }

    /// @dev Two deployments are independent tokens: each mints its own supply to its own deployer
    ///      and neither sees the other's balances.
    function test_twoDeploymentsAreIndependent() public {
        vm.prank(alice);
        CrawlHiveToken second = new CrawlHiveToken();
        assertTrue(address(second) != address(token));
        assertEq(second.totalSupply(), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev The mint goes to msg.sender, so a deployment from the zero address is refused by the
    ///      receiver check rather than minting a supply nobody can spend.
    function test_RevertWhen_deployedFromZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(address(0));
        new CrawlHiveToken();
    }

    function testFuzz_anyDeployerReceivesWholeSupply(uint160 seed) public {
        address who = address(uint160(bound(uint256(seed), 1, type(uint160).max)));
        vm.prank(who);
        CrawlHiveToken fresh = new CrawlHiveToken();
        assertEq(fresh.balanceOf(who), EXPECTED_SUPPLY);
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------- one wei, twice, full balance

    function test_transferOneWei() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 1);
    }

    function test_RevertWhen_transferOneWeiAboveBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        vm.prank(alice);
        token.transfer(bob, 2);
    }

    function test_RevertWhen_transferMaxUint() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, type(uint256).max
            )
        );
        vm.prank(deployer);
        token.transfer(alice, type(uint256).max);
    }

    /// @dev The same full-balance transfer twice: the first drains, the second fails on an empty
    ///      balance with the exact numbers, and nothing was created in between.
    function test_sameTransferTwiceFailsTheSecondTime() public {
        vm.startPrank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, EXPECTED_SUPPLY)
        );
        token.transfer(alice, EXPECTED_SUPPLY);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_fullRoundTripReturnsExactly() public {
        vm.prank(deployer);
        token.transfer(alice, EXPECTED_SUPPLY);
        vm.prank(alice);
        token.transfer(bob, EXPECTED_SUPPLY);
        vm.prank(bob);
        token.transfer(deployer, EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToTokenContractIsAllowedAndStranded() public {
        // No rescue function exists by design; the README says so. Pin that it is really stranded.
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 5));
        assertEq(token.balanceOf(address(token)), 5);
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", deployer, 5));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("withdrawToken(address,uint256)", deployer, 5));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 5);
    }

    // ---------------------------------------------------------------- transferFrom edges

    function test_transferFromZeroAmountNeedsNoAllowance() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(deployer, spender), 0);
    }

    /// @dev From the zero address with a zero amount: the allowance comparison passes (0 <= 0) but
    ///      updating the zero owner's allowance is refused, so even a no-op pull from the burn
    ///      address reverts.
    function test_RevertWhen_transferFromZeroSenderEvenForZero() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 0);
    }

    function test_RevertWhen_transferFromToZeroAddress() public {
        vm.prank(deployer);
        token.approve(spender, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 1 ether);
        assertEq(token.allowance(deployer, spender), 1 ether, "a failed pull spent allowance");
    }

    function test_RevertWhen_transferFromOneWeiAboveAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1, 2));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 2);
        assertEq(token.allowance(deployer, spender), 1);
    }

    /// @dev The allowance is checked before the balance, so the allowance error names the spender
    ///      even when the owner could not pay either.
    function test_allowanceIsCheckedBeforeBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
    }

    function test_ownerCanPullFromItselfOnlyWithSelfAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1);

        vm.startPrank(deployer);
        token.approve(deployer, 3);
        assertTrue(token.transferFrom(deployer, alice, 2));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 2);
        assertEq(token.allowance(deployer, deployer), 1);
    }

    function test_transferFromBackToOwnerStillSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, 4));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.allowance(deployer, spender), 6);
    }

    function test_transferFromEmitsTransferButNoApproval() public {
        vm.prank(deployer);
        token.approve(spender, 10);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(deployer, bob, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom must emit exactly one event");
        assertEq(logs[0].topics[0], Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), deployer);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), 4);
    }

    // ---------------------------------------------------------------- allowance edges

    function test_approveOverwritesRatherThanAccumulates() public {
        vm.startPrank(deployer);
        token.approve(spender, 5);
        token.approve(spender, 5);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 5, "approve accumulated");
    }

    function test_approveZeroRevokes() public {
        vm.startPrank(deployer);
        token.approve(spender, 5);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, 0);
        token.approve(spender, 0);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
    }

    function test_approveSelfAndZeroAmountAreAllowed() public {
        vm.startPrank(alice);
        assertTrue(token.approve(alice, 0));
        assertTrue(token.approve(spender, 0));
        vm.stopPrank();
        assertEq(token.allowance(alice, alice), 0);
    }

    /// @dev Only the exact maximum is "infinite": one below it is a finite allowance and is spent.
    function test_maxMinusOneAllowanceIsDecremented() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, spender), type(uint256).max - 2);
    }

    function test_infiniteAllowanceSurvivesRepeatedPulls() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        token.transferFrom(deployer, bob, 1);
        token.transferFrom(deployer, bob, EXPECTED_SUPPLY - 1);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(bob), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_allowanceIsDirectional() public {
        vm.prank(deployer);
        token.approve(spender, 7);
        assertEq(token.allowance(spender, deployer), 0, "an allowance leaked in the other direction");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(spender, bob, 1);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_approveThenPullLeavesExactRemainder(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1); // finite
        amount = bound(amount, 0, allowed < EXPECTED_SUPPLY ? allowed : EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.allowance(deployer, spender), allowed - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
    }

    function testFuzz_chainOfTransfersConservesSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, EXPECTED_SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(deployer, c);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - a + c);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev Transfers to arbitrary non-zero addresses, the token contract and precompiles included,
    ///      all land whole: there is no receiver hook and no address is special.
    function testFuzz_anyNonZeroReceiverGetsExactly(uint160 seed, uint256 amount) public {
        address to = address(uint160(bound(uint256(seed), 1, type(uint160).max)));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        uint256 beforeTo = token.balanceOf(to);
        uint256 beforeFrom = token.balanceOf(deployer);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), beforeFrom);
        } else {
            assertEq(token.balanceOf(to), beforeTo + amount);
            assertEq(token.balanceOf(deployer), beforeFrom - amount);
        }
    }

    function testFuzz_zeroAddressIsNeverAValidReceiver(uint256 amount) public {
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), amount);
    }

    function testFuzz_unknownSelectorsRevert(bytes4 selector, bytes calldata args) public {
        // Skip the real ABI: everything else must be refused (no fallback, no receive).
        bytes4[9] memory known = [
            token.name.selector,
            token.symbol.selector,
            token.decimals.selector,
            token.totalSupply.selector,
            token.balanceOf.selector,
            token.transfer.selector,
            token.allowance.selector,
            token.approve.selector,
            token.transferFrom.selector
        ];
        bool isKnown;
        for (uint256 i = 0; i < known.length; i++) {
            if (selector == known[i]) isKnown = true;
        }
        if (
            selector == token.TOKEN_NAME.selector || selector == token.TOKEN_SYMBOL.selector
                || selector == token.DECIMALS.selector || selector == token.TOTAL_SUPPLY.selector
        ) isKnown = true;
        if (isKnown) return;
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "an unknown selector was accepted");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }
}
