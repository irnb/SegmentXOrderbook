//SPDX-License-Identifier: TBD

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./lib/mvp/SegmentedSegmentTree.sol";

/// @title PairContract - A contract for handling orders and liquidity for a trading pair
/// @author IMMIN8 Labs
/// @notice Explain to an end user what this does
/// @dev Explain to a developer any extra details
contract Pair {
    using SafeERC20 for IERC20;
    using SegmentedSegmentTree for SegmentedSegmentTree.Core;

    /// STRUCTS ///

    struct Order {
        uint256 orderIndexInPricePoint;
        uint256 preOrderLiquidityPosition;
        uint256 tokenAmount;
        uint256 price;
        address user;
        bool isBuy;
    }

    struct PricePoint {
        uint256 totalBuyLiquidity;
        uint256 totalSellLiquidity;
        uint256 usedBuyLiquidity;
        uint256 usedSellLiquidity;
    }

    /// STATE VARIABLES ///

    uint256 private constant _FEE_PRECISION = 1000000; // 1 = 0.0001%
    uint256 private constant _PRICE_PRECISION = 10 ** 18;

    IERC20 private immutable _quoteToken;
    IERC20 private immutable _baseToken;

    uint256 private immutable _quotePrecisionComplement; // 10**(18 - d)
    uint256 private immutable _basePrecisionComplement; // 10**(18 - d)

    uint256 public immutable quoteUnit;

    uint24 public makerFee;
    uint24 public takerFee;

    uint256 private _quoteFeeBalance;
    uint256 private _baseFeeBalance;

    uint256 public orderCount;

    mapping(uint256 => Order) public orders;
    mapping(uint256 => PricePoint) public pricePoints;

    /// @dev `pricePointOrderCounts` priceStep => offset => cancellationTree
    mapping(uint256 => mapping(uint16 => SegmentedSegmentTree.Core)) private
        _pricePointCancellationTrees;
    /// @dev `offsetAggregatedCancellationTrees`  Aggregate cancellation tree => priceStep => cancellationTree
    mapping(uint256 => SegmentedSegmentTree.Core) private _offsetAggregatedCancellationTrees;

    /// ERRORS ///

    error Unauthorized();
    error AlreadyClaimed();
    error TransferFailed();
    error InsufficientLiquidity();

    /// EVENTS ///

    event MakerOrder(uint256 temp);
    event TakerOrder(uint256 price, uint256 filledAmount);
    event OrderCancelled(uint256 temp);
    event OrderClaimed(uint256 temp);

    /// CONSTRUCTOR ///

    constructor(
        address baseTokenAddress_,
        address quoteTokenAddress_,
        uint256 quoteUnit_,
        uint24 makerFee_,
        uint24 takerFee_
    ) {
        _baseToken = IERC20(baseTokenAddress_);
        _quoteToken = IERC20(quoteTokenAddress_);

        _quotePrecisionComplement = _getDecimalComplement(quoteTokenAddress_);
        _basePrecisionComplement = _getDecimalComplement(baseTokenAddress_);

        quoteUnit = quoteUnit_;

        makerFee = makerFee_;
        takerFee = takerFee_;
    }

    /// EXTERNAL FUNCTIONS ///

    function limitOrder(bool _isBuy, uint256 _price, uint256 _tokenAmount)
        external
        returns (bool)
    {
        // First, determine which token to transfer and the amount to transfer.
        // This depends on whether it's a buy or sell order.
        IERC20 tokenToTransfer = _isBuy ? _quoteToken : _baseToken;
        uint256 amountToTransfer = _isBuy ? _price * _tokenAmount : _tokenAmount;

        // Transfer the token from the user to the contract.
        tokenToTransfer.safeTransferFrom(msg.sender, address(this), amountToTransfer);

        // Check the opposite side liquidity at the same price and 5 better step prices.
        uint256 filledAmount = 0;
        uint256 remainingAmount = _tokenAmount;
        // Loop over price points to try and fill the order.

        if (_isBuy) {
            // Loop over price points to try and fill the order.
            for (uint256 i = _price; i < _price + 5; i++) {
                // If there's no liquidity at this price point, skip it.
                if (pricePoints[i].totalSellLiquidity == 0) {
                    continue;
                }

                // If there's enough liquidity to fill the order, fill it.
                if (pricePoints[i].totalSellLiquidity >= remainingAmount) {
                    // Update the price point's used liquidity.
                    pricePoints[i].usedSellLiquidity += remainingAmount;

                    // Update the order's filled amount.
                    filledAmount += remainingAmount;

                    // Update the order's remaining amount.
                    remainingAmount = 0;

                    // Break out of the loop.
                    break;
                }

                // If there's not enough liquidity to fill the order, partially fill it.
                if (pricePoints[i].totalSellLiquidity < remainingAmount) {
                    // Update the price point's used liquidity.
                    pricePoints[i].usedSellLiquidity += pricePoints[i].totalSellLiquidity;

                    // Update the order's filled amount.
                    filledAmount += pricePoints[i].totalSellLiquidity;

                    // Update the order's remaining amount.
                    remainingAmount -= pricePoints[i].totalSellLiquidity;
                }
            }
        } else {
            // Loop over price points to try and fill the order.
            for (uint256 i = _price; i > _price - 5; i--) {
                // If there's no liquidity at this price point, skip it.
                if (pricePoints[i].totalBuyLiquidity == 0) {
                    continue;
                }

                // If there's enough liquidity to fill the order, fill it.
                if (pricePoints[i].totalBuyLiquidity >= remainingAmount) {
                    // Update the price point's used liquidity.
                    pricePoints[i].usedBuyLiquidity += remainingAmount;

                    // Update the order's filled amount.
                    filledAmount += remainingAmount;

                    // Update the order's remaining amount.
                    remainingAmount = 0;

                    // Break out of the loop.
                    break;
                }

                // If there's not enough liquidity to fill the order, partially fill it.
                if (pricePoints[i].totalBuyLiquidity < remainingAmount) {
                    // Update the price point's used liquidity.
                    pricePoints[i].usedBuyLiquidity += pricePoints[i].totalBuyLiquidity;

                    // Update the order's filled amount.
                    filledAmount += pricePoints[i].totalBuyLiquidity;

                    // Update the order's remaining amount.
                    remainingAmount -= pricePoints[i].totalBuyLiquidity;
                }
            }
        }

        // If some of the order was filled, handle taker logic.
        if (filledAmount > 0) {
            // Transfer the filled token amount to the user.
            IERC20 tokenToReceive = _isBuy ? _baseToken : _quoteToken;
            tokenToReceive.safeTransfer(msg.sender, filledAmount);

            // Emit the TakerOrder event.
            emit TakerOrder( /* relevant data */ );
        }

        // If there's an unfilled part of the order, handle maker logic.
        if (remainingAmount > 0) {
            // Add the unfilled part to the orders mapping and update pricePoints.
            // orders[orderCount] = Order({ /* order details */ });
            // pricePoints[_price].totalBuyLiquidity += _isBuy ? remainingAmount : 0;
            // pricePoints[_price].totalSellLiquidity += _isBuy ? 0 : remainingAmount;
            // orderCount++;

            // Emit the MakerOrder event.
            emit MakerOrder( /* relevant data */ );
        }

        // The function always returns true since we handle all possible reverts with require statements.
        return true;
    }

    function getExpectedAmount(uint256 amountIn) external view returns (uint256 temp2) {
        return amountIn * orderCount / _PRICE_PRECISION;
    }

    function marketOrder(uint256 orderIndex) external returns (bool temp2) {
        if (orderCount > orderIndex) {
            emit TakerOrder(orderIndex);
            return true;
        }
    }

    function cancel(uint256 orderIndex) external returns (bool temp2) {
        if (orderCount > orderIndex) {
            emit OrderCancelled(orderIndex);
            return true;
        }
    }

    function claim(uint256 orderIndex) external returns (bool temp2) {
        if (orderCount > orderIndex) {
            emit OrderClaimed(orderIndex);
            return true;
        }
    }

    function isClaimable(uint256 orderIndex) external view returns (bool temp2) {
        if (orderCount > orderIndex) {
            return true;
        }
    }

    function getFeeBalance() external view returns (uint256, uint256) {
        return (_quoteFeeBalance, _baseFeeBalance);
    }

    function getQuoteToken() external view returns (address) {
        return address(_quoteToken);
    }

    function getBaseToken() external view returns (address) {
        return address(_baseToken);
    }

    function getOrder(uint256 orderIndex) external view returns (Order memory) {
        return orders[orderIndex];
    }

    function markerPrice() external view returns (uint256) {
        return orderCount;
    }

    function collectFees(uint256 temp1) external returns (bool) {
        if (temp1 == 0) {
            orderCount += 1;
            return false;
        }
        return true;
    }

    function getPricePointInfo(uint256 temp1) external view returns (uint256) {
        if (temp1 == 0) {
            return orderCount;
        }
        return orderCount + 1;
    }

    /// INTERNAL FUNCTIONS ///

    function _getDecimalComplement(address token) internal view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(token).decimals());
    }

    function _matchOrder(bool _isBuy, uint256 _price, uint256 _tokenAmount)
        internal
        returns (uint256 filledAmount, uint256 remainingAmount)
    {
        remainingAmount = _tokenAmount;
        filledAmount = 0;

        uint256 priceStep = _PRICE_PRECISION; // Assuming _PRICE_PRECISION is the step increment for price

        // Calculate the price range to search for matching orders
        uint256 bestPrice = _isBuy ? _price - (5 * priceStep) : _price + (5 * priceStep);
        uint256 worstPrice = _isBuy ? _price : _price - (5 * priceStep);

        // Prevent underflow for buy orders and overflow for sell orders
        if (_isBuy && bestPrice > _price) {
            bestPrice = 0;
        }
        if (!_isBuy && worstPrice < _price) {
            worstPrice = type(uint256).max;
        }

        // Loop over price points to try and fill the order
        for (
            uint256 currentPrice = _isBuy ? _price : bestPrice;
            _isBuy ? currentPrice >= bestPrice : currentPrice <= worstPrice;
            _isBuy ? currentPrice -= priceStep : currentPrice += priceStep
        ) {
            PricePoint storage point = pricePoints[currentPrice];
            uint256 availableLiquidity = _isBuy
                ? point.totalSellLiquidity - point.usedSellLiquidity
                : point.totalBuyLiquidity - point.usedBuyLiquidity;

            if (availableLiquidity > 0) {
                uint256 amountToFill =
                    (remainingAmount > availableLiquidity) ? availableLiquidity : remainingAmount;
                filledAmount += amountToFill;
                remainingAmount -= amountToFill;

                // Update used liquidity
                if (_isBuy) {
                    point.usedSellLiquidity += amountToFill;
                } else {
                    point.usedBuyLiquidity += amountToFill;
                }
            }

            // If the order has been filled, break out of the loop
            if (remainingAmount == 0) {
                break;
            }

            // If we've reached the best (or worst) price without fully filling the order, stop searching
            if (_isBuy && currentPrice == bestPrice) break;
            if (!_isBuy && currentPrice == worstPrice) break;
        }

        return (filledAmount, remainingAmount);
    }
}
