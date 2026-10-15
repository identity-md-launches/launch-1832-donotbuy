// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadErrors} from "./interfaces/PadErrors.sol";

import {PadLib} from "./libs/PadLib.sol";
import {Lock} from "../lib/v4-core/src/libraries/Lock.sol";
import {PadHook} from "./PadHook.sol";
import {
    IArbSys,
    IPoolManager,
    IPoolStateReader,
    IUnlockCallback,
    IPadToken,
    IPadGame,
    IPvPPad,
    PoolKey,
    ModifyLiquidityParams,
    SwapParams
} from "./interfaces/Interfaces.sol";

interface IKingView {
    function king() external view returns (address);
}

/// @title PadLiquidity
/// @notice Converts curve ETH into IMD, then seeds sorted coin/IMD v4 pools (native fallback on
/// zero conversion), fee 10000, tickSpacing 200, PadHook. Owns full-range LP forever, pays king fees
/// in kind and buys/burns PVP through two hops. All swaps use PoolManager.unlock with own funds.
contract PadLiquidity is IUnlockCallback {
    uint24 internal constant FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant MIN_TICK = -887_200;
    int24 internal constant MAX_TICK = 887_200;
    // TickMath.getSqrtPriceAtTick(-887200) and (887200) of v4-core v4.0.0; asserted in LiquidityV4.t.sol.
    uint160 public constant SQRT_MIN_FULL = 4_310_618_292;
    uint160 public constant SQRT_MAX_FULL = 1_456_195_216_270_955_103_206_513_029_158_776_779_468_408_838_535;
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant CONVERT_INTERVAL = 30;
    uint256 internal constant CONVERT_TIMEOUT = 24 hours;
    /// @notice Hard bound on a conversion, whatever progress it makes: never stranded.
    uint256 internal constant CONVERT_MAX_DURATION = 7 days;
    /// @notice A chunk never sells below the game's anchor minus 1% in sqrt price (about 2% in price).
    uint256 internal constant ANCHOR_BAND_BPS = 100;
    /// @notice The anchor follows a falling market by at most 0.5% sqrt price (about 1% price) per hour.
    uint256 internal constant ANCHOR_DECAY_BPS_PER_HOUR = 50;
    /// @notice Converting at least 1/1000 of the escrow since the last stamp is needed to count as progress.
    uint256 internal constant PROGRESS_FLOOR_DIVISOR = 1000;
    uint256 internal constant Q96 = 1 << 96;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant BURN_MAX = 0.02 ether;
    uint256 internal constant BURN_INTERVAL = 10 minutes;
    uint256 internal constant COLLECT_GAS = 300_000;
    /// @notice Public `distribute` examines at most this many pools per call.
    uint256 internal constant MAX_DISTRIBUTE_POOLS = 16;
    /// @dev A pre-crown settlement walks every pool while gas fits and must reach at least this many.
    uint256 internal constant MIN_CROWN_POOLS = 16;
    uint256 internal constant COLLECTION_RESERVE_GAS = 100_000;
    uint256 internal constant BROKEN_FAILURES = 3;
    uint256 internal constant LIQUIDITY_MARGIN_PPM = 1_000_000;
    /// @notice Each burn buy is limited to this sqrt-price move from the
    /// pre-swap spot: 0.5% in sqrt price, about 1% in price. Unfilled input stays for a later chunk.
    /// This bounds per-call impact; it is not a general guarantee against MEV or spot manipulation.
    uint256 internal constant IMPACT_BPS = 50;
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    uint8 internal constant ACT_ADD = 1;
    uint8 internal constant ACT_COLLECT = 2;
    uint8 internal constant ACT_BURN = 3;
    uint8 internal constant ACT_CONVERT = 4;

    struct Pool {
        uint256 launchId;
        address token;
        uint128 liquidity;
        /// @dev Reign the pool's fees are settled for (see `reign`). Below the current reign, the pool
        /// still holds fees of an earlier reign and its next collection pays that reign's king.
        /// Packed with `liquidity` so its first update rewrites a non-zero slot.
        uint64 settledReign;
        uint256 ethFees;
        uint256 tokenFees;
        uint64 lastFailureBlock;
        uint8 failures;
        uint256 imdFees;
    }

    /// @dev mark: convertedEth at the last lastProgress stamp.
    struct Guard {
        uint64 startedAt;
        uint256 mark;
    }

    struct Conversion {
        uint256 remainingEth;
        uint256 convertedEth;
        uint256 imdReceived;
        uint64 lastAttempt;
        uint64 lastProgress;
        bool started;
        bool closed;
    }

    // Written only by the constructor; no setters. Storage avoids repeated PUSH32
    // addresses in runtime and keeps the complete deployment below its gas target.
    IPoolManager public poolManager;
    address public imd;
    mapping(address => Conversion) public conversions;
    mapping(address => bool) public imdPool;
    uint256 public totalConversionEth;
    uint256 public totalConversionIMD;
    uint256 public burnIMD;
    address public pad;
    address public king;
    address public hook;
    uint256 public burnBucket;
    uint64 public lastBurnAt;
    uint256 public distributeCursor;
    uint256 public totalBurnedEth;
    /// @notice Number of crown changes settled so far. Reign r is the time between settlement r and
    /// settlement r + 1; reign 0 runs from deployment (no king, then the first king) to the first change.
    uint256 public reign;
    /// @notice The king whose reign each settlement closed; set when `settleCrown` runs.
    mapping(uint256 => address) public reignKing;
    bool private locked;
    bool private claimLocked;
    /// @dev Pad-wide anchor: the best IMD/ETH sqrt price seen at any pad touch (every roll, entry, poke,
    /// launch, king action, finalization and chunk observes it), decaying linearly from anchorAt. Shared
    /// by every game: a single venue has a single market price, and a position pushed before one
    /// game's finalization is measured against what every earlier touch recorded.
    uint160 internal marketAnchor;
    uint64 internal marketAnchorAt;

    Pool[] internal pools;
    mapping(uint256 => uint256) public poolIndexOf; // launchId => index + 1
    mapping(address => uint256) public claimable;
    mapping(address => Guard) internal guards;

    event ConversionStarted(address indexed game, uint256 eth, uint256 deadline);
    event ConversionProgress(address indexed game, uint256 spent, uint256 received, uint256 remaining);
    event ConversionStalled(address indexed game);
    event ConversionFallback(address indexed game, uint256 carriedEth, bool nativePool);
    event ImdFeesCollected(uint256 indexed launchId, address indexed king, uint256 imd, uint256 coins);
    event KingBound(address indexed king);
    event HookDeployed(address indexed hook, bytes32 salt);
    event Graduated(
        uint256 indexed launchId,
        address indexed token,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 eth,
        uint256 tokens,
        uint256 burnedTokens
    );
    event BurnFunded(address indexed from, uint256 amount);
    event Burned(uint256 ethSpent, uint256 tokensBurned);
    event FeesCollected(uint256 indexed launchId, address indexed king, uint256 eth, uint256 tokens);
    event PoolCollectionFailed(uint256 indexed launchId);
    event PoolHealth(uint256 indexed launchId, uint256 failures, bool broken);
    event KingPaid(address indexed king, uint256 amount, bool pushed);
    event Claimed(address indexed to, uint256 amount);

    modifier guard() {
        if (!(!locked)) revert PadErrors.PadReentrancy();
        locked = true;
        _;
        locked = false;
    }

    /// @param imdEthPoolId_ Canonical v4 PoolId: keccak256(abi.encode(PoolKey)). The fixed
    /// native currency and hookless venue are reconstructed, not supplied as party addresses.
    constructor(address poolManager_, address pad_, address imd_, bytes32 imdEthPoolId_) {
        if (!(poolManager_ != address(0) && pad_ != address(0))) revert PadErrors.PadZero();
        poolManager = IPoolManager(poolManager_);
        pad = pad_;
        if (!(imd_ != address(0))) revert PadErrors.PadZeroIMD();
        imd = imd_;
        if (imdEthPoolId_ != keccak256(abi.encode(imdEthKey()))) revert PadErrors.PadIMDKey();
        IPvPPad(pad_).bindLiquidity();
    }

    /// @dev Only the PoolManager pays ETH here (fee collection); everything else uses fundBurn/graduate.
    receive() external payable {
        _onlyManager();
    }

    function bindKing() external {
        if (!(king == address(0))) revert PadErrors.PadBound();
        king = msg.sender;
        emit KingBound(msg.sender);
    }

    // ---- hook ------------------------------------------------------------------------------------
    function deployHook(bytes32 salt) external returns (address h) {
        if (!(msg.sender == pad)) revert PadErrors.PadNotPad();
        if (!(hook == address(0))) revert PadErrors.PadDeployed();
        h = address(new PadHook{salt: salt}(address(poolManager), address(this)));
        hook = h;
        emit HookDeployed(h, salt);
    }

    /// @notice Init code hash to mine the open salt against (CREATE2 from this contract).
    function hookInitCodeHash() public view returns (bytes32) {
        return keccak256(abi.encodePacked(type(PadHook).creationCode, abi.encode(address(poolManager), address(this))));
    }

    function hookAddressFor(bytes32 salt) public view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash()))))
            );
    }

    // ---- graduation ------------------------------------------------------------------------------
    function imdEthKey() public view returns (PoolKey memory) {
        return PoolKey(address(0), imd, FEE, 100, address(0));
    }

    function poolKey(address token) public view returns (PoolKey memory) {
        if (!imdPool[token]) return PoolKey(address(0), token, FEE, TICK_SPACING, hook);
        return token < imd ? PoolKey(token, imd, FEE, TICK_SPACING, hook) : PoolKey(imd, token, FEE, TICK_SPACING, hook);
    }

    /// @dev Registered games escrow their net curve ETH once, after finalization. Donations cannot
    /// affect conversion balances, graduation price or the stall timer. The stall clock starts when
    /// the escrow is created, not at finalization: an untouched game is not "no progress".
    function startConversion(uint256 launchId, uint64) external payable {
        _onlyGame(launchId);
        Conversion storage c = conversions[msg.sender];
        if (!(!c.started && msg.value != 0)) revert PadErrors.PadConversionStartedOrEmpty();
        c.started = true;
        c.remainingEth = msg.value;
        c.lastProgress = uint64(block.timestamp);
        guards[msg.sender].startedAt = uint64(block.timestamp);
        totalConversionEth += msg.value;
        emit ConversionStarted(msg.sender, msg.value, block.timestamp + CONVERT_TIMEOUT);
    }

    /// @notice Records the IMD/ETH spot into the pad-wide anchor. The pad calls it at every touch
    /// (PvPPad upkeep, which every finalize path runs) and every chunk does; anyone may call it. Only a higher
    /// spot moves the anchor up, so a push-down bundled with any of those calls is ignored, and a
    /// spot read inside a PoolManager unlock (flash-pushed) is not recorded at all. Never reverts for
    /// a missing venue: an uninitialized pool reads as spot 0.
    function observeMarket() public returns (uint256 ref) {
        ref = anchor();
        if (_managerUnlocked()) return ref;
        uint256 spot = sqrtPriceOf(imdEthKey());
        if (spot > ref) ref = spot;
        marketAnchor = uint160(ref);
        marketAnchorAt = uint64(block.timestamp);
    }

    /// @notice The anchor now: the best spot seen at any pad touch, minus 0.5% sqrt price per elapsed hour.
    function anchor() public view returns (uint256) {
        uint256 cut = (block.timestamp - marketAnchorAt) * ANCHOR_DECAY_BPS_PER_HOUR;
        if (cut >= 10_000 * 1 hours) return 0;
        return uint256(marketAnchor) * (10_000 * 1 hours - cut) / (10_000 * 1 hours);
    }

    /// @notice One ETH -> IMD chunk, at most once per 30 seconds/game, limited to a 1% price move from
    /// spot and never below the anchor band (2% price under the decaying best spot seen at any pad
    /// touch), so a position held across all chunks, or pushed just before finalization, cannot walk
    /// the game's price. A missing/broken/empty/out-of-band pool records no progress, does not consume
    /// the interval and does not postpone the fallback deadline.
    function convertChunk(address game) external guard {
        // Inside a PoolManager unlock the venue is unreachable: reject instead of recording an attempt.
        requireManagerLocked();
        if (!conversions[game].started) IPadGame(game).prepareConversion();
        Conversion storage c = conversions[game];
        if (!(c.started && !c.closed && c.remainingEth != 0)) revert PadErrors.PadNotConverting();
        if (!(c.lastAttempt == 0 || block.timestamp >= uint256(c.lastAttempt) + CONVERT_INTERVAL)) {
            revert PadErrors.PadConversionInterval();
        }
        // A caller cannot consume the per-game interval with a deliberately underfunded probe.
        if (gasleft() < 350_000 + uint256(350_000) / 63 + 100_000) revert PadErrors.PadConversionGas();
        uint256 spot = sqrtPriceOf(imdEthKey());
        uint256 ref = observeMarket();
        uint256 limit;
        // spot and ref are uint160, so the products fit.
        unchecked {
            limit = spot - spot * IMPACT_BPS / 10_000;
            uint256 band = ref - ref * ANCHOR_BAND_BPS / 10_000;
            if (band > limit) limit = band;
        }
        if (limit <= MIN_SQRT_PRICE_LIMIT) limit = MIN_SQRT_PRICE_LIMIT + 1;
        if (limit >= spot) {
            emit ConversionStalled(game);
            return;
        }
        // The bounded self-call rolls back all PoolManager deltas on error, preserving the escrow.
        try this.executeConversion{gas: 350_000}(c.remainingEth, uint160(limit)) returns (
            uint256 spent, uint256 received
        ) {
            c.lastAttempt = uint64(block.timestamp);
            if (spent != 0 && received != 0) {
                c.remainingEth -= spent;
                c.convertedEth += spent;
                c.imdReceived += received;
                totalConversionEth -= spent;
                totalConversionIMD += received;
                // Dust fills on a collapsed venue do not refresh the stall clock.
                uint256 total = c.remainingEth + c.convertedEth;
                if (c.remainingEth == 0 || (c.convertedEth - guards[game].mark) * PROGRESS_FLOOR_DIVISOR >= total) {
                    guards[game].mark = c.convertedEth;
                    c.lastProgress = uint64(block.timestamp);
                }
            }
            emit ConversionProgress(game, spent, received, c.remainingEth);
        } catch {
            emit ConversionStalled(game);
        }
    }

    function executeConversion(uint256 amount, uint160 limit) external returns (uint256 spent, uint256 received) {
        _onlySelf();
        return abi.decode(poolManager.unlock(abi.encode(ACT_CONVERT, imdEthKey(), amount, limit)), (uint256, uint256));
    }

    function _king() internal view returns (address) {
        return IKingView(king).king();
    }

    function _onlySelf() internal view {
        if (!(msg.sender == address(this) && locked)) revert PadErrors.PadNotSelf();
    }

    function _onlyManager() internal view {
        if (!(msg.sender == address(poolManager))) revert PadErrors.PadNotPoolManager();
    }

    function _onlyGame(uint256 launchId) internal view {
        if (!(msg.sender == IPvPPad(pad).gameOf(launchId))) revert PadErrors.PadNotGame();
    }

    function canGraduate(address game) public view returns (bool) {
        Conversion storage c = conversions[game];
        return c.started && !c.closed
            && (c.remainingEth == 0
                || block.timestamp >= uint256(c.lastProgress) + CONVERT_TIMEOUT
                || block.timestamp >= uint256(guards[game].startedAt) + CONVERT_MAX_DURATION);
    }

    /// @notice Tokens arrive from the game. Quote funds come exclusively from that game's escrow.
    /// No progress for 24h: use partial IMD and carry the remaining ETH; zero IMD uses v3 native LP.
    function graduate(uint256 launchId, address token, uint256 tokenAmount, uint256 vEth, uint256 vTok)
        external
        payable
        guard
    {
        _onlyGame(launchId);
        if (!(hook != address(0))) revert PadErrors.PadPadNotOpen();
        if (!(poolIndexOf[launchId] == 0)) revert PadErrors.PadGraduated();
        Conversion storage c = conversions[msg.sender];
        if (!(msg.value == 0 && c.started && canGraduate(msg.sender))) revert PadErrors.PadConversionPending();
        c.closed = true;
        uint256 remaining = c.remainingEth;
        c.remainingEth = 0;
        totalConversionEth -= remaining;
        uint256 quoteAmount;
        uint256 coins;
        if (c.imdReceived == 0) {
            quoteAmount = remaining;
            coins = PadLib.mulDiv(remaining, vTok, vEth);
            emit ConversionFallback(msg.sender, 0, true);
        } else {
            imdPool[token] = true;
            quoteAmount = c.imdReceived;
            totalConversionIMD -= quoteAmount;
            coins = PadLib.mulDiv(c.convertedEth, vTok, vEth);
            if (remaining != 0) {
                IPvPPad(pad).fundCarry{value: remaining}();
                emit ConversionFallback(msg.sender, remaining, false);
            }
        }
        if (!(quoteAmount != 0 && coins != 0 && coins <= tokenAmount)) revert PadErrors.PadEmpty();
        PoolKey memory key = poolKey(token);
        bool coin0 = key.currency0 == token;
        uint256 max0 = coin0 ? coins : quoteAmount;
        uint256 max1 = coin0 ? quoteAmount : coins;
        uint160 sqrtP = PadLib.sqrtRatioX96(max1, max0);
        if (!(sqrtP > SQRT_MIN_FULL && sqrtP < SQRT_MAX_FULL)) revert PadErrors.PadPriceRange();
        uint256 l0 = PadLib.mulDiv(max0, PadLib.mulDiv(sqrtP, SQRT_MAX_FULL, Q96), SQRT_MAX_FULL - sqrtP);
        uint256 l1 = PadLib.mulDiv(max1, Q96, sqrtP - SQRT_MIN_FULL);
        uint256 l = l0 < l1 ? l0 : l1;
        l -= l / LIQUIDITY_MARGIN_PPM;
        if (!(l != 0 && l <= type(uint128).max)) revert PadErrors.PadLiquidity();
        poolManager.initialize(key, sqrtP);
        (uint256 used0, uint256 used1) =
            abi.decode(poolManager.unlock(abi.encode(ACT_ADD, key, l, max0, max1)), (uint256, uint256));
        uint256 usedQuote = coin0 ? used1 : used0;
        uint256 usedCoins = coin0 ? used0 : used1;
        pools.push(Pool(launchId, token, uint128(l), uint64(reign), 0, 0, 0, 0, 0));
        poolIndexOf[launchId] = pools.length;
        IPadToken(token).unlock();
        uint256 excess = tokenAmount - usedCoins;
        if (excess != 0) if (!(IPadToken(token).transfer(DEAD, excess))) revert PadErrors.PadBurn();
        if (!imdPool[token]) burnBucket += quoteAmount - usedQuote;
        emit Graduated(launchId, token, sqrtP, uint128(l), usedQuote, usedCoins, excess);
    }

    // ---- fees to the king -----------------------------------------------------------------------
    /// @notice Reject nested v4 unlocks even when this contract itself is idle.
    /// The slot comes directly from the pinned v4-core Lock library.
    function requireManagerLocked() public view {
        if (_managerUnlocked()) revert PadErrors.PadManagerUnlocked();
    }

    function _managerUnlocked() internal view returns (bool) {
        return IPoolStateReader(address(poolManager)).exttload(Lock.IS_UNLOCKED_SLOT) != bytes32(0);
    }

    /// @notice Permissionless round-robin collection. Fees stay in positions before the first crown.
    /// Three failed, fully gas-funded attempts in distinct L2 blocks flag a pool as broken.
    function distribute(uint256 n) external guard {
        _distribute(n, false);
    }

    /// @notice Atomic pre-crown batch: walks every pool from the cursor while the forwarded gas fits
    /// another collection, at least MIN_CROWN_POOLS of them, and an unflagged collection failure
    /// vetoes the bid. Pools it does not reach keep their entitlement: their next collection, by
    /// anyone, pays the outgoing king. Failed bids revert their failure counters too; use
    /// distribute/retryPool to diagnose a pool.
    function settleCrown() external guard {
        if (!(msg.sender == king)) revert PadErrors.PadNotKing();
        _distribute(type(uint256).max, true);
    }

    function _distribute(uint256 n, bool strict) internal {
        requireManagerLocked();
        address k = _king();
        uint256 count = pools.length;
        if (k == address(0) || count == 0 || n == 0) return;
        uint256 floor;
        if (strict) {
            // Close the outgoing king's reign: pools this walk does not reach stay owed to it.
            reignKing[reign] = k;
            reign += 1;
            n = count;
            floor = count < MIN_CROWN_POOLS ? count : MIN_CROWN_POOLS;
        } else {
            if (n > MAX_DISTRIBUTE_POOLS) n = MAX_DISTRIBUTE_POOLS;
            if (n > count) n = count;
        }
        for (uint256 i; i < n; ++i) {
            uint256 idx = distributeCursor % count;
            if (pools[idx].failures < BROKEN_FAILURES) {
                if (gasleft() < COLLECT_GAS + COLLECTION_RESERVE_GAS) {
                    if (!(i >= floor)) revert PadErrors.PadCollectionGas();
                    break;
                }
                bool ok = _collect(idx, k);
                if (!(ok || !strict)) revert PadErrors.PadPoolCollectionFailed();
            }
            distributeCursor = idx + 1;
        }
    }

    /// @notice Anyone can retry any pool, including a broken one. Success clears the flag.
    function retryPool(uint256 idx) external guard returns (bool) {
        requireManagerLocked();
        address k = _king();
        if (!(k != address(0))) revert PadErrors.PadNoKing();
        if (!(gasleft() >= COLLECT_GAS + COLLECTION_RESERVE_GAS)) revert PadErrors.PadCollectionGas();
        return _collect(idx, k);
    }

    /// @dev Pays the current king, unless the pool still holds fees of an earlier reign it was never
    /// settled for (not reached by that crown's walk, or broken then), in which case that reign's king.
    function _collect(uint256 idx, address k) internal returns (bool) {
        Pool storage p = pools[idx];
        uint256 settled = p.settledReign;
        address payee = settled < reign ? reignKing[settled] : k;
        try this.collectPool{gas: COLLECT_GAS}(idx, payee) {
            if (settled < reign) p.settledReign = uint64(reign);
            if (p.failures != 0) {
                p.failures = 0;
                p.lastFailureBlock = 0;
                _emitHealth(p);
            }
            return true;
        } catch {
            uint256 current = IArbSys(address(0x64)).arbBlockNumber();
            if (p.failures < BROKEN_FAILURES && (p.failures == 0 || current > p.lastFailureBlock)) {
                p.lastFailureBlock = uint64(current);
                ++p.failures;
                _emitHealth(p);
            }
            emit PoolCollectionFailed(p.launchId);
            return false;
        }
    }

    function _emitHealth(Pool storage p) private {
        emit PoolHealth(p.launchId, p.failures, p.failures == BROKEN_FAILURES);
    }

    /// @dev The self-call isolates a pool's revert. Both currencies are paid to the captured king;
    /// tokens are never swapped or stashed, and rejected ETH stays owed to that same king.
    function collectPool(uint256 idx, address k) external {
        _onlySelf();
        Pool storage p = pools[idx];
        PoolKey memory key = poolKey(p.token);
        bytes memory res = poolManager.unlock(abi.encode(ACT_COLLECT, key));
        (uint256 a0, uint256 a1) = abi.decode(res, (uint256, uint256));
        bool coin0 = key.currency0 == p.token;
        uint256 t = coin0 ? a0 : a1;
        uint256 q = coin0 ? a1 : a0;
        p.tokenFees += t;
        if (t != 0) if (!(IPadToken(p.token).transfer(k, t))) revert PadErrors.PadTokenFees();
        if (imdPool[p.token]) {
            p.imdFees += q;
            if (q != 0) if (!(_transfer(imd, k, q))) revert PadErrors.PadIMDFees();
            emit ImdFeesCollected(p.launchId, k, q, t);
        } else {
            p.ethFees += q;
            if (q != 0) {
                bool ok = PadLib.push(k, q);
                if (!ok) claimable[k] += q;
                emit KingPaid(k, q, ok);
            }
            emit FeesCollected(p.launchId, k, q, t);
        }
    }

    // ---- burn ------------------------------------------------------------------------------------
    function fundBurn() external payable {
        burnBucket += msg.value;
        emit BurnFunded(msg.sender, msg.value);
    }

    /// @notice Buys PvP with up to 0.02 ETH of the burn bucket and sends it to dEaD, once per 10 minutes.
    /// The buy stops at a 1% price move; ETH not spent stays in the bucket for the next chunk.
    function burnChunk() external guard {
        uint256 gid = IPvPPad(pad).genesisId();
        uint256 idx = gid == 0 ? 0 : poolIndexOf[gid];
        if ((burnBucket == 0 && burnIMD == 0) || idx == 0) return;
        if (block.timestamp < lastBurnAt + BURN_INTERVAL) return;
        uint256 amount = burnBucket > BURN_MAX ? BURN_MAX : burnBucket;
        burnBucket -= amount;
        lastBurnAt = uint64(block.timestamp);
        bytes memory res = poolManager.unlock(abi.encode(ACT_BURN, poolKey(pools[idx - 1].token), amount));
        (uint256 spent, uint256 tokens) = abi.decode(res, (uint256, uint256));
        if (spent < amount) burnBucket += amount - spent;
        totalBurnedEth += spent;
        emit Burned(spent, tokens);
    }

    /// @notice Current sqrt price of a pool, read from the PoolManager's storage (v4 StateLibrary layout).
    function sqrtPriceOf(PoolKey memory key) public view returns (uint160) {
        bytes32 slot = keccak256(abi.encodePacked(keccak256(abi.encode(key)), POOLS_SLOT));
        return uint160(uint256(IPoolStateReader(address(poolManager)).extsload(slot)));
    }

    /// @dev Both directions stay strictly inside a 1% price change: 0.995 for decreasing price,
    /// sqrt(1.01) rounded down to 18 decimals. Bounds are also clamped to v4's valid range.
    function _priceLimit(PoolKey memory key, bool zeroForOne) internal view returns (uint160) {
        uint256 spot = sqrtPriceOf(key);
        if (!(spot != 0)) revert PadErrors.PadPoolUninitialized();
        uint256 limit;
        // spot is uint160, so either product fits in 221 bits.
        unchecked {
            limit = zeroForOne ? spot - spot * IMPACT_BPS / 10_000 : spot * 1004987562112089027 / 1e18;
        }
        if (limit <= MIN_SQRT_PRICE_LIMIT) limit = MIN_SQRT_PRICE_LIMIT + 1;
        if (limit >= MAX_SQRT_PRICE_LIMIT) limit = MAX_SQRT_PRICE_LIMIT - 1;
        return uint160(limit);
    }

    /// @notice Pays a parked king payment to its owner. Uses its own lock, not the pool `guard`: the
    /// claimer receives all remaining gas, and holding the pool lock while untrusted code runs would
    /// let a claimer bid for the crown while `distribute` is unreachable (revision finding e2ea0e40).
    function claim() external {
        if (!(!claimLocked)) revert PadErrors.PadReentrancy();
        claimLocked = true;
        uint256 amount = claimable[msg.sender];
        if (!(amount != 0)) revert PadErrors.PadNothing();
        claimable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!(ok)) revert PadErrors.PadClaimFailed();
        emit Claimed(msg.sender, amount);
        claimLocked = false;
    }

    // ---- v4 callback -----------------------------------------------------------------------------
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        _onlyManager();
        uint8 action = abi.decode(data, (uint8));
        if (action == ACT_ADD) {
            (, PoolKey memory key, uint256 l, uint256 maxEth, uint256 maxTok) =
                abi.decode(data, (uint8, PoolKey, uint256, uint256, uint256));
            (int256 delta,) =
                poolManager.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, int256(l), 0), "");
            (int128 a0, int128 a1) = _split(delta);
            if (!(a0 <= 0 && a1 <= 0)) revert PadErrors.PadDeltaSign();
            uint256 owe0 = uint256(uint128(-a0));
            uint256 owe1 = uint256(uint128(-a1));
            if (!(owe0 <= maxEth && owe1 <= maxTok)) revert PadErrors.PadOwesTooMuch();
            // Put IMD rounding remainder into this position's fee growth. It is collected
            // in kind for its reign, even when genesis uses the native fallback; no IMD dust
            // is stranded in an unusable burn route. Coin excess still goes to dEaD.
            if (key.currency0 == imd && maxEth > owe0) {
                poolManager.donate(key, maxEth - owe0, 0, "");
                owe0 = maxEth;
            } else if (key.currency1 == imd && maxTok > owe1) {
                poolManager.donate(key, 0, maxTok - owe1, "");
                owe1 = maxTok;
            }
            _settleCurrency(key.currency0, owe0);
            _settleCurrency(key.currency1, owe1);
            return abi.encode(owe0, owe1);
        }
        if (action == ACT_COLLECT) {
            (, PoolKey memory key) = abi.decode(data, (uint8, PoolKey));
            (, int256 fees) = poolManager.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 0, 0), "");
            (int128 f0, int128 f1) = _split(fees);
            uint256 e = f0 > 0 ? uint256(uint128(f0)) : 0;
            uint256 t = f1 > 0 ? uint256(uint128(f1)) : 0;
            if (e != 0) poolManager.take(key.currency0, address(this), e);
            if (t != 0) poolManager.take(key.currency1, address(this), t);
            return abi.encode(e, t);
        }
        if (action == ACT_CONVERT) {
            (, PoolKey memory key, uint256 amount, uint160 limit) = abi.decode(data, (uint8, PoolKey, uint256, uint160));
            (uint256 spent, uint256 out) = _swap(key, true, amount, limit);
            if (!(spent == 0 || out != 0)) revert PadErrors.PadZeroOutput();
            _settleEth(spent);
            if (out != 0) poolManager.take(imd, address(this), out);
            return abi.encode(spent, out);
        }
        if (action == ACT_BURN) {
            (, PoolKey memory key, uint256 amount) = abi.decode(data, (uint8, PoolKey, uint256));
            if (key.currency0 == address(0)) {
                // The explicitly required zero-conversion genesis fallback has a native pool.
                (uint256 nativeSpent, uint256 nativeOut) = _swap(key, true, amount, _priceLimit(key, true));
                _settleEth(nativeSpent);
                if (nativeOut != 0) poolManager.take(key.currency1, DEAD, nativeOut);
                return abi.encode(nativeSpent, nativeOut);
            }
            uint256 spent;
            uint256 bought;
            if (amount != 0) (spent, bought) = _swap(imdEthKey(), true, amount, _priceLimit(imdEthKey(), true));
            bool zeroForOne = key.currency0 == imd;
            uint256 available = bought + burnIMD;
            uint256 used;
            uint256 out;
            if (available != 0) (used, out) = _swap(key, zeroForOne, available, _priceLimit(key, zeroForOne));
            if (!(spent == 0 || bought != 0)) revert PadErrors.PadZeroOutput();
            // Net the intermediate IMD delta within this single unlock; only bucket-owned IMD
            // can be settled. Unused intermediate coins stay separately accounted for next time.
            if (used > bought) _settleToken(imd, used - bought);
            else if (bought > used) poolManager.take(imd, address(this), bought - used);
            burnIMD = available - used;
            _settleEth(spent);
            if (out != 0) poolManager.take(zeroForOne ? key.currency1 : key.currency0, DEAD, out);
            return abi.encode(spent, out);
        }
        revert PadErrors.PadBadAction();
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amount, uint160 limit)
        internal
        returns (uint256 spent, uint256 out)
    {
        if (!(amount <= uint256(type(int256).max))) revert PadErrors.PadAmount();
        int256 d = poolManager.swap(key, SwapParams(zeroForOne, -int256(amount), limit), "");
        (int128 a0, int128 a1) = _split(d);
        int128 input = zeroForOne ? a0 : a1;
        int128 output = zeroForOne ? a1 : a0;
        if (!(input <= 0 && output >= 0)) revert PadErrors.PadSwapSign();
        spent = uint256(uint128(-input));
        out = uint256(uint128(output));
        if (!(spent <= amount)) revert PadErrors.PadOverspent();
    }

    function _settleCurrency(address currency, uint256 amount) internal {
        if (currency == address(0)) _settleEth(amount);
        else _settleToken(currency, amount);
    }

    function _settleEth(uint256 amount) internal {
        if (amount == 0) return;
        // v4 sync is permissionless and transient across unlocks in the same transaction.
        // Explicitly select native ETH so a preceding token sync cannot poison settlement.
        poolManager.sync(address(0));
        poolManager.settle{value: amount}();
    }

    function _settleToken(address token, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(token);
        if (!(_transfer(token, address(poolManager), amount))) revert PadErrors.PadToken();
        poolManager.settle();
    }

    /// @dev Accepts both `true` and an empty return, so an IMD without a bool return still settles.
    function _transfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        return ok && (r.length == 0 || abi.decode(r, (bool)));
    }

    function _split(int256 delta) internal pure returns (int128 a0, int128 a1) {
        assembly ("memory-safe") {
            a0 := sar(128, delta)
            a1 := signextend(15, delta)
        }
    }

    // ---- views -----------------------------------------------------------------------------------
    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function getPool(uint256 idx) external view returns (Pool memory) {
        return pools[idx];
    }

    function currentKing() external view returns (address) {
        return king == address(0) ? address(0) : _king();
    }
}
