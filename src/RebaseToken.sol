// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/access/AccessControl.sol";

/**
 * @title RebaseToken
 * @author Fer Enoch
 * @notice This is a cross-chain rebase token that incentivizes users to deposit into a vault and gain interests in reward.
 * @notice The interest rate in the smart contract can only decrease.
 * @notice Each user will have their own interest rate that is the global interest rate at the time of deposit.
 */
contract RebaseToken is ERC20, Ownable, AccessControl {
    //////// errors
    error RebaseToken__InterestRateCanOnlyDecrease(
        uint256 oldInterestRate,
        uint256 newInterestRate
    );

    uint256 private constant PRECISION_FACTOR = 1e18;
    // If `1e18` represents 100%, then `5e10` represents a rate of `(5e10 / 1e18) = 0.00000005` or `0.000005%` per second.
    // The global interest rate -> 0.000005% interest rate per 1 second.
    // We could increase the truncation precision by using a larger scale factor, e.g. `1e27'
    // Then, we'll need to adjust the interest rate accordingly with a formula, e.g. (5 * PRECISION_FACTOR) / 1e8
    // uint256 private s_interestRate = 5e10; // 5 * 10^-8 = 5 * 1 / 10^8
    uint256 private s_interestRate = (5 * PRECISION_FACTOR) / 1e8;
    bytes32 private constant MINT_AND_BURN_ROLE =
        keccak256("MINT_AND_BURN_ROLE"); // This role is used to mint and burn tokens.
    mapping(address => uint256) private s_userInterestRate;
    mapping(address => uint256) private s_userLastUpdatedTimestamp;

    //////// events
    event InterestRateSet(uint256 newInterestRate);

    constructor() ERC20("Rebase Token", "RBT") Ownable(msg.sender) {}

    function grantMintAndBurnRole(address _account) external onlyOwner {
        // The `grantRole` function typically requires the caller to have
        // the admin role for the role being granted (often the `DEFAULT_ADMIN_ROLE`).
        // In our setup, we've bypassed this by allowing the `Ownable` owner to directly call `_grantRole`.
        _grantRole(MINT_AND_BURN_ROLE, _account);
    }

    /**
     * @notice Sets a new interest rate for the contract.
     * @param _newInterestRate The new interest rate to set for the token.
     * @dev The interest rate can only be decreased.
     */
    function setInterestRate(uint256 _newInterestRate) external onlyOwner {
        if (_newInterestRate > s_interestRate) {
            revert RebaseToken__InterestRateCanOnlyDecrease(
                s_interestRate,
                _newInterestRate
            );
        }
        // uint256 oldRate = s_interestRate;
        s_interestRate = _newInterestRate;
        emit InterestRateSet(_newInterestRate);
    }

    /**
     * @notice Returns the principal balance of the user, excluding any accrued interest, i.e.
     * the actual balance of rebase tokens effectively minted, not including any interest that
     * has accrued (but remain unminted) since the last time the user interacted with the protocol.
     * @param _user The address of the user to get the principal balance for.
     * @return The current principal balance of the user.
     */
    function principleBalanceOf(address _user) external view returns (uint256) {
        // This function returns the principal balance of the user, i.e. the actual balance of rebase tokens minted.
        return super.balanceOf(_user);
    }

    /**
     *
     * @notice Mints the user tokens when they deposit into the vault.
     * @dev Also mints accrued interest and locks-in the current global rate for the user.
     * @dev note This sequence ensures fairness and correct accounting: past interest is honored at past rates,
     * while future interest reflects current conditions.
     * @param _to The address to mint the tokens to.
     * @param _amount The principal amount of tokens to mint.
     */
    function mint(
        address _to,
        uint256 _amount,
        uint256 _interestRate
    ) external onlyRole(MINT_AND_BURN_ROLE) {
        // 1. We settle any existing accrued interest for the user.
        // This calculation users the interest rate that was applicable to their existing deposit.
        // s_userLastUpdatedTimestamp is also updated.
        _mintAccruedInterest(_to);

        // 2. Update the user's interest rate for future calculations if necessary.
        // This is an important design choice:
        // - For first time depositors, the interest rate is set to the current global interest rate.
        // - For users who already have a deposit, the global interest rate WILL be changed (e.g. [note ->] decreased).
        // This design can incentivize early or large deposits when rates are favorable (e.g. as early as possible).
        s_userInterestRate[_to] = _interestRate;

        // 3. Mint the newly deposited amount
        _mint(_to, _amount);
    }

    /**
     * @notice Burn the user's tokens when they withdraw from a vault or for cross-chain transfers.
     * @dev Handles burning the entire balance if _amount is type(uint256).max.
     * @param _from The address to burn the tokens from.
     * @param _amount The amount of tokens to burn.
     */
    function burn(
        address _from,
        uint256 _amount
    ) external onlyRole(MINT_AND_BURN_ROLE) {
        // Common pattern in defi: if the amount is max, we burn the entire balance of the user. It allows users to withdraw
        // or interact with their full holdings without needing to calculate the exact, potentially dust-affected, amount off-chain.
        // This is useful for when the user wants to withdraw all their tokens and there's "dust" - accumulated interest
        // during the time elapsed since the transaction was initialized and the transaction is settled. This helps to mitigate
        // against dust. So if the user wants to
        // withdraw all their tokens, they would do it without having to worry about the small remnants.
        uint256 amountToBurn = _amount;
        if (_amount == type(uint256).max) {
            // We update `_amount` to be the user's current total balance, including any just-in-time accrued interest
            amountToBurn = balanceOf(_from);
        }

        // Before burning nay tokens, we ensure the user's principal balance is up-to-date.
        // (we also update user's last updated timestamp)
        // Enrure _amount does not exceed balance after potential interest accrual.
        // This check is important especially if _amount wasn't type(uint256).max.
        // _mintAccruedInterest will update the super.balanceOf(_from) to include any accrued interest.
        // So, after _mintAccruedInterest, super.balanceOf(_from) should be currentToralBalance.
        // The ERC20 _burn function will typically revert if _amount > super.balanceOf(_from),
        _mintAccruedInterest(_from);

        // Internal function inhereted from ERC20 standard.
        // At this point, super.balanvceOf(_from) reflects the balance including all interest up to now.
        // If _aomunt was type(uint256).max, at this point -> _amount = super.balanceOf(_from)
        // If _amount was a specific value, super.balanceOf(_from) must be >= _amount for _burn to succeed.
        _burn(_from, amountToBurn);
    }

    /**
     * @notice Calculates the user's balance including the interest accumulated since the last update,
     * e.g. principle balance + some interest that has accrued.
     * The formula used is the linear, simple interest formula: A = P * (1 + rt),
     * where:
     *   - A is the final amount (balance of the user).
     *   - P is the principal amount (the actual balance of rebase tokens minted).
     *   - r is the interest rate (the user's interest rate).
     *   - t is the time elapsed since the last update (in seconds).
     * The formula can be rearranged to:
     *   balanceOf(_user) = principalBalance * (1 + (interestRate * timeElapsed / scaleFactor))
     * where:
     *   - principalBalance is the actual balance of rebase tokens minted.
     *   - interestRate is the user's interest rate.
     *   - timeElapsed is the time elapsed since the last update.
     *   - scaleFactor is a precision factor to ensure the interest rate is applied correctly.
     * Note that a known issue with this approach is that users who frequently trigger the _mintAccruedInterest function
     * (for example, through many small transfers or burns) would experience a more rapid compounding of their interest
     * compared to a scenario where interest is strictly calculated only on their initial principal.
     * This behavior, while not necessarily critical, diverges from a strictly linear interest model.
     * @param _user The address of the user to calculate the interest for.
     * @return The balance of the user including the interest accumulated since the last update.
     */
    function balanceOf(address _user) public view override returns (uint256) {
        // Get the user's principal balance (the actual balance of rebase tokens minted)
        uint256 principalBalance = super.balanceOf(_user);

        uint256 growthFactor = _calculateAccumulatedInterestSinceLastUpdate(
            _user
        );

        // Multiply the user's principal balance by the user's interest rate accumulated
        // Remember PRECISION_FACTOR is used for scaling, so we divide by it here.
        // A note on precision: always be mindful of potential overflows. We multiply and then divide,
        // to ensure we don't lose precision in the calculations. This is safe if principalBalance and growthFactor
        // are within reasonable limits such that their product does not exceed the uint256's maximum value.
        return (principalBalance * growthFactor) / PRECISION_FACTOR;
    }

    /**
     * @notice Transfers tokens from the caller to a recipient.
     * Accrued interest for both sender and recipient is minted before the transfer.
     * If the recipient is new (has zero balance), they inherit the sender's interest rate.
     * @param _recipient The address to transfer the tokens to.
     * @param _amount The amount of tokens to transfer. Can be type(uint256).max to transfer full balance.
     * @return A boolean indicating whether the transfer was successful.
     */
    function transfer(
        address _recipient,
        uint256 _amount
    ) public override returns (bool) {
        // Before transferring, we need to mint the accrued interest to both the sender and recipient.
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recipient);

        // Handle request to transfer the maximum balance.
        if (_amount == type(uint256).max) {
            // If the amount is max, we transfer the entire interest-inclusive balance of the user.
            _amount = balanceOf(msg.sender);
        }

        // Set recipient's interest rate if they are new (balance is checked before super.transfer).
        // The logic is: if they *effective* balance is 0 before the main transfer part, they get the sender's rate.
        if (balanceOf(_recipient) == 0 && _amount > 0) {
            // Ensure _amount > 0 to avoid setting rate on 0 value initial transfer.
            // If the recipient has no balance, we set their interest rate to the current user's interest rate.
            s_userInterestRate[_recipient] = s_userInterestRate[msg.sender];
        }

        // Call the super transfer function to transfer the tokens.
        return super.transfer(_recipient, _amount);
    }

    /**
     * @notice Transfers tokens from one address to another, on behalf of the sender..
     * Accrued interest for both sender and recipient is minted before the transfer.
     * If the recipient is new (has zero balance), they inherit the sender's interest rate.
     * @param _sender The address to transfer tokens from.
     * @param _recipient The address to transfer tokens to.
     * @param _amount The amount of tokens to transfer. Can be type(uint256).max to transfer full balance.
     * @return A boolean indicating whether the operation succeeded.
     */
    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public override returns (bool) {
        // Before transferring, we need to mint the accrued interest to both the sender and recipient.
        _mintAccruedInterest(_sender);
        _mintAccruedInterest(_recipient);

        if (_amount == type(uint256).max) {
            // If the amount is max, we transfer the entire interest-inclusive balance of the _sender.
            _amount = balanceOf(_sender);
        }

        // Set recipient's interest rate if they are new
        if (balanceOf(_recipient) == 0 && _amount > 0) {
            // If the recipient has no balance, we set their interest rate to the current user's interest rate.
            s_userInterestRate[_recipient] = s_userInterestRate[_sender];
        }

        return super.transferFrom(_sender, _recipient, _amount);
    }

    /**
     * @notice Calculates growth factor (accumulated interest) rate since the last update for a user.
     * @param _user The address of the user to calculate the interest for.
     * @return linearInterest -> The growth factor, scaled by the PRECISION_FACTOR.
     */
    function _calculateAccumulatedInterestSinceLastUpdate(
        address _user
    ) internal view returns (uint256 linearInterest) {
        // We need to calculate the interest that has accumulated since the last update.
        // This is goin to be linear growth with time
        // 1. calculate the time elapsed since the last update
        // 2. calculate the amount of linear growth that has occurred since the last update
        // FORMULA:
        //  accumulatedInterestRate = principalBalance * (1 + (interestRate * timeElapsed / scaleFactor))
        // For example, if the interest rate is 5% per second, we got 15 tokens, and the time elapsed is 10 seconds,
        // the accumulated interest rate would be:
        //  accumulatedInterestRate = 15 * (1 + (0.05 * 10)) = 15 * (1 + 0.5) = 15 * 1.5 = 22.5
        // After 10 seconds, the user would have 22.5 tokens in total.
        // This means that the user would have gained 7.5 tokens in interest.
        // Note: The interest rate is assumed to be in a scale factor of 1e10, so we need to adjust the calculation accordingly.
        //
        // An equivalent formula for the accumulated interest rate is:
        //  accumulatedInterestRate = principalBalance + (principalBalance * interestRate * timeElapsed)
        // Following the same example:
        //  accumulatedInterestRate = 15 + (15 * 0.05 * 10) = 15 + (15 * 0.5) = 15 + 7.5 = 22.5

        // Calculate the time elapsed since the last update
        uint256 timeElapsed = block.timestamp -
            s_userLastUpdatedTimestamp[_user];

        // If the time elapsed is 0 or the user has no interest rate (e.g. never interacted), the growth factor is
        // simply 1 (scaled by the precision factor)
        // This means that no interest has accumulated since the last update.
        if (timeElapsed == 0 || s_userInterestRate[_user] == 0) {
            return PRECISION_FACTOR;
        }

        // Get the user's interest rate
        uint256 userInterestRate = s_userInterestRate[_user];

        // Calculate the total fractional interest accrued: userInterestRate * TimeElapsed
        // The product is already scaled properly if userInterestRate is stored scaled.
        // Formula for the growth factor: 1 + totallFractionalInterestAccrued
        // Since 1 is represented by PRECISION_FACTOR, and fractionalInterest is already scaled, we add them directly.
        linearInterest = PRECISION_FACTOR + (userInterestRate * timeElapsed);
    }

    /**
     * @notice This function mints the accrued interest to the user since the last time they interacted with the protocol
     * (e.g. burn, mint, transfer, bridging).
     * @dev This function synchronizes a user's on-chain principal balance with their current balance (which inclusdes accrued
     * interest) BEFORE anu other balance-altering operation (e.g. transfer, burn, mint) occurs.
     * @dev Updates the user's last updated timestamp.
     * @dev It calculates the user's balance to increase, i.e. the tokens they are entitled to be minted,
     * @dev This function follows the C.E.I. pattern by updating state variable BEFORE external calls or interactions (like _mint).
     * @param _user The address of the user to mint the accrued interest for.
     */
    function _mintAccruedInterest(address _user) internal {
        // (1) Find their current balance of rebase tokens that have been minted to the user -> the principal balance
        uint256 previoustPrincipleBalance = super.balanceOf(_user);

        // (2)  balanceOf -> Dinamically calculates their current balance including any interest:
        //     - This is done by adding the principal balance (actual balance of rebase tokens minted)
        //     to any rebase tokens pending to mint (tokens the user is entitled to).
        uint256 currentBalance = balanceOf(_user);

        // (3) Calculate interest (the number of tokens) that need to be minted to the user -> (2) - (1)
        uint256 balanceIncrease = currentBalance - previoustPrincipleBalance;

        // (4) Set the user's last updated timestamp (Effect):
        // Before minting, we update the user's last interaction timestamp.
        s_userLastUpdatedTimestamp[_user] = block.timestamp;

        // (5) Call _mint (inhereted from ERC20 contract) to mint the tokens to the user (Interaction):
        // Common good practice and optimization: only mint if there is an increase in balance.
        if (balanceIncrease > 0) {
            _mint(_user, balanceIncrease);
        }
    }

    /**
     * @notice Gets the current interest rate of the token..
     * Any future deposits will be made at this interest rate.
     * @return The current interest rate of the contract.
     */
    function getInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    /**
     * @notice Gets the current interest rate of the user.
     * @param _user The address of the user to get the interest rate for.
     * @return The interest rate of the user.
     */
    function getUserInterestRate(
        address _user
    ) external view returns (uint256) {
        return s_userInterestRate[_user];
    }
}
