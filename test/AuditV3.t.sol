// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {IPoolManager, IUnlockCallback, PoolKey, ModifyLiquidityParams} from "../src/interfaces/Interfaces.sol";
import {Rejector} from "./mocks/Mocks.sol";

contract UnlockCrownProbe is IUnlockCallback {
    IPoolManager immutable manager;
    KingOfThePad immutable king;
    PadLiquidity immutable liquidity;

    constructor(IPoolManager m, KingOfThePad k, PadLiquidity l) {
        manager = m;
        king = k;
        liquidity = l;
    }

    function attempt(uint256 mode) external payable {
        manager.unlock(abi.encode(mode));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint256 mode = abi.decode(data, (uint256));
        if (mode == 0) king.takeCrown{value: address(this).balance}();
        else if (mode == 1) king.distribute(16);
        else liquidity.distribute(16);
        return "";
    }

    receive() external payable {}
}

contract GasEatingKing {
    function bid(KingOfThePad k, uint256 value) external {
        k.takeCrown{value: value}();
    }

    receive() external payable {
        assembly ("memory-safe") { for {} 1 {} {} }
    }
}

contract AuditV3KingTest is BaseTest {
    function setUp() public override {
        super.setUp();
        graduatePvp();
    }

    function _crownAndAccrue() internal {
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        vm.warp(king.challengeOpensAt());
        liq.burnChunk();
        liq.distribute(16);
        donateFees(liq.poolKey(address(pvpToken)), 0.1 ether, 2_000_000 ether);
    }

    function test_unlockCallbackCannotTakeCrownOrDistribute() public {
        _crownAndAccrue();
        UnlockCrownProbe probe = new UnlockCrownProbe(pm, king, liq);
        vm.deal(address(probe), 0.011 ether);
        uint256 before = players[8].balance;
        for (uint256 mode; mode < 3; ++mode) {
            vm.expectRevert(abi.encodeWithSignature("PadManagerUnlocked()"));
            probe.attempt(mode);
        }
        assertEq(king.king(), players[8]);
        assertEq(players[8].balance, before);
        assertEq(liq.getPool(0).failures, 0, "nested unlock cannot flag a healthy pool");
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether}();
        assertApproxEqAbs(players[8].balance - before, 0.11 ether, 1);
        assertApproxEqAbs(pvpToken.balanceOf(players[8]), 2_000_000 ether, 1);
    }

    function test_firstCrownAlsoRejectsUnlockedManager() public {
        UnlockCrownProbe probe = new UnlockCrownProbe(pm, king, liq);
        vm.deal(address(probe), 0.01 ether);
        vm.expectRevert(abi.encodeWithSignature("PadManagerUnlocked()"));
        probe.attempt(0);
        assertEq(king.crownCount(), 0);
    }

    function test_gasStarvedBidRevertsWithoutChangingCrownOrPoolHealth() public {
        _crownAndAccrue();
        vm.prank(players[9]);
        (bool ok, bytes memory reason) =
            address(king).call{gas: 500_000, value: 0.011 ether}(abi.encodeCall(KingOfThePad.takeCrown, ()));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSignature("PadSettlementGas()"));
        assertEq(king.king(), players[8]);
        assertEq(liq.getPool(0).failures, 0);
        // Underfunding a permissionless health probe must not manufacture a failed collection.
        (ok,) = address(liq).call{gas: 200_000}(abi.encodeCall(PadLiquidity.distribute, (16)));
        assertTrue(ok, "ordinary distribution skips work below its gas floor");
        assertEq(liq.getPool(0).failures, 0);
        (ok,) = address(liq).call{gas: 200_000}(abi.encodeCall(PadLiquidity.retryPool, (0)));
        assertFalse(ok);
        assertEq(liq.getPool(0).failures, 0);
    }

    function test_failedPoolRequiresThreeDistinctL2BlocksThenAnyoneCanRecoverIt() public {
        _crownAndAccrue();
        PoolKey memory key = liq.poolKey(address(pvpToken));
        vm.mockCallRevert(
            address(pm),
            abi.encodeCall(
                IPoolManager.modifyLiquidity, (key, ModifyLiquidityParams(-887200, 887200, 0, 0), bytes(""))
            ),
            bytes("broken position")
        );
        vm.prank(players[9]);
        vm.expectRevert(abi.encodeWithSignature("PadPoolCollectionFailed()"));
        king.takeCrown{value: 0.011 ether}();
        assertEq(liq.getPool(0).failures, 0, "failed bid rolls back all settlement state");
        liq.distribute(16);
        liq.distribute(16);
        liq.retryPool(0);
        assertEq(liq.getPool(0).failures, 1, "same L2 block counts once");
        // L1 block progress is deliberately irrelevant on this chain.
        vm.roll(vm.getBlockNumber() + 100);
        liq.retryPool(0);
        assertEq(liq.getPool(0).failures, 1);
        arb.advance(1);
        liq.retryPool(0);
        assertEq(liq.getPool(0).failures, 2);
        vm.prank(players[9]);
        vm.expectRevert(abi.encodeWithSignature("PadPoolCollectionFailed()"));
        king.takeCrown{value: 0.011 ether}();
        arb.advance(1);
        liq.retryPool(0);
        assertEq(liq.getPool(0).failures, 3);
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether}();
        assertEq(king.king(), players[9], "a diagnosed dead pool cannot freeze crown");
        vm.clearMockedCalls();
        vm.prank(players[10]);
        assertTrue(liq.retryPool(0));
        assertEq(liq.getPool(0).failures, 0);
        // The pool was skipped at the crown, so it stays owed to the king whose reign earned its fees.
        assertApproxEqAbs(pvpToken.balanceOf(players[8]), 2_000_000 ether, 1);
        assertEq(pvpToken.balanceOf(players[9]), 0);
        // A fresh failure after recovery starts a new sequence.
        vm.mockCallRevert(address(pm), abi.encodeWithSelector(IPoolManager.unlock.selector), bytes("new failure"));
        liq.retryPool(0);
        assertEq(liq.getPool(0).failures, 1);
    }

    function test_failedSettlementRollsBackEarlierHealthyPoolPayments() public {
        PadGame g = PadGame(pad.gameOf(pad.launch("Second", "S", "")));
        playOut(g, 1, 1);
        graduateGame(g);
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        vm.warp(king.challengeOpensAt());
        liq.burnChunk();
        liq.distribute(16);
        uint256 first = liq.distributeCursor() % 2;
        uint256 second = (first + 1) % 2;
        PoolKey memory healthy = liq.poolKey(liq.getPool(first).token);
        PoolKey memory broken = liq.poolKey(liq.getPool(second).token);
        donateFees(healthy, 0.1 ether, 1000 ether);
        donateFees(broken, 0.1 ether, 1000 ether);
        vm.mockCallRevert(
            address(pm),
            abi.encodeCall(
                IPoolManager.modifyLiquidity, (broken, ModifyLiquidityParams(-887200, 887200, 0, 0), bytes(""))
            ),
            bytes("failure after healthy pool")
        );
        uint256 ethBefore = players[8].balance;
        uint256 tokensBefore = PadToken(healthy.currency1).balanceOf(players[8]);
        uint256 cursor = liq.distributeCursor();
        uint256 collected = liq.getPool(first).ethFees;
        vm.prank(players[9]);
        vm.expectRevert(abi.encodeWithSignature("PadPoolCollectionFailed()"));
        king.takeCrown{value: 0.011 ether}();
        assertEq(king.king(), players[8]);
        assertEq(players[8].balance, ethBefore);
        assertEq(PadToken(healthy.currency1).balanceOf(players[8]), tokensBefore);
        assertEq(liq.getPool(first).ethFees, collected);
        assertEq(liq.distributeCursor(), cursor);
        assertEq(liq.getPool(second).failures, 0);
        vm.clearMockedCalls();
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether}();
        assertApproxEqAbs(players[8].balance - ethBefore, 0.21 ether, 2);
    }

    function test_outgoingKingGetsLargeTokenFeesInKindAndNextKingGetsNoStash() public {
        _crownAndAccrue();
        uint256 ethBefore = players[8].balance;
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether}();
        assertApproxEqAbs(players[8].balance - ethBefore, 0.11 ether, 1);
        assertApproxEqAbs(pvpToken.balanceOf(players[8]), 2_000_000 ether, 1);
        assertEq(pvpToken.balanceOf(address(liq)), 0);
        uint256 newEth = players[9].balance;
        uint256 newTokens = pvpToken.balanceOf(players[9]);
        for (uint256 i; i < 10; ++i) {
            liq.distribute(16);
        }
        assertEq(players[9].balance, newEth);
        assertEq(pvpToken.balanceOf(players[9]), newTokens);
    }

    function test_sixteenPoolsBothCurrenciesAndGasEatingKingFitSettlementBudget() public {
        vm.pauseGasMetering();
        for (uint256 i; i < 15; ++i) {
            PadGame g = PadGame(pad.gameOf(pad.launch("Gas", "G", "")));
            playOut(g, 1, 1);
            graduateGame(g);
        }
        vm.resumeGasMetering();
        GasEatingKing outgoing = new GasEatingKing();
        vm.deal(address(outgoing), 1 ether);
        outgoing.bid(king, 0.01 ether);
        uint256 previousClaim = liq.claimable(address(outgoing));
        for (uint256 i; i < 16; ++i) {
            donateFees(liq.poolKey(liq.getPool(i).token), 0.001 ether, 1000 ether);
        }
        vm.warp(king.challengeOpensAt());
        vm.resumeGasMetering();
        uint256 start = gasleft();
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether, gas: 6_000_000}();
        uint256 used = start - gasleft();
        emit log_named_uint("16 real pools both currencies, rejecting king, bid gas used", used);
        assertLt(used, king.CROWN_DISTRIBUTE_GAS());
        assertApproxEqAbs(liq.claimable(address(outgoing)) - previousClaim, 0.016 ether, 16);
        assertEq(king.claimable(address(outgoing)), 0.01 ether);
        for (uint256 i; i < 16; ++i) {
            assertApproxEqAbs(PadToken(liq.getPool(i).token).balanceOf(address(outgoing)), 1000 ether, 1);
            assertEq(liq.getPool(i).failures, 0);
        }
    }
}

