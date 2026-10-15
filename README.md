# PvP Pad v4

Contracts-only launchpad on Robinhood Chain (4663). Every launch is a fast Spireth game played
in ETH; successful launches normally graduate into coin/IMD pools. This is a fresh deployment
of `identity-md-launches/launch-1764-pvp-pad-v3-robinhood` at
`c3a2fac8312fac1dabbd8deca78a987e180523c8`, with bail-outs, chunked IMD conversion and two-hop burns.
All vendored dependencies and v3 regressions are retained. No website is included.

**Legal review and an independent security audit are required before public launch.** The builder's
review and tests are not an independent audit. Review the game of chance, token issuance, auctions,
fund custody and chain-specific operational risks. See [AUDIT.md](docs/AUDIT.md).

## Deployment and ownership

Deployment creates **no token supply, token name/symbol, game clone, hook, pool or distributor**.
The two sealed templates cannot be initialized directly. The pad itself creates every token later,
including genesis PVP when the owner opens the pad. The manifest contains five applications:

| Order | Contract | Constructor arguments |
|---|---|---|
| 1 | `PadToken` | none |
| 2 | `PadGame` | none |
| 3 | `PvPPad` | `$owner`, `$contract:PadToken`, `$contract:PadGame` |
| 4 | `PadLiquidity` | `0x8366a39cc670b4001a1121b8f6a443a643e40951`, `$contract:PvPPad`, IMD, IMD/ETH PoolKey |
| 5 | `KingOfThePad` | `$contract:PvPPad`, `$contract:PadLiquidity`, `0x5b95a971b4583a5f011e9da082acdd679b870d06` |

Owner and dev are `0x5b95a971b4583a5f011e9da082acdd679b870d06`. Neither the factory nor IMD owns an
application. The owner can open before day 30 and receives 25% of crown extras; there is no pause,
upgrade, sweep, fee setter or privileged token mint. Anyone can open after day 30.

All five applications **must deploy in one transaction**, consuming the inherited one-shot binders
without an intervening transaction. Constructors are nonpayable, take only static arguments, and
call only earlier manifest contracts. They never call ArbSys or the PoolManager or require external
code. Nothing needs to be called after deployment to configure the applications. No deployment,
broadcast or RPC was performed here. The later `openPad` remains the intended public-opening action.

