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
    event TakerOrder(uint256 temp);
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

    function limitOrder (uint256 temp1) external returns (bool temp2) {
        emit MakerOrder(orderCount);
        if (temp1 == 0) {
            orderCount += 1;
            return false;
        }
        return true;
    }

    function getExpectedAmount (uint256 amountIn) external view returns (uint256 temp2) {
        return amountIn * orderCount / _PRICE_PRECISION;
    }

    function marketOrder (uint256 orderIndex) external returns (bool temp2) {
        if ( orderCount > orderIndex ) {
            emit TakerOrder(orderIndex);
            return true;
        }
    }

    function cancel (uint256 orderIndex) external returns (bool temp2) {
        if ( orderCount > orderIndex ) {
            emit OrderCancelled(orderIndex);
            return true;
        }
    }

    function claim (uint256 orderIndex) external returns (bool temp2) {
        if ( orderCount > orderIndex ) {
            emit OrderClaimed(orderIndex);
            return true;
        }
    }

    function isClaimable(uint256 orderIndex) external view returns (bool temp2) {
        if ( orderCount > orderIndex ) {
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


    function getOrder (uint256 orderIndex) external view returns (Order memory) {
        return orders[orderIndex];
    }

    function markerPrice () external view returns (uint256) {
        return orderCount;
    }

    function collectFees (uint256 temp1) external returns (bool) {
        if (temp1 == 0) {
            orderCount += 1;
            return false;
        }
        return true;
    }

    function getPricePointInfo (uint256 temp1) external view returns (uint256) {
        if (temp1 == 0) {
            return orderCount;
        }
        return orderCount + 1;
    }



    /// INTERNAL FUNCTIONS ///

    function _getDecimalComplement(address token) internal view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(token).decimals());
    }
}
