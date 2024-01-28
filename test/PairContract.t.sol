//SPDX-License-Identifier: TBD

pragma solidity 0.8.20;

import {Test, console2} from "lib/forge-std/src/Test.sol";
import {Pair} from "../src/PairContract.sol";
import {FakeToken} from "./util/fakeToken.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract PairTest is Test {
    using SafeERC20 for IERC20;

    address constant TOKEN_HOLDER = address(0x123);
    address constant GOVERNANCE_TREASURY = address(0x456);

    function setUp() public {
        IERC20 baseToken = new FakeToken("BASE", "BT", TOKEN_HOLDER);
        IERC20 quoteToken = new FakeToken("QUOTE", "QT", TOKEN_HOLDER);

        uint24 makerFee_ = 10;
        uint24 takerFee_ = 20;

        uint256 quoteUnit_ = 1;

        Pair pair = new Pair(
            address(baseToken),
            address(quoteToken),
            quoteUnit_,
            makerFee_,
            takerFee_,
            GOVERNANCE_TREASURY
        );
    }

    function test_Constructor() public {
        // TODO
    }
    function test_InsertLimitOrder() public {
        // TODO
    }

    function test_MarketOrder() public {
        // TODO
    }

    function test_CancelOrder() public {
        // TODO
    }

    function test_ClaimOrder() public {
        // TODO
    }
}
