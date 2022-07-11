// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;
pragma abicoder v2;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {XChainStargateHub} from "../src/XChainStargateHub.sol";
import {XChainStargateHubMockReducer, XChainStargateHubMockLzSend, MockStargateRouter} from "./mocks/MockXChainStargateHub.sol";

import {AuxoTest} from "./mocks/MockERC20.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {LZEndpointMock} from "./mocks/MockLayerZeroEndpoint.sol";

import {IStargateRouter} from "../src/interfaces/IStargateRouter.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IHubPayload} from "../src/interfaces/IHubPayload.sol";

contract MockStrat {
    ERC20 public underlying;

    constructor(ERC20 _underlying) {
        underlying = _underlying;
    }
}

contract TestXChainStargateHub is Test {
    address public stargate;
    address public lz;
    address public refund;
    address public vaultAddr;
    IVault public vault;
    XChainStargateHub public hub;
    XChainStargateHubMockReducer hubMockReducer;

    function setUp() public {
        vaultAddr = 0x4A1c900Ee1042dC2BA405821F0ea13CfBADCAb7B;
        vault = IVault(vaultAddr);

        (stargate, lz, refund) = (
            0x4A1c900Ee1042dC2BA405821F0ea13CfBADCAb7B,
            0x63BCe354DBA7d6270Cb34dAA46B869892AbB3A79,
            0x675e75A6f90E0610d150f415e4406B4989AaD023
        );
        hub = new XChainStargateHub(stargate, lz, refund);
        hubMockReducer = new XChainStargateHubMockReducer(stargate, lz, refund);
    }

    // test initial state of the contract
    function testInitialContractState() public {
        assertEq(address(hub.stargateRouter()), stargate);
        assertEq(address(hub.layerZeroEndpoint()), lz);
        assertEq(address(hub.refundRecipient()), refund);
    }

    // test we can set/unset a trusted vault
    function testSetUnsetTrustedVault() public {
        assertEq(hub.trustedVault(vaultAddr), false);
        hub.setTrustedVault(vaultAddr, true);
        assert(hub.trustedVault(vaultAddr));
        hub.setTrustedVault(vaultAddr, false);
        assertEq(hub.trustedVault(vaultAddr), false);
    }

    // test we can set/unset an exiting vault
    function testSetUnsetExitingVault() public {
        assertEq(hub.exiting(vaultAddr), false);
        hub.setExiting(vaultAddr, true);
        assert(hub.exiting(vaultAddr));
        hub.setExiting(vaultAddr, false);
        assertEq(hub.exiting(vaultAddr), false);
    }

    // test onlyOwner can call certain functions
    function testOnlyOwner(address _notOwner) public {
        vm.assume(_notOwner != hub.owner());
        bytes memory onlyOwnerErr = bytes("Ownable: caller is not the owner");
        uint16[] memory dstChains = new uint16[](1);
        address[] memory strats = new address[](1);
        dstChains[0] = 1;
        strats[0] = 0x4A1c900Ee1042dC2BA405821F0ea13CfBADCAb7B;

        vm.startPrank(_notOwner);
        vm.expectRevert(onlyOwnerErr);
        hub.reportUnderlying(vault, dstChains, strats, bytes(""));

        vm.expectRevert(onlyOwnerErr);
        hub.setTrustedVault(vaultAddr, true);

        vm.expectRevert(onlyOwnerErr);
        hub.setExiting(vaultAddr, true);

        vm.expectRevert(onlyOwnerErr);
        hub.finalizeWithdrawFromVault(vault);
    }

    /// @notice helper function to avoid repetition
    function _checkReducerAction(
        uint8 _action,
        XChainStargateHubMockReducer mock
    ) internal {
        mock.reducer(1, abi.encodePacked(vaultAddr), mock.makeMessage(_action));
        assertEq(mock.lastCall(), _action);
    }

    // Test reducer
    function testReducerSwitchesCorrectly() public {
        assertEq(hubMockReducer.lastCall(), 0);

        vm.startPrank(address(hubMockReducer));
        _checkReducerAction(hub.DEPOSIT_ACTION(), hubMockReducer);
        _checkReducerAction(hub.REQUEST_WITHDRAW_ACTION(), hubMockReducer);
        _checkReducerAction(hub.FINALIZE_WITHDRAW_ACTION(), hubMockReducer);
        _checkReducerAction(hub.REPORT_UNDERLYING_ACTION(), hubMockReducer);
    }

    /// @dev testFail because the specific revert is not working
    function testFailReducerRevertsOnUnknownAction() public {
        /// @dev come back to this https://github.com/foundry-rs/foundry/discussions/2236
        vm.prank(stargate);
        // vm.expectRevert(bytes("XChainHub::_reducer:UNRECOGNISED ACTION"));
        hubMockReducer.reducer(
            1,
            abi.encodePacked(vaultAddr),
            hubMockReducer.makeMessage(245)
        );
    }

    /// @dev testFail because the specific revert is not working
    function testFailReducerCanOnlyBeCalledByItself(address _caller) public {
        vm.assume(_caller != address(hubMockReducer));
        // vm.expectRevert(bytes("XChainHub::_reducer:UNAUTHORIZED"));
        vm.prank(_caller);
        hubMockReducer.reducer(
            1,
            abi.encodePacked(vaultAddr),
            hubMockReducer.makeMessage(1)
        );
    }

    /// test entrypoints
    function testSgReceiveCannotBeCalledByExternal(address _caller) public {
        vm.assume(_caller != address(hub));
        vm.prank(_caller);
        vm.expectRevert(bytes("XChainHub::sgRecieve:NOT STARGATE ROUTER"));
        hub.sgReceive(
            1,
            abi.encodePacked(vaultAddr),
            1,
            vaultAddr,
            1,
            bytes("")
        );
    }

    function testLayerZeroCannotBeCalledByExternal(address _caller) public {
        vm.assume(_caller != address(hub));
        vm.prank(_caller);
        vm.expectRevert(bytes("LayerZeroApp: caller must be address(this)"));
        hub.nonblockingLzReceive(1, abi.encodePacked(vaultAddr), 1, bytes(""));
    }

    function testSgReceiveWhitelistedActions(uint8 _action) public {
        vm.assume(_action <= hub.LAYER_ZERO_MAX_VALUE());
        IHubPayload.Message memory message = IHubPayload.Message({
            action: _action,
            payload: bytes("")
        });
        vm.startPrank(stargate);
        vm.expectRevert(bytes("XChainHub::sgRecieve:PROHIBITED ACTION"));
        hub.sgReceive(
            1,
            abi.encodePacked(vaultAddr),
            1,
            vaultAddr,
            1,
            abi.encode(message)
        );
    }

    // should silently pass
    function testEmptyPayloadSgReceive() public {
        vm.startPrank(stargate);
        hub.sgReceive(
            1,
            abi.encodePacked(vaultAddr),
            1,
            vaultAddr,
            1,
            bytes("")
        );
    }

    function testFinalizeWithdrawFromVault() public {
        // setup the token
        ERC20 token = new AuxoTest();
        assertEq(token.balanceOf(address(this)), 1e27);

        // setup the mock vault and wrap it
        MockVault _vault = new MockVault(token);
        IVault tVault = IVault(address(_vault));
        token.transfer(address(_vault), 1e26); // 1/2 balance
        assertEq(token.balanceOf(address(_vault)), 1e26);

        // execute the action
        hub.finalizeWithdrawFromVault(tVault);

        // check the value, corresponds to the mock vault expected outcome
        assertEq(
            hub.withdrawnPerRound(address(_vault), 2),
            _vault.expectedWithdrawal()
        );
    }

    function testRequestWithdrawFromChainFailsWithUntrustedStrategy(
        address untrusted
    ) public {
        address trustedStrat = 0x69b8C988b17BD77Bb56BEe902b7aB7E64F262F35;
        vm.assume(untrusted != trustedStrat);

        vm.prank(untrusted);
        vm.expectRevert(bytes("XChainHub::requestWithdrawFromChain:UNTRUSTED"));
        hub.requestWithdrawFromChain(
            1,
            vaultAddr,
            1e19,
            bytes(""),
            payable(refund)
        );
    }

    function testRequestWithdrawFromChain() public {
        // test params
        uint16 _mockChainIdSrc = 1;
        address _dstAddress = address(hub);
        address _trustedStrat = 0x69b8C988b17BD77Bb56BEe902b7aB7E64F262F35;

        // instantiate the mock
        XChainStargateHubMockLzSend hubSrc = new XChainStargateHubMockLzSend(
            stargate,
            lz,
            refund
        );

        // minimal whitelisting
        hubSrc.setTrustedStrategy(_trustedStrat, true);
        hubSrc.setTrustedRemote(_mockChainIdSrc, abi.encodePacked(_dstAddress));

        vm.prank(_trustedStrat);
        hubSrc.requestWithdrawFromChain(
            _mockChainIdSrc,
            _dstAddress,
            1e19,
            bytes(""),
            payable(refund)
        );

        // the mock intercepts and stores payloads that we can inspect
        bytes memory payload = hubSrc.payloads(0);

        // decode the outer message
        IHubPayload.Message memory message = abi.decode(
            payload,
            (IHubPayload.Message)
        );

        // decode the inner payload
        IHubPayload.RequestWithdrawPayload memory decoded = abi.decode(
            message.payload,
            (IHubPayload.RequestWithdrawPayload)
        );

        // run through relevant calldata
        assertEq(message.action, hub.REQUEST_WITHDRAW_ACTION());
        assertEq(decoded.vault, _dstAddress);
        assertEq(decoded.strategy, _trustedStrat);
        assertEq(decoded.amountVaultShares, 1e19);
        assertEq(hubSrc.refundAddresses(0), refund);
    }

    function testFinalizeWithdrawFromChainFailsWithUntrustedStrategy(
        address untrusted
    ) public {
        address trustedStrat = 0x69b8C988b17BD77Bb56BEe902b7aB7E64F262F35;
        uint16 _mockChainIdDst = 2;
        address _dstAddress = address(hub);
        uint16 srcPoolId = 1;
        uint16 dstPoolId = 2;
        uint256 minOutUnderlying = 1e21;

        vm.assume(untrusted != trustedStrat);

        vm.prank(untrusted);
        vm.expectRevert(
            bytes("XChainHub::finalizeWithdrawFromChain:UNTRUSTED")
        );
        hub.finalizeWithdrawFromChain(
            _mockChainIdDst,
            _dstAddress,
            bytes(""),
            payable(refund),
            srcPoolId,
            dstPoolId,
            minOutUnderlying
        );
    }

    function testFinalizeWithdrawFromChain() public {
        // test params
        uint16 _mockChainIdDst = 2;
        address _dstAddress = address(hub);
        address _trustedStrat = 0x69b8C988b17BD77Bb56BEe902b7aB7E64F262F35;
        uint16 srcPoolId = 1;
        uint16 dstPoolId = 2;
        uint256 minOutUnderlying = 1e21;

        // instantiate the mock
        XChainStargateHubMockLzSend hubSrc = new XChainStargateHubMockLzSend(
            stargate,
            lz,
            refund
        );

        // minimal whitelisting
        hubSrc.setTrustedStrategy(_trustedStrat, true);
        hubSrc.setTrustedRemote(_mockChainIdDst, abi.encodePacked(_dstAddress));

        vm.prank(_trustedStrat);
        hubSrc.finalizeWithdrawFromChain(
            _mockChainIdDst,
            _dstAddress,
            bytes(""),
            payable(refund),
            srcPoolId,
            dstPoolId,
            minOutUnderlying
        );

        // the mock intercepts and stores payloads that we can inspect
        bytes memory payload = hubSrc.payloads(0);

        // decode the outer message
        IHubPayload.Message memory message = abi.decode(
            payload,
            (IHubPayload.Message)
        );

        // decode the inner payload
        IHubPayload.FinalizeWithdrawPayload memory decoded = abi.decode(
            message.payload,
            (IHubPayload.FinalizeWithdrawPayload)
        );

        // run through relevant calldata
        assertEq(message.action, hub.FINALIZE_WITHDRAW_ACTION());
        assertEq(decoded.vault, _dstAddress);
        assertEq(decoded.strategy, _trustedStrat);
        assertEq(decoded.minOutUnderlying, minOutUnderlying);
        assertEq(decoded.srcPoolId, srcPoolId);
        assertEq(decoded.dstPoolId, dstPoolId);
        assertEq(hubSrc.refundAddresses(0), refund);
    }

    function _decodeDepositCalldata(MockStargateRouter mockRouter)
        internal
        returns (IHubPayload.Message memory, IHubPayload.DepositPayload memory)
    {
        // the mock intercepts and stores payloads that we can inspect
        bytes memory payload = mockRouter.callparams(0);

        // decode the calldata
        (
            uint16 _dstChainId,
            uint256 _srcPoolId,
            uint256 _dstPoolId,
            address payable _refundAddress,
            uint256 _amountLD,
            uint256 _minAmountLD,
            IStargateRouter.lzTxObj memory _lzTxParams,
            bytes memory _to,
            bytes memory _payload
        ) = abi.decode(
                payload,
                (
                    uint16,
                    uint256,
                    uint256,
                    address,
                    uint256,
                    uint256,
                    IStargateRouter.lzTxObj,
                    bytes,
                    bytes
                )
            );

        // decode the outer message
        IHubPayload.Message memory message = abi.decode(
            _payload,
            (IHubPayload.Message)
        );

        // decode the inner payload
        IHubPayload.DepositPayload memory decoded = abi.decode(
            message.payload,
            (IHubPayload.DepositPayload)
        );

        return (message, decoded);
    }

    function testDepositToChainFailsWithUntrustedStrategy(address untrusted)
        public
    {
        address trustedStrat = 0x69b8C988b17BD77Bb56BEe902b7aB7E64F262F35;
        vm.assume(untrusted != trustedStrat);

        vm.prank(untrusted);
        vm.expectRevert(bytes("XChainHub::depositToChain:UNTRUSTED"));
        hub.depositToChain(
            1,
            2,
            1,
            address(0),
            address(0),
            1e21,
            1e20,
            payable(refund)
        );
    }

    function testDeposit() public {
        // minimal dependencies
        ERC20 token = new AuxoTest();
        MockStrat strat = new MockStrat(token);

        // test params
        address trustedStrat = address(strat);
        uint16 srcPoolId = 1;
        uint16 dstPoolId = 2;
        uint16 dstChainId = 1;
        address dstHub = address(hub);
        address dstVault = vaultAddr;
        uint256 minOut = token.balanceOf(address(this)) / 2;
        uint256 amount = token.balanceOf(address(this));

        // instantiate the mock
        MockStargateRouter mockRouter = new MockStargateRouter();
        XChainStargateHub hubMockRouter = new XChainStargateHub(
            address(mockRouter),
            lz,
            refund
        );

        // minimal whitelisting
        hubMockRouter.setTrustedStrategy(trustedStrat, true);
        hubMockRouter.setTrustedRemote(dstChainId, abi.encodePacked(dstHub));

        // deposit requires tokens
        token.transfer(trustedStrat, token.balanceOf(address(this)));

        // approve hub to take my tokens
        vm.prank(trustedStrat);
        token.approve(address(hubMockRouter), type(uint256).max);

        vm.prank(trustedStrat);
        hubMockRouter.depositToChain(
            dstChainId,
            srcPoolId,
            dstPoolId,
            dstHub,
            dstVault,
            amount,
            minOut,
            payable(refund)
        );

        // grab payloads stored against the mock
        (
            IHubPayload.Message memory message,
            IHubPayload.DepositPayload memory decoded
        ) = _decodeDepositCalldata(mockRouter);

        // run through relevant calldata
        assertEq(message.action, hub.DEPOSIT_ACTION());
        assertEq(decoded.vault, dstVault);
        assertEq(decoded.strategy, trustedStrat);
        assertEq(decoded.amountUnderyling, amount);
        assertEq(decoded.min, minOut);
    }

    // REPORT UNDERLYING

    // test reverts if the vault is untrusted
    // test reverts if length mismatched
    // test reverts if one of the strategies has no deposits
    // test reverts if attempted before the timestamp has elapsed
    // test the mock was called with the correct message
    // test the latest update was set correctly for each chain
}
