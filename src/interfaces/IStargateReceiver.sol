// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.0;

interface IStargateReceiver {
    /// @notice triggered when executing a stargate swap by any stargate enabled contract
    /// @param _chainId the layerZero chain ID
    /// @param _srcAddress The remote Bridge address
    /// @param _nonce The message ordering nonce
    /// @param _token The token contract on the local chain
    /// @param amountLD The qty of local _token contract tokens
    /// @param _payload The bytes containing the toAddress
    function sgReceive(
        uint16 _chainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        address _token,
        uint256 amountLD,
        bytes memory payload
    ) external;
}
