// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DaoFactory} from "../src/DaoFactory.sol";

/// @notice Deploys the DaoFactory.
/// @dev Config via env vars:
///      - INITIAL_FEE   (uint, wei): starting protocol fee, must be <= DaoFactory.MAX_FEE (0.1 ether). Defaults to 0.
///      - FEE_RECIPIENT (address):   receives protocol fees, must be non-zero. Required.
///      The broadcasting key (its address becomes the factory owner) is supplied to
///      `forge script` via --private-key / --account / --ledger, not read here.
contract Deploy is Script {
    function run() external returns (DaoFactory factory) {
        uint256 initialFee = vm.envOr("INITIAL_FEE", uint256(0));
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast();
        factory = new DaoFactory(initialFee, feeRecipient);
        vm.stopBroadcast();

        console2.log("DaoFactory deployed at:", address(factory));
        console2.log("owner (deployer):", factory.owner());
        console2.log("initialFee (wei):", factory.fee());
        console2.log("feeRecipient:", factory.feeRecipient());
    }
}
