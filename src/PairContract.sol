// SPDX-License-Identifier: TBD
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./lib/mvp/SegmentedSegmentTree.sol";

contract PairContract {
    using SegmentedSegmentTree for SegmentedSegmentTree.Core;

    /* 
    Structs & Enums
        1. OrderType: 
        2. Order: Order structure containing details of each order
        3. PricePool: Structure to track liquidity in buy and sell pools
    */
    enum OrderType {
        Buy,
        Sell
    }

    struct Order {
        uint256 orderId;
        address user;
        OrderType orderType;
        uint256 price;
        uint256 tokenAmount;
        uint256 poolPosition;
        bool isClaimed;
    }

    struct PricePool {
        uint256 totalBuyLiquidity;
        uint256 totalSellLiquidity;
        uint256 usedBuyLiquidity;
        uint256 usedSellLiquidity;
    }

    /*
    State Variables
        1. baseToken: ERC20 tokens for the trading pair
        2. quoteToken: 

        3. pairAddress: Address and version for the pair (useful for AMM integration)
        4. ammVersion:

        5. initialPrice: Variable for initial price to validate new pool prices

        6. pricePools: Mappings for tracking price pools and orders
        7. orders:

        8. orderCount:
    */

    IERC20 public baseToken;
    IERC20 public quoteToken;

    address public pairAddress;
    string public ammVersion;

    uint256 public initialPrice;

    mapping(uint256 => PricePool) public pricePools;
    mapping(uint256 => Order) public orders;

    uint256 public orderCount;

    SegmentedSegmentTree.Core private cancellationTree;

    mapping(uint256 => SegmentedSegmentTree.Core) private pricePoolsCancellationTree;

    /*
    Errors:
        1. Unauthorized():
        2. AlreadyClaimed():
        3. TransferFailed():
        4. InvalidPoolPrice():
        5. InsufficientLiquidity():
    */
    error Unauthorized();
    error AlreadyClaimed();
    error TransferFailed();
    error InvalidPoolPrice();
    error InsufficientLiquidity();

    /*
    Events
        1. OrderPlaced: Events for tracking order placements and claims
        2. FundsClaimed
    */

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed user,
        OrderType orderType,
        uint256 price,
        uint256 tokenAmount
    );
    event FundsClaimed(uint256 indexed orderId, address indexed user, uint256 amount);

    // Modifiers

    /* 
    Constructor
        // Constructor to initialize the contract with token addresses, pair address, AMM version and initial price

    */
    constructor(
        address _baseToken,
        address _quoteToken,
        address _pairAddress,
        string memory _ammVersion,
        uint256 _initialPrice
    ) {
        baseToken = IERC20(_baseToken);
        quoteToken = IERC20(_quoteToken);
        pairAddress = _pairAddress;
        ammVersion = _ammVersion;
        initialPrice = _initialPrice;
    }

    /*
    External Functions
    */

    //@audit we can have modifier for the order validity for cancel and claim
    // basic check

    //@audit for implementing the cancel that store the cancellation in the segment tree 
    // and it usage in the claim order we need to revise on the order ide and pool position
    // because our current orderID is not effect on the poolPrice and we should fix it first
    function cancelOrder(uint256 _orderID) external {
        Order storage order = orders[_orderID];
        if (msg.sender != order.user) revert Unauthorized();
        if (order.isClaimed) revert AlreadyClaimed();




    }

    /*
    Public Functions
        1. createPricePool: Function to create a new price pool
        2. placeOrder: Function to place an order
        3. claimFunds: Function to claim funds for an order

    */

    //@audit why createPricePool and placeOrder and claimFunds functions are public 
    // not external?

    //@audit what is the purpose of this function?
    //@audit the check is not correct, because when we create a new pricePool its with 
    //the zero value and the first check again get failed when we call this function
    // twice in raw it create twice the same pricePool without telling its already exist
    function createPricePool(uint256 _poolPrice) public {
        if (_poolPrice % (initialPrice / 1000) != 0) {
            revert InvalidPoolPrice();
        }

        // Check if the pool already exists and create a new one if it doesn't
        if (
            pricePools[_poolPrice].totalBuyLiquidity == 0
                && pricePools[_poolPrice].totalSellLiquidity == 0
        ) {
            pricePools[_poolPrice] = PricePool(0, 0, 0, 0);
        }
    }

    function placeOrder(OrderType _orderType, uint256 _price, uint256 _tokenAmount) public {
        // Transfer tokens from the user to the contract
        if (_orderType == OrderType.Buy) {
            if (!quoteToken.transferFrom(msg.sender, address(this), _tokenAmount)) {
                revert TransferFailed();
            }
        } else {
            if (!baseToken.transferFrom(msg.sender, address(this), _tokenAmount)) {
                revert TransferFailed();
            }
        }

        // Update the pool and order data
        PricePool storage pool = pricePools[_price];
        uint256 poolPosition =
            (_orderType == OrderType.Buy) ? pool.totalBuyLiquidity : pool.totalSellLiquidity;
        if (_orderType == OrderType.Buy) {
            pool.totalBuyLiquidity += _tokenAmount;
        } else {
            pool.totalSellLiquidity += _tokenAmount;
        }

        //@audit in the Order struct we does not need the orderCount because we have it in the 
        //order mapping and its duplicated data and kinda we does not need to it.
        // Record the order
        orders[orderCount] =
            Order(orderCount, msg.sender, _orderType, _price, _tokenAmount, poolPosition, false);

        // Emit an event for the order placement
        emit OrderPlaced(orderCount, msg.sender, _orderType, _price, _tokenAmount);

        orderCount++;
    }

    function claimFunds(uint256 orderId) public {
        Order storage order = orders[orderId];
        if (msg.sender != order.user) revert Unauthorized();
        if (order.isClaimed) revert AlreadyClaimed();

        // Check if the order's liquidity has been used
        PricePool storage pool = pricePools[order.price];
        bool isLiquidityUsed = (order.orderType == OrderType.Buy)
            ? pool.usedSellLiquidity > order.poolPosition
            : pool.usedBuyLiquidity > order.poolPosition;
        if (!isLiquidityUsed) revert InsufficientLiquidity();

        // Calculate the amount to transfer and execute the transfer
        uint256 amountToTransfer = order.tokenAmount;
        if (order.orderType == OrderType.Buy) {
            // Transfer base tokens to the user for a buy order
            if (!baseToken.transfer(order.user, amountToTransfer)) {
                revert TransferFailed();
            }
        } else {
            // Transfer quote tokens to the user for a sell order
            if (!quoteToken.transfer(order.user, amountToTransfer)) {
                revert TransferFailed();
            }
        }

        order.isClaimed = true;

        // Emit an event for the funds claim
        emit FundsClaimed(orderId, order.user, amountToTransfer);
    }

    /*
    Internal Functions
        1. matchOrder: Internal function to match orders and update used liquidity
    */

    function matchOrder(OrderType _orderType, uint256 _price, uint256 _tokenAmount) internal {
        PricePool storage pool = pricePools[_price];

        if (_orderType == OrderType.Buy) {
            // For a buy order, check available liquidity in the sell pool
            uint256 availableSellLiquidity = pool.totalSellLiquidity - pool.usedSellLiquidity;
            uint256 amountToMatch =
                (_tokenAmount <= availableSellLiquidity) ? _tokenAmount : availableSellLiquidity;
            pool.usedSellLiquidity += amountToMatch;
        } else {
            // For a sell order, check available liquidity in the buy pool
            uint256 availableBuyLiquidity = pool.totalBuyLiquidity - pool.usedBuyLiquidity;
            uint256 amountToMatch =
                (_tokenAmount <= availableBuyLiquidity) ? _tokenAmount : availableBuyLiquidity;
            pool.usedBuyLiquidity += amountToMatch;
        }
    }

    // Private Functions
}
