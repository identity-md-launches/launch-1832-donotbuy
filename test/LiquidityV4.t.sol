// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {PoolKey, IPoolManager, ModifyLiquidityParams} from "../src/interfaces/Interfaces.sol";
import {V4Manager, StateLibrary, PoolId} from "./RealV4.sol";
import {TickMath} from "../lib/v4-core/src/libraries/TickMath.sol";
import {Vm} from "forge-std/Vm.sol";

contract LiquidityV4Test is BaseTest {
    function test_realPoolManagerGraduatesSoldOutAfter2400ActualRolls() public {
        openPad();
        vm.pauseGasMetering();
        address[] memory entrants = new address[](200);
        for (uint256 i; i < 200; ++i) {
            entrants[i] = address(uint160(0x200000 + i));
            vm.deal(entrants[i], 1 ether);
            vm.prank(entrants[i]);
            pvp.enter{value: 0.001 ether}();
        }
        advance(10 minutes);
        for (uint256 r; r < 12; ++r) {
            for (uint256 i; i < 200; ++i) {
                vm.prank(entrants[i]);
                pvp.roll{value: 0.002 ether}();
            }
            advance(61);
        }
        assertEq(pvp.rollCount(), 2400);
        assertEq(pvp.ethRaised(), 4 ether);
        assertEq(pvp.tokensSold(), 800_000_000 ether);
        assertFalse(pvp.bellRang(), "12 rolls cannot reach height 50");
        advance(10 minutes);
        while (pvp.pendingCount() != 0) pvp.resolvePending(32);
        pvp.finalize();
        vm.resumeGasMetering();
        graduateGame(pvp);
        assertTrue(pvp.graduated() && !pvp.failed());
        assertTrue(pvpToken.unlocked());
        assertEq(pvpToken.balanceOf(address(pvp)), 0);
        assertGt(liq.getPool(0).liquidity, 0);
        assertGt(address(pm).balance, 3.99 ether);
        assertEq(pvpToken.totalSupply(), 1_000_000_000 ether);
        _assertRealState(pvpToken);
    }

    function test_realPoolManagerSmallestRaiseGraduatesAndConservesAccounting() public {
        openPad();
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        advance(10 minutes);
        pvp.finalize();
        pm.sync(address(pvpToken)); // dirty transient currency from another caller in this transaction
        graduateGame(pvp);
        assertEq(pvp.ethRaised(), 0.0018 ether);
        assertTrue(pvp.graduated() && !pvp.failed());
        assertGt(pvpToken.balanceOf(address(pm)), 0);
        assertGt(pvpToken.balanceOf(DEAD), 0);
        assertEq(
            pvpToken.balanceOf(address(pm)) + pvpToken.balanceOf(DEAD) + pvpToken.balanceOf(players[0])
                + pvpToken.balanceOf(address(liq)),
            pvpToken.totalSupply()
        );
        assertEq(address(liq).balance, liq.burnBucket());
        _assertRealState(pvpToken);
    }

    function _assertRealState(PadToken token) internal view {
        PoolKey memory key = liq.poolKey(address(token));
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (uint160 price, int24 tick, uint24 protocolFee, uint24 fee) = StateLibrary.getSlot0(V4Manager(address(pm)), id);
        assertEq(liq.sqrtPriceOf(key), price, "mirror extsload matches upstream StateLibrary");
        assertEq(TickMath.getTickAtSqrtPrice(price), tick);
        assertEq(protocolFee, 0);
        assertEq(fee, 10000);
        assertEq(
            StateLibrary.getLiquidity(V4Manager(address(pm)), id),
            liq.getPool(liq.poolIndexOf(token.game() == address(pvp) ? 1 : PadGame(token.game()).launchId()) - 1)
            .liquidity
        );
    }

    function test_realTradingTokenFeesPaidInKindWithoutSwap() public {
        graduatePvp();
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        PoolKey memory key = liq.poolKey(address(pvpToken));
        vm.prank(players[0]);
        pvpToken.transfer(address(router), 100_000 ether);
        router.trade(key, false, 100_000 ether);
        uint256 before = pvpToken.balanceOf(players[8]);
        uint256 feesBefore = liq.getPool(0).tokenFees;
        uint160 price = managerPrice(key);
        king.distribute(1);
        uint256 got = pvpToken.balanceOf(players[8]) - before;
        assertGt(got, 0);
        assertEq(got, liq.getPool(0).tokenFees - feesBefore);
        assertEq(managerPrice(key), price, "collection never swaps");
        assertEq(pvpToken.balanceOf(address(liq)), 0);
        assertEq(address(liq).balance, liq.burnBucket());
    }

    function test_outgoingKingReceivesFeesBeforeCrownEvent() public {
        graduatePvp();
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        donateFees(liq.poolKey(address(pvpToken)), 0.1 ether, 1000 ether);
        uint256 previousBalance = players[8].balance;
        vm.warp(king.challengeOpensAt());
        vm.recordLogs();
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether}();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool paidBefore;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(liq) && logs[i].topics[0] == keccak256("KingPaid(address,uint256,bool)")) {
                if (address(uint160(uint256(logs[i].topics[1]))) == players[8]) paidBefore = true;
            }
            if (
                logs[i].emitter == address(king)
                    && logs[i].topics[0] == keccak256("Crowned(address,address,uint256,uint256,uint256)")
            ) {
                assertTrue(paidBefore, "outgoing king must be paid before dethroning");
            }
        }
        assertTrue(paidBefore);
        assertApproxEqAbs(players[8].balance - previousBalance, 0.11 ether, 1, "refund plus ETH fees");
        assertApproxEqAbs(pvpToken.balanceOf(players[8]), 1000 ether, 1);
        assertEq(king.king(), players[9]);
    }

    function test_oneFailingPoolCannotBlockBidOrHealthyPoolFees() public {
        graduatePvp();
        uint256 id = pad.launch("Healthy", "OK", "");
        PadGame game = PadGame(pad.gameOf(id));
        playOut(game, 2, 1);
        graduateGame(game);
        PoolKey memory broken = liq.poolKey(address(pvpToken));
        PoolKey memory healthy = liq.poolKey(pad.tokenOf(id));
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        donateFees(broken, 0.02 ether, 0);
        donateFees(healthy, 0.03 ether, 0);
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
        uint256 before = players[8].balance;
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether}();
        assertEq(king.king(), players[9]);
        assertApproxEqAbs(players[8].balance - before, 0.04 ether, 1e10, "healthy pool paid plus old bid refund");
        vm.clearMockedCalls();
        uint256 newBefore = players[9].balance;
        uint256 oldBefore = players[8].balance;
        assertTrue(liq.retryPool(0));
        assertEq(liq.getPool(0).failures, 0);
        assertGe(players[8].balance - oldBefore, 0.02 ether - 10, "failed pool stays owed to the king of its reign");
        assertEq(players[9].balance, newBefore);
    }

    function test_crownPrecollectsAllEighteenPools() public {
        graduatePvp();
        vm.pauseGasMetering();
        for (uint256 i; i < 17; ++i) {
            PadGame game = PadGame(pad.gameOf(pad.launch("Pool", "P", "")));
            playOut(game, 1, 1);
            graduateGame(game);
        }
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        for (uint256 i; i < 18; ++i) {
            donateFees(liq.poolKey(liq.getPool(i).token), 0.001 ether, 0);
        }
        vm.warp(king.challengeOpensAt());
        vm.resumeGasMetering();
        vm.recordLogs();
        uint256 oldBefore = players[8].balance;
        uint256 start = gasleft();
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether}();
        uint256 used = start - gasleft();
        emit log_named_uint("takeCrown gas, eighteen real pools", used);
        assertLt(used, 8_000_000);
        assertApproxEqAbs(players[8].balance - oldBefore, 0.028 ether, 18, "refund plus all eighteen pools");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 collectedBefore;
        uint256 collectedAfter;
        bool crowned;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(king)
                    && logs[i].topics[0] == keccak256("Crowned(address,address,uint256,uint256,uint256)")
            ) crowned = true;
            if (
                logs[i].emitter == address(liq)
                    && logs[i].topics[0] == keccak256("FeesCollected(uint256,address,uint256,uint256)")
            ) {
                if (crowned) ++collectedAfter;
                else ++collectedBefore;
            }
        }
        assertEq(collectedBefore, 18, "the whole walk fits the stipend");
        assertEq(collectedAfter, 2, "normal upkeep follows crowning and finds nothing of the old reign");
        uint256 cursor = liq.distributeCursor();
        liq.distribute(type(uint256).max);
        assertEq(liq.distributeCursor() % 18, (cursor + 16) % 18, "public distribute is bounded too");
    }

    function test_failedDistributorBlocksCrown() public {
        graduatePvp();
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        vm.warp(king.challengeOpensAt());
        vm.mockCallRevert(address(liq), abi.encodeWithSelector(PadLiquidity.settleCrown.selector), bytes("failure"));
        vm.prank(players[9]);
        vm.expectRevert(bytes("failure"));
        king.takeCrown{value: 0.011 ether}();
        assertEq(king.king(), players[8]);
    }

    function test_realBurnIgnoresAnUnrelatedPriorTokenSync() public {
        graduatePvp();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 before = liq.totalBurnedEth();
        pm.sync(address(pvpToken));
        liq.burnChunk();
        assertGt(liq.totalBurnedEth(), before);
    }

    function test_collectPoolRejectsExternalCallers() public {
        vm.expectRevert(abi.encodeWithSignature("PadNotSelf()"));
        liq.collectPool(0, players[0]);
    }
}
