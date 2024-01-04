// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "./lib/mvp/SegmentedSegmentTree.sol";

contract MultipleFinanceCancellationTree {
    using SegmentedSegmentTree for SegmentedSegmentTree.Core;

    // Aggregate cancellation tree
    mapping(uint256 => SegmentedSegmentTree.Core) private aggregateCancellationTrees;

    // priceStep => offset => cancellationTree
    mapping(uint256 => mapping(uint16 => SegmentedSegmentTree.Core)) private cancellationTrees;

    function cancel(uint256 _priceStep, uint256 _orderID) external {
        // calculate offset
        // 32768 = 2^15
        uint16 offset = uint16(_orderID / 32768);
        uint16 orderID = uint16(_orderID % 32768);

        // cancel amount

        //@TODO this section should be updated
        //@audit the Clober approach limit the amount and liquidity to uint64 and it probably make issue with the token has 18 decimal place
        uint64 amount = 1;

        // cancel order
        cancellationTrees[_priceStep][offset].update(orderID, amount);

        // update aggregate cancellation tree
        aggregateCancellationTrees[_priceStep].update(offset, amount);
    }

    function getCancellationAmount(uint256 _priceStep, uint256 _orderID)
        external
        view
        returns (uint64)
    {
        // calculate offset
        // 32768 = 2^15
        uint16 offset = uint16(_orderID / 32768);
        uint16 orderID = uint16(_orderID % 32768);

        if (offset == 0) {
            return cancellationTrees[_priceStep][offset].query(0, orderID);
        } else if (offset < 5) {
            uint64 amount;
            amount += cancellationTrees[_priceStep][offset].query(0, orderID);
            for (uint16 i = 0; i < offset; i++) {
                amount += cancellationTrees[_priceStep][i].total();
            }
            return amount;
        } else {
            uint64 amount;
            amount += cancellationTrees[_priceStep][offset].query(0, orderID);
            amount += aggregateCancellationTrees[_priceStep].query(0, offset - 1);
            return amount;
        }
    }
}
