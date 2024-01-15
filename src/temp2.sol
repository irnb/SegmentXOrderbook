//SPDX-License-Identifier: TBD

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./lib/mvp/SegmentedSegmentTree.sol";

contract Pair {
    using SafeERC20 for IERC20;
    using SegmentedSegmentTree for SegmentedSegmentTree.Core;

    /// STRUCTS & ENUMS ///

    enum OrderStatus {
        None,
        Open,
        Canceled,
        Claimed
    }

    struct Order {
        uint256 orderIndexInPricePoint;
        uint256 preOrderLiquidityPosition;
        uint256 tokenAmount;
        uint256 price;
        address user;
        bool isBuy;
        OrderStatus status;
    }

    struct PricePoint {
        uint256 totalBuyLiquidity;
        uint256 totalSellLiquidity;
        uint256 usedBuyLiquidity;
        uint256 usedSellLiquidity;
        uint256 orderCount;
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
    uint256 public latestTradePrice;

    mapping(uint256 => Order) public orders;
    mapping(uint256 => PricePoint) public pricePoints;

    /// @dev `pricePointOrderCounts` priceStep => offset => cancellationTree
    mapping(uint256 => mapping(uint16 => SegmentedSegmentTree.Core)) private
        _pricePointCancellationTrees;
    /// @dev `offsetAggregatedCancellationTrees`  Aggregate cancellation tree => priceStep => cancellationTree
    mapping(uint256 => SegmentedSegmentTree.Core) private _offsetAggregatedCancellationTrees;

    address public governanceTreasury;

    constructor(
        address baseTokenAddress_,
        address quoteTokenAddress_,
        uint256 quoteUnit_,
        uint24 makerFee_,
        uint24 takerFee_,
        address governanceTreasury_
    ) {
        _baseToken = IERC20(baseTokenAddress_);
        _quoteToken = IERC20(quoteTokenAddress_);

        _quotePrecisionComplement = _getDecimalComplement(quoteTokenAddress_);
        _basePrecisionComplement = _getDecimalComplement(baseTokenAddress_);

        quoteUnit = quoteUnit_;

        makerFee = makerFee_;
        takerFee = takerFee_;
        
        governanceTreasury = governanceTreasury_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Insert a limit order
    /// @param isBuy True if the order is a buy order, false if it is a sell order
    /// @param price This represents the value of the base token in terms of the quote token.
    /// For instance, in an ETH/USD pair with a price of 2000, 1 ETH is equivalent to 2000 USD.
    /// In this Multipool version, the price is always determined by the quote token for both buy and sale orders.
    /// @param amount The amount of the base token to buy or sell
    /// @dev first we transfer the tokens the user wants to sell to the contract
    /// if the order is a buy order, we transfer the quote token to the contract with the amount = price * amount
    /// if the order is a sell order, we transfer the base token to the contract with the amount = amount
    /// then we check for order matching at the same and if we need 5 better prices points to match the order
    /// if it get matched, we transfer the tokens to the user and collect the taker fees and emit the taker events
    /// (the events contain the orderId)
    /// if there was any remaining amount, we add it to the order book (updating the price point and adding the
    /// order to orders mapping and updating the order count) and emit the maker events (the events contain the orderId)
    function insertLimitOrder(bool isBuy, uint256 price, uint256 amount) external {}

    /// @notice insert a market order
    /// @param isBuy True if the order is a buy order, false if it is a sell order
    /// @param amount The amount of the base token to buy or sell
    /// @param maxPrice The maximum price the user is willing to pay for a buy order or
    /// the minimum price the user is willing to accept for a sell order
    /// @dev first we detect the side of the order (buy or sell) and the latest trade price
    /// then we start checking for liquidity at the latest trade price and check its enough to fill the order or not
    /// if it was enough, we calculate the amount of the user should pay
    /// for buy orders, amount = amount * latestTradePrice and using the transferFrom to transfer this much of quote token from the user to the contract
    /// for sell orders, amount = amount and using the transferFrom to transfer this much of base token from the user to the contract
    /// then we transfer the tokens to the user and collect the taker fees and emit the taker events and update the price point
    /// if it was not enough, we start checking for liquidity at the next price point and add the amount of the liquidity from previous price point we checked
    /// and again check if it was enough to fill the order or not
    /// if it was enough, we do the same as above and update the all the price points we checked
    /// if it was not enough, we continue checking till we get to the max price the user specified and if we didn't find enough liquidity, we revert
    function insertMarketOrder(bool isBuy, uint256 amount, uint256 maxPrice) external {}

    /// @notice claim the filled order
    /// @param orderId The id of the order to claim
    /// @param user The user who wants to claim the order
    /// @dev first we check the order status and it should be the open if it is not, we revert
    /// then we fetch the order from the orders mapping and check if the user is the same as the msg sender
    /// and now we should do some calculations to check the order is claimable or not (we discuss the calculations in the last line)
    /// if the order was fully claimable we calculate the maker fees and then transfer the suitable token to the user
    /// (buy orders: base token, sell orders: quote token) and collect the maker fees and emit the claim events and update the price point
    /// if the order wasn't fully claimable we revert (for claiming the partial filled orders user can use the cancel order function)
    /// the calculations:
    ///     for buy orders:
    ///         a. fetch the sum of the cancellation tree from 0 to the order index in the price point in the buy side
    ///         b. first we scale up the result and then subtract the sum of the cancellation range result from the preOrderLiquidityPosition of the order to find real liquidity position start
    ///         c. add the order amount to the real liquidity position start to find real liquidity position end
    ///         d. check if the real liquidity position end is smaller than or equal with the usedBuyLiquidity in the price point
    ///         e. if it was smaller, the order is fully claimable
    ///     for sell orders: (the same as buy orders but in the sell side)
    function claimOrder(uint256 orderId, address user) external {}

    /// @notice cancel the order
    /// @param orderId The id of the order to cancel
    /// @dev first we check the order status and it should be the open if it is not, we revert
    /// then we fetch the order from the orders mapping and check if the user is the same as the msg sender
    /// now we should check the order is the claimable or not (we discuss the calculations in the claim order function)
    /// based on the state of claimable, we should do different things:
    ///     a. not claimable:
    ///         in this case we should add the order amount and index to the cancellation tree
    ///         and transfer the original amount of the order to the user and emit the cancel events
    ///         before updating cancellation tree we should scale down the order amount we discuss about our scaling down method in the related method documentation
    ///     b. fully claimable:
    ///         in this case we act like the claim order function and we don't transfer the original amount of the order to the user
    ///         and we don't add the order amount and index to the cancellation tree and also we should get taker fee and emit the claim events
    ///     c. partially claimable:
    ///         in this case we claim the part of the order get filled and we cancel the rest of the order and we emit the claim and cancel events and also we need to
    ///         update the cancellation tree for the part of order it's not filled and get the taker fee for the part of order it's filled
    function cancelOrder(uint256 orderId) external {}

    /// @notice collect the fees
    /// @dev first we check the msg sender is the governance treasury or not if it is not, we revert
    /// then we transfer the fee collected in the form of quote and base token to the treasury.
    /// and we should update the related state variables
    function collectFees() external {}


    /// @notice update the fees
    /// @param makerFee_ The new maker fee
    /// @param takerFee_ The new taker fee
    /// @dev first we check the msg sender is the governance treasury or not if it is not, we revert
    /// then we update the maker and taker fees
    function updateFees(uint24 makerFee_, uint24 takerFee_) external {}

    

    /// INTERNAL FUNCTIONS ///

    function _getDecimalComplement(address token) internal view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(token).decimals());
    }
}
