// SPDX-License-Identifier: TBD
pragma solidity 0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract FakeToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _mint(msg.sender, 1000 ether);
    }
}

