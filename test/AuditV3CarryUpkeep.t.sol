// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";

contract ExhaustUpkeepGas {
    function upkeepStep(address) external pure {
        assembly ("memory-safe") { for {} 1 {} {} }
    }
}

contract AuditV3CarryUpkeepTest is BaseTest {
    function setUp() public override {
        super.setUp();
        graduatePvp();
    }

    function test_fiveWalletCarryChainOnlyPullsUnusedCapAtFinalize() public {
        vm.deal(address(this), 2 ether);
        pad.fundCarry{value: 1 ether}(); // permissionless, as the audit observed
        PadGame a = PadGame(pad.gameOf(pad.launch("A", "A", "")));
        mintAll(a, 5);
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        assertEq(a.fundedPot(), 0.005 ether, "king share retains v2 routing");
        advance(10 minutes);
        for (uint256 cycle; cycle < 3; ++cycle) {
            uint256 carryBefore = pad.carryPot();
            uint256 fundedBefore = a.fundedPot();
            PadGame b;
            for (uint256 round; round < 6; ++round) {
                if (round == 5) {
                    vm.warp(a.playStart() + 40 minutes);
                    arb.advance(2400);
                    b = PadGame(pad.gameOf(pad.launch("Next", "N", "")));
                    mintAll(b, 5);
                }
                vm.warp(a.playStart() + round * 9 minutes);
                arb.advance(5400);
                for (uint256 i; i < 5; ++i) {
                    rollAs(a, players[i]);
                }
            }
            vm.warp(a.hardEnd());
            arb.advance(3000);
            a.resolvePending(16);
            uint256 cap = a.fundedReleaseCap();
            uint256 unused = cap > fundedBefore ? cap - fundedBefore : 0;
            assertEq(pad.carryPot(), carryBefore, "nothing leaves carry during play");
            b.draw(1); // commit B immediately before A finalizes
            arb.advance(4);
            a.finalize(); // reproduces the audit: its upkeep completes B's five-wallet draw
            assertTrue(b.drawComplete());
            assertEq(b.fundedPot(), 0, "next five-wallet game cannot recapture carry");
            assertEq(a.livingAtEnd(), 5);
            assertGe(pad.carryPot(), carryBefore - unused, "only unused allowance leaves carry");
            assertLe(pad.carryPot(), carryBefore - unused + 10, "bounded rounding dust returns");
            assertEq(a.pot(), 0);
            assertEq(a.fundedPot(), 0);
            uint256 afterFinalize = pad.carryPot();
            vm.expectRevert(abi.encodeWithSignature("PadNotFinalizable()"));
            a.finalize();
            assertEq(pad.carryPot(), afterFinalize, "no second pull");
            a = b;
        }
        assertGt(pad.carryPot(), 0.97 ether, "the chain cannot park the full carry in any game");
        assertEq(address(pad).balance, pad.carryPot());
    }

    function test_fiveWalletNoRollChainNeverTakesCarry() public {
        vm.deal(address(this), 1 ether);
        pad.fundCarry{value: 1 ether}();
        uint256 carry = pad.carryPot();
        PadGame a = PadGame(pad.gameOf(pad.launch("Idle A", "A", "")));
        mintAll(a, 5);
        advance(10 minutes);
        PadGame b = PadGame(pad.gameOf(pad.launch("Idle B", "B", "")));
        mintAll(b, 5);
        vm.warp(b.signupEnd());
        b.draw(1);
        arb.advance(4);
        a.finalize();
        assertTrue(b.drawComplete());
        assertEq(a.livingAtEnd(), 0);
        assertEq(b.fundedPot(), 0);
        assertEq(pad.carryPot(), carry);
    }

    function _pendingForeign(uint256 phase) internal returns (PadGame entryGame, PadGame rollGame, PadGame foreign) {
        entryGame = PadGame(pad.gameOf(pad.launch("Entry", "E", "")));
        rollGame = PadGame(pad.gameOf(pad.launch("Roll", "R", "")));
        mintAll(rollGame, 1);
        advance(10 minutes);
        foreign = PadGame(pad.gameOf(pad.launch("Work", "W", "")));
        for (uint256 i; i < 200; ++i) {
            address who = address(uint160(0x987000 + i));
            vm.deal(who, 1 ether);
            vm.prank(who);
            foreign.enter{value: 0.001 ether}();
        }
        // Keep the local roller alive while the foreign signup runs.
        vm.warp(foreign.signupEnd() - 100);
        arb.advance(5000);
        rollAs(rollGame, players[0]);
        vm.warp(foreign.signupEnd());
        arb.advance(1000);
        foreign.draw(1);
        arb.advance(4);
        if (phase != 0) {
            while (!foreign.drawComplete()) foreign.draw(32);
            for (uint256 i; i < 200; ++i) {
                rollAs(foreign, foreign.getImp(i).owner);
            }
            arb.advance(4);
            while (foreign.pendingCount() != 0) foreign.resolvePending(16);
            // Fixture a bell after real paid rolls: all 200 Imps live at this end.
            uint256 clocks = uint256(foreign.firstEntryAt()) | (uint256(vm.getBlockTimestamp()) << 64)
                | (uint256(foreign.maxActivity()) << 128);
            vm.store(address(foreign), bytes32(uint256(8)), bytes32(clocks));
            vm.store(address(foreign), bytes32(uint256(9)), bytes32(uint256(uint160(foreign.getImp(0).owner))));
            assertTrue(foreign.ended());
            if (phase == 2) foreign.finalize();
        }
        // After entryGame's first entry the older round-robin slot points at foreign.
        while (pad.upkeepCursor() != 2) pad.upkeep{gas: 200_000}();
    }

    /// @dev Local gas estimation by snapshot/replay, with no RPC. Search a range below optional upkeep
    /// stipends; this measures the user's own work plus pad traversal, regardless of pending work.
    function _ownGasEstimate(PadGame g, address actor, bool entry) internal returns (uint256 high) {
        uint256 low = 30_000;
        high = 500_000;
        bytes memory data = entry ? abi.encodeCall(PadGame.enter, ()) : abi.encodeCall(PadGame.roll, ());
        uint256 value = entry ? 0.001 ether : 0.002 ether;
        while (high - low > 1000) {
            uint256 snap = vm.snapshotState();
            uint256 mid = (low + high) / 2;
            vm.prank(actor);
            (bool ok,) = address(g).call{gas: mid, value: value}(data);
            vm.revertToState(snap);
            if (ok) high = mid;
            else low = mid;
        }
        // Include ordinary estimator rounding headroom, not a foreign lifecycle stipend.
        high += 10_000;
    }

    function _assertOwnActionsSucceed(uint256 phase) internal {
        vm.pauseGasMetering();
        (PadGame entryGame, PadGame rollGame, PadGame foreign) = _pendingForeign(phase);
        vm.resumeGasMetering();
        uint256 entryGas = _ownGasEstimate(entryGame, players[10], true);
        uint256 rollGas = _ownGasEstimate(rollGame, players[0], false);
        vm.prank(players[10]);
        entryGame.enter{gas: entryGas, value: 0.001 ether}();
        vm.prank(players[0]);
        rollGame.roll{gas: rollGas, value: 0.002 ether}();
        assertEq(entryGame.entryCount(), 1);
        assertEq(rollGame.rollCount(), 2);
        assertLt(entryGas, 500_000);
        assertLt(rollGas, 500_000);
        emit log_named_uint("own entry gas limit", entryGas);
        emit log_named_uint("own roll gas limit", rollGas);
        if (phase == 0) assertFalse(foreign.drawSeeded(), "heavy draw skipped");
        if (phase == 1) assertFalse(foreign.finalized(), "heavy finalize skipped");
        if (phase == 2) assertFalse(foreign.graduated(), "heavy graduation skipped");
    }

    function test_ownGasEstimateEntryAndRollWithForeignDraw() public {
        _assertOwnActionsSucceed(0);
    }

    function test_ownGasEstimateEntryAndRollWithForeignFinalize() public {
        _assertOwnActionsSucceed(1);
    }

    function test_ownGasEstimateEntryAndRollWithForeignGraduate() public {
        _assertOwnActionsSucceed(2);
    }

    function test_upkeepSubcallCanExhaustItsFullStipendWithoutRevertingEntry() public {
        (PadGame entryGame,, PadGame foreign) = _pendingForeign(0);
        ExhaustUpkeepGas eater = new ExhaustUpkeepGas();
        vm.etch(address(foreign), address(eater).code);
        vm.prank(players[10]);
        entryGame.enter{gas: 5_100_000, value: 0.001 ether}();
        assertEq(entryGame.entryOf(players[10]), 1);
    }
}
