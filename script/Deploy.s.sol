// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DaoFactory} from "../src/DaoFactory.sol";
import {TokenDeployer} from "../src/TokenDeployer.sol";
import {GovernorDeployer} from "../src/GovernorDeployer.sol";

/// @notice Deploys the two child deployers and the DaoFactory wired to them.
///   INITIAL_FEE   - starting protocol fee in wei (optional, default 0, must be <= MAX_FEE)
///   FEE_RECIPIENT - receives protocol fees (required)
/// Individual DAOs are created after deploy via factory.createDao(...).
contract Deploy is Script {
    function run() external returns (DaoFactory factory, TokenDeployer td, GovernorDeployer gd) {
        uint256 initialFee = vm.envOr("INITIAL_FEE", uint256(0));
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        vm.startBroadcast();
        td = new TokenDeployer();
        gd = new GovernorDeployer();
        factory = new DaoFactory(td, gd, initialFee, feeRecipient);
        vm.stopBroadcast();
        console2.log("TokenDeployer:", address(td));
        console2.log("GovernorDeployer:", address(gd));
        console2.log("DaoFactory:", address(factory));
    }
}
