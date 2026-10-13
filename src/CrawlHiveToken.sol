// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CrawlHive (CRAWLHIVE)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 CRAWLHIVE (18 decimals) is
///         minted once, in the constructor, to the deployer. There is no owner, no minting after
///         deployment, no pause, no blocklist, no transfer fee and no burn hook: every transfer moves
///         exactly the amount requested and the supply can never grow.
/// @dev The deployer is `msg.sender` of the constructor. On an IdentityMD launch that is the
///      ProjectFactory, which distributes the supply (swarm share, pool seed, remainder) itself.
///      The contract takes no constructor arguments and makes no external calls while deploying,
///      so it can be deployed on an empty chain from its creation code alone.
contract CrawlHiveToken is ERC20 {
    /// @notice Token name returned by `name()`.
    string public constant TOKEN_NAME = "CrawlHive";
    /// @notice Token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "CRAWLHIVE";
    /// @notice Number of decimals; the fixed ERC-20 default.
    uint8 public constant DECIMALS = 18;
    /// @notice Whole supply in minor units: 1,000,000,000 * 10^18. Minted once, never again.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Mints the entire fixed supply to the deployer.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
