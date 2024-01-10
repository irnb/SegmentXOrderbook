//SPDX-License-Identifier: TBD

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./lib/mvp/SegmentedSegmentTree.sol";

/// @title PairContract - A contract for handling orders and liquidity for a trading pair
/// @author IMMIN8 Labs

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

    uint24 public immutable makerFee;
    uint24 public immutable takerFee;

    uint256 private _quoteFeeBalance;
    uint256 private _baseFeeBalance;

    uint256 public orderCount;

    mapping(uint256 => Order) public orders;
    mapping(uint256 => PricePoint) public pricePoints;

    // priceStep => offset => cancellationTree
    mapping(uint256 => mapping(uint16 => SegmentedSegmentTree.Core)) private
        _pricePointCancellationTrees;
    // Aggregate cancellation tree => priceStep => cancellationTree
    mapping(uint256 => SegmentedSegmentTree.Core) private _offsetAggregatedCancellationTrees;

    /// ERRORS ///

    error Unauthorized();
    error AlreadyClaimed();
    error TransferFailed();
    error InsufficientLiquidity();

    /// EVENTS ///

    event MakerOrder();
    event TakerOrder();
    event OrderCancelled();
    event OrderClaimed();


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

    /// PUBLIC FUNCTIONS ///

    /// INTERNAL FUNCTIONS ///

    function _getDecimalComplement(address token) internal view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(token).decimals());
    }

    /// PRIVATE FUNCTIONS ///
}
