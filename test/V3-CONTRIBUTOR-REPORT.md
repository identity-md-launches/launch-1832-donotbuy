# PvP Pad v3 contributor test report

Verification date: 2026-10-14. Foundry 1.8.3, Solidity 0.8.26, Cancun, optimizer 200,
via-IR, and the inherited metadata settings.

The complete suite passes: **193 tests, zero failures, zero skips, across 20 suites**.
`forge build`, formatting checks on the added Solidity files, and the existing offline
manifest validator pass. Existing compiler lint warnings remain; this is not a claim of
a warning-free security analysis. No additional implementation defect was reproduced.

This contribution adds ten regression/property tests and two invariant campaigns checking
four properties. The other 181 tests, real v4-core implementation, application sources,
manifest, dependencies, configuration, and existing documentation are preserved. All
deliverable changes are under `test/`; no dependencies were added.

Revision note (2026-10-14): after this contribution was first accepted, the implementation
adopted reign-stamped settlement (`docs/AUDIT.md` item 29): a pool that a crown change does
not settle, because it was flagged broken or because the bid's gas did not reach it, pays the
king of the earliest reign it was never settled for on its next collection, then takes the
current reign's stamp. One retained test asserted the earlier behaviour (the bidder received a
broken pool's fees on retry) and failed against the revised sources. It now asserts the
documented semantics: the retry pays the outgoing king both currencies in kind, the bidder
receives nothing from that reign, the pool is stamped with the new reign, and fees earned
afterwards go to the new king only. The accepted imprecision recorded in item 29 (fees a
skipped pool earns between the crown change and its next collection also reach the earlier
king) is a documented design choice, not asserted as a defect here; the new king limits it
by collecting promptly.

## Added coverage

| File | Assertions and failure paths |
|---|---|
| `V3FailureEdges.t.sol` / `V3PoolFailureEdgesTest` | A token transfer returning false rolls back both fee currencies and vetoes a crown change; a successful retry clears failure history; three new failures must occur in distinct L2 blocks; a pool flagged broken does not veto the next bid, stays stamped with the outgoing reign, and its permissionless recovery pays the outgoing king both currencies in kind while the bidder gets nothing from that reign and everything earned afterwards; retry inside an actual PoolManager unlock reverts without corrupting health; unauthorized strict settlement and an invalid pool index revert. |
| `V3FailureEdges.t.sol` / `V3GameFailureEdgesTest` | Resolver accounting over hash-window offsets 0–350; settled rolls cannot pay another resolver; bounty callback reentrancy cannot capture twice or enlarge a draw chunk; resolver debt survives finalization and real v4 graduation; rejected claims preserve debt; a finalization with too many pending rolls rolls back partial resolution and tips, then succeeds after permissionless progress; both optional liquidity upkeep calls may exhaust their entire gas caps without reverting entry or roll. |
| `V3CarryProperties.t.sol` | Public carry donations, actual crown funding, and paid rolls with zero through six survivors. Drawing never pulls carry. Finalization pulls exactly the available unused allowance, at most once. Existing funding consumes the allowance first. The release cap obeys both 3x earned pot and 15% of curve ETH. Beneficiary receipts plus returned carry conserve the entire pot, including rounding dust. Repeated finalization cannot pull again. |
| `V3ResolverInvariant.t.sol` | Six recipients, paid play, time advancement, direct resolution with ordinary or constrained gas, and accepting/rejecting claims in random order. Each tip is pending, expired into the pot, or owed/paid to its actual resolver. Settled roll records are immutable. Game ETH, curve proceeds, burn funding, and token supply reconcile independently. Every sequence ends by resolving, claiming, finalizing, and graduating, with no game ETH or tokens stranded. |
| `V3KingFeesInvariant.t.sol` | Four recipients, real v4 fee donations, collection/retry, crown changes, gas-starved bids, and claims in random order. Per-recipient ETH receipts plus debts equal fees and refunds owed to that reign. Token balances account for donations and in-kind fees. No fee-token stash remains. ETH is conserved across recipients, the manager, liquidity, crown, pad, router, and dev. Every sequence finishes by collecting and draining all claim debts. |
| `V3AccountingActors.sol` | Test recipients that can reject ETH and independently count successful receipts. These are test actors, not application contracts. |

The invariant campaigns start after their relevant lifecycle gates, with successful economic
actions and rejected claims already exercised. Unexpected handler reverts fail the campaign;
expected failed claims and bids are explicitly checked. No `vm.store` fixtures or synthetic
token balances are used by the added tests. The pool failure tests selectively
mock a token transfer returning false. The upkeep exhaustion test replaces only the optional
liquidity target with gas-consuming methods; it also checks the exact forwarded stipends.
Other successful pool operations use the retained, unmodified v4-core PoolManager.

| Campaign | Inline runs | Depth / domain | Calls or cases | Unexpected handler reverts |
|---|---:|---|---:|---:|
| Resolver invariant | 128 | 96 actions | 12,288 | 0 |
| King fee invariant | 128 | 64 actions | 8,192 | 0 |
| Resolution window fuzz | 1,000 | Offset 0–350 L2 blocks | 1,000 | — |
| Carry allowance fuzz | 128 | 0–6 living Imps, donations, absent/minimum/larger crown funding | 128 | — |

