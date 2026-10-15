# v4 test contribution: revision for the pad-wide anchor

Scope of this round: the implementation revision (commit `891e8e7`) replaced the per-game conversion
anchor (`observe(launchId)`, `anchorOf(game)`) with a pad-wide one (`observeMarket()`, `anchor()`)
that every pad touch refreshes and anyone may call. The two accepted files of this contribution,
`test/V4Edges.t.sol` and `test/V4BailConversionInvariant.t.sol`, were brought onto the new API
without changing what they assert, and coverage was added for what the new design introduced.

## Changed

- `V4Edges.t.sol`: every `anchorOf(pvp)` read is now `anchor()`. The "never observed game has no
  anchor" assertion no longer has a meaning and now checks that the finalize upkeep recorded the
  untouched spot. New section "pad-wide anchor":
  - `test_flashPushInsideAnUnlockIsNotRecordedByObserveMarketOrThePadUpkeep`: inside one
    PoolManager unlock a contract sells 12 IMD (spot up >15%), calls the public `observeMarket()`,
    runs `pad.upkeep()`, tries `convertChunk` (rejected with `PadManagerUnlocked`), then buys the
    IMD back. The anchor is unchanged, the escrow untouched, and the honest chunk converts after.
  - `test_strangerObservationOfAGenuineRiseLetsTheNextChunkSellAtTheBetterPrice`: a lasting rise
    recorded by a stranger never stalls the next chunk and pays the game at least the fair rate.
- `V4BailConversionInvariant.t.sol`: the handler's band prediction uses `anchor()`, and a new
  `observe(actor)` action calls `observeMarket()` from random actors and checks it returns and
  records exactly `max(decayed anchor, spot)`. 164 calls in the pinned-seed run, no violation.

## Finding reported, not asserted (`.imd-findings.json`)

**Medium.** `observeMarket()` is public and the only flash guard is "PoolManager locked at the
read". One transaction can sell IMD in one unlock, observe, and buy back in a second unlock: the
venue returns to the fair price, the attacker pays two 1% fees (0.22 IMD measured for a 17% sqrt
push against the 68 ETH venue), and the shared anchor sits 17% above the market for ~28 h of
decay. Every converting game's chunks stall for longer than the 24 h no-progress fallback, so a
game with no IMD converted yet graduates into the v3 coin/ETH pool, and a partly converted one
sends its remaining escrow to the carry pot. Proof: `test/scratch/AnchorGriefProof.t.sol`
(self-contained, fails on this code at "a fair, untouched venue must convert within 24 h").

## Results

`forge test` with the pinned fuzz seed: 252 passed, 0 failed across 25 suites (the scratch proof
is the only failing test and is removed before verification). Fork runs against the live
Robinhood Chain IMD/ETH pool remain owed; the suite uses the real v4-core PoolManager with a local
venue matching the production key.
