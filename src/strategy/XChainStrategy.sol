//   ______
//  /      \
// /$$$$$$  | __    __  __    __   ______
// $$ |__$$ |/  |  /  |/  \  /  | /      \
// $$    $$ |$$ |  $$ |$$  \/$$/ /$$$$$$  |
// $$$$$$$$ |$$ |  $$ | $$  $$<  $$ |  $$ |
// $$ |  $$ |$$ \__$$ | /$$$$  \ $$ \__$$ |
// $$ |  $$ |$$    $$/ /$$/ $$  |$$    $$/
// $$/   $$/  $$$$$$/  $$/   $$/  $$$$$$/
//
// auxo.fi

// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import {XChainHub} from "../XChainHub.sol";
import {IVault} from "../interfaces/IVault.sol";
import {BaseStrategy} from "./BaseStrategy.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

contract XChainStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // possible states:
    //  - not deposited: strategy withdrawn
    //  - Depositing: strategy is depositing
    //  - Deposited: strategy has deposited
    //  - withdrawing: strategy is withdrawing
    enum DepositState {
        NOT_DEPOSITED,
        DEPOSITING,
        DEPOSITED,
        WITHDRAWING
    }

    struct DepositParams {
        uint16 dstChain;
        address dstVault;
        bytes adapterParams;
        address payable refundAddress;
    }

    struct Deposit {
        DepositParams params;
        uint256 amountDeposited;
    }

    XChainHub private hub;
    DepositState public state;
    Deposit public xChainDeposit;

    uint256 public reportedUnderlying;

    constructor(
        XChainHub hub_,
        IVault vault_,
        IERC20 underlying_,
        address manager_,
        address strategist_,
        string memory name_
    ) {
        __initialize(vault_, underlying_, manager_, strategist_, name_);
        hub = hub_;
    }

    function depositUnderlying(
        uint256 amount,
        uint256 minAmount,
        DepositParams calldata params
    ) external {
        require(
            msg.sender == manager || msg.sender == strategist,
            "XChainStrategy: caller not authorized"
        );

        DepositState currentState = state;

        require(
            currentState != DepositState.WITHDRAWING,
            "XChainStrategy: wrong state"
        );

        state = DepositState.DEPOSITING;
        xChainDeposit.params = params;
        xChainDeposit.amountDeposited += amount;

        underlying.safeApprove(address(hub), amount);
        hub.depositToChain(
            params.dstChain,
            params.dstVault,
            amount,
            minAmount,
            params.adapterParams,
            params.refundAddress
        );
    }

    function withdrawUnderlying(uint256 amount) external {
        require(
            msg.sender == manager || msg.sender == strategist,
            "XChainStrategy: caller not authorized"
        );

        DepositState currentState = state;

        require(
            currentState == DepositState.DEPOSITED,
            "XChainStrategy: wrong state"
        );

        DepositParams memory params = xChainDeposit.params;

        hub.withdrawFromChain(
            params.dstChain,
            params.dstVault,
            amount,
            params.adapterParams,
            params.refundAddress
        );
    }

    function estimatedUnderlying() external view override returns (uint256) {
        if (state == DepositState.NOT_DEPOSITED) {
            return float();
        }

        return reportedUnderlying;
    }

    function report(uint256 reportedAmount) external {
        require(
            msg.sender == address(hub),
            "XChainStrategy: caller is not hub"
        );

        DepositState currentState = state;

        require(
            currentState != DepositState.NOT_DEPOSITED,
            "XChainStrategy: wrong state"
        );

        if (reportedAmount == 0) {
            state = DepositState.NOT_DEPOSITED;
            xChainDeposit.amountDeposited = 0;
            return;
        }

        if (currentState == DepositState.DEPOSITING) {
            state = DepositState.DEPOSITED;
        }

        reportedUnderlying = reportedAmount;
    }
}
