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

library DirtyUint64 {
    error DirtyUint64Error(uint256 errorCode);

    uint256 private constant _OVERFLOW_ERROR = 0;
    uint256 private constant _UNDERFLOW_ERROR = 1;

    function toDirtyUnsafe(uint64 cleanUint) internal pure returns (uint64 dirtyUint) {
        assembly {
            dirtyUint := add(cleanUint, 1)
        }
    }

    function toDirty(uint64 cleanUint) internal pure returns (uint64 dirtyUint) {
        assembly {
            dirtyUint := add(cleanUint, 1)
        }
        if (dirtyUint == 0) {
            revert DirtyUint64Error(_OVERFLOW_ERROR);
        }
    }

    function toClean(uint64 dirtyUint) internal pure returns (uint64 cleanUint) {
        assembly {
            cleanUint := sub(dirtyUint, gt(dirtyUint, 0))
        }
    }

    function addClean(uint64 current, uint64 cleanUint) internal pure returns (uint64) {
        assembly {
            current := add(add(current, iszero(current)), cleanUint)
        }
        if (current < cleanUint) {
            revert DirtyUint64Error(_OVERFLOW_ERROR);
        }
        return current;
    }

    function addDirty(uint64 current, uint64 dirtyUint) internal pure returns (uint64) {
        assembly {
            current := sub(add(add(current, iszero(current)), add(dirtyUint, iszero(dirtyUint))), 1)
        }
        if (current < dirtyUint) {
            revert DirtyUint64Error(_OVERFLOW_ERROR);
        }
        return current;
    }

    function subClean(uint64 current, uint64 cleanUint) internal pure returns (uint64 ret) {
        assembly {
            current := add(current, iszero(current))
            ret := sub(current, cleanUint)
        }
        if (current < ret || ret == 0) {
            revert DirtyUint64Error(_UNDERFLOW_ERROR);
        }
    }

    function subDirty(uint64 current, uint64 dirtyUint) internal pure returns (uint64 ret) {
        assembly {
            current := add(current, iszero(current))
            ret := sub(add(current, 1), add(dirtyUint, iszero(dirtyUint)))
        }
        if (current < ret || ret == 0) {
            revert DirtyUint64Error(_UNDERFLOW_ERROR);
        }
    }

    function sumPackedUnsafe(uint256 packed, uint256 from, uint256 to)
        internal
        pure
        returns (uint64 ret)
    {
        packed = packed >> (from << 6);
        unchecked {
            for (uint256 i = from; i < to; ++i) {
                assembly {
                    let element := and(packed, 0xffffffffffffffff)
                    ret := add(ret, add(element, iszero(element)))
                    packed := shr(64, packed)
                }
            }
        }
        assembly {
            ret := sub(ret, sub(to, from))
        }
    }
}