These are **20,480 new randomized handler calls** and **1,128 new fuzz cases** in the full
assignment-seed run, in addition to the retained suite. Foundry 1.8 reports the properties
in each invariant contract as one aggregate test. The original whole-pad invariant campaign
continues to cover the registry, carry custody, game liabilities, token supply, and lifecycle.

## Audit regression mapping

The existing implementation mapping remains in `docs/AUDIT.md`; this table records the
additional evidence without changing those application documents.

| Requested fix | Retained proof coverage | Added evidence |
|---|---|---|
| 1. Strict king settlement | `AuditV3KingTest`, `CrownSettlementTest`: nested real unlock, insufficient gas, atomic rollback, three-block diagnosis and recovery, reign-stamped entitlement of unreached and broken pools | Token-transfer failure rollback; nested retry lock check; failure-history reset; a broken pool skipped by a bid still pays the outgoing king on recovery; randomized gas-starved bids and debt accounting |
| 2. King fees in kind | `LiquidityV4Test`, `KingTest`, `AuditV3KingTest`, `CrownSettlementTest`: no collection before first crown, real swap fees, outgoing king payment, sixteen-pool floor and gas-extended walks | Per-reign ETH/token reconciliation across random bids, donations, rejected pushes, and claims |
| 3. Resolver incentive and expiry | `AuditV3GameTest`: 60-second roller at ten L2 blocks/second, direct/upkeep beneficiaries, split, expiry penalty, sixteen-record limit | Every hash-window region, double-resolution resistance, debt across graduation, failed-finalization rollback, and resolver accounting invariants |
| 4. Binding draw seed and bounty | `RaffleTest`, `AuditV3GameTest`: deterministic fallback, unchanged commit, chunk/caller independence, one-time bounty | A bounty recipient attempts a second draw during its ETH callback; it cannot receive twice or advance extra seats |
| 5. Upkeep gas isolation | `AuditV3CarryUpkeepTest`: own-action estimates with foreign draw/finalize/graduate work, full game-step exhaustion | Distribution and burn each exhaust their explicit gas cap during both entry and roll; both user actions still succeed |
| 6. Carry release | `AuditV3CarryUpkeepTest`: three linked five-wallet games and the no-roll carry chain | Public-path fuzzing of survivor thresholds, king funding priority, unused allowance, cap bounds, conservation, and duplicate-finalization rejection |

## Gas measured in the complete run

| Operation | Gas |
|---|---:|
| Atomic raw-CREATE2 application deployment, including calldata and intrinsic | 12,188,501 |
| Later `openPad`, including hook and genesis clones | 786,290 |
| Combined deployment and later opening | **12,974,791** |
| Crown transition, sixteen real pools, both fee currencies, outgoing king exhausts ETH pushes | 4,698,427 |
| Entry while both optional liquidity upkeep stipends are exhausted | 1,353,887 |
| Roll while both optional liquidity upkeep stipends are exhausted | 1,428,275 |
| Entry call limit from retained own-action estimation tests | 185,039 |
| Roll call limit with pending foreign draw | 178,613 |
| Roll call limit with pending foreign finalize or graduate | 183,203 |

The new exhaustion checks each supply a 1,600,000-gas call limit and require both the
750,000-gas distribution call and 350,000-gas burn call to occur. Their measurements include
test-side call overhead and exclude transaction intrinsic gas. They measure deliberate
upkeep exhaustion, not the minimum gas for entry/roll. The own-action figures are call limits,
not consumed gas. Large per-test gas totals elsewhere include fixture construction and many
separate calls; they are not single transaction estimates. The atomic deployment rehearsal
excludes deployment-service-specific wrapper overhead, as documented in the retained report.

Manifest validation confirms the original five-contract order, string constructor arguments,
backward references, lowercase static addresses, no unresolved links, nonpayable constructors,
initcode/runtime bounds, forbidden-opcode checks, `bytecode_hash = "none"`, and
`cbor_metadata = false`. Runtime sizes are 3,210 / 18,665 / 11,790 / 13,808 / 3,138 bytes
for PadToken / PadGame / PvPPad / PadLiquidity / KingOfThePad respectively, all below 24,576.

## Reproduction and limits

The complete run used the assignment seed:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0x1e572fb3fcde0b288122efe0d6a70e987a222567a2ac5cd3bc7883ffbf299030 \
  forge test --out test/scratch/out --cache-path test/scratch/cache -vv
```

The revision run used the normal Foundry output location: `forge build`, `forge test` with
the assignment seed above, `forge fmt --check` on the added files, and
`python3 -I tools/validate_manifest.py`. Inline fuzz/invariant settings travel with the tests;
no configuration edits or environment-setting cheatcodes are required.

The twelve added tests also pass with the inherited configuration seed
`0x6db4fb9e8219718221c07e9d6a1b41d1300d50a7ad58787663b260552f351f1f`, using
`--match-path 'test/V3*.t.sol'`. Both campaigns again completed with zero unexpected
handler reverts. The full-suite count above refers to the assignment-seed run.

No deployment, broadcast, RPC, or fork was performed. ArbSys remains a local block/hash-window
model. The real-core tests do not establish equivalence with the manager deployed on chain
4663 or prove sequencer fairness and resolver availability. The independent audit before
public launch and later explorer verification described in README and `docs/VERIFY.md`
remain operational requirements.
