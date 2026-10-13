# Vendored OpenZeppelin Contracts (subset)

Source: OpenZeppelin/openzeppelin-contracts, version 5.4.0, commit
`c64a1edb67b6e3f4a15cca8909c9482ad33a02b0`, MIT licence (see `LICENSE`).

Only the files `ERC20` depends on are vendored, unmodified, as ordinary files so the
project builds with no network and no git submodule:

- `contracts/token/ERC20/ERC20.sol`
- `contracts/token/ERC20/IERC20.sol`
- `contracts/token/ERC20/extensions/IERC20Metadata.sol`
- `contracts/utils/Context.sol`
- `contracts/interfaces/draft-IERC6093.sol`

Remapped as `@openzeppelin/contracts/` in `foundry.toml`.