IMD is `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, treated as a plain ERC20 with internal
accounting in raw token units. The constructor accepts the canonical `bytes32` PoolId of the
native ETH / IMD key, fee **10000**, tick spacing **100**, no hooks:
`0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02`.
The constructor reconstructs the full key from the configured IMD address and requires its
`keccak256(abi.encode(key))` to match the supplied PoolId before binding to the pad. This needs no
external venue call. `launch.json` supplies four string arguments: manager, pad reference, IMD,
and the PoolId above. Native ETH and no hooks are fixed protocol values in the reconstructed key;
there are no zero-address constructor arguments. `imdEthKey()` exposes the full key. The supplied
approximately 68 ETH depth is a modelling assumption, not a live observation made by this assignment.

All dependencies are ordinary files under `lib/`, with licenses and pins in `lib/DEPENDENCIES.md`.
There are no submodules or network installs. Compiler settings are Solidity 0.8.26, Cancun,
via-IR, optimizer **1**, `bytecode_hash = "none"`, `cbor_metadata = false`. Compact custom errors
in `src/interfaces/PadErrors.sol` preserve the rejection conditions while reducing deployment gas;
clients must decode the v4 ABI. PadLiquidity's manager, pad and IMD addresses are constructor-written
storage with no setters, to reduce repeated address constants in runtime. They cannot be changed.
The offline validator checks schema, flattened static arguments, metadata, linking, sizes and
forbidden application opcodes. See [TEST-REPORT.md](docs/TEST-REPORT.md) for measured deployment
and later-opening gas and the limits of the factory rehearsal.

## After deployment: operational responsibilities

1. Obtain the independent audit and legal review before opening. The deployer must separately check
   the intended live PoolManager, IMD ERC20 behavior and pool identity/depth, `exttload`/Lock slot, slot0 layout and a graduation rehearsal on the
   target chain. The inherited manager address was not queried here; real-core local tests do not
   attest a different live implementation.
2. Mine a hook salt locally against the **final** PadLiquidity address and `hookInitCodeHash()`.
   CREATE2 is from PadLiquidity, and the resulting address must satisfy `address & 0x3fff == 0x2000`.
   About 1 in 16,384 salts match. `hookAddressFor(salt)` predicts the address; `mineSalt()` in
   `test/Base.t.sol` is the local reference. PadHook is deliberately absent from the manifest.
3. The owner calls `openPad(salt)` once, or anyone can after 30 days. It creates the hook and launch
   #1, “Pepes Value Pepes” / PVP. First paid entry starts its signup. If genesis ends with no roll,
   permissionless `restartGenesis()` (or `launch(...)`) creates a replacement. Other launches and
   crown bids wait for a successful genesis graduation.
4. Run permissionless resolvers and monitor draw commits. At ~10 L2 blocks/s the 256-block hash
   window is about 26 seconds, **shorter than the 60-second roll cooldown**. Resolve from commit+4,
   preferably within a few seconds, without waiting for the player to roll again. Watch pending
   queues, unfinished draws/finalizations/graduations, pool health and claimable balances. The 1%
   reward is an incentive, not a guarantee that a resolver is available.
5. Collect fees regularly and diagnose failures with `distribute(n)` or `retryPool(index)`. A bid
   that fails settlement rolls back its counters too. Three failed, fully funded attempts in
   distinct **ArbSys L2 blocks** mark a pool broken. Retry it after recovery; anyone can do so.
   Individual pools and large backlogs can require direct calls rather than opportunistic upkeep.
6. Run `PadLiquidity.convertChunk(game)` after finalization, with at least 30 seconds between
   attempts per game. It automatically escrows that game's net curve ETH once. Monitor
   `conversions(game)`, `ConversionProgress`, `ConversionStalled` and `canGraduate(game)`; call
   `graduate()` when ready. A failed attempt does not move the 24-hour no-progress deadline.
   The deadline starts at finalization, so an absent keeper does not add another day on first use.
   Upkeep attempts conversion and graduation, but explicit calls remain necessary if gas is scarce.

There are no oracle subscriptions, secret keys, backend signers, additional settings or operator
roles to configure in these contracts. Explorer verification is the deployer's later step:
[VERIFY.md](docs/VERIFY.md), for robin.etherscan.io.

## Game and raffle

- Anyone can `launch(name,ticker,imageURL)` after genesis graduates. Limits remain 32/10/200 bytes;
  name and ticker are nonempty. Each launch creates an EIP-1167 token and game clone, 1 billion
  tokens at 18 decimals. Transfers stay locked until graduation except transfers by the game or
  liquidity contract. Names and template addresses do not prove a clone belongs to the pad:
  use `tokenOf(id)`, `gameOf(id)` and `isGame(address)`.
- Entry costs exactly **0.001 ETH**, one per wallet, with no entry cap or EOA restriction. It is
  nonrefundable whether seated or not. First entry starts ten minutes of signup and stays in the
  game as `drawBounty`; every subsequent entry fee goes to the PVP burn bucket.
- The first post-signup draw call commits its ArbSys L2 block once. At commit+4 through commit+257
  the seed is `keccak256(abi.encode(game, hash(commit+1), hash(commit+2), hash(commit+3)))`. If nobody
  captures it before expiry, the seed is `keccak256(abi.encode(game, commitBlock, entryCount))`.
  **There is no recommit.** The caller that captures either seed earns the first entry fee once,
  by capped ETH push or claimable fallback. Upkeep forwards the actual user as bounty beneficiary.
- `draw(n)` performs up to 32 sparse Fisher-Yates trials with rejection sampling and seats at most
  200 distinct wallets. All wallets play when entries <=200; otherwise seat selection is random
  under the hash assumptions. Chunking, caller and capture delay do not change an already captured
  seed. Play starts only when all seats are drawn; seats are Imp records, not NFTs.
- This is not VRF randomness. Sequencer influence/censorship remains. The deterministic fallback
  prevents unlimited fresh-seed fishing but is predictable; a sole keeper still has the choice of
  timely capture versus the one fixed fallback. Independent prompt capture is desirable. Multiple
  wallets remain possible; the first entrant can recover its own fee by capturing the seed, so a
  solo failed-genesis round no longer necessarily burns that wallet's entry fee.
- Rolls cost **0.002 ETH**, with a **60-second cooldown**. The split is **90% curve, 7% pot,
  2% PVP burn, 1% resolver tip**. Genesis sends its 2% burn share to its own pot. The virtual curve
  starts with 1 ETH/1 billion tokens and sells 800 million tokens; sell-out requires 4 ETH on the
  curve. Unused curve share after sell-out goes to the pot; the tip remains separate.
- During play only, any seated wallet, including a croaked wallet while others keep the game alive,
  may `bailOut(minOut)`. All its locked coins return to the curve without an approval. If their
  constant-product sell value is V and its rolls actually spent C on the curve, payout is
  `C + floor((V-C)/2)` when `V >= C`, otherwise `floor(0.9*V)`. The remainder goes to the pot.
  A payout below minOut reverts the entire action; a rejected ETH push becomes claimable.
  Erasure is permanent: the seat cannot roll, rank, ring a bell, count as living or earn pot.
  Historical seat records remain visible with `erased(wallet) = true`. A pending roll resolves
  with zero height effect and its normal tip: timely to the resolver, expired to the roll pot.
  Erased activity cannot extend the all-dead timer. Returning coins after sell-out reopens capacity.
  `curveSpent(wallet)` excludes sold-out overflow. `ethRaised` is net of all bail-out sale values.
- Each roll commits its L2 block. Three future hashes plus game/Imp/nonce determine -4..-1 or
  +1..+4, clamped to ±50. Anyone can `resolvePending(max)`, at most 16 records per call, with a
  gas floor; successful timely resolution credits **0.00002 ETH** to that resolver's game
  `claimable`. `claim()` withdraws tips, including after graduation. A roll past commit+257 instead
  moves height up to four toward zero, sends its tip to the pot, and pays no resolver. The expiry
  penalty is retained to discourage withholding. Calls are idempotent and cannot double-pay.
- Death is ten minutes since last roll, or play start if none. A bell at ±50, all dead, or fifty
  minutes after play starts ends the game. Living Imps rank by absolute height, earlier committing
  L2 block, earlier roll index, then lower randomized seat index. The top ceil(living/2) split the
  ranked pot with triangular weights. Bell ringer receives 20%; without a bell all goes to ranks.
  With none living, the distributable pot carries forward. Finalizer receives 0.5%, max 0.005 ETH,
  capped by roll-earned ETH. Rejected ETH pushes are claimable; rounding dust goes to carry.

## Carry, liquidity and crown

`fundCarry()` is **permissionless**. Carry remains in PvPPad throughout signup, drawing and play.
At finalization, with at least five living Imps, a game pulls only its unused funded allowance:
`max(0, min(3 * rollPot, 15% * netCurveETH) - fundedPot)`, limited by available carry. Existing king
funding uses the cap first. Excess existing funding returns to carry. Completing another game's
draw inside the same transaction cannot capture the remainder. Donations and bail-out pot additions never increase rollPot. Bail-outs reduce the net curve term in the cap.

After finalization, curve ETH is escrowed separately for each game in PadLiquidity. Each
`convertChunk(game)` uses its own funds in one PoolManager unlock, with a spot-relative limit
of `sqrtPrice * 0.995` (less than 1% in price). A chunk can spend only to that limit; remaining
ETH stays in the game's escrow for the next attempt, at least 30 seconds later. Missing, empty,
failing or gas-hungry pools leave the escrow intact. A deliberately underfunded call cannot consume
the interval. Unsolicited IMD or ETH never increases a game's credited amounts.

Let P be the final curve ETH price per coin, E the ETH actually converted and I the IMD received.
Graduation reserves `floor(E/P)` coins and I IMD, setting IMD per coin to `I / floor(E/P)`.
Currencies are sorted, fee is 10000, tick spacing 200, hooks PadHook, and the full-range ticks
remain ±887200. PadLiquidity owns LP forever, with no removal path. The 1 ppm liquidity haircut
protects settlement rounding. Excess launch coins go to dEaD, and the token unlocks in that
transaction. `poolKey(token)` describes the established route after graduation.

After **24 hours without conversion progress**, `graduate()` uses partial IMD, sends unconverted
ETH to carry, and unlocks. If no IMD was obtained, the same timeout permits the v3 coin/ETH
full-range pool at the final curve price. A zero-net-curve game fails and burns remaining supply,
including a game whose buyers all bailed out; failed genesis remains restartable. No administrator
or post-deployment setting is needed for either fallback. IMD rounding remainder is donated to the same permanent position as fees inside the unlock,
then collected in kind for its reign. Native fallback dust joins the ETH burn bucket.

Crown auction opens after genesis graduates: first bid >=0.01 ETH; subsequent bids >=110% after
one hour. The outgoing bid is refunded in full by push/claimable. The extra (the whole first bid)
splits 50% games, 25% burn, 25% dev. Games share follows v2: last ten **entered** launches with five
entries during signup/draw or five seats after draw, weighted by roll-earned pot (equal if all zero).
No eligible game means carry. Free launches never displace entered games from this window.

Before changing an existing king, the pre-crown settlement walks **every pool** from the public
cursor while the bid's gas still fits another collection (300k per self-call plus a 100k reserve),
and must reach at least **16 pools** or the bid reverts. A bid requires at least the 5M minimum
stipend plus EIP-150 margin and a 600k reserve; everything above the reserve is forwarded, so a bid
sent with more gas settles more pools (the minimum fits about 40 real pools locally; 60 pools need
about 7.6M). `takeCrown` and `distribute` reject an already-unlocked PoolManager via the vendored
Lock transient slot read through `exttload`. Any failure in an unflagged pool aborts the bid.
Permissionless normal collection records failures instead; after three failures in distinct L2
blocks a pool is skipped as broken until a successful `retryPool` clears its flag. A gas-starved
probe cannot mark it broken.

Collected **IMD and launch coins (ETH for native fallback pools) are paid in kind** to the king each pool is owed to. ETH has a 30k push
cap and claimable fallback; tokens use plain transfer. There is no fee sale, token stash,
`SELL_CHUNK` or king escrow. Before the first crown, collection does nothing and fees accrue in LP
positions; the first king collects them. Each settlement closes a **reign**: PadLiquidity records
the outgoing king as `reignKing[reign]` and bumps `reign`; every pool stores the reign it is
settled for. A pool the walk did not reach (gas ran out after the 16-pool floor, or the pool was
flagged broken) keeps the old reign stamp, and its next collection, by anyone, pays that reign's
king rather than the new one. So nothing earned under a reign can be collected by the next king,
whatever the pool count or the public cursor position. The one imprecision runs the other way: fees
such a pool earns between the crown change and its next collection also go to the earlier king,
which the new king avoids by collecting promptly (or by sending the bid with enough gas).

Burn-bucket buys use **ETH → IMD → PVP in one unlock**, at most 0.02 ETH every ten minutes.
Each hop has its own limit from current spot: sqrt factor 0.995 in the decreasing direction,
or 1.004987562112089027 in the increasing direction, both within 1% in price. Unspent ETH stays
in `burnBucket`; unused intermediate IMD stays in `burnIMD` and can be used on later chunks.
These balances are separate from conversion escrows and king fees. PVP output goes directly to
dEaD. When genesis used the explicitly required native fallback, burns retain the v3 ETH → PVP
route, since there is no PVP/IMD pool. Spot-relative limits bound each swap's impact, not the absolute price or all possible MEV.

## Gas bounds and public work

| Work | Limit |
|---|---|
| Draw | 32 trials, at most 200 seats |
| Roll resolution | 16 examined records, including already resolved records; 200k gas floor |
| Crown settlement | every pool while gas fits, at least 16; 300k each + 100k reserve; 5M minimum stipend, all surplus forwarded; 600k outer reserve + EIP-150 margin |
| Public distribute(n) | at most 16 pools per call; unreached or broken pools pay the reign's recorded king |
| Collection health probe | Whole 300k stipend + 100k reserve required |
| Pad game upkeep step | 4.5M per call; latest entered game plus one older round-robin game |
| Pad distribute(2) / burnChunk | 750k / 350k |
| Conversion | 500k upkeep call, 350k isolated swap; 30s/game; 24h no-progress fallback |
| Pad reserve | 100k plus cap/63 before each subcall; return immediately below 150k |
| ETH pushes | 30k; rejected push becomes claimable |
| King funding window | Last 10 entered games; eligibility threshold 5 |
| Funded release | >=5 living; min(3x roll pot excluding bail taxes, 15% net curve ETH); unused allowance only for carry |

Entry, roll, launch, crown and game lifecycle calls run best-effort upkeep. Subcalls get explicit
caps and run only with sufficient gas left; other games' draw/finalize/graduate work can be skipped
without reverting the user's action. Direct `draw`, `resolvePending`, `finalize`, `graduate`,
`distribute`, `retryPool`, `convertChunk(game)`, `burnChunk`, game `poke` and pad `upkeep` remain public. Large queues may
need repeated calls; fee payouts alone do not guarantee operators will find work profitable.

Game views retain `entryCount`, `entryOf`, paginated `getEntrants` (max 200), `impOf`, `myEntry`,
`drawProgress`, `drawSeed`, `drawNonce`, `drawCommitted`, `drawSeeded`, `drawComplete`, and separate
signup/play/end clocks. Entry and seat event indexes are 1-based, matching getters. Status codes:
0 waiting, 1 signup, 2 play, 3 ended, 4 finalized/ready, 5 graduated, 6 failed, 7 drawing, 8 converting.
A prepared escrow becomes ready when conversion completes or the stall timeout is reached. New events expose
resolver tips, seed bounties and pool health. Timers use timestamps; randomness and distinct failure
blocks use ArbSys L2 numbers. No L1 blockhash, block number, or prevrandao drives game outcomes.

## Offline build and checks

```sh
forge build
FOUNDRY_FUZZ_SEED=0xb5c5a9b40cefda723aeaf099e10ee3bceaa5447ce85a23ffe7d1b73cc8363f6c forge test
forge fmt --check
python3 tools/validate_manifest.py
```

Compiler: Solidity **0.8.26**, Cancun, via-IR, optimizer 1, `bytecode_hash = "none"`,
`cbor_metadata = false`. FFI and filesystem permissions are disabled. foundry.toml pins this assignment's
fuzz seed, also supplied by the reproduction command. Tests read no
configuration/environment variables and need no network. The real v4.0.0 PoolManager and its
required Solmate dependency are vendored; versions and licenses are in `lib/DEPENDENCIES.md`.
MockArbSys models hash-window boundaries offline, including the requested ten L2 blocks per second.

Further records: [test report](docs/TEST-REPORT.md), [current audit](docs/AUDIT.md),
[original v2 review](docs/AUDIT-V2-HISTORY.md), [verification handoff](docs/VERIFY.md).
