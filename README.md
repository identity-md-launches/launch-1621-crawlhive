# CrawlHive (CRAWLHIVE)

A plain, fixed-supply ERC-20 token for an IdentityMD custom-token launch on Ethereum mainnet.

| Property        | Value                                                       |
| --------------- | ----------------------------------------------------------- |
| Contract        | `CrawlHiveToken` (`src/CrawlHiveToken.sol`)                 |
| Name            | `CrawlHive`                                                 |
| Symbol          | `CRAWLHIVE`                                                 |
| Decimals        | 18                                                          |
| Total supply    | 1,000,000,000 CRAWLHIVE = `1000000000000000000000000000` minor units (1e27) |
| Minting         | Once, in the constructor, all to `msg.sender` (the deployer) |
| Constructor args| none                                                        |
| Base library    | OpenZeppelin Contracts 5.4.0 `ERC20` (vendored, unmodified) |
| Compiler        | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## Behaviour

- Standard ERC-20: `transfer`, `transferFrom`, `approve`, `allowance`, `balanceOf`, `totalSupply`,
  `name`, `symbol`, `decimals`, with the `Transfer` and `Approval` events.
- Every transfer moves exactly the amount requested. There is no fee, tax, reflection, burn-on-transfer,
  max-wallet or cooldown.
- The supply is fixed at deployment. There is no `mint`, no minter role and no owner: nothing can ever
  increase `totalSupply`.
- There is no pause, blocklist, freeze, seize or forced burn. No address, the deployer included, can
  move or lock another holder's balance; `transferFrom` requires an allowance like any ERC-20.
- The contract is not upgradeable and its runtime contains no `DELEGATECALL`, `CALLCODE` or
  `SELFDESTRUCT`. It has no `receive`/`fallback`, so it rejects ether.
- The constructor makes no external calls and needs nothing deployed beforehand, so the creation
  code can be deployed on an empty chain.

## Assumptions

- **The deployer is the launch factory.** On the IdentityMD launch the ProjectFactory deploys the
  token (CREATE2, from the attested creation code) and is therefore `msg.sender` of the constructor.
  It receives the entire supply and pays it out: 10% to the launch's MerkleDistributor (the swarm's
  share), 88% (`poolBps = 8800`) seeds the single-sided Uniswap v4 pool against IMD
  (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), and the remaining 2% is forwarded to
  `economics.remainderTo` (`0x12a7aad083cef06fef7c295514b52fc8bc81960d`). The token itself reserves,
  allocates or sends nothing: it only mints to its deployer.
- **No exemptions are needed.** Because transfers are untaxed, the token does not need to know the
  factory, the PoolManager or the distributor. It therefore takes no constructor arguments.
- **Supply and decimals** are hard-coded constants (`TOTAL_SUPPLY`, `DECIMALS`) and must match the
  manifest the launch step writes (`token.totalSupply = 1000000000000000000000000000`, `decimals = 18`).
- The pool parameters (`pool.fee = 12500`, `tickSpacing = 60`, opening market cap of 2,500 IMD) are
  the launch's, not the token's; nothing in this repository encodes them.

## Deployment parameters

The launch manifest (`launch.json`) is written by the manifest step after this work is accepted; it
is intentionally **not** included here. For that step:

| Field                   | Value                                   |
| ----------------------- | --------------------------------------- |
| `token.contract`        | `CrawlHiveToken`                        |
| `token.name`            | `CrawlHive`                             |
| `token.symbol`          | `CRAWLHIVE`                             |
| `token.decimals`        | `18`                                    |
| `token.constructorArgs` | `[]`                                    |
| `token.totalSupply`     | `1000000000000000000000000000`          |
| `contracts`             | `[]` (no application contracts)         |

`script/DeployCrawlHive.s.sol` is a helper for reproducing a deployment on a fork or testnet with
a reviewer's own key. It is **not** the launch path and takes no configuration; `deploy()` is
covered by the tests directly. The launch's deployer, the factory, never runs it.

## After launch

There is nothing for the owner to configure: the token has no owner-settable values, no roles and
no external dependencies. No post-launch calls are required or possible.

## Operational responsibilities

- **Holders** are responsible for their own keys and allowances. Approvals are standard ERC-20
  approvals; grant them only to contracts you trust and prefer exact amounts over `type(uint256).max`.
- **The requester** receives the 2% remainder at `economics.remainderTo` and is responsible for that
  wallet. Nobody can recover tokens sent to a wrong address or to the token contract itself: the
  contract has no rescue function by design (a rescue function would be a privileged hand on
  balances).
- **The launch deployer (IdentityMD)** attests the source, deploys from the built bytecode and
  performs the supply distribution. Explorer verification of the deployed contract belongs to that
  step; the build is reproducible (`bytecode_hash = "none"`, `cbor_metadata = false`, pinned solc).
- **Nobody** has an administrative capability over this contract once deployed. There is no
  upgrade, pause, blocklist or mint, so there are no keys to rotate or multisigs to hand over.

## Security notes

Checked against the eth-security checklist supplied with the task:

- Reentrancy: no external calls in any function; no ether handling.
- Access control: no privileged functions exist, so none can be misconfigured.
- Arithmetic: solc 0.8.26 checked arithmetic; the supply constant (1e27) is far below `uint256`.
- Front-running / approval race: the standard ERC-20 approve race applies, as to every ERC-20;
  users should set an allowance to zero before changing a non-zero one, or use exact amounts.
- Upgradeability / `delegatecall` / `selfdestruct`: none present (asserted by a test that scans
  the runtime bytecode).
- Library linking: only internal library code (OpenZeppelin `ERC20` is inherited, not linked), so the
  bytecode is deployable without linking.
- Tools run: `forge build`, `forge test` (unit + fuzz, 256 runs each), `forge fmt --check`. Slither
  and Mythril were not available in this environment. Tests passing are not an audit; a fixed-supply
  OpenZeppelin ERC-20 with no custom logic is the smallest reasonable surface.

## Layout

```
foundry.toml                      solc 0.8.26, bytecode_hash = "none", remappings
src/CrawlHiveToken.sol            the token
test/CrawlHiveToken.t.sol         unit, failure and fuzz tests
script/DeployCrawlHive.s.sol      local/testnet helper (not the launch path)
lib/forge-std/                    vendored forge-std 1.17.0 (plain files)
lib/openzeppelin-contracts/       vendored OpenZeppelin 5.4.0 ERC20 subset (plain files)
```

## Build and test

```
forge build
forge test
forge fmt --check
```

No network is needed: all dependencies are committed as ordinary files and the compiler is pinned
to 0.8.26.

## Tests

`test/CrawlHiveToken.t.sol` covers:

- metadata, decimals and the exact supply constant;
- the constructor minting the whole supply to the deployer, including when deployed via CREATE2
  from a factory contract (the launch's path) and via the script's `deploy()`;
- successful `transfer`, `transferFrom`, `approve`, infinite allowance, self-transfer, zero transfer,
  and that secondary transfers are untaxed;
- failures: transfer above balance, from an empty account, to the zero address; `transferFrom`
  without, above, or with allowance but no balance; approving the zero spender; unknown selectors;
  sending ether;
- the launch flows (swarm 10%, pool 88%, remainder 2%, then a claim) moving exact amounts and
  leaving the supply unchanged;
- that no mint / ownership / upgrade / pause / blocklist / freeze / seize / `burnFrom` entry point
  exists, from a stranger and from the deployer, and that a holder keeps its balance and can still
  transfer afterwards;
- that the runtime bytecode contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` and fits EIP-170;
- fuzz: supply conservation across transfers, reverts above balance, allowance enforcement.
