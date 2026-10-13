// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CrawlHiveToken} from "../src/CrawlHiveToken.sol";
import {DeployCrawlHive} from "../script/DeployCrawlHive.s.sol";

/// @dev Stands in for the launch factory: deploys the token from its creation code with CREATE2
///      (as the factory does) and then pays the supply out. Lets the tests check that the deployer,
///      not the test contract, receives the mint.
contract FactoryStub {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "constructor failed");
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract CrawlHiveTokenTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 ether; // 1e9 * 1e18
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant POOL_BPS = 8_800;

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

    // ---------------------------------------------------------------- metadata & supply

    function test_metadata() public view {
        assertEq(token.name(), "CrawlHive");
        assertEq(token.symbol(), "CRAWLHIVE");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "CrawlHive");
        assertEq(token.TOKEN_SYMBOL(), "CRAWLHIVE");
        assertEq(token.DECIMALS(), 18);
    }

    function test_totalSupplyIsExactlyOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY, "deployer does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test contract must not receive anything");
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, EXPECTED_SUPPLY);
        vm.prank(alice);
        new CrawlHiveToken();
    }

    /// @dev The launch deploys the token with CREATE2 from a factory contract: the factory is
    ///      msg.sender of the constructor and must receive the whole supply.
    function test_create2DeploymentFromFactoryMintsToFactory() public {
        FactoryStub factory = new FactoryStub();
        bytes memory code = type(CrawlHiveToken).creationCode;
        bytes32 salt = bytes32(uint256(42));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );

        address deployed = factory.deploy(code, salt);
        assertEq(deployed, predicted, "CREATE2 address mismatch");

        CrawlHiveToken launched = CrawlHiveToken(deployed);
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY, "factory does not hold the supply");
        assertEq(launched.balanceOf(address(this)), 0);
    }

    function test_deployScriptFunctionMintsToCaller() public {
        DeployCrawlHive script = new DeployCrawlHive();
        CrawlHiveToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(script)), EXPECTED_SUPPLY);
        assertEq(deployed.name(), "CrawlHive");
        assertEq(deployed.symbol(), "CRAWLHIVE");
    }

    // ---------------------------------------------------------------- transfers (success)

    function test_transferMovesExactAmountAndEmits() public {
        uint256 amount = 1_234 ether;
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));

        assertEq(token.balanceOf(alice), amount, "recipient received a different amount");
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "a transfer changed the supply");
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_secondaryTransfersAreUntaxed() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 60 ether);
        vm.prank(bob);
        token.transfer(alice, 10 ether);
        assertEq(token.balanceOf(alice), 50 ether);
        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------- transfers (failure)

    function test_RevertWhen_transferExceedsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 10 ether + 1)
        );
        vm.prank(alice);
        token.transfer(bob, 10 ether + 1);
    }

    function test_RevertWhen_transferFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1 ether);
    }

    // ---------------------------------------------------------------- allowances

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, 7 ether);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 7 ether));
        assertEq(token.allowance(deployer, spender), 7 ether);
    }

    function test_transferFromSpendsAllowanceExactly() public {
        vm.prank(deployer);
        token.approve(spender, 10 ether);

        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 4 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 4 ether));

        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 4 ether);
        assertEq(token.allowance(deployer, spender), 6 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
    }

    function test_RevertWhen_transferFromWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1 ether);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1 ether, 2 ether)
        );
        vm.prank(spender);
        token.transferFrom(deployer, bob, 2 ether);
    }

    function test_RevertWhen_transferFromExceedsBalanceEvenWithAllowance() public {
        vm.prank(alice);
        token.approve(spender, 5 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 5 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 5 ether);
    }

    function test_RevertWhen_approveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- launch flows (shape of the floor)

    /// @dev The swarm's 10% leaves the factory whole and is claimable whole; the pool share and the
    ///      remainder likewise arrive exactly. Nothing is taxed, nothing is burned, the supply holds.
    function test_launchFlowsMoveExactAmounts() public {
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainderTo = makeAddr("remainderTo");
        address claimant = makeAddr("claimant");

        uint256 swarm = (EXPECTED_SUPPLY * SWARM_BPS) / 10_000;
        uint256 poolShare = (EXPECTED_SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = EXPECTED_SUPPLY - swarm - poolShare;

        vm.startPrank(deployer);
        assertTrue(token.transfer(distributor, swarm));
        assertTrue(token.transfer(pool, poolShare));
        assertTrue(token.transfer(remainderTo, remainder));
        vm.stopPrank();

        assertEq(token.balanceOf(distributor), swarm, "the swarm's share arrived short");
        assertEq(token.balanceOf(pool), poolShare, "the pool seed arrived short");
        assertEq(token.balanceOf(remainderTo), remainder, "the remainder arrived short");
        assertEq(token.balanceOf(deployer), 0, "the factory kept something back");

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm, "a claim arrived short");
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "the launch flows changed the supply");
    }

    // ---------------------------------------------------------------- no privileged surface

    /// @dev Common mint / ownership / upgrade entry points do not exist: every call reverts, the
    ///      supply stays put, and the caller gets nothing. Tried from a stranger and from the deployer.
    function test_noAdminCallIncreasesSupply() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected entry point: ", signatures[i]));
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected entry point: ", signatures[i]));
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    /// @dev No pause, blocklist, freeze or seize: every such call reverts, the holder keeps its
    ///      balance and can still transfer afterwards, and the deployer cannot pull from the holder.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        uint256 held = EXPECTED_SUPPLY / 1_000;
        vm.prank(deployer);
        token.transfer(alice, held);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, true);
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected entry point: ", signatures[i]));
        }

        vm.prank(deployer);
        (bool moved,) = address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, alice, deployer, 1));
        assertFalse(moved, "the deployer pulled from a holder without allowance");
        assertEq(token.balanceOf(alice), held, "a privileged call moved the holder's balance");

        vm.prank(alice);
        assertTrue(token.transfer(bob, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(bob), held / 2);
    }

    function test_RevertWhen_callingUnknownFunction() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
    }

    function test_RevertWhen_sendingEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token must not accept ether");
        assertEq(address(token).balance, 0);
    }

    /// @dev The launch floor refuses DELEGATECALL, CALLCODE and SELFDESTRUCT in the runtime.
    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
            assertTrue(op != 0xF2, "runtime code contains CALLCODE");
            assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, EXPECTED_SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, amount)
        );
        vm.prank(deployer);
        token.transfer(alice, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);

        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
            vm.prank(spender);
            token.transferFrom(deployer, bob, amount);
        } else {
            vm.prank(spender);
            assertTrue(token.transferFrom(deployer, bob, amount));
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(deployer, spender), allowed - amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }
}
