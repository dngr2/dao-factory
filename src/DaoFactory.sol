// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {DaoToken} from "./DaoToken.sol";
import {DaoGovernor} from "./DaoGovernor.sol";

/// @title DaoFactory
/// @notice One-call deployer for a complete, self-sovereign DAO: a votes-token, a TimelockController,
///         and an OpenZeppelin v5 Governor, correctly wired together.
/// @dev Each deployment charges a bounded flat protocol fee forwarded to `feeRecipient`.
contract DaoFactory is Ownable {
    /// @notice Hard ceiling on the protocol fee; the owner can never set a fee above this.
    uint256 public constant MAX_FEE = 0.1 ether;

    /// @notice Current flat protocol fee charged per DAO deployment.
    uint256 public fee;

    /// @notice Recipient of collected protocol fees.
    address public feeRecipient;

    /// @notice Grouped addresses of one deployed DAO.
    struct Dao {
        address token;
        address timelock;
        address governor;
    }

    /// @notice All DAOs deployed by this factory, in creation order.
    Dao[] public daos;

    event DaoCreated(
        uint256 indexed daoId, address indexed creator, address token, address timelock, address governor, string name
    );
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    /// @param initialFee Starting protocol fee (must be <= MAX_FEE).
    /// @param feeRecipient_ Address that receives protocol fees.
    constructor(uint256 initialFee, address feeRecipient_) Ownable(msg.sender) {
        require(initialFee <= MAX_FEE, "DaoFactory: fee over cap");
        require(feeRecipient_ != address(0), "DaoFactory: recipient is zero");
        fee = initialFee;
        feeRecipient = feeRecipient_;
    }

    /// @notice Deploys and wires a full DAO (token + timelock + governor) in a single call.
    /// @dev Grants the governor PROPOSER + CANCELLER roles on the timelock, opens execution to anyone
    ///      (EXECUTOR_ROLE -> address(0)), and renounces the factory's admin role so the DAO is
    ///      self-governing. Requires exactly `fee` in msg.value.
    /// @param name Governor name (also its EIP-712 domain name).
    /// @param tokenName ERC20 token name.
    /// @param tokenSymbol ERC20 token symbol.
    /// @param initialSupply Tokens minted to `initialHolder` at deployment.
    /// @param initialHolder Recipient of the initial supply.
    /// @param votingDelay Blocks before voting opens on a new proposal.
    /// @param votingPeriod Voting window length, in blocks.
    /// @param quorumPercent Quorum as a percent of total supply (0-100).
    /// @param timelockDelay Timelock minimum delay, in seconds.
    /// @param proposalThreshold Minimum votes required to submit a proposal.
    /// @return token The governance token address.
    /// @return timelock The timelock controller address.
    /// @return governor The governor address.
    function createDao(
        string calldata name,
        string calldata tokenName,
        string calldata tokenSymbol,
        uint256 initialSupply,
        address initialHolder,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 quorumPercent,
        uint256 timelockDelay,
        uint256 proposalThreshold
    ) external payable returns (address token, address timelock, address governor) {
        require(msg.value == fee, "DaoFactory: wrong fee");
        require(quorumPercent <= 100, "DaoFactory: quorum > 100");

        // 1. Governance token, initial supply minted to the specified holder.
        DaoToken daoToken = new DaoToken(tokenName, tokenSymbol, initialSupply, initialHolder);

        // 2. Timelock. Factory is the temporary admin so it can wire roles, then renounces.
        address[] memory empty = new address[](0);
        TimelockController tl = new TimelockController(timelockDelay, empty, empty, address(this));

        // 3. Governor bound to the token and timelock.
        DaoGovernor gov = new DaoGovernor(
            name, IVotes(address(daoToken)), tl, votingDelay, votingPeriod, proposalThreshold, quorumPercent
        );

        // 4. Wire roles: governor proposes/cancels, anyone executes, DAO self-administers.
        tl.grantRole(tl.PROPOSER_ROLE(), address(gov));
        tl.grantRole(tl.CANCELLER_ROLE(), address(gov));
        tl.grantRole(tl.EXECUTOR_ROLE(), address(0));
        tl.renounceRole(tl.DEFAULT_ADMIN_ROLE(), address(this));

        token = address(daoToken);
        timelock = address(tl);
        governor = address(gov);

        uint256 daoId = daos.length;
        daos.push(Dao({token: token, timelock: timelock, governor: governor}));
        emit DaoCreated(daoId, msg.sender, token, timelock, governor, name);

        // 5. Forward the protocol fee.
        if (msg.value > 0) {
            (bool ok,) = feeRecipient.call{value: msg.value}("");
            require(ok, "DaoFactory: fee transfer failed");
        }
    }

    /// @notice Number of DAOs deployed by this factory.
    function daoCount() external view returns (uint256) {
        return daos.length;
    }

    /// @notice Returns the addresses of a previously deployed DAO.
    function getDao(uint256 daoId) external view returns (address token, address timelock, address governor) {
        Dao storage d = daos[daoId];
        return (d.token, d.timelock, d.governor);
    }

    /// @notice Owner-only: update the protocol fee (bounded by MAX_FEE).
    function setFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_FEE, "DaoFactory: fee over cap");
        emit FeeUpdated(fee, newFee);
        fee = newFee;
    }

    /// @notice Owner-only: update the fee recipient.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "DaoFactory: recipient is zero");
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }
}
