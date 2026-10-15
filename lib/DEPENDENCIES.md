# Vendored dependencies

All dependencies are ordinary files. No submodules, package install or network is needed to build.

- `forge-std`: unchanged from the pinned base repository
  `identity-md-launches/launch-1643-dontbuythistoken` at
  `2ed30a2f81876c537e98f792e7239012e3e64311`; licenses in `forge-std/`.
- `v4-core`: Uniswap **v4.0.0**, commit
  `e50237c43811bd9b526eff40f26772152a42daba` from
  https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba.
  Unmodified production `src/` (upstream `src/test/` excluded), README and licenses.
  `PoolManager` and its imported production code compile with solc 0.8.26 in the default tests.
  The manifest applications continue using the base ABI mirror; they do not deploy PoolManager.
- `solmate`: commit `4b47a19038b798b4a33d9749d25e570443520647`, the submodule
  revision pinned by v4.0.0. Only required file `src/auth/Owned.sol` and LICENSE.
  https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647.

`test/RealV4.sol` is a local callback router, not a pool substitute. Test fixtures use real
`unlock`, `modifyLiquidity`, `swap`, `donate`, `settle`, `take` and `extsload` operations.
The only blockchain-system mock is `MockArbSys` at the local test address 0x64.
Tests may inject explicit dependency failures with Foundry cheatcodes to exercise recovery.
