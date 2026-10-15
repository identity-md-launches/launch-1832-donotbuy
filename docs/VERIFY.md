# Verifying PvP Pad v4 on robin.etherscan.io

Verification is the authorized deployer's later step, after the deployment handoff supplies the
confirmed application addresses. This assignment does not deploy, broadcast, query RPCs, or submit
explorer verification. Use [Robinhood Etherscan](https://robin.etherscan.io) for chain **4663**.

Use the exact committed sources, including vendored imports, with Solidity **0.8.26**, Cancun,
via-IR enabled, optimizer enabled with **1 run**, `bytecode_hash = "none"` and
`cbor_metadata = false`. No application needs a linked library. Standard JSON verification is
preferred. Foundry's `forge verify-contract --show-standard-json-input` can prepare the compiler
input for a confirmed address and source identifier; that preparation command is distinct from
submitting verification. Keep the compiler settings from `foundry.toml` unchanged.

The five applications must be deployed atomically in this order, with zero deployment ETH:

| Source identifier | ABI constructor arguments |
|---|---|
| `src/PadToken.sol:PadToken` | `()` |
| `src/PadGame.sol:PadGame` | `()` |
| `src/PvPPad.sol:PvPPad` | `(owner, tokenTemplate, gameTemplate)` |
| `src/PadLiquidity.sol:PadLiquidity` | `(poolManager, pad, imd, imdEthPoolId)` |
| `src/KingOfThePad.sol:KingOfThePad` | `(pad, liquidity, dev)` |

Owner and dev: `0x5b95a971b4583a5f011e9da082acdd679b870d06`.
Inherited PoolManager: `0x8366a39cc670b4001a1121b8f6a443a643e40951`.
IMD: `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`.
The venue PoolKey is `(native ETH, IMD, 10000, 100, no hooks)`, with id
`0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02`.
In `launch.json`, the key is represented by that canonical `bytes32` PoolId after the first three
address arguments, for four static string words in total. The constructor reconstructs
`PoolKey(address(0), imd, 10000, 100, address(0))` and checks its ABI-encoded keccak256 hash against
the supplied ID before binding. Native ETH and no hooks remain fixed protocol values, without
zero-address manifest arguments. Use this constructor ABI when verifying:

```text
constructor(address,address,address,bytes32)
```

Use the confirmed addresses of this fresh deployment for contract references. The templates have
zero supply and empty names/symbols; no token constructor metadata or allocation is required.
The supplied DONOTBUY/DNB/supply metadata is not used: the final decision is a contracts-only
launch, and every actual token is created later by the pad. No deployment token, game clone, hook,
pool or distributor exists at the end of the manifest deployment. There is no post-constructor
configuration call. Later `openPad(salt)` is the intended opening action.

Before handing off artifacts, run:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xb5c5a9b40cefda723aeaf099e10ee3bceaa5447ce85a23ffe7d1b73cc8363f6c forge test
forge fmt --check
python3 tools/validate_manifest.py
```

The validator checks exact constructor words and backward references, nonzero lowercase addresses, the
compiler and metadata settings, absence of link references, runtime/initcode sizes, and the
protected floor's forbidden-opcode scan. `AtomicDeploymentTest` rehearses the raw CREATE2 manifest
with no external code at either the PoolManager or IMD address. Its gas measurement is inside the
probe so code-deposit gas is included; factory-specific attestation overhead remains a pipeline
responsibility. The deployment service must enforce the 16,777,216 transaction ceiling itself.

`PadHook` is created later by PadLiquidity during opening. Mine the salt against the **new**
PadLiquidity address and `hookInitCodeHash()`; it must give `address & 0x3fff == 0x2000`. Do not reuse
an old launch's salt or addresses. Verify the resulting hook as `src/PadHook.sol:PadHook`, with
`(poolManager, padLiquidity)` constructor arguments. Token and game clones are EIP-1167 proxies
of the verified templates. Clone authenticity comes from `PvPPad.tokenOf(id)`, `gameOf(id)` and
`isGame(address)`, not a name, symbol or shared template.

Before public opening, the deployer must obtain legal review and an independent audit, confirm the
actual manager supports the vendored `exttload` Lock slot and slot0 layout, confirm the configured
IMD is a plain ERC20 and the venue key/depth is appropriate, and rehearse conversion, both currency
orders and graduation on the target chain. These are future operational responsibilities, not
claims that this offline assignment verified live code or liquidity. No operator key, oracle,
subscription or post-deployment address setter is needed by the delivered contracts.
