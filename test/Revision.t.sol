// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {PoolKey} from "../src/interfaces/Interfaces.sol";
import {TickMath} from "../lib/v4-core/src/libraries/TickMath.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev A former king that first refuses ETH (so its fees park as a PadLiquidity claimable), then claims
/// them and bids for the crown from inside the claim callback (revision finding e2ea0e40).
contract ClaimBidder {
    KingOfThePad immutable king;
    PadLiquidity immutable liq;
    bool public reject = true;
    uint256 public bidAmount;

    constructor(KingOfThePad king_, PadLiquidity liq_) {
        king = king_;
        liq = liq_;
    }

    function setReject(bool r) external {
        reject = r;
    }

    function bid(uint256 v) external {
        king.takeCrown{value: v}();
    }

    function attack(uint256 v) external {
        bidAmount = v;
        liq.claim();
    }

    receive() external payable {
        if (reject) revert("no");
        if (bidAmount != 0) {
            uint256 v = bidAmount;
            bidAmount = 0;
            king.takeCrown{value: v}();
        }
    }
}

contract RevisionTest is BaseTest {
    event Seated(address indexed owner, uint256 indexed imp, uint256 indexed entry);

    // ---- e2ea0e40: crown taken from inside PadLiquidity.claim -----------------------------------
    function test_outgoingKingIsPaidEvenWhenTheBidComesFromInsideLiquidityClaim() public {
        graduatePvp();
        ClaimBidder thief = new ClaimBidder(king, liq);
        vm.deal(address(thief), 1 ether);
        thief.bid(0.01 ether);
        donateFees(liq.poolKey(address(pvpToken)), 0.1 ether, 0);
        liq.distribute(1);
        assertGt(liq.claimable(address(thief)), 0, "fees parked as claimable");
        vm.warp(king.challengeOpensAt());
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether}();
        donateFees(liq.poolKey(address(pvpToken)), 0.2 ether, 0);
        vm.warp(king.challengeOpensAt());
        thief.setReject(false);
        uint256 before = players[9].balance;
        thief.attack(0.0121 ether);
        assertEq(king.king(), address(thief), "the bid itself is valid");
        assertGe(players[9].balance - before, 0.011 ether + 0.2 ether - 1e12, "refund plus the fees of the reign");
        assertEq(liq.claimable(address(thief)), 0);
    }

    function test_takeCrownRevertsInsteadOfSkippingTheOutgoingKingWhileLiquidityIsLocked() public {
        graduatePvp();
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        vm.warp(king.challengeOpensAt());
        vm.mockCallRevert(
            address(liq),
            abi.encodeWithSelector(PadLiquidity.settleCrown.selector),
            abi.encodeWithSignature("PadReentrancy()")
        );
        vm.prank(players[9]);
        vm.expectRevert(abi.encodeWithSignature("PadReentrancy()"));
        king.takeCrown{value: 0.011 ether}();
        assertEq(king.king(), players[8]);
        vm.clearMockedCalls();
        // Every distributor failure now vetoes a bid.
        vm.mockCallRevert(address(liq), abi.encodeWithSelector(PadLiquidity.settleCrown.selector), bytes("pool"));
        vm.prank(players[9]);
        vm.expectRevert(bytes("pool"));
        king.takeCrown{value: 0.011 ether}();
        assertEq(king.king(), players[8]);
    }

    function test_liquidityClaimLockIsSeparateFromThePoolGuard() public {
        graduatePvp();
        ClaimBidder c = new ClaimBidder(king, liq);
        vm.deal(address(c), 1 ether);
        c.bid(0.01 ether);
        donateFees(liq.poolKey(address(pvpToken)), 0.05 ether, 0);
        liq.distribute(1);
        uint256 owed = liq.claimable(address(c));
        assertGt(owed, 0);
        c.setReject(false);
        vm.prank(address(c));
        liq.claim();
        assertEq(liq.claimable(address(c)), 0);
        vm.prank(address(c));
        vm.expectRevert(abi.encodeWithSignature("PadNothing()"));
        liq.claim();
    }

    // ---- 22ea8fdb: funded release cap versus a sole-buyer token dump ------------------------------
    function test_soleBuyerSybilLosesMoneyEvenAfterDumpingEveryTokenAndTakingTheCappedRelease() public {
        graduatePvp();
        PadGame g = PadGame(pad.gameOf(pad.launch("Bot", "BOT", "")));
        // a large funded pot (king share / carry) sits in the game before the sybil's five wallets play
        vm.deal(address(pad), address(pad).balance + 5 ether);
        vm.prank(address(pad));
        g.fundPot{value: 5 ether}();
        uint256 spent;
        uint256[5] memory before;
        for (uint256 i; i < 5; ++i) {
            before[i] = players[i].balance;
        }
        vm.pauseGasMetering();
        mintAll(g, 5);
        advance(10 minutes);
        for (uint256 r; r < 49; ++r) {
            for (uint256 i; i < 5; ++i) {
                if (g.ended()) break;
                rollAs(g, players[i]);
            }
            advance(61);
        }
        while (!g.ended()) advance(60);
        advance(5);
        g.poke();
        if (!g.finalized()) g.finalize();
        vm.resumeGasMetering();
        if (!g.graduated()) graduateGame(g);
        assertEq(g.livingAtEnd(), 5, "all five sybil Imps living at the end");
        uint256 raised = g.ethRaised();
        assertGt(raised, 0.4 ether);
        // dump every token the sybil holds into the real pool
        PadToken t = PadToken(g.token());
        PoolKey memory key = liq.poolKey(address(t));
        for (uint256 i; i < 5; ++i) {
            uint256 bal = t.balanceOf(players[i]);
            vm.prank(players[i]);
            t.transfer(address(router), bal);
            router.trade(key, false, bal);
        }
        uint256 dump = address(router).balance;
        uint256 back = dump;
        for (uint256 i; i < 5; ++i) {
            spent += before[i] - players[i].balance; // net of what the game paid this wallet back
        }
        // `spent` is already net of payouts: a profitable attack would make it negative, i.e. revert above
        assertLt(back, spent, "dump plus capped release plus roll pot never reach what the sybil paid");
        assertLe(5 ether - pad.carryPot(), raised * 15 / 100 + 1, "release never above 15% of the curve ETH");
        emit log_named_uint("curve ETH raised", raised);
        emit log_named_uint("sybil net outlay before the dump", spent);
        emit log_named_uint("dump proceeds", back);
    }

    // ---- 1d6515bf: carry never parked in a launch nobody enters ---------------------------------
    function test_carryStaysInPadEvenAfterFiveSeats() public {
        graduatePvp();
        vm.deal(address(this), 1 ether);
        pad.fundCarry{value: 0.4 ether}();
        uint256 carry = pad.carryPot();
        address griefer = address(0xBAD);
        vm.prank(griefer);
        PadGame junk = PadGame(pad.gameOf(pad.launch("junk", "J", "")));
        assertEq(pad.carryPot(), carry, "a free launch moves nothing");
        assertEq(address(junk).balance, 0);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        pad.upkeep();
        assertEq(pad.carryPot(), carry);
        // a one-entry game completes its draw but is too small to ever release funded ETH: no carry
        PadGame small = PadGame(pad.gameOf(pad.launch("small", "S", "")));
        mintAll(small, 1);
        advance(10 minutes);
        assertTrue(small.drawComplete());
        assertEq(pad.carryPot(), carry, "fewer than five seats never take the carry");
        assertEq(small.fundedPot(), 0);
        // Even a five-seat game leaves carry in the pad at draw completion
        PadGame real = PadGame(pad.gameOf(pad.launch("real", "R", "")));
        mintAll(real, 5);
        vm.warp(real.signupEnd());
        real.draw(32); // commit
        arb.advance(4);
        real.draw(32); // seed, five seats, play starts without taking carry
        assertTrue(real.drawComplete());
        assertEq(pad.carryPot(), carry);
        assertEq(real.fundedPot(), 0);
        assertEq(address(pad).balance, carry);
    }

    event CarryPaid(uint256 indexed id, uint256 amount);

    function test_takeCarryAndNoteFirstEntryAreGameOnly() public {
        graduatePvp();
        vm.expectRevert(abi.encodeWithSignature("PadNotGame()"));
        pad.takeCarry(1, 1 ether);
        vm.expectRevert(abi.encodeWithSignature("PadNotGame()"));
        pad.noteFirstEntry(1);
        uint256 id = pad.launch("X", "X", "");
        vm.prank(pad.gameOf(1));
        vm.expectRevert(abi.encodeWithSignature("PadNotGame()"));
        pad.takeCarry(id, 1 ether);
    }

    function test_freeLaunchesDoNotCrowdEnteredGamesOutOfTheKingWindowOrUpkeep() public {
        graduatePvp();
        PadGame live = PadGame(pad.gameOf(pad.launch("Live", "L", "")));
        mintAll(live, 5);
        assertEq(pad.enteredCount(), 2);
        assertEq(pad.enteredAt(1), live.launchId());
        for (uint256 i; i < 12; ++i) {
            vm.prank(address(0xBAD));
            pad.launch("junk", "J", "");
        }
        assertEq(pad.launchCount(), 14);
        assertEq(pad.enteredCount(), 2, "free launches are not entered launches");
        vm.prank(players[8]);
        king.takeCrown{value: 1 ether}();
        assertEq(live.fundedPot(), 0.5 ether, "the entered live game still receives the king's share");
        // upkeep tends the entered game even though twelve newer launches exist
        vm.warp(live.signupEnd());
        arb.advance(40 * 60 * 4);
        pad.upkeep();
        assertTrue(live.drawCommitted(), "upkeep reached the entered game");
        arb.advance(4);
        while (!live.drawComplete()) pad.upkeep();
        assertTrue(live.drawComplete());
    }

    // ---- 9ce6a613: 1-based event indexes --------------------------------------------------------
    function test_seatedEventUsesTheSameOneBasedIndexesAsTheViews() public {
        openPad();
        mintAll(pvp, 1);
        (uint256 entry,,) = pvp.myEntry();
        assertEq(entry, 0, "views are per caller");
        assertEq(pvp.entryOf(players[0]), 1);
        vm.warp(pvp.signupEnd());
        pvp.draw(32);
        arb.advance(4);
        vm.expectEmit(true, true, true, true);
        emit Seated(players[0], 1, 1);
        pvp.draw(32);
        assertEq(pvp.impOf(players[0]), 1);
    }

    // ---- 561f5bd6: full-range sqrt price constants ----------------------------------------------
    function test_fullRangeSqrtPriceConstantsMatchTickMath() public view {
        assertEq(uint256(liq.SQRT_MIN_FULL()), uint256(TickMath.getSqrtPriceAtTick(-887_200)));
        assertEq(uint256(liq.SQRT_MAX_FULL()), uint256(TickMath.getSqrtPriceAtTick(887_200)));
    }
}
