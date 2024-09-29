// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IMonuNFT is IERC721 {
    function setBaseURI(string calldata) external ;
    function isApprovedForAll(address , address ) external override(IERC721) view returns (bool);
    function burn(uint256) external;
    function setMinter(address) external;
    function mint() external returns (uint256);
    function setMounersDAO(address) external;
    function _mintTo(address , uint256 ) external returns (uint256);
}
