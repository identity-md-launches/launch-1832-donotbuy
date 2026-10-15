# PvP Pad v4: audit fixes and trust model

This is the builder's own review, not an independent audit. Work holding other people's funds
needs an independent audit before public launch. The original reviews are retained in
`AUDIT-V2-HISTORY.md` and `AUDIT-V3-HISTORY.md`. All v3 fixes below remain implemented; this
review adds bail-outs, conversion, IMD pools and two-hop burns.

Base: `identity-md-launches/launch-1764-pvp-pad-v3-robinhood` at
`c3a2fac8312fac1dabbd8deca78a987e180523c8`. The inherited v3 work addressed the v2 external report:
[IdentityMD job 5c4ec689](https://api.imd.fun/jobs/5c4ec689-085b-4d72-8807-668b284d3222/report.md).
The source was imported as ordinary files, including all offline dependencies. No deployment,
broadcast, RPC, fork, wallet, environment-reading test, or outside constructor call was used.

## Privileges

| Who | Power | Notes |
|-----|-------|-------|
| Owner / dev (both `$owner`, the launch owner `0x5b95…0d06`) | `openPad(salt)` before day 30; receives 25% of king extras | Cannot pause, upgrade, sweep, mint or change fees. After 30 days anyone can open. |
| Anyone | enter, draw, resolvePending, roll, bailOut, prepareConversion, convertChunk, poke, finalize, graduate, launch (after PvP), restartGenesis, takeCrown, distribute, retryPool, burnChunk, fundCarry, claim | Funded donations and pool recovery are permissionless. Lifecycle work is bounded. |
| PvPPad (contract) | only caller of `PadGame.fundPot` | King share during play; unused carry allowance at finalization. Anyone can donate via `PvPPad.fundCarry`. |
| Factory / IMD | none | No `msg.sender` / `tx.origin` ownership anywhere. |
| PadLiquidity | Only sender allowed by `PadHook.beforeInitialize`; may unlock tokens; owns all LP forever | No withdrawal path for LP exists. |

## External audit mapping

| External finding | v3 fix | Main regression evidence |
|---|---|---|
| 1, High: crown inside v4 unlock | `takeCrown` and both distribution paths read `Lock.IS_UNLOCKED_SLOT` through `exttload`. Every failure in an unflagged pre-crown pool aborts the bid. EIP-150-aware gas precondition precedes settlement. | `AuditV3KingTest.test_unlockCallbackCannotTakeCrownOrDistribute`, `test_firstCrownAlsoRejectsUnlockedManager`, `test_gasStarvedBidRevertsWithoutChangingCrownOrPoolHealth`; real v4 callbacks |
| 3, Medium: outgoing king loses token fees | All collected tokens transfer to the king captured before collection; ETH uses a 30k push and claimable fallback. No fee-sale swap, `SELL_CHUNK`, stash or king escrow. No collection before first crown. The pre-crown walk covers every pool the bid's gas fits (at least 16, else the bid reverts); pools it does not reach stay owed to the outgoing king through the reign stamp (#29). | `test_outgoingKingGetsLargeTokenFeesInKindAndNextKingGetsNoStash`, `test_sixteenPoolsBothCurrenciesAndGasEatingKingFitSettlementBudget`; real trading and 18-pool tests in `LiquidityV4.t.sol`; `CrownSettlementTest` (18, 40 and 60 real pools) |
| 2, Medium: 60-second rollers expire at 10 blocks/s | 90/7/2/1 split, 1% reserved per roll and credited to the resolver, including the caller forwarded through upkeep. Expired tip goes to the roll pot and the height penalty remains. At most 16 records examined per call, with a gas floor. | `AuditV3GameTest.test_tenBlocksPerSecondSixtySecondRollerNeverExpiresWithResolver`, `test_nonGenesisSplitAndExpiredTipGoesToPotWithPenalty`, `test_resolveBatchClampsToSixteenAndLowGasStopsSafely` |
| 4, Low: sole caller repeatedly re-rolls seed | First commit never changes. At commit+258 or later, uncaptured seed is `keccak256(abi.encode(game, commitBlock, entryCount))`. First entry fee pays one seed-capture bounty; all other entry fees burn. | `RaffleTest.test_lapsedCommitFallsBackOnceAndNeverRecommits`; direct, rejecting-recipient and upkeep bounty tests in `AuditV3GameTest` |
| 5, Low: upkeep starves entry/roll | Explicit caps on each game step, distribution and burn; each checks cap + EIP-150 margin + caller reserve before starting. | `AuditV3CarryUpkeepTest.test_ownGasEstimateEntryAndRollWithForeignDraw`, `...Finalize`, `...Graduate`, `test_upkeepSubcallCanExhaustItsFullStipendWithoutRevertingEntry` |
| 6, Low: five-wallet carry chain | Draw never takes carry. A finalized game counts living Imps and pulls at most `fundedReleaseCap() - fundedPot` if positive and living >=5. King funding consumes the cap first. | `test_fiveWalletCarryChainOnlyPullsUnusedCapAtFinalize` repeats three linked games; `test_fiveWalletNoRollChainNeverTakesCarry`; original release-cap/economics tests retained |
| 7, Info: permissionless carry donations | Explicitly documented here, in NatSpec, and README; donation permission retained. | Carry-chain tests donate from a non-owner; game-only pull/fundPot tests retained |
| 8, Info: live manager differs from vendored core | No new claim about deployed code. Real-core tests remain offline. Independent target-chain manager checks and a graduation rehearsal are the deployer's pre-opening responsibility. | `AtomicDeploymentTest`, `LiquidityV4Test`, `tools/validate_manifest.py`; no RPC performed |

## Findings and accepted risks

1. **On-chain randomness and resolvers.** Dice retain the three future ArbSys L2 hashes. This is
   not VRF randomness: sequencers can influence/censor blocks. Wall-clock cooldown remains 60s.
   At ~10 L2 blocks/s the oldest hash expires in ~25.8s; unrelated paid actions alone do not
   guarantee resolution. Anyone can resolve from commit+4 through commit+257 and earn 0.00002 ETH
   per roll as a claimable. A missed window sends the tip to the pot and moves height up to four
   toward zero. No keeper is exclusive and payment does not guarantee service. Operate redundant
   resolvers well inside the window. Direct and pad-mediated resolution preserve the beneficiary.
   Scan count is capped at 16, including previously resolved entries; a 200k gas floor stops the
   loop before another record. Own-previous-roll resolution remains available.
2. **Finalization gas.** The inherited packed-key heap sort remains O(n log n), followed by at
   most 100 gas-capped payments. The 200-living regression remains and gas is in TEST-REPORT.md.
   A game upkeep call gets 4.5M gas only when the pad can also retain an EIP-150 margin and 100k
   reserve. Unusually expensive finalization can still fail within the cap and be called directly.
   Unlike v2, an inner OOG cannot consume the user's remaining gas.
3. **Upkeep isolation.** Each of two game steps has a 4.5M cap, distribute(2) has 750k,
   and burnChunk has 350k. Every call is conditional on its whole stipend plus cap/63 and a 100k
   reserve. A pad call with less than 150k immediately returns. Failures are caught and mandatory
   work is available directly. Entries and rolls with only their own gas budget skip other games.
   Tests estimate gas locally with snapshot/replay (no RPC) and exercise a subcall burning its
   entire stipend. Upkeep is best effort, so keepers must monitor unfinished lifecycle work.
4. **Genesis failure remains recoverable, with paid griefing.** A failed genesis requires its
   draw to finish and **zero net curve ETH** at the end: no roll before all Imps die, or every
   roll's coins sold back by bail-outs (a sole roller's full bail-out returns exactly its curve
   cost, so `ethRaised` returns to 0; revision finding a5b159e5). `restartGenesis` and `launch`
   recover it. Such a griefer still pays its entry, the non-curve 10% of each roll and gas; the
   other entrants' entries stay in the burn bucket and a restarted genesis costs them a new entry.
   The first entry's 0.001 ETH is now the draw bounty, so a sole entrant who captures its own seed
   can recover that fee (gas remains spent); subsequent entries still burn. This weakens the v2
   solo-entry grief cost intentionally under Fix 4. The uncapped entry list prevents speed-based
   exclusion, and a seated honest roller prevents a no-roll genesis failure. Three failed rounds
   and a successful replacement remain tested.
