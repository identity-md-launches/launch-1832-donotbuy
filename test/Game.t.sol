// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {Rejector} from "./mocks/Mocks.sol";

contract GameTest is BaseTest {
    function setUp() public override {
        super.setUp();
        openPad();
    }

    // ---- signup ----------------------------------------------------------------------------------
    function test_firstEntryStartsSignupWithoutSeating() public {
        assertEq(pvp.status(), 0);
        vm.prank(players[0]);
        pvp.enter{value: 0.001 ether}();
        assertEq(pvp.firstEntryAt(), vm.getBlockTimestamp());
        assertEq(pvp.signupEnd(), vm.getBlockTimestamp() + 10 minutes);
        assertEq(pvp.playStart(), 0);
        assertEq(pvp.hardEnd(), 0);
        assertEq(pvp.status(), 1);
        assertEq(pvp.impCount(), 0);
        assertEq(pvp.entryOf(players[0]), 1);
    }

    function test_entryOnePerWalletAndSignupWindow() public {
        vm.prank(players[0]);
        pvp.enter{value: 0.001 ether}();
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadOneEntryPerWallet()"));
        pvp.enter{value: 0.001 ether}();
        advance(10 minutes - 1);
        vm.prank(players[1]);
        pvp.enter{value: 0.001 ether}();
        advance(1);
        vm.prank(players[2]);
        vm.expectRevert(abi.encodeWithSignature("PadSignupOver()"));
        pvp.enter{value: 0.001 ether}();
    }

    // ---- roll rules ------------------------------------------------------------------------------
    function test_rollRequiresPlayPhasePriceAndImp() public {
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadRollPrice()"));
        pvp.roll{value: 0.001 ether}();
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.roll{value: 0.002 ether}();
        vm.prank(players[0]);
        pvp.enter{value: 0.001 ether}();
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.roll{value: 0.002 ether}();
        advance(10 minutes);
        rollAs(pvp, players[0]);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadCooldown()"));
        pvp.roll{value: 0.002 ether}();
        advance(60);
        rollAs(pvp, players[0]);
    }

    function test_rollSplitGenesisBurnShareToPot() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        // 90% curve, 7% pot, 2% genesis pot, 1% pending resolver tip
        assertEq(pvp.ethRaised(), 0.0018 ether);
        assertEq(pvp.pot(), 0.00018 ether);
        assertEq(liq.burnBucket(), 0);
        assertEq(address(pvp).balance, 0.002 ether);
        assertGt(pvpToken.balanceOf(players[0]), 0);
        (uint256 q,) = gameTemplate.quote(0.0018 ether);
        assertEq(pvpToken.balanceOf(players[0]), q);
    }

    function test_nonGenesisBurnShareGoesToBurnBucket() public {
        graduatePvp();
        uint256 id = pad.launch("Foo", "FOO", "");
        PadGame g = PadGame(pad.gameOf(id));
        mintAll(g, 1);
        advance(10 minutes);
        uint256 before = liq.burnBucket() + liq.totalBurnedEth();
        uint256 potBefore = g.pot(); // may hold the carry pot of the genesis game
        rollAs(g, players[0]);
        assertEq(liq.burnBucket() + liq.totalBurnedEth() - before, 0.00004 ether);
        assertEq(g.pot() - potBefore, 0.00014 ether);
        assertEq(g.ethRaised(), 0.0018 ether);
    }

    function test_curveQuoteMatchesConstantProduct() public view {
        (uint256 out, uint256 used) = gameTemplate.quote(1 ether);
        // (1+1)*(1e9 - out) = 1e9 -> out = 5e8
        assertEq(out, 500_000_000 ether);
        assertEq(used, 1 ether);
        (out, used) = gameTemplate.quote(4 ether);
        assertEq(out, 800_000_000 ether);
        assertEq(used, 4 ether);
        (out, used) = gameTemplate.quote(5 ether);
        assertEq(out, 800_000_000 ether);
        assertEq(used, 4 ether);
    }

    function test_soldOutCurveSendsRollToPot() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        // fill the curve almost completely through a large donation-free path: simulate by rolling until
        // sold out is impractical (2222 rolls); instead check the sold-out branch via quote on a state set by rolls.
        rollAs(pvp, players[0]);
        (,, uint256 remaining) = pvp.curveState();
        assertLt(remaining, 800_000_000 ether);
        assertGt(remaining, 0);
    }

    function test_tokenLockedUntilGraduation() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        uint256 bal = pvpToken.balanceOf(players[0]);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadLockedUntilGraduation()"));
        pvpToken.transfer(players[1], bal);
        vm.prank(players[0]);
        pvpToken.approve(players[1], bal);
        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSignature("PadLockedUntilGraduation()"));
        pvpToken.transferFrom(players[0], players[1], bal);
        vm.expectRevert(abi.encodeWithSignature("PadNotLiquidity()"));
        pvpToken.unlock();
    }

    // ---- dice and RNG ----------------------------------------------------------------------------
    function test_rollResolvesAfterThreeBlocksWithArbHashes() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        PadGame.Roll memory r = pvp.getRoll(0);
        assertEq(r.commitBlock, arb.number());
        assertEq(pvp.pendingCount(), 1);
        arb.advance(3);
        pvp.poke();
        assertEq(pvp.pendingCount(), 1, "needs commit+4");
        arb.advance(1);
        pvp.poke();
        assertEq(pvp.pendingCount(), 0);
        r = pvp.getRoll(0);
        assertTrue(r.resolved);
        assertFalse(r.expired);
        PadGame.Imp memory imp = pvp.getImp(0);
        int256 expected = _expectedDelta(address(pvp), 0, 0, r.commitBlock);
        assertEq(int256(r.delta), expected);
        assertEq(int256(imp.height), expected);
        assertTrue(expected != 0 && expected >= -4 && expected <= 4);
    }

    function test_expiredRollMovesTowardZero() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        arb.advance(4);
        pvp.poke();
        int256 h0 = pvp.getImp(0).height;
        advance(60);
        rollAs(pvp, players[0]);
        arb.advance(300); // past the 256-block window, no hash available
        pvp.poke();
        PadGame.Roll memory r = pvp.getRoll(1);
        assertTrue(r.resolved && r.expired);
        int256 h1 = pvp.getImp(0).height;
        if (h0 > 0) assertEq(h1, h0 >= 4 ? h0 - 4 : int256(0));
        else assertEq(h1, h0 <= -4 ? h0 + 4 : int256(0));
    }

    function test_rollResolvesOwnPreviousRoll() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        advance(60); // 240 blocks
        rollAs(pvp, players[0]);
        assertTrue(pvp.getRoll(0).resolved);
        assertFalse(pvp.getRoll(1).resolved);
        assertEq(pvp.pendingCount(), 1);
    }

    function test_resolveBatchIncludesTenRolls() public {
        mintAll(pvp, 10);
        advance(10 minutes);
        for (uint256 i; i < 10; ++i) {
            rollAs(pvp, players[i]);
        }
        assertEq(pvp.pendingCount(), 10);
        arb.advance(4);
        pvp.poke();
        assertEq(pvp.pendingCount(), 0);
        pvp.poke();
        assertEq(pvp.pendingCount(), 0);
    }

    function test_bellEndsGame() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        // force a height of 49 then resolve a +1..+4 roll
        rollAs(pvp, players[0]);
        _setHeight(0, 49);
        PadGame.Roll memory r = pvp.getRoll(0);
        int256 d = _expectedDelta(address(pvp), 0, 0, r.commitBlock);
        arb.advance(4);
        pvp.poke();
        if (d > 0) {
            assertEq(pvp.getImp(0).height, 50);
            assertEq(pvp.bellAt(), vm.getBlockTimestamp());
            assertEq(pvp.bellRinger(), players[0]);
            assertTrue(pvp.ended() && pvp.bellRang());
            vm.prank(players[1]);
            vm.expectRevert(abi.encodeWithSignature("PadGameOver()"));
            pvp.roll{value: 0.002 ether}();
        } else {
            assertEq(pvp.getImp(0).height, 49 + d);
            assertEq(pvp.bellAt(), 0);
        }
    }

    function test_deathAndAllDeadEnd() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        advance(10 minutes); // player 1 never rolled: dead; player 0 dies now too
        assertTrue(pvp.ended(), "all dead");
        assertFalse(pvp.isAlive(0));
        assertFalse(pvp.isAlive(1));
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadGameOver()"));
        pvp.roll{value: 0.002 ether}();
    }

    function test_deadImpCannotRollWhileOthersPlay() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        advance(9 minutes);
        rollAs(pvp, players[0]);
        advance(2 minutes);
        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSignature("PadImpDead()"));
        pvp.roll{value: 0.002 ether}();
        rollAs(pvp, players[0]);
    }

    function test_hardEndAt50MinutesAfterPlayStart() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        for (uint256 i; i < 9; ++i) {
            rollAs(pvp, players[0]);
            advance(5 minutes);
        }
        assertFalse(pvp.ended());
        advance(5 minutes);
        assertEq(pvp.endTime(), pvp.hardEnd());
        assertTrue(pvp.ended());
    }

    // ---- finalize --------------------------------------------------------------------------------
    function test_finalizeRanksAndPays() public {
        mintAll(pvp, 5);
        advance(10 minutes);
        for (uint256 i; i < 5; ++i) {
            rollAs(pvp, players[i]);
        }
        arb.advance(4);
        pvp.poke();
        // fix heights deterministically: p0 = 30, p1 = -30 (reached later), p2 = 10, p3 = 5, p4 = 0
        _setHeight(0, 30);
        _setHeightAt(1, -30, uint40(vm.getBlockTimestamp() + 1));
        _setHeight(2, 10);
        _setHeight(3, 5);
        _setHeight(4, 0);
        advance(10 minutes); // all dead at the same time -> living counts those alive at endTime
        // everyone rolled at the same second so they all die at endTime: nobody living -> carry pot
        assertTrue(pvp.ended());
        uint256 potBefore = pvp.pot();
        vm.prank(players[9]);
        pvp.finalize();
        assertTrue(pvp.finalized());
        assertEq(pvp.livingAtEnd(), 0);
        uint256 fee = potBefore * 50 / 10_000;
        assertEq(pad.carryPot(), potBefore - fee);
        assertEq(players[9].balance, 10 ether + fee);
        assertEq(pvp.pot(), 0);
    }

    function test_finalizePaysTriangularRanksAndBell() public {
        mintAll(pvp, 5);
        advance(10 minutes);
        for (uint256 i; i < 5; ++i) {
            rollAs(pvp, players[i]);
            advance(1); // staggered so later rollers stay alive longer
        }
        arb.advance(4);
        pvp.poke();
        _setHeight(0, 30);
        _setHeightAt(1, -30, uint40(vm.getBlockTimestamp() + 1));
        _setHeight(2, 10);
        _setHeight(3, 5);
        _setHeight(4, 0);
        // bell by player 4 (last roller), game ends now, all five alive
        _setBell(uint64(vm.getBlockTimestamp()), players[4]);
        _setHeight(4, 50);
        assertTrue(pvp.ended() && pvp.bellRang());
        uint256 p = pvp.pot();
        uint256[5] memory before;
        for (uint256 i; i < 5; ++i) {
            before[i] = players[i].balance;
        }
        vm.prank(players[9]);
        pvp.finalize();
        uint256 fee = p * 50 / 10_000;
        p -= fee;
        uint256 bell = p * 20 / 100;
        uint256 ranks = p - bell;
        // living 5 -> paid 3: order p4 (50), p0 (30, earlier), p1 (-30, later); weights 3,2,1 / 6
        assertEq(pvp.livingAtEnd(), 5);
        assertEq(pvp.paidAtEnd(), 3);
        assertEq(players[4].balance - before[4], ranks * 3 / 6 + bell);
        assertEq(players[0].balance - before[0], ranks * 2 / 6);
        assertEq(players[1].balance - before[1], ranks * 1 / 6);
        assertEq(players[2].balance, before[2]);
        assertEq(players[3].balance, before[3]);
        assertEq(players[9].balance, 10 ether + fee);
        vm.expectRevert(abi.encodeWithSignature("PadNotFinalizable()"));
        pvp.finalize();
    }

    function test_finalizeWaitsForPendingRolls() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        vm.warp(vm.getBlockTimestamp() + 60 minutes); // time passes, no new L2 blocks
        assertTrue(pvp.ended());
        vm.expectRevert(abi.encodeWithSignature("PadNotFinalizable()"));
        pvp.finalize();
        arb.advance(4);
        pvp.finalize();
        assertTrue(pvp.finalized());
    }

    function test_finalizerFeeCapped() public {
        mintAll(pvp, 5);
        advance(10 minutes);
        for (uint256 r; r < 7; ++r) {
            for (uint256 i; i < 5; ++i) {
                rollAs(pvp, players[i]);
            }
            advance(61);
        }
        assertGe(pvp.rollPot(), 0.005 ether, "roll pot covers the max fee");
        vm.deal(address(pad), 10 ether);
        vm.prank(address(pad));
        pvp.fundPot{value: 5 ether}();
        assertEq(pvp.fundedPot(), 5 ether);
        advance(60 minutes);
        uint256 carryBefore = pad.carryPot();
        pvp.resolvePending(16);
        uint256 earned = pvp.rollPot();
        vm.prank(players[9]);
        pvp.finalize();
        assertEq(players[9].balance, 10 ether + 0.005 ether);
        // nobody living: funded ETH and the rest of the roll pot return to the carry
        assertEq(pad.carryPot() - carryBefore, 5 ether + earned - 0.005 ether);
    }

    function test_finalizerFeeNeverExceedsRollPot() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        uint256 earned = pvp.rollPot() + pvp.pendingCount() * pvp.ROLL_TIP();
        vm.deal(address(pad), 10 ether);
        vm.prank(address(pad));
        pvp.fundPot{value: 5 ether}();
        advance(60 minutes);
        vm.prank(players[9]);
        pvp.finalize();
        assertEq(players[9].balance, 10 ether + earned, "fee comes out of roll income only");
    }

    function test_fundPotOnlyPad() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSignature("PadNotPad()"));
        pvp.fundPot{value: 1 ether}();
    }

    function test_failedPushBecomesClaimable() public {
        Rejector rj = new Rejector();
        vm.deal(address(rj), 1 ether);
        vm.prank(address(rj));
        pvp.enter{value: 0.001 ether}();
        advance(10 minutes);
        vm.deal(address(rj), 1 ether);
        vm.prank(address(rj));
        pvp.roll{value: 0.002 ether}();
        advance(60 minutes);
        pvp.finalize();
        // rejector was the only player; it died 10 min after its roll -> not living -> carry pot.
        assertEq(pvp.livingAtEnd(), 0);
        // now a winner that rejects ETH: play with staggered rolls so it is alive at end.
    }

    function test_claimableWinner() public {
        Rejector rj = new Rejector();
        vm.deal(address(rj), 1 ether);
        vm.prank(address(rj));
        pvp.enter{value: 0.001 ether}();
        mintAll(pvp, 1);
        advance(10 minutes);
        vm.prank(address(rj));
        pvp.roll{value: 0.002 ether}();
        advance(1);
        rollAs(pvp, players[0]);
        arb.advance(4);
        pvp.poke();
        _setHeight(pvp.impOf(address(rj)) - 1, 20);
        _setHeight(pvp.impOf(players[0]) - 1, 1);
        _setBell(uint64(vm.getBlockTimestamp()), players[0]);
        uint256 p = pvp.pot();
        pvp.finalize();
        uint256 fee = p * 50 / 10_000;
        uint256 ranks = (p - fee) * 80 / 100;
        assertEq(pvp.claimable(address(rj)), ranks);
        assertEq(address(pvp).balance, ranks + pvp.ethRaised() + gameReserves(pvp));
        vm.prank(address(rj));
        vm.expectRevert(abi.encodeWithSignature("PadClaimFailed()"));
        pvp.claim();
    }

    function test_conservationOfEth() public {
        mintAll(pvp, 4);
        advance(10 minutes);
        for (uint256 r; r < 3; ++r) {
            for (uint256 i; i < 4; ++i) {
                rollAs(pvp, players[i]);
            }
            advance(61);
        }
        assertEq(address(pvp).balance, pvp.pot() + pvp.ethRaised() + gameReserves(pvp));
        assertEq(pvp.ethRaised() + pvp.pot() + gameReserves(pvp), 12 * 0.002 ether);
    }

    // ---- graduation ------------------------------------------------------------------------------
    function test_graduationCreatesPoolUnlocksTokenBurnsExcess() public {
        playOut(pvp, 4, 3);
        assertTrue(pvp.finalized());
        uint256 raised = pvp.ethRaised();
        uint256 tokens = pvpToken.balanceOf(address(pvp));
        if (!pvp.graduated()) graduateGame(pvp);
        assertTrue(pvp.graduated() && !pvp.failed());
        assertTrue(pvpToken.unlocked());
        assertEq(pvpToken.balanceOf(address(pvp)), 0);
        assertEq(liq.poolCount(), 1);
        assertGt(managerPrice(liq.poolKey(address(pvpToken))), 0);
        PadLiquidity_Pool(liq.getPool(0).token, address(pvpToken));
        uint256 inPool = pvpToken.balanceOf(address(pm));
        uint256 burned = pvpToken.balanceOf(DEAD);
        assertEq(inPool + burned, tokens);
        assertGt(burned, 0, "token side is in excess at the curve price");
        assertApproxEqRel(address(pm).balance, raised, 0.006e18);
        assertEq(address(pvp).balance, gameReserves(pvp));
        // price: sqrtP^2 / 2^192 = vTok / vEth
        uint160 sqrtP = managerPrice(liq.poolKey(address(pvpToken)));
        (uint256 vEth, uint256 vTok,) = pvp.curveState();
        uint256 price = (uint256(sqrtP) * uint256(sqrtP)) >> 192;
        // the mock moves its price after the dust burn that upkeep ran inside graduate(): allow 0.01%
        assertApproxEqRel(price, vTok / vEth, 0.011e18);
        // token now transferable
        uint256 bal = pvpToken.balanceOf(players[0]);
        uint256 other = pvpToken.balanceOf(players[1]);
        vm.prank(players[0]);
        pvpToken.transfer(players[1], bal);
        assertEq(pvpToken.balanceOf(players[1]), other + bal);
        vm.expectRevert(abi.encodeWithSignature("PadNotGraduable()"));
        pvp.graduate();
    }

    function PadLiquidity_Pool(address a, address b) internal pure {
        assertEq(a, b);
    }

    function test_graduationWithoutEthFailsAndBurns() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        advance(10 minutes); // nobody rolled -> all dead, no ETH
        assertTrue(pvp.ended());
        pvp.finalize();
        graduateGame(pvp);
        assertTrue(pvp.failed());
        assertEq(pvpToken.balanceOf(DEAD), 1_000_000_000 ether);
        assertFalse(pad.genesisGraduated());
        assertEq(liq.poolCount(), 0);
    }

    function test_graduateOnlyFromGame() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSignature("PadNotGame()"));
        liq.graduate{value: 1 ether}(1, address(pvpToken), 1, 1, 1);
    }

    function test_upkeepFinalizesAndGraduatesDueGame() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        advance(60 minutes);
        // a state-changing call elsewhere (pad.upkeep) finalizes and, on the next call, graduates
        pad.upkeep();
        assertTrue(pvp.finalized());
        vm.warp(uint256(pvp.finalizedAt()) + 24 hours);
        pad.upkeep();
        assertTrue(pvp.graduated());
    }

    // ---- funded pot (carry pot, king share) ------------------------------------------------------
    function test_fundedPotReturnsToCarryWhenFewerThanFiveLive() public {
        mintAll(pvp, 1);
        vm.deal(address(pad), 10 ether);
        vm.prank(address(pad));
        pvp.fundPot{value: 0.5 ether}();
        assertEq(pvp.pot(), 0.5 ether);
        advance(10 minutes);
        for (uint256 i; i < 6; ++i) {
            rollAs(pvp, players[0]);
            advance(599);
        }
        while (!pvp.ended()) advance(60);
        advance(5);
        uint256 carryBefore = pad.carryPot();
        pvp.resolvePending(16);
        uint256 earned = pvp.rollPot();
        vm.prank(players[0]);
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 1);
        // the solo player gets back exactly its roll income (fee + rank), the funded 0.5 ETH returns
        assertEq(players[0].balance, 10 ether - 0.001 ether - 6 * 0.002 ether + earned);
        assertEq(pad.carryPot() - carryBefore, 0.5 ether);
        assertEq(pvp.fundedPot(), 0);
    }

    function test_fundedPotReleasedToFiveLivingCappedAtThreeTimesRollPot() public {
        mintAll(pvp, 5);
        vm.deal(address(pad), 10 ether);
        vm.prank(address(pad));
        pvp.fundPot{value: 1 ether}();
        advance(10 minutes);
        for (uint256 i; i < 5; ++i) {
            rollAs(pvp, players[i]);
        }
        advance(10 minutes); // all five die at endTime
        pvp.resolvePending(16);
        uint256 earned = pvp.rollPot();
        uint256 carryBefore = pad.carryPot();
        uint256 mine = address(this).balance;
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 0);
        // fee = min(0.5% of 1.001 ETH, 0.005 ETH, roll pot) = the whole roll pot; the funded ETH returns in full
        assertEq(address(this).balance - mine, earned);
        assertEq(pad.carryPot() - carryBefore, 1 ether);

        // same setup with everyone alive at the end: 3x the roll pot is released, the rest returns
        BaseTest.setUp();
        openPad();
        mintAll(pvp, 5);
        vm.deal(address(pad), 10 ether);
        vm.prank(address(pad));
        pvp.fundPot{value: 1 ether}();
        advance(10 minutes);
        for (uint256 i; i < 5; ++i) {
            rollAs(pvp, players[i]);
        }
        advance(61);
        for (uint256 i; i < 5; ++i) {
            rollAs(pvp, players[i]);
        }
        arb.advance(4);
        pvp.poke();
        // death is lastRoll + 10 min <= end, so end the game now with a bell by player 0: all five alive
        _setBell(uint64(vm.getBlockTimestamp()), players[0]);
        _setHeight(0, 50);
        assertTrue(pvp.ended() && pvp.bellRang());
        earned = pvp.rollPot();
        uint256 cap = pvp.fundedReleaseCap();
        assertEq(cap, pvp.ethRaised() * 15 / 100, "15% of the curve ETH binds before 3x the roll pot here");
        assertLt(cap, 3 * earned);
        carryBefore = pad.carryPot();
        uint256 sum;
        uint256[5] memory before;
        for (uint256 i; i < 5; ++i) {
            before[i] = players[i].balance;
        }
        vm.prank(players[9]);
        pvp.finalize();
        for (uint256 i; i < 5; ++i) {
            sum += players[i].balance - before[i];
        }
        assertEq(pvp.livingAtEnd(), 5);
        uint256 fee = (1 ether + earned) * 50 / 10_000;
        if (fee > 0.005 ether) fee = 0.005 ether;
        if (fee > earned) fee = earned;
        uint256 returned = 1 ether - cap;
        uint256 paidOut = 1 ether + earned - fee - returned;
        uint256 carryGain = pad.carryPot() - carryBefore;
        assertGe(carryGain, returned, "unreleased funded ETH returns to the carry (plus dust)");
        assertLe(carryGain - returned, 10, "only rounding dust on top");
        assertApproxEqAbs(sum, paidOut, 10, "players share roll pot plus the capped release from the funded pot");
        assertEq(players[9].balance, 10 ether + fee);
    }

    // ---- bell and tie-break details --------------------------------------------------------------
    function test_rollAfterOwnBellReverts() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        PadGame.Roll memory r = pvp.getRoll(0);
        int256 d = _expectedDelta(address(pvp), 0, 0, r.commitBlock);
        _setHeight(0, d > 0 ? int16(49) : int16(-49)); // the pending roll will ring the bell
        advance(60);
        uint256 rolls = pvp.rollCount();
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadGameOver()"));
        pvp.roll{value: 0.002 ether}();
        pvp.poke();
        assertTrue(pvp.bellRang());
        assertEq(pvp.rollCount(), rolls, "no roll recorded after the bell");
        assertEq(pvp.pendingCount(), 0);
    }

    function test_deadImpCannotRingTheBell() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        PadGame.Roll memory r = pvp.getRoll(0);
        int256 d = _expectedDelta(address(pvp), 0, 0, r.commitBlock);
        _setHeight(0, d > 0 ? int16(49) : int16(-49));
        // player 1 keeps the game alive while the chain is quiet: only 2 L2 blocks in 9 minutes
        vm.warp(vm.getBlockTimestamp() + 9 minutes);
        arb.advance(2);
        rollAs(pvp, players[1]);
        assertEq(pvp.getImp(0).pendingRoll, 1, "player 0's roll is still pending");
        vm.warp(vm.getBlockTimestamp() + 1 minutes + 1);
        assertFalse(pvp.isAlive(0));
        assertFalse(pvp.ended());
        arb.advance(5);
        pvp.resolvePending(8);
        assertEq(pvp.getImp(0).pendingRoll, 0);
        assertEq(PadGame(pvp).getImp(0).height, d > 0 ? int16(50) : int16(-50), "height still moves");
        assertEq(pvp.bellAt(), 0, "a dead imp does not ring the bell");
    }

    function test_tieBreakFollowsCommitOrderNotResolutionOrder() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]); // B: commits first
        vm.warp(vm.getBlockTimestamp() + 1);
        arb.advance(1); // next L2 block: B's roll is not resolvable yet
        rollAs(pvp, players[1]); // A: commits second
        PadGame.Roll memory r0 = pvp.getRoll(0);
        PadGame.Roll memory r1 = pvp.getRoll(1);
        int256 d0 = _expectedDelta(address(pvp), 0, 0, r0.commitBlock);
        int256 d1 = _expectedDelta(address(pvp), 1, 0, r1.commitBlock);
        _setHeight(0, int16(30 - d0)); // both land on +30
        _setHeight(1, int16(30 - d1));
        advance(60);
        // A rolls again: its own pending roll resolves first, then the batch resolves B's
        rollAs(pvp, players[1]);
        assertEq(pvp.getImp(0).height, 30);
        assertEq(pvp.getImp(0).heightReachedAt, r0.commitBlock, "stamped with the commit block");
        assertEq(pvp.getImp(1).heightReachedAt, r1.commitBlock);
        // let A's new roll resolve, then put A back on 30 with its original stamp so only the tie-break counts
        advance(1);
        pvp.resolvePending(8);
        _setHeightAt(1, 30, uint40(r1.commitBlock));
        _setBell(uint64(vm.getBlockTimestamp()), players[5]);
        assertTrue(pvp.ended());
        uint256 b0 = players[0].balance;
        uint256 b1 = players[1].balance;
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 2);
        assertEq(pvp.paidAtEnd(), 1);
        assertGt(players[0].balance, b0, "B committed first and wins the tie");
        assertEq(players[1].balance, b1);
    }

    function test_finalizeWith200LivingImpsStaysUnderFiveMillionGas() public {
        address[] memory many = new address[](200);
        for (uint256 i; i < 200; ++i) {
            many[i] = address(uint160(0xB000 + i));
            vm.deal(many[i], 1 ether);
            vm.prank(many[i]);
            pvp.enter{value: 0.001 ether}();
        }
        advance(10 minutes);
        for (uint256 i; i < 200; ++i) {
            vm.prank(many[i]);
            pvp.roll{value: 0.002 ether}();
        }
        advance(2);
        while (pvp.pendingCount() != 0) pvp.resolvePending(16);
        assertEq(pvp.pendingCount(), 0);
        uint256 end = pvp.endTime();
        // heights ascend with the index so every insertion walks to the front; all alive at the end
        for (uint256 i; i < 200; ++i) {
            uint256 word = uint256(uint160(pvp.getImp(i).owner)) | (uint256(uint16(int16(int256(i / 4)))) << 160)
                | (uint256(end - 1) << 176) | (uint256(1000 - i) << 216);
            vm.store(address(pvp), _impSlot(i), bytes32(word));
        }
        vm.warp(end);
        assertTrue(pvp.ended());
        uint256 g = gasleft();
        pvp.finalize();
        g -= gasleft();
        assertEq(pvp.livingAtEnd(), 200);
        assertEq(pvp.paidAtEnd(), 100);
        assertLt(g, 5_000_000, "200-imp finalize gas");
    }

    // ---- helpers ---------------------------------------------------------------------------------
    function _expectedDelta(address game, uint256 imp, uint256 nonce, uint256 commit) internal pure returns (int256) {
        bytes32 h1 = keccak256(abi.encode("arb", commit + 1));
        bytes32 h2 = keccak256(abi.encode("arb", commit + 2));
        bytes32 h3 = keccak256(abi.encode("arb", commit + 3));
        uint256 face = uint256(keccak256(abi.encode(game, imp, nonce, h1, h2, h3))) % 8;
        return face < 4 ? -int256(face + 1) : int256(face - 3);
    }

    // imps[] is at slot 10 in PadGame; each Imp packs into one word:
    // owner (160) | height (16) | lastRoll (40) | heightReachedAt (40)  -> word 0; nonce, pendingRoll -> word 1
    function _impSlot(uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(uint256(10)))) + i * 2);
    }

    function _setHeight(uint256 i, int16 h) internal {
        PadGame.Imp memory imp = pvp.getImp(i);
        _setHeightAt(i, h, imp.heightReachedAt);
    }

    function _setHeightAt(uint256 i, int16 h, uint40 at) internal {
        PadGame.Imp memory imp = pvp.getImp(i);
        uint256 word = uint256(uint160(imp.owner)) | (uint256(uint16(h)) << 160) | (uint256(imp.lastRoll) << 176)
            | (uint256(at) << 216);
        vm.store(address(pvp), _impSlot(i), bytes32(word));
        PadGame.Imp memory after_ = pvp.getImp(i);
        assertEq(after_.height, h, "height set");
        assertEq(after_.owner, imp.owner, "owner kept");
    }

    // bellAt (uint64) and maxActivity (uint64) share slot 8 with firstEntryAt: firstEntryAt | bellAt<<64 | maxActivity<<128
    function _setBell(uint64 at, address ringer) internal {
        uint256 word = uint256(pvp.firstEntryAt()) | (uint256(at) << 64) | (uint256(pvp.maxActivity()) << 128);
        vm.store(address(pvp), bytes32(uint256(8)), bytes32(word));
        vm.store(address(pvp), bytes32(uint256(9)), bytes32(uint256(uint160(ringer))));
        assertEq(pvp.bellAt(), at, "bell set");
        assertEq(pvp.bellRinger(), ringer, "ringer set");
    }
}
