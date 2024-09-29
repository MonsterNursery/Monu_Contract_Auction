// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { ERC721 } from './base/ERC721.sol';
import { IERC721 } from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IMonuNFT} from "./interfaces/IMonuNFT.sol";
import { ERC721Checkpointable } from './base/ERC721Checkpointable.sol';
import { IProxyRegistry } from './external/opensea/IProxyRegistry.sol';
import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';


abstract contract MonuNFT is IMonuNFT, Ownable, ERC721Checkpointable {
    event MonuersDAOUpdated(address monuersDAO);
    event MonuCreated(uint256 monuId);
    event MonuBurned(uint256 monuId);
    event MinterUpdated(address indexed newMinter);
    event BaseURIUpdated(string newBaseURI);


    // Monuders DAO 地址（创作者组织）
    address public monuersDAO;

    // 具有权限铸造 Monu 的地址
    address public minter;

    // The internal Monu ID tracker
    uint256 private _currentMonuId;

    string private _baseTokenURI;
    
    // OpenSea's Proxy Registry
    IProxyRegistry public immutable proxyRegistry;

    modifier onlyMinter() {
        require(msg.sender == minter, 'Sender is not the minter');
        _;
    }

    modifier onlyMonuersDAO() {
        require(msg.sender == monuersDAO, 'Sender is not the Monuers DAO');
        _;
    }

    constructor(
        address _monuersDAO,
        address _minter,
        IProxyRegistry _proxyRegistry
    ) ERC721('Monu', 'MONU'){
        monuersDAO = _monuersDAO;
        minter = _minter;
        proxyRegistry = _proxyRegistry;
    }

    function setBaseURI(string calldata baseURI) external onlyOwner {
    _baseTokenURI = baseURI;
    emit BaseURIUpdated(baseURI);
    }       

    function _baseURI() internal view override returns (string memory) {
    return _baseTokenURI;
    }

    function isApprovedForAll(address _owner, address operator) public view override(IMonuNFT, IERC721,ERC721) returns (bool) {
        // Whitelist OpenSea proxy contract for easy trading.
        if (proxyRegistry.proxies(_owner) == operator) {
            return true;
        }
        return super.isApprovedForAll(_owner, operator);
    }

    function mint() public override onlyMinter returns (uint256) {
        if (_currentMonuId <= 1820 && _currentMonuId % 10 == 0) {
            _mintTo(monuersDAO, _currentMonuId++);
        }
        return _mintTo(minter, _currentMonuId++);
    }

    function setMinter(address _newMinter) external onlyOwner {
        require(_newMinter != address(0), "Invalid minter address");
        minter = _newMinter;
        emit MinterUpdated(_newMinter);
    }

    function burn(uint256 monuId) public override onlyMinter {
        _burn(monuId);
        emit MonuBurned(monuId);
    }

    function setMounersDAO(address _monuersDAO) external onlyMonuersDAO {
        monuersDAO = _monuersDAO;

        emit MonuersDAOUpdated(_monuersDAO);
    }

    function _mintTo(address to, uint256 monuId) internal override returns (uint256) {

        _mint(owner(), to, monuId);
        emit MonuCreated(monuId);

        return monuId;
    }

}
