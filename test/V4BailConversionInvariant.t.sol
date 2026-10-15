// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {IPoolManager, PoolKey} from "../src/interfaces/Interfaces.sol";
import {V4Router} from "./RealV4.sol";
import {MockArbSys, Rejector} from "./mocks/Mocks.sol";
import {TestIMD} from "./V4Pad.t.sol";

/// @notice Drives the v4 value paths (bail-outs, ETH -> IMD conversion, IMD graduation, two-hop burn,
/// in-kind king fees) with bounded random calls on the real v4-core PoolManager and a real IMD/ETH
/// venue that an outside trader keeps moving. Expectations that must hold at the moment of a call
/// are checked inside the handler and recorded as violations, never as reverts, so a swallowed revert
/// cannot hide them.
contract V4Handler is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    PvPPad public pad;
    PadLiquidity public liq;
    KingOfThePad public king;
    MockArbSys public arb;
    IPoolManager public pm;
    TestIMD public imd;
    V4Router public trader;
    PoolKey public imdKey;

    address[] public actors;
    uint256 public externalEth;
    uint256 public violations;
    string public lastViolation;

    uint256 public bailOuts;
    uint256 public bailRefusals;
    uint256 public chunksWithProgress;
    uint256 public imdGraduations;
    uint256 public nativeGraduations;
    uint256 public failedGraduations;
    uint256 public finalizations;
    uint256 public burns;
    uint256 public crowns;

    mapping(address => mapping(address => bool)) public ghostErased; // game => wallet
    mapping(address => uint256) public ghostEscrow; // game => ETH escrowed at startConversion
    mapping(address => bool) public ghostGraduated;
    mapping(address => bool) public ghostClosed;
    mapping(address => uint256) public ghostLastProgress;

    constructor(PvPPad pad_, PadLiquidity liq_, KingOfThePad king_, MockArbSys arb_, IPoolManager pm_, TestIMD imd_) {
        pad = pad_;
        liq = liq_;
        king = king_;
        arb = arb_;
        pm = pm_;
        imd = imd_;
        trader = new V4Router(pm_);
        imdKey = PoolKey(address(0), address(imd_), 10_000, 100, address(0));
    }

    receive() external payable {}

    function addActor(address a) external {
        actors.push(a);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---- game play --------------------------------------------------------------------------------
    function enter(uint256 a, uint256 g) external {
        PadGame game = _game(g);
        vm.prank(_actor(a));
        try game.enter{value: 0.001 ether}() {} catch {}
        _after();
    }

    function roll(uint256 a, uint256 g) external {
        PadGame game = _game(g);
        address who = _actor(a);
        if (who.balance < 0.002 ether) return;
        bool erased = game.erased(who);
        vm.prank(who);
        try game.roll{value: 0.002 ether}() {
            _check(!erased, "erased wallet rolled");
        } catch {}
        _after();
    }

    /// @dev Every bail-out attempt is predicted from the public views and compared with the outcome.
    function bailOut(uint256 a, uint256 g, uint256 seed) external {
        PadGame game = _game(g);
        PadToken token = PadToken(game.token());
        address who = _actor(a);
        bool eligible =
            game.drawComplete() && !game.ended() && !game.finalized() && game.impOf(who) != 0 && !game.erased(who);
        uint256 coins = token.balanceOf(who);
        uint256 value = coins <= game.tokensSold() ? game.quoteSell(coins) : 0;
        uint256 cost = game.curveSpent(who);
        uint256 payout = value >= cost ? cost + (value - cost) / 2 : value * 90 / 100;
        uint256 mode = seed % 4;
        uint256 minOut = mode == 0 ? payout + 1 : mode == 1 ? payout : mode == 2 ? 0 : bound(seed / 4, 0, payout);
        uint256 pot = game.pot();
        uint256 earned = game.rollPot();
        uint256 raised = game.ethRaised();
        uint256 sold = game.tokensSold();
        uint256 wealth = who.balance + game.claimable(who);
        uint256 cap = game.fundedReleaseCap();
        vm.prank(who);
        try game.bailOut(minOut) {
            bailOuts += 1;
            _check(eligible, "bail-out accepted outside play or from a non-seated/erased wallet");
            _check(minOut <= payout, "bail-out paid less than minOut");
            _check(game.erased(who), "bailed wallet not erased");
            _check(token.balanceOf(who) == 0, "bailed wallet keeps coins");
            _check(game.ethRaised() == raised - value, "curve ETH not reduced by the sell value");
            _check(game.tokensSold() == sold - coins, "tokens sold not reduced by the coins");
            _check(game.pot() == pot + value - payout, "pot did not receive the rest of V");
            _check(game.rollPot() == earned, "bail tax raised rollPot");
            _check(payout <= value, "payout above the sell value");
            _check(who.balance + game.claimable(who) == wealth + payout, "payout not delivered");
            _check(game.fundedReleaseCap() <= cap, "bail-out raised the funded release cap");
            _check(game.fundedReleaseCap() <= game.ethRaised() * 15 / 100, "cap above 15% of net curve ETH");
            _check(!game.isAlive(game.impOf(who) - 1), "erased seat still alive");
            ghostErased[address(game)][who] = true;
        } catch {
            bailRefusals += 1;
            _check(!(eligible && minOut <= payout), "eligible bail-out at or above minOut refused");
            _check(game.ethRaised() == raised && game.pot() == pot, "refused bail-out changed state");
            _check(game.erased(who) == ghostErased[address(game)][who], "refused bail-out changed erasure");
        }
        _after();
    }

    function warp(uint256 secs, uint256 blocks) external {
        secs = bound(secs, 1, 12 minutes);
        blocks = bound(blocks, 0, 300);
        vm.warp(vm.getBlockTimestamp() + secs);
        arb.advance(blocks);
        _after();
    }

    function resolve(uint256 g, uint256 max) external {
        _game(g).resolvePending(bound(max, 0, 20));
        _after();
    }

    function poke(uint256 a, uint256 g) external {
        vm.prank(_actor(a));
        try _game(g).poke() {} catch {}
        _after();
    }

    function padUpkeep(uint256 a) external {
        vm.prank(_actor(a));
        pad.upkeep();
        _after();
    }

    /// @dev Composite: end the game by the clock, resolve, finalize from this contract, and check
    /// that erased wallets receive nothing from the pot.
    function finalizeNow(uint256 g) external {
        PadGame game = _game(g);
        if (!game.drawComplete() || game.finalized()) return;
        if (!game.ended()) {
            vm.warp(game.endTime() + 1);
        }
        arb.advance(300);
        for (uint256 i; i < 20 && game.pendingCount() != 0; ++i) {
            game.resolvePending(16);
        }
        uint256[] memory wealth = new uint256[](actors.length);
        for (uint256 i; i < actors.length; ++i) {
            wealth[i] = actors[i].balance + game.claimable(actors[i]);
        }
        uint256 erasedSeats;
        for (uint256 i; i < game.impCount(); ++i) {
            if (game.erased(game.getImp(i).owner)) ++erasedSeats;
        }
        bool quiet = _othersQuiet(game);
        try game.finalize() {
            finalizations += 1;
            _check(game.livingAtEnd() + erasedSeats <= game.impCount(), "erased seat counted as living");
            for (uint256 i; i < actors.length; ++i) {
                if (quiet && ghostErased[address(game)][actors[i]]) {
                    _check(
                        actors[i].balance + game.claimable(actors[i]) == wealth[i], "erased wallet earned from the pot"
                    );
                }
            }
            _check(game.pot() == 0, "pot left after finalize");
        } catch {}
        _after();
    }

    // ---- conversion and graduation ------------------------------------------------------------------
    function convertChunk(uint256 a, uint256 g) external {
        PadGame game = _game(g);
        (uint256 remaining, uint256 converted, uint256 received, uint64 attempted,, bool started, bool closed) =
            liq.conversions(address(game));
        uint256 spot = _spot(imdKey);
        bool intervalOpen = attempted == 0 || vm.getBlockTimestamp() >= uint256(attempted) + 30;
        bool open = started && !closed && remaining != 0;
        vm.prank(_actor(a));
        try liq.convertChunk(address(game)) {
            (uint256 r2, uint256 c2, uint256 i2,,, bool s2,) = liq.conversions(address(game));
            _check(s2, "chunk on an unstarted conversion");
            if (!open) {
                // only a game whose conversion was prepared by this very call can succeed here
                _check(game.finalized() && !started, "chunk accepted while not converting");
            } else {
                _check(intervalOpen, "chunk inside the 30 s interval");
            }
            _check(r2 + c2 == (started ? remaining + converted : game.ethRaised()), "escrow ledger not conserved");
            if (c2 > converted) {
                chunksWithProgress += 1;
                _check(i2 > received, "progress without IMD");
                uint256 newSpot = _spot(imdKey);
                _check(newSpot >= spot - spot * 50 / 10_000, "chunk moved the venue below the 1% limit");
                _check(newSpot <= spot, "ETH -> IMD chunk raised the sqrt price");
                ghostLastProgress[address(game)] = vm.getBlockTimestamp();
            } else {
                _check(i2 == received, "IMD credited without ETH spent");
            }
        } catch {
            _check(!(open && intervalOpen), "open conversion with free interval refused a chunk");
        }
        _after();
    }

    function convertAll(uint256 g) external {
        PadGame game = _game(g);
        for (uint256 i; i < 40; ++i) {
            (uint256 remaining,,,,, bool started, bool closed) = liq.conversions(address(game));
            if (started && (closed || remaining == 0)) break;
            try liq.convertChunk(address(game)) {} catch {}
            (uint256 after_,,,,,,) = liq.conversions(address(game));
            if (after_ == remaining && started) {
                // the venue is not moving this game forward; let time pass towards the fallback
                vm.warp(vm.getBlockTimestamp() + 30);
            } else {
                vm.warp(vm.getBlockTimestamp() + 30);
            }
        }
        _after();
    }

    function graduate(uint256 a, uint256 g) external {
        PadGame game = _game(g);
        PadToken token = PadToken(game.token());
        (uint256 remaining, uint256 converted, uint256 received,,, bool started,) = liq.conversions(address(game));
        bool could = game.finalized() && !game.graduated()
            && (game.ethRaised() == 0 || (started && liq.canGraduate(address(game))));
        uint256 liqEth = address(liq).balance;
        uint256 carry = pad.carryPot();
        bool quiet = _othersQuiet(game);
        vm.prank(_actor(a));
        try game.graduate() {
            _check(could, "graduated while not graduable");
            _check(game.graduated(), "graduate without flag");
            if (game.failed()) {
                failedGraduations += 1;
                _check(game.ethRaised() == 0, "failed with curve ETH");
                _check(!token.unlocked(), "failed token unlocked");
            } else {
                _check(token.unlocked(), "graduated token still locked");
                uint256 idx = liq.poolIndexOf(game.launchId());
                _check(idx != 0, "no pool after graduation");
                (,,,,,, bool closed) = liq.conversions(address(game));
                _check(closed, "conversion left open after graduation");
                (uint256 r2,,,,,,) = liq.conversions(address(game));
                _check(r2 == 0, "escrow ETH left after graduation");
                if (received == 0) {
                    nativeGraduations += 1;
                    _check(!liq.imdPool(address(token)), "native fallback registered as IMD pool");
                    if (quiet) _check(pad.carryPot() == carry, "native fallback carried ETH");
                } else {
                    imdGraduations += 1;
                    _check(liq.imdPool(address(token)), "IMD graduation not registered");
                    if (quiet) _check(pad.carryPot() == carry + remaining, "unconverted ETH not carried");
                    _check(converted + remaining == ghostEscrow[address(game)], "escrow split mismatch");
                }
                _check(token.balanceOf(address(game)) == 0 && token.balanceOf(address(liq)) == 0, "coins stranded");
            }
        } catch {
            _check(!could, "graduable game refused to graduate");
            (,,,,, bool s2,) = liq.conversions(address(game));
            _check(s2 == started, "failed graduate changed the escrow start");
            _check(address(liq).balance == liqEth, "failed graduate moved ETH");
        }
        _after();
    }

    // ---- venue, burn, king ----------------------------------------------------------------------------
    /// @dev An outside trader moves the IMD/ETH spot both ways. ETH it receives is tracked as external.
    function trade(bool zeroForOne, uint256 amount) external {
        if (_spot(imdKey) == 0) return;
        amount = bound(amount, 0.001 ether, 8 ether);
        if (zeroForOne) {
            vm.deal(address(trader), address(trader).balance + amount);
            externalEth += amount;
        } else {
            imd.mint(address(trader), amount);
        }
        try trader.trade(imdKey, zeroForOne, amount) {} catch {}
        _after();
    }

    function fundBurn(uint256 a, uint256 amount) external {
        amount = bound(amount, 0, 0.3 ether);
        address who = _actor(a);
        if (who.balance < amount) return;
        vm.prank(who);
        liq.fundBurn{value: amount}();
        _after();
    }

    function burnChunk() external {
        uint256 bucket = liq.burnBucket();
        uint256 spent = liq.totalBurnedEth();
        uint256 spot = _spot(imdKey);
        try liq.burnChunk() {
            uint256 used = liq.totalBurnedEth() - spent;
            _check(used <= 0.02 ether, "burn chunk above 0.02 ETH");
            _check(liq.burnBucket() == bucket - used, "unspent burn ETH left the bucket");
            if (used != 0) {
                burns += 1;
                uint256 newSpot = _spot(imdKey);
                if (liq.imdPool(PadGame(pad.gameOf(pad.genesisId())).token())) {
                    _check(newSpot >= spot - spot * 50 / 10_000, "burn first hop moved past 1%");
                }
            }
        } catch {}
        _after();
    }

    function fundCarry(uint256 a, uint256 amount) external {
        amount = bound(amount, 0, 0.5 ether);
        address who = _actor(a);
        if (who.balance < amount) return;
        vm.prank(who);
        pad.fundCarry{value: amount}();
        _after();
    }

    function takeCrown(uint256 a, uint256 amount) external {
        amount = bound(amount, 0.01 ether, 2 ether);
        address who = _actor(a);
        if (who.balance < amount) return;
        vm.prank(who);
        try king.takeCrown{value: amount}() {
            crowns += 1;
        } catch {}
        _after();
    }

    function distribute(uint256 a, uint256 n) external {
        address k = king.king();
        uint256 imdBefore = k == address(0) ? 0 : imd.balanceOf(k);
        vm.prank(_actor(a));
        try liq.distribute(bound(n, 1, 4)) {} catch {}
        if (k != address(0)) _check(imd.balanceOf(k) >= imdBefore, "king lost IMD on distribution");
        _after();
    }

    /// @dev Pretend trading fees on a graduated IMD pool: IMD comes from outside, coins from dEaD.
    function creditFees(uint256 poolSeed, uint256 q, uint256 c) external {
        uint256 count = liq.poolCount();
        if (count == 0) return;
        PadLiquidity.Pool memory p = liq.getPool(poolSeed % count);
        if (!liq.imdPool(p.token)) return;
        PadToken t = PadToken(p.token);
        q = bound(q, 0, 0.05 ether);
        c = bound(c, 0, t.balanceOf(DEAD));
        if (q != 0) imd.mint(address(trader), q);
        if (c != 0) {
            vm.prank(DEAD);
            t.transfer(address(trader), c);
        }
        PoolKey memory key = liq.poolKey(p.token);
        bool coin0 = key.currency0 == p.token;
        try trader.donate(key, coin0 ? c : q, coin0 ? q : c) {} catch {}
        _after();
    }

    function launch(uint256 a) external {
        vm.prank(_actor(a));
        try pad.launch("Launch", "L", "") {} catch {}
        _after();
    }

    function claimGame(uint256 a, uint256 g) external {
        vm.prank(_actor(a));
        try _game(g).claim() {} catch {}
        _after();
    }

    function claimLiquidity(uint256 a) external {
        vm.prank(_actor(a));
        try liq.claim() {} catch {}
        _after();
    }

    // ---- ghost bookkeeping ------------------------------------------------------------------------------
    function _after() internal {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame game = PadGame(pad.gameOf(i));
            address ga = address(game);
            (uint256 remaining, uint256 converted,,, uint64 progress, bool started, bool closed) = liq.conversions(ga);
            if (started && ghostEscrow[ga] == 0) ghostEscrow[ga] = remaining + converted;
            if (ghostGraduated[ga]) _check(game.graduated(), "graduation reopened");
            else ghostGraduated[ga] = game.graduated();
            if (ghostClosed[ga]) _check(closed, "closed conversion reopened");
            else ghostClosed[ga] = closed;
            if (started) _check(progress >= game.finalizedAt(), "progress stamp before finalization");
            for (uint256 j; j < actors.length; ++j) {
                if (ghostErased[ga][actors[j]]) _check(game.erased(actors[j]), "erasure undone");
            }
        }
    }

    function _check(bool ok, string memory what) internal {
        if (ok) return;
        violations += 1;
        lastViolation = what;
    }

    /// @dev True when no other game can pay anyone during this call's bounded upkeep.
    function _othersQuiet(PadGame game) internal view returns (bool) {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame other = PadGame(pad.gameOf(i));
            if (other == game) continue;
            if (other.entryCount() != 0 && !other.graduated()) return false;
        }
        return true;
    }

    function _spot(PoolKey memory key) internal view returns (uint256) {
        return liq.sqrtPriceOf(key);
    }

    function _game(uint256 seed) internal view returns (PadGame) {
        return PadGame(pad.gameOf(seed % pad.launchCount() + 1));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
contract V4BailConversionInvariantTest is BaseTest {
    V4Handler handler;
    TestIMD imd;
    PoolKey imdKey;
    Rejector rejector;
    uint256 initialEth;

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
        handler = new V4Handler(pad, liq, king, arb, pm, imd);
        rejector = new Rejector();
        for (uint256 i; i < 6; ++i) {
            vm.deal(players[i], 100 ether);
            handler.addActor(players[i]);
        }
        vm.deal(address(rejector), 100 ether);
        handler.addActor(address(rejector));
        initialEth = _systemEth();

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](24);
        sels[0] = V4Handler.enter.selector;
        sels[1] = V4Handler.enter.selector;
        sels[2] = V4Handler.roll.selector;
        sels[3] = V4Handler.roll.selector;
        sels[4] = V4Handler.roll.selector;
        sels[5] = V4Handler.bailOut.selector;
        sels[6] = V4Handler.bailOut.selector;
        sels[7] = V4Handler.warp.selector;
        sels[8] = V4Handler.warp.selector;
        sels[9] = V4Handler.resolve.selector;
        sels[10] = V4Handler.poke.selector;
        sels[11] = V4Handler.padUpkeep.selector;
        sels[12] = V4Handler.finalizeNow.selector;
        sels[13] = V4Handler.convertChunk.selector;
        sels[14] = V4Handler.convertAll.selector;
        sels[15] = V4Handler.graduate.selector;
        sels[16] = V4Handler.trade.selector;
        sels[17] = V4Handler.fundBurn.selector;
        sels[18] = V4Handler.burnChunk.selector;
        sels[19] = V4Handler.fundCarry.selector;
        sels[20] = V4Handler.takeCrown.selector;
        sels[21] = V4Handler.distribute.selector;
        sels[22] = V4Handler.creditFees.selector;
        sels[23] = V4Handler.launch.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
        bytes4[] memory more = new bytes4[](2);
        more[0] = V4Handler.claimGame.selector;
        more[1] = V4Handler.claimLiquidity.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: more}));
    }

    function invariant_handlerSawNoViolation() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// @notice A game holds exactly its pot, its curve ETH until escrowed, the bounty, pending tips and
    /// failed pushes. Bail-outs move ETH between these buckets and to the player, never outside them.
    function invariant_gameBalanceEqualsObligations() public view {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame g = PadGame(pad.gameOf(i));
            (,,,,, bool started,) = liq.conversions(address(g));
            uint256 owed = g.pot() + (started || g.graduated() ? 0 : g.ethRaised()) + g.drawBounty() + g.pendingCount()
                * g.ROLL_TIP();
            for (uint256 a; a < _payeeCount(); ++a) {
                owed += g.claimable(_payee(a));
            }
            assertEq(address(g).balance, owed, "game balance != obligations");
        }
    }

    /// @notice PadLiquidity holds exactly the burn bucket, the open conversion escrows and parked king
    /// payments in ETH, and exactly the converted-but-unseeded IMD plus the burn intermediate in IMD.
    function invariant_liquidityEthAndImdFullyAccounted() public view {
        uint256 owed = liq.burnBucket() + liq.totalConversionEth();
        for (uint256 a; a < _payeeCount(); ++a) {
            owed += liq.claimable(_payee(a));
        }
        assertEq(address(liq).balance, owed, "liquidity ETH != bucket + escrows + claimables");
        assertEq(imd.balanceOf(address(liq)), liq.totalConversionIMD() + liq.burnIMD(), "IMD != escrow + burn");
        uint256 escrows;
        uint256 credits;
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            (uint256 remaining,, uint256 received,,, bool started, bool closed) = liq.conversions(pad.gameOf(i));
            if (started && !closed) {
                escrows += remaining;
                credits += received;
            }
            if (closed) assertEq(remaining, 0, "closed conversion keeps ETH");
        }
        assertEq(liq.totalConversionEth(), escrows, "total escrow != sum of open escrows");
        assertEq(liq.totalConversionIMD(), credits, "total IMD credit != sum of open credits");
    }

    function invariant_systemEthConserved() public view {
        assertEq(_systemEth(), initialEth + handler.externalEth(), "ETH appeared or vanished");
    }

    /// @notice Before graduation the curve's sold coins are exactly what seated wallets hold; a bail-out
    /// returns them to the game. The supply never changes.
    function invariant_coinsSoldEqualHoldingsUntilGraduation() public view {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame g = PadGame(pad.gameOf(i));
            PadToken t = PadToken(g.token());
            assertEq(t.totalSupply(), 1_000_000_000 ether);
            uint256 held;
            for (uint256 a; a < handler.actorCount(); ++a) {
                held += t.balanceOf(handler.actors(a));
            }
            if (!g.graduated()) {
                assertEq(held, g.tokensSold(), "sold coins != wallet holdings");
                assertEq(held + t.balanceOf(address(g)), 1_000_000_000 ether, "coins left the game early");
            }
            assertLe(g.tokensSold(), 800_000_000 ether);
            assertLe(g.ethRaised(), 4 ether);
            (uint256 vEth, uint256 vTok,) = g.curveState();
            assertGe(vEth * vTok, 1 ether * 1_000_000_000 ether, "constant product below K after sells");
            assertEq(g.tokensSold() == 0, g.ethRaised() == 0, "curve ETH without coins or coins without ETH");
        }
    }

    /// @notice Erased seats never roll, rank, live or count for the king, and funded ETH stays capped by
    /// the roll-earned pot and 15% of net curve ETH.
    function invariant_erasedSeatsExcludedAndCapsHold() public view {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame g = PadGame(pad.gameOf(i));
            uint256 erased;
            uint256 alive;
            for (uint256 j; j < g.impCount(); ++j) {
                address owner = g.getImp(j).owner;
                if (g.erased(owner)) {
                    ++erased;
                    assertFalse(g.isAlive(j), "erased seat alive");
                    assertEq(PadToken(g.token()).balanceOf(owner) == 0 || g.graduated(), true, "erased keeps coins");
                } else if (g.isAlive(j)) {
                    ++alive;
                }
            }
            (bool live,) = g.isLiveForKing();
            if (live && g.drawComplete()) assertGe(g.impCount() - erased, 5, "king counts erased seats");
            if (g.finalized()) assertLe(g.livingAtEnd() + erased, g.impCount(), "living includes erased");
            assertLe(g.rollPot(), g.pot(), "roll pot above pot");
            assertLe(g.fundedReleaseCap(), g.ethRaised() * 15 / 100, "cap above 15% of net curve ETH");
            assertLe(g.fundedReleaseCap(), g.rollPot() * 3, "cap above 3x roll income");
        }
    }

    /// @notice The converting phase is reported exactly while an escrow is open and cannot graduate yet,
    /// and graduation is final.
    function invariant_statusAndConversionPhases() public view {
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            PadGame g = PadGame(pad.gameOf(i));
            PadToken t = PadToken(g.token());
            uint8 s = g.status();
            bool converting = g.finalized() && !g.graduated() && g.ethRaised() != 0 && !liq.canGraduate(address(g));
            assertEq(s == 8, converting, "converting phase misreported");
            if (g.graduated()) {
                assertTrue(g.finalized(), "graduated before finalize");
                assertEq(s, g.failed() ? 6 : 5);
                (uint256 remaining,,,,, bool started, bool closed) = liq.conversions(address(g));
                if (!g.failed()) {
                    assertTrue(started && closed, "graduated without a closed escrow");
                    assertEq(remaining, 0);
                    assertNotEq(liq.poolIndexOf(g.launchId()), 0, "graduated without pool");
                }
            }
            assertEq(t.unlocked(), g.graduated() && !g.failed(), "unlock out of step with graduation");
            if (g.finalized()) assertEq(g.pot(), 0);
        }
    }

    function invariant_callSummary() public view {
        // informational
        handler.bailOuts();
        handler.chunksWithProgress();
        handler.imdGraduations();
    }

    // ---- helpers ------------------------------------------------------------------------------------------
    function _payeeCount() internal view returns (uint256) {
        return handler.actorCount() + 2;
    }

    function _payee(uint256 i) internal view returns (address) {
        uint256 c = handler.actorCount();
        if (i < c) return handler.actors(i);
        if (i == c) return address(king);
        return address(handler);
    }

    function _systemEth() internal view returns (uint256 total) {
        for (uint256 a; a < _payeeCount(); ++a) {
            total += _payee(a).balance;
        }
        uint256 n = pad.launchCount();
        for (uint256 i = 1; i <= n; ++i) {
            total += pad.gameOf(i).balance;
        }
        total += address(liq).balance + address(pad).balance + address(pm).balance + DEAD.balance + OWNER.balance
        + address(handler.trader()).balance + address(router).balance;
    }
}
