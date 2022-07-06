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

import {IStargateReceiver} from "./interfaces/IStargateReceiver.sol";
import {IStargateRouter} from "./interfaces/IStargateRouter.sol";

/// @title XChainHub
/// @dev Expect this contract to change in future.
contract XChainHub is LayerZeroApp, IStargateReceiver {
    using SafeERC20 for IERC20;

    // --------------------------
    //     Events
    // --------------------------

    event CrossChainDepositSent(uint16 dstChainId, uint256 amount);
    event CrossChainWithdrawRequestedSent(uint16 dstChainId, uint256 amount);
    event CrossChainWithdrawFinalizedSent(uint16 dstChainId, uint256 amount);
    event CrossChainReportUnderylingSent(uint16 dstChainId, uint256 amount);

    event CrossChainDepositReceived(uint16 _srcChainId, uint256 _amount);
    event CrossChainWithdrawRequestedReceived(
        uint16 _srcChainId,
        uint256 _amount
    );
    event CrossChainWithdrawFinalizedReceived(
        uint16 _srcChainId,
        uint256 _amount
    );
    event CrossChainReportUnderylingReceived(
        uint16 _srcChainId,
        uint256 _amount
    );

    event CrossChainNoopReceived(uint16 _srcChainId);

    // --------------------------
    //     Errors
    // --------------------------

    error NotImplemented();

    // --------------------------
    //     Actions Reducer
    // --------------------------

    /// Enter into a vault
    uint8 internal constant DEPOSIT_ACTION = 0;
    /// Begin the batch burn process
    uint8 internal constant REQUEST_WITHDRAW_ACTION = 1;
    /// Withdraw funds once batch burn completed
    uint8 internal constant FINALIZE_WITHDRAW_ACTION = 2;
    /// Report underlying from different chain
    uint8 internal constant REPORT_UNDERLYING_ACTION = 3;
    /// Intentional Noop for  when swap is triggered on dstChain
    uint8 internal constant NO_ACTION = 3;

    // --------------------------
    //  Structs
    // --------------------------

    /// @notice Message struct
    /// @param action is the number of the action above
    /// @param payload is the encoded data to be sent with the message
    struct Message {
        uint8 action;
        bytes payload;
    }

    // --------------------------
    //  Constants & Immutables
    // --------------------------

    /// Report delay
    uint64 internal constant REPORT_DELAY = 6 hours;

    /// @notice https://stargateprotocol.gitbook.io/stargate/developers/official-erc20-addresses
    IStargateRouter public immutable stargateRouter;

    // --------------------------
    //  Single Chain Mappings
    // --------------------------

    /// @notice Trusted vaults on current chain.
    mapping(address => bool) public trustedVault;

    /// @notice Trusted strategies on current chain.
    mapping(address => bool) public trustedStrategy;

    /// @notice Indicates if the hub is gathering exit requests
    ///         for a given vault.
    mapping(address => bool) public exiting;

    /// @notice Indicates withdrawn amount per round for a given vault.
    /// @dev format vaultAddr => round => withdrawn
    mapping(address => mapping(uint256 => uint256)) public withdrawnPerRound;

    // --------------------------
    //  Cross Chain Mappings
    // --------------------------

    /// @notice Shares held on behalf of strategies from other chains.
    /// @dev This is for DESTINATION CHAIN.
    /// @dev Each strategy will have one and only one underlying forever.
    /// @dev So we map the shares held like:
    /// @dev     (chainId => strategy => shares)
    /// @dev eg. when a strategy deposits from chain A to chain B
    ///          the XChainHub on chain B will account for minted shares.
    mapping(uint16 => mapping(address => uint256)) public sharesPerStrategy;

    /// @notice  Destination Chain ID => Strategy => CurrentRound
    mapping(uint16 => mapping(address => uint256))
        public currentRoundPerStrategy;

    /// @notice Shares waiting for social burn process.
    ///     Destination Chain ID => Strategy => ExitingShares
    mapping(uint16 => mapping(address => uint256))
        public exitingSharesPerStrategy;

    /// @notice Latest updates per strategy
    ///     Destination Chain ID => Strategy => LatestUpdate
    mapping(uint16 => mapping(address => uint256)) public latestUpdate;

    // --------------------------
    //  Constructor
    // --------------------------

    /// @param stargateEndpoint
    /// @param lzEndpoint address of the layerZero endpoint contract on the source chain
    constructor(address stargateEndpoint, address lzEndpoint)
        LayerZeroApp(lzEndpoint)
    {
        stargateRouter = IStargateRouter(stargateEndpoint);
    }

    // --------------------------
    // Single Chain Functions
    // --------------------------

    /// @notice updates a vault on the current chain to be either trusted or untrusted
    /// @dev trust determines whether a vault can be interacted with
    /// @dev This is callable only by the owner
    function setTrustedVault(address vault, bool trusted) external onlyOwner {
        trustedVault[vault] = trusted;
    }

    /// @notice indicates whether the vault is in an `exiting` state
    ///     which restricts certain methods
    /// @dev This is callable only by the owner
    function setExiting(address vault, bool exit) external onlyOwner {
        exiting[vault] = exit;
    }

    // --------------------------
    // Cross Chain Functions
    // --------------------------

    /// @notice iterates through a list of destination chains and sends the current value of
    ///     the strategy (in terms of the underlying vault token) to that chain.
    /// @param vault Vault on the current chain.
    /// @param dstChains is an array of the layerZero chain Ids to check
    /// @param strats array of strategy addresses on the destination chains, index should match the dstChainId
    /// @param adapterParams is additional info to send to the Lz receiver
    /// @dev There are a few caveats:
    ///     1. All strategies must have deposits.
    ///     2. Requires that the setTrustedRemote method be set from lzApp, with the address being the deploy
    ///        address of this contract on the dstChain.
    ///     3. The list of chain ids and strategy addresses must be the same length, and use the same underlying token.
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

            // record the latest update for future reference
            latestUpdate[dstChains[i]][strats[i]] = block.timestamp;

            amountToReport = (shares * exchangeRate) / 10**vault.decimals();

            // See Layer zero docs for details on _lzSend
            // Corrolary method is _nonblockingLzReceive which will be invoked
            //      on the destination chain
            _lzSend(
                dstChains[i],
                abi.encode(REPORT_UNDERLYING_ACTION, strats[i], amountToReport),
                payable(msg.sender),
                address(0),
                adapterParams
            );
        }
    }

    /// @dev this looks like it completes the exit process but it's not
    ///     clear how that is useful in the context of rest of the contract
    function finalizeWithdrawFromVault(IVault vault) external onlyOwner {
        uint256 round = vault.batchBurnRound();
        IERC20 underlying = vault.underlying();

        uint256 balanceBefore = underlying.balanceOf(address(this));
        vault.exitBatchBurn();
        uint256 withdrawn = underlying.balanceOf(address(this)) - balanceBefore;

        withdrawnPerRound[address(vault)][round] = withdrawn;

        /// @dev I think here we might need to execute the swap
    }

    /// @dev Only Called by the Cross Chain Strategy
    /// @notice makes a deposit of the underyling token into the vault on a given chain
    /// @param _dstChainId the layerZero chain id
    /// @param _srcPoolId https://stargateprotocol.gitbook.io/stargate/developers/pool-ids
    /// @param _dstPoolId https://stargateprotocol.gitbook.io/stargate/developers/pool-ids
    /// @param _dstVault address of the vault on the destination chain
    /// @param _amount is the amount to deposit in underlying tokens
    /// @param _minOut how not to get rekt
    /// @param _refundAddress if extra native is sent, to whom should be refunded
    function depositToChain(
        uint16 _dstChainId,
        uint16 _srcPoolId,
        uint16 _dstPoolId,
        address _dstVault,
        uint256 _amount,
        uint256 _minOut,
        address payable _refundAddress
    ) external payable {
        /* 
            Possible reverts:
            -- null address checks
            -- null pool checks
            -- Pool doesn't match underlying
        */

        require(
            trustedStrategy[msg.sender],
            "XChainHub::depositToChain sender not trusted"
        );

        IStrategy strategy = IStrategy(msg.sender);
        IERC20 underlying = strategy.underlying();

        underlying.safeTransferFrom(msg.sender, address(this), _amount);
        underlying.safeApprove(address(stargateRouter), _amount);

        // encode payload to be sent along with the router
        /// @dev we could encode into a struct to share between src and dst
        bytes memory payload = abi.encode(
            DEPOSIT_ACTION,
            _dstVault,
            msg.sender,
            _amount,
            _minOut
        );

        stargateRouter.swap{value: msg.value}(
            _dstChainId,
            _srcPoolId,
            _dstPoolId,
            _refundAddress, // refunds sent to operator
            _amount,
            _minOut,
            IStargateRouter.lzTxObj(200000, 0, "0x"), /// @dev review this default value
            abi.encodePacked(_dstVault), // This vault must implement sgReceive
            payload
        );
    }

    /// @notice Only called by x-chain Strategy
    /// @notice make a request to withdraw tokens from a vault on a specified chain
    ///     the actual withdrawal takes place once the batch burn process is completed
    /// @dev see the _requestWithdrawAction for detail
    function withdrawFromChain(
        uint16 dstChainId,
        address dstVault,
        uint256 amount, // is this amount of underlying or vault share?
        bytes memory adapterParams,
        address payable refundAddress
    ) external payable {
        require(
            trustedStrategy[msg.sender],
            "XChainHub::withdrawFromChain sender is not trusted"
        );

        _lzSend(
            dstChainId,
            abi.encode(REQUEST_WITHDRAW_ACTION, dstVault, msg.sender, amount),
            refundAddress,
            address(0), // the address of the ZRO token holder who would pay for the transaction
            adapterParams
        );
    }

    /// @notice provided a successful batch burn has been executed, sends a message to
    ///     a vault to release the underlying tokens to the user, on a given chain.
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
            abi.encode(FINALIZE_WITHDRAW_ACTION, dstVault, msg.sender),
            refundAddress,
            address(0),
            adapterParams
        );
    }

    // --------------------------
    // Reducers
    // --------------------------

    /// @notice called by the stargate application on the dstChain
    /// TODO what are those empty params?
    function sgReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint256,
        address,
        uint256,
        bytes memory _payload
    ) external override {
        require(
            msg.sender == address(stargateRouter),
            "only stargate router can call sgReceive!"
        );

        // check that the message is encoded properly
        Message memory message = abi.decode(_payload, (Message));

        address srcAddress;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            srcAddress := mload(add(_srcAddress, 20))
        }

        if (message.action == DEPOSIT_ACTION) {
            // Deposit Action from payload in the stargate swap.
            _depositAction(_srcChainId, message.payload);

            // TODO This feels wrong, shouldn't this action come from a message instead of a callback of a swap????
            // ^^^^^^^^^^^^^^^^^^^^^^^^
        } else if (message.action == FINALIZE_WITHDRAW_ACTION) {
            _finalizeWithdrawAction(_srcChainId, message.payload);
        } else if (message.action == NO_ACTION) {
            emit CrossChainNoopReceived(_srcChainId);
        } else {
            revert("XChainHub: Unrecognised Action sgReceive");
        }
    }

    /// @notice called by the Lz application on the dstChain, then executes the corresponding action.
    /// @param _srcChainId the layerZero chain id
    /// @param _srcAddress UNUSED PARAM
    /// @param _nonce UNUSED PARAM
    /// @param _payload bytes encoded Message to be passed to the action
    /// @dev do not confuse _payload with Message.payload, these are encoded separately
    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        bytes memory _payload
    ) internal virtual override {
        Message memory message = abi.decode(_payload, (Message));

        address srcAddress;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            srcAddress := mload(add(_srcAddress, 20))
        }

        if (message.action == REQUEST_WITHDRAW_ACTION) {
            _requestWithdrawAction(_srcChainId, message.payload);
        } else if (message.action == REPORT_UNDERLYING_ACTION) {
            _reportUnderlyingAction(message.payload);
        } else if (message.action == NO_ACTION) {
            emit CrossChainNoopReceived(_srcChainId);
        } else {
            revert("XChainHub: Unrecognised Action in _nonBlockingLzReceive");
        }
    }

    // --------------------------
    //     Action Functions
    // --------------------------

    /// @param _srcChainId what layerZero chainId was the request initiated from
    /// @param _payload abi encoded as follows:
    ///     IVault
    ///     address (of strategy)
    ///     uint256 (amount to deposit)
    ///     uint256 (min amount of shares expected to be minted)
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

    /// @notice enter the batch burn for a vault on the current chain
    /// @param _srcChainId layerZero chain id where the request originated
    /// @param _payload encoded in the format:
    ///     IVault
    ///     address (of strategy)
    ///     uint256 (amount of auxo tokens to burn)
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
            "XChainHub::_requestWithdrawAction vault is not trusted"
        );

        require(
            exiting[address(vault)],
            "XChainHub::_requestWithdrawAction vault is not in exit window"
        );

        require(
            currentRound == 0 || currentRound == round,
            "XChainHub::_requestWithdrawAction strategy is already exiting from a previous round"
        );

        // update the state before entering the burn
        currentRoundPerStrategy[_srcChainId][strategy] = round;
        sharesPerStrategy[_srcChainId][strategy] -= amount;
        exitingSharesPerStrategy[_srcChainId][strategy] += amount;

        // TODO Test: Do we need to approve shares? I think so
        // will revert if amount is more than what we have.
        vault.enterBatchBurn(amount);
    }

    /// @notice executes a withdrawal of underlying tokens from a vault
    ///        to a strategy on the source chain
    /// @dev why strategy and not the user?
    /// @param _srcChainId what layerZero chainId was the request initiated from
    /// @param _payload abi encoded as follows:
    ///    IVault
    ///    address (of strategy)
    ///    uint16 (source stargate pool Id)
    ///    uint16 (dest stargate pool Id)
    function _finalizeWithdrawAction(uint16 _srcChainId, bytes memory _payload)
        internal
    {
        (
            IVault vault,
            address strategy,
            uint16 srcPoolId,
            uint16 dstPoolId
        ) = abi.decode(_payload, (IVault, address, uint16, uint16));

        require(
            !exiting[address(vault)],
            "XChainHub::_finalizeWithdrawAction exit window is not closed."
        );

        require(
            trustedVault[address(vault)],
            "XChainHub::_finalizeWithdrawAction vault is not trusted"
        );

        uint256 currentRound = currentRoundPerStrategy[_srcChainId][strategy];
        uint256 exitingShares = exitingSharesPerStrategy[_srcChainId][strategy];

        require(
            currentRound > 0,
            "XChainHub::_finalizeWithdrawAction no withdraws for strategy"
        );

        // TODO why are we resetting the current round?
        // Because the round is closed.
        currentRoundPerStrategy[_srcChainId][strategy] = 0;
        exitingSharesPerStrategy[_srcChainId][strategy] = 0;

        IERC20 underlying = vault.underlying();

        // calculate the amount based on existing shares and current batch burn round
        IVault.BatchBurn memory batchBurn = vault.batchBurns(currentRound);
        uint256 amountPerShare = batchBurn.amountPerShare;
        uint256 strategyAmount = (amountPerShare * exitingShares) /
            (10**vault.decimals());

        underlying.safeApprove(address(stargateRouter), strategyAmount);

        /// @dev review and change minAmountOut and txParams before moving to production
        stargateRouter.swap{value: msg.value}(
            // TODO Is this _srcChainId the same for Layer Zero and Stargate?
            _srcChainId, // send back to the source
            srcPoolId,
            dstPoolId,
            // TODO This probably not correct, the sender will be the layzer zero router.
            // We might want to have a default address for refunds.

            payable(msg.sender), // refund to the sender
            strategyAmount,
            0, //TODO what is this?
            IStargateRouter.lzTxObj(200000, 0, "0x"),
            strategy,
            // TODO Why do we do this? let's just pass empty bytes maybe?
            abi.encode(NO_ACTION, (uint8))
        );
    }

    /// @notice underlying holdings are updated on another chain and this function is broadcast
    ///     to all other chains for the strategy.
    /// @param _payload byte encoded data containing
    ///     IStrategy
    ///     uint256 (amount of underyling to report)
    function _reportUnderlyingAction(bytes memory _payload) internal {
        (IStrategy strategy, uint256 amountToReport) = abi.decode(
            _payload,
            (IStrategy, uint256)
        );

        strategy.report(amountToReport);
    }
}
