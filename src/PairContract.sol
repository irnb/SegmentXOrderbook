// SPDX-License-Identifier: TBD
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PairContract {
    // ERC20 tokens for the trading pair
    IERC20 public baseToken;
    IERC20 public quoteToken;

    // Address and version for the pair (useful for AMM integration)
    address public pairAddress;
    string public ammVersion;

    // Variable for initial price to validate new pool prices
    uint256 public initialPrice;

    // Order types for trading
    enum OrderType {
        Buy,
        Sell
    }

    // Custom error definitions for specific failure scenarios
    error Unauthorized();
    error AlreadyClaimed();
    error TransferFailed();
    error InvalidPoolPrice();
    error InsufficientLiquidity();

    // Order structure containing details of each order
    struct Order {
        uint256 orderId;
        address user;
        OrderType orderType;
        uint256 price;
        uint256 tokenAmount;
        uint256 poolPosition;
        bool isClaimed;
    }

    // Structure to track liquidity in buy and sell pools
    struct PricePool {
        uint256 totalBuyLiquidity;
        uint256 totalSellLiquidity;
        uint256 usedBuyLiquidity;
        uint256 usedSellLiquidity;
    }

    // Mappings for tracking price pools and orders
    mapping(uint256 => PricePool) public pricePools;
    mapping(uint256 => Order) public orders;

    uint256 public orderCount;

    // Events for tracking order placements and claims
    event OrderPlaced(
        uint256 indexed orderId, address indexed user, OrderType orderType, uint256 price, uint256 tokenAmount
    );
    event FundsClaimed(uint256 indexed orderId, address indexed user, uint256 amount);

    // Constructor to initialize the contract with token addresses, pair address, AMM version and initial price
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
        initialPrice = _initialPrice; // Initialize initialPrice
    }

    // Function to create a new price pool
    function createPricePool(uint256 _poolPrice) public {
        if (_poolPrice % (initialPrice / 1000) != 0) {
            revert InvalidPoolPrice();
        }

        // Check if the pool already exists and create a new one if it doesn't
        if (pricePools[_poolPrice].totalBuyLiquidity == 0 && pricePools[_poolPrice].totalSellLiquidity == 0) {
            pricePools[_poolPrice] = PricePool(0, 0, 0, 0);
        }
    }

    // Function to place an order
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
        uint256 poolPosition = (_orderType == OrderType.Buy) ? pool.totalBuyLiquidity : pool.totalSellLiquidity;
        if (_orderType == OrderType.Buy) {
            pool.totalBuyLiquidity += _tokenAmount;
        } else {
            pool.totalSellLiquidity += _tokenAmount;
        }

        // Record the order
        orders[orderCount] = Order(orderCount, msg.sender, _orderType, _price, _tokenAmount, poolPosition, false);

        // Emit an event for the order placement
        emit OrderPlaced(orderCount, msg.sender, _orderType, _price, _tokenAmount);

        orderCount++;
    }

    // Internal function to match orders and update used liquidity
    function matchOrder(OrderType _orderType, uint256 _price, uint256 _tokenAmount) internal {
        PricePool storage pool = pricePools[_price];

        if (_orderType == OrderType.Buy) {
            // For a buy order, check available liquidity in the sell pool
            uint256 availableSellLiquidity = pool.totalSellLiquidity - pool.usedSellLiquidity;
            uint256 amountToMatch = (_tokenAmount <= availableSellLiquidity) ? _tokenAmount : availableSellLiquidity;
            pool.usedSellLiquidity += amountToMatch;
        } else {
            // For a sell order, check available liquidity in the buy pool
            uint256 availableBuyLiquidity = pool.totalBuyLiquidity - pool.usedBuyLiquidity;
            uint256 amountToMatch = (_tokenAmount <= availableBuyLiquidity) ? _tokenAmount : availableBuyLiquidity;
            pool.usedBuyLiquidity += amountToMatch;
        }
    }

    // Function to claim funds for an order
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
}
