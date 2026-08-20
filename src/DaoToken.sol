// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title DaoToken
/// @notice ERC20 governance token with checkpointed voting power (ERC20Votes) and permit support.
/// @dev Voting power uses the default block-number clock; holders must self-delegate to activate votes.
contract DaoToken is ERC20, ERC20Permit, ERC20Votes {
    /// @param name_ ERC20 token name (also used as the EIP-712 domain name for permit/delegation).
    /// @param symbol_ ERC20 token symbol.
    /// @param initialSupply Amount minted at construction (already scaled to token decimals).
    /// @param initialHolder Recipient of the initial supply.
    constructor(string memory name_, string memory symbol_, uint256 initialSupply, address initialHolder)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        require(initialHolder != address(0), "DaoToken: holder is zero");
        _mint(initialHolder, initialSupply);
    }

    // --- Required overrides for the ERC20 + ERC20Votes + ERC20Permit stack ---

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
