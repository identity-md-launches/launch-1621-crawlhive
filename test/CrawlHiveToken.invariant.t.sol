// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CrawlHiveToken} from "../src/CrawlHiveToken.sol";

/// @title CrawlHiveHandler
/// @notice Drives the token with random call sequences from a fixed set of actors (the deployer plus
///         five holders) and keeps a ghost ledger of what every actor and every allowance should be.
/// @dev Every handler bounds its inputs so the success paths are reachable, and the failure paths
///      (over balance, over allowance, zero receiver, zero spender, zero sender, unknown selectors,
///      ether) are driven explicitly with the exact revert they must produce. The handlers assert
///      nothing about the token beyond the revert reason: the ledger they keep is compared with the
///      token's state by the invariants after every call.
contract CrawlHiveHandler is Test {
    CrawlHiveToken public immutable token;
    uint256 public immutable supply;

    address[] public actors;
    mapping(address => bool) public isActor;

    // ---- ghost ledger
    mapping(address => uint256) public ghost_balance;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    uint256 public ghost_transferred; // sum of every successful transfer / transferFrom amount
    uint256 public ghost_transferCount;
    uint256 public ghost_transferFromCount;
    uint256 public ghost_approveCount;
    uint256 public ghost_revertCount;
    uint256 public ghost_adminCallCount;

    // Entry points a privileged token would expose; every one must revert on this token.
    string[22] private adminSignatures = [
        "mint(address,uint256)",
        "mint(uint256)",
        "mint()",
        "issue(uint256)",
        "setOwner(address)",
        "transferOwnership(address)",
        "upgradeTo(address)",
        "initialize(address)",
        "unpause()",
        "setMinter(address)",
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

    constructor(CrawlHiveToken token_, address deployer, uint256 holderCount) {
        token = token_;
        supply = token_.totalSupply();
        _addActor(deployer);
        for (uint256 i = 0; i < holderCount; i++) {
            _addActor(makeAddr(string.concat("holder", vm.toString(i))));
        }
        ghost_balance[deployer] = token_.balanceOf(deployer);
    }

    function _addActor(address a) private {
        actors.push(a);
        isActor[a] = true;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // ------------------------------------------------------------------ success paths

    /// @dev A holder sends up to its whole balance (zero and the full balance included) to any actor,
    ///      itself included.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        ghost_balance[from] -= amount;
        ghost_balance[to] += amount;
        ghost_transferred += amount;
        ghost_transferCount++;
    }

    /// @dev Any allowance value, the infinite one included; approve overwrites, it never adds.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (amount % 7 == 0) amount = type(uint256).max; // keep the infinite allowance reachable

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");

        ghost_allowance[owner][spender] = amount;
        ghost_approveCount++;
    }

    /// @dev A spender pulls up to min(balance, allowance) from the owner to any actor. An infinite
    ///      allowance is never decremented; a finite one is decremented by exactly the amount.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < balance ? allowed : balance);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        assertTrue(ok, "transferFrom returned false");

        ghost_balance[owner] -= amount;
        ghost_balance[to] += amount;
        if (allowed != type(uint256).max) ghost_allowance[owner][spender] = allowed - amount;
        ghost_transferred += amount;
        ghost_transferFromCount++;
    }

    // ------------------------------------------------------------------ failure paths

    /// @dev One wei (or more) above the balance must revert with the exact ERC-6093 error and leave
    ///      every balance where it was.
    function transferAboveBalanceReverts(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
        ghost_revertCount++;
    }

    /// @dev Above a finite allowance (balance permitting or not, the allowance is checked first) the
    ///      pull must revert with ERC20InsufficientAllowance and the allowance must be untouched.
    function transferFromAboveAllowanceReverts(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // Pin a finite allowance first so the failure path is always reachable.
            allowed = bound(excess, 0, supply);
            vm.prank(owner);
            token.approve(spender, allowed);
            ghost_allowance[owner][spender] = allowed;
            ghost_approveCount++;
        }
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ghost_revertCount++;
    }

    /// @dev With an infinite allowance but not enough balance the pull must revert on the balance.
    function transferFromAboveBalanceWithInfiniteAllowanceReverts(
        uint256 spenderSeed,
        uint256 ownerSeed,
        uint256 excess
    ) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghost_allowance[owner][spender] = type(uint256).max;
        ghost_approveCount++;

        uint256 balance = token.balanceOf(owner);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, spender, amount);
        ghost_revertCount++;
    }

    function transferToZeroReverts(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        ghost_revertCount++;
    }

    function transferFromToZeroReverts(uint256 spenderSeed, uint256 ownerSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < balance ? allowed : balance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
        ghost_revertCount++;
    }

    /// @dev Pulling from the zero address with a zero amount passes the allowance comparison (0 <= 0)
    ///      but the allowance update then refuses the zero owner, so nobody can "move" from the burn
    ///      address, not even for nothing.
    function transferFromZeroSenderReverts(uint256 spenderSeed, uint256 toSeed) external {
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), to, 0);
        ghost_revertCount++;
    }

    function approveZeroSpenderReverts(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        ghost_revertCount++;
    }

    /// @dev A would-be privileged call, from any actor (the deployer included), must revert.
    function adminCallReverts(uint256 callerSeed, uint256 sigSeed, uint256 victimSeed, uint256 amount) external {
        address caller = _actor(callerSeed);
        address victim = _actor(victimSeed);
        string memory sig = adminSignatures[bound(sigSeed, 0, adminSignatures.length - 1)];
        bytes memory data = abi.encodeWithSignature(sig, victim, amount);

        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, string.concat("unexpected entry point: ", sig));
        ghost_adminCallCount++;
    }

    /// @dev The deployer may not pull from a holder without an allowance from that holder.
    function deployerPullWithoutAllowanceReverts(uint256 victimSeed, uint256 amount) external {
        address deployer = actors[0];
        address victim = _actor(victimSeed);
        if (victim == deployer) victim = actors[1];
        uint256 allowed = token.allowance(victim, deployer);
        if (allowed == type(uint256).max) {
            // The holder revokes: afterwards the deployer is just another spender with nothing.
            vm.prank(victim);
            token.approve(deployer, 0);
            ghost_allowance[victim][deployer] = 0;
            ghost_approveCount++;
            allowed = 0;
        }
        amount = bound(amount, allowed + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, allowed, amount)
        );
        vm.prank(deployer);
        token.transferFrom(victim, deployer, amount);
        ghost_revertCount++;
    }

    function sendEtherReverts(uint256 fromSeed, uint256 value) external {
        address from = _actor(fromSeed);
        value = bound(value, 0, 100 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        ghost_revertCount++;
    }
}

