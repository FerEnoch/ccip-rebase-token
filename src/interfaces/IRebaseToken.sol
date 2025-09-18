// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Note We only include functions that the Vault contract will call.
 * Other functions from the actual RebaseToken contract are not needed here.
 */
interface IRebaseToken {
    /**
     * @notice Grants the mint and burn role to a specified address.
     * @param account The address to grant the mint and burn role to.
     */
    function grantMintAndBurnRole(address account) external;

    /**
     * @notice Mints new tokens to a specified address.
     * @param to The address to mint tokens to.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount, uint256 interestRate) external;

    /**
     * @notice Burns tokens from a specified address.
     * @param from The address to burn tokens from.
     * @param amount The amount of tokens to burn.
     */
    function burn(address from, uint256 amount) external;

    /**
     * @notice Returns the balance of rebase tokens for a specified address.
     * @param account The address to query the balance of.
     * @return The balance of rebase tokens for the specified address.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @notice Returns the total supply of rebase tokens.
     * @return The total supply of rebase tokens.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Returns the user interest rate for a specified address.
     * @param account The address to query the interest rate of.
     * @return The user interest rate for the specified address.
     */
    function getUserInterestRate(
        address account
    ) external view returns (uint256);

    /**
     * @notice Returns the current global interest rate.
     * @return The current global interest rate.
     */
    function getInterestRate() external view returns (uint256);
}
