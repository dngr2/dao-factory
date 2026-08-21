// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DaoGovernor} from "./DaoGovernor.sol";

/// @title GovernorDeployer — deploys DaoGovernor instances.
/// @notice Holds the DaoGovernor creation bytecode so the factory doesn't have to, keeping the
///         factory's own runtime code under the EIP-170 24,576-byte limit. Stateless, no admin.
contract GovernorDeployer {
    function deploy(
        string calldata name,
        IVotes token,
        TimelockController timelock,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumPercent
    ) external returns (DaoGovernor) {
        return new DaoGovernor(name, token, timelock, votingDelay, votingPeriod, proposalThreshold, quorumPercent);
    }
}
