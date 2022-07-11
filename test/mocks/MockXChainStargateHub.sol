// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;
import {XChainStargateHub} from "../../src/XChainStargateHub.sol";

/// @title XChainStargateHubMockReducer
/// @dev test the reducer by overriding calls
/// @dev we can't use mockCall because of a forge bug.
///     https://github.com/foundry-rs/foundry/issues/432
contract XChainStargateHubMockReducer is XChainStargateHub {
    uint8 public lastCall;

    constructor(
        address _stargateEndpoint,
        address _lzEndpoint,
        address _refundRecipient
    ) XChainStargateHub(_stargateEndpoint, _lzEndpoint, _refundRecipient) {}

    /// @dev default arg
    function makeMessage(uint8 _action) external pure returns (Message memory) {
        return Message({action: _action, payload: bytes("")});
    }

    /// @dev overload
    function makeMessage(uint8 _action, bytes memory _payload)
        external
        pure
        returns (Message memory)
    {
        return Message({action: _action, payload: _payload});
    }

    /// @notice grant access to the internal reducer function
    function reducer(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        Message memory message
    ) external {
        super._reducer(_srcChainId, _srcAddress, message);
    }

    function _depositAction(uint16, bytes memory) internal override {
        lastCall = DEPOSIT_ACTION;
    }

    function _requestWithdrawAction(uint16, bytes memory) internal override {
        lastCall = REQUEST_WITHDRAW_ACTION;
    }

    function _finalizeWithdrawAction(uint16, bytes memory) internal override {
        lastCall = FINALIZE_WITHDRAW_ACTION;
    }

    function _reportUnderlyingAction(bytes memory) internal override {
        lastCall = REPORT_UNDERLYING_ACTION;
    }
}
