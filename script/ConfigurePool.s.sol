// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@ccip/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";

contract ConfigurePool is Script {
    function run(
        address _localPool,
        uint64 _remoteChainSelector,
        address _remotePool,
        address _remoteToken,
        bool _outboundRateLimiterIsEnabled,
        uint128 _outboundRateLimiterCapacity,
        uint128 _outboundRateLimiterRate,
        bool _inboundRateLimiterIsEnabled,
        uint128 _inboundRateLimiterCapacity,
        uint128 _inboundRateLimiterRate
    ) public {
        vm.startBroadcast();
        // Construct the chainsToAdd array
        TokenPool.ChainUpdate[]
            memory chainsToAdd = new TokenPool.ChainUpdate[](1);

        // Populate the ChainUpdate struct
        // Refer to TokenPool.sol for the ChainUpdate struct definition:
        chainsToAdd[0] = TokenPool.ChainUpdate({
            remoteChainSelector: _remoteChainSelector,
            allowed: true,
            remotePoolAddress: abi.encode(_remotePool),
            remoteTokenAddress: abi.encode(_remoteToken),
            // For this example, rate limits are disabled.
            // Consult CCIP documentation for production rate limit configurations.
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: _outboundRateLimiterIsEnabled,
                capacity: _outboundRateLimiterCapacity,
                rate: _outboundRateLimiterRate
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: _inboundRateLimiterIsEnabled,
                capacity: _inboundRateLimiterCapacity,
                rate: _inboundRateLimiterRate
            })
        });

        // applyChainUpdates is typically an owner-restricted function.
        TokenPool(_localPool).applyChainUpdates(chainsToAdd);

        vm.stopBroadcast();
    }
}