contract AuditV3GameTest is BaseTest {
    function setUp() public override {
        super.setUp();
        openPad();
    }

    function test_tenBlocksPerSecondSixtySecondRollerNeverExpiresWithResolver() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        for (uint256 i; i < 10; ++i) {
            rollAs(pvp, players[0]);
            vm.warp(vm.getBlockTimestamp() + 1);
            arb.advance(10);
            vm.prank(players[10]);
            if (i % 2 == 0) pvp.resolvePending(16);
            else pad.upkeep();
            assertTrue(pvp.getRoll(i).resolved);
            assertFalse(pvp.getRoll(i).expired);
            assertTrue(pvp.getRoll(i).delta != 0);
            vm.warp(vm.getBlockTimestamp() + 59);
            arb.advance(590);
        }
        assertEq(pvp.claimable(players[10]), 10 * pvp.ROLL_TIP());
        assertEq(pvp.claimable(address(pad)), 0, "upkeep tip belongs to its actual caller");
        assertEq(pvp.pot(), 10 * 0.00018 ether);
        assertEq(pvp.ethRaised(), 10 * 0.0018 ether);
        uint256 before = players[10].balance;
        vm.prank(players[10]);
        pvp.claim();
        assertEq(players[10].balance - before, 10 * pvp.ROLL_TIP());
        vm.prank(players[10]);
        vm.expectRevert(abi.encodeWithSignature("PadNothing()"));
        pvp.claim();
        pvp.resolvePending(16);
        assertEq(pvp.claimable(players[10]), 0, "a resolved roll cannot pay twice");
        assertEq(address(pvp).balance, pvp.ethRaised() + pvp.pot());
    }

    function test_nonGenesisSplitAndExpiredTipGoesToPotWithPenalty() public {
        graduatePvp();
        PadGame g = PadGame(pad.gameOf(pad.launch("Tips", "TIP", "")));
        mintAll(g, 1);
        advance(10 minutes);
        uint256 burn = liq.burnBucket() + liq.totalBurnedEth();
        rollAs(g, players[0]);
        assertEq(g.ethRaised(), 0.0018 ether);
        assertEq(g.pot(), 0.00014 ether);
        assertEq(liq.burnBucket() + liq.totalBurnedEth() - burn, 0.00004 ether);
        assertEq(address(g).balance, g.ethRaised() + g.pot() + g.ROLL_TIP());
        arb.advance(10);
        vm.prank(players[10]);
        g.resolvePending(16);
        assertEq(g.claimable(players[10]), 0.00002 ether);
        int256 height = g.getImp(0).height;
        assertTrue(height != 0);
        vm.warp(vm.getBlockTimestamp() + 60);
        arb.advance(600);
        rollAs(g, players[0]);
        uint256 pot = g.pot();
        arb.advance(258);
        vm.prank(players[9]);
        g.resolvePending(16);
        assertTrue(g.getRoll(1).expired);
        assertEq(g.getImp(0).height, 0, "expiry still moves up to four toward zero");
        assertEq(g.pot(), pot + g.ROLL_TIP());
        assertEq(g.claimable(players[9]), 0);
        g.resolvePending(16);
        assertEq(g.pot(), pot + g.ROLL_TIP());
        assertEq(address(g).balance, g.ethRaised() + g.pot() + g.claimable(players[10]));
    }

    function test_resolveBatchClampsToSixteenAndLowGasStopsSafely() public {
        for (uint256 i; i < 33; ++i) {
            address who = address(uint160(0x123000 + i));
            vm.deal(who, 1 ether);
            vm.prank(who);
            pvp.enter{value: 0.001 ether}();
        }
        advance(10 minutes);
        for (uint256 i; i < 33; ++i) {
            rollAs(pvp, pvp.getImp(i).owner);
        }
        arb.advance(4);
        vm.prank(players[10]);
        pvp.resolvePending(type(uint256).max);
        assertEq(pvp.pendingCount(), 17);
        assertEq(pvp.claimable(players[10]), 16 * pvp.ROLL_TIP());
        vm.prank(players[9]);
        (bool ok,) = address(pvp).call{gas: 300_000}(abi.encodeCall(PadGame.resolvePending, (16)));
        assertTrue(ok);
        uint256 resolved = 17 - pvp.pendingCount();
        assertGt(resolved, 0);
        assertLt(resolved, 16);
        assertEq(pvp.claimable(players[9]), resolved * pvp.ROLL_TIP());
        pvp.resolvePending(16);
        assertEq(pvp.pendingCount(), 0);
        assertEq(gameClaims(pvp), 33 * pvp.ROLL_TIP());
    }

    function test_lapsedSeedIsIndependentOfCallerAndCaptureDelayAndBountyPaidOnce() public {
        mintAll(pvp, 5);
        assertEq(pvp.drawBounty(), pvp.ENTRY_PRICE());
        assertEq(liq.burnBucket(), 4 * pvp.ENTRY_PRICE());
        vm.warp(pvp.signupEnd());
        pvp.draw(32);
        uint256 commit = pvp.drawCommitBlock();
        uint256 snapshot = vm.snapshotState();
        arb.set(commit + 258);
        uint256 before = players[9].balance;
        vm.prank(players[9]);
        pvp.draw(32);
        assertEq(players[9].balance - before, pvp.ENTRY_PRICE());
        bytes32 expected = keccak256(abi.encode(address(pvp), commit, uint256(5)));
        assertEq(pvp.drawSeed(), expected);
        address[5] memory order;
        for (uint256 i; i < 5; ++i) {
            order[i] = pvp.getImp(i).owner;
        }
        vm.revertToState(snapshot);
        arb.set(commit + 100_000);
        Rejector rejector = new Rejector();
        vm.prank(address(rejector));
        pvp.draw(1);
        assertEq(pvp.claimable(address(rejector)), pvp.ENTRY_PRICE());
        assertEq(pvp.drawBounty(), 0);
        arb.advance(100_000);
        while (!pvp.drawComplete()) pvp.draw(1);
        for (uint256 i; i < 5; ++i) {
            assertEq(pvp.getImp(i).owner, order[i]);
        }
        assertEq(pvp.drawSeed(), expected);
        assertEq(pvp.drawCommitBlock(), commit);
        pvp.draw(32);
        assertEq(pvp.claimable(address(rejector)), pvp.ENTRY_PRICE());
        assertEq(address(pvp).balance, pvp.ENTRY_PRICE());
    }

    function test_upkeepSeedBountyGoesToCallerAndNotPad() public {
        mintAll(pvp, 5);
        vm.warp(pvp.signupEnd());
        pad.upkeep();
        arb.advance(4);
        uint256 before = players[9].balance;
        vm.prank(players[9]);
        pad.upkeep();
        assertTrue(pvp.drawSeeded());
        assertEq(players[9].balance - before, pvp.ENTRY_PRICE());
        assertEq(pvp.drawBounty(), 0);
        vm.prank(players[10]);
        pad.upkeep();
        assertEq(players[10].balance, 10 ether);
    }
}
