// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface IWETH {
    function deposit() external payable;

    function withdraw(uint256 wad) external;

    function transfer(address to, uint256 value) external returns (bool);
}
