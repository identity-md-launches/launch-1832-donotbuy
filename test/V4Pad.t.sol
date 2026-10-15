// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {PadLib} from "../src/libs/PadLib.sol";
import {PoolKey, IPoolManager, IUnlockCallback} from "../src/interfaces/Interfaces.sol";
import {V4Router} from "./RealV4.sol";
import {Rejector} from "./mocks/Mocks.sol";

/// @dev Ordinary fixed-balance ERC20 for the offline venue; never a manifest application.
contract TestIMD {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Same balance logic and storage layout as TestIMD, but `transfer` returns nothing (USDT style).
contract NoReturnIMD {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Calls convertChunk from inside its own PoolManager unlock (finding d74f26e2).
contract NestedConverter is IUnlockCallback {
    IPoolManager immutable pm;
    PadLiquidity immutable liq;
    bytes public reason;

    constructor(IPoolManager pm_, PadLiquidity liq_) {
        pm = pm_;
        liq = liq_;
    }

    function run(address game) external {
        pm.unlock(abi.encode(game));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        try liq.convertChunk(abi.decode(data, (address))) {}
        catch (bytes memory r) {
            reason = r;
        }
        return "";
    }
}

contract V4PadTest is BaseTest {
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
        // ~68 ETH of real full-range depth, the exact production PoolKey and PoolId.
        router.add(imdKey, 68 ether);
        openPad();
    }

    function _start(uint256 n) internal {
        mintAll(pvp, n);
        advance(10 minutes);
    }

    function _finish() internal {
        vm.warp(pvp.endTime() + 1);
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

    function _largeRaise() internal {
        _start(12);
        for (uint256 r; r < 20; ++r) {
            for (uint256 i; i < 12; ++i) {
                rollAs(pvp, players[i]);
            }
            advance(61);
        }
        _finish();
        assertGt(pvp.ethRaised(), 0.4 ether);
    }

    function _oneRollGraduation() internal {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        _convertAll(pvp);
        pvp.graduate();
    }

    function _assertEscrow() internal view {
        assertEq(address(liq).balance, liq.totalConversionEth() + liq.burnBucket());
        assertEq(imd.balanceOf(address(liq)), liq.totalConversionIMD() + liq.burnIMD());
    }

    function _height(uint256 i, int16 h) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(uint256(10)))) + i * 2);
        uint256 word = uint256(vm.load(address(pvp), slot));
        word = (word & ~(uint256(type(uint16).max) << 160)) | (uint256(uint16(h)) << 160);
        vm.store(address(pvp), slot, bytes32(word));
    }

    function _bell(address who) internal {
        uint256 word = uint256(vm.load(address(pvp), bytes32(uint256(8))));
        word = (word & ~(uint256(type(uint64).max) << 64)) | (vm.getBlockTimestamp() << 64);
        vm.store(address(pvp), bytes32(uint256(8)), bytes32(word));
        vm.store(address(pvp), bytes32(uint256(9)), bytes32(uint256(uint160(who))));
    }

    function test_exactIMDKeyAndEmptyApplicationDeployment() public view {
        assertEq(keccak256(abi.encode(imdKey)), 0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02);
        assertEq(tokenTemplate.totalSupply(), 0);
        assertEq(bytes(tokenTemplate.name()).length, 0);
        assertEq(bytes(tokenTemplate.symbol()).length, 0);
        assertEq(liq.imd(), IMD);
        assertEq(abi.encode(liq.imdEthKey()), abi.encode(imdKey));
    }

    function test_bailOutProfitLossMinOutAndConservation() public {
        _start(3);
        rollAs(pvp, players[0]);
        rollAs(pvp, players[1]);
        uint256 coins = pvpToken.balanceOf(players[0]);
        uint256 value = pvp.quoteSell(coins);
        uint256 cost = pvp.curveSpent(players[0]);
        assertGt(value, cost);
        uint256 payout = cost + (value - cost) / 2;
        uint256 pot = pvp.pot();
        uint256 earned = pvp.rollPot();
        uint256 raised = pvp.ethRaised();
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadMinOut()"));
        pvp.bailOut(payout + 1);
        assertFalse(pvp.erased(players[0]));
        assertEq(pvp.ethRaised(), raised);
        uint256 before = players[0].balance;
        vm.prank(players[0]);
        pvp.bailOut(payout);
        assertEq(players[0].balance - before, payout);
        assertEq(pvpToken.balanceOf(players[0]), 0);
        assertEq(pvp.ethRaised(), raised - value);
        assertEq(pvp.pot(), pot + value - payout);
        assertEq(pvp.rollPot(), earned, "bail tax cannot lift the funded allowance");
        assertEq(pvp.fundedReleaseCap(), (raised - value) * 15 / 100);
        value = pvp.quoteSell(pvpToken.balanceOf(players[1]));
        assertLt(value, pvp.curveSpent(players[1]));
        before = players[1].balance;
        vm.prank(players[1]);
        pvp.bailOut(value * 90 / 100);
        assertEq(players[1].balance - before, value * 90 / 100);
        assertEq(pvp.ethRaised(), 0);
        assertEq(pvp.tokensSold(), 0);
        assertEq(pvp.fundedReleaseCap(), 0);
        assertEq(pvpToken.balanceOf(address(pvp)), pvpToken.totalSupply());
        assertEq(address(pvp).balance, pvp.pot() + pvp.pendingCount() * pvp.ROLL_TIP());
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNoImp()"));
        pvp.bailOut(0);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadErased()"));
        pvp.roll{value: 0.002 ether}();
    }

    function test_erasureExcludesRankingBellLivingAndFundedReleaseButPaysPendingTip() public {
        _start(5);
        for (uint256 i; i < 5; ++i) {
            rollAs(pvp, players[i]);
        }
        uint256 seat = pvp.impOf(players[0]) - 1;
        _height(seat, 50);
        vm.prank(players[0]);
        pvp.bailOut(0);
        assertFalse(pvp.isAlive(seat));
        (bool live,) = pvp.isLiveForKing();
        assertFalse(live, "erased seat cannot meet king's five-seat eligibility");
        arb.advance(4);
        uint256 tip = pvp.claimable(address(this));
        pvp.resolvePending(16);
        assertEq(pvp.getRoll(0).delta, 0);
        assertEq(pvp.getImp(seat).height, 50, "pending roll has no height effect");
        assertEq(pvp.claimable(address(this)) - tip, 5 * pvp.ROLL_TIP());
        assertEq(pvp.bellAt(), 0);
        vm.deal(address(this), 1 ether);
        pad.fundCarry{value: 1 ether}();
        _bell(players[1]); // controlled end/rank fixture, no PoolManager substitution
        uint256 erasedBalance = players[0].balance;
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 4);
        assertEq(pvp.paidAtEnd(), 2);
        assertEq(players[0].balance, erasedBalance, "erased high rank earns no pot");
        assertApproxEqAbs(pad.carryPot(), 1 ether, 1, "four living cannot release funding; rank dust returns");
    }

    function test_deadWalletMayBailWhileAnotherLivesAndErasedActivityDoesNotDelayEnd() public {
        _start(2);
        rollAs(pvp, players[0]);
        advance(9 minutes);
        rollAs(pvp, players[1]);
        advance(61);
        assertFalse(pvp.isAlive(pvp.impOf(players[0]) - 1));
        vm.prank(players[0]);
        pvp.bailOut(0);
        assertFalse(pvp.ended());
        vm.prank(players[1]);
        pvp.bailOut(0);
        assertTrue(pvp.ended());
        assertEq(pvp.endTime(), vm.getBlockTimestamp());
        arb.advance(4);
        pvp.resolvePending(16);
        pvp.finalize();
        pvp.graduate();
        assertTrue(pvp.failed());
        assertEq(pvp.livingAtEnd(), 0);
    }

    function test_bailOnlyDuringPlayAndOnlySeatedWallets() public {
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.bailOut(0);
        _start(2);
        vm.expectRevert(abi.encodeWithSignature("PadNoImp()"));
        pvp.bailOut(0);
        rollAs(pvp, players[0]);
        _finish();
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.bailOut(0);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNotGameOrUnlocked()"));
        pvpToken.reclaim(players[0], 1);
        _convertAll(pvp);
        pvp.graduate();
        vm.prank(address(pvp));
        vm.expectRevert(abi.encodeWithSignature("PadNotGameOrUnlocked()"));
        pvpToken.reclaim(players[0], 1);
    }

    function test_rejectedBailPaymentRemainsClaimableAndCannotBePaidTwice() public {
        Rejector recipient = new Rejector();
        vm.deal(address(recipient), 1 ether);
        vm.prank(address(recipient));
        pvp.enter{value: 0.001 ether}();
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, address(recipient));
        uint256 value = pvp.quoteSell(pvpToken.balanceOf(address(recipient)));
        vm.prank(address(recipient));
        pvp.bailOut(value);
        assertEq(pvp.claimable(address(recipient)), value);
        vm.prank(address(recipient));
        vm.expectRevert(abi.encodeWithSignature("PadClaimFailed()"));
        pvp.claim();
        assertEq(pvp.claimable(address(recipient)), value);
        assertEq(address(pvp).balance, value + pvp.pot() + pvp.pendingCount() * pvp.ROLL_TIP());
    }

    function test_conversionLimitIntervalPartialFillAndEscrow() public {
        _largeRaise();
        assertEq(pvp.status(), 8);
        uint256 price = managerPrice(imdKey);
        uint256 ethBefore = address(liq).balance;
        liq.convertChunk(address(pvp));
        (uint256 left, uint256 spent, uint256 received, uint64 attempted, uint64 progress,,) =
            liq.conversions(address(pvp));
        assertGt(left, 0);
        assertGt(spent, 0);
        assertGt(received, 0);
        assertEq(left + spent, pvp.ethRaised());
        assertEq(price - price * 50 / 10_000, managerPrice(imdKey));
        assertEq(attempted, vm.getBlockTimestamp());
        assertEq(progress, attempted);
        assertEq(address(liq).balance - ethBefore, left);
        _assertEscrow();
        vm.expectRevert(abi.encodeWithSignature("PadConversionInterval()"));
        liq.convertChunk(address(pvp));
        vm.warp(vm.getBlockTimestamp() + 29);
        vm.expectRevert(abi.encodeWithSignature("PadConversionInterval()"));
        liq.convertChunk(address(pvp));
        vm.warp(vm.getBlockTimestamp() + 1);
        liq.convertChunk(address(pvp));
        (left, spent, received,,,,) = liq.conversions(address(pvp));
        assertEq(left, 0);
        assertEq(spent, pvp.ethRaised());
        assertEq(pvp.status(), 4);
        assertEq(imd.balanceOf(address(liq)), received);
        _assertEscrow();
        vm.expectRevert(abi.encodeWithSignature("PadNotConverting()"));
        liq.convertChunk(address(pvp));
    }

    function test_graduationPriceEquivalentAndUnlocksInSameTransaction() public {
        _start(3);
        for (uint256 i; i < 3; ++i) {
            rollAs(pvp, players[i]);
        }
        _finish();
        vm.expectRevert(abi.encodeWithSignature("PadNotGraduable()"));
        pvp.graduate();
        assertFalse(pvpToken.unlocked());
        _convertAll(pvp);
        (, uint256 converted, uint256 received,,,,) = liq.conversions(address(pvp));
        (uint256 vEth, uint256 vTok,) = pvp.curveState();
        uint256 lpCoins = PadLib.mulDiv(converted, vTok, vEth);
        vm.recordLogs();
        pvp.graduate();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool priceEvent;
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(liq)
                    && entries[i].topics[0]
                        == keccak256("Graduated(uint256,address,uint160,uint128,uint256,uint256,uint256)")
            ) {
                (uint160 initialPrice,, uint256 seededQuote, uint256 seededCoins,) =
                    abi.decode(entries[i].data, (uint160, uint128, uint256, uint256, uint256));
                uint160 expected = address(pvpToken) < IMD
                    ? PadLib.sqrtRatioX96(received, lpCoins)
                    : PadLib.sqrtRatioX96(lpCoins, received);
                assertEq(initialPrice, expected, "exact final curve equivalence before any upkeep burn");
                assertEq(seededQuote, received, "all converted IMD enters principal or its position's fee growth");
                assertLe(seededCoins, lpCoins);
                priceEvent = true;
            }
        }
        assertTrue(priceEvent);
        PoolKey memory key = liq.poolKey(address(pvpToken));
        assertEq(key.currency0, address(pvpToken) < IMD ? address(pvpToken) : IMD);
        assertEq(key.currency1, address(pvpToken) < IMD ? IMD : address(pvpToken));
        assertEq(key.fee, 10_000);
        assertEq(key.tickSpacing, 200);
        assertEq(key.hooks, address(liq.hook()));
        uint256 price = managerPrice(key);
        uint256 quotePerCoin = address(pvpToken) < IMD
            ? PadLib.mulDiv(price, price * 1e18, 1 << 192)
            : PadLib.mulDiv(1 << 192, 1e18, price * price);
        // An opportunistic burn can move the just-created pool by <1%; the ratio still matches.
        assertApproxEqRel(quotePerCoin, PadLib.mulDiv(received, 1e18, lpCoins), 0.011e18);
        assertTrue(pvpToken.unlocked());
        assertTrue(pvp.graduated());
        assertGt(liq.getPool(0).liquidity, 0);
        assertTrue(liq.imdPool(address(pvpToken)));
        assertEq(pvpToken.balanceOf(address(pvp)), 0);
        assertEq(pvpToken.balanceOf(address(liq)), 0);
        uint256 total = pvpToken.balanceOf(address(pm)) + pvpToken.balanceOf(DEAD);
        for (uint256 i; i < 3; ++i) {
            total += pvpToken.balanceOf(players[i]);
        }
        assertEq(total, pvpToken.totalSupply());
        _assertEscrow();
    }

    function test_partial24HourFallbackUsesIMDAndCarriesOnlyRemainingETH() public {
        _largeRaise();
        liq.convertChunk(address(pvp));
        (uint256 left, uint256 converted, uint256 received,, uint64 progress,,) = liq.conversions(address(pvp));
        assertGt(left, 0);
        vm.mockCallRevert(address(pm), abi.encodeWithSelector(IPoolManager.swap.selector, imdKey), bytes("venue down"));
        vm.warp(uint256(progress) + 23 hours);
        liq.convertChunk(address(pvp));
        (,,,, uint64 unchanged,,) = liq.conversions(address(pvp));
        assertEq(unchanged, progress);
        vm.warp(uint256(progress) + 24 hours - 1);
        vm.expectRevert(abi.encodeWithSignature("PadNotGraduable()"));
        pvp.graduate();
        vm.warp(uint256(progress) + 24 hours);
        uint256 carry = pad.carryPot();
        pvp.graduate();
        assertTrue(liq.imdPool(address(pvpToken)));
        assertTrue(pvpToken.unlocked());
        assertEq(pad.carryPot() - carry, left);
        (, uint256 afterConverted, uint256 afterReceived,,,, bool closed) = liq.conversions(address(pvp));
        assertEq(converted, afterConverted);
        assertEq(received, afterReceived);
        assertTrue(closed);
        _assertEscrow();
        vm.clearMockedCalls();
    }

    function test_upkeepConvertsAndGraduatesWithBoundedGas() public {
        _largeRaise();
        uint256 before = gasleft();
        pad.upkeep();
        emit log_named_uint("Conversion upkeep gas", before - gasleft());
        (uint256 left,,,,,,) = liq.conversions(address(pvp));
        assertGt(left, 0);
        assertFalse(pvp.graduated());
        vm.warp(vm.getBlockTimestamp() + 30);
        pad.upkeep();
        assertTrue(pvp.graduated());
        assertTrue(pvpToken.unlocked());
        _assertEscrow();
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_sandwichOnConversionChunkLoses(uint96 input) public {
        _largeRaise();
        uint256 front = bound(input, 0.0001 ether, 60 ether);
        V4Router attacker = new V4Router(pm);
        vm.deal(address(attacker), front);
        uint256 moved = managerPrice(imdKey);
        attacker.trade(imdKey, true, front);
        moved = managerPrice(imdKey) * 10_000 / moved;
        liq.convertChunk(address(pvp));
        (, uint256 converted,,,,,) = liq.conversions(address(pvp));
        // Inside the anchor band the chunk fills; a front-run past it is refused outright.
        if (moved > 9_901) assertGt(converted, 0);
        if (moved < 9_899) assertEq(converted, 0);
        attacker.trade(imdKey, false, imd.balanceOf(address(attacker)));
        assertLt(address(attacker).balance, front, "front/victim/back round trip loses both venue fees");
    }

    function test_twoHopBurnBothPriceLimitsIntervalAndIntermediateAccounting() public {
        _oneRollGraduation();
        vm.deal(address(this), 1 ether);
        liq.fundBurn{value: 0.05 ether}();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        PoolKey memory pvpKey = liq.poolKey(address(pvpToken));
        uint256 p0 = managerPrice(imdKey);
        uint256 p1 = managerPrice(pvpKey);
        uint256 bucket = liq.burnBucket();
        uint256 dead = pvpToken.balanceOf(DEAD);
        uint256 totalSpent = liq.totalBurnedEth();
        uint256 gasBefore = gasleft();
        liq.burnChunk();
        emit log_named_uint("Two-hop burn gas", gasBefore - gasleft());
        uint256 spent = liq.totalBurnedEth() - totalSpent;
        assertGt(spent, 0);
        assertLe(spent, 0.02 ether);
        assertEq(liq.burnBucket(), bucket - spent);
        assertGt(pvpToken.balanceOf(DEAD), dead);
        assertGe(managerPrice(imdKey), p0 - p0 * 50 / 10_000);
        if (pvpKey.currency0 == IMD) assertGe(managerPrice(pvpKey), p1 - p1 * 50 / 10_000);
        else assertLe(managerPrice(pvpKey), PadLib.mulDiv(p1, 1004987562112089027, 1e18));
        assertGt(liq.burnIMD(), 0, "thin second hop preserves unused intermediate IMD");
        _assertEscrow();
        uint256 intermediate = liq.burnIMD();
        liq.burnChunk();
        assertEq(liq.burnIMD(), intermediate);
        assertEq(liq.burnBucket(), bucket - spent);
    }

    function test_kingCollectsIMDAndCoinsInKindAcrossCrown() public {
        _oneRollGraduation();
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        PoolKey memory key = liq.poolKey(address(pvpToken));
        imd.mint(address(router), 2 ether);
        vm.prank(players[0]);
        pvpToken.transfer(address(router), 1000 ether);
        router.donate(key, key.currency0 == IMD ? 1 ether : 1000 ether, key.currency0 == IMD ? 1000 ether : 1 ether);
        uint256 feeBefore = liq.getPool(0).imdFees;
        uint256 imdBefore = imd.balanceOf(players[8]);
        uint256 coinBefore = pvpToken.balanceOf(players[8]);
        uint160 price = managerPrice(key);
        liq.distribute(1);
        assertGt(imd.balanceOf(players[8]) - imdBefore, 0.999 ether);
        assertGt(pvpToken.balanceOf(players[8]) - coinBefore, 999 ether);
        assertEq(liq.getPool(0).imdFees - feeBefore, imd.balanceOf(players[8]) - imdBefore);
        assertEq(liq.getPool(0).ethFees, 0);
        assertEq(managerPrice(key), price, "fees are never sold");
        imd.mint(address(router), 1 ether);
        router.donate(key, key.currency0 == IMD ? 1 ether : 0, key.currency0 == IMD ? 0 : 1 ether);
        vm.warp(king.challengeOpensAt());
        imdBefore = imd.balanceOf(players[8]);
        vm.prank(players[9]);
        king.takeCrown{value: 0.011 ether}();
        assertGt(imd.balanceOf(players[8]) - imdBefore, 0.999 ether);
        assertEq(imd.balanceOf(players[9]), 0);
        _assertEscrow();
    }

    function test_bailAfterActualSellOutReopensCurveAndCostCountsOnlySpentETH() public {
        vm.pauseGasMetering();
        address[] memory entrants = new address[](200);
        for (uint256 i; i < 200; ++i) {
            entrants[i] = address(uint160(0x910000 + i));
            vm.deal(entrants[i], 1 ether);
            vm.prank(entrants[i]);
            pvp.enter{value: 0.001 ether}();
        }
        advance(10 minutes);
        for (uint256 round; round < 12; ++round) {
            for (uint256 i; i < 200; ++i) {
                rollAs(pvp, entrants[i]);
            }
            advance(61);
            arb.advance(300);
        }
        vm.resumeGasMetering();
        assertEq(pvp.ethRaised(), 4 ether);
        assertEq(pvp.tokensSold(), 800_000_000 ether);
        assertLt(pvp.curveSpent(entrants[199]), 12 * 0.0018 ether, "sold-out rolls spend no curve ETH");
        uint256 coins = pvpToken.balanceOf(entrants[0]);
        uint256 value = pvp.quoteSell(coins);
        uint256 earned = pvp.rollPot();
        vm.prank(entrants[0]);
        pvp.bailOut(0);
        assertEq(pvp.ethRaised(), 4 ether - value);
        assertEq(pvp.tokensSold(), 800_000_000 ether - coins);
        assertEq(pvp.rollPot(), earned);
        assertEq(pvp.fundedReleaseCap(), (4 ether - value) * 15 / 100);
        uint256 cost = pvp.curveSpent(entrants[199]);
        uint256 priorCoins = pvpToken.balanceOf(entrants[199]);
        rollAs(pvp, entrants[199]);
        assertEq(pvp.curveSpent(entrants[199]) - cost, 0.0018 ether);
        assertGt(pvpToken.balanceOf(entrants[199]), priorCoins);
        uint256 total = pvpToken.balanceOf(address(pvp));
        for (uint256 i; i < 200; ++i) {
            total += pvpToken.balanceOf(entrants[i]);
        }
        assertEq(total, pvpToken.totalSupply());
        uint256 claims = pvp.claimable(address(this));
        for (uint256 i; i < 200; ++i) {
            claims += pvp.claimable(entrants[i]);
        }
        assertEq(address(pvp).balance, pvp.ethRaised() + pvp.pot() + claims + pvp.pendingCount() * pvp.ROLL_TIP());
    }

    function test_soleBuyerSybilWithProfitableBailAndFiveSurvivorsStillLosesAfterTwoHopDump() public {
        vm.deal(address(this), 10 ether);
        pad.fundCarry{value: 5 ether}();
        _start(6);
        uint256 initial;
        for (uint256 i; i < 6; ++i) {
            initial += players[i].balance;
        }
        uint256 finalizerStart = address(this).balance;
        for (uint256 round; round < 49; ++round) {
            for (uint256 i; i < 6; ++i) {
                if (!pvp.erased(players[i])) rollAs(pvp, players[i]);
            }
            if (round == 20) {
                uint256 value = pvp.quoteSell(pvpToken.balanceOf(players[0]));
                assertGt(value, pvp.curveSpent(players[0]), "a profitable individual bailout is included");
                vm.prank(players[0]);
                pvp.bailOut(0);
            }
            advance(61); // worst case: tips return to the sybil's pot
            arb.advance(300);
        }
        vm.warp(pvp.hardEnd());
        arb.advance(300);
        pvp.resolvePending(16);
        uint256 netCurve = pvp.ethRaised();
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 5);
        assertLe(5 ether - pad.carryPot(), netCurve * 15 / 100 + 1);
        _convertAll(pvp);
        pvp.graduate();
        V4Router seller = new V4Router(pm);
        uint256 coins;
        for (uint256 i; i < 6; ++i) {
            uint256 bal = pvpToken.balanceOf(players[i]);
            if (bal != 0) {
                vm.prank(players[i]);
                pvpToken.transfer(address(seller), bal);
                coins += bal;
            }
        }
        PoolKey memory key = liq.poolKey(address(pvpToken));
        seller.trade(key, key.currency0 == address(pvpToken), coins);
        seller.trade(imdKey, false, imd.balanceOf(address(seller)));
        uint256 recovered = address(seller).balance + address(this).balance - finalizerStart;
        for (uint256 i; i < 6; ++i) {
            recovered += players[i].balance + pvp.claimable(players[i]);
        }
        recovered += pvp.claimable(address(this));
        assertLt(recovered, initial, "bailouts + ranks + funding + finalizer + both-hop dump still lose");
        emit log_named_uint("Sybil net curve ETH after bailout", netCurve);
        emit log_named_uint("Sybil loss excluding entries and gas", initial - recovered);
        _assertEscrow();
    }

    function test_bothCurrencyOrdersGraduateAndPayTheCorrectKingAssets() public {
        _oneRollGraduation();
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        bool sawCoin0 = address(pvpToken) < IMD;
        bool sawCoin1 = address(pvpToken) > IMD;
        for (uint256 i; i < 24 && !(sawCoin0 && sawCoin1); ++i) {
            PadGame game = PadGame(pad.gameOf(pad.launch("Order", "O", "")));
            mintAll(game, 1);
            advance(10 minutes);
            rollAs(game, players[0]);
            advance(10 minutes);
            game.finalize();
            _convertAll(game);
            game.graduate();
            PadToken coin = PadToken(game.token());
            PoolKey memory key = liq.poolKey(address(coin));
            sawCoin0 = sawCoin0 || address(coin) < IMD;
            sawCoin1 = sawCoin1 || address(coin) > IMD;
            vm.prank(players[0]);
            coin.transfer(address(router), 1000 ether);
            imd.mint(address(router), 1 ether);
            router.donate(key, key.currency0 == IMD ? 1 ether : 1000 ether, key.currency0 == IMD ? 1000 ether : 1 ether);
            uint256 beforeIMD = imd.balanceOf(players[8]);
            uint256 beforeCoins = coin.balanceOf(players[8]);
            liq.retryPool(liq.poolIndexOf(game.launchId()) - 1);
            assertGt(imd.balanceOf(players[8]) - beforeIMD, 0.999 ether);
            assertGt(coin.balanceOf(players[8]) - beforeCoins, 999 ether);
        }
        assertTrue(sawCoin0 && sawCoin1, "exercise both address orderings");
        _assertEscrow();
    }

    function test_lowGasProbeCannotConsumeConversionInterval() public {
        _largeRaise();
        pvp.prepareConversion();
        (bool ok, bytes memory reason) =
            address(liq).call{gas: 300_000}(abi.encodeCall(PadLiquidity.convertChunk, (address(pvp))));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSignature("PadConversionGas()"));
        (,,, uint64 attempted,,,) = liq.conversions(address(pvp));
        assertEq(attempted, 0);
        liq.convertChunk(address(pvp));
        (, uint256 converted,,,,,) = liq.conversions(address(pvp));
        assertGt(converted, 0);
    }

    function test_IMDDonationsDoNotChangeConversionCreditOrGraduationPrice() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        imd.mint(address(liq), 123 ether);
        _convertAll(pvp);
        (,, uint256 credit,,,,) = liq.conversions(address(pvp));
        assertLt(credit, 0.002 ether);
        assertEq(imd.balanceOf(address(liq)), credit + 123 ether);
        pvp.graduate();
        assertEq(imd.balanceOf(address(liq)), liq.burnIMD() + 123 ether);
        assertEq(liq.totalConversionIMD(), 0);
        assertTrue(pvpToken.unlocked());
    }

    function test_largeRawTokenRatioDoesNotOverflowPriceEncoding() public pure {
        uint160 sqrtPrice = PadLib.sqrtRatioX96(1e27, 1);
        assertGt(sqrtPrice, uint160(1 << 128));
        uint256 ratio = PadLib.mulDiv(sqrtPrice, sqrtPrice, 1 << 192);
        assertApproxEqRel(ratio, 1e27, 1e6); // < 1e-12 relative error
        uint160 reciprocal = PadLib.sqrtRatioX96(1, 1e27);
        assertGt(reciprocal, 4_310_618_292);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_bailSequencesConserveETHAndSupply(uint8 count, uint8 mask) public {
        uint256 rounds = bound(count, 1, 8);
        _start(6);
        uint256 initial;
        for (uint256 i; i < 6; ++i) {
            initial += players[i].balance;
        }
        for (uint256 r; r < rounds; ++r) {
            for (uint256 i; i < 6; ++i) {
                rollAs(pvp, players[i]);
            }
            advance(61);
            arb.advance(300);
        }
        for (uint256 i; i < 6; ++i) {
            if (uint256(mask) & (1 << i) == 0) continue;
            uint256 value = pvp.quoteSell(pvpToken.balanceOf(players[i]));
            uint256 cost = pvp.curveSpent(players[i]);
            uint256 payout = value >= cost ? cost + (value - cost) / 2 : value * 90 / 100;
            uint256 earned = pvp.rollPot();
            vm.prank(players[i]);
            pvp.bailOut(payout);
            assertEq(pvp.rollPot(), earned);
            assertFalse(pvp.isAlive(pvp.impOf(players[i]) - 1));
            assertLe(pvp.fundedReleaseCap(), pvp.ethRaised() * 15 / 100);
        }
        uint256 holdings;
        uint256 wealth = address(pvp).balance;
        uint256 claims = pvp.claimable(address(this));
        for (uint256 i; i < 6; ++i) {
            wealth += players[i].balance;
            holdings += pvpToken.balanceOf(players[i]);
            claims += pvp.claimable(players[i]);
        }
        assertEq(wealth, initial);
        assertEq(holdings, pvp.tokensSold());
        assertEq(holdings + pvpToken.balanceOf(address(pvp)), pvpToken.totalSupply());
        assertEq(address(pvp).balance, pvp.ethRaised() + pvp.pot() + claims + pvp.pendingCount() * pvp.ROLL_TIP());
    }

    function test_zeroLiquidityChunksDoNotExtendTimeout() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        router.remove(imdKey, 68 ether);
        uint64 finalized = pvp.finalizedAt();
        liq.convertChunk(address(pvp));
        (uint256 left, uint256 spent, uint256 got,, uint64 progress,,) = liq.conversions(address(pvp));
        assertEq(left, pvp.ethRaised());
        assertEq(spent, 0);
        assertEq(got, 0);
        assertEq(progress, finalized);
        vm.warp(uint256(finalized) + 24 hours - 1);
        liq.convertChunk(address(pvp));
        (,,,, progress,,) = liq.conversions(address(pvp));
        assertEq(progress, finalized);
        vm.warp(uint256(finalized) + 24 hours);
        pvp.graduate();
        assertFalse(liq.imdPool(address(pvpToken)));
        assertTrue(pvpToken.unlocked());
    }

    function test_conversionAccessAndConstructorKeyValidation() public {
        vm.expectRevert(abi.encodeWithSignature("PadNotConverting()"));
        liq.convertChunk(address(pvp));
        vm.expectRevert(abi.encodeWithSignature("PadNotSelf()"));
        liq.executeConversion(1, 1);
        vm.expectRevert(abi.encodeWithSignature("PadNotPoolManager()"));
        liq.unlockCallback("");
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSignature("PadNotGame()"));
        liq.startConversion{value: 1}(1, uint64(vm.getBlockTimestamp()));
        PoolKey memory invalid = imdKey;
        invalid.fee = 3000;
        vm.expectRevert(abi.encodeWithSignature("PadIMDKey()"));
        new PadLiquidity(address(pm), address(pad), IMD, keccak256(abi.encode(invalid)));
        vm.expectRevert(abi.encodeWithSignature("PadZeroIMD()"));
        new PadLiquidity(address(pm), address(pad), address(0), keccak256(abi.encode(imdKey)));
        assertEq(pad.liquidity(), address(liq));
        assertEq(liq.totalConversionEth(), 0);
    }

    function test_constructorPoolIdRejectsChangedVenueFields() public {
        // A PoolId commits to every key field. Changing even the implicit native/hookless
        // fields must fail before the constructor can call the pad's one-shot binder.
        PoolKey[5] memory invalid = [
            PoolKey(address(pvpToken), IMD, 10_000, 100, address(0)),
            PoolKey(address(0), address(pvpToken), 10_000, 100, address(0)),
            PoolKey(address(0), IMD, 3000, 100, address(0)),
            PoolKey(address(0), IMD, 10_000, 200, address(0)),
            PoolKey(address(0), IMD, 10_000, 100, liq.hook())
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(abi.encodeWithSignature("PadIMDKey()"));
            new PadLiquidity(address(pm), address(pad), IMD, keccak256(abi.encode(invalid[i])));
        }
        vm.expectRevert(abi.encodeWithSignature("PadIMDKey()"));
        new PadLiquidity(address(pm), address(pad), IMD, bytes32(0));
        // A supplied IMD address cannot disagree with the key's currency1.
        vm.expectRevert(abi.encodeWithSignature("PadIMDKey()"));
        new PadLiquidity(address(pm), address(pad), address(pvpToken), keccak256(abi.encode(imdKey)));
        assertEq(pad.liquidity(), address(liq));
        assertEq(abi.encode(liq.imdEthKey()), abi.encode(imdKey));
    }

    function test_twoGamesKeepIndependentConversionEscrows() public {
        _oneRollGraduation();
        PadGame a = PadGame(pad.gameOf(pad.launch("A", "A", "")));
        PadGame b = PadGame(pad.gameOf(pad.launch("B", "B", "")));
        mintAll(a, 12);
        mintAll(b, 12);
        advance(10 minutes);
        for (uint256 round; round < 20; ++round) {
            for (uint256 i; i < 12; ++i) {
                rollAs(a, players[i]);
                rollAs(b, players[i]);
            }
            advance(61);
            arb.advance(300);
        }
        vm.warp(b.endTime() + 1);
        arb.advance(300);
        a.resolvePending(16);
        b.resolvePending(16);
        a.finalize();
        if (!b.finalized()) b.finalize();
        a.prepareConversion();
        b.prepareConversion();
        uint256 raiseA = a.ethRaised();
        uint256 raiseB = b.ethRaised();
        assertEq(liq.totalConversionEth(), raiseA + raiseB);
        liq.convertChunk(address(a));
        (uint256 leftA, uint256 spentA, uint256 gotA,,,,) = liq.conversions(address(a));
        (uint256 leftB, uint256 spentB, uint256 gotB,,,,) = liq.conversions(address(b));
        assertEq(leftA + spentA, raiseA);
        assertGt(gotA, 0);
        assertEq(leftB, raiseB);
        assertEq(spentB, 0);
        assertEq(gotB, 0);
        _assertEscrow();
        liq.convertChunk(address(b)); // interval is per game, not global
        (leftB, spentB, gotB,,,,) = liq.conversions(address(b));
        assertEq(leftB + spentB, raiseB);
        assertGt(gotB, 0);
        assertEq(liq.totalConversionEth(), leftA + leftB);
        assertEq(liq.totalConversionIMD(), gotA + gotB);
        _assertEscrow();
    }

    // ---- revision: anchored band, nested unlock, progress floor, stall clock, no-return IMD -------

    function _sumConverted(uint256 n) internal returns (uint256 converted) {
        for (uint256 i; i < n; ++i) {
            try liq.convertChunk(address(pvp)) {} catch {}
            (uint256 left, uint256 c,,,,,) = liq.conversions(address(pvp));
            converted = c;
            if (left == 0) return converted;
            vm.warp(vm.getBlockTimestamp() + 30);
        }
    }

    function test_heldFrontRunAcrossAllChunksIsRefusedAndLoses() public {
        _largeRaise();
        uint256 anchor = liq.anchorOf(address(pvp));
        assertEq(anchor, managerPrice(imdKey), "finalize anchors the spot before any chunk is known");
        V4Router attacker = new V4Router(pm);
        vm.deal(address(attacker), 10 ether);
        attacker.trade(imdKey, true, 10 ether);
        // The attacker drives every chunk itself for 100 minutes: the band refuses them all.
        assertEq(_sumConverted(200), 0, "no chunk sells into the attacker's price");
        (,,, uint64 attempted,,,) = liq.conversions(address(pvp));
        assertEq(attempted, 0, "refused chunks do not consume the interval");
        attacker.trade(imdKey, false, imd.balanceOf(address(attacker)));
        assertLt(address(attacker).balance, 10 ether, "the held position only paid both venue fees");
        // Once the price is back the conversion completes at the fair price.
        _convertAll(pvp);
        (, uint256 converted, uint256 received,,,,) = liq.conversions(address(pvp));
        assertEq(converted, pvp.ethRaised());
        assertGt(received, converted * 97 / 100, "IMD received at roughly the pre-attack price");
        _assertEscrow();
    }

    function test_anchorBandBoundsCumulativeWalkAndDecaysForAGenuineMove() public {
        _largeRaise();
        uint256 a = liq.anchorOf(address(pvp));
        // A lasting market move of ~3% in price (1.5% sqrt) below the anchor, with no arbitrage back.
        router.trade(imdKey, true, 1.03 ether);
        assertLt(managerPrice(imdKey), a - a * 100 / 10_000);
        liq.convertChunk(address(pvp));
        (, uint256 converted,,,,,) = liq.conversions(address(pvp));
        assertEq(converted, 0, "outside the 2% band");
        // The anchor follows a falling market by 0.5% sqrt price per hour.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertApproxEqAbs(liq.anchorOf(address(pvp)), a - a * 50 / 10_000, 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 spot = managerPrice(imdKey);
        liq.convertChunk(address(pvp));
        (, converted,,,,,) = liq.conversions(address(pvp));
        assertGt(converted, 0, "after the decay the band reaches the new market");
        uint256 floor = liq.anchorOf(address(pvp));
        floor -= floor * 100 / 10_000;
        assertGe(managerPrice(imdKey), floor, "never below the band");
        assertGe(managerPrice(imdKey), spot - spot * 50 / 10_000, "never more than 1% from spot");
        _assertEscrow();
    }

    function test_nestedUnlockCallerIsRejectedAndHonestChunkConverts() public {
        _largeRaise();
        pvp.prepareConversion();
        NestedConverter nested = new NestedConverter(pm, liq);
        nested.run(address(pvp));
        assertEq(nested.reason(), abi.encodeWithSignature("PadManagerUnlocked()"));
        (,,, uint64 attempted,,,) = liq.conversions(address(pvp));
        assertEq(attempted, 0);
        liq.convertChunk(address(pvp));
        (, uint256 converted,,,,,) = liq.conversions(address(pvp));
        assertGt(converted, 0, "the honest chunk in the same window converts");
    }

    function test_failedVenueAttemptDoesNotConsumeInterval() public {
        _largeRaise();
        pvp.prepareConversion();
        vm.mockCallRevert(address(pm), abi.encodeWithSelector(IPoolManager.swap.selector, imdKey), bytes("down"));
        liq.convertChunk(address(pvp));
        vm.clearMockedCalls();
        (, uint256 converted,, uint64 attempted,,,) = liq.conversions(address(pvp));
        assertEq(converted, 0);
        assertEq(attempted, 0);
        liq.convertChunk(address(pvp));
        (, converted,, attempted,,,) = liq.conversions(address(pvp));
        assertGt(converted, 0);
        assertEq(attempted, vm.getBlockTimestamp());
    }

    function test_dustFillsDoNotRefreshTheStallClock() public {
        _largeRaise();
        router.remove(imdKey, 68 ether);
        router.add(imdKey, 1e6);
        liq.convertChunk(address(pvp));
        (,,,, uint64 start,,) = liq.conversions(address(pvp));
        assertEq(start, vm.getBlockTimestamp());
        vm.warp(uint256(start) + 23 hours);
        liq.convertChunk(address(pvp));
        (uint256 left, uint256 converted, uint256 received,, uint64 progress,,) = liq.conversions(address(pvp));
        assertGt(converted, 0, "dust did fill");
        assertGt(received, 0);
        assertLt(converted * 1000, left + converted, "below the 0.1% floor");
        assertEq(progress, start, "dust is not progress");
        vm.warp(uint256(start) + 24 hours - 1);
        assertFalse(liq.canGraduate(address(pvp)));
        vm.warp(uint256(start) + 24 hours);
        assertTrue(liq.canGraduate(address(pvp)));
        uint256 carry = pad.carryPot();
        pvp.graduate();
        assertTrue(liq.imdPool(address(pvpToken)), "graduates with the IMD converted so far");
        assertEq(pad.carryPot() - carry, left, "unconverted ETH carried");
        assertTrue(pvpToken.unlocked());
        _assertEscrow();
    }

    function test_realProgressAboveFloorRefreshesClockButSevenDayCapBounds() public {
        _largeRaise();
        router.remove(imdKey, 68 ether);
        router.add(imdKey, 0.2 ether); // ~0.001 ETH per 1% chunk: above the 0.1% floor, far from done
        liq.convertChunk(address(pvp));
        (,,,, uint64 start,,) = liq.conversions(address(pvp));
        for (uint256 d = 1; d < 7; ++d) {
            vm.warp(uint256(start) + d * 23 hours);
            liq.convertChunk(address(pvp));
            (uint256 left,,,, uint64 progress,,) = liq.conversions(address(pvp));
            assertGt(left, 0);
            assertEq(progress, vm.getBlockTimestamp(), "real progress refreshes the clock");
            assertFalse(liq.canGraduate(address(pvp)));
        }
        vm.warp(uint256(start) + 7 days);
        assertTrue(liq.canGraduate(address(pvp)), "never stranded: seven days from the escrow at most");
        pvp.graduate();
        assertTrue(liq.imdPool(address(pvpToken)));
        _assertEscrow();
    }

    function test_untouchedGameStartsItsClockOnFirstTouchAndGraduatesIntoIMD() public {
        _start(1);
        rollAs(pvp, players[0]);
        _finish();
        (,,,,, bool started,) = liq.conversions(address(pvp));
        assertFalse(started);
        vm.warp(uint256(pvp.finalizedAt()) + 3 days);
        pvp.poke();
        assertTrue(pvp.graduated());
        assertTrue(liq.imdPool(address(pvpToken)), "a healthy venue is used, however late the first touch");
        (, uint256 converted, uint256 received,,,,) = liq.conversions(address(pvp));
        assertEq(converted, pvp.ethRaised());
        assertGt(received, 0);
    }

    function test_noReturnIMDStillSettlesGraduationBurnAndFees() public {
        vm.etch(IMD, address(new NoReturnIMD()).code);
        _oneRollGraduation();
        assertTrue(liq.imdPool(address(pvpToken)));
        assertTrue(pvpToken.unlocked());
        vm.deal(address(this), 1 ether);
        liq.fundBurn{value: 0.02 ether}();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        liq.burnChunk();
        assertGt(liq.totalBurnedEth(), 0);
        _assertEscrow();
    }
}

