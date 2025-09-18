// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

contract Vault {
    // Core Requirements:
    // 1. Store the address of the RebaseToken contracto (passed in the constructor)
    // 2. Implement the "deposit" function:
    //   - Accepts ETH from the user
    //   - Mints RebaseTonkens to the user, equivalent to the ETH sent (1:1 peg, initially -> 1 WEI = 1 RebaseToken)
    // 3. Implement a "redeem" function:
    //   - Burns the users RebaseTokens
    //   - Sends the corresponding amount of ETH back to the user
    // 4. Implement a mechanism to add ETH rewards to the vault.

    IRebaseToken private immutable REBASE_TOKEN;

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);

    error Vault_RedeemFailed();

    constructor(IRebaseToken _rebaseToken) {
        REBASE_TOKEN = _rebaseToken;
    }

    /**
     * @notice Fallback function to accept ETH rewards sent directly to the contract.
     * Any ETH sent this way simply increases the contract's balance.
     * This ETH can then be considered part of the rewards pool
     * While this is a simplified mechanism, in a production environment, you might incorporate more sophisticated logic,
     * such as access controls on who can send rewards or mechanisms for tracking different types of rewards
     * @dev Any ETH sent to this contract's address without data will be accepted.
     */
    receive() external payable {}

    /**
     * @notice Allows a user to deposit ETH and receive an equivalent amount of RebaseTokens.
     * @dev The amount of ETH sent with the transaction (msg.value) determines the amount of tokens minted.
     * Assumes a 1:1 peg for ETH to RebaseToken for simplicity in this version (e.g. 1 WEI = 1 RebaseToken).
     */
    function deposit() external payable {
        // The amount of ETH is sent with msg.value
        // The user making the call is msg.sender
        uint256 amountToMint = msg.value;

        if (amountToMint == 0) {
            revert("Vault_DepositAmountIsZero"); // Consider adding a custom error
        }

        // Call the mint function on the RebaseToken contract
        uint256 interestRate = REBASE_TOKEN.getInterestRate();
        REBASE_TOKEN.mint(msg.sender, amountToMint, interestRate);

        // Emit an event to log the deposit
        emit Deposit(msg.sender, amountToMint);
    }

    /**
     * @notice Allows a user to redeem their RebaseTokens for ETH.
     * @dev Burns the specified amount of RebaseTokens from the caller
     * @param _amount The amount of RebaseTokens to redeem. If set to type(uint256).max, it redeems the user's entire balance.
     */
    function redeem(uint256 _amount) external {
        uint256 amountToRedeem = _amount;
        if (amountToRedeem == type(uint256).max) {
            amountToRedeem = REBASE_TOKEN.balanceOf(msg.sender);
        }

        // 1. Effects (State changes occur first)
        // Burn the specified amount of tokens from the caller (msg.sender)
        // The RebaseToken's burn function should handle checks for sufficient balance.
        REBASE_TOKEN.burn(msg.sender, amountToRedeem);

        // 2. Interactions (External calls occur after state changes)
        // Transfer the equivalent _amount of WEI to msg.sender
        (bool success, ) = payable(msg.sender).call{value: amountToRedeem}("");
        if (!success) {
            revert Vault_RedeemFailed();
        }

        // Emit an event logging the redemption
        emit Redeem(msg.sender, _amount);
    }

    /**
     * @notice Gets the address of the RebaseToken contract associated with this vault.
     * @return The address of the RebaseToken.
     */
    function getRebaseTokenAddress() external view returns (address) {
        return address(REBASE_TOKEN);
    }
}
