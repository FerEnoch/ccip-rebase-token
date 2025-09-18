// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {IAccessControl} from "@openzeppelin/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Vault} from "../src/Vault.sol";
import {Test} from "forge-std/Test.sol";

contract RebaseTokenTest is Test {
    RebaseToken private rebaseToken;
    Vault private vault;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");

    uint256 constant VAULT_INITIAL_SUPPLY = 1e18; // 1 ether

    function setUp() public {
        // Impersonate the "owner" address for deployments and role granting
        vm.startPrank(owner);
        vm.deal(owner, 1e18);

        rebaseToken = new RebaseToken();

        // Deploy Vault: requires IRebaseToken.abi
        // Direct casting -IRebaseToken(rebaseToken)- is invalid.
        // The correct way: cast rebaseToken to address, then to IRebaseToken.
        vault = new Vault(IRebaseToken(address(rebaseToken)));

        // Grant the MINT_AND_BURN_ROLE to the Vault contract
        // The grantMintAndBurnRole function expects an address.
        rebaseToken.grantMintAndBurnRole(address(vault));

        // Stop impersonating the owner
        vm.stopPrank();
    }

    function addRewardsToVault(uint256 rewardAmount) internal {
        // Send 1 ETH (1e18) to the Vault to simulate initial funds.
        // The target address must be cast to payable
        (bool success, ) = payable(address(vault)).call{value: rewardAmount}(
            ""
        );
        require(success, "Failed to send initial ETH to Vault");
    }

    function testDepositLinear(uint256 amount) public {
        // Constrain the fuzzed "amount" to a practical range
        // Min: 0.00001 ETH (1e5 WEI - 100,000), Max: type(uint96).max to avoid overflows.
        amount = bound(amount, 1e5, type(uint96).max);

        // User deposits "amount" ETH into the Vault
        vm.startPrank(user);
        vm.deal(user, amount);

        // Check initial rebase token balance for 'user'
        uint256 initialRebaseTokenBalance = rebaseToken.balanceOf(user);

        vm.assertEq(
            initialRebaseTokenBalance,
            0,
            "User should start with 0 RebaseTokens"
        );

        // Implement deposit logic:
        vault.deposit{value: amount}();

        uint256 rebaseTokenBalanceAfterDeposit = rebaseToken.balanceOf(user);

        uint256 expectedRebaseTokenBalance = amount; // 1:1 peg assumed and no time passed yet
        vm.assertEq(
            rebaseTokenBalanceAfterDeposit,
            expectedRebaseTokenBalance,
            "RebaseToken balance should match deposited ETH"
        );

        // Warp time forward and check balance again
        uint256 timeDelta = 1 days;
        vm.warp(block.timestamp + timeDelta);

        uint256 balanceAfterFirstWarp = rebaseToken.balanceOf(user);
        uint256 interestFirstPeriod = balanceAfterFirstWarp -
            rebaseTokenBalanceAfterDeposit;
        vm.assertGt(
            interestFirstPeriod,
            0,
            "User should earn interest over time"
        );

        // Warp the time for another period to determine if interest accrual is linear
        vm.warp(block.timestamp + timeDelta);
        uint256 balanceAfterSecondWarp = rebaseToken.balanceOf(user);
        uint256 interestSecondPeriod = balanceAfterSecondWarp -
            balanceAfterFirstWarp;

        // TODO: Assert that interestFirstPeriod == interestSecondPeriod for linear accrual.
        // We need the delta of 1 wei due to truncation!
        assertApproxEqAbs(interestFirstPeriod, interestSecondPeriod, 1);

        vm.stopPrank();
    }

    function testRedeemStraightAway(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);

        vm.deal(user, amount);

        // User redeems 100% of their RebaseTokens for ETH
        vm.startPrank(user);

        vault.deposit{value: amount}();

        vault.redeem(type(uint256).max); // Redeem all RebaseTokens

        uint256 rebaseTokenBalanceAfterRedeem = rebaseToken.balanceOf(user);
        vm.assertEq(
            rebaseTokenBalanceAfterRedeem,
            0,
            "User should have 0 RebaseTokens after redeeming"
        );

        uint256 userBalanceAfterRedeem = user.balance;
        vm.assertEq(
            userBalanceAfterRedeem,
            amount,
            "User should receive the equivalent amount of ETH after redeeming"
        );

        vm.stopPrank();
    }

    function testRedeemAfterTimePassed(
        uint256 depositAmount,
        uint256 time
    ) public {
        time = bound(time, 1000, type(uint96).max); // this type means maximum time -> 2.5 + 10^21 years!!
        depositAmount = bound(depositAmount, 1e5, type(uint96).max); // This is a ridiculous amount of ETH

        vm.deal(user, depositAmount);

        vm.prank(user);
        // User deposits some ETH into the Vault
        vault.deposit{value: depositAmount}();

        // Warp time forward
        vm.warp(block.timestamp + time);

        uint256 userBalanceAfterSomeTime = rebaseToken.balanceOf(user);

        // Add the rewards to the Vault
        vm.deal(owner, userBalanceAfterSomeTime - depositAmount);
        vm.startPrank(owner);

        addRewardsToVault(userBalanceAfterSomeTime - depositAmount); // Add 10% of the user's earnings
        vm.startPrank(user);

        // User redeems all RebaseTokens for ETH
        vault.redeem(type(uint256).max);

        uint256 rebaseTokenBalanceAfterRedeem = rebaseToken.balanceOf(user);

        vm.assertEq(
            rebaseTokenBalanceAfterRedeem,
            0,
            "User should have 0 RebaseTokens after redeeming"
        );

        uint256 userBalanceAfterRedeem = user.balance;

        assertGt(
            userBalanceAfterRedeem,
            depositAmount,
            "User should receive more ETH than deposited due to interest accrual"
        );

        vm.stopPrank();
    }

    function testTransfer(uint256 amount, uint256 amountToSend) public {
        amount = bound(amount, 1e5 + 1e5, type(uint96).max);
        amountToSend = bound(amountToSend, 1e5, amount - 1e5);

        vm.deal(user, amount);
        vm.startPrank(user);
        vault.deposit{value: amount}();

        address user2 = makeAddr("user2");
        uint256 userBalanceBeforeTransfer = rebaseToken.balanceOf(user);
        uint256 user2BalanceBeforeTransfer = rebaseToken.balanceOf(user2);
        assertEq(
            userBalanceBeforeTransfer,
            amount,
            "User should have the full RebaseToken balance after deposit"
        );
        assertEq(
            user2BalanceBeforeTransfer,
            0,
            "User2 should start with 0 RebaseTokens"
        );

        // Owner reduces the interest rate
        vm.startPrank(owner);
        rebaseToken.setInterestRate(4e10); // 4% interest rate

        // 2. transfer
        vm.startPrank(user);
        rebaseToken.transfer(user2, amountToSend);
        uint256 userBalanceAfterTransfer = rebaseToken.balanceOf(user);
        uint256 user2BalanceAfterTransfer = rebaseToken.balanceOf(user2);
        assertEq(
            userBalanceAfterTransfer,
            userBalanceBeforeTransfer - amountToSend,
            "User should have reduced RebaseToken balance after transfer"
        );
        assertEq(
            user2BalanceAfterTransfer,
            user2BalanceBeforeTransfer + amountToSend,
            "User2 should have increased RebaseToken balance after transfer"
        );

        // Check the user interest rate after transfer (has been inherited)
        assertEq(
            rebaseToken.getUserInterestRate(user),
            5e10,
            "User's interest rate should remain unchanged after transfer"
        );

        assertEq(
            rebaseToken.getUserInterestRate(user2),
            5e10,
            "User2's should have inherited the interest rate from the user"
        );

        vm.stopPrank();
    }

    function testCannotSetInteresRate(uint256 newInterestRate) public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                // bytes4(keccak256("OwnableUnauthorizedAccount(address)")),
                Ownable.OwnableUnauthorizedAccount.selector,
                user
            )
        );
        rebaseToken.setInterestRate(newInterestRate);
    }

    function testCannotCallMint(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);

        vm.deal(user, amount);
        vm.startPrank(user);

        uint256 userInterestRate = rebaseToken.getUserInterestRate(user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                keccak256("MINT_AND_BURN_ROLE")
            )
        );

        rebaseToken.mint(user, amount, userInterestRate);

        vm.stopPrank();
    }

    function testCannotCallBurn(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);

        vm.deal(user, amount);
        vm.startPrank(user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                keccak256("MINT_AND_BURN_ROLE")
            )
        );

        rebaseToken.burn(user, amount);

        vm.stopPrank();
    }

    function testPrincipalAmount(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);

        vm.deal(user, amount);
        vm.startPrank(user);

        // User deposits some ETH into the Vault
        vault.deposit{value: amount}();

        // Check the principal amount
        uint256 principalAmount = rebaseToken.principleBalanceOf(user);
        assertEq(
            principalAmount,
            amount,
            "Principal amount should match the deposited ETH"
        );

        vm.warp(block.timestamp + 1 hours);
        assertEq(
            rebaseToken.principleBalanceOf(user),
            amount,
            "Principal amount should remain unchanged after time warp"
        );

        vm.stopPrank();
    }

    function testGetRebaseTokenAddress() public view {
        // Check if the Vault can retrieve the RebaseToken address correctly
        address rebaseTokenAddress = vault.getRebaseTokenAddress();
        assertEq(
            rebaseTokenAddress,
            address(rebaseToken),
            "Vault should return the correct RebaseToken address"
        );
    }

    function testInterestRateCanOnlyDecrease(uint256 newInterestRate) public {
        uint256 initialInterestRate = rebaseToken.getInterestRate();

        newInterestRate = bound(
            newInterestRate,
            initialInterestRate + 1,
            type(uint96).max
        );
        vm.startPrank(owner);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "RebaseToken__InterestRateCanOnlyDecrease(uint256,uint256)"
                    )
                ),
                initialInterestRate,
                newInterestRate
            )
        );
        rebaseToken.setInterestRate(newInterestRate);

        assertEq(
            rebaseToken.getInterestRate(),
            initialInterestRate,
            "Interest rate should remain unchanged after failed increase attempt"
        );
        vm.stopPrank();
    }
}
