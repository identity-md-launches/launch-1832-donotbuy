// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {PadLib} from "../src/libs/PadLib.sol";
import {PoolKey} from "../src/interfaces/Interfaces.sol";
import {V4Router} from "./RealV4.sol";
import {Rejector} from "./mocks/Mocks.sol";
import {TestIMD} from "./V4Pad.t.sol";

/// @notice Failure paths and boundaries of the v4 changes that the main v4 suite does not pin:
/// zero-coin and boundary bail-outs, bail-outs after the bell and after the hard end, expired pending
/// rolls of erased seats, a near-cap erased seat that cannot ring, the king's split ignoring erased
/// seats, escrow start/rollback semantics, conversion after graduation, exact partial-fill limits
/// with an arbitrageur between chunks, the leftover-IMD-only burn hop, and a dry IMD venue.
contract V4EdgesTest is BaseTest {
    TestIMD imd;
    PoolKey imdKey;

    function setUp() public override {
        super.setUp();
        TestIMD impl = new TestIMD();
        vm.etch(IMD, address(impl).code);
        imd = TestIMD(IMD);
        imdKey = PoolKey(address(0), IMD, 10_000, 100, address(0));
        pm.initialize(imdKey, uint160(1 << 96));
        imd.mint(address(router), 100 ether);
        vm.deal(address(router), 100 ether);
        router.add(imdKey, 68 ether);
        openPad();
    }

    function _start(uint256 n) internal {
        mintAll(pvp, n);
        advance(10 minutes);
    }

    function _finish() internal {
        if (!pvp.ended()) vm.warp(pvp.endTime() + 1);
        arb.advance(300);
        while (pvp.pendingCount() != 0) pvp.resolvePending(16);
        pvp.finalize();
    }

    function _convertAll(PadGame game) internal {
        for (uint256 i; i < 100; ++i) {
            liq.convertChunk(address(game));
            (uint256 left,,,,,,) = liq.conversions(address(game));
            if (left == 0) return;
            vm.warp(vm.getBlockTimestamp() + 30);
        }
        revert("too many chunks");
    }

    function _height(uint256 i, int16 h) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(uint256(10)))) + i * 2);
        uint256 word = uint256(vm.load(address(pvp), slot));
        word = (word & ~(uint256(type(uint16).max) << 160)) | (uint256(uint16(h)) << 160);
        vm.store(address(pvp), slot, bytes32(word));
    }

    function _gameEthAccounted() internal view {
        uint256 claims = pvp.claimable(address(this));
        for (uint256 i; i < players.length; ++i) {
            claims += pvp.claimable(players[i]);
        }
        (,,,,, bool started,) = liq.conversions(address(pvp));
        uint256 curve = started || pvp.graduated() ? 0 : pvp.ethRaised();
        assertEq(address(pvp).balance, curve + pvp.pot() + claims + pvp.pendingCount() * pvp.ROLL_TIP());
    }

    // ---- bail-out boundaries -------------------------------------------------------------------------

    function test_seatedWalletWithoutCoinsBailsForZeroAndMinOutOneReverts() public {
        _start(3);
        rollAs(pvp, players[1]);
        assertEq(pvpToken.balanceOf(players[0]), 0);
        assertEq(pvp.curveSpent(players[0]), 0);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadMinOut()"));
        pvp.bailOut(1);
        uint256 pot = pvp.pot();
        uint256 raised = pvp.ethRaised();
        uint256 before = players[0].balance;
        vm.prank(players[0]);
        pvp.bailOut(0);
        assertTrue(pvp.erased(players[0]));
        assertEq(players[0].balance, before, "nothing to pay");
        assertEq(pvp.pot(), pot);
        assertEq(pvp.ethRaised(), raised);
        assertFalse(pvp.isAlive(pvp.impOf(players[0]) - 1));
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadErased()"));
        pvp.roll{value: 0.002 ether}();
        _gameEthAccounted();
    }

    function test_bailOutRefusedAfterBellAndAfterHardEnd() public {
        _start(2);
        rollAs(pvp, players[0]);
        rollAs(pvp, players[1]);
        // the pending roll of seat 0 will land at +-50 from 49 / -49 only if it moves the right way; force the
        // bell directly by resolving a roll from the cap-adjacent height in the direction it goes.
        uint256 seat = pvp.impOf(players[0]) - 1;
        arb.advance(4);
        PadGame.Roll memory r = pvp.getRoll(0);
        uint256 rand = uint256(
            keccak256(
                abi.encode(
                    address(pvp),
                    uint256(r.imp),
                    uint256(r.nonce),
                    arb.arbBlockHash(r.commitBlock + 1),
                    arb.arbBlockHash(r.commitBlock + 2),
                    arb.arbBlockHash(r.commitBlock + 3)
                )
            )
        );
        uint256 face = rand % 8;
        int256 d = face < 4 ? -int256(face + 1) : int256(face - 3);
        _height(seat, d > 0 ? int16(50 - int16(d)) : int16(-50 - int16(d)));
        pvp.resolvePending(1);
        assertTrue(pvp.bellRang(), "bell");
        assertTrue(pvp.ended());
        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.bailOut(0);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.bailOut(0);
    }

    function test_bailOutRefusedAtHardEndEvenWithLiveActivity() public {
        _start(2);
        for (uint256 i; i < 6; ++i) {
            rollAs(pvp, players[0]);
            rollAs(pvp, players[1]);
            if (i < 5) advance(9 minutes);
        }
        assertFalse(pvp.ended());
        assertEq(pvp.endTime(), pvp.hardEnd(), "live activity: the hard end decides");
        vm.warp(pvp.hardEnd() - 1);
        vm.prank(players[0]);
        pvp.bailOut(0);
        vm.warp(pvp.hardEnd());
        assertTrue(pvp.ended());
        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.bailOut(0);
    }

    function test_expiredPendingRollOfErasedSeatPaysTipToPotWithNoEffect() public {
        _start(2);
        rollAs(pvp, players[0]);
        rollAs(pvp, players[1]);
        uint256 seat = pvp.impOf(players[0]) - 1;
        vm.prank(players[0]);
        pvp.bailOut(0);
        uint256 pot = pvp.pot();
        arb.advance(300); // past the 256-block hash window: both rolls expire
        pvp.resolvePending(16);
        assertEq(pvp.pendingCount(), 0);
        assertEq(pvp.pot(), pot + 2 * pvp.ROLL_TIP(), "expired tips return to the pot");
        assertEq(pvp.getImp(seat).height, 0, "no height effect for the erased seat");
        assertEq(pvp.getRoll(0).delta, 0);
        assertTrue(pvp.getRoll(0).expired);
        _gameEthAccounted();
    }

    function test_erasedSeatOneBelowCapNeverRingsTheBell() public {
        _start(2);
        rollAs(pvp, players[0]);
        rollAs(pvp, players[1]);
        uint256 seat = pvp.impOf(players[0]) - 1;
        _height(seat, 49);
        vm.prank(players[0]);
        pvp.bailOut(0);
        arb.advance(4);
        pvp.resolvePending(16);
        assertEq(pvp.getImp(seat).height, 49);
        assertEq(pvp.bellAt(), 0, "an erased seat cannot ring");
        assertFalse(pvp.ended());
    }

    function test_kingSplitIgnoresGameWithErasedSeatBelowFive() public {
        _start(6);
        for (uint256 i; i < 6; ++i) {
            rollAs(pvp, players[i]);
        }
        (bool live, uint256 weight) = pvp.isLiveForKing();
        assertTrue(live);
        uint256 earned = pvp.rollPot();
        assertEq(weight, earned);
        vm.prank(players[5]);
        pvp.bailOut(0);
        (live, weight) = pvp.isLiveForKing();
        assertTrue(live, "five non-erased seats still qualify");
        assertEq(weight, earned, "bail tax is not king weight");
        vm.prank(players[4]);
        pvp.bailOut(0);
        (live,) = pvp.isLiveForKing();
        assertFalse(live, "four non-erased seats do not qualify");
        // the king's share then goes to the carry pot instead of this game
        vm.deal(address(king), 1 ether);
        uint256 carry = pad.carryPot();
        uint256 funded = pvp.fundedPot();
        vm.prank(address(king));
        pad.fundGames{value: 0.5 ether}();
        assertEq(pad.carryPot(), carry + 0.5 ether);
        assertEq(pvp.fundedPot(), funded);
    }

    function test_everySeatBailingOutEndsTheGameAtOnceAndFailsGraduation() public {
        _start(3);
        for (uint256 i; i < 3; ++i) {
            rollAs(pvp, players[i]);
        }
        for (uint256 i; i < 3; ++i) {
            vm.prank(players[i]);
            pvp.bailOut(0);
            assertEq(pvp.ended(), i == 2);
        }
        assertEq(pvp.endTime(), vm.getBlockTimestamp());
        assertEq(pvp.ethRaised(), 0);
        assertEq(pvp.tokensSold(), 0);
        uint256 pot = pvp.pot();
        assertGt(pot, 0);
        arb.advance(4);
        pvp.resolvePending(16);
        pot = pvp.pot(); // resolved tips
        uint256 fee = pot * 50 / 10_000;
        if (fee > pvp.rollPot()) fee = pvp.rollPot();
        uint256 carry = pad.carryPot();
        uint256 finalizer = address(this).balance;
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 0);
        assertEq(address(this).balance - finalizer, fee, "finalizer fee from roll income only");
        assertEq(pad.carryPot(), carry + pot - fee, "nobody ranks: the rest of the pot is carried");
        assertEq(pvp.status(), 4, "no curve ETH: no converting phase");
        pvp.graduate();
        assertTrue(pvp.failed());
        assertEq(pvp.status(), 6);
        assertEq(pvpToken.balanceOf(DEAD), pvpToken.totalSupply());
        assertFalse(pvpToken.unlocked());
        (,,,,, bool started,) = liq.conversions(address(pvp));
        assertFalse(started, "no escrow for a game without curve ETH");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_bailPayoutFormulaAndCurveLedger(uint8 rollsSeed, uint8 who, uint96 minOutSeed) public {
        uint256 rounds = bound(rollsSeed, 1, 5);
        _start(4);
        for (uint256 r; r < rounds; ++r) {
            for (uint256 i; i < 4; ++i) {
                if ((uint256(rollsSeed) >> i) & 1 == 1 || r == 0) rollAs(pvp, players[i]);
            }
            advance(61);
            arb.advance(300);
        }
        address p = players[who % 4];
        uint256 coins = pvpToken.balanceOf(p);
        uint256 value = pvp.quoteSell(coins);
        uint256 cost = pvp.curveSpent(p);
        uint256 expected = value >= cost ? cost + (value - cost) / 2 : value * 90 / 100;
        assertLe(expected, value, "the curve never pays above the sell value");
        assertLe(value, pvp.ethRaised(), "the sell value never exceeds the curve ETH");
        uint256 minOut = bound(minOutSeed, 0, expected + 1);
        uint256 pot = pvp.pot();
        uint256 earned = pvp.rollPot();
        uint256 raised = pvp.ethRaised();
        uint256 sold = pvp.tokensSold();
        uint256 before = p.balance;
        vm.prank(p);
        if (minOut > expected) {
            vm.expectRevert(abi.encodeWithSignature("PadMinOut()"));
            pvp.bailOut(minOut);
            assertFalse(pvp.erased(p));
            return;
        }
        pvp.bailOut(minOut);
        assertEq(p.balance - before, expected);
        assertEq(pvp.pot() - pot, value - expected);
        assertEq(pvp.rollPot(), earned);
        assertEq(raised - pvp.ethRaised(), value);
        assertEq(sold - pvp.tokensSold(), coins);
        (uint256 vEth, uint256 vTok,) = pvp.curveState();
        assertGe(vEth * vTok, pvp.K(), "constant product holds after the sell");
        assertEq(pvpToken.balanceOf(address(pvp)), pvpToken.totalSupply() - pvp.tokensSold());
        _gameEthAccounted();
    }

    // ---- conversion escrow semantics -------------------------------------------------------------------

    function test_prepareConversionGatesAndIsIdempotent() public {
        vm.expectRevert(abi.encodeWithSignature("PadNotConverting()"));
        pvp.prepareConversion();
        _start(2);
        rollAs(pvp, players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNotConverting()"));
        pvp.prepareConversion();
        _finish();
        uint256 raised = pvp.ethRaised();
        assertEq(liq.anchorOf(address(pvp)), managerPrice(imdKey), "finalize anchors the IMD/ETH spot");
        vm.warp(vm.getBlockTimestamp() + 1 hours); // nobody touches the game for an hour
        pvp.prepareConversion();
        assertEq(liq.totalConversionEth(), raised);
        assertEq(address(pvp).balance, pvp.claimable(address(this)) + pvp.pot());
        pvp.prepareConversion(); // second call is a no-op, not a second escrow
        assertEq(liq.totalConversionEth(), raised);
        (uint256 remaining,,,, uint64 progress, bool started,) = liq.conversions(address(pvp));
        assertTrue(started);
        assertEq(remaining, raised);
        assertEq(progress, vm.getBlockTimestamp(), "the stall clock starts when the escrow is created");
        assertEq(progress, pvp.finalizedAt() + 1 hours, "not at finalization: an untouched game is not a stall");
        vm.warp(uint256(pvp.finalizedAt()) + 24 hours);
        assertFalse(liq.canGraduate(address(pvp)), "24 h after finalization is not yet a stall");
        assertEq(pvp.status(), 8);
        vm.warp(uint256(progress) + 24 hours);
        assertTrue(liq.canGraduate(address(pvp)), "24 h after the escrow with no progress is");
        vm.warp(uint256(progress)); // back to the escrow block: convert normally
        _convertAll(pvp);
        pvp.graduate();
        vm.expectRevert(abi.encodeWithSignature("PadNotConverting()"));
        pvp.prepareConversion();
        vm.expectRevert(abi.encodeWithSignature("PadNotConverting()"));
        liq.convertChunk(address(pvp));
        vm.expectRevert(abi.encodeWithSignature("PadNotGraduable()"));
        pvp.graduate();
    }

    function test_directGraduateBeforeConversionRevertsWithoutLeavingAnEscrow() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        uint256 raised = pvp.ethRaised();
        uint256 gameEth = address(pvp).balance;
        vm.expectRevert(abi.encodeWithSignature("PadNotGraduable()"));
        pvp.graduate();
        (,,,,, bool started,) = liq.conversions(address(pvp));
        assertFalse(started, "a reverted graduate must not leave the escrow half-started");
        assertEq(address(pvp).balance, gameEth);
        assertEq(liq.totalConversionEth(), 0);
        // poke is the non-reverting path: it starts the escrow, converts one chunk and, since one roll
        // fits a single chunk, graduates in the same call
        pvp.poke();
        (uint256 remaining, uint256 converted,,,, bool s2, bool closed) = liq.conversions(address(pvp));
        assertTrue(s2);
        assertEq(remaining, 0);
        assertEq(converted, raised);
        assertTrue(closed);
        assertEq(address(pvp).balance, gameEth - raised);
        assertTrue(pvp.graduated());
        assertTrue(pvpToken.unlocked());
        assertEq(pvp.status(), 5);
    }

    function test_strangerCannotStartOrCloseAnEscrowAndGraduateRejectsValue() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        pvp.prepareConversion();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSignature("PadNotGame()"));
        liq.startConversion{value: 1}(1, 0);
        vm.expectRevert(abi.encodeWithSignature("PadNotGame()"));
        liq.graduate(1, address(pvpToken), 1, 1, 1);
        // the game itself cannot double-escrow
        vm.deal(address(pvp), address(pvp).balance + 1);
        vm.prank(address(pvp));
        vm.expectRevert(abi.encodeWithSignature("PadConversionStartedOrEmpty()"));
        liq.startConversion{value: 1}(1, 0);
        // the game cannot graduate while chunks are still owed
        vm.prank(address(pvp));
        vm.expectRevert(abi.encodeWithSignature("PadConversionPending()"));
        liq.graduate(1, address(pvpToken), 1, 1, 1);
    }

    function test_chunkStopsExactlyAtTheLimitAndArbitrageBetweenChunksRefillsThem() public {
        _start(12);
        for (uint256 r; r < 20; ++r) {
            for (uint256 i; i < 12; ++i) {
                rollAs(pvp, players[i]);
            }
            advance(61);
        }
        _finish();
        uint256 raised = pvp.ethRaised();
        assertGt(raised, 0.4 ether);
        router.remove(imdKey, 60 ether); // 8 ETH of depth: a 1% chunk is about 0.04 ETH
        uint256 spot0 = managerPrice(imdKey);
        liq.convertChunk(address(pvp));
        (uint256 left1, uint256 spent1,,,,,) = liq.conversions(address(pvp));
        assertGt(left1, 0, "a 0.4+ ETH raise needs more than one 1% chunk");
        assertEq(managerPrice(imdKey), spot0 - spot0 * 50 / 10_000, "partial fill stops on the limit");
        // Nobody arbitrages: the next chunk starts from the lower spot and stops at its own 1% limit
        uint256 spot1 = managerPrice(imdKey);
        vm.warp(vm.getBlockTimestamp() + 30);
        liq.convertChunk(address(pvp));
        (uint256 left2, uint256 spent2,,,,,) = liq.conversions(address(pvp));
        uint256 secondFill = spent2 - spent1;
        assertEq(managerPrice(imdKey), spot1 - spot1 * 50 / 10_000, "second partial fill stops on its limit");
        assertApproxEqRel(secondFill, spent1, 0.02e18, "each limit-bound chunk takes about the same ETH");
        assertEq(left2 + spent2, raised);
        // An arbitrageur restores the venue; the third chunk again stops 1% below the restored spot
        V4Router arb_ = new V4Router(pm);
        imd.mint(address(arb_), 10 ether);
        arb_.trade(imdKey, false, 0.2 ether);
        uint256 spot2 = managerPrice(imdKey);
        assertGe(spot2, spot0, "venue restored");
        vm.warp(vm.getBlockTimestamp() + 30);
        liq.convertChunk(address(pvp));
        (, uint256 spent3,,,,,) = liq.conversions(address(pvp));
        assertEq(managerPrice(imdKey), spot2 - spot2 * 50 / 10_000, "third partial fill stops on its limit");
        assertApproxEqRel(spent3 - spent2, spent1, 0.03e18, "a restored venue fills a full-size chunk");
        assertEq(imd.balanceOf(address(liq)), liq.totalConversionIMD() + liq.burnIMD());
    }

    function test_lastChunkFillsCompletelyBelowTheLimitAndClosesTheEscrow() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        uint256 spot = managerPrice(imdKey);
        liq.convertChunk(address(pvp));
        (uint256 left, uint256 spent, uint256 got, uint64 attempted, uint64 progress,,) = liq.conversions(address(pvp));
        assertEq(left, 0, "0.0018 ETH fits inside one 1% chunk of a 68 ETH venue");
        assertEq(spent, pvp.ethRaised());
        assertGt(got, 0);
        assertGt(managerPrice(imdKey), spot - spot * 50 / 10_000, "well inside the limit");
        assertEq(attempted, progress);
        assertTrue(liq.canGraduate(address(pvp)));
        assertEq(pvp.status(), 4);
        vm.expectRevert(abi.encodeWithSignature("PadNotConverting()"));
        liq.convertChunk(address(pvp));
    }

    function test_dryVenueAfterPartialProgressFallsBackWithPartialIMD() public {
        _start(12);
        for (uint256 r; r < 20; ++r) {
            for (uint256 i; i < 12; ++i) {
                rollAs(pvp, players[i]);
            }
            advance(61);
        }
        _finish();
        liq.convertChunk(address(pvp));
        (uint256 left, uint256 converted, uint256 received,, uint64 progress,,) = liq.conversions(address(pvp));
        assertGt(left, 0);
        router.remove(imdKey, 68 ether); // the venue dries up on the real manager, no mock
        vm.warp(vm.getBlockTimestamp() + 30);
        liq.convertChunk(address(pvp));
        (uint256 left2,,,, uint64 progress2,,) = liq.conversions(address(pvp));
        assertEq(left2, left, "an empty venue makes no progress");
        assertEq(progress2, progress, "and does not postpone the fallback");
        vm.warp(uint256(progress) + 24 hours);
        uint256 carry = pad.carryPot();
        pvp.graduate();
        assertTrue(liq.imdPool(address(pvpToken)));
        assertEq(pad.carryPot(), carry + left);
        (uint256 vEth, uint256 vTok,) = pvp.curveState();
        uint256 lpCoins = PadLib.mulDiv(converted, vTok, vEth);
        PoolKey memory key = liq.poolKey(address(pvpToken));
        uint256 price = managerPrice(key);
        uint256 quotePerCoin = address(pvpToken) < IMD
            ? PadLib.mulDiv(price, price * 1e18, 1 << 192)
            : PadLib.mulDiv(1 << 192, 1e18, price * price);
        assertApproxEqRel(quotePerCoin, PadLib.mulDiv(received, 1e18, lpCoins), 0.011e18, "partial IMD, same price");
        assertEq(address(liq).balance, liq.burnBucket() + liq.totalConversionEth());
    }

    // ---- anchor band (revision) ---------------------------------------------------------------------------

    /// @dev Pushes the IMD/ETH spot about 4% (sqrt) under the anchor by buying IMD, and returns the pusher.
    function _pushBelowBand() internal returns (V4Router pusher, uint256 pushed) {
        pusher = new V4Router(pm);
        vm.deal(address(pusher), 30 ether);
        pusher.trade(imdKey, true, 3 ether);
        pushed = managerPrice(imdKey);
        uint256 anchor = liq.anchorOf(address(pvp));
        assertLt(pushed, anchor - anchor * 100 / 10_000, "spot is below the 1% sqrt band under the anchor");
    }

    function test_bandStallDoesNotConsumeIntervalAndArbitrageReopensItInTheSameBlock() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        assertEq(liq.anchorOf(address(0xBEEF)), 0, "a game never observed has no anchor");
        (V4Router pusher, uint256 pushed) = _pushBelowBand();
        pvp.prepareConversion();
        (uint256 left,,,,, bool started,) = liq.conversions(address(pvp));
        assertTrue(started);
        vm.expectEmit(true, false, false, true, address(liq));
        emit PadLiquidity.ConversionStalled(address(pvp));
        liq.convertChunk(address(pvp));
        (uint256 left1,, uint256 got1, uint64 attempted1, uint64 progress1,,) = liq.conversions(address(pvp));
        assertEq(left1, left, "no fill below the band");
        assertEq(got1, 0);
        assertEq(attempted1, 0, "a banded stall does not consume the 30 s interval");
        assertEq(progress1, uint64(vm.getBlockTimestamp()), "the escrow stamp is untouched by a stall");
        assertEq(managerPrice(imdKey), pushed, "the venue was not touched");
        assertEq(pvp.status(), 8, "still converting");
        // the same block: a second stalled call is allowed and changes nothing
        liq.convertChunk(address(pvp));
        (uint256 left2,,, uint64 attempted2,,,) = liq.conversions(address(pvp));
        assertEq(left2, left);
        assertEq(attempted2, 0);
        // an arbitrageur sells the IMD back; the very next call fills without waiting for an interval
        pusher.trade(imdKey, false, imd.balanceOf(address(pusher)));
        assertGe(managerPrice(imdKey), liq.anchorOf(address(pvp)) * 99 / 100, "venue back inside the band");
        liq.convertChunk(address(pvp));
        (uint256 left3,, uint256 got3, uint64 attempted3,,,) = liq.conversions(address(pvp));
        assertEq(left3, 0, "one roll fits a single chunk");
        assertGt(got3, 0);
        assertEq(attempted3, uint64(vm.getBlockTimestamp()));
        assertTrue(liq.canGraduate(address(pvp)));
        assertEq(imd.balanceOf(address(liq)), liq.totalConversionIMD() + liq.burnIMD());
    }

    function test_heldStallIsFollowedByAnchorDecayWithinHoursNotMinutes() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        uint256 anchor0 = liq.anchorOf(address(pvp));
        (, uint256 pushed) = _pushBelowBand();
        pvp.prepareConversion();
        (uint256 left,,,, uint64 progress0,,) = liq.conversions(address(pvp));
        // four hours: the anchor has decayed 2% in sqrt price, the band is still above the held spot
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        uint256 anchor4 = liq.anchorOf(address(pvp));
        assertEq(anchor4, anchor0 * (10_000 - 200) / 10_000, "0.5% sqrt per hour");
        assertLt(pushed, anchor4 - anchor4 * 100 / 10_000);
        liq.convertChunk(address(pvp));
        (uint256 left1,,, uint64 attempted1, uint64 progress1,,) = liq.conversions(address(pvp));
        assertEq(left1, left, "still stalled after four hours");
        assertEq(attempted1, 0);
        assertEq(progress1, progress0, "a stall never refreshes the clock");
        // the stalled call re-stamped the decayed anchor; decay continues from there
        assertEq(liq.anchorOf(address(pvp)), anchor4);
        // eight hours in total: the band has fallen under the held spot and the chunk goes through
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        uint256 anchor8 = liq.anchorOf(address(pvp));
        assertLt(anchor8, anchor4);
        assertGt(pushed, anchor8 - anchor8 * 100 / 10_000);
        uint256 spot = managerPrice(imdKey);
        liq.convertChunk(address(pvp));
        (uint256 left2,, uint256 got2, uint64 attempted2, uint64 progress2,,) = liq.conversions(address(pvp));
        assertEq(left2, 0);
        assertGt(got2, 0);
        assertEq(attempted2, uint64(vm.getBlockTimestamp()));
        assertEq(progress2, uint64(vm.getBlockTimestamp()), "completion stamps progress");
        assertGe(managerPrice(imdKey), anchor8 - anchor8 * 100 / 10_000, "never below the band");
        assertGe(managerPrice(imdKey), spot - spot * 50 / 10_000, "never past the 1% spot limit");
        assertEq(liq.anchorOf(address(pvp)), anchor8, "a lower spot does not lower the anchor");
    }

    function test_heldStallForTwentyFourHoursGraduatesNativeWhenNoIMDWasEverConverted() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        (V4Router pusher,) = _pushBelowBand();
        pvp.prepareConversion();
        (,,,, uint64 progress0,,) = liq.conversions(address(pvp));
        // the pusher keeps the venue down: each hour it buys IMD again so the spot stays under the band,
        // and a keeper tries a chunk each time
        for (uint256 h = 1; h <= 24; ++h) {
            vm.warp(uint256(progress0) + h * 1 hours);
            uint256 anchor = liq.anchorOf(address(pvp));
            if (managerPrice(imdKey) >= anchor - anchor * 100 / 10_000) pusher.trade(imdKey, true, 0.5 ether);
            liq.convertChunk(address(pvp));
            (uint256 l,, uint256 got, uint64 attempted, uint64 progress,,) = liq.conversions(address(pvp));
            assertEq(got, 0, "the held venue never sells IMD into the band");
            assertEq(attempted, 0);
            assertEq(progress, progress0);
            assertEq(l, pvp.ethRaised());
        }
        assertTrue(liq.canGraduate(address(pvp)), "24 h without progress: never stranded");
        uint256 carry = pad.carryPot();
        uint256 raised = pvp.ethRaised();
        uint256 liqEth = address(liq).balance;
        pvp.graduate();
        assertTrue(pvp.graduated());
        assertFalse(pvp.failed());
        assertTrue(pvpToken.unlocked());
        assertFalse(liq.imdPool(address(pvpToken)), "no IMD at all: the v3 coin/ETH pool");
        assertEq(pad.carryPot(), carry, "the ETH went into the pool, not to carry");
        assertEq(liq.totalConversionEth(), 0);
        assertEq(address(liq).balance, liqEth - raised, "the escrow left for the pool");
        PoolKey memory key = liq.poolKey(address(pvpToken));
        assertEq(key.currency0, address(0));
        assertGt(managerPrice(key), 0);
        assertEq(pvp.status(), 5);
    }

    // ---- burn --------------------------------------------------------------------------------------------

    function test_burnSecondHopRunsOnLeftoverIMDWhenTheBucketIsEmpty() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        _convertAll(pvp);
        pvp.graduate();
        vm.deal(address(this), 1 ether);
        liq.fundBurn{value: 0.02 ether}();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        liq.burnChunk();
        assertEq(liq.burnBucket(), 0, "the full 0.02 ETH fits the first hop");
        uint256 leftover = liq.burnIMD();
        assertGt(leftover, 0, "a one-roll PvP pool is too thin for all the IMD");
        uint256 dead = pvpToken.balanceOf(DEAD);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 spent = liq.totalBurnedEth();
        liq.burnChunk();
        assertEq(liq.totalBurnedEth(), spent, "no ETH: first hop skipped");
        assertLt(liq.burnIMD(), leftover, "second hop consumes leftover IMD");
        assertGt(pvpToken.balanceOf(DEAD), dead, "and still burns PvP");
        assertEq(imd.balanceOf(address(liq)), liq.totalConversionIMD() + liq.burnIMD());
    }

    function test_burnWithDryIMDVenueSpendsNothingAndKeepsTheBucket() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        _convertAll(pvp);
        pvp.graduate();
        router.remove(imdKey, 68 ether);
        vm.deal(address(this), 1 ether);
        liq.fundBurn{value: 0.05 ether}();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 dead = pvpToken.balanceOf(DEAD);
        liq.burnChunk();
        assertEq(liq.burnBucket(), 0.05 ether, "unspent ETH stays in the bucket");
        assertEq(liq.totalBurnedEth(), 0);
        assertEq(pvpToken.balanceOf(DEAD), dead);
        assertEq(liq.lastBurnAt(), vm.getBlockTimestamp(), "the attempt still consumes the interval");
        assertEq(address(liq).balance, liq.burnBucket() + liq.totalConversionEth());
    }

    // ---- king fees ---------------------------------------------------------------------------------------

    function test_kingThatRejectsETHStillReceivesIMDAndCoinsInKind() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        _convertAll(pvp);
        pvp.graduate();
        Rejector crown = new Rejector();
        vm.deal(address(crown), 1 ether);
        vm.prank(address(crown));
        king.takeCrown{value: 0.01 ether}();
        PoolKey memory key = liq.poolKey(address(pvpToken));
        imd.mint(address(router), 1 ether);
        vm.prank(players[0]);
        pvpToken.transfer(address(router), 1000 ether);
        router.donate(key, key.currency0 == IMD ? 1 ether : 1000 ether, key.currency0 == IMD ? 1000 ether : 1 ether);
        liq.distribute(1);
        assertGt(imd.balanceOf(address(crown)), 0.999 ether);
        assertGt(pvpToken.balanceOf(address(crown)), 999 ether);
        assertEq(liq.claimable(address(crown)), 0, "nothing parked: IMD is not pushed as ETH");
        assertEq(liq.getPool(0).failures, 0);
    }
}