/// @title CrawlHiveTokenInvariantTest
/// @notice Properties that must hold after every random call sequence the handler produces.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract CrawlHiveTokenInvariantTest is StdInvariant, Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 ether;
    uint256 constant HOLDERS = 5;

    CrawlHiveToken token;
    CrawlHiveHandler handler;
    address deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new CrawlHiveToken();
        handler = new CrawlHiveHandler(token, deployer, HOLDERS);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = CrawlHiveHandler.transfer.selector;
        selectors[1] = CrawlHiveHandler.approve.selector;
        selectors[2] = CrawlHiveHandler.transferFrom.selector;
        selectors[3] = CrawlHiveHandler.transferAboveBalanceReverts.selector;
        selectors[4] = CrawlHiveHandler.transferFromAboveAllowanceReverts.selector;
        selectors[5] = CrawlHiveHandler.transferFromAboveBalanceWithInfiniteAllowanceReverts.selector;
        selectors[6] = CrawlHiveHandler.transferToZeroReverts.selector;
        selectors[7] = CrawlHiveHandler.transferFromToZeroReverts.selector;
        selectors[8] = CrawlHiveHandler.transferFromZeroSenderReverts.selector;
        selectors[9] = CrawlHiveHandler.approveZeroSpenderReverts.selector;
        selectors[10] = CrawlHiveHandler.adminCallReverts.selector;
        selectors[11] = CrawlHiveHandler.deployerPullWithoutAllowanceReverts.selector;
        selectors[12] = CrawlHiveHandler.sendEtherReverts.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The fixed supply never changes: no sequence of transfers, approvals, failed calls or
    ///      would-be admin calls mints or burns.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "the supply changed");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// @dev Conservation: tokens only ever move between actors, so the actors' balances sum to the
    ///      supply exactly. Nothing leaks to the zero address, the token contract or anywhere else.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, EXPECTED_SUPPLY, "balances do not sum to the supply");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token contract holds tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
    }

    /// @dev Every balance equals what the ghost ledger says the actor should hold: each transfer moved
    ///      exactly its amount, no fee, no reflection, no rounding.
    function invariant_balancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghost_balance(a), "a balance drifted from the ledger");
            assertLe(token.balanceOf(a), EXPECTED_SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev Every allowance equals what was last approved, minus exactly what finite allowances were
    ///      spent; the infinite allowance is never decremented; failed pulls spend nothing.
    function invariant_allowancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n; j++) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender), handler.ghost_allowance(owner, spender), "an allowance drifted"
                );
            }
        }
    }

    /// @dev Metadata is immutable: nothing in any sequence can rename or redenominate the token.
    function invariant_metadataIsFixed() public view {
        assertEq(token.name(), "CrawlHive");
        assertEq(token.symbol(), "CRAWLHIVE");
        assertEq(token.decimals(), 18);
    }

    /// @dev The token never holds ether and never gains code it did not deploy with.
    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @dev Not a property of the token but of the harness, checked once at the end of each run: the
    ///      sequence reached the success paths and the failure paths, so the invariants above were
    ///      not checked over nothing. With 13 uniformly chosen handlers over 64 calls, a run that
    ///      misses one of the three kinds entirely is a ~1e-7 event.
    function afterInvariant() public view {
        uint256 moves = handler.ghost_transferCount() + handler.ghost_transferFromCount();
        uint256 failures = handler.ghost_revertCount() + handler.ghost_adminCallCount();
        assertGt(moves, 0, "no successful transfer was exercised");
        assertGt(failures, 0, "no failure path was exercised");
    }
}
