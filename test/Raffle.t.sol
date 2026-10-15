// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadLib} from "../src/libs/PadLib.sol";
import {PadToken} from "../src/PadToken.sol";

contract EntryWallet {
    function enter(PadGame game) external payable {
        game.enter{value: msg.value}();
    }
}

/// @dev Isolated clone fixture to exercise the gate and a malicious burn callback.
contract EntryGate {
    bool public opened;

    function create(address template, address burn) external returns (PadGame game) {
        game = PadGame(PadLib.clone(template));
        game.initialize(1, address(this), burn, true);
    }

    function open() external {
        opened = true;
    }
    function upkeepFor(address) external {}
    function noteFirstEntry(uint256) external {}
    function takeCarry(uint256, uint256) external {}
}

contract ReentrantBurn {
    PadGame public game;
    address public entrant;
    bool public blocked;
    bool public effectsVisible;

    function arm(PadGame game_, address entrant_) external {
        game = game_;
        entrant = entrant_;
    }

    function fundBurn() external payable {
        effectsVisible = game.entryCount() == 2 && game.entryOf(entrant) == 2;
        (bool ok,) = address(game).call{value: msg.value}(abi.encodeCall(PadGame.enter, ()));
        blocked = !ok;
    }
}

contract RaffleTest is BaseTest {
    function setUp() public override {
        super.setUp();
        openPad();
    }

    function _enterMany(PadGame game, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(0x100000 + i));
            vm.deal(who, 1 ether);
            vm.prank(who);
            game.enter{value: 0.001 ether}();
        }
    }

    function _commit(PadGame game) internal {
        vm.warp(game.signupEnd());
        game.draw(32);
        assertTrue(game.drawCommitted());
        assertEq(game.drawCommitBlock(), arb.number());
        assertFalse(game.drawSeeded());
        assertEq(game.impCount(), 0);
    }

    function _complete(PadGame game, uint256 chunk) internal {
        arb.advance(4);
        while (!game.drawComplete()) game.draw(chunk);
    }

    function test_entryGateAndReentrantBurnCallback() public {
        EntryGate gate = new EntryGate();
        ReentrantBurn burn = new ReentrantBurn();
        PadGame game = gate.create(address(gameTemplate), address(burn));
        burn.arm(game, players[0]);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadPadNotOpen()"));
        game.enter{value: 0.001 ether}();
        assertEq(game.entryCount(), 0);
        gate.open();
        vm.prank(players[0]);
        game.enter{value: 0.001 ether}();
        burn.arm(game, players[1]);
        vm.prank(players[1]);
        game.enter{value: 0.001 ether}();
        assertTrue(burn.blocked());
        assertTrue(burn.effectsVisible(), "CEI before external funding call");
        assertEq(game.entryCount(), 2);
        assertEq(address(burn).balance, 0.001 ether);
        assertEq(game.entryOf(address(burn)), 0);
    }

    function test_entryFeesAlsoFundBurnOnOrdinaryGames() public {
        graduatePvp();
        PadGame game = PadGame(pad.gameOf(pad.launch("Next", "NXT", "")));
        uint256 accounted = liq.burnBucket() + liq.totalBurnedEth();
        uint256 potBefore = game.pot();
        vm.prank(players[9]);
        game.enter{value: 0.001 ether}();
        assertEq(liq.burnBucket() + liq.totalBurnedEth() - accounted, 0);
        assertEq(game.pot(), potBefore);
        assertEq(game.ethRaised(), 0);
        assertEq(game.drawBounty(), 0.001 ether);
    }

    function test_entryExactFeeOnePerWalletAndNoRefund() public {
        vm.startPrank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadEntryPrice()"));
        pvp.enter();
        vm.expectRevert(abi.encodeWithSignature("PadEntryPrice()"));
        pvp.enter{value: 0.001 ether - 1}();
        vm.expectRevert(abi.encodeWithSignature("PadEntryPrice()"));
        pvp.enter{value: 0.001 ether + 1}();
        pvp.enter{value: 0.001 ether}();
        vm.expectRevert(abi.encodeWithSignature("PadOneEntryPerWallet()"));
        pvp.enter{value: 0.001 ether}();
        vm.expectRevert(abi.encodeWithSignature("PadNothing()"));
        pvp.claim();
        vm.stopPrank();
        assertEq(players[0].balance, 9.999 ether);
        assertEq(pvp.entryCount(), 1);
        assertEq(pvp.impCount(), 0);
        assertEq(pvp.pot(), 0);
        assertEq(pvp.ethRaised(), 0);
        assertEq(address(pvp).balance, 0.001 ether);
        assertEq(pvp.drawBounty(), 0.001 ether);
        assertEq(liq.burnBucket(), 0);
        assertEq(address(liq).balance, liq.burnBucket());
        liq.burnChunk();
        assertEq(liq.totalBurnedEth(), 0);
        assertEq(liq.burnBucket(), 0);
    }

    function test_contractWalletCanEnterAndViewsArePaged() public {
        EntryWallet wallet = new EntryWallet();
        vm.deal(address(this), 1 ether);
        wallet.enter{value: 0.001 ether}(pvp);
        _enterMany(pvp, 205);
        assertEq(pvp.entryOf(address(wallet)), 1);
        address[] memory page = pvp.getEntrants(0, type(uint256).max);
        assertEq(page.length, 200);
        assertEq(page[0], address(wallet));
        page = pvp.getEntrants(200, 200);
        assertEq(page.length, 6);
        assertEq(pvp.getEntrants(206, 1).length, 0);
        assertEq(pvp.getEntrants(type(uint256).max, 1).length, 0);
        assertEq(pvp.getEntrants(0, 0).length, 0);
        vm.prank(address(wallet));
        (uint256 entry, uint256 seat, bool complete) = pvp.myEntry();
        assertEq(entry, 1);
        assertEq(seat, 0);
        assertFalse(complete);
        _commit(pvp);
        _complete(pvp, 7);
        vm.prank(address(wallet));
        (entry, seat, complete) = pvp.myEntry();
        assertEq(entry, 1);
        assertEq(seat, pvp.impOf(address(wallet)));
        assertTrue(complete);
    }

    function test_firstEntryStartsTenMinutesAndLateEntryRejected() public {
        assertEq(pvp.signupEnd(), 0);
        assertEq(pvp.status(), 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _enterMany(pvp, 1);
        assertEq(pvp.firstEntryAt(), vm.getBlockTimestamp());
        assertEq(pvp.signupEnd(), vm.getBlockTimestamp() + 10 minutes);
        assertEq(pvp.playStart(), 0);
        assertEq(pvp.status(), 1);
        vm.warp(pvp.signupEnd() - 1);
        vm.prank(players[0]);
        pvp.enter{value: 0.001 ether}();
        vm.warp(pvp.signupEnd());
        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSignature("PadSignupOver()"));
        pvp.enter{value: 0.001 ether}();
        assertEq(pvp.status(), 7);
        assertFalse(pvp.ended());
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_everyEntrantPlaysAtOrBelow200(uint16 count) public {
        uint256 n = bound(count, 1, 200);
        _enterMany(pvp, n);
        _commit(pvp);
        _complete(pvp, 11);
        assertEq(pvp.impCount(), n);
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(0x100000 + i));
            uint256 seat = pvp.impOf(who);
            assertTrue(seat != 0 && seat <= n);
            assertEq(pvp.getImp(seat - 1).owner, who);
        }
    }

    function test_5000EntriesChunkedDrawGasAndNonselectedFeesStayBurned() public {
        vm.pauseGasMetering();
        _enterMany(pvp, 5000);
        _commit(pvp);
        arb.advance(4);
        vm.resumeGasMetering();
        uint256 totalGas;
        uint256 maxGas;
        while (!pvp.drawComplete()) {
            vm.cool(address(pvp));
            uint256 beforeCount = pvp.impCount();
            uint256 start = gasleft();
            pvp.draw(type(uint256).max);
            uint256 used = start - gasleft();
            if (used > maxGas) maxGas = used;
            totalGas += used;
            assertLe(pvp.impCount() - beforeCount, 32, "bounded regardless of n");
        }
        emit log_named_uint("5000-entry draw max chunk gas (cold game)", maxGas);
        emit log_named_uint("5000-entry draw total gas", totalGas);
        assertLt(maxGas, 3_000_000);
        assertLt(totalGas, 17_000_000);
        assertEq(pvp.impCount(), 200);
        assertEq(liq.burnBucket(), 4.999 ether);
        assertEq(address(pvp).balance, 0);
        uint256 seats;
        for (uint256 i; i < 5000; ++i) {
            address who = address(uint160(0x100000 + i));
            if (pvp.impOf(who) != 0) ++seats;
            assertEq(pvp.claimable(who), 0);
        }
        assertEq(seats, 200);
        uint256 completeAt = pvp.playStart();
        pvp.draw(32);
        assertEq(pvp.playStart(), completeAt, "draw completion is immutable");
    }

    function test_seedUsesOnlyThreeFutureL2HashesAndChunkSizeCannotChangeSeats() public {
        _enterMany(pvp, 250);
        vm.roll(999999999);
        _commit(pvp);
        uint256 commit = arb.number();
        arb.advance(3);
        pvp.draw(32);
        assertFalse(pvp.drawSeeded());
        arb.advance(1);
        bytes32 expected = keccak256(
            abi.encode(
                address(pvp), arb.arbBlockHash(commit + 1), arb.arbBlockHash(commit + 2), arb.arbBlockHash(commit + 3)
            )
        );
        uint256 snapshot = vm.snapshotState();
        while (!pvp.drawComplete()) pvp.draw(1);
        assertEq(pvp.drawSeed(), expected);
        address[] memory order = new address[](200);
        for (uint256 i; i < 200; ++i) {
            order[i] = pvp.getImp(i).owner;
        }
        vm.revertToState(snapshot);
        vm.roll(1);
        while (!pvp.drawComplete()) pvp.draw(32);
        for (uint256 i; i < 200; ++i) {
            assertEq(pvp.getImp(i).owner, order[i]);
        }
    }

    function test_lapsedCommitFallsBackOnceAndNeverRecommits() public {
        _enterMany(pvp, 201);
        _commit(pvp);
        uint256 first = pvp.drawCommitBlock();
        arb.set(first + 258);
        pvp.draw(32);
        bytes32 expected = keccak256(abi.encode(address(pvp), first, uint256(201)));
        assertEq(pvp.drawCommitBlock(), first);
        assertTrue(pvp.drawSeeded());
        assertEq(pvp.drawSeed(), expected);
        assertEq(pvp.impCount(), 32);
        arb.advance(1000);
        while (!pvp.drawComplete()) pvp.draw(32);
        assertEq(pvp.drawSeed(), expected);
        assertEq(pvp.drawCommitBlock(), first);
    }

    function test_hashAtExactly256BlocksOldStillSeeds() public {
        _enterMany(pvp, 1);
        _commit(pvp);
        uint256 commit = pvp.drawCommitBlock();
        arb.set(commit + 257);
        pvp.draw(1);
        assertTrue(pvp.drawComplete());
        assertEq(pvp.drawCommitBlock(), commit);
    }

    function test_noRollUntilAllSeatsDrawnAndDelayedPlayStartsFresh() public {
        _enterMany(pvp, 201);
        vm.prank(address(0x100000));
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.roll{value: 0.002 ether}();
        _commit(pvp);
        arb.advance(4);
        pvp.draw(1);
        address first = pvp.getImp(0).owner;
        vm.prank(first);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.roll{value: 0.002 ether}();
        assertFalse(pvp.isAlive(0));
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        assertFalse(pvp.ended());
        while (!pvp.drawComplete()) pvp.draw(32);
        assertEq(pvp.playStart(), vm.getBlockTimestamp());
        assertEq(pvp.hardEnd(), vm.getBlockTimestamp() + 50 minutes);
        assertEq(pvp.endTime(), vm.getBlockTimestamp() + 10 minutes);
        assertTrue(pvp.isAlive(0));
        vm.prank(first);
        pvp.roll{value: 0.002 ether}();
    }

    function test_upkeepCommitsThenDrawsInBoundedChunksAndKingCountsEntries() public {
        _enterMany(pvp, 4);
        (bool live,) = pvp.isLiveForKing();
        assertFalse(live);
        vm.prank(players[0]);
        pvp.enter{value: 0.001 ether}();
        (live,) = pvp.isLiveForKing();
        assertTrue(live);
        vm.warp(pvp.signupEnd());
        pad.upkeep();
        assertTrue(pvp.drawCommitted());
        assertFalse(pvp.drawSeeded());
        arb.advance(4);
        pad.upkeep();
        assertTrue(pvp.drawComplete());
        (live,) = pvp.isLiveForKing();
        assertTrue(live);
        vm.warp(pvp.playStart() + 10 minutes);
        assertTrue(pvp.ended());
        (live,) = pvp.isLiveForKing();
        assertFalse(live);
    }

    function test_failedGenesisGriefCostsOneFeeEveryRoundAndNeverRefunds() public {
        vm.deal(players[0], 1 ether);
        for (uint256 r; r < 3; ++r) {
            PadGame game = PadGame(pad.gameOf(pad.genesisId()));
            vm.prank(players[0]);
            game.enter{value: 0.001 ether}();
            _commit(game);
            _complete(game, 32);
            vm.warp(game.playStart() + 10 minutes);
            game.finalize();
            graduateGame(game);
            assertTrue(game.failed());
            assertEq(game.claimable(players[0]), 0);
            assertEq(liq.totalBurnedEth(), 0);
            assertEq(liq.burnBucket(), 0);
            pad.restartGenesis();
        }
        assertEq(players[0].balance, 0.997 ether);
        assertEq(pad.genesisId(), 4);
    }

    function test_manySeedsGiveEarlyAndLateEntrantsEqualOpportunity() public {
        vm.pauseGasMetering();
        _enterMany(pvp, 400);
        vm.warp(pvp.signupEnd());
        uint256 snapshot = vm.snapshotState();
        uint256[] memory counts = new uint256[](400);
        uint256 earlySeats;
        // Vary the mocked future L2 blocks, never a caller-selected production seed.
        for (uint256 sample; sample < 256; ++sample) {
            vm.revertToState(snapshot);
            snapshot = vm.snapshotState();
            arb.set(10000 + sample * 10);
            pvp.draw(32);
            arb.advance(4);
            while (!pvp.drawComplete()) pvp.draw(32);
            for (uint256 i; i < 200; ++i) {
                uint256 entrant = uint160(pvp.getImp(i).owner) - 0x100000;
                ++counts[entrant];
                if (entrant < 200) ++earlySeats;
            }
        }
        vm.resumeGasMetering();
        // Each wallet expects 128 selections, standard deviation 8. These generous bounds
        // detect systematic order bias without claiming a cryptographic proof from statistics.
        for (uint256 i; i < 400; ++i) {
            assertGt(counts[i], 80);
            assertLt(counts[i], 176);
        }
        assertApproxEqAbs(earlySeats, 25600, 1000);
    }

    function test_drawBeforeEntryBeforeSignupAndZeroChunkRejected() public {
        vm.expectRevert(abi.encodeWithSignature("PadSignupNotOver()"));
        pvp.draw(32);
        _enterMany(pvp, 1);
        vm.expectRevert(abi.encodeWithSignature("PadSignupNotOver()"));
        pvp.draw(32);
        vm.warp(pvp.signupEnd());
        vm.expectRevert(abi.encodeWithSignature("PadZeroChunk()"));
        pvp.draw(0);
        assertFalse(pvp.drawCommitted());
    }
}