5. **Liquidity rounding.** `PadLiquidity` computes full-range liquidity with its own mulDiv and takes
   a 1 ppm haircut so the real PoolManager (which rounds amounts up) never asks for more ETH than
   sent. Any native fallback ETH dust goes to the burn bucket; launch-coin excess goes to dEaD.
   IMD rounding remainder is donated to the same LP as fee growth inside the graduation unlock,
   then collected in kind for its reign. It is never stranded when genesis uses the native fallback.
6. **Real v4 exercised offline.** All PoolManager-dependent tests now compile and deploy unmodified
   Uniswap v4-core v4.0.0 (`e50237c43811bd9b526eff40f26772152a42daba`); the old behavioral mock is
   removed. Tests use actual liquidity, swap, donation, fee-growth, delta settlement and storage
   layout logic, including sold-out graduation after 2,400 actual rolls and a one-roll small raise.
   Hook salt is mined locally, foreign initialization goes through the real manager (which wraps
   hook errors), and `extsload` is checked against upstream StateLibrary. A test router only pays
   deltas and takes proceeds. MockArbSys remains intentional. This does not verify the implementation
   deployed at the inherited chain address, nor sequencer behavior; no RPC/fork was used.
7. **Hook address.** `openPad` reverts unless `address & 0x3FFF == 0x2000`. The v4 PoolManager
   validates the same mask at `initialize`. Only PadLiquidity can initialize pools with the hook.
8. **Price-impact cap on burn buys.** The inherited 0.02 ETH/10min burn has a 0.5% sqrt-price
   limit from spot, about 1% in price. Unfilled ETH stays in the burn bucket. Native currency is
   explicitly selected before settlement. Fee-token sales have been removed entirely. The real
   manager thin-pool partial-fill and self-sandwich regressions remain; the tested round trip loses
   money but is not a proof against all MEV or external venues. Spot-relative limits do not detect
   manipulation, and thin genesis liquidity slows burns.
9. **King accounting.** The king contract never holds a settled bid: the whole first bid is split,
   and each later bid refunds the previous king and splits the extra. The balance therefore equals
   the sum of claimables. Tested.
