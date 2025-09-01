/**
 * Resolving "Stack too deep" Errors with --via-ir:
 * If you encounter "Stack too deep" compiler errors in Foundry, especially with complex contracts or many local variables,
 * try building with the --via-ir flag:
 * ```bash
 *  forge build --via-ir
 * ```
 * This flag instructs the Solidity compiler to first translate your code to Yul (an intermediate representation).
 * The Yul optimizer can then perform more advanced optimizations, often resolving stack depth issues by managing
 * stack usage more effectively. For a deeper understanding of Yul, resources like the Cyfrin Updraft course
 * on Assembly & Formal Verification can be beneficial.
 */

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";
import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";
import {CCIPLocalSimulatorFork} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {Register} from "@chainlink/local/src/ccip/Register.sol";
import {BurnMintERC677Helper} from "@chainlink/local/src/ccip/BurnMintERC677Helper.sol";
import {RegistryModuleOwnerCustom} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@ccip/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

contract CrossChainTest is Test {
    uint256 sepoliaFork;
    uint256 arbSepoliaFork;

    Vault vault; // Vault will only be on the source chain (eth-sepolia) in this burn-and-mint example.

    RebaseToken sepoliaRebaseToken; // RebaseToken will be deployed on both chains
    RebaseToken arbSepoliaRebaseToken;

    RebaseTokenPool sepoliaPool;
    RebaseTokenPool arbSepoliaPool;

    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant INITIAL_AMOUNT = 10 ether;
    uint256 constant AMOUNT_TO_BRIDGE = 1 ether;

    CCIPLocalSimulatorFork ccipLocalSimulatorFork;

    Register.NetworkDetails sepoliaNetworkDetails;
    Register.NetworkDetails arbSepoliaNetworkDetails;

    TokenAdminRegistry sepoliaTokenAdminRegistry;
    TokenAdminRegistry arbSepoliaTokenAdminRegistry;

    function setUp() public {
        console2.log("setUp()");
        // 1. Create and select the initial (source) fork (Sepolia)
        // This uses the "sepolia" alias defined in foundry.toml
        sepoliaFork = vm.createFork("sepolia");

        // 2. Create the destination fork (Arbitrum Sepolia) BUT don't select it yet
        // This uses the "arb-sepolia" alias defined in foundry.toml
        arbSepoliaFork = vm.createFork("arb-sepolia");

        vm.selectFork(sepoliaFork);
        // 3. Deploy the CCIP Local Simulator contract ON THE SOURCE CHAIN (Sepolia)
        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();

        // 4. Make the simulator's address persistent across all active forks
        // This is crucial so both the Sepolia and Arbitrum Sepolia forks
        // can interact with the *same* instance of the simulator (accessible with
        // the same address and state on both the Sepolia and Arbitrum Sepolia forks).
        vm.makePersistent(address(ccipLocalSimulatorFork));

        // Create our EOA "owner"
        owner = makeAddr("owner");
        vm.deal(owner, INITIAL_AMOUNT);

        // Make the RebaseToken and Vault contracts deployments in the source chain (Sepolia)
        sepoliaRebaseToken = deployRebaseToken(owner, sepoliaFork);
        vault = deployVault(sepoliaFork, address(sepoliaRebaseToken));

        // Deploy the RebaseTokenPool contract in the source chain (Sepolia)
        vm.selectFork(sepoliaFork);
        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(
            block.chainid
        );

        sepoliaPool = deployRebaseTokenPool(
            sepoliaFork,
            address(sepoliaRebaseToken),
            sepoliaNetworkDetails.rmnProxyAddress,
            sepoliaNetworkDetails.routerAddress
        );

        // Deploy the RebaseToken contract in the destination chain (Arbitrum Sepolia)
        arbSepoliaRebaseToken = deployRebaseToken(owner, arbSepoliaFork);

        // Change to destination chain
        vm.selectFork(arbSepoliaFork);
        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(
            block.chainid
        );
        vm.stopPrank();

        // Deploy the RebaseTokenPool contract in the destination chain (Arbitrum Sepolia)
        arbSepoliaPool = deployRebaseTokenPool(
            arbSepoliaFork,
            address(arbSepoliaRebaseToken),
            arbSepoliaNetworkDetails.rmnProxyAddress,
            arbSepoliaNetworkDetails.routerAddress
        );

        // Grant the RebaseTokenPool contracts the MINTER AND BURNER role in their respective RebaseToken contracts
        address[] memory sepoliaGrantees = new address[](2);
        sepoliaGrantees[0] = address(vault);
        sepoliaGrantees[1] = address(sepoliaPool);
        grantMintAndBurnRole(sepoliaFork, sepoliaRebaseToken, sepoliaGrantees);

        address[] memory arbSepoliaGrantees = new address[](1);
        arbSepoliaGrantees[0] = address(arbSepoliaPool);
        grantMintAndBurnRole(
            arbSepoliaFork,
            arbSepoliaRebaseToken,
            arbSepoliaGrantees
        );

        // Register admin via owner in source and destination chains
        registerAdminViaOwner(
            sepoliaFork,
            address(sepoliaRebaseToken),
            sepoliaNetworkDetails
        );
        registerAdminViaOwner(
            arbSepoliaFork,
            address(arbSepoliaRebaseToken),
            arbSepoliaNetworkDetails
        );

        // Accept admin role in source and destination chains
        sepoliaTokenAdminRegistry = acceptAdminRole(
            sepoliaFork,
            address(sepoliaRebaseToken),
            sepoliaNetworkDetails
        );

        arbSepoliaTokenAdminRegistry = acceptAdminRole(
            arbSepoliaFork,
            address(arbSepoliaRebaseToken),
            arbSepoliaNetworkDetails
        );

        // Link tokens to their respective pools
        linkTokensToPool(
            sepoliaFork,
            address(sepoliaRebaseToken),
            address(sepoliaPool),
            sepoliaTokenAdminRegistry
        );
        linkTokensToPool(
            arbSepoliaFork,
            address(arbSepoliaRebaseToken),
            address(arbSepoliaPool),
            arbSepoliaTokenAdminRegistry
        );
    }

    modifier fundAliceAndBob() {
        // Fund Alice and Bob in both chains
        console2.log(
            "Funding sender and receiver in source and destination chains"
        );
        vm.selectFork(sepoliaFork);
        vm.deal(alice, INITIAL_AMOUNT);
        vm.deal(bob, INITIAL_AMOUNT);
        vm.selectFork(arbSepoliaFork);
        vm.deal(alice, INITIAL_AMOUNT);
        vm.deal(bob, INITIAL_AMOUNT);
        _;
    }

    function checkInterestRatesForSenderAndReceiver(
        address _sender,
        address _receiver,
        address _localToken,
        address _remoteToken,
        uint256 _localFork,
        uint256 _remoteFork
    ) public {
        vm.selectFork(_localFork);
        /**
         * vm.prank(user) vs. vm.startPrank(user)/vm.stopPrank():
         * This lesson utilizes single-line vm.prank(user) calls immediately before state-changing operations
         * initiated by the user (e.g., approve, ccipSend). This is preferred over vm.startPrank/vm.stopPrank
         * blocks in scenarios involving external contract calls, such as those made by CCIPLocalSimulatorFork.
         * Using vm.startPrank could lead to the pranked sender context being inadvertently reset or altered by
         * these external calls, complicating the test logic. vm.prank ensures the desired sender context for only
         * that specific call.
         */
        vm.prank(_sender);
        uint256 senderInterestRate = RebaseToken(_localToken).getInterestRate();

        vm.selectFork(_remoteFork);
        vm.prank(_receiver);
        uint256 receiverInterestRate = RebaseToken(_remoteToken)
            .getInterestRate();

        // Compare interest rates
        assertEq(
            senderInterestRate,
            receiverInterestRate,
            "Interest rates do not match"
        );
    }

    function simulateCrossChainMessagePropagationAndVerification(
        uint256 _localFork,
        uint256 _remoteFork,
        address _receiver,
        address _remoteToken,
        uint256 _amountBridged
    ) public {
        vm.selectFork(_remoteFork);

        uint256 remoteBalanceBefore = RebaseToken(_remoteToken).balanceOf(
            _receiver
        );

        // 10. Simulate message propagation to the remote chain
        vm.warp(block.timestamp + 20 minutes); // fast-forward time

        // 11. Process the message on the remote chain
        vm.selectFork(_localFork); // in the latest version of chainlink-local, it assumes you are currently on the local fork before calling switchChainAndRouteMessage
        ccipLocalSimulatorFork.switchChainAndRouteMessage(_remoteFork);

        // 12. Get user's balance on the remote chain
        uint256 remoteBalanceAfter = RebaseToken(_remoteToken).balanceOf(
            _receiver
        );

        assertEq(
            remoteBalanceAfter,
            remoteBalanceBefore + _amountBridged,
            "Remote balance did not increase as expected"
        );
    }

    function initializeBridging(
        uint256 _localFork,
        address _sender,
        address _receiver,
        address _localToken,
        uint256 _amountToBridge,
        Register.NetworkDetails memory _localNetworkDetails,
        Register.NetworkDetails memory _remoteNetworkDetails
    ) public {
        vm.selectFork(_localFork);
        // 1. Initialize token amounts array
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: _localToken,
            amount: _amountToBridge
        });

        // 2. Construct the EVM2AnyMessage ->
        //  struct EVM2AnyMessage {
        //      bytes receiver; // abi.encode(receiver address) for dest EVM chains
        //      bytes data; // Data payload
        //      EVMTokenAmount[] tokenAmounts; // Token transfers
        //      address feeToken; // Address of feeToken. address(0) means you will send msg.value.
        //      bytes extraArgs; // Populate this with _argsToBytes(EVMExtraArgsV2)
        //  }
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver), // In this example, the owner will receive the tokens on the destination chain
            data: abi.encode(""), // No additional data payload is sent in this example
            tokenAmounts: tokenAmounts,
            feeToken: _localNetworkDetails.linkAddress, // Using LINK to pay for CCIP fees
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    // Gas limit for the callback on the destination chain, for the execution of receiver logic,
                    // which may not be needed if you're sending tokens to an EOA.
                    gasLimit: 500_000,
                    allowOutOfOrderExecution: true
                })
            )
        });

        // 3. Get the CCIP fee
        uint256 fee = IRouterClient(_localNetworkDetails.routerAddress).getFee(
            _remoteNetworkDetails.chainSelector,
            message
        );

        // 4. Fund the user with LINK (for testing via CCIPLocalSimulatorFork)
        // This step is specific to the local simulator
        ccipLocalSimulatorFork.requestLinkFromFaucet(_sender, fee);

        /**
         * vm.prank(user) vs. vm.startPrank(user)/vm.stopPrank():
         * This lesson utilizes single-line vm.prank(user) calls immediately before state-changing operations
         * initiated by the user (e.g., approve, ccipSend). This is preferred over vm.startPrank/vm.stopPrank
         * blocks in scenarios involving external contract calls, such as those made by CCIPLocalSimulatorFork.
         * Using vm.startPrank could lead to the pranked sender context being inadvertently reset or altered by
         * these external calls, complicating the test logic. vm.prank ensures the desired sender context for only
         * that specific call.
         */
        vm.prank(_sender);
        // 5. Approve LINK for the Router
        IERC20(_localNetworkDetails.linkAddress).approve(
            _localNetworkDetails.routerAddress,
            fee
        );

        // 6. Approve the actual token to be bridged
        vm.prank(_sender);
        IERC20(_localToken).approve(
            _localNetworkDetails.routerAddress,
            _amountToBridge
        );

        // 7. Get user's balance on the local chain BEFORE sending
        uint256 localBalanceBefore = RebaseToken(_localToken).balanceOf(
            _sender
        );

        // 8. Send the CCIP message
        vm.prank(_sender);
        IRouterClient(_localNetworkDetails.routerAddress).ccipSend(
            _remoteNetworkDetails.chainSelector,
            message
        );

        // 9. Get user's balance on the local chain AFTER sending
        uint256 localBalanceAfter = RebaseToken(_localToken).balanceOf(_sender);

        vm.stopPrank();

        assertEq(
            localBalanceAfter,
            localBalanceBefore - _amountToBridge,
            "Local balance did not decrease as expected"
        );
    }

    // function bridgeTokens(
    //     uint256 _amountToBridge,
    //     uint256 _localFork, // Source chain fork Id
    //     uint256 _remoteFork, // Destination chain fork Id
    //     Register.NetworkDetails memory _localNetworkDetails, // Struct with source chain info
    //     Register.NetworkDetails memory _remoteNetworkDetails, // Struct with dest. chain info
    //     RebaseToken _localToken, // Source token contract instance
    //     RebaseToken _remoteToken // Destination token contract instance
    // ) public {}

    function configureTokenPool(
        uint256 _fork,
        address _localPoolAddress,
        uint64 _remoteChainSelector,
        address _remotePoolAddress,
        address _remoteTokenAddress
    ) public {
        vm.selectFork(_fork);

        // Construct the chainsToAdd array
        TokenPool.ChainUpdate[]
            memory chainsToAdd = new TokenPool.ChainUpdate[](1);

        // Populate the ChainUpdate struct
        // Refer to TokenPool.sol for the ChainUpdate struct definition:
        chainsToAdd[0] = TokenPool.ChainUpdate({
            remoteChainSelector: _remoteChainSelector,
            allowed: true,
            remotePoolAddress: abi.encode(_remotePoolAddress),
            remoteTokenAddress: abi.encode(_remoteTokenAddress),
            // For this example, rate limits are disabled.
            // Consult CCIP documentation for production rate limit configurations.
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false,
                capacity: 0,
                rate: 0
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false,
                capacity: 0,
                rate: 0
            })
        });

        vm.startPrank(owner); // The 'owner' variable should be the deployer/owner of the localPoolAddress
        // Execute applyChainUpdates as the owner
        // applyChainUpdates is typically an owner-restricted function.
        TokenPool(_localPoolAddress).applyChainUpdates(chainsToAdd);
        vm.stopPrank();
    }

    function linkTokensToPool(
        uint256 _fork,
        address _token,
        address _pool,
        TokenAdminRegistry _tokenAdminRegistry
    ) public {
        console2.log("linkTokensToPool", _fork);
        vm.startPrank(owner);
        vm.selectFork(_fork);
        _tokenAdminRegistry.setPool(_token, _pool);
        vm.stopPrank();
    }

    function acceptAdminRole(
        uint256 _fork,
        address _token,
        Register.NetworkDetails memory _networkDetails
    ) public returns (TokenAdminRegistry tokenAdminRegistry) {
        console2.log("acceptAdminRole", _fork);
        vm.startPrank(owner);
        vm.selectFork(_fork);
        tokenAdminRegistry = TokenAdminRegistry(
            _networkDetails.tokenAdminRegistryAddress
        );
        tokenAdminRegistry.acceptAdminRole(_token);
        vm.stopPrank();
    }

    function registerAdminViaOwner(
        uint256 _fork,
        address _token,
        Register.NetworkDetails memory _networkDetails
    ) public {
        console2.log("registerAdminViaOwner", _fork);
        vm.startPrank(owner);
        vm.selectFork(_fork);
        RegistryModuleOwnerCustom(
            _networkDetails.registryModuleOwnerCustomAddress
        ).registerAdminViaOwner(_token);
        vm.stopPrank();
    }

    function grantMintAndBurnRole(
        uint256 _fork,
        RebaseToken _rebaseToken,
        address[] memory _grantees
    ) public {
        console2.log("grantMintAndBurnRole", _fork);
        console2.log("Token:", address(_rebaseToken));
        console2.log("Number of grantees:", _grantees.length);

        vm.startPrank(owner);
        vm.selectFork(_fork);

        for (uint256 i = 0; i < _grantees.length; i++) {
            console2.log("Granting role to:", _grantees[i]);
            _rebaseToken.grantMintAndBurnRole(_grantees[i]);
        }

        vm.stopPrank();
    }

    function deployRebaseTokenPool(
        uint256 _fork,
        address _rebaseToken,
        address _rmnProxy, // The address of the Risk Management Network (RMN) proxy contract for the respective chain.
        address _router // The address of the CCIP Router contract for the respective chain.
    ) public returns (RebaseTokenPool deployedRebaseTokenPool) {
        console2.log("deployRebaseTokenPool", _fork);
        vm.startPrank(owner);
        vm.selectFork(_fork);

        address[] memory allowlist = new address[](0); // No restrictions on who can send tokens cross-chain

        deployedRebaseTokenPool = new RebaseTokenPool(
            IERC20(_rebaseToken),
            allowlist,
            _rmnProxy,
            _router
        );

        vm.stopPrank();
    }

    function deployRebaseToken(
        address _owner,
        uint256 _fork
    ) public returns (RebaseToken deployedRebaseToken) {
        console2.log("deployRebaseToken", _fork);
        vm.startPrank(_owner);
        vm.selectFork(_fork);

        deployedRebaseToken = new RebaseToken();

        vm.stopPrank();
    }

    function deployVault(
        uint256 _fork,
        address _rebaseToken
    ) public returns (Vault deployedVault) {
        console2.log("deployVault", _fork);
        vm.startPrank(owner);
        vm.selectFork(_fork);

        deployedVault = new Vault(IRebaseToken(_rebaseToken));

        vm.stopPrank();
    }

    function testSetUpOk() public view {
        console2.log("testSetUpOk()");
        console2.log("=== Contract Addresses ===");
        console2.log("Vault address:", address(vault));
        console2.log(
            "Sepolia RebaseToken address:",
            address(sepoliaRebaseToken)
        );
        console2.log(
            "Arbitrum Sepolia RebaseToken address:",
            address(arbSepoliaRebaseToken)
        );
        console2.log("Sepolia Pool address:", address(sepoliaPool));
        console2.log("Arbitrum Sepolia Pool address:", address(arbSepoliaPool));
        console2.log(
            "CCIP Simulator address:",
            address(ccipLocalSimulatorFork)
        );
        console2.log("Owner address:", owner);

        console2.log("=== Fork Information ===");
        console2.log("Sepolia Fork ID:", sepoliaFork);
        console2.log("Arbitrum Sepolia Fork ID:", arbSepoliaFork);

        console2.log("=== Network Details ===");
        console2.log("Sepolia Router:", sepoliaNetworkDetails.routerAddress);
        console2.log(
            "Sepolia RMN Proxy:",
            sepoliaNetworkDetails.rmnProxyAddress
        );
        console2.log(
            "Sepolia Chain Selector:",
            sepoliaNetworkDetails.chainSelector
        );
        console2.log(
            "Arbitrum Sepolia Router:",
            arbSepoliaNetworkDetails.routerAddress
        );
        console2.log(
            "Arbitrum Sepolia RMN Proxy:",
            arbSepoliaNetworkDetails.rmnProxyAddress
        );
        console2.log(
            "Arbitrum Sepolia Chain Selector:",
            arbSepoliaNetworkDetails.chainSelector
        );

        console2.log("=== Running Assertions ===");
        assert(address(vault) != address(0));
        assert(address(sepoliaRebaseToken) != address(0));
        assert(address(arbSepoliaRebaseToken) != address(0));
        assert(address(sepoliaPool) != address(0));
        assert(address(arbSepoliaPool) != address(0));
        assert(address(ccipLocalSimulatorFork) != address(0));
        assert(owner != address(0));
        assert(sepoliaNetworkDetails.chainSelector != 0);
        assert(arbSepoliaNetworkDetails.chainSelector != 0);

        console2.log("All setup validations passed!");
    }

    function testBridgeAllTokens() public fundAliceAndBob {
        console2.log("testBridgeAllTokens()");

        // Mint tokens to the owner for testing purposes
        vm.selectFork(sepoliaFork);

        // Configuring pools for bidirectional communication
        // Chain A <-> Chain B)
        // Configure Sepolia pool to interact with Arbitrum Sepolia Pool
        configureTokenPool(
            sepoliaFork,
            address(sepoliaPool),
            arbSepoliaNetworkDetails.chainSelector,
            address(arbSepoliaPool),
            address(arbSepoliaRebaseToken)
        );
        // ...and vice-versa
        configureTokenPool(
            arbSepoliaFork,
            address(arbSepoliaPool),
            sepoliaNetworkDetails.chainSelector,
            address(sepoliaPool),
            address(sepoliaRebaseToken)
        );

        vm.selectFork(sepoliaFork);

        uint256 gasReserve = 1 ether;

        vm.prank(alice);
        vault.deposit{value: INITIAL_AMOUNT - gasReserve}();

        uint256 userInterestRate = sepoliaRebaseToken.getUserInterestRate(
            alice
        );

        uint256 userBalance = sepoliaRebaseToken.balanceOf(alice);

        console2.log(
            "Alice's initial RebaseToken balance on Sepolia:",
            userBalance
        );
        console2.log(
            "Alice's initial interest rate on Sepolia:",
            userInterestRate
        );

        uint256 amountToBridge = AMOUNT_TO_BRIDGE;

        initializeBridging(
            sepoliaFork,
            alice,
            bob, // Bob will receive the tokens on Arbitrum Sepolia
            address(sepoliaRebaseToken),
            amountToBridge,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails
        );

        simulateCrossChainMessagePropagationAndVerification(
            sepoliaFork,
            arbSepoliaFork,
            bob,
            address(arbSepoliaRebaseToken),
            amountToBridge
        );

        checkInterestRatesForSenderAndReceiver(
            alice,
            bob,
            address(sepoliaRebaseToken),
            address(arbSepoliaRebaseToken),
            sepoliaFork,
            arbSepoliaFork
        );
    }
}
