// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DaoToken} from "./DaoToken.sol";

/// @title TokenDeployer — deploys DaoToken instances.
/// @notice Holds the DaoToken creation bytecode so the factory doesn't have to, keeping the
///         factory's own runtime code under the EIP-170 24,576-byte limit. Stateless, no admin.
contract TokenDeployer {
    function deploy(string calldata name, string calldata symbol, uint256 initialSupply, address initialHolder)
        external
        returns (DaoToken)
    {
        return new DaoToken(name, symbol, initialSupply, initialHolder);
    }
}