10. **Token lock bypass.** While locked, only `msg.sender == game || liquidity` may move tokens.
    Approvals do not bypass the lock (tested). The lock is per-token and only PadLiquidity can
    unlock it.
11. **Reentrancy and obligations.** Entry, draw, roll, resolution, finalization and claims use
    guards; callbacks into a busy game return during upkeep. Effects precede payouts. ETH pushes
    use 30k gas and a failed push becomes claimable; do not assume a stipend alone prevents all
    reentry. PadLiquidity claims retain their separate lock from pool operations (#21). A game's
    ETH backs curve funds until preparation, pot, pending tips, draw bounty, and claimables. Prepared
    curve ETH is separately backed by PadLiquidity conversion escrow until swapped or graduated.
    Timely tips remain claimable even after finalization/graduation. Invariants account for all of
    these liabilities; failures cannot pay a bounty or tip twice.
12. **Timestamps.** Minutes/hours/days use `block.timestamp` (sequencer-controlled within protocol
    bounds). Block numbers from ArbSys are used only for the RNG window. The brief's "timing uses
    ArbSys" was read as the RNG commit window, because L2 block cadence is not a reliable clock.

13. **Funded release with bail-outs and IMD conversion.** `fundedPot` is segregated from roll
    income and bail-out taxes. At finalization at least five **non-erased living** seats are required.
    The release is at most `min(3 * rollPot, 0.15 * e)`, where e is **net** curve ETH after every
    bail-out sell, not gross roll purchases. `bailPot` contributes to prizes but neither to rollPot,
    the king's game weights, nor the roll-income ceiling on the finalizer fee. Unreleased funding
    returns to carry; carry is pulled only for the unused allowance at finalization. There is no setter.

    Re-derivation (ETH and e normalized by the 1 ETH virtual reserve): let S be all curve purchases,
    V the sum of bail-out sell values and H their total withheld amounts. Net e = S − V, and total
    bail-out payouts are V − H. Even crediting a single sybil with **every** pot prize, resolver tip,
    finalizer fee and every bail tax H, its curve outlay is still e. Erasing wallets cannot reduce
    that net outlay while leaving the gross S in the funded cap. No erased wallet can itself collect
    pot, rank or ring a bell. With the fixed invariant, outstanding player coins are approximately
    `T = VTOK * e/(1+e)`, with rounding against buyers/sellers. Sell-out still bounds e by 4.

    For the native fallback, LP coins are `L = VTOK * e/(1+e)^2`. Even ignoring the coin pool fee
    entirely (conservative also when the sybil is king and recollects its own fees), dumping all T
    returns at most `e*(1+e)/(2+e)` ETH. At least `e/(2+e) >= e/6` remains in permanent LP, greater
    than the `0.15*e` funded rebate. Bail-outs merely move the calculation to a smaller net e.

    For full conversion, let the existing IMD/ETH venue have constant-product reserves A ETH and B
    IMD before the game conversions. Ignoring both venue fees gives the attacker a generous upper
    bound: conversion obtains `I = B*e/(A+e)`. The coin/IMD dump recovers at most the fraction
    `alpha = (1+e)/(2+e)` of I. Selling that IMD back to the same venue recovers at most
    `e*alpha*(A+e)/(A+alpha*e)` ETH. Thus the irrecoverable curve outlay is at least
    `e*A / (A*(2+e) + e*(1+e))`. At the supplied A = 68 ETH and e <= 4, it is at least
    `68e/428`, approximately **15.88785% of e**, above the 15% funded rebate. At sell-out the
    remaining margin is about **0.0355 ETH**, before charging any entry costs, burn, pool fees or gas.
    Real fees make the tested attack less profitable. This proof also credits coin LP fees back to
    the sybil; the old fee-dependent 0.99 bound was unnecessarily optimistic about fee leakage.

    The fair `I = B*e/(A+e)` assumes nobody holds the venue away from its price across the chunks.
    Since revision f2032eaa, a chunk never sells below the game's anchor (spot recorded at
    finalization, raised by any better spot seen at a chunk, decaying 0.5% sqrt / ~1% price per
    hour) minus 1% sqrt (~2% price). A position held across all chunks therefore cannot make the
    game buy more than ~2% (plus elapsed decay) below the finalize-time price, and the sybil, who
    would be the one moving the venue, gains at most that same fraction of I while paying both
    venue fees on its position. The 15.89% bound above becomes at least ~13.9% of e only if the
    sybil also holds the venue 2% away for the whole conversion with no arbitrage, against the
    funded rebate of 15% minus its own two 1% venue fees on a position worth at least 2% of A;
    `test_soleBuyerSybilWithProfitableBailAndFiveSurvivorsStillLosesAfterTwoHopDump` remains green.

    With a partial conversion E <= e, LP coins are `E/P`, where `P = (1+e)^2/VTOK`, and the coin
    dump fraction is at most `e*(1+e)/(E+e*(1+e))`. Apply that fraction to the IMD obtained with E;
    the unconverted `e−E` goes to carry, not the attacker. The ETH recovery upper bound increases
    with E, so the full-conversion case above is the worst case. A later attempt to harvest that
    carry must incur another game's capped net curve outlay. If e is zero, the funded allowance
    is zero; all-bailed games fail instead of creating an empty LP.

    **Scope of this economic argument:** it is a sole-buyer, closed-venue calculation with no
    favorable external price movement, no outside buyers and the specified approximately 68 ETH
    depth, modelled as full-range constant-product liquidity in the real-core test. The sufficient
    depth bound in this zero-fee worst case is A > 30 ETH. It is not a guarantee after major LP
    withdrawals, concentrated-liquidity changes, external price appreciation or third-party flow.
    The contracts enforce per-chunk impact, not an oracle price or minimum future depth; an
    independent audit must evaluate live liquidity before opening. Finite-range rounding and the
    1 ppm LP haircut are much smaller than the stated margin in the tested domain.

    `V4PadTest.test_soleBuyerSybilWithProfitableBailAndFiveSurvivorsStillLosesAfterTwoHopDump`
    plays six wallets, erases one at a profit, retains five living survivors, takes funded carry,
    converts on the real IMD/ETH venue and dumps every remaining coin through both pools. Net
    curve ETH is about 0.433763; loss is about **0.116819 ETH**, excluding entries and gas and
    crediting the attacker with the finalizer payment. The original v3 sole-buyer and carry-chain
    regressions still execute on the required native fallback. Fuzzed bail sequences independently
    reconcile token supply, net curve ETH, payouts, pot, tips and claims.

