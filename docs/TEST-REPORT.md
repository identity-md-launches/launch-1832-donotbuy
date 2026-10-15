# PvP Pad v4 test report

Local offline verification on 2026-10-15 with Foundry 1.8.3 and Solidity 0.8.26. Settings:
Cancun, via-IR, optimizer **1**, `bytecode_hash = "none"`, `cbor_metadata = false`.

**219 tests passed, zero failed, zero skipped, across 22 suites.** This includes all 193 inherited
v3 tests and 26 new v4 tests. The complete run used the assignment's seed, also pinned in
`foundry.toml`:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xb5c5a9b40cefda723aeaf099e10ee3bceaa5447ce85a23ffe7d1b73cc8363f6c forge test -vv
forge fmt --check
python3 tools/validate_manifest.py
```

Build, formatting and manifest checks pass. Compiler heuristic lint warnings remain about casts,
timestamps and guarded external calls; this is not a claim of warning-free static analysis or an
independent audit. Tests require no network, RPC, fork, environment reads, FFI or external files.

## Coverage

| Coverage | Tests | Evidence |
|---|---:|---|
| All inherited v3 suites | 193 | Raffle, seed bounty, resolver tips/expiry, ranking/bell/death, 200-seat settlement, carry release, crown ordering and gas caps, in-kind fees, reign stamps, broken-pool retries, entry/roll upkeep isolation, claims/reentrancy, deployment and invariant campaigns |
| `V4PadTest` | 24 | Bail profit/loss/minOut rollback; erasure of rank/bell/living/funding eligibility; timely pending tips; croaked wallets; all-erased end clock; rejected payments; actual sell-out then bail and buy; funded sybil economics; ETH/token conservation; real IMD/ETH limits, partial fills, interval, gas floor, per-game escrow isolation and donation isolation; exact initial price equivalence, token unlock, both currency orders; partial timeout; zero-liquidity no-progress timeout; bounded upkeep; two-hop burn and intermediate balances; IMD/coin fees across crown transitions; constructor/access failures, including changed PoolId fields and IMD/key mismatch; large raw-token price ratios |
| `V4FallbackTest` | 2 | Uninitialized real venue, exact 24-hour native fallback, continued v3 burn; native genesis followed by an IMD graduation, with rounding remainder collected as fees instead of stranded |

The two new fuzz tests run 64 cases each: bail sequences independently reconcile ETH and supply,
and real front-run / conversion / back-run swaps vary front-run capital from 0.0001 to 60 ETH.
The existing fuzz counts and invariant campaign depths remain, including the resolver campaign
(128 × 96 actions), king-fee campaign (128 × 64), and whole-pad campaign (40 × 60).
The original statistical raffle and 5,000-entry draw tests remain.

Every successful pool interaction uses the unmodified, vendored **Uniswap v4-core v4.0.0
PoolManager**, including initialization, full-range liquidity, fees, swaps, donations, settlement
and storage reads. The test IMD is a minimal plain, non-rebasing ERC20 fixture at the supplied
address. Its ETH/IMD pool has the exact production key and id, with approximately 68 ETH of
full-range depth and a fixture price of 1 raw IMD unit per wei. This price is chosen for local
arithmetic and is not asserted to be the live price. Both tokens use raw units throughout.
MockArbSys models the L2 hash window; a mock does not establish production randomness.

V3 regression adaptations are limited to the requested lifecycle changes and deployment size:
normal v3 ETH-pool scenarios explicitly wait for the new zero-IMD 24-hour fallback, rejected actions
expect the corresponding named v4 custom error, and the whole-pad accounting invariant includes
prepared conversion escrows. The actual v3 behavior assertions remain. No assertion relies on a
successful mocked PoolManager swap or substituted pool math. Explicit venue failures and selected
ranking fixtures are used only where stated by the tests.

## Gas measurements

| Operation | Local gas |
|---|---:|
| Atomic raw-CREATE2 manifest, including calldata/intrinsic and probe accounting overhead | **12,221,065** |
| Later `openPad`, including hook and genesis clones, calldata/intrinsic | **774,342** |
| Combined deployment and later opening | **12,995,407** |
| Conversion upkeep on a partially filled game | 451,623 |
| Direct two-hop burn, thin PVP pool | 283,960 |
| Crown transition, 16 real pools, both currencies, outgoing king exhausts ETH pushes | 4,795,428 |
| Crown transition, 18 real pools | 2,829,928 |
| Crown transition, 60 real pools fully settled | 7,804,512 |
| Minimum-gas crown bid, 60 real pools | 40 settled immediately; unreached pools retain the outgoing reign |
| Finalize, 200 living Imps, adverse rank order | 4,057,835 |
| Largest 32-seat draw chunk at 5,000 entries, cold game | 2,668,320 |
| All seven draw chunks for 200 seats | 16,251,690 across separate calls |
| Entry with pending foreign draw/finalize/graduate, estimated call limit | 185,039 |
| Roll with pending foreign draw, estimated call limit | 187,792 |
| Roll with pending foreign finalize/graduate, estimated call limit | 191,464 |

The deployment test enforces both the **16,777,216** hard ceiling and the **13M** combined target.
It measures gas inside the raw CREATE2 probe and checks the result exceeds total runtime
code-deposit cost; a gasleft comparison only around a top-level probe call can omit that cost in
Foundry 1.8. The rehearsal includes intrinsic/calldata gas and a 23k allowance for probe bookkeeping
and return overhead. Factory-specific attestation/wrapper overhead is not simulated; the authorized
pipeline must still enforce the actual transaction ceiling. The combined 13M target has little
headroom, so changing source, compiler options or constructor policy requires another measurement.

Operational measurements are call gas unless stated otherwise. Large fixtures sometimes pause
metering during setup, then resume before the measured operation. Each optional upkeep call retains
an explicit stipend and reserve. Conversion gets a 500k upkeep call with a 350k isolated venue
subcall and a pre-attempt gas floor; burn retains its 350k upkeep stipend. Direct calls remain public.

## Artifacts and offline reproducibility

| Application | Initcode bytes, excluding constructor words | Runtime bytes | Static words |
|---|---:|---:|---:|
| PadToken | 3,044 | 2,999 | 0 |
| PadGame | 19,977 | 19,936 | 0 |
| PvPPad | 11,613 | 11,233 | 3 |
| PadLiquidity | 18,152 | 17,554 | 4 |
| KingOfThePad | 3,311 | 2,829 | 3 |

Total runtime is **54,551 bytes**, or **10,910,200** code-deposit gas. Each runtime is below
24,576 bytes and each initcode plus arguments is below 49,152 bytes. The manifest validator and
runtime scan find no linked libraries or forbidden application escape opcodes. All constructors
succeed without code at either external dependency address, and create no token supply, name,
symbol, hook, game clone, pool or distributor. Both templates remain sealed.

All **85 vendored dependency files** were compared byte-for-byte with the exact pinned base
archive. No dependency was changed or installed as a submodule. The manifest has five contracts,
string-valued arguments, nonzero lowercase addresses, backward references, and the canonical
IMD venue PoolId as one static `bytes32` argument. The constructor reconstructs the full key and
rejects a mismatching ID before the pad binding. Its key hash matches
`0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02` in the real-core tests.

The manifest repair removes the native-currency/no-hooks zero-address arguments without changing
their protocol meaning. Constructor regressions reject changes to each of the five key fields,
a zero PoolId, and an IMD/key mismatch. The atomic CREATE2 test uses the literal supplied PoolId
and confirms the reconstructed key with no external code present. The offline validator now
rejects zero-address arguments and validates the `bytes32` word against the compiled ABI.

## Economic evidence and limits

The six-wallet sybil test includes a profitable individual bail-out, five living survivors,
funded carry release, the finalizer payment and a dump through coin/IMD and IMD/ETH. It leaves
**0.433763283181329605 ETH** net on the curve and loses **0.116818580362673557 ETH**, even excluding
entries and gas. AUDIT.md #13 derives the bound with bail-outs and explicitly states the venue-depth
and closed-market assumptions; it is not a promise against external price changes or withdrawn LP.

No deployment, broadcast, RPC, live bytecode attestation, explorer submission, Slither/Mythril run,
or independent contributor audit was performed. Legal review, an independent audit, confirmation of
live manager/IMD behavior and liquidity, and a target-chain rehearsal remain required before public
opening. Resolver, seed-capture, conversion and fee-collection operators remain permissionless;
rewards do not guarantee timely service. See README and AUDIT.md for responsibility and trust details.
