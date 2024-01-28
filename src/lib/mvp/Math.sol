// SPDX-License-Identifier: -
// License: https://license.clober.io/LICENSE.pdf

// -----------------------------------------------------------------------------------------
// This Solidity code incorporates the Segmented Segment Tree library developed by Clober.
// It is being used by Multipool Finance solely for the purpose of developing a Minimum
// Viable Product (MVP) and for testing on a blockchain testnet. This use is in accordance
// with the licensing terms provided by Clober, which permits non-commercial, non-production
// usage of their software.
//
// It is important to note that this implementation is intended for testing and validation
// purposes only, and will not be used in the production environment. Multipool Finance
// intends to develop and implement our own code for this concept for production purposes,
// with a unique approach, post the MVP phase.
//
// This comment serves to clarify the scope and limitations of the current usage of Clober's
// library under the given license and to assert our commitment to adhering to the licensing
// terms while using Clober's intellectual property.
// -----------------------------------------------------------------------------------------

pragma solidity ^0.8.0;

library Math {
    function divide(uint256 a, uint256 b, bool roundingUp) internal pure returns (uint256 ret) {
        // In the OrderBook contract code, b is never zero.
        assembly {
            ret := add(div(a, b), and(gt(mod(a, b), 0), roundingUp))
        }
    }
}