14. **Upkeep callers and fees.** `KingOfThePad.takeCrown` runs `pad.upkeepFor(msg.sender)`, so a
    finalizer fee paid by that upkeep goes to the bidder, not to the king contract (which cannot
    claim). `upkeepFor` accepts games and the king contract only. Revision finding f7386928.
15. **Roll after the bell.** `roll()` resolves the Imp's previous roll first; if that resolution rings
    the bell the call now reverts `game over` instead of recording a roll after the end.
16. **Dead Imps and the bell.** A roll resolved after its Imp has died (quiet chain, no L2 blocks)
    still moves the height but cannot ring the bell or earn the 20% share.
17. **Tie-break.** `heightReachedAt` is the commit L2 block of the roll that reached the height, with
    the roll index as a second key, so ties follow commit order, not who resolved first.
18. **Receive guard.** `PadLiquidity.receive()` accepts ETH only from the PoolManager; all other ETH
    enters through `fundBurn` or `graduate` and is credited to a bucket.
19. **One-shot binders.** `bindLiquidity`, `startGenesis` and `bindKing` accept the first caller.
    They are safe only because the launch deploys the five contracts in one transaction from the
    factory; a rehearsal in separate transactions must not leave a window between them. Trust
    assumption of the deployment policy, documented, not changed.
20. **upkeepStep lock.** `upkeepStep` now sets the game's reentrancy lock while it finalizes or
    graduates, so the protection no longer rests on the 30k push gas cap alone.
