// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";

/// @notice Boundary and adversarial edges of the seat raffle and the play clock that the main suites
/// do not pin to the exact second or to the exact count.
contract RaffleEdgesTest is BaseTest {
    function setUp() public override {
        super.setUp();
        openPad();
    }

    function _wallet(uint256 i) internal pure returns (address) {
        return address(uint160(0x200000 + i));
    }

    function _enterMany(PadGame game, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            address who = _wallet(i);
            vm.deal(who, 0.001 ether);
            vm.prank(who);
            game.enter{value: 0.001 ether}();
        }
    }

    function _drawAll(PadGame game, uint256 chunk) internal {
        vm.warp(game.signupEnd());
        game.draw(chunk);
        arb.advance(4);
        while (!game.drawComplete()) {
            game.draw(chunk);
        }
    }

    // ---- above 200 entries: exactly 200 distinct seats, whatever the hashes or the chunking ----------
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_above200ExactlyTwoHundredDistinctSeats(uint16 count, uint32 l2Block, uint8 chunk) public {
        uint256 n = bound(count, 201, 420);
        uint256 c = bound(chunk, 1, 40);
        _enterMany(pvp, n);
        arb.set(uint256(l2Block) + 300);
        _drawAll(pvp, c);

        (uint256 entries, uint256 seated, uint256 target,, bool seeded, bool complete) = pvp.drawProgress();
        assertEq(entries, n);
        assertEq(seated, 200);
        assertEq(target, 200);
        assertTrue(seeded && complete);
        assertEq(pvp.impCount(), 200);

        // Every seat belongs to a distinct entrant and the two indexes agree in both directions.
        uint256 holders;
        for (uint256 i; i < n; ++i) {
            uint256 seat = pvp.impOf(_wallet(i));
            if (seat == 0) continue;
            ++holders;
            assertLe(seat, 200);
            assertEq(pvp.getImp(seat - 1).owner, _wallet(i));
        }
        assertEq(holders, 200, "200 distinct entrants hold the 200 seats");
        for (uint256 s; s < 200; ++s) {
            address who = pvp.getImp(s).owner;
            assertEq(pvp.impOf(who), s + 1);
            assertTrue(pvp.entryOf(who) != 0 && pvp.entryOf(who) <= n, "seat holders are entrants");
        }
        // All but the first fee burn; the first fee paid the seed capturer. Nothing is refundable.
        assertEq(liq.burnBucket(), (n - 1) * 0.001 ether);
        assertEq(address(pvp).balance, 0);
    }

    // ---- unselected entrant: views and gates after the draw -----------------------------------------
    function test_unselectedEntrantKeepsEntryHasNoSeatAndCannotRollOrReenter() public {
        _enterMany(pvp, 201);
        vm.warp(pvp.signupEnd());
        assertEq(pvp.status(), 7, "drawing phase before the commit");
        // Entry closes at the exact second signup ends, even before the draw has started.
        vm.deal(_wallet(999), 0.001 ether);
        vm.prank(_wallet(999));
        vm.expectRevert(abi.encodeWithSignature("PadSignupOver()"));
        pvp.enter{value: 0.001 ether}();
        pvp.draw(32);
        assertEq(pvp.status(), 7, "drawing phase while committed");
        arb.advance(4);
        while (!pvp.drawComplete()) {
            pvp.draw(32);
        }
        assertEq(pvp.status(), 2);

        address loser;
        for (uint256 i; i < 201; ++i) {
            if (pvp.impOf(_wallet(i)) == 0) {
                loser = _wallet(i);
                break;
            }
        }
        assertTrue(loser != address(0), "exactly one of 201 is left out");
        vm.startPrank(loser);
        (uint256 entry, uint256 seat, bool complete) = pvp.myEntry();
        assertTrue(entry != 0 && seat == 0 && complete);
        vm.deal(loser, 0.003 ether);
        vm.expectRevert(abi.encodeWithSignature("PadNoImp()"));
        pvp.roll{value: 0.002 ether}();
        vm.expectRevert(abi.encodeWithSignature("PadOneEntryPerWallet()"));
        pvp.enter{value: 0.001 ether}();
        vm.stopPrank();
        assertEq(pvp.claimable(loser), 0, "nothing to refund");
        assertFalse(pvp.isAlive(200), "no seat 200");
    }

    // ---- death clock: exactly 10 minutes from play start for an Imp that never rolled ---------------
    function test_deathAtExactlyTenMinutesFromPlayStartAndAllDeadEndsTheGame() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        uint256 start = pvp.playStart();
        assertEq(start, vm.getBlockTimestamp());
        advance(60);
        rollAs(pvp, players[0]);
        uint256 idle = pvp.impOf(players[1]) - 1;

        vm.warp(start + 10 minutes - 1);
        assertTrue(pvp.isAlive(idle));
        vm.warp(start + 10 minutes);
        assertFalse(pvp.isAlive(idle), "dead at exactly playStart + 10 minutes");
        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSignature("PadImpDead()"));
        pvp.roll{value: 0.002 ether}();
        // The roller is still alive, so the game is not over yet.
        assertFalse(pvp.ended());
        assertEq(pvp.endTime(), start + 60 + 10 minutes, "last activity + 10 minutes");
        assertEq(pvp.status(), 2);
        vm.warp(start + 60 + 10 minutes - 1);
        assertFalse(pvp.ended());
        vm.warp(start + 60 + 10 minutes);
        assertFalse(pvp.isAlive(pvp.impOf(players[0]) - 1));
        // All dead ends the game on the clock even while the roll is still pending.
        assertTrue(pvp.ended());
        assertEq(pvp.status(), 3);
        vm.expectRevert(abi.encodeWithSignature("PadNotFinalizable()"));
        pvp.finalize();
        arb.advance(4);
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 0);
        assertEq(address(pvp).balance, pvp.ethRaised() + gameReserves(pvp), "the whole pot left for the carry");
    }

    // ---- hard end: a roll one second before the 50-minute cap works, at the cap it is refused ------
    function test_rollOneSecondBeforeHardEndWorksAndAtHardEndReverts() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        uint256 start = pvp.playStart();
        assertEq(pvp.hardEnd(), start + 50 minutes);
        for (uint256 i; i < 9; ++i) {
            rollAs(pvp, players[0]);
            advance(5 minutes);
        }
        advance(5 minutes - 1);
        assertEq(vm.getBlockTimestamp(), start + 50 minutes - 1);
        assertFalse(pvp.ended());
        rollAs(pvp, players[0]);
        advance(1);
        assertTrue(pvp.ended());
        assertEq(pvp.endTime(), pvp.hardEnd());
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadGameOver()"));
        pvp.roll{value: 0.002 ether}();
        // Ten rolls were accepted in all, each at the exact roll price.
        assertEq(pvp.rollCount(), 10);
        assertEq(
            pvp.ethRaised() + pvp.pot() + gameReserves(pvp),
            10 * 0.002 ether,
            "genesis keeps every wei on the curve or in the pot"
        );
    }

    // ---- king share to a game that is live by entries only, returned when nobody plays -------------
    function test_kingFundsSignupGameByEntriesAndFundedEthReturnsToCarryWhenNobodyRolls() public {
        graduatePvp();
        uint256 carryBefore = pad.carryPot();
        vm.prank(players[6]);
        uint256 id = pad.launch("Entries Only", "ENT", "");
        PadGame game = PadGame(pad.gameOf(id));
        // Carry stays in the pad until an eligible finalization:
        // a launch nobody enters never custodies it.
        assertEq(game.fundedPot(), 0, "a fresh launch holds no carry");
        assertEq(pad.carryPot(), carryBefore, "launching moves nothing out of the carry pot");

        mintAll(game, 4);
        vm.deal(players[7], 2 ether);
        vm.prank(players[7]);
        king.takeCrown{value: 1 ether}();
        // Four entries: not live for the king, the games share went to the carry pot instead.
        assertEq(pad.carryPot(), carryBefore + 0.5 ether);
        assertEq(game.fundedPot(), 0);

        vm.prank(players[4]);
        game.enter{value: 0.001 ether}();
        (bool live, uint256 weight) = game.isLiveForKing();
        assertTrue(live, "five entries make a signup game live");
        assertEq(weight, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.deal(players[8], 2 ether);
        vm.prank(players[8]);
        king.takeCrown{value: 1.1 ether}();
        assertEq(game.fundedPot(), 0.05 ether, "half of the 0.1 ETH extra reached the signup game");
        assertEq(game.pot(), 0.05 ether);
        // The hold hour passed signup; the bid's upkeep already committed the draw of this game.
        assertEq(game.status(), 7);
        assertTrue(game.drawCommitted());
        uint256 carryWaiting = pad.carryPot();
        assertEq(carryWaiting, carryBefore + 0.5 ether, "the carry still waits in the pad while drawing");

        // The draw seats all five without moving any carry.
        arb.advance(4);
        while (!game.drawComplete()) {
            game.draw(32);
        }
        assertEq(game.impCount(), 5);
        assertEq(pad.carryPot(), carryWaiting, "a five-seat draw leaves carry in pad");
        uint256 funded = game.fundedPot();
        assertEq(funded, 0.05 ether, "only king share is funded ETH during play");
        assertEq(game.pot(), funded, "nobody rolled: the pot is funded ETH only");
        // Nobody rolls; the game ends with no living Imps.
        vm.warp(game.playStart() + 10 minutes);
        assertTrue(game.ended());
        uint256 carryPending = pad.carryPot();
        game.finalize();
        assertEq(game.pot(), 0);
        assertEq(game.fundedPot(), 0);
        assertEq(game.livingAtEnd(), 0);
        assertEq(pad.carryPot(), carryPending + funded, "every funded wei returned to the carry pot");
        assertEq(address(game).balance, 0);
        for (uint256 i; i < 5; ++i) {
            assertEq(game.claimable(players[i]), 0);
        }
        // No roll means the launch fails on graduation and burns its supply; entry fees stay burned.
        graduateGame(game);
        assertTrue(game.failed());
        assertFalse(pad.genesisFailed(), "a failed ordinary launch never touches the genesis");
    }

    // ---- draw is permissionless and idempotent across repeated callers in one block ----------------
    function test_repeatedDrawCallsInOneBlockOnlyAdvanceAfterSeedAndNeverSeatTwice() public {
        _enterMany(pvp, 300);
        vm.warp(pvp.signupEnd());
        pvp.draw(32);
        uint256 commit = pvp.drawCommitBlock();
        // Calls inside the commit window neither recommit nor seat anyone.
        for (uint256 i; i < 3; ++i) {
            arb.advance(1);
            pvp.draw(32);
            assertEq(pvp.drawCommitBlock(), commit);
            assertFalse(pvp.drawSeeded());
            assertEq(pvp.impCount(), 0);
        }
        arb.advance(1);
        pvp.draw(5);
        assertTrue(pvp.drawSeeded());
        assertLe(pvp.impCount(), 5);
        uint256 nonceAfterFive = pvp.drawNonce();
        assertGe(nonceAfterFive, pvp.impCount(), "every seat costs at least one trial");
        while (!pvp.drawComplete()) {
            pvp.draw(32);
        }
        assertEq(pvp.impCount(), 200);
        uint256 nonceDone = pvp.drawNonce();
        pvp.draw(32);
        pvp.poke();
        assertEq(pvp.drawNonce(), nonceDone, "no trials after completion");
        assertEq(pvp.impCount(), 200);
    }
}
