# Auxo X Chain

<span style="
    font-weight:bold;
    color:orange;
    border:1px solid orange;
    padding:5px;
">
    Warning! This repository is incomplete state and will be changing heavily
</span>

This repository contains the source code for the Auxo Cross chain hub, it consists of 3 parts:

1. The XChainHub - an interface for interacting with vaults and strategies deployed on multiple chains.

2. The XChainStrategy - an implementation of the same BaseStrategy used in the Auxo Vaults that adds support for using the XChainHub.

3. LayerZeroApp - an implementation of a nonBlockingLayerZero application that allows for cross chain messaging using the LayerZero protocol.


## The Hub
----------
The hub itself allows users to intiate vault actions from any chain and have them be executed on any other chain with a [LayerZero endpoint](https://layerzero.gitbook.io/docs/technical-reference/mainnet/supported-chain-ids). 

LayerZero applications initiate cross chain requests by calling the `endpoint.send` method, which then invokes `_nonBlockingLzReceive` on the destination chain. 

The hub itself implements a reducer pattern to route inbound messages from the `_nonBlockingLzReceive` function, to a particular internal action. The main actions are:

1. Deposit into a vault.
2. Request to withdraw from a vault (this begins the batch burn process).
3. Provided we have a successful batch burn, complete a batch burn request and send underlying funds from a vault to a user.
4. Report changes in the underlying balance of each strategy on a given chain.

Therefore, each cross chain request will go through the following workflow:

1. Call the Cross Chain function on the source chain (i.e. `depositToChain`)
2. Cross chain function will call the `_lzSend` method, which in turn calls the `LayerZeroEndpoint.send` method.
3. The LZ endpoint will call `_nonBlockingLzReceive` on the destination chain.
4. The reducer at `_nonBlockingLzReceive` will call the corresponding action passed in the payload (i.e. `_depositAction`)

## Swaps
----------
Currently, the hub utilises the [Anyswap router](https://github.com/anyswap/CrossChain-Router/wiki/How-to-integrate-AnySwap-Router) to execute cross chain deposits of the underlying token into the auxo vault. We are discussing removing the router and replacing with stargate. 

### Advantages of Stargate:
- Guaranteed instant finality if the transaction is approved, due to Stargate's cross-chain liquidity pooling.
- We can pass our payload data to the Stargate router and use `sgReceive` to both handle the swapping, and post-swap logic. This would remove the need for calls to both the LayerZero endpoint and to Anyswap router.


### Advantages of Anyswap:
- Anyswap supports a much larger array of tokens, whereas stargate only implements a few stables and Eth. 


## Implementing Stargate To Do List
--------
*This is a development reference only*

Our to do list to swap out AnySwap/LayerZero with Stargate is as follows:

- [x] Add the `IStargateRouter` to the list of interfaces
- [x] Replace the AnySwap swaps with `IStargateRouter.swap`
    - [x] `_finalizeWithdrawAction`
    - [x] `constructor`
    - [x] `depositToChain`

- [x] Replace* the `_lzSend` messages with encoded payloads in `IStargateRouter.swap`
    - [x] `depositToChain`

- [x] Keep _lzSend in:
    - [x] `reportUnderlying`
    - [x] `finalizeWithdrawFromChain`

## Known set of implementation tasks to work on:
- [ ] Implement events at different stages of the contract
- [x] Remove the NI error if we don't need it
- [ ] Confirm the Noop action with Team
- [ ] Connect finalizeWithdrawFromVault to a cross chain action
- [ ] Confirm that finalizeWithdrawFromVault is a step in _finalizeWithdrawAction
- [ ] Ensure the format of messages in `sgReceive` matches the encoding in `IStargateRouter.swap` - currently in format `encoded(Message(, encoded(payload)))`
    - [ ] Pass all payloads a Message structs
    - [ ] Check encodings, in particular encoding IVaults and IStrategies
    - [ ] Consider defining structs for all payloads to ensure consistent serialisation and deserialisation
- [x] See if the reducers can be combined by passing the payloads from both entrypoints
- [ ] Confirm the params for both stargate swaps:
    - [ ] default lzTxObj
    - [ ] minAmountOut
    - [ ] destination (strategy?)
- [ ] Refactoring: start to break down some of the larger functions into smaller chunks


## Testing
- [ ] Setup the mocks:
    - [ ] LayerZero
    - [ ] Stargate
- [ ] Define the unit test suite
- [ ] Build integration test scripts for the testnets


