// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";
import {PadGame} from "src/PadGame.sol";

/// @notice Tests the cap through public donations, real crown funding and actual paid rolls.
/// In particular, no vm.store or impersonation of the pad is used to manufacture fundedPot.
contract V3CarryPropertiesTest is BaseTest {
    struct Settlement {
        uint256 earned;
        uint256 funded;
        uint256 cap;
        uint256 carryBefore;
        uint256 expectedPull;
        uint256 receiptsBefore;
    }

    function setUp() public override {
        super.setUp();
        graduatePvp();
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_onlyUnusedReleaseAllowanceLeavesCarryAtFinalization(
        uint256 livingSeed,
        uint256 donationSeed,
        uint256 kingSeed
    ) public {
        uint256 living = bound(livingSeed, 0, 6);
        uint256 donation = bound(donationSeed, 0, 0.1 ether);
        PadGame game = _prepareGame(donation, kingSeed);
        _playToEnd(game, living);
        _checkSettlement(game, living);
    }

    function _prepareGame(uint256 donation, uint256 kingSeed) private returns (PadGame game) {
        game = PadGame(pad.gameOf(pad.launch("Carry allowance", "CAP", "")));
        mintAll(game, 6);
        // Zero, exactly the minimum bid, and overfunded games all remain in the input domain.
        uint256 mode = kingSeed % 3;
        if (mode != 0) {
            uint256 bid = mode == 1 ? 0.01 ether : bound(kingSeed, 0.01 ether, 1 ether);
            vm.prank(players[8]);
            king.takeCrown{value: bid}();
            assertEq(game.fundedPot(), bid / 2);
        }
        vm.prank(players[11]);
        pad.fundCarry{value: donation}();
        uint256 carryBeforeDraw = pad.carryPot();
        uint256 fundedBeforeDraw = game.fundedPot();
        advance(10 minutes);
        assertTrue(game.drawComplete());
        assertEq(pad.carryPot(), carryBeforeDraw, "draw consumed carry");
        assertEq(game.fundedPot(), fundedBeforeDraw, "draw added funded ETH");
    }

    function _playToEnd(PadGame game, uint256 living) private {
        // At 10 blocks/s, these deliberately unattended rolls expire between nine-minute
        // heartbeats. The selected wallets remain alive; the other wallets die naturally.
        for (uint256 minute; minute <= 45; minute += 9) {
            vm.warp(game.playStart() + minute * 60);
            arb.advance(5_400);
            if (game.ended()) break;
            for (uint256 i; i < living; ++i) {
                rollAs(game, players[i]);
            }
        }
        if (vm.getBlockTimestamp() < game.endTime()) vm.warp(game.endTime());
        arb.advance(6_000);
        game.resolvePending(16);
    }

    function _checkSettlement(PadGame game, uint256 living) private {
        Settlement memory s;
        s.earned = game.rollPot();
        s.funded = game.fundedPot();
        s.cap = game.fundedReleaseCap();
        assertLe(s.cap, s.earned * 3, "release cap exceeds three times earned pot");
        assertLe(s.cap, game.ethRaised() * 15 / 100, "release cap exceeds fifteen percent of curve ETH");
        s.carryBefore = pad.carryPot();
        uint256 unused = living >= 5 && s.cap > s.funded ? s.cap - s.funded : 0;
        s.expectedPull = unused < s.carryBefore ? unused : s.carryBefore;
        s.receiptsBefore = _beneficiaryBalances();
        vm.recordLogs();
        vm.prank(players[10]);
        game.finalize();
        _checkCarryEvents(vm.getRecordedLogs(), game.launchId(), s.expectedPull);
        assertEq(game.livingAtEnd(), living);
        assertEq(game.fundedPot(), 0);
        assertEq(game.pot(), 0);
        uint256 available = s.funded + s.expectedPull;
        uint256 fundedAllowed = living < 5 ? 0 : (available < s.cap ? available : s.cap);
        uint256 paid = _beneficiaryBalances() - s.receiptsBefore;
        assertLe(paid, s.earned + fundedAllowed, "funded ETH escaped beyond the release cap");
        assertEq(
            paid + pad.carryPot() - (s.carryBefore - s.expectedPull),
            s.earned + available,
            "payouts and returned carry do not conserve the entire game pot"
        );
        assertEq(address(game).balance, game.ethRaised(), "finalization left unaccounted pot ETH");
        assertEq(address(pad).balance, pad.carryPot());
        uint256 carryAfter = pad.carryPot();
        vm.expectRevert(abi.encodeWithSignature("PadNotFinalizable()"));
        game.finalize();
        assertEq(pad.carryPot(), carryAfter, "finalizing twice pulled carry again");
    }

    function _checkCarryEvents(Vm.Log[] memory logs, uint256 id, uint256 expectedPull) private view {
        uint256 pulled;
        uint256 pulls;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pad) && logs[i].topics[0] == keccak256("CarryPaid(uint256,uint256)")) {
                assertEq(uint256(logs[i].topics[1]), id);
                pulled += abi.decode(logs[i].data, (uint256));
                ++pulls;
            }
        }
        assertEq(pulled, expectedPull, "carry transfer exceeded or missed the unused allowance");
        assertEq(pulls, expectedPull == 0 ? 0 : 1);
    }

    function _beneficiaryBalances() private view returns (uint256 total) {
        for (uint256 i; i < 6; ++i) {
            total += players[i].balance;
        }
        total += players[10].balance;
    }
}
