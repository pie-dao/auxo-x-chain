// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;
pragma abicoder v2;

import "forge-std/Script.sol";

import {XChainStrategyStargate} from "src/strategy/XChainStrategyStargate.sol";
import {XChainStargateHub} from "src/XChainStargateHub.sol";

import {IVault} from "src/interfaces/IVault.sol";

/// @title shared logic for cross chain deploys
contract XChainHubOptimism is Script {
    address constant stargateRouter =
        0xCC68641528B948642bDE1729805d6cf1DECB0B00;
    address constant lzEndpoint = 0x72aB53a133b27Fa428ca7Dc263080807AfEc91b5;
    address constant refundRecipient =
        0x63BCe354DBA7d6270Cb34dAA46B869892AbB3A79;

    address constant owner = refundRecipient;

    uint16 _dstChainIdArbtrium = 10010;

    address constant hubAddress = 0x5417B42215921b129Aa13a2A54661B6b0E4F87Fe;
    address constant vaultAddr = 0xaF29Ba76af7ef547b867ebA712a776c61B40Ed02;
    address constant vaultAddrDst = 0x2E05590c1B24469eAEf2B29c6c7109b507ec2544;
    address constant stratAddr = 0xdE3D13189F8ea601868402E9071d21c6544B8be3;
    address constant hubDstAddr = 0x69b8C988b17BD77Bb56BEe902b7aB7E64F262F35;

    XChainStargateHub public hub;
    IVault public vault;
    XChainStrategyStargate public strat;

    function trustVault() public {
        vm.broadcast(refundRecipient);
        // trust the vault from the hub
        hub.setTrustedVault(address(vault), true);
    }

    function trustedRemote() public {
        // set trusted remote
        // TODO reploy this on destChain
        bytes memory _hubDst = abi.encodePacked(hubDstAddr);
        vm.broadcast(owner);
        hub.setTrustedRemote(_dstChainIdArbtrium, _hubDst);
    }

    function run() public {
        hub = XChainStargateHub(hubAddress);
        vault = IVault(vaultAddr);
        strat = XChainStrategyStargate(stratAddr);

        // need to add a way to set a trusted strategy
        //hub.setTrustedStrategy(stratAddr, true);
        vm.broadcast(owner);
        strat.depositUnderlying{value: 1 ether}(
            1e9,
            0,
            XChainStrategyStargate.DepositParams(
                _dstChainIdArbtrium,
                1,
                1,
                hubDstAddr,
                vaultAddrDst,
                payable(refundRecipient)
            )
        );
    }
}
