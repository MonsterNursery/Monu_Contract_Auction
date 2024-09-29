// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// 导入必要的接口和合约
import {IMonuNFT} from "./interfaces/IMonuNFT.sol";
import {IMonuAuction} from "./interfaces/IMonuAuction.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
// import {PausableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
// import {ReentrancyGuardUpgradeable} from
//     "lib/openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {IWETH} from "./interfaces/IWETH.sol";

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";


contract MonuAuction is Pausable, ReentrancyGuard ,VRFConsumerBaseV2Plus {
    // 错误定义
    error AuctionNotBegin(); // 拍卖尚未开始
    error AuctionNotEnd(); // 拍卖尚未结束
    error AuctionAlreadySettled(); // 拍卖已结算
    error NotUpForAuction(); // 当前物品未上架拍卖
    error AuctionExpired(); // 拍卖已过期
    error MustOverReservePrice(); // 出价必须高于最低出价
    error MustOverLastBid(); // 出价必须高于上次出价
    error NotFoundBid(); // 没有找到出价记录
    error WrongPriceInput(); // 输入的价格不正确

    // 拍卖事件
    event AuctionSettled(uint256 indexed monuId, address winner, uint256 amount); // 拍卖结算事件
    event AuctionCreated(uint256 indexed monuId, uint256 startTime, uint256 endTime); // 拍卖创建事件
    event AuctionReservePriceUpdated(uint256 reservePrice); // 拍卖最低出价更新事件

    // Monu ERC721 代币合约
    IMonuNFT public monu;

    // 最高中奖率的分子
    uint256 constant MAX_WINNINGRATE_NUMERATOR = 75_00;

    // 胜率计算因子分母
    uint256 constant OTHERS_MAX_WINNINGRATE_NUMERATOR = 25_00;

    // 剩余用户最高获胜概率
    uint256 constant WINNINGRATE_DENOMINATOR = 100_00;


    // 竞拍者在竞拍当前 monuId 下的胜率
    mapping(uint256 => mapping( uint256 => uint256)) bidder_winningRate;

    // weth 合约地址
    address public weth;

    // 拍卖的初始价格: 0.1 ETH
    uint256 public reservePrice;

    // 单次拍卖的持续时间: 24 小时
    uint256 public duration;

    // 当前正在进行的拍卖
    IMonuAuction.Auction public auction;

    // 竞拍记录列表，每个 monuId 对应的竞价列表
    mapping(uint256 => IMonuAuction.Bid[]) public bidsList;

    // 竞拍者列表，每个 monuId 对应的竞拍者列表
    mapping(uint256 => address[]) public bidderList;

    // 个人出价记录，每个 monuId 和竞拍者地址对应的出价信息
    mapping(uint256 => mapping(address => IMonuAuction.Bid)) public personalBid;
    
    mapping(uint256 => uint256) public totalBidPrice;

    mapping(uint256 => uint256) public bidIndex;
    uint256 monuAuctionIndex;

    // VRF 变量
    uint256 s_subscriptionId;
    address vrfCoordinator = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    bytes32 s_keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
    uint32 callbackGasLimit = 40000;
    uint16 requestConfirmations = 3;
    uint32 numWords =  1;

    mapping(uint256 => address) private s_rollers;
    mapping(address => uint256) private s_results;

    event DiceRolled(uint256 indexed requestId, address indexed roller);
    event DiceLanded(uint256 indexed requestId, uint256 indexed result);

    uint256 private constant ROLL_IN_PROGRESS = 42;


    // 初始化函数
    constructor (IMonuNFT _monu, address _weth, uint256 _reservePrice, uint256 _duration, uint256 subscriptionId) VRFConsumerBaseV2Plus(vrfCoordinator){
        s_subscriptionId = subscriptionId;
        monu = _monu; // 设置 MonuNFT 合约地址
        weth = _weth; // 设置 WETH 合约地址
        reservePrice = _reservePrice; // 设置最低出价
        duration = _duration; // 设置拍卖持续时间
    }

    // 结算当前拍卖并创建新的拍卖
    function settleCurrentAndCreateNewAuction() external nonReentrant whenNotPaused {
        _settleAuction(); // 结算当前拍卖
        _createAuction(); // 创建新的拍卖
    }

    // 仅结算当前拍卖
    function settleAuction() external whenPaused nonReentrant {
        _settleAuction(); // 结算拍卖
    }

    // 创建竞拍
    function placeBid(uint256 monuId) external payable nonReentrant {
        IMonuAuction.Auction memory _auction = auction;

        if (_auction.monuId != monuId) {
            revert NotUpForAuction(); // 如果拍卖的物品与传入的 monuId 不匹配，抛出错误
        }

        if (block.timestamp >= _auction.endTime) {
            revert AuctionExpired(); // 如果拍卖已结束，抛出错误
        }

        if (msg.value < reservePrice) {
            revert MustOverReservePrice(); // 出价必须高于最低出价
        }

        IMonuAuction.Bid storage existingBid = personalBid[monuId][msg.sender];

        if (existingBid.bidder == address(0)) {
            // 如果竞拍者是第一次出价，则创建新的出价记录
            IMonuAuction.Bid memory newBid =
                IMonuAuction.Bid({price: msg.value, bidTime: block.timestamp, bidder: payable(msg.sender), index: bidIndex[monuId]});

            personalBid[monuId][msg.sender] = newBid; // 保存个人出价记录
            bidderList[monuId].push(msg.sender); // 添加竞拍者到列表中
            bidder_winningRate[monuId][bidIndex[monuId]];

            bidIndex[monuId]++;
        } else {
            if (msg.value < _getBidPrice(monuId, msg.sender)) {
                revert MustOverLastBid(); // 新的出价必须高于之前的出价
            }
            // 更新现有的出价记录
            existingBid.price = msg.value;
            existingBid.bidTime = block.timestamp;
        }
    }


    // 暂停拍卖
    function pause() external onlyOwner {
        _pause(); // 暂停合约
    }

    // 恢复拍卖
    function unpause() external onlyOwner {
        _unpause(); // 恢复合约

        if (auction.startTime == 0 || auction.settled) {
            _createAuction(); // 如果当前没有拍卖，或者拍卖已结算，创建新的拍卖
        }
    }

    // 更新最低出价
    function setReservePrice(uint256 _reservePrice) external onlyOwner {
        reservePrice = _reservePrice; // 设置新的最低出价
        emit AuctionReservePriceUpdated(_reservePrice); // 触发最低出价更新事件
    }

    // 内部函数：创建拍卖
    function _createAuction() internal {
        try monu.mint() returns (uint256 monuId) {
            uint256 startTime = block.timestamp; // 获取当前时间戳
            uint256 endTime = startTime + duration; // 设置拍卖结束时间

            auction = IMonuAuction.Auction({monuId: monuId, startTime: startTime, endTime: endTime, settled: false});
            monuAuctionIndex++;

            emit AuctionCreated(monuId, startTime, endTime); // 触发拍卖创建事件
        } catch Error(string memory) {
            _pause(); // 如果铸造失败，暂停拍卖
        }
    }

    // 内部函数：结算拍卖
    function _settleAuction() internal {
        IMonuAuction.Auction memory _auction = auction;

        if (_auction.startTime == 0) {
            revert AuctionNotBegin(); // 如果拍卖尚未开始，抛出错误
        }

        if (_auction.settled) {
            revert AuctionAlreadySettled(); // 如果拍卖已经结算，抛出错误
        }

        if (block.timestamp < _auction.endTime) {
            revert AuctionNotEnd(); // 如果拍卖尚未结束，抛出错误
        }

        auction.settled = true; // 将拍卖标记为已结算
    }

    // 获取当前拍卖的最高出价
    function _getHighestBid(uint256 monuId) public view returns (IMonuAuction.Bid memory) {
        address[] memory biddersList = bidderList[monuId];

        uint256 highestPrice = 0;
        IMonuAuction.Bid memory highestBid;

        for (uint256 i = 0; i < biddersList.length; i++) {
            address bidder = biddersList[i];
            IMonuAuction.Bid storage bid = personalBid[monuId][bidder];

            if (bid.price > highestPrice) {
                highestPrice = bid.price; // 更新最高出价
                highestBid = bid;
            }
        }

        return highestBid; // 返回最高出价记录
    }

    // 计算当前最高的胜率
    function checkIfHighestWinningRateMax(uint256 monuId) internal view returns (bool) {
        uint256 currentHighestRate = _getHighestBid(monuId).price;

        if (currentHighestRate >= MAX_WINNINGRATE_NUMERATOR) {
            return true; // 如果达到最大胜率，返回 true
        }

        return false;
    }

    // 根据价格计算胜率
    function _calculateBiddersWinningRate(uint256 monuId,uint256 price) internal returns (uint256) {
        uint256 totalprice = _getTotalBidPrice(monuId);
        if (totalprice == 0) {
            return 100_00; // 如果余额为 0，返回默认胜率 100%
        }

        if (price > totalprice) {
            revert WrongPriceInput(); // 如果出价高于总金额，抛出错误
        }

        return (totalprice * WINNINGRATE_DENOMINATOR / price); // 计算并返回胜率
    }

    // 获取竞拍者的出价金额
    function _getBidPrice(uint256 monuId, address bidder) internal view returns (uint256) {
        IMonuAuction.Bid memory bid = personalBid[monuId][bidder];

        if (bid.bidder == address(0)) {
            revert NotFoundBid(); // 如果没有找到匹配的出价记录，抛出错误
        }

        return bid.price; // 返回出价金额
    }

    // 获取所有竞拍者地址
    function _getAllBidders(uint256 monuId) internal view returns (address[] memory) {
        return bidderList[monuId]; // 返回竞拍者列表
    }

    function _getTotalBidPrice(uint256 monuId) internal returns(uint256) {
        IMonuAuction.Bid[] memory bids = bidsList[monuId]; // 获取该 monuId 的所有出价

        for (uint256 i = 0; i < bids.length; i++) {
            totalBidPrice[monuId]+= bids[i].price; // 逐个累加每个出价的金额
        }
        
        return     totalBidPrice[monuId];
    }
    
    function calculateAllBiddersWinningRate(uint256 monuId) internal returns (uint256[] memory _winningRate) {
        uint256 bidderCount = bidderList[monuId].length;
        uint256[] memory winningRate = new uint256[](bidderCount);
        uint256 _totalBidPrice = _getTotalBidPrice(monuId); // 假设该函数返回的是竞拍的总金额
    
        if (_totalBidPrice == 0) {
            // 防止除以零错误，返回默认胜率
            return winningRate;
        }
    
        // 检查是否有竞拍者达到最大胜率
        if (checkIfHighestWinningRateMax(monuId)) {
            uint256 highestBidIndex = _getHighestBid(monuId).index;
            uint256 higestBidderWinningRate = (bidder_winningRate[monuId][highestBidIndex] * 75_00) / _totalBidPrice;
    
            for (uint256 i = 0; i < bidderCount; i++) {
                IMonuAuction.Bid storage bid = personalBid[monuId][bidderList[monuId][i]];
    
                if (i == highestBidIndex) {
                    // 最高竞拍者获得 75% 胜率
                    winningRate[i] = higestBidderWinningRate;
                } else {
                    // 其他竞拍者分配剩余的 25% 胜率
                    uint256 otherBidderWinningRate = (bid.price * 25_00) / _totalBidPrice;
                    winningRate[i] = otherBidderWinningRate;
                    bidder_winningRate[monuId][i] = otherBidderWinningRate; // 更新竞拍者的胜率
                }
            }
        } else {
            // 没有达到最大胜率，按价格计算胜率
            for (uint256 i = 0; i < bidderCount; i++) {
                IMonuAuction.Bid storage bid = personalBid[monuId][bidderList[monuId][i]];
                // 根据竞拍者出价比例计算胜率
                uint256 bidderRate = (bid.price * 100_00) / _totalBidPrice;
                winningRate[i] = bidderRate;
                bidder_winningRate[monuId][i] = bidderRate; // 更新竞拍者的胜率
            }
        }
    
        return winningRate;
    }


    function selectWinner(uint256 monuId) external whenNotPaused {
        IMonuAuction.Auction memory _auction = auction;
    
        if (!_auction.settled) {
            revert AuctionNotEnd(); // 确保拍卖已经结束
        }
    
        // 计算所有竞标者的胜率
        uint256[] memory winningRates = calculateAllBiddersWinningRate(monuId);
        address[] memory bidders = _getAllBidders(monuId);
        
        // 生成随机数以选择赢家
        uint256 totalWinningRate = 0;
        for (uint256 i = 0; i < winningRates.length; i++) {
            totalWinningRate += winningRates[i]; // 累加所有竞标者的胜率
        }
    
        uint256 randomValue = (s_results[s_rollers[monuAuctionIndex]] % totalWinningRate) + 1; // 随机数范围在 1 到总胜率之间
        uint256 cumulativeSum = 0;
        address winner;
    
        // 选择赢家
        for (uint256 i = 0; i < bidders.length; i++) {
            cumulativeSum += winningRates[i];
            if (randomValue <= cumulativeSum) {
                winner = bidders[i];
                break;
            }
        }
    
        // 触发拍卖结算事件
        emit AuctionSettled(monuId, winner, _getHighestBid(monuId).price);
    }










    // 安全转账 ETH
    function _safeTransferETH(address to, uint256 value) internal returns (bool) {
        (bool success,) = to.call{value: value, gas: 30_000}(new bytes(0));
        return success; // 返回转账结果
    }

    // 安全转账 ETH 或回退到 WETH 转账
    function _safeTransferETHWithFallback(address to, uint256 amount) internal {
        if (!_safeTransferETH(to, amount)) {
            IWETH(weth).deposit{value: amount}(); // 如果转账失败，将 ETH 转为 WETH
            IERC20(weth).transfer(to, amount); // 使用 WETH 进行转账
        }
    }




    // VRF function
    function rollDice(address roller) public onlyOwner returns (uint256 requestId) {
        require(s_results[roller] == 0, "Already rolled");
        // Will revert if subscription is not set and funded.

       requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                // Set nativePayment to true to pay for VRF requests with Sepolia ETH instead of LINK
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        s_rollers[requestId] = roller;
        s_results[roller] = ROLL_IN_PROGRESS;
        emit DiceRolled(requestId, roller);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {

        uint256 rangeNum =  totalBidPrice[monuAuctionIndex] * 100_00;

        uint256 d20Value = (randomWords[0] % rangeNum) + 1;

        s_results[s_rollers[requestId]] = d20Value;

        emit DiceLanded(requestId, d20Value);
    }

}
