// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {IRebaseToken} from "./interfaces/IRebaseToken.sol";
import {Pool} from "@ccip/contracts/src/v0.8/ccip/libraries/Pool.sol"; // for CCIP structs

contract RebaseTokenPool is TokenPool {
    constructor(
        IERC20 _token,
        address[] memory _allowlist, // List of addresses allowed to send tokens cross chain - Empty array means no restrictions
        address _rmnProxy, // The risk management network proxy address
        address _router // The CCIP router address
    ) TokenPool(_token, _allowlist, _rmnProxy, _router) {
        // Constructor body - if additional logic is needed.
    }

    function lockOrBurn(
        Pool.LockOrBurnInV1 calldata lockOrBurnIn
    ) external override returns (Pool.LockOrBurnOutV1 memory lockOrBurnOut) {
        _validateLockOrBurn(lockOrBurnIn);

        // Fetch the user's current interest rate from the rebase token
        uint256 userInterestRate = IRebaseToken(address(i_token))
            .getUserInterestRate(lockOrBurnIn.originalSender);

        // Burn the specified amount of tokens from this pool contract
        // CCIP router first transfers the user's tokens to this pool contract before lockOrBurn is executed.
        IRebaseToken(address(i_token)).burn(address(this), lockOrBurnIn.amount);

        // Prepare the output for CCIP
        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector), // This is the address of the corresponding token contract on the destination chain
            destPoolData: abi.encode(userInterestRate) // Encode the interest rate to send cross-chain
        });
    }

    function releaseOrMint(
        Pool.ReleaseOrMintInV1 calldata releaseOrMintIn
    )
        external
        override
        returns (Pool.ReleaseOrMintOutV1 memory releaseOrMintOut)
    {
        _validateReleaseOrMint(releaseOrMintIn);

        // Decode the interest rate from the incoming data
        uint256 userInterestRate = abi.decode(
            releaseOrMintIn.sourcePoolData,
            (uint256)
        );

        // Mint token to the receiver, applying the propagated interest rate
        IRebaseToken(address(i_token)).mint(
            releaseOrMintIn.receiver,
            releaseOrMintIn.amount,
            userInterestRate // Pass the interest rate to the rebase token's mint function
        );

        // Prepare the output for CCIP
        releaseOrMintOut = Pool.ReleaseOrMintOutV1({
            destinationAmount: releaseOrMintIn.amount // The number of tokens minted or released in the destination chain, denominated in the local token's decimals.
        });
    }
}
