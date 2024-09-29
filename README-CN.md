# 怪獸保育園智能合約（拍賣）

## 核心功能
通過 Chainlink VRF 實現完全去中心化的抽獎機制

### 關鍵變量
 ```
    // 保存單次拍賣所需的數據結構
    struct Auction {
        // 此次拍賣的 monuId
        uint256 monuId;
        // 競拍開始的時間
        uint256 startTime;
        // 競拍結束的時間
        uint256 endTime;
        // 拍賣是否已經結束
        bool settled;
    }
    // 保存競拍者出價順序、出價金額、出價時間以及競拍者地址的數據結構
    struct Bid {
        // 當前的出價順序，紀錄首次出價的時間
        uint256 index;
        // 當前出價
        uint256 price;
        // 出價時間
        uint256 bidTime;
        // 競拍者的帳戶地址
        address payable bidder;
    }
```

### 關鍵函數
1. `_createAuction`
```
    function _createAuction() internal {
        try monu.mint() returns (uint256 monuId) {
            uint256 startTime = block.timestamp; // 獲取當前時間戳
            uint256 endTime = startTime + duration; // 設置拍賣的結束時間

            auction = IMonuAuction.Auction({monuId: monuId, startTime: startTime, endTime: endTime, settled: false});
            monuAuctionIndex++;

            emit AuctionCreated(monuId, startTime, endTime); // 觸發拍賣創建的時間
        } catch Error(string memory) {
            _pause(); // 如果 Monu 鑄造失敗則暫停拍賣
        }
    }
```    

2. `placeBid`:此函數用戶參與拍賣，如果用首次參與拍賣，則將用戶紀錄到`bidderList`中並紀錄相關的競拍數據；如果用戶二次出價則更新相關的出價數據
```
function placeBid(uint256 monuId) external payable nonReentrant {
        IMonuAuction.Auction memory _auction = auction;

        if (_auction.monuId != monuId) {
            revert NotUpForAuction(); // 如果拍賣的物品與傳入的 monuId 不匹配，則抛出錯誤
        }

        if (block.timestamp >= _auction.endTime) {
            revert AuctionExpired(); // 如果拍賣已結束，則抛出錯誤
        }

        if (msg.value < reservePrice) {
            revert MustOverReservePrice(); // 出價必須高于最低出價
        }

        IMonuAuction.Bid storage existingBid = personalBid[monuId][msg.sender];

        if (existingBid.bidder == address(0)) {
            // 如果競拍者是第一次出價，則創建新的出價記錄
            IMonuAuction.Bid memory newBid =
                IMonuAuction.Bid({price: msg.value, bidTime: block.timestamp, bidder: payable(msg.sender), index: bidIndex[monuId]});

            personalBid[monuId][msg.sender] = newBid; // 保存個人出價記錄
            bidderList[monuId].push(msg.sender); // 添加競拍者到競拍者列表中
            bidder_winningRate[monuId][bidIndex[monuId]];

            bidIndex[monuId]++;
        } else {
            if (msg.value < _getBidPrice(monuId, msg.sender)) {
                revert MustOverLastBid(); // 新的出價必須高于之前的出價
            }
            // 更新現有的出價記錄
            existingBid.price = msg.value;
            existingBid.bidTime = block.timestamp;
        }
    }
```

3. `calculateAllBiddersWinningRate`:當日拍賣停止後，根據出價金額的不同計算每位競拍者的獲勝概率
```
function calculateAllBiddersWinningRate(uint256 monuId) internal returns (uint256[] memory _winningRate) {
        uint256 bidderCount = bidderList[monuId].length;
        uint256[] memory winningRate = new uint256[](bidderCount);
        uint256 _totalBidPrice = _getTotalBidPrice(monuId); 
    
        if (_totalBidPrice == 0) {
            // 防止除以零錯誤，返回默認勝率
            return winningRate;
        }
    
        // 檢查是否有競拍者達到最大勝率（75%）
        if (checkIfHighestWinningRateMax(monuId)) {
            uint256 highestBidIndex = _getHighestBid(monuId).index;
            uint256 higestBidderWinningRate = (bidder_winningRate[monuId][highestBidIndex] * 75_00) / _totalBidPrice;
    
            for (uint256 i = 0; i < bidderCount; i++) {
                IMonuAuction.Bid storage bid = personalBid[monuId][bidderList[monuId][i]];
    
                if (i == highestBidIndex) {
                    // 出價最高的競拍者获得 75% 勝率
                    winningRate[i] = higestBidderWinningRate;
                } else {
                    // 其他競拍者分配剩余的 25% 勝率
                    uint256 otherBidderWinningRate = (bid.price * 25_00) / _totalBidPrice;
                    winningRate[i] = otherBidderWinningRate;
                    bidder_winningRate[monuId][i] = otherBidderWinningRate; // 更新競拍者的勝率
                }
            }
        } else {
            // 沒有達到最大勝率，按競拍者各自的出價計算勝率
            for (uint256 i = 0; i < bidderCount; i++) {
                IMonuAuction.Bid storage bid = personalBid[monuId][bidderList[monuId][i]];
                // 根據競拍者出價比例計算勝率
                uint256 bidderRate = (bid.price * 100_00) / _totalBidPrice;
                winningRate[i] = bidderRate;
                bidder_winningRate[monuId][i] = bidderRate; // 更新竞拍者的胜率
            }
        }
    
        return winningRate;
    }
```

4. `rollDice & fulfillRandomWords`函數：調用`Chainlink VRF`預言機隨機生成一個0-最大出價金額之間的隨機數，並基於此隨機數選出當日的競拍成功者
```
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
```

5. `selectWinner`函數：借助`Chainlink VRF`生成的隨機數，根據`加權隨機抽樣法`選出最終的獲勝者。
```
    function selectWinner(uint256 monuId) external whenNotPaused {
        IMonuAuction.Auction memory _auction = auction;
    
        if (!_auction.settled) {
            revert AuctionNotEnd(); // 確保拍賣已經結束
        }
    
        // 計算所有競拍者的勝率
        uint256[] memory winningRates = calculateAllBiddersWinningRate(monuId);
        address[] memory bidders = _getAllBidders(monuId);
        
        // 生成隨機數以選擇贏家
        uint256 totalWinningRate = 0;
        for (uint256 i = 0; i < winningRates.length; i++) {
            totalWinningRate += winningRates[i]; // 生成隨機數以選擇贏家
        }
    
        uint256 randomValue = (s_results[s_rollers[monuAuctionIndex]] % totalWinningRate) + 1; // 隨機數範圍在 1 到總勝率之間
        uint256 cumulativeSum = 0;
        address winner;
    
        // 選出贏家
        for (uint256 i = 0; i < bidders.length; i++) {
            cumulativeSum += winningRates[i];
            if (randomValue <= cumulativeSum) {
                winner = bidders[i];
                break;
            }
        }
    
        // 觸發拍賣結算事件
        emit AuctionSettled(monuId, winner, _getHighestBid(monuId).price);
    }
```