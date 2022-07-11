// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;
import {XChainStargateHub} from "../../src/XChainStargateHub.sol";
import {IStargateRouter} from "../../src/interfaces/IStargateRouter.sol";
import {IHubPayload} from "../../src/interfaces/IHubPayload.sol";

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
    function makeMessage(uint8 _action)
        external
        pure
        returns (IHubPayload.Message memory)
    {
        return IHubPayload.Message({action: _action, payload: bytes("")});
    }

    /// @dev overload
    function makeMessage(uint8 _action, bytes memory _payload)
        external
        pure
        returns (IHubPayload.Message memory)
    {
        return IHubPayload.Message({action: _action, payload: _payload});
    }

    /// @notice grant access to the internal reducer function
    function reducer(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        IHubPayload.Message memory message
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

    /// @notice wrap the inner function and capture an event
    function requestWithdrawFromChainMockCapture(
        uint16 dstChainId,
        address dstVault,
        uint256 amountVaultShares,
        bytes memory adapterParams,
        address payable refundAddress
    ) external {
        this.requestWithdrawFromChain(
            dstChainId,
            dstVault,
            amountVaultShares,
            adapterParams,
            refundAddress
        );
    }
}

/// @dev this contract overrides the _lzSend method. Instead of forwarding the message
///     to a mock Lz endpoint, we just store the calldata in a public array.
///     This makes it easy to check that the payload was encoded as expected in unit tests.
///     You will want to setup separate tests with LZMocks to test cross chain interop.
contract XChainStargateHubMockLzSend is XChainStargateHub {
    bytes[] public payloads;
    address payable[] public refundAddresses;
    address[] public zroPaymentAddresses;
    bytes[] public adapterParams;

    constructor(
        address _stargateEndpoint,
        address _lzEndpoint,
        address _refundRecipient
    ) XChainStargateHub(_stargateEndpoint, _lzEndpoint, _refundRecipient) {}

    /// @notice intercept the layerZero send and log the outgoing request
    function _lzSend(
        uint16 _dstChainId,
        bytes memory _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes memory _adapterParams
    ) internal override {
        bytes memory trustedRemote = trustedRemoteLookup[_dstChainId];

        require(
            trustedRemote.length != 0,
            "LayerZeroApp: destination chain is not a trusted source"
        );

        if (payloads.length == 0) {
            payloads = [_payload];
        } else {
            payloads.push(_payload);
        }

        if (refundAddresses.length == 0) {
            refundAddresses = [_refundAddress];
        } else {
            refundAddresses.push(_refundAddress);
        }

        if (adapterParams.length == 0) {
            adapterParams = [_adapterParams];
        } else {
            adapterParams.push(_adapterParams);
        }

        if (zroPaymentAddresses.length == 0) {
            zroPaymentAddresses = [_zroPaymentAddress];
        } else {
            zroPaymentAddresses.push(_zroPaymentAddress);
        }
    }
}

contract MockStargateRouter is IStargateRouter {
    bytes[] public callparams;

    /// @notice intercept the layerZero send and log the outgoing request
    function swap(
        uint16 _dstChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        uint256 _amountLD,
        uint256 _minAmountLD,
        lzTxObj memory _lzTxParams,
        bytes calldata _to,
        bytes calldata _payload
    ) external payable {
        bytes memory params = abi.encode(
            _dstChainId,
            _srcPoolId,
            _dstPoolId,
            _refundAddress,
            _amountLD,
            _minAmountLD,
            _lzTxParams,
            _to,
            _payload
        );
        if (callparams.length == 0) {
            callparams = [params];
        } else {
            callparams.push(params);
        }
    }

    function addLiquidity(
        uint256 _poolId,
        uint256 _amountLD,
        address _to
    ) external {}

    function redeemRemote(
        uint16 _dstChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        uint256 _amountLP,
        uint256 _minAmountLD,
        bytes calldata _to,
        lzTxObj memory _lzTxParams
    ) external payable {}

    function instantRedeemLocal(
        uint16 _srcPoolId,
        uint256 _amountLP,
        address _to
    ) external returns (uint256) {
        return 0;
    }

    function redeemLocal(
        uint16 _dstChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        uint256 _amountLP,
        bytes calldata _to,
        lzTxObj memory _lzTxParams
    ) external payable {}

    function sendCredits(
        uint16 _dstChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress
    ) external payable {}

    function quoteLayerZeroFee(
        uint16 _dstChainId,
        uint8 _functionType,
        bytes calldata _toAddress,
        bytes calldata _transferAndCallPayload,
        lzTxObj memory _lzTxParams
    ) external view returns (uint256, uint256) {
        return (0, 0);
    }
}
