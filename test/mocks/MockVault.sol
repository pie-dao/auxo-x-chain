// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice A vault seeking for yield.
contract MockVault is ERC20 {
    ERC20 public underlying;

    uint256 public batchBurnRound = 2;
    uint256 private amountPerShare = 100;
    uint256 private shares = 1e21;
    uint256 public expectedWithdrawal;

    struct BatchBurnReceipt {
        uint256 round;
        uint256 shares;
    }

    mapping(address => BatchBurnReceipt) public userBatchBurnReceipts;

    constructor(ERC20 _underyling) ERC20("Auxo Test", "auxoTST") {
        underlying = _underyling;
        expectedWithdrawal = shares * amountPerShare;
    }

    function deposit(address to, uint256 underlyingAmount)
        external
        returns (uint256)
    {
        _deposit(
            to,
            (shares = calculateShares(underlyingAmount)),
            underlyingAmount
        );
    }

    function _deposit(
        address to,
        uint256 shares,
        uint256 underlyingAmount
    ) internal virtual whenNotPaused {
        uint256 userUnderlying = calculateUnderlying(balanceOf(to)) +
            underlyingAmount;
        uint256 vaultUnderlying = totalUnderlying() + underlyingAmount;

        require(
            userUnderlying <= userDepositLimit,
            "_deposit::USER_DEPOSIT_LIMITS_REACHED"
        );
        require(
            vaultUnderlying <= vaultDepositLimit,
            "_deposit::VAULT_DEPOSIT_LIMITS_REACHED"
        );

        // Determine te equivalent amount of shares and mint them
        _mint(to, shares);

        emit Deposit(msg.sender, to, underlyingAmount);

        // Transfer in underlying tokens from the user.
        // This will revert if the user does not have the amount specified.
        underlying.safeTransferFrom(
            msg.sender,
            address(this),
            underlyingAmount
        );
    }

    function exitBatchBurn() external {
        uint256 batchBurnRound_ = batchBurnRound;
        BatchBurnReceipt memory receipt = BatchBurnReceipt({
            round: 1,
            shares: shares
        });

        userBatchBurnReceipts[msg.sender] = receipt;

        require(receipt.round != 0, "exitBatchBurn::NO_DEPOSITS");
        require(
            receipt.round < batchBurnRound_,
            "exitBatchBurn::ROUND_NOT_EXECUTED"
        );

        userBatchBurnReceipts[msg.sender].round = 0;
        userBatchBurnReceipts[msg.sender].shares = 0;

        uint256 underlyingAmount = receipt.shares * amountPerShare;

        // batchBurnBalance -= underlyingAmount;
        underlying.transfer(msg.sender, underlyingAmount);
    }
}
