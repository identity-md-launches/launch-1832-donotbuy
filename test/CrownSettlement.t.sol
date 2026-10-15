// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {IPoolManager, ModifyLiquidityParams, PoolKey} from "../src/interfaces/Interfaces.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Revision finding 8b022036: a pre-crown settlement must cover every pool the bid's gas
/// fits (at least 16), and pools it does not reach stay owed to the outgoing king, so a bidder can
/// neither starve the walk nor steer the public cursor to collect the previous reign's fees.
contract CrownSettlementTest is BaseTest {
    bytes32 constant FEES_COLLECTED = keccak256("FeesCollected(uint256,address,uint256,uint256)");
    bytes32 constant CROWNED = keccak256("Crowned(address,address,uint256,uint256,uint256)");

    function setUp() public override {
        super.setUp();
        graduatePvp();
    }

    function _addPools(uint256 n) internal {
        vm.pauseGasMetering();
        for (uint256 i; i < n; ++i) {
            PadGame game = PadGame(pad.gameOf(pad.launch("Pool", "P", "")));
            playOut(game, 1, 1);
            graduateGame(game);
        }
        vm.resumeGasMetering();
    }

    /// @dev Counts FeesCollected logs before and after the Crowned event, and who they paid.
    function _collections(Vm.Log[] memory logs, address payee) internal view returns (uint256 before, uint256 after_) {
        bool crowned;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(king) && logs[i].topics[0] == CROWNED) crowned = true;
            if (logs[i].emitter == address(liq) && logs[i].topics[0] == FEES_COLLECTED) {
                if (address(uint160(uint256(logs[i].topics[2]))) != payee) continue;
                if (crowned) ++after_;
                else ++before;
            }
        }
    }

    function test_bidderCannotSteerCursorToDivertReignFees() public {
        _addPools(17);
        assertEq(liq.poolCount(), 18);
        address oldKing = players[8];
        address bidder = players[9];
        vm.prank(oldKing);
        king.takeCrown{value: 0.01 ether}();
        vm.warp(king.challengeOpensAt());
        // The reviewer's attack: nudge the public cursor so two rich pools sit outside a 16-index window.
        vm.prank(bidder);
        liq.distribute(1);
        uint256 c = liq.distributeCursor();
        uint256 rich1 = (c + 16) % 18;
        uint256 rich2 = (c + 17) % 18;
        for (uint256 i; i < 18; ++i) {
            bool rich = i == rich1 || i == rich2;
            donateFees(liq.poolKey(liq.getPool(i).token), rich ? 0.05 ether : 0.0001 ether, 0);
        }
        uint256 oldBefore = oldKing.balance;
        uint256 bidBefore = bidder.balance;
        vm.recordLogs();
        vm.prank(bidder);
        king.takeCrown{value: 0.011 ether}();
        assertEq(king.king(), bidder);
        assertEq(bidder.balance + 0.011 ether - bidBefore, 0, "bid tx pays the bidder nothing");
        assertEq(liq.claimable(bidder), 0);
        assertApproxEqAbs(oldKing.balance - oldBefore, 0.01 ether + 0.1016 ether, 18, "refund plus every pool");
        (uint256 oldReign, uint256 oldAfter) = _collections(vm.getRecordedLogs(), oldKing);
        assertEq(oldReign, 18, "all eighteen pools settle before the crown moves");
        assertEq(oldAfter, 0);
        assertEq(liq.reign(), 1);
        assertEq(liq.reignKing(0), oldKing);
        for (uint256 i; i < 18; ++i) {
            assertEq(liq.getPool(i).settledReign, 1);
        }
    }

    function test_poolsBeyondTheBidGasStayOwedToTheOutgoingKing() public {
        _addPools(59);
        assertEq(liq.poolCount(), 60);
        address oldKing = players[8];
        address bidder = players[9];
        vm.prank(oldKing);
        king.takeCrown{value: 0.01 ether}();
        vm.warp(king.challengeOpensAt());
        for (uint256 i; i < 60; ++i) {
            donateFees(liq.poolKey(liq.getPool(i).token), 0.001 ether, 0);
        }
        uint256 oldBefore = oldKing.balance;
        uint256 bidBefore = bidder.balance;
        vm.recordLogs();
        // The minimum stipend the bid must carry: the walk stops when gas no longer fits a collection.
        vm.prank(bidder);
        king.takeCrown{value: 0.011 ether, gas: 5_800_000}();
        assertEq(king.king(), bidder);
        (uint256 settled,) = _collections(vm.getRecordedLogs(), oldKing);
        emit log_named_uint("pools settled by a minimum-gas bid, sixty real pools", settled);
        assertGe(settled, 16, "at least sixteen pools settle");
        assertLt(settled, 60, "the minimum stipend does not fit sixty pools");
        uint256 unreached;
        for (uint256 i; i < 60; ++i) {
            if (liq.getPool(i).settledReign == 0) ++unreached;
        }
        assertEq(unreached, 60 - settled);
        assertEq(liq.reignKing(0), oldKing);
        // Anyone collecting the rest pays the outgoing king, never the bidder.
        for (uint256 i; i < 4; ++i) {
            vm.prank(players[10]);
            liq.distribute(16);
        }
        for (uint256 i; i < 60; ++i) {
            assertEq(liq.getPool(i).settledReign, 1, "every pool settled for the new reign");
        }
        // Donations plus the genesis pool's real swap fees from the fixture's burn buys.
        uint256 oldGain = oldKing.balance - oldBefore;
        assertGe(oldGain, 0.01 ether + 0.06 ether - 60, "refund plus all sixty pools");
        assertLt(oldGain, 0.01 ether + 0.061 ether);
        assertEq(bidder.balance + 0.011 ether, bidBefore, "bidder collects nothing of the old reign");
        assertEq(liq.claimable(bidder), 0);
        // Fees earned from now on belong to the new king.
        donateFees(liq.poolKey(liq.getPool(1).token), 0.002 ether, 0);
        vm.prank(players[10]);
        liq.retryPool(1);
        assertApproxEqAbs(bidder.balance + 0.011 ether - bidBefore, 0.002 ether, 1);
    }

    function test_settlementRevertsBelowSixteenPoolsAndSucceedsAbove() public {
        _addPools(17);
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        for (uint256 i; i < 18; ++i) {
            donateFees(liq.poolKey(liq.getPool(i).token), 0.001 ether, 0);
        }
        vm.prank(address(king));
        (bool ok, bytes memory reason) = address(liq).call{gas: 1_200_000}(abi.encodeCall(PadLiquidity.settleCrown, ()));
        assertFalse(ok, "fewer than sixteen pools fit");
        assertEq(reason, abi.encodeWithSignature("PadCollectionGas()"));
        assertEq(liq.reign(), 0, "a failed walk records nothing");
        assertEq(liq.getPool(0).settledReign, 0);
        vm.recordLogs();
        vm.prank(address(king));
        (ok,) = address(liq).call{gas: 2_800_000}(abi.encodeCall(PadLiquidity.settleCrown, ()));
        assertTrue(ok);
        (uint256 settled,) = _collections(vm.getRecordedLogs(), players[8]);
        assertGe(settled, 16);
        assertEq(liq.reign(), 1);
        assertEq(liq.reignKing(0), players[8]);
    }

    function test_nonKingCannotSettleOrCloseAReign() public {
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        vm.prank(players[9]);
        vm.expectRevert(abi.encodeWithSignature("PadNotKing()"));
        liq.settleCrown();
        assertEq(liq.reign(), 0);
    }

    function test_firstCrownOpensNoReignAndPaysPreCrownFeesToTheFirstKing() public {
        donateFees(liq.poolKey(address(pvpToken)), 0.05 ether, 0);
        liq.distribute(16);
        assertEq(liq.getPool(0).ethFees, 0, "no king, fees stay in the position");
        uint256 before = players[8].balance;
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        assertEq(liq.reign(), 0, "the first crown closes no reign");
        liq.distribute(16);
        // The bid's own upkeep or this call pays the first king everything accrued before any crown.
        assertGe(players[8].balance + 0.01 ether - before, 0.05 ether - 1);
        assertEq(liq.getPool(0).settledReign, 0);
    }

    function test_brokenPoolSkippedByTwoCrownsPaysTheEarliestUnsettledReign() public {
        _addPools(1);
        address a = players[8];
        address b = players[9];
        address c = players[10];
        vm.prank(a);
        king.takeCrown{value: 0.01 ether}();
        PoolKey memory broken = liq.poolKey(address(pvpToken));
        donateFees(broken, 0.03 ether, 0);
        vm.mockCallRevert(
            address(pm),
            abi.encodeCall(
                IPoolManager.modifyLiquidity, (broken, ModifyLiquidityParams(-887200, 887200, 0, 0), bytes(""))
            ),
            bytes("pool failure")
        );
        for (uint256 i; i < 3; ++i) {
            liq.retryPool(0);
            arb.advance(1);
        }
        assertEq(liq.getPool(0).failures, 3);
        vm.warp(king.challengeOpensAt());
        vm.prank(b);
        king.takeCrown{value: 0.011 ether}();
        vm.warp(king.challengeOpensAt());
        vm.prank(c);
        king.takeCrown{value: 0.0121 ether}();
        assertEq(liq.reign(), 2);
        assertEq(liq.reignKing(0), a);
        assertEq(liq.reignKing(1), b);
        assertEq(liq.getPool(0).settledReign, 0, "the broken pool was never settled");
        assertEq(liq.getPool(1).settledReign, 2);
        vm.clearMockedCalls();
        uint256 aBefore = a.balance;
        uint256 bBefore = b.balance;
        uint256 cBefore = c.balance;
        vm.prank(players[11]);
        assertTrue(liq.retryPool(0));
        assertEq(liq.getPool(0).failures, 0);
        // The donation plus the genesis pool's real swap fees from the fixture's burn buys.
        assertGe(a.balance - aBefore, 0.03 ether - 1, "the earliest unsettled reign is paid");
        assertLt(a.balance - aBefore, 0.031 ether);
        assertEq(b.balance, bBefore);
        assertEq(c.balance, cBefore);
        assertEq(liq.getPool(0).settledReign, 2, "now settled for the current reign");
        uint256 aPaid = a.balance;
        donateFees(broken, 0.01 ether, 0);
        liq.retryPool(0);
        assertApproxEqAbs(c.balance - cBefore, 0.01 ether, 1, "later fees go to the current king");
        assertEq(a.balance, aPaid, "the earlier king gets nothing more");
    }

    function test_extraBidGasSettlesMorePoolsInOneBid() public {
        _addPools(59);
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        vm.warp(king.challengeOpensAt());
        for (uint256 i; i < 60; ++i) {
            donateFees(liq.poolKey(liq.getPool(i).token), 0.001 ether, 0);
        }
        uint256 before = players[8].balance;
        vm.recordLogs();
        uint256 start = gasleft();
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether, gas: 12_000_000}();
        emit log_named_uint("takeCrown gas, sixty real pools fully settled", start - gasleft());
        (uint256 settled,) = _collections(vm.getRecordedLogs(), players[8]);
        assertEq(settled, 60, "a generous bid settles every pool before the crown moves");
        assertGe(players[8].balance - before, 0.07 ether - 60);
        assertLt(players[8].balance - before, 0.071 ether);
        for (uint256 i; i < 60; ++i) {
            assertEq(liq.getPool(i).settledReign, 1);
        }
    }
}