21. **Outgoing king fees and pool liveness.** `takeCrown` rejects an unlocked manager, using
    the exact transient slot from vendored `Lock.sol`, and requires 5M + 5M/63 + 600k gas before
    calling `settleCrown` with every unit of gas above the 600k reserve. The strict path is
    king-only and walks every pool from the cursor while gas fits another collection, at least
    min(16, poolCount) of them, before updating king (#29). Each self-call gets 300k. Any unflagged
    collection failure, distributor error, guard failure or OOG reverts the entire bid and its
    partial settlements.
    Ordinary `distribute` is permissionless and records failures without reverting successful
    pools. It checks the whole stipend plus 100k before each attempt, so gas starvation cannot
    manufacture a failure. Three failures in distinct ArbSys L2 blocks mark a pool broken; repeat
    attempts in one block count once. Both normal and strict batches skip broken pools.
    `retryPool(index)` is permissionless and can recover a broken pool; success resets the count.
    A failed bid cannot persist diagnosis, so operators use distribute/retryPool across blocks.
    All fee tokens transfer in kind. ETH is pushed or owed to the captured king; no token stash or
    sale proceeds survive settlement. Before the first crown, fees remain in positions.
    The previous claim-reentry fix is retained: claims never hold the pool guard, and the original
    adversarial callback test still pays the outgoing king. Both currencies, 16 pools and a king
    exhausting every ETH push are measured in the new real-manager regression.
    Limits: pools the walk does not reach and explicitly broken pools are paid later, to the king
    of the reign they are stamped with (#29), not to the next king. A broken pool may remain
    broken indefinitely; monitor PoolHealth and retry. This is the requested liveness exception,
    not a guarantee that every historical fee is paid promptly.
22. **Paid Sybil entry remains possible; speed no longer buys seats.** No EOA checks, one entry per
    wallet, no cap on wallets. Every entry costs 0.001 ETH, including unselected wallets. For H honest
    and B bot entries, let N=H+B and S=min(N,200). Bot seats follow Hypergeometric(N,B,S), with mean
    S*B/N, assuming unbiased future hashes. A bot pays 0.001*B ETH plus transaction/helper-wallet gas.
    Examples with H=200 honest entrants:

    | Bot entries | Entry cost | Expected bot seats (of 200) | Expected share |
    |---:|---:|---:|---:|
    | 200 | 0.200 ETH | 100 | 50% |
    | 201 | 0.201 ETH | 100.249 | >50% in expectation only |
    | 800 | 0.800 ETH | 160 | 80% |
    | 1,800 | 1.800 ETH | 180 | 90% |
    | 3,800 | 3.800 ETH | 190 | 95% |
    | 4,800 | 4.800 ETH | 192 | 96% (5,000 total entries) |

    With H=200, B=240 costs **0.240 ETH plus gas** and gives about **95.073%** probability of
    at least 101 seats. This is computed as
    `sum(comb(B,k)*comb(H,200-k), k=101..200) / comb(H+B,200)`; B=239 is below 95%.
    It assumes exactly 200 honest entries and unbiased hashes, not additional honest demand.
    Expected majority is not a guaranteed majority. If total entries are <=200 everyone gets a
    seat, but randomized seat order removes entry-order preference in the last ranking tie-break.
    When H is small, domination is correspondingly cheap: with no honest entrants 101 bot wallets
    buy all 101 seats for 0.101 ETH. No claim of one human per seat or Sybil resistance is made.
    These fees supplement, rather than replace, the base funded-pot safeguards (#13).
23. **Binding draw seed and bounty.** The first post-signup call commits once. Through
    current=commit+257, the seed uses the next three L2 hashes; from commit+258 an uncaptured seed
    is `keccak256(abi.encode(game, commitBlock, entryCount))`. No recommit exists. The first entry
    fee is held separately from pot and curve; whoever captures either seed gets it once via
    capped push/claimable fallback, including the actual upkeep caller. Seed and bounty state
    settle before the external payment. Sparse Fisher-Yates, rejection sampling, 32-trial chunks,
    200-seat cap, chunk-independent ordering, and fresh play/death clocks are retained.
    A delayed partial draw always resumes the same seed. The fallback prevents unbounded
    best-of-k fresh seeds; it is predictable. A sole keeper can still choose timely capture versus
    the one known fallback, and a sequencer can influence the commit block/hashes. These are
    disclosed limits of the requested mechanism, not VRF-level fairness. Timely independent
    seed capture remains desirable; payout incentives do not guarantee availability.
24. **Native settlement selected explicitly.** Real v4 allows anyone to `sync(token)` while locked;
    the synced currency is transient transaction state, not scoped to an unlock caller. The base's
    ETH `settle{value: ...}` could revert when preceded by an unrelated token sync in the same
    transaction. `_settleEth` now always calls `sync(address(0))` first. Real-manager tests dirty
    this state before graduation and burn, and verify success and conservation.
25. **No token at deployment.** The base called `_create` in the last constructor and minted genesis,
    contradicting its own contracts-only/no-token description. The five constructors now only deploy
    templates and bind the application contracts. `openPad(salt)` creates the hook and genesis in
    one reversible transaction; failure rolls back the open switch. This satisfies the final
    decision while retaining deploy order, constructor args, ownership, genesis identity and the
    public day-30 opening fallback. No post-deploy configuration call is needed to complete the
    manifest deployment; opening is the existing intentional public-launch action.
26. **Carry and entered-game accounting.** Free launches never receive carry and never enter
    the king/upkeep window until their first paid entry. The inherited entered-list fix remains.
    A draw with five or 200 seats also receives no carry in v3. Only `_finalize`, after pending
    rolls resolve and living Imps are counted, requests `max(0, fundedReleaseCap()-fundedPot)` when
    at least five live. PvPPad transfers at most that request and its current carry balance.
    The immutable registered game alone can pull; funds are credited as funded, so king share
    consumes the same cap first. Excess existing funding still returns under v2 rules. No game
    custodies unused carry through play, and a finalization plus next-game draw in one transaction
    cannot move the remainder. Three linked five-wallet games and the original no-roll chain are
    tested. Anyone may donate to carry; timing a donation never enlarges a game's release cap.
27. **Template initializers.** `PadToken.initialize` and `PadGame.initialize` accept any first
    caller on a clone (the templates themselves are sealed in their constructors). Anyone can deploy
    their own EIP-1167 proxy to the templates and initialize a look-alike "PVP" token they fully hold
    (revision finding 879f037c). Protocol funds are unaffected: `PadLiquidity.graduate` accepts only
    `pad.gameOf(launchId)`, `upkeepFor` only `isGame`, `deployHook` only the pad. The templates
    deploy before the pad, so they cannot pin it; `PvPPad.tokenOf`, `gameOf` and `isGame` are the only
    source of truth for a site or an explorer (see `docs/VERIFY.md`).
28. **Event indexes.** `Entered` and `Seated` now carry the same 1-based entry and seat numbers as
    `entryOf`, `impOf` and `myEntry` (revision finding 9ce6a613). `SQRT_MIN_FULL` / `SQRT_MAX_FULL`
    now equal `TickMath.getSqrtPriceAtTick(±887200)` of the vendored v4-core and are asserted against
    it (finding 561f5bd6); the earlier off-by-one values were covered by the 1 ppm haircut.
29. **Reign-stamped fee entitlement (revision finding 8b022036, medium).** The previous strict
    batch clamped the pre-crown settlement to 16 indexes before looking at gas, and `takeCrown`'s
    trailing `upkeepFor` then ran `distribute(2)` for the new king, so with 17 or more pools the
    bidder received the fees of the pools the batch skipped inside its own bid, and could choose
    them by moving the public cursor with `distribute(1)` first. The reviewer's proof reproduced on
    the previous tree (bidder gained 0.1 ETH of the old reign's fees in the bid transaction). Fix,
    in `PadLiquidity`: (a) `settleCrown` sets `n = poolCount` and keeps collecting while
    `gasleft() >= 300k + 100k`, reverting `collection gas` only if fewer than min(16, poolCount)
    pools were visited, and `takeCrown` forwards everything above its 600k reserve instead of a
    fixed 5M, so a bid can settle more pools by sending more gas; (b) each settlement records the
    outgoing king in `reignKing[reign]` and increments `reign`; each pool carries `settledReign`,
    stamped at graduation and on every successful collection; a collection of a pool whose stamp is
    below `reign` pays `reignKing[stamp]`, the king of the earliest reign the pool was never settled
    for, and then stamps the current reign. Pools skipped for gas or because they were broken are
    therefore paid to the old king by whoever collects them next (including the bid's own trailing
    upkeep), and the bidder can neither starve the walk below 16 nor pick which pools fall outside
    it. Accepted imprecision: such a pool's fees earned after the crown change and before its next
    collection also go to the earlier king; the new king controls that by collecting promptly.
    Also, the first crown closes no reign, so fees accrued before any king go to the first king as
    before. Gas: the stamp is packed beside `liquidity`, so its update rewrites a non-zero slot; the
    minimum stipend settles about 40 real pools locally and 60 need about 7.6M. To keep the
    deployment under the 13M target, ten PadLiquidity constants that no contract or test reads
    became `internal` (values unchanged, listed in the README). Tests: `CrownSettlementTest`
    (the reviewer's cursor-steering scenario on 18 real pools, 60 pools with a minimum-gas bid and
    with a generous bid, the 16-pool floor revert, non-king settlement, first-crown reign, a broken
    pool skipped by two crowns paid to the earliest reign), and the updated 18-pool and
    broken-pool tests in `LiquidityV4Test` and `AuditV3KingTest`.
30. **Fallback seed and the commit block (revision finding 779d74d2, low, disputed).** The
    lapsed-window seed is `keccak256(abi.encode(game, commitBlock, entryCount))`, exactly the
    formula the brief prescribes for Fix 4. The reviewer notes that the first `draw()` caller
    chooses the commit block and can therefore pre-compute the fallback seating for candidate
    blocks, then let the hash window lapse. That is correct and already disclosed in #23 (the
    fallback is predictable; a sole keeper chooses between timely capture and the one known
    fallback). It is not changed here: the formula is the requested one; any replacement input
    available at commit time (an earlier block hash, the signup-end block) is equally observable
    or steerable by whoever sends the first post-signup call; the attack needs the attacker to be
    the first committer, 201 paid wallets, and a pad on which nobody else calls `draw`, `poke` or
    any upkeep for the whole 26-second window; and below 200 entries the seed only orders seats,
    the last tie-break key. Anyone, including the would-be victim, can commit first and capture the
    seed. Operators should run an independent seed-capture keeper (README, after launch).

31. **Bail-out erasure and pending rolls.** `bailOut(minOut)` requires an actual seat and active
    play, but allows a croaked seat while another keeps the game alive. Coins return through a
    game-only locked-token `reclaim`; no allowance or arbitrary-player input is exposed to callers.
    Effects precede the capped payout, with rejected ETH claimable. A pending roll still resolves
    once and consumes its original tip, but applies delta zero and cannot ring a bell. Expired
    erased rolls retain the v3 tip-to-pot rule. Erased owners are excluded from rank keys, living
    counts, king eligibility and activity clocks. No storage deletion can orphan pending rolls.
    Full sell-out can be followed by a sale and another buy; C records only actually used curve ETH.
32. **Conversion escrow, timing and isolation.** Only a registered game can start its escrow,
    transferring net curve ETH after finalization. Public `convertChunk(game)` prepares it if
    necessary. Every game has independent remaining ETH, converted ETH, IMD received, attempt and
    progress timestamps. IMD balances are credited only from successful PoolManager deltas; direct
    donations are ignored. The whole swap is inside a gas-capped self-call, so a revert, malformed
    result, zero output for positive input, or exhausted stipend rolls back all deltas. Failed/zero
    progress attempts never extend the deadline. A gas floor prevents deliberate underfunding,
    `lastAttempt` is written only after the venue unlock returned, and a caller inside a
    PoolManager unlock is rejected with `PadManagerUnlocked` (revision d74f26e2), so failed or
    out-of-band attempts never consume the 30-second interval. Upkeep retains its v3 outer game cap and
    uses 500k for conversion, with a 350k isolated venue call; direct calls remain available.
33. **Graduation and timeout.** Normal conversion spends at most to sqrt factor 0.995 from spot,
    strictly less than 1% price movement, once per 30 seconds per game, and never below the anchor
    band (see 37). Graduation cannot bypass unfinished conversion until 24 hours since the escrow
    was created or the last stamp of real progress (at least 0.1% of the escrow converted since the
    previous stamp), or 7 days after the escrow at most.
    Partial success seeds the IMD pool and carries the rest of ETH; no IMD success seeds the native
    v3 pool. Both paths unlock atomically only after actual LP settlement, burn excess launch coins,
    and preserve permanent full-range LP ownership. An overflow-safe sqrt-ratio encoding supports
    either currency order and raw-token ratios above 2^64. No fee-on-transfer/rebasing IMD support
    is claimed: the supplied asset is required to be a plain ERC20.
34. **Two-hop burn and assets in kind.** The ETH budget remains 0.02 per ten minutes. ETH/IMD and
    IMD/PVP swaps share one unlock; intermediate deltas are netted and any unused intermediate IMD
    stays in its own `burnIMD` bucket. It cannot borrow conversion IMD or king fees. The second hop
    handles either sorted currency order. Each hop has a fresh spot-relative limit: decreasing
    sqrt factor 0.995; increasing factor 1.004987562112089027 (rounded inside 1%). The native-genesis
    fallback necessarily retains the v3 one-hop native buy. IMD fees are ordinary ERC20 transfers,
    never sold; native fees retain push/claim fallback. Reign stamps, broken-pool recovery and
    pre-crown settlement apply to both quote currencies, unchanged. The sandwich regression uses
    real front-run / chunk / back-run swaps and varies front-run capital; it is not a universal
    MEV guarantee or an absolute-price oracle.
35. **Deployment-size changes.** All application constructors still call only earlier manifest
    contracts. No deployment token, hook, game, pool or distributor is created. Static IMD and
    PoolId args add no external constructor call. Named custom errors replace revert strings
    without changing rejection conditions, and optimizer runs are 1. Arithmetic proven bounded by
    the fixed curve reserves or the 200-seat heap-sort inputs uses unchecked blocks; public inputs
    retain their bounds and all 200-seat ranking regressions remain. Manager, pad and IMD addresses in
    PadLiquidity have no setters and are written only in its constructor. `PoolHealth` emission is
    shared to avoid an optimizer-generated data constant being misread as an escape opcode by the
    protected linear scan. Gas is measured inside the atomic CREATE2 probe, including code deposits;
    measuring `gasleft()` only around a top-level test call under Foundry 1.8 can omit that cost.
36. **Manifest venue encoding.** The launch validator treats every zero-valued address argument
    as an unset party, including the native currency and no-hook fields of a full PoolKey tuple.
    PadLiquidity therefore accepts the supplied canonical PoolId as a `bytes32` constructor
    argument. It reconstructs the exact fixed native/IMD/10000/100/no-hooks key from the IMD
    address and requires `keccak256(abi.encode(key)) == imdEthPoolId` before the pad binding call.
    The protocol's native currency stays zero internally; no replacement token or guessed
    recipient is introduced. The manifest contains four nonzero static arguments for liquidity.
    Regression tests reject IDs for changed currencies, fee, tick spacing or hooks, a zero ID,
    and an IMD/key mismatch. Atomic deployment tests use the literal supplied ID and assert the
    reconstructed key matches it without external code. Runtime pool behavior is unchanged.

37. **Revision: conversion anchor, stall clock and dust (findings f2032eaa, d74f26e2, 0183622a,
    ff0950e5, 1c54845c).**
    - *Held front-run / dominant LP.* The 1% band was relative to a spot the caller can set. Each
      chunk's limit is `max(0.995 * spot, 0.99 * anchor)` in sqrt price; if spot is already below it
      the chunk is skipped (`ConversionStalled`, no interval used). The anchor is pad-wide
      (`PadLiquidity.anchor()`): the best IMD/ETH spot observed at any pad touch, decaying linearly
      by 0.5% sqrt per hour so a genuine market move is followed within hours. `observeMarket()`
      runs in `PvPPad._upkeep` (every roll, entry, poke, launch and king action), in `_finalize`
      (gas-capped; a dead venue does not block finalization), in every chunk, and may be called by
      anyone. Only a higher spot moves it, and a spot read while the PoolManager is unlocked is not
      recorded. Tested: `test_heldFrontRunAcrossAllChunksIsRefusedAndLoses`,
      `test_anchorBandBoundsCumulativeWalkAndDecaysForAGenuineMove`,
      `test_observationOnlyRaisesTheAnchorAndEveryTouchRefreshesIt`, the sandwich fuzz.
    - *Self-finalizing front-run (finding 15d57b2a).* The first revision anchored at `finalize`
      only. `finalize()` is permissionless and callable at a computable time, so an attacker bundled
      a 10 ETH ETH -> IMD swap with its own `finalize()`, anchored the pushed spot, drove the chunks
      and sold back. The reviewer measured the game receiving 24.5% less IMD and the attacker
      netting ~0.002 ETH on a 0.8 ETH escrow; reproduced here before the fix on the real
      PoolManager with a 0.432 ETH escrow: anchor equal to the pushed spot and 15% less IMD for
      the game (the attacker's own result was a small loss at that size). Now the anchor the
      finalization inherits was set by every touch of the whole game (a roll every minute in the
      reproduction), so the bundled push is ignored and every chunk is refused until the attacker
      unwinds; the position would have to be held since before the game's last touch, against
      arbitrage, to lower the anchor. `_finalize` no longer observes itself: every path to it
      (`finalize`, `poke`, `upkeepStep`) runs the pad upkeep that does. Tested:
      `test_frontRunBundledWithFinalizeCannotLowerTheAnchorAndLoses` (12 wallets roll to the hard
      end, >0.75 ETH escrow, 10 ETH push bundled with finalize: anchor unchanged, zero chunks fill,
      attacker ends below 10 ETH, conversion later completes within 3% of the fair price).
      Residual risk, stated as a bound: the anchor decays 0.5% sqrt per hour from the last touch,
      so a game whose pad stays untouched for T hours before someone finalizes it lets a
      self-finalizing front-runner move the effective anchor down by 0.5% * T in sqrt price (about
      1% * T in price) plus the 2% band; prompt finalization (the finalizer fee), any other game's
      activity and a public `observeMarket()` call all close that window. The same decay means a
      genuine IMD/ETH drop larger than the elapsed decay during play stalls the game's conversion
      until the decay catches up, and a drop of more than ~24% in price within a day sends the game
      to the 24-hour fallback (partial IMD or the v3 native pool); this is preferred to converting
      into a manipulated price. Raising the anchor costs the griefer both venue fees and sells the
      game IMD cheaply; it delays chunks only by the decay time.
    - *Nested unlock.* See 32. Tested: `test_nestedUnlockCallerIsRejectedAndHonestChunkConverts`,
      `test_failedVenueAttemptDoesNotConsumeInterval`.
    - *Dust progress.* A fill refreshes `lastProgress` only when the ETH converted since the last
      stamp reaches 1/1000 of the escrow, or completes it; `CONVERT_MAX_DURATION = 7 days` from the
      escrow bounds any conversion. Tested: `test_dustFillsDoNotRefreshTheStallClock`,
      `test_realProgressAboveFloorRefreshesClockButSevenDayCapBounds`.
    - *Stall clock.* `startConversion` stamps `lastProgress = block.timestamp`, so a game nobody
      touched for a day still gets a real conversion attempt on a healthy venue before the native
      fallback can apply. Tested: `test_untouchedGameStartsItsClockOnFirstTouchAndGraduatesIntoIMD`.
    - *IMD without a bool return.* Token settlement and IMD fee payment accept `true` or an empty
      return. Tested: `test_noReturnIMDStillSettlesGraduationBurnAndFees`.
    - Deployment gas stays under the 13M target: repeated external-call and check sequences were
      folded into internal helpers (no behaviour change) to pay for the new code.

## Edges covered by tests and known gaps

Covered: open/salt/expiry/once, hook foreign initialize (direct and through the manager), genesis
gating of launch and king, deploy gas and opcode scan, paid signup window, uniqueness and uncapped entry list, roll preconditions,
split (genesis and non-genesis), curve quotes and sold-out cap, token lock and unlock, RNG
resolution timing, expiry, own-previous-roll resolution, batch of 16, bell, death, all-dead,
50-minute play cap, ranking with ties and triangular weights, bell share, finalizer fee cap,
claimable fallback, ETH conservation, graduation (pool, unlock, burn excess, price), failed
graduation, upkeep-driven finalize/graduate, king bid rules, king split, live-game weighting,
refund claimable, in-kind distribution and pre-crown atomicity, reign-stamped entitlement of unreached and broken pools,
cursor steering before a bid, 16-pool settlement floor, burn chunk cap and interval, paid failed genesis
restart (via `launch` and `restartGenesis`) through to a graduated second PvP and a burn on its
pool, funded pot returned with fewer than five living, 3x release cap with five living, finalizer
fee from roll income only, `fundPot` pad-only, king share weighted by roll pot, finalizer fee to
the bidder through `takeCrown`, roll after own bell reverts, dead Imp cannot ring, commit-order
tie-break, 200 living Imps finalize gas, burn chunk partial fill at the price limit, self-sandwich
does not pay.

Additional coverage: entry fee amount and burn routing (genesis and later games), no refunds,
contract wallets, paginated entry/seat views, everyone seated at <=200 and exactly 200 at 5,000,
binding fallback boundaries, chunk independence, delayed draw clocks, king eligibility before/after draw,
statistical fairness, outgoing king fee ordering, pool-failure isolation, real token-side fee transfers,
partial burn fills and real slot0 reads. See `docs/TEST-REPORT.md` for measured results.

New v4 coverage: profitable/loss/minOut bail-outs, rejected payments, croaked seats, pending rolls,
erased ranking/bell/living/funding exclusions, sold-out re-entry, ETH/token conservation, closed-venue
sybil economics, conversion limits/cooldown/partial fills/gas starvation, both timeout paths, donation
isolation, both currency orders, price equivalence, two-hop burns, and in-kind IMD/coin king fees.

Known limits: local real-core tests do not attest target-chain deployed code or sequencer entropy.
No VRF or external oracle is added. Immutable LP and burn mechanics retain exposure to market price,
liquidity depth and MEV. Fee collection does not swap or cross ticks. Unexpected manager behavior can still fail the
fixed stipend; broken-pool retries remain permissionless. The application has no upgrade, sweep or operator rescue.
The one-shot binders still require atomic deployment (#19). Statistical fairness is not a formal
proof, and tests passing is not an independent adversarial review.

## Tools run

The final test report records `forge build`, `forge test`, `forge fmt --check`, the offline manifest
validator, fuzz/invariant results and gas measurements. No deployment, broadcast, RPC or fork calls.
Slither/Mythril and an independent security review were not performed in this assignment.
