// SPDX-License-Identifier: TBD
pragma solidity 0.8.20;

import "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract FakeToken is ERC20 {
    uint8 decimal;

    constructor(
        string memory name_,
        string memory symbol_,
        address tokenReceiver,
        uint8 _decimal,
        uint256 initialValue
    ) ERC20(name_, symbol_) {
        decimal = _decimal;
        _mint(tokenReceiver, initialValue);
    }

    function decimals() public view override returns (uint8) {
        return decimal;
    }
}
