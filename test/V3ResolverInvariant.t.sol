// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {AccountingRecipient} from "./V3AccountingActors.sol";
import {MockArbSys} from "./mocks/Mocks.sol";
import {PadGame} from "src/PadGame.sol";
import {PadToken} from "src/PadToken.sol";
import {PadLiquidity} from "src/PadLiquidity.sol";

/// @notice Focuses the random sequence on a drawn, non-genesis game. No storage patches, synthetic
/// token balances or swallowed unexpected reverts. Time advances at ten L2 blocks per second.
contract ResolverLedgerHandler is Test {
    PadGame public immutable game;
    MockArbSys public immutable arb;
    AccountingRecipient[6] public actors;
    uint256 public paidRolls;
    uint256 public expiredRolls;
    uint256 public resolvedRolls;
    uint256 public claimsSucceeded;
    uint256 public claimsRejected;
    mapping(address => uint256) public tipsEarned;
    mapping(address => uint256) public tipsWithdrawn;
    mapping(uint256 => bytes32) public settledRoll;

    constructor(PadGame game_, MockArbSys arb_, AccountingRecipient[6] memory actors_) {
        game = game_;
        arb = arb_;
        actors = actors_;
    }

    function roll(uint256 actorSeed) public {
        address actor = address(actors[actorSeed % actors.length]);
        uint256 seat = game.impOf(actor) - 1;
        PadGame.Imp memory imp = game.getImp(seat);
        if (game.ended() || !game.isAlive(seat)) return;
        if (imp.lastRoll != 0 && vm.getBlockTimestamp() < imp.lastRoll + 60) return;
        vm.prank(actor);
        game.roll{value: 0.002 ether}();
        ++paidRolls;
        _recordResolutions(actor);
    }

    function advance(uint256 secondsSeed) public {
        uint256 secondsElapsed = bound(secondsSeed, 0, 90);
        vm.warp(vm.getBlockTimestamp() + secondsElapsed);
        arb.advance(secondsElapsed * 10);
    }

    function resolve(uint256 actorSeed, uint256 batchSeed, bool constrainedGas) public {
        address actor = address(actors[actorSeed % actors.length]);
        uint256 batch = bound(batchSeed, 0, 32);
        vm.prank(actor);
        game.resolvePending{gas: constrainedGas ? 300_000 : 2_000_000}(batch);
        _recordResolutions(actor);
    }

    function claim(uint256 actorSeed, bool reject) public {
        AccountingRecipient actor = actors[actorSeed % actors.length];
        actor.setRejecting(reject);
        uint256 owed = game.claimable(address(actor));
        uint256 receivedBefore = actor.received();
        vm.prank(address(actor));
        (bool ok, bytes memory reason) = address(game).call(abi.encodeCall(PadGame.claim, ()));
        if (owed == 0 || reject) {
            assertFalse(ok, "empty or rejected claim must revert");
            assertEq(reason, abi.encodeWithSignature(owed == 0 ? "PadNothing()" : "PadClaimFailed()"));
            assertEq(game.claimable(address(actor)), owed, "failed claim erased a resolver debt");
            assertEq(actor.received(), receivedBefore);
            if (owed != 0) ++claimsRejected;
        } else {
            assertTrue(ok, "a solvent resolver claim must succeed");
            assertEq(actor.received() - receivedBefore, owed);
            tipsWithdrawn[address(actor)] += owed;
            ++claimsSucceeded;
            assertEq(game.claimable(address(actor)), 0);
        }
    }

    function _recordResolutions(address resolver) private {
        uint256 count = game.rollCount();
        for (uint256 i; i < count; ++i) {
            PadGame.Roll memory r = game.getRoll(i);
            bytes32 recorded = settledRoll[i];
            if (recorded != bytes32(0)) {
                assertEq(keccak256(abi.encode(r)), recorded, "a settled roll changed");
            } else if (r.resolved) {
                settledRoll[i] = keccak256(abi.encode(r));
                ++resolvedRolls;
                if (r.expired) ++expiredRolls;
                else tipsEarned[resolver] += 0.00002 ether;
            }
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract V3ResolverInvariantTest is BaseTest {
    PadGame internal game;
    ResolverLedgerHandler internal handler;
    AccountingRecipient[6] internal actors;
    uint256 internal burnAtStart;

    function setUp() public override {
        super.setUp();
        graduatePvp();
        game = PadGame(pad.gameOf(pad.launch("Resolver ledger", "RES", "")));
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = new AccountingRecipient();
            vm.deal(address(actors[i]), 1 ether);
            vm.prank(address(actors[i]));
            game.enter{value: 0.001 ether}();
        }
        vm.warp(game.signupEnd());
        arb.advance(6_000);
        game.draw(32);
        arb.advance(4);
        game.draw(32);
        assertTrue(game.drawComplete());
        assertEq(game.drawBounty(), 0);
        handler = new ResolverLedgerHandler(game, arb, actors);
        burnAtStart = liq.burnBucket() + liq.totalBurnedEth();

        // Every sequence begins with real roll debt, a paid resolver, and a failed claim. This
        // removes dependence on the fuzzer discovering signup, drawing and resolution in order.
        for (uint256 i; i < actors.length; ++i) {
            handler.roll(i);
        }
        handler.advance(1);
        handler.resolve(0, 16, false);
        handler.claim(0, true);
        handler.claim(0, false);
        handler.advance(59);
        handler.roll(1);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.roll.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.resolve.selector;
        selectors[3] = handler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_eachTipIsPendingExpiredOrOwedToItsActualResolver() public view {
        uint256 issued;
        for (uint256 i; i < actors.length; ++i) {
            address actor = address(actors[i]);
            uint256 earned = handler.tipsEarned(actor);
            assertEq(game.claimable(actor) + handler.tipsWithdrawn(actor), earned, "wrong resolver or double tip");
            assertEq(actors[i].received(), handler.tipsWithdrawn(actor), "ETH receipts disagree with withdrawals");
            issued += earned;
        }
        assertEq(
            issued + (handler.expiredRolls() + game.pendingCount()) * 0.00002 ether,
            handler.paidRolls() * 0.00002 ether,
            "a paid roll lost or duplicated its tip"
        );
        assertEq(handler.resolvedRolls() + game.pendingCount(), handler.paidRolls());
        assertEq(game.rollCount(), handler.paidRolls());
        assertGe(handler.paidRolls(), 7, "campaign never reached paid play");
        assertGe(handler.claimsSucceeded(), 1);
        assertGe(handler.claimsRejected(), 1);
    }

    function invariant_paidETHAndTokensRemainFullyAccounted() public view {
        uint256 paid = handler.paidRolls();
        uint256 outstanding;
        uint256 tokenBalances = PadToken(game.token()).balanceOf(address(game));
        for (uint256 i; i < actors.length; ++i) {
            outstanding += game.claimable(address(actors[i]));
            tokenBalances += PadToken(game.token()).balanceOf(address(actors[i]));
        }
        // At most 103 rolls in this campaign, far below the 2,223-roll curve sell-out.
        assertEq(game.ethRaised(), paid * 0.0018 ether);
        assertEq(game.pot(), paid * 0.00014 ether + handler.expiredRolls() * 0.00002 ether);
        assertEq(liq.burnBucket() + liq.totalBurnedEth() - burnAtStart, paid * 0.00004 ether);
        assertEq(
            address(game).balance, game.ethRaised() + game.pot() + outstanding + game.pendingCount() * 0.00002 ether
        );
        assertEq(tokenBalances, 1_000_000_000 ether);
        assertFalse(game.finalized(), "focused campaign unexpectedly finalized through unrelated upkeep");
    }

    /// @dev Every random sequence must also be drainable through the real lifecycle. Tips are
    /// claimed first so finalization payments cannot mask a missing or duplicated tip.
    function afterInvariant() public {
        if (vm.getBlockTimestamp() <= game.endTime()) vm.warp(game.endTime() + 1);
        arb.advance(30_000);
        while (game.pendingCount() != 0) handler.resolve(5, 16, false);
        invariant_eachTipIsPendingExpiredOrOwedToItsActualResolver();
        invariant_paidETHAndTokensRemainFullyAccounted();
        for (uint256 i; i < actors.length; ++i) {
            handler.claim(i, false);
        }
        invariant_eachTipIsPendingExpiredOrOwedToItsActualResolver();
        vm.prank(address(actors[5]));
        game.finalize();
        graduateGame(game);
        assertTrue(game.graduated());
        assertFalse(game.failed());
        assertEq(address(game).balance, 0, "settled game stranded ETH after graduation");
        assertEq(PadToken(game.token()).balanceOf(address(game)), 0);
    }
}
