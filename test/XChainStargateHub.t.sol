// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;
pragma abicoder v2;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {XChainStargateHub} from "../src/XChainStargateHub.sol";
import {XChainStargateHubMockReducer} from "./mocks/MockXChainStargateHub.sol";
import {AuxoTest} from "./mocks/MockERC20.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {IStargateRouter} from "../src/interfaces/IStargateRouter.sol";
import {IVault} from "../src/interfaces/IVault.sol";

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

    /// @dev testFail because the specific revert is not working
    function testFailSgReceiveWhitelistedActions(uint8 _action) public {
        vm.assume(_action <= hub.LAYER_ZERO_MAX_VALUE());
        vm.startPrank(stargate);
        // vm.expectRevert(bytes("XChainHub::sgRecieve:PROHIBITED ACTION"));
        hub.sgReceive(
            1,
            abi.encodePacked(vaultAddr),
            1,
            vaultAddr,
            1,
            abi.encode(hubMockReducer.makeMessage(_action))
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

    // test finalizeWithdrawFromVault
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

    // REPORT UNDERLYING

    // test reverts if the vault is untrusted
    // test reverts if length mismatched
    // test reverts if one of the strategies has no deposits
    // test reverts if attempted before the timestamp has elapsed
    // test the mock was called with the correct message
    // test the latest update was set correctly for each chain
}