contract V4FallbackTest is BaseTest {
    function test_nativeGenesisThenIMDGraduationLeavesNoStrandedQuoteDust() public {
        graduatePvp();
        assertFalse(liq.imdPool(address(pvpToken)));
        TestIMD implementation = new TestIMD();
        vm.etch(IMD, address(implementation).code);
        TestIMD imd = TestIMD(IMD);
        PoolKey memory key = PoolKey(address(0), IMD, 10_000, 100, address(0));
        pm.initialize(key, uint160(1 << 96));
        imd.mint(address(router), 100 ether);
        vm.deal(address(router), 100 ether);
        router.add(key, 68 ether);
        PadGame game = PadGame(pad.gameOf(pad.launch("After fallback", "AF", "")));
        mintAll(game, 1);
        advance(10 minutes);
        rollAs(game, players[0]);
        advance(10 minutes);
        game.finalize();
        liq.convertChunk(address(game));
        game.graduate();
        assertTrue(liq.imdPool(game.token()));
        assertEq(imd.balanceOf(address(liq)), 0, "all credited IMD is settled, including LP fee dust");
        assertEq(liq.burnIMD(), 0, "native genesis has no unusable intermediate bucket");
        vm.prank(players[8]);
        king.takeCrown{value: 0.01 ether}();
        liq.distribute(16);
        assertGt(imd.balanceOf(players[8]), 0, "the first king receives the graduation dust in kind");
        assertEq(imd.balanceOf(address(liq)), 0);
    }

    function test_zeroIMDAfter24HoursGraduatesNativeAndPreservesV3Burn() public {
        openPad();
        mintAll(pvp, 2);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        advance(10 minutes);
        pvp.finalize();
        uint64 start = pvp.finalizedAt();
        liq.convertChunk(address(pvp)); // real manager, uninitialized IMD pool
        (uint256 left, uint256 spent, uint256 got,,, bool started,) = liq.conversions(address(pvp));
        assertTrue(started);
        assertEq(spent, 0);
        assertEq(got, 0);
        assertEq(left, pvp.ethRaised());
        vm.warp(uint256(start) + 24 hours - 1);
        vm.expectRevert(abi.encodeWithSignature("PadNotGraduable()"));
        pvp.graduate();
        vm.warp(uint256(start) + 24 hours);
        pvp.graduate();
        assertTrue(pvpToken.unlocked());
        assertFalse(liq.imdPool(address(pvpToken)));
        assertEq(liq.poolKey(address(pvpToken)).currency0, address(0));
        assertEq(liq.totalConversionEth(), 0);
        vm.deal(address(this), 1 ether);
        liq.fundBurn{value: 0.02 ether}();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 before = liq.totalBurnedEth();
        liq.burnChunk();
        assertGt(liq.totalBurnedEth(), before);
    }
}
