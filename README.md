# Cross-chain Rebase Token

### Protocol Overview

The fundamental idea is to create a system where users can deposit an underlying asset (for example, ETH or a stablecoin like WETH) into a central smart contract, which we'll refer to as the `Vault`. In exchange for their deposit, users receive `rebase tokens`. These `rebase tokens` are special; they represent the user's proportional share of the total underlying assets held within the `Vault`, including any interest or rewards that accrue over time.

### Key Features

1. A protocol that allows users to deposit into a vault and in return, receive rebase tokens that represent their underlying assets.
2. Rebase token -> balanceOf function is dynamic to show the changing balance with time.
    - Is a View Function (Gas Efficiency)
    - Balance increases linearly with time.
    - State Update (i.e., updating the user's on-chain token amount) on Interaction: mint tokens to our users *before* they perform an interaction (depositing, minting, withdrawing/redeeming, burning, transferring, or bridging).
3. Interest rate model: Rewarding early adopters.
    - User-specific interest rate snapshot: individually set an interest rate of each user based on some global interest rate of the protocol at the time the user deposits into the vault.
    - Decreasing global Rate is a key design choice: the global interest rate can only decrease to incentivise/reward early adopters.
    - The "interest" is primarily a function of the rebase mechanism itself, designed to increase token adoption by directly rewarding token holders with more tokens over time.

### The totalSupply() Dillemma: Accuracy vs. Gas Efficiency
#### Decision: we WIL NOT OVERRIDE the totalSupply() ERC20 standard function. So, this function will return the sum of principal balances only (i.e., tokens that have been explicitly minted vía the _mint function). This means the totalSupply() will not represent the true economic supply of the token, which includes unmaterialized interest. This is a deliberate design trade-off to avoid excesive gas costs and potential DoS vulnerabilities. This "inaccuracy" is a known characteristic of this specific protocol implementation.

### A note about roles
*Design Note on Granting Roles:* Why not grant the *MINT_AND_BURN_ROLE* role directly in the constructor to the deployer? In many scenarios, the address needing this role (e.g., a Vault contract) might not exist at the time of `RebaseToken` deployment, or there might be circular dependencies if both contracts need each other's addresses in their constructors. Deploying the token, then the vault, and then calling `grantMintAndBurnRole` with the vault's address is a common and cleaner pattern.

### Security Considerations and Design Rationale

* **Centralization Risk with** **`Ownable`** **and Role Granting:**
In our current implementation, the `owner` (established by `Ownable`) has the power to call `grantMintAndBurnRole`. This means the owner can grant the powerful `MINT_AND_BURN_ROLE` to any address, including their own. This gives the owner significant control over the token supply, which could be a point of centralization and potential misuse.


## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
