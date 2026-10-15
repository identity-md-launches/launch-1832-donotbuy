// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {AccountingRecipient} from "./V3AccountingActors.sol";
import {MockArbSys} from "./mocks/Mocks.sol";
import {V4Router} from "./RealV4.sol";
import {PadToken} from "src/PadToken.sol";
import {PadLiquidity} from "src/PadLiquidity.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";

/// @notice Real v4 fees, crown changes and rejected ETH payments in random order. Recipients keep
/// an independent ETH receipt counter; token donations use their existing tokens, never vm.deal.
contract KingFeeLedgerHandler is Test {
    PadLiquidity public immutable liquidity;
    KingOfThePad public immutable crown;
    PadToken public immutable token;
    V4Router public immutable router;
    MockArbSys public immutable arb;
    AccountingRecipient[4] public actors;
    mapping(address => uint256) public ethFees;
    mapping(address => uint256) public tokenFees;
    mapping(address => uint256) public refunds;
    mapping(address => uint256) public donatedTokens;
    mapping(address => uint256) public initialTokens;
    uint256 public successfulBids;
    uint256 public feeDonations;
    uint256 public successfulClaims;
    uint256 public rejectedClaims;
    uint256 public starvedBids;

    constructor(
        PadLiquidity liquidity_,
        KingOfThePad crown_,
        PadToken token_,
        V4Router router_,
        MockArbSys arb_,
        AccountingRecipient[4] memory actors_
    ) {
        liquidity = liquidity_;
        crown = crown_;
        token = token_;
        router = router_;
        arb = arb_;
        actors = actors_;
        for (uint256 i; i < actors.length; ++i) {
            initialTokens[address(actors[i])] = token.balanceOf(address(actors[i]));
        }
    }

    function donate(uint256 actorSeed, uint256 ethSeed, uint256 tokenSeed) public {
        address donor = address(actors[actorSeed % actors.length]);
        uint256 e = bound(ethSeed, 1, 0.001 ether);
        uint256 t = bound(tokenSeed, 0, token.balanceOf(donor));
        if (t > 1000 ether) t = 1000 ether;
        vm.prank(donor);
        (bool funded,) = address(router).call{value: e}("");
        assertTrue(funded);
        vm.prank(donor);
        token.transfer(address(router), t);
        router.donate(liquidity.poolKey(address(token)), e, t);
        donatedTokens[donor] += t;
        ++feeDonations;
    }

    function distribute(uint256 batchSeed, bool retry) public {
        address recipient = crown.king();
        PadLiquidity.Pool memory beforePool = liquidity.getPool(0);
        if (retry) assertTrue(liquidity.retryPool(0), "healthy real pool could not be retried");
        else liquidity.distribute(bound(batchSeed, 0, 32));
        _recordFees(recipient, beforePool);
    }

    function bid(uint256 actorSeed, uint256 extraSeed, bool rejectPushes) public {
        AccountingRecipient next = actors[actorSeed % actors.length];
        next.setRejecting(rejectPushes);
        uint256 value = crown.nextMinBid() + bound(extraSeed, 0, 0.0001 ether);
        if (value > 1 ether) return;
        address previous = crown.king();
        uint256 refund = crown.bid();
        if (previous != address(0) && vm.getBlockTimestamp() < crown.challengeOpensAt()) {
            uint256 elapsed = crown.challengeOpensAt() - vm.getBlockTimestamp();
            vm.warp(crown.challengeOpensAt());
            arb.advance(elapsed * 10);
        }
        PadLiquidity.Pool memory beforePool = liquidity.getPool(0);
        vm.prank(address(next));
        crown.takeCrown{gas: 7_000_000, value: value}();
        _recordFees(previous == address(0) ? address(next) : previous, beforePool);
        if (previous != address(0)) refunds[previous] += refund;
        ++successfulBids;
        assertEq(crown.king(), address(next));
        assertEq(crown.bid(), value);
    }

    function starveBid(uint256 actorSeed, uint256 gasSeed) public {
        address challenger = address(actors[actorSeed % actors.length]);
        uint256 value = crown.nextMinBid();
        if (value > 1 ether) return;
        if (vm.getBlockTimestamp() < crown.challengeOpensAt()) vm.warp(crown.challengeOpensAt());
        uint256 gasLimit = bound(gasSeed, 100_000, 5_500_000);
        address previous = crown.king();
        uint256 oldBid = crown.bid();
        uint256 oldBalance = challenger.balance;
        uint256 cursor = liquidity.distributeCursor();
        PadLiquidity.Pool memory beforePool = liquidity.getPool(0);
        vm.prank(challenger);
        (bool ok, bytes memory reason) =
            address(crown).call{gas: gasLimit, value: value}(abi.encodeCall(KingOfThePad.takeCrown, ()));
        assertFalse(ok, "underfunded settlement accepted the bid");
        assertEq(reason, abi.encodeWithSignature("PadSettlementGas()"));
        assertEq(crown.king(), previous);
        assertEq(crown.bid(), oldBid);
        assertEq(challenger.balance, oldBalance);
        assertEq(liquidity.distributeCursor(), cursor);
        assertEq(keccak256(abi.encode(liquidity.getPool(0))), keccak256(abi.encode(beforePool)));
        ++starvedBids;
    }

    function claim(uint256 actorSeed, bool fromLiquidity, bool reject) public {
        AccountingRecipient actor = actors[actorSeed % actors.length];
        actor.setRejecting(reject);
        uint256 owed = fromLiquidity ? liquidity.claimable(address(actor)) : crown.claimable(address(actor));
        uint256 receivedBefore = actor.received();
        address target = fromLiquidity ? address(liquidity) : address(crown);
        vm.prank(address(actor));
        (bool ok, bytes memory reason) = target.call(abi.encodeWithSignature("claim()"));
        if (owed == 0 || reject) {
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSignature(owed == 0 ? "PadNothing()" : "PadClaimFailed()"));
            if (owed != 0) ++rejectedClaims;
        } else {
            assertTrue(ok, "owed ETH is not withdrawable");
            assertEq(actor.received() - receivedBefore, owed);
            ++successfulClaims;
        }
        uint256 afterDebt = fromLiquidity ? liquidity.claimable(address(actor)) : crown.claimable(address(actor));
        assertEq(afterDebt, ok ? 0 : owed, "claim failed to preserve or clear the debt");
    }

    function _recordFees(address recipient, PadLiquidity.Pool memory beforePool) private {
        PadLiquidity.Pool memory afterPool = liquidity.getPool(0);
        ethFees[recipient] += afterPool.ethFees - beforePool.ethFees;
        tokenFees[recipient] += afterPool.tokenFees - beforePool.tokenFees;
        assertEq(afterPool.failures, 0, "healthy pool was incorrectly marked broken");
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract V3KingFeesInvariantTest is BaseTest {
    KingFeeLedgerHandler internal handler;
    AccountingRecipient[4] internal actors;
    uint256 internal initialEth;

    function setUp() public override {
        super.setUp();
        graduatePvp();
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = new AccountingRecipient();
            vm.deal(address(actors[i]), 100 ether);
            vm.prank(players[0]);
            pvpToken.transfer(address(actors[i]), 100_000 ether);
        }
        handler = new KingFeeLedgerHandler(liq, king, pvpToken, router, arb, actors);
        initialEth = _ethInScope();
        // Seed both claim systems and prove they are usable before randomized calls begin.
        handler.bid(0, 0, true);
        handler.donate(2, 0.001 ether, 100 ether);
        handler.distribute(16, false);
        handler.bid(1, 0, false);
        handler.claim(0, true, true);
        handler.claim(0, true, false);
        handler.claim(0, false, false);
        handler.starveBid(2, 500_000);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.distribute.selector;
        selectors[2] = handler.bid.selector;
        selectors[3] = handler.starveBid.selector;
        selectors[4] = handler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_eachReignKeepsItsETHAndTokensIncludingRejectedPayments() public view {
        uint256 ethCollected;
        uint256 tokensCollected;
        uint256 liquidityDebt;
        uint256 crownDebt;
        for (uint256 i; i < actors.length; ++i) {
            address actor = address(actors[i]);
            uint256 feeDebt = liq.claimable(actor);
            uint256 refundDebt = king.claimable(actor);
            assertEq(
                actors[i].received() + feeDebt + refundDebt,
                handler.ethFees(actor) + handler.refunds(actor),
                "ETH paid to the wrong reign or lost on rejection"
            );
            assertEq(
                pvpToken.balanceOf(actor) + handler.donatedTokens(actor),
                handler.initialTokens(actor) + handler.tokenFees(actor),
                "fee token was sold, stashed or misdirected"
            );
            ethCollected += handler.ethFees(actor);
            tokensCollected += handler.tokenFees(actor);
            liquidityDebt += feeDebt;
            crownDebt += refundDebt;
        }
        assertEq(liq.getPool(0).ethFees, ethCollected);
        assertEq(liq.getPool(0).tokenFees, tokensCollected);
        assertEq(address(liq).balance, liq.burnBucket() + liquidityDebt);
        assertEq(address(king).balance, crownDebt);
        assertEq(pvpToken.balanceOf(address(liq)), 0, "collected tokens stayed behind for another king");
        assertGe(handler.successfulBids(), 2);
        assertGe(handler.successfulClaims(), 2);
        assertGe(handler.rejectedClaims(), 1);
        assertGe(handler.starvedBids(), 1);
    }

    function invariant_realV4FeesAndBidsConserveETH() public view {
        assertEq(_ethInScope(), initialEth, "ETH escaped the fee and crown system");
        assertEq(address(pad).balance, pad.carryPot());
        assertEq(address(router).balance, 0, "donation router retained ETH");
        assertEq(pvpToken.balanceOf(address(router)), 0, "donation router retained tokens");
    }

    function afterInvariant() public {
        handler.distribute(16, true);
        for (uint256 i; i < actors.length; ++i) {
            handler.claim(i, true, false);
            handler.claim(i, false, false);
        }
        invariant_eachReignKeepsItsETHAndTokensIncludingRejectedPayments();
        invariant_realV4FeesAndBidsConserveETH();
        assertEq(address(king).balance, 0);
        assertEq(address(liq).balance, liq.burnBucket());
    }

    function _ethInScope() private view returns (uint256 value) {
        value = address(liq).balance + address(king).balance + address(pad).balance + address(pm).balance
            + address(router).balance + OWNER.balance;
        for (uint256 i; i < actors.length; ++i) {
            value += address(actors[i]).balance;
        }
    }
}
