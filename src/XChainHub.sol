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

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {IVault} from "./interfaces/IVault.sol";
import {LayerZeroApp} from "./LayerZeroApp.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IAnyswapRouter} from "./interfaces/IAnyswapRouter.sol";

/// @title XChainHub
/// @dev Expect this contract to change in future.
contract XChainHub is LayerZeroApp {
    using SafeERC20 for IERC20;

    /// Actions

    uint8 internal constant DEPOSIT_ACTION = 0;
    uint8 internal constant REQUEST_WITHDRAW_ACTION = 1;
    uint8 internal constant FINALIZE_WITHDRAW_ACTION = 2;
    uint8 internal constant REPORT_UNDERLYING_ACTION = 3;

    /// Report delay
    uint64 internal constant REPORT_DELAY = 6 hours;

    /// Message struct

    struct Message {
        uint8 action;
        bytes payload;
    }

    /// @notice Anyswap router.
    IAnyswapRouter public immutable anyswapRouter;

    /// @notice Trusted vaults on current chain.
    mapping(address => bool) public trustedVault;

    /// @notice Trusted strategies on current chain.
    mapping(address => bool) public trustedStrategy;

    /// @notice Indicates if the hub is gathering exit requests
    ///         for a given vault.
    mapping(address => bool) public exiting;

    /// @notice Indicates withdrawn amount per round for a given vault.
    mapping(address => mapping(uint256 => uint256)) public withdrawnPerRound;

    /// @notice Shares held on behalf of strategies from other chains.
    /// @dev This is for DESTINATION CHAIN.
    /// @dev Each strategy will have one and only one underlying forever.
    /// @dev So we map the shares held like:
    /// @dev     (chainId => strategy => shares)
    /// @dev eg. when a strategy deposits from chain A to chain B
    ///          the XChainHub on chain B will account for minted shares.
    mapping(uint16 => mapping(address => uint256)) public sharesPerStrategy;

    /// @notice Current round per strategy.
    mapping(uint16 => mapping(address => uint256))
        public currentRoundPerStrategy;

    /// @notice Shares waiting for social burn process.
    /// @dev This is for DESTINATION CHAIN.
    mapping(uint16 => mapping(address => uint256))
        public exitingSharesPerStrategy;

    /// @notice Latest updates per strategy
    mapping(uint16 => mapping(address => uint256)) public latestUpdate;

    constructor(address anyswapEndpoint, address lzEndpoint)
        LayerZeroApp(lzEndpoint)
    {
        anyswapRouter = IAnyswapRouter(anyswapEndpoint);
    }

    function setTrustedVault(address vault, bool trusted) external onlyOwner {
        trustedVault[vault] = trusted;
    }

    function setExiting(address vault, bool exit) external onlyOwner {
        exiting[vault] = exit;
    }

    function reportUnderlying(
        IVault vault,
        uint16[] memory dstChains,
        address[] memory strats,
        bytes memory adapterParams
    ) external payable onlyOwner {
        require(
            trustedVault[address(vault)],
            "XChainHub: vault is not trusted."
        );

        require(
            dstChains.length == strats.length,
            "XChainHub: dstChains and strats wrong length"
        );

        uint256 amountToReport;
        uint256 exchangeRate = vault.exchangeRate();
        for (uint256 i; i < dstChains.length; i++) {
            uint256 shares = sharesPerStrategy[dstChains[i]][strats[i]];

            require(shares > 0, "XChainHub: strat has no deposits");

            require(
                latestUpdate[dstChains[i]][strats[i]] >=
                    (block.timestamp + REPORT_DELAY),
                "XChainHub: latest update too recent"
            );

            latestUpdate[dstChains[i]][strats[i]] = block.timestamp;
            amountToReport = (shares * exchangeRate) / 10**vault.decimals();

            _lzSend(
                dstChains[i],
                abi.encode(REPORT_UNDERLYING_ACTION, strats[i], amountToReport),
                payable(msg.sender),
                address(0),
                adapterParams
            );
        }
    }

    function finalizeWithdrawFromVault(IVault vault) external onlyOwner {
        uint256 round = vault.batchBurnRound();
        IERC20 underlying = vault.underlying();

        uint256 balanceBefore = underlying.balanceOf(address(this));
        vault.exitBatchBurn();
        uint256 withdrawn = underlying.balanceOf(address(this)) - balanceBefore;

        withdrawnPerRound[address(vault)][round] = withdrawn;
    }

    function depositToChain(
        uint16 dstChainId,
        address dstVault,
        uint256 amount,
        uint256 minOut,
        bytes memory adapterParams,
        address payable refundAddress
    ) external payable {
        require(
            trustedStrategy[msg.sender],
            "XChainHub: sender is not a trusted strategy"
        );

        IStrategy strategy = IStrategy(msg.sender);
        IERC20 underlying = strategy.underlying();

        underlying.safeTransferFrom(msg.sender, address(this), amount);
        underlying.safeApprove(address(anyswapRouter), amount);

        anyswapRouter.anySwapOutUnderlying(
            address(underlying),
            dstVault,
            amount,
            dstChainId
        );

        _lzSend(
            dstChainId,
            abi.encode(DEPOSIT_ACTION, dstVault, msg.sender, amount, minOut),
            refundAddress,
            address(0),
            adapterParams
        );
    }

    function withdrawFromChain(
        uint16 dstChainId,
        address dstVault,
        uint256 amount,
        bytes memory adapterParams,
        address payable refundAddress
    ) external payable {
        require(
            trustedStrategy[msg.sender],
            "XChainHub: sender is not a trusted strategy"
        );

        _lzSend(
            dstChainId,
            abi.encode(1, dstVault, msg.sender, amount),
            refundAddress,
            address(0),
            adapterParams
        );
    }

    function finalizeWithdrawFromChain(
        uint16 dstChainId,
        address dstVault,
        uint256 amount,
        bytes memory adapterParams,
        address payable refundAddress
    ) external payable {
        require(
            trustedStrategy[msg.sender],
            "XChainHub: sender is not a trusted strategy"
        );

        _lzSend(
            dstChainId,
            abi.encode(2, dstVault, msg.sender),
            refundAddress,
            address(0),
            adapterParams
        );
    }

    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) internal virtual override {
        Message memory message = abi.decode(_payload, (Message));

        address srcAddress;
        assembly {
            srcAddress := mload(add(_srcAddress, 20))
        }

        if (message.action == DEPOSIT_ACTION) {
            // deposit
            _depositAction(_srcChainId, message.payload);
        } else if (message.action == REQUEST_WITHDRAW_ACTION) {
            // request exit
            _requestWithdrawAction(_srcChainId, message.payload);
        } else if (message.action == FINALIZE_WITHDRAW_ACTION) {
            // finalize exit
            _finalizeWithdrawAction(_srcChainId, message.payload);
        } else if (message.action == REPORT_UNDERLYING_ACTION) {
            // receive report
            _reportUnderlyingAction(message.payload);
        } else {
            revert();
        }
    }

    function _depositAction(uint16 _srcChainId, bytes memory _payload)
        internal
    {
        (IVault vault, address strategy, uint256 amount, uint256 min) = abi
            .decode(_payload, (IVault, address, uint256, uint256));

        require(
            trustedVault[address(vault)],
            "XChainHub: vault is not trusted"
        );

        IERC20 underlying = vault.underlying();

        uint256 vaultBalance = vault.balanceOf(address(this));

        underlying.safeApprove(address(vault), amount);
        vault.deposit(address(this), amount);

        uint256 mintedShares = vault.balanceOf(address(this)) - vaultBalance;

        require(
            mintedShares >= min,
            "XChainHub: minted less shares than required"
        );

        sharesPerStrategy[_srcChainId][strategy] += mintedShares;
    }

    function _requestWithdrawAction(uint16 _srcChainId, bytes memory _payload)
        internal
    {
        (IVault vault, address strategy, uint256 amount) = abi.decode(
            _payload,
            (IVault, address, uint256)
        );

        uint256 round = vault.batchBurnRound();
        uint256 currentRound = currentRoundPerStrategy[_srcChainId][strategy];

        require(
            trustedVault[address(vault)],
            "XChainHub: vault is not trusted"
        );

        require(
            exiting[address(vault)],
            "XChainHub: vault is not in exit window"
        );

        require(
            currentRound == 0 || currentRound == round,
            "XChainHub: strategy is already exiting from a previous round"
        );

        currentRoundPerStrategy[_srcChainId][strategy] = round;
        sharesPerStrategy[_srcChainId][strategy] -= amount;
        exitingSharesPerStrategy[_srcChainId][strategy] += amount;

        vault.enterBatchBurn(amount);
    }

    function _finalizeWithdrawAction(uint16 _srcChainId, bytes memory _payload)
        internal
    {
        (IVault vault, address strategy) = abi.decode(
            _payload,
            (IVault, address)
        );

        require(
            !exiting[address(vault)],
            "XChainHub: exit window is not closed."
        );

        require(
            trustedVault[address(vault)],
            "XChainHub: vault is not trusted"
        );

        uint256 currentRound = currentRoundPerStrategy[_srcChainId][strategy];
        uint256 exitingShares = exitingSharesPerStrategy[_srcChainId][strategy];

        require(currentRound > 0, "XChainHub: no withdraws for strategy");

        currentRoundPerStrategy[_srcChainId][strategy] = 0;
        exitingSharesPerStrategy[_srcChainId][strategy] = 0;

        IERC20 underlying = vault.underlying();

        IVault.BatchBurn memory batchBurn = vault.batchBurns(currentRound);
        uint256 amountPerShare = batchBurn.amountPerShare;
        uint256 strategyAmount = (amountPerShare * exitingShares) /
            (10**vault.decimals());

        underlying.safeApprove(address(anyswapRouter), strategyAmount);
        anyswapRouter.anySwapOutUnderlying(
            address(underlying),
            strategy,
            strategyAmount,
            _srcChainId
        );
    }

    function _reportUnderlyingAction(bytes memory payload) internal {
        (IStrategy strategy, uint256 amountToReport) = abi.decode(
            payload,
            (IStrategy, uint256)
        );

        strategy.report(amountToReport);
    }
}
