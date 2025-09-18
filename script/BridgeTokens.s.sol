// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script} from "forge-std/Script.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

contract BridgeTokensScript is Script {
    function run(
        address _receiverAddress, // Address receiving tokens on the destination chain
        uint64 _destinationChainSelector, // CCIP selector for the destination chain
        address _tokenToSendAddress, // Address of the ERC20 token being bridged
        uint256 _amountToSend, // Amount of the token to bridge
        address _linkTokenAddress, // Address of the LINK token (for fees) on the source chain
        address _routerAddress // Address of the CCIP Router on the source chain
    ) public {
        vm.startBroadcast();

        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);

        tokenAmounts[0] = Client.EVMTokenAmount({
            token: _tokenToSendAddress,
            amount: _amountToSend
        });

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiverAddress), // In this example, the owner will receive the tokens on the destination chain
            data: abi.encode(""), // No additional data payload is sent in this example
            tokenAmounts: tokenAmounts,
            feeToken: _linkTokenAddress, // Using LINK to pay for CCIP fees
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    // Gas limit for the callback on the destination chain, for the execution of receiver logic,
                    // which may not be needed if you're sending tokens to an EOA.
                    gasLimit: 500_000, // This GAS is used for localCCIP. In real world implementation, you can set this to 0.
                    allowOutOfOrderExecution: true
                })
            )
        });

        uint256 fee = IRouterClient(_routerAddress).getFee(
            _destinationChainSelector,
            message
        );

        // Approve the CCIP Router to spend the fee token (LINK)
        IERC20(_linkTokenAddress).approve(_routerAddress, fee);

        // Approve the CCIP Router to spend the token being bridged
        IERC20(_tokenToSendAddress).approve(_routerAddress, _amountToSend);

        // ccipLocalSimulatorFork.requestLinkFromFaucet(_sender, fee);

        // Although ccipSend is a payable function, we are not sending any native
        // currency (msg.value) with this call because we've specified linkTokenAddress
        // as the feeToken in our message and have approved the LINK tokens.
        // If feeToken were address(0), we would need to send the ccipFee amount as msg.value
        IRouterClient(_routerAddress).ccipSend(
            _destinationChainSelector,
            message
        );

        vm.stopBroadcast();
    }
}
