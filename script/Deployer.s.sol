// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script} from "forge-std/Script.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";
import {Vault} from "../src/Vault.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {CCIPLocalSimulatorFork} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {Register} from "@chainlink/local/src/ccip/Register.sol";
import {RegistryModuleOwnerCustom} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";

// Separation of Deployment and Configuration:
// This lesson follows a common and recommended pattern: contract deployment (creating instances)
// is handled by one script, while inter-contract state setup (configuration) is managed by a separate script.
// Token and Pool are deployed on both source and destination chains
contract TokenAndPoolDeployer is Script {
    function run() public returns (RebaseToken token, RebaseTokenPool pool) {
        CCIPLocalSimulatorFork ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        // The Register.NetworkDetails struct holds crucial addresses for CCIP components.
        // It must be stored in memory.
        Register.NetworkDetails memory networkDetails = ccipLocalSimulatorFork
            .getNetworkDetails(block.chainid);

        vm.startBroadcast();

        token = new RebaseToken();

        pool = new RebaseTokenPool(
            IERC20(address(token)), // The deployed token address
            new address[](0), // Empty allowlist
            networkDetails.rmnProxyAddress, // RMN Proxy address from simulator
            networkDetails.routerAddress // Router address from simulator
        );
        vm.stopBroadcast();
    }
}

contract SetPermissions is Script {
    function grantRole(address token, address pool) public {
        vm.startBroadcast();
        IRebaseToken(token).grantMintAndBurnRole(address(pool));
        vm.stopBroadcast();
    }

    function setAdmin(address token, address pool) public {
        CCIPLocalSimulatorFork ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        Register.NetworkDetails memory networkDetails = ccipLocalSimulatorFork
            .getNetworkDetails(block.chainid);

        //////////////////////////////////
        // Perform CCIP Configuration Steps
        //////////////////////////////////
        vm.startBroadcast();
        // Register Admin: We inform the CCIP RegistryModuleOwnerCustom contract
        // that the deployer of this script (the owner of the token) will be the administrator for this RebaseToken.
        // That is -> the token's owner (our deployer EOA) as its CCIP administrator.
        RegistryModuleOwnerCustom(
            networkDetails.registryModuleOwnerCustomAddress
        ).registerAdminViaOwner(address(token));

        // Accept Admin Role: The designated admin (our deployer account) must then formally accept
        // this administrative role for the token within the TokenAdminRegistry.
        TokenAdminRegistry(networkDetails.tokenAdminRegistryAddress)
            .acceptAdminRole(address(token));

        // Set Pool: Finally, we link our RebaseToken to its dedicated RebaseTokenPool in the TokenAdminRegistry.
        // This tells CCIP which pool contract is responsible for managing our specific token.
        TokenAdminRegistry(networkDetails.tokenAdminRegistryAddress).setPool(
            address(token),
            address(pool)
        );

        vm.stopBroadcast();
    }
}

// Vault is only deployed in the source chain. This is because core functionalities like
// deposit and redemptions are restricted to the source chain environment.
contract VaultDeployer is Script {
    IRebaseToken public immutable REBASE_TOKEN;

    constructor(IRebaseToken _rebaseToken) {
        REBASE_TOKEN = _rebaseToken;
    }

    function run(address _rebaseToken) public returns (Vault vault) {
        vm.startBroadcast();

        vault = new Vault(IRebaseToken(_rebaseToken));

        IRebaseToken(_rebaseToken).grantMintAndBurnRole(address(vault));

        vm.stopBroadcast();
    }
}
