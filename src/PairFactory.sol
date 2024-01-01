// SPDX-License-Identifier: TBD
pragma solidity 0.8.20;

import "./PairContract.sol";

contract FactoryContract {
    // Event emitted when a new pair is created
    event PairCreated(
        address indexed baseToken, address indexed quoteToken, address pairAddress, string version
    );

    // Mapping to track deployed pairs with a unique identifier
    mapping(bytes32 => address) public deployedPairs;

    // Custom errors for specific failure scenarios
    error PairAlreadyDeployed();
    error InvalidAddress(string addressType);

    // Function to create a new trading pair contract
    function createPair(
        address baseToken,
        address quoteToken,
        address uniswapPairAddress,
        string memory uniswapVersion,
        uint256 initialPrice
    ) public {
        // Validate that the provided addresses are not zero addresses
        if (baseToken == address(0)) {
            revert InvalidAddress("Base Token");
        }
        if (quoteToken == address(0)) {
            revert InvalidAddress("Quote Token");
        }
        if (uniswapPairAddress == address(0)) {
            revert InvalidAddress("Uniswap Pair");
        }

        // Create a unique key for the pair based on the tokens and version
        bytes32 pairKey = keccak256(abi.encodePacked(baseToken, quoteToken, uniswapVersion));

        // Ensure that the pair has not already been deployed
        if (deployedPairs[pairKey] != address(0)) {
            revert PairAlreadyDeployed();
        }

        // Create a new PairContract with the provided details, including the initial price
        PairContract newPair = new PairContract(
            baseToken, quoteToken, uniswapPairAddress, uniswapVersion, initialPrice
        );

        // Store the address of the new PairContract in the mapping
        deployedPairs[pairKey] = address(newPair);

        // Emit an event to log the creation of the new pair
        emit PairCreated(baseToken, quoteToken, address(newPair), uniswapVersion);
    }
}
