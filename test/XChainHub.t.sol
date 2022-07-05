// SPDX-License-Identifier: UNLICENSED
/* 
    Tests for the x chain hub. These should cover:
        - Variables - the various mappings are set correctly
        - The LayerZero and Stargate components are set in the constructor

        Report Underlying correctly sets underlying amounts for a set of strategies
        - It reverts if the strategy/chain arrays are misconfigured
        - It reverts if there are issues with the vault
        - Reverts if vault underlying doesn't match strategy underlying?
        - Makes a properly formatted call to the lzEndpoint
        - Record the latest updates correctly

        Deposit
        - Revert conditions
        - Makes the correctly formatted request to stargate router



*/
pragma solidity ^0.8.13;
