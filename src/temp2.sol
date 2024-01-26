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

    enum PricePointDirection {
        Deposit,
        Withdraw
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
        uint256 buyOrderCount;
        uint256 sellOrderCount;
    }

    struct MatchedPricePoint {
        uint256 pricePoint;
        uint256 amount;
    }

    /// STATE VARIABLES ///

    uint256 private constant _FEE_PRECISION = 1000000; // 1 = 0.0001%
    uint8 private constant _MAX_MATCHED_PRICE_POINTS = 5;
    uint16 private constant _OFFSET_PER_PRICE_POINT = 32768; // 2^15

    IERC20 private immutable _quoteToken;
    IERC20 private immutable _baseToken;

    uint256 private immutable _quotePrecisionComplement; // 10**(18 - d)
    uint256 private immutable _basePrecisionComplement; // 10**(18 - d)

    uint256 public immutable quoteUnit;

    uint24 public makerFee;
    uint24 public takerFee;
    uint256 public pricePrecision = 10 ** 18;

    /// for the `sellLeadingPricePoints`, the smaller price is the leading price
    /// for the `buyLeadingPricePoints`, the bigger price is the leading price
    uint256 public sellLeadingPricePoint;
    uint256 public buyLeadingPricePoint;

    uint256 private _quoteFeeBalance;
    uint256 private _baseFeeBalance;

    uint256 public orderCount;

    uint256 public latestTradePrice;

    mapping(uint256 => Order) public orders;
    mapping(uint256 => PricePoint) public pricePoints;

    /// @dev `pricePointOrderCounts` priceStep => offset => cancellationTree
    mapping(uint256 => mapping(uint16 => SegmentedSegmentTree.Core)) private
        _pricePointBuyCancellationTrees;

    /// @dev `pricePointOrderCounts` priceStep => offset => cancellationTree
    mapping(uint256 => mapping(uint16 => SegmentedSegmentTree.Core)) private
        _pricePointSellCancellationTrees;

    /// @dev `offsetAggregatedCancellationTrees`  Aggregate cancellation tree => priceStep => cancellationTree
    mapping(uint256 => SegmentedSegmentTree.Core) private _offsetAggregatedBuyCancellationTrees;

    /// @dev `offsetAggregatedCancellationTrees`  Aggregate cancellation tree => priceStep => cancellationTree
    mapping(uint256 => SegmentedSegmentTree.Core) private _offsetAggregatedSellCancellationTrees;

    address public governanceTreasury;

    /// ERRORS ///

    error ExceedWorstPrice(uint256 worstPrice, uint256 price);
    error NotEnoughLiquidity();
    error InvalidOrderStatus(uint256 orderId, OrderStatus status);
    error IsNotFullyClaimable();
    error InvalidCaller(address caller);

    /// EVENTS ///

    /// @notice Emitted when a user inserts a limit order via the `insertLimitOrder` method.
    /// @dev This event denotes one of three possible outcomes when `insertLimitOrder` is invoked:
    ///      1. Full Match: The order is completely matched, setting `remainingAmount` to 0. NOTE: `matchedPricePoints` and `matchedAmounts`
    ///         detail the match, with each index in `matchedAmounts` corresponding to the same index in `matchedPricePoints`.
    ///      2. Partial Match: The order is partially matched, leaving `remainingAmount` greater than 0. `matchedPricePoints` and `matchedAmounts`
    ///         contain the partial match details.
    ///      3. No Match: The order finds no match, keeping `remainingAmount` equal to the original order amount, and leaving `matchedPricePoints` and
    ///         `matchedAmounts` arrays empty.
    /// @param orderId Identifier for the order, equating to `orderCount` prior to the order's insertion.
    /// @param user Address of the user who placed the order.
    /// @param pricePoint Price set for the base token in terms of the quote token.
    /// @param matchedPricePoints Array of MatchedPricePoint struct where the order found a match.
    /// @param remainingAmount Unmatched amount of the order.
    /// @param isBuy Boolean flag indicating the order type: `true` for buy, `false` for sell.
    event LimitOrderInserted(
        uint256 indexed orderId,
        address indexed user,
        uint256 pricePoint,
        MatchedPricePoint[] matchedPricePoints,
        uint256 remainingAmount,
        bool isBuy
    );

    /// @notice Emitted when a market order is placed using the `insertMarketOrder` method.
    /// @dev For a market order, the `orderId` equals `orderCount` at the time of insertion, but unlike limit orders, market orders
    ///      are not stored in the orders mapping. The `orderId` solely serves as an identifier. The structure of `matchedPricePoints`
    ///      and `matchedAmounts` is akin to that in the `LimitOrderInserted` event. Market orders do not specify a price, as they are
    ///      executed at any available price for a set amount. The `worstPrice` parameter is the upper price limit acceptable to the user,
    ///      helping to mitigate potential user-side attack vectors.
    /// @param orderId Identifier for the order, corresponding to `orderCount` just before the order's insertion.
    /// @param user Address of the user who initiated the order.
    /// @param amount Desired transaction amount in the base token.
    /// @param matchedPricePoints Array of MatchedPricePoint struct at which the order matched.
    /// @param worstPrice Maximum acceptable price set by the user for executing the order.
    /// @param isBuy Boolean flag to indicate the order type: `true` for a buy order, `false` for a sell order.
    event MarketOrderInserted(
        uint256 indexed orderId,
        address indexed user,
        uint256 amount,
        MatchedPricePoint[] matchedPricePoints,
        uint256 worstPrice,
        bool isBuy
    );

    /// @notice Emitted upon the cancellation of a limit order using the `cancelOrder` method.
    /// @dev Cancelling an order results in one of three scenarios:
    ///      1. Non-Claimable Order: The order is entirely unmatched. The user gets the full original order amount back,
    ///         setting `receiveBackAmount` equal to this amount and `claimedAmount` to zero.
    ///      2. Fully Claimable Order: The order is completely matched. The user receives the corresponding amount in the
    ///         alternate asset.
    ///      3. Partially Claimable Order: The order is partially matched. The user receives the unmatched portion in the
    ///         original asset and the matched portion in the alternate asset.
    /// @param orderId The unique identifier of the order.
    /// @param user The address of the user who placed the order.
    /// @param pricePoint The specified price for the base token in quote token terms.
    /// @param receiveBackAmount The amount of the original asset to be returned to the user.
    /// @param claimedAmount The amount of the alternate asset to be returned to the user.
    /// @param filledAmountFee The fee amount in the alternate asset to be collected.
    /// @param isBuy A boolean flag indicating the type of order: `true` for a buy order, `false` for a sell order.
    event LimitMakerOrderCanceled(
        uint256 indexed orderId,
        address indexed user,
        uint256 pricePoint,
        uint256 receiveBackAmount,
        uint256 claimedAmount,
        uint256 filledAmountFee,
        bool isBuy
    );

    /// @notice Emitted upon the claiming of a limit order using the `claimOrder` method.
    /// @param orderId The unique identifier of the order.
    /// @param user The address of the user who placed the order.
    /// @param pricePoint The specified price for the base token in quote token terms.
    /// @param claimedAmount The amount of the alternate asset to be returned to the user.
    /// @param fee The fee amount in the alternate asset to be collected.
    /// @param isBuy A boolean flag indicating the type of order: `true` for a buy order, `false` for a sell order.
    event LimitMakerOrderClaimed(
        uint256 indexed orderId,
        address indexed user,
        uint256 pricePoint,
        uint256 claimedAmount,
        uint256 fee,
        bool isBuy
    );

    /// @notice Emitted upon the calling updateFees method.
    /// @param makerFee The new fee to be set for makers.
    /// @param takerFee The new fee to be set for takers.
    event FeePolicyUpdated(uint24 makerFee, uint24 takerFee, uint256 pricePrecision);

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

    /// @notice insertLimitOrder - Places a limit order in the trading system.
    /// @param isBuy Indicates the order type: `true` for a buy order, `false` for a sell order.
    /// @param price The price of the base token in terms of the quote token.
    ///              For a pair like ETH/USD, a price of 2000 means 1 ETH equals 2000 USD.
    /// @param amount The quantity of the base token to be bought or sold.
    /// @dev Order Processing Steps:
    ///      1. Transfer the tokens the user wishes to trade to the contract.
    ///         - For a buy order: Transfer the quote token to the contract. The transfer amount is calculated as `price * amount`.
    ///         - For a sell order: Transfer the base token to the contract. The transfer amount is equal to `amount`.
    ///      2. Check for a match in the order book. We look for matching orders at the current price point and up to 5 more favorable price points.
    ///      3. If a match is found:
    ///         - Execute the trade by transferring the corresponding tokens to the user.
    ///         - Collect taker fees.
    ///         - Emit taker events, which include the `orderId`.
    ///      4. If there is any remaining amount that was not matched:
    ///         - Add the remaining amount to the order book. This involves updating the price point and adding the order to the orders mapping, as well as updating the order count.
    ///         - Emit maker events, which also include the `orderId`.
    /// @dev Note: It's important to monitor the maximum amount and price to maintain integrity, especially when an order is canceled.
    /// @dev Note: if we had limit taker order, we update the latest trade price
    function insertLimitOrder(bool isBuy, uint256 price, uint256 amount) external {
        IERC20 token = isBuy ? _quoteToken : _baseToken;
        uint256 transferAmount = isBuy ? price * amount : amount;

        // Transfer tokens from the user to the contract
        token.safeTransferFrom(msg.sender, address(this), transferAmount);

        // Check for a match in the order book
        (MatchedPricePoint[] memory matchedPricePoints, uint8 matchFoundCount) =
            _findMatchedPricePoints(isBuy, price, amount);

        uint256 remainingAmount = amount;
        uint256 matchedAmount = 0;
        uint256 matchedAmountForTransfer = 0;

        for (uint8 i = 0; i < matchFoundCount; i++) {
            // update the price point
            _updatePricePoint(
                matchedPricePoints[i].pricePoint,
                matchedPricePoints[i].amount,
                isBuy,
                false,
                PricePointDirection.Withdraw
            );

            // update the remaining amount
            remainingAmount -= matchedPricePoints[i].amount;

            // update the matched amount
            matchedAmount += matchedPricePoints[i].amount;

            // update the matched amount for transfer
            if (isBuy) {
                matchedAmountForTransfer += matchedPricePoints[i].amount;
            } else {
                matchedAmountForTransfer +=
                    matchedPricePoints[i].amount * matchedPricePoints[i].pricePoint;
            }
        }

        if (remainingAmount > 0) {
            // update the price point
            _updatePricePoint(price, remainingAmount, isBuy, false, PricePointDirection.Deposit);

            uint256 orderCountInPricePoint =
                isBuy ? pricePoints[price].buyOrderCount : pricePoints[price].sellOrderCount;
            // add the order to the orders mapping
            uint256 preOrderLiquidityPosition =
                isBuy ? pricePoints[price].usedBuyLiquidity : pricePoints[price].usedSellLiquidity;
            orders[orderCount] = Order(
                orderCountInPricePoint,
                preOrderLiquidityPosition,
                remainingAmount,
                price,
                msg.sender,
                isBuy,
                OrderStatus.Open
            );

            // update the pricePoint order count
            if (isBuy) {
                pricePoints[price].buyOrderCount++;
            } else {
                pricePoints[price].sellOrderCount++;
            }
        }

        if (matchedAmount > 0) {
            // update the latest trade price
            latestTradePrice = matchedPricePoints[matchedPricePoints.length - 1].pricePoint;

            // Transfer matched tokens to the user and collect taker fees
            _executeTakerOrder(isBuy, matchedAmountForTransfer);
        }

        // Emit events
        emit LimitOrderInserted(
            orderCount, msg.sender, price, matchedPricePoints, remainingAmount, isBuy
        );

        // Update the order count
        orderCount++;
    }

    /// @notice insertMarketOrder - Submits a market order in the trading platform.
    /// @param isBuy Indicates the order type: `true` for a buy order, `false` for a sell order.
    /// @param amount The quantity of the base token to be bought or sold.
    /// @param worstPrice For a buy order, it's the maximum price the user is willing to pay.
    ///                   For a sell order, it's the minimum price the user will accept.
    /// @dev Execution Process:
    ///      1. Determine the order type (buy or sell) and fetch the latest trade price.
    ///      2. Check liquidity at the latest trade price to assess if it's sufficient to execute the order.
    ///         - If enough liquidity is available:
    ///           - For buy orders: Calculate `amount = amount * latestTradePrice`. Transfer the equivalent quote token from the user to the contract.
    ///           - For sell orders: Transfer the stated base token amount from the user to the contract.
    ///         - Execute the trade, transfer tokens to the user, collect taker fees, emit taker events, and update the price point.
    ///      3. If liquidity is inadequate:
    ///         - Sequentially check liquidity at subsequent price points, accumulating liquidity from each checked point.
    ///         - If the aggregated liquidity meets the order requirements, execute as described above, updating all checked price points.
    ///      4. If sufficient liquidity is not found up to the maxPrice, revert the transaction.
    /// @dev Note: Market orders don't have an order ID. Therefore, `0` is used as the order ID in event emissions.
    /// @dev Note: We should update the latest trade price
    /// @dev Note: In the case of scenario 3, for calculating the amount that user should pay, we should use theses formulas:
    ///           - For buy orders:  (liquidityInPricePoint0 * PricePoint0 + liquidityInPricePoint1 * PricePoint1 + ... + liquidityInPricePointN * PricePointN)
    ///           - For sell orders: (liquidityInPricePoint0 + liquidityInPricePoint1 + ... + liquidityInPricePointN)
    function insertMarketOrder(bool isBuy, uint256 amount, uint256 worstPrice) external {
        (MatchedPricePoint[] memory matchedPricePoints, uint8 matchFoundCount) =
            _findMatchedPricePoints(isBuy, latestTradePrice, amount);

        if (matchFoundCount == 0) {
            revert NotEnoughLiquidity();
        }

        uint256 remainingAmount = amount;
        uint256 matchedAmountForTransfer = 0;

        for (uint8 i = 0; i < matchedPricePoints.length; i++) {
            if (matchedPricePoints[i].pricePoint > worstPrice) {
                revert ExceedWorstPrice(worstPrice, matchedPricePoints[i].pricePoint);
            }

            // update the price point
            _updatePricePoint(
                matchedPricePoints[i].pricePoint,
                matchedPricePoints[i].amount,
                isBuy,
                false,
                PricePointDirection.Withdraw
            );

            // update the remaining amount
            remainingAmount -= matchedPricePoints[i].amount;

            // update the matched amount for transfer
            if (isBuy) {
                matchedAmountForTransfer +=
                    matchedPricePoints[i].amount * matchedPricePoints[i].pricePoint;
            } else {
                matchedAmountForTransfer += matchedPricePoints[i].amount;
            }
        }

        if (remainingAmount > 0) {
            revert NotEnoughLiquidity();
        }

        // transfer the tokens to the contract
        IERC20 token = isBuy ? _quoteToken : _baseToken;
        token.safeTransferFrom(msg.sender, address(this), matchedAmountForTransfer);

        // update the latest trade price
        latestTradePrice = matchedPricePoints[matchedPricePoints.length - 1].pricePoint;

        // Transfer matched tokens to the user and collect taker fees
        _executeTakerOrder(isBuy, amount);

        // Emit events
        emit MarketOrderInserted(
            orderCount, msg.sender, amount, matchedPricePoints, worstPrice, isBuy
        );

        // Update the order count
        orderCount++;
    }

    /// @notice claimFilledOrder - Claims a filled order from the trading system.
    /// @param orderId The identifier of the order to be claimed.
    /// @param user The user who owns the order.
    /// @dev Process Overview:
    ///      1. Verify the order status. It must be 'open'; otherwise, revert the transaction.
    ///      2. Retrieve the specified order from the orders mapping.
    ///      3. Perform calculations to determine if the order is fully claimable. (Details of these calculations are described below).
    ///         - If the order is fully claimable:
    ///           - Calculate maker fees.
    ///           - Transfer the appropriate tokens to the user (base tokens for buy orders, quote tokens for sell orders).
    ///           - Collect maker fees, emit claim events, and update the price point.
    ///         - If the order is not fully claimable, revert the transaction. (Note: For claiming partially filled orders, users should use the cancel order function).
    /// @dev Claimability Calculations:
    ///      - For buy orders:
    ///        a. Accumulate the cancellation tree sum from index 0 to the order's index at the buy side price point.
    ///        b. Scale up the result, then deduct the sum of the cancellation range from the order's preOrderLiquidityPosition to find the start of the real liquidity position.
    ///        c. Add the order amount to this real start point to determine the end of the real order liquidity position.
    ///        d. Check if this end point is less than or equal to the usedBuyLiquidity at the price point.
    ///        e. If it is, the order is fully claimable.
    ///      - For sell orders:
    ///        Follow the same steps as for buy orders, but apply them to the sell side.
    function claimOrder(uint256 orderId, address user) external {
        Order memory order = orders[orderId];

        if (order.status != OrderStatus.Open) {
            revert InvalidOrderStatus(orderId, order.status);
        }

        (bool isFullyClaimable, uint256 claimableAmount) = _claimStatus(order);

        if (!isFullyClaimable) {
            revert IsNotFullyClaimable();
        }

        // update the price point
        _updatePricePoint(
            order.price, order.tokenAmount, order.isBuy, false, PricePointDirection.Withdraw
        );

        // update the order status
        orders[orderId].status = OrderStatus.Claimed;

        // transfer the tokens and take maker fees
        uint256 fee = _executeClaimTransfer(order.isBuy, claimableAmount);

        // Emit events

        emit LimitMakerOrderClaimed(orderId, user, order.price, claimableAmount, fee, order.isBuy);
    }

    /// @notice cancelOrder - Cancels an existing order in the trading system.
    /// @param orderId The identifier of the order to be canceled.
    /// @dev Execution Steps:
    ///      1. Verify the order status. It must be 'open'; if not, revert the transaction.
    ///      2. Retrieve the order from the orders mapping and ensure the caller (`msg.sender`) is the same as the order creator.
    ///      3. Determine if the order is claimable (the calculation method is detailed in the claimOrder function).
    ///      4. Based on the claimability of the order, perform the following actions:
    ///         a. Not Claimable:
    ///            - Scale down the order amount for cancellation tree update (scaling method detailed in related method documentation).
    ///            - Add the order's amount and index to the cancellation tree.
    ///            - Transfer the original order amount back to the user.
    ///            - Emit cancel events.
    ///         b. Fully Claimable:
    ///            - Follow the procedure outlined in the claimOrder function.
    ///            - Do not transfer the original order amount to the user.
    ///            - Do not add to the cancellation tree.
    ///            - Collect taker fees and emit claim events.
    ///         c. Partially Claimable:
    ///            - Claim the filled part of the order.
    ///            - Cancel the unfilled portion.
    ///            - Emit both claim and cancel events.
    ///            - Update the cancellation tree for the unfilled part of the order.
    ///            - Collect taker fees for the filled portion.
    function cancelOrder(uint256 orderId) external {
        Order memory order = orders[orderId];

        if (order.status != OrderStatus.Open) {
            revert InvalidOrderStatus(orderId, order.status);
        }

        uint256 receiveBackAmount = 0;
        uint256 claimedAmount = 0;
        uint256 filledAmountFee = 0;

        (bool isFullyClaimable, uint256 claimableAmount) = _claimStatus(order);

        if (isFullyClaimable) {
            // update the price point
            _updatePricePoint(
                order.price, order.tokenAmount, order.isBuy, false, PricePointDirection.Withdraw
            );

            // update the order status
            orders[orderId].status = OrderStatus.Claimed;

            // transfer the tokens and take maker fees
            filledAmountFee = _executeClaimTransfer(order.isBuy, claimableAmount);

            claimedAmount = claimableAmount;
        } else if (!isFullyClaimable && claimableAmount > 0) {
            // claim the filled part of the order
            filledAmountFee = _executeClaimTransfer(order.isBuy, claimableAmount);
            claimedAmount = claimableAmount;

            // update the price point
            _updatePricePoint(
                order.price, order.tokenAmount, order.isBuy, false, PricePointDirection.Withdraw
            );

            // cancel the unfilled part of the order

            receiveBackAmount = order.tokenAmount - claimableAmount;

            _updatePricePoint(
                order.price, receiveBackAmount, order.isBuy, true, PricePointDirection.Withdraw
            );

            _updateCancellationTree(
                order.price, order.orderIndexInPricePoint, receiveBackAmount, order.isBuy
            );

            // update the order status
            orders[orderId].status = OrderStatus.Canceled;

            // transfer the tokens back to the user

            IERC20 token = order.isBuy ? _quoteToken : _baseToken;
            token.safeTransfer(msg.sender, receiveBackAmount);
        } else {
            // update the price point
            _updatePricePoint(
                order.price, order.tokenAmount, order.isBuy, true, PricePointDirection.Withdraw
            );

            // update the order status
            orders[orderId].status = OrderStatus.Canceled;

            // transfer the tokens back to the user
            receiveBackAmount = order.tokenAmount;
            claimedAmount = 0;
            filledAmountFee = 0;
            // update the cancellation tree
            _updateCancellationTree(
                order.price, order.orderIndexInPricePoint, order.tokenAmount, order.isBuy
            );

            IERC20 token = order.isBuy ? _quoteToken : _baseToken;
            token.safeTransfer(msg.sender, receiveBackAmount);
        }

        // emit events
        emit LimitMakerOrderCanceled(
            orderId,
            order.user,
            order.price,
            receiveBackAmount,
            claimedAmount,
            filledAmountFee,
            order.isBuy
        );
    }

    /// @notice collectFees - Transfers collected fees to the governance treasury.
    /// @dev Execution Steps:
    ///      1. Verify the caller (`msg.sender`). The caller must be the governance treasury. If not, revert the transaction.
    ///      2. Transfer the accumulated fees to the treasury. This includes fees in both quote and base token forms.
    ///      3. Update relevant state variables to reflect the transfer of fees.
    ///
    ///      Note: This function assumes the presence of mechanisms for fee accumulation and state variables tracking these fees.
    function collectFees() external {
        if (msg.sender != governanceTreasury) {
            revert InvalidCaller(msg.sender);
        }

        // transfer the fees to the treasury
        _quoteToken.safeTransfer(governanceTreasury, _quoteFeeBalance);
        _baseToken.safeTransfer(governanceTreasury, _baseFeeBalance);

        // update the fee balances
        _quoteFeeBalance = 0;
        _baseFeeBalance = 0;
    }

    /// @notice updateFees - Adjusts the maker and taker fees in the trading system.
    /// @param makerFee_ The new fee to be set for makers.
    /// @param takerFee_ The new fee to be set for takers.
    /// @param pricePrecision_ The precision of the price
    /// @dev Execution Steps:
    ///      1. Validate the caller (`msg.sender`). This action must be performed by the governance treasury. If not, revert the transaction.
    ///      2. Update the maker and taker fees with the new values provided (makerFee_ and takerFee_).
    ///
    ///      Note: This function is designed to be called by authorized personnel or systems (e.g., governance treasury) to adjust trading fees dynamically.
    function updateMarketPolicy(uint24 makerFee_, uint24 takerFee_, uint256 pricePrecision_)
        external
    {
        if (msg.sender != governanceTreasury) {
            revert InvalidCaller(msg.sender);
        }

        makerFee = makerFee_;
        takerFee = takerFee_;
        pricePrecision = pricePrecision_;

        emit FeePolicyUpdated(makerFee_, takerFee_, pricePrecision_);
    }

    /// VIEW FUNCTIONS ///

    /// @notice is the order claimable or not
    /// @param orderId The id of the order to check
    function isClaimable(uint256 orderId) external view returns (bool) {}

    /// @notice get the balance of collected fees
    function getFeeBalance()
        external
        view
        returns (uint256 quoteFeeBalance, uint256 baseFeeBalance)
    {}

    /// @notice get base token
    function getBaseToken() external view returns (address) {}

    /// @notice get quote token
    function getQuoteToken() external view returns (address) {}

    /// @notice get the price of latest trade
    function getLatestTradePrice() external view returns (uint256) {}

    /// @notice get the order by id
    /// @param orderId The id of the order to get
    function getOrder(uint256 orderId)
        external
        view
        returns (
            uint256 _orderIndexInPricePoint,
            uint256 _preOrderLiquidityPosition,
            uint256 _tokenAmount,
            uint256 _price,
            address _user,
            bool _isBuy,
            OrderStatus _status
        )
    {}

    /// @notice get the price point by price
    /// @param price The price of the price point to get
    function getPricePoint(uint256 price)
        external
        view
        returns (
            uint256 _totalBuyLiquidity,
            uint256 _totalSellLiquidity,
            uint256 _usedBuyLiquidity,
            uint256 _usedSellLiquidity,
            uint256 _orderCount
        )
    {}

    /// INTERNAL FUNCTIONS ///

    function _findMatchedPricePoints(bool isBuy, uint256 price, uint256 amount)
        internal
        view
        returns (MatchedPricePoint[] memory, uint8)
    {
        MatchedPricePoint[] memory responses = new MatchedPricePoint[](5);
        uint8 matchFoundCount = 0;

        uint256 remainingAmount = amount;
        uint256 checkingPrice = price;

        // check the leading price
        if (
            isBuy
                && ((price >= sellLeadingPricePoint) || (pricePoints[price].totalSellLiquidity) > 0)
        ) {
            for (uint8 i = 0; i < _MAX_MATCHED_PRICE_POINTS; i++) {
                uint256 matchedAmount =
                    _findMatchedPricePointAtPrice(isBuy, checkingPrice, remainingAmount);

                remainingAmount -= matchedAmount;

                if (matchedAmount > 0) {
                    responses[matchFoundCount] = MatchedPricePoint(checkingPrice, matchedAmount);
                    matchFoundCount++;
                }

                if (remainingAmount == 0) {
                    break;
                }

                checkingPrice -= pricePrecision;
            }
        } else if (
            !isBuy
                && ((price <= buyLeadingPricePoint) || (pricePoints[price].totalBuyLiquidity > 0))
        ) {
            for (uint8 i = 0; i < _MAX_MATCHED_PRICE_POINTS; i++) {
                uint256 matchedAmount =
                    _findMatchedPricePointAtPrice(isBuy, checkingPrice, remainingAmount);

                remainingAmount -= matchedAmount;

                if (matchedAmount > 0) {
                    responses[matchFoundCount] = MatchedPricePoint(checkingPrice, matchedAmount);
                    matchFoundCount++;
                }

                if (remainingAmount == 0) {
                    break;
                }

                checkingPrice += pricePrecision;
            }
        }

        return (responses, matchFoundCount);
    }

    function _findMatchedPricePointAtPrice(bool isBuy, uint256 price, uint256 amount)
        internal
        view
        returns (uint256 matchedAmount)
    {
        uint256 totalLiquidity =
            isBuy ? pricePoints[price].totalSellLiquidity : pricePoints[price].totalBuyLiquidity;

        if (totalLiquidity == 0) {
            return 0;
        }

        if (totalLiquidity >= amount) {
            return amount;
        }

        return totalLiquidity;
    }

    function _updatePricePoint(
        uint256 pricePoint,
        uint256 amount,
        bool isBuy,
        bool isCancel,
        PricePointDirection direction
    ) internal {
        if (isBuy && direction == PricePointDirection.Withdraw && !isCancel) {
            pricePoints[pricePoint].totalSellLiquidity -= amount;
            pricePoints[pricePoint].usedSellLiquidity += amount;
        } else if (isBuy && direction == PricePointDirection.Deposit && !isCancel) {
            pricePoints[pricePoint].totalBuyLiquidity += amount;
        } else if (isBuy && direction == PricePointDirection.Withdraw && isCancel) {
            pricePoints[pricePoint].totalBuyLiquidity -= amount;
            pricePoints[pricePoint].usedBuyLiquidity -= amount;
        } else if (!isBuy && direction == PricePointDirection.Withdraw && !isCancel) {
            pricePoints[pricePoint].totalBuyLiquidity -= amount;
            pricePoints[pricePoint].usedBuyLiquidity += amount;
        } else if (!isBuy && direction == PricePointDirection.Deposit && !isCancel) {
            pricePoints[pricePoint].totalSellLiquidity += amount;
        } else if (!isBuy && direction == PricePointDirection.Withdraw && isCancel) {
            pricePoints[pricePoint].totalSellLiquidity -= amount;
            pricePoints[pricePoint].usedSellLiquidity -= amount;
        }

        // update leading price points
        if (direction == PricePointDirection.Deposit && !isCancel) {
            if (isBuy && pricePoint > buyLeadingPricePoint) {
                buyLeadingPricePoint = pricePoint;
            } else if (!isBuy && pricePoint < sellLeadingPricePoint) {
                sellLeadingPricePoint = pricePoint;
            }
        }
    }

    function _executeTakerOrder(bool isBuy, uint256 amount) internal returns (uint256) {
        uint256 feeAmount = 0;

        if (isBuy) {
            feeAmount = (amount * takerFee) / _FEE_PRECISION;
            _quoteFeeBalance += feeAmount;
            _quoteToken.safeTransfer(msg.sender, amount - feeAmount);
        } else {
            feeAmount = (amount * takerFee) / _FEE_PRECISION;
            _baseFeeBalance += feeAmount;
            _baseToken.safeTransfer(msg.sender, amount - feeAmount);
        }

        return feeAmount;
    }

    function _claimStatus(Order memory order)
        internal
        view
        returns (bool isFullyClaimable, uint256 claimableAmount)
    {
        uint256 cancellationTreeSum =
            _getCancellationAmountInRange(order.isBuy, order.price, order.orderIndexInPricePoint);

        uint256 realStartPoint = order.preOrderLiquidityPosition - cancellationTreeSum;

        uint256 realEndPoint = realStartPoint + order.tokenAmount;

        if (order.isBuy) {
            if (realEndPoint <= pricePoints[order.price].usedBuyLiquidity) {
                return (true, order.tokenAmount);
            } else if (realStartPoint >= pricePoints[order.price].usedBuyLiquidity) {
                return (false, 0);
            } else {
                return (false, pricePoints[order.price].usedBuyLiquidity - realStartPoint);
            }
        } else {
            if (realEndPoint <= pricePoints[order.price].usedSellLiquidity) {
                return (true, order.tokenAmount);
            } else if (realStartPoint >= pricePoints[order.price].usedSellLiquidity) {
                return (false, 0);
            } else {
                return (false, pricePoints[order.price].usedSellLiquidity - realStartPoint);
            }
        }
    }

    function _executeClaimTransfer(bool isBuy, uint256 amount) internal returns (uint256) {
        uint256 feeAmount = 0;

        if (isBuy) {
            feeAmount = (amount * makerFee) / _FEE_PRECISION;
            _quoteFeeBalance += feeAmount;
            _quoteToken.safeTransfer(msg.sender, amount - feeAmount);
        } else {
            feeAmount = (amount * makerFee) / _FEE_PRECISION;
            _baseFeeBalance += feeAmount;
            _baseToken.safeTransfer(msg.sender, amount - feeAmount);
        }

        return feeAmount;
    }

    function _getCancellationAmountInRange(
        bool isBuy,
        uint256 priceStep,
        uint256 orderIndexInPricePoint
    ) internal view returns (uint256) {
        (uint16 offset, uint256 orderId) = _calCulateOffset(orderIndexInPricePoint);
        uint64 rawCancellationAmount = 0;
        uint256 cancellationAmount = 0;

        if (offset == 0) {
            rawCancellationAmount = isBuy
                ? _pricePointBuyCancellationTrees[priceStep][offset].query(0, orderId)
                : _pricePointSellCancellationTrees[priceStep][offset].query(0, orderId);
        } else if (offset <= 5) {
            rawCancellationAmount = isBuy
                ? _pricePointBuyCancellationTrees[priceStep][offset].query(0, orderId)
                : _pricePointSellCancellationTrees[priceStep][offset].query(0, orderId);
            for (uint16 i = 0; i < offset; i++) {
                rawCancellationAmount += isBuy
                    ? _pricePointBuyCancellationTrees[priceStep][i].total()
                    : _pricePointSellCancellationTrees[priceStep][i].total();
            }
        } else {
            rawCancellationAmount = isBuy
                ? _pricePointBuyCancellationTrees[priceStep][offset].query(0, orderId)
                : _pricePointSellCancellationTrees[priceStep][offset].query(0, orderId);

            rawCancellationAmount += isBuy
                ? _offsetAggregatedBuyCancellationTrees[priceStep].query(0, offset - 1)
                : _offsetAggregatedSellCancellationTrees[priceStep].query(0, offset - 1);
        }

        cancellationAmount = _scaleUp(
            rawCancellationAmount,
            priceStep,
            isBuy ? _quotePrecisionComplement : _basePrecisionComplement
        );
        return cancellationAmount;
    }

    function _updateCancellationTree(
        uint256 priceStep,
        uint256 orderIndexInPricePoint,
        uint256 amount,
        bool isBuy
    ) internal {
        (uint16 offset, uint256 orderId) = _calCulateOffset(orderIndexInPricePoint);

        uint64 rawAmount = _scaleDown(
            amount, priceStep, isBuy ? _quotePrecisionComplement : _basePrecisionComplement
        );

        if (isBuy) {
            _pricePointBuyCancellationTrees[priceStep][offset].update(orderId, rawAmount);
            uint64 total = _pricePointBuyCancellationTrees[priceStep][offset].total();
            _offsetAggregatedBuyCancellationTrees[priceStep].update(offset, total);
        } else {
            _pricePointSellCancellationTrees[priceStep][offset].update(orderId, rawAmount);
            uint64 total = _pricePointSellCancellationTrees[priceStep][offset].total();
            _offsetAggregatedSellCancellationTrees[priceStep].update(offset, total);
        }
    }

    function _calCulateOffset(uint256 orderIndexInPricePoint)
        internal
        pure
        returns (uint16 offset, uint16 orderID)
    {
        offset = uint16(orderIndexInPricePoint / _OFFSET_PER_PRICE_POINT);
        orderID = uint16(orderIndexInPricePoint % _OFFSET_PER_PRICE_POINT);
    }

    function _getDecimalComplement(address token) internal view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(token).decimals());
    }

    function _scaleDown(uint256 amount, uint256 price, uint256 precisionComplement)
        internal
        pure
        returns (uint64)
    {}

    function _scaleUp(uint256 amount, uint256 price, uint256 precisionComplement)
        internal
        pure
        returns (uint256)
    {}


}

// @TODO: the amount in the contract is based on the base token and the transfer amount
//        should be based on the the token. make this correct in the execution of the claim and taker order

// @TODO: now we have the price precision, and we should add price precision check in the needed places

// @TODO: scale up and scale down should be based on the price precision and apply their limits and logic
//        in the needed places
