# Monster Daycare Auction Smart Contract

## Core Features

This contract utilizes Chainlink VRF to implement a fully decentralized random auction mechanism.

### Core Variables
 ```
    // Data structure for storing information about a single auction
    struct Auction {
        // The monuId being auctioned
        uint256 monuId;
        // Auction start time
        uint256 startTime;
        // Auction end time
        uint256 endTime;
        // Whether the auction has been settled
        bool settled;
    }

    // Data structure for storing bidder information such as bid order, amount, time, and bidder address
    struct Bid {
        // The current bid order, marking the time of the first bid
        uint256 index;
        // The current bid amount
        uint256 price;
        // Time of the bid
        uint256 bidTime;
        // Address of the bidder
        address payable bidder;
    }
```

### Core Function
1. `_createAuction`: The _createAuction function is responsible for initiating a new auction in the smart contract
```
    function _createAuction() internal {
        try monu.mint() returns (uint256 monuId) {
            uint256 startTime = block.timestamp; // Get the current timestamp
            uint256 endTime = startTime + duration; // Set the auction end time

            auction = IMonuAuction.Auction({
                monuId: monuId, 
                startTime: startTime, 
                endTime: endTime, 
                settled: false
            });
            monuAuctionIndex++;

            emit AuctionCreated(monuId, startTime, endTime); // Trigger event when auction is created
        } catch Error(string memory) {
            _pause(); // Pause auction if Monu minting fails
        }
    }
```    

2. `placeBid`: This function allows users to participate in the auction. If they bid for the first time, they are recorded in the bidderList and their bid details are stored. If they bid again, their previous bid data is updated.
```
function placeBid(uint256 monuId) external payable nonReentrant {
        IMonuAuction.Auction memory _auction = auction;

        if (_auction.monuId != monuId) {
            revert NotUpForAuction(); // Revert if the auction item does not match the passed monuId
        }

        if (block.timestamp >= _auction.endTime) {
            revert AuctionExpired(); // Revert if the auction has ended
        }

        if (msg.value < reservePrice) {
            revert MustOverReservePrice(); // Bid must be above the reserve price
        }

        IMonuAuction.Bid storage existingBid = personalBid[monuId][msg.sender];

        if (existingBid.bidder == address(0)) {
            // Create a new bid record if the bidder is bidding for the first time
            IMonuAuction.Bid memory newBid =
                IMonuAuction.Bid({
                    price: msg.value, 
                    bidTime: block.timestamp, 
                    bidder: payable(msg.sender), 
                    index: bidIndex[monuId]
                });

            personalBid[monuId][msg.sender] = newBid; // Save individual bid record
            bidderList[monuId].push(msg.sender); // Add bidder to the bidder list
            bidder_winningRate[monuId][bidIndex[monuId]];

            bidIndex[monuId]++;
        } else {
            if (msg.value < _getBidPrice(monuId, msg.sender)) {
                revert MustOverLastBid(); // New bid must be higher than the previous one
            }
            // Update the existing bid record
            existingBid.price = msg.value;
            existingBid.bidTime = block.timestamp;
        }
    }
```

3. `calculateAllBiddersWinningRate`:After the auction ends for the day, this function calculates the winning probability of each bidder based on their bid amount.
```
function calculateAllBiddersWinningRate(uint256 monuId) internal returns (uint256[] memory _winningRate) {
        uint256 bidderCount = bidderList[monuId].length;
        uint256[] memory winningRate = new uint256[](bidderCount);
        uint256 _totalBidPrice = _getTotalBidPrice(monuId); 
    
        if (_totalBidPrice == 0) {
            // Prevent division by zero error, return default win rate
            return winningRate;
        }
    
        // Check if any bidder has reached the maximum win rate (75%)
        if (checkIfHighestWinningRateMax(monuId)) {
            uint256 highestBidIndex = _getHighestBid(monuId).index;
            uint256 highestBidderWinningRate = (bidder_winningRate[monuId][highestBidIndex] * 75_00) / _totalBidPrice;
    
            for (uint256 i = 0; i < bidderCount; i++) {
                IMonuAuction.Bid storage bid = personalBid[monuId][bidderList[monuId][i]];
    
                if (i == highestBidIndex) {
                    // The highest bidder gets 75% win rate
                    winningRate[i] = highestBidderWinningRate;
                } else {
                    // Other bidders share the remaining 25%
                    uint256 otherBidderWinningRate = (bid.price * 25_00) / _totalBidPrice;
                    winningRate[i] = otherBidderWinningRate;
                    bidder_winningRate[monuId][i] = otherBidderWinningRate; // Update the bidder's win rate
                }
            }
        } else {
            // If no one reaches the maximum win rate, calculate each bidder's win rate based on their bid
            for (uint256 i = 0; i < bidderCount; i++) {
                IMonuAuction.Bid storage bid = personalBid[monuId][bidderList[monuId][i]];
                // Calculate the win rate based on the bidder's bid proportion
                uint256 bidderRate = (bid.price * 100_00) / _totalBidPrice;
                winningRate[i] = bidderRate;
                bidder_winningRate[monuId][i] = bidderRate; // Update the bidder's win rate
            }
        }
    
        return winningRate;
    }
```

4. `rollDice & fulfillRandomWords`:This function calls Chainlink VRF oracle to generate a random number between 0 and the highest bid, then selects the winning bidder based on this random number.
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

5.`selectWinner`: this function use the random number generated by Chainlink VRF, this function selects the final winner based on weighted random sampling.
```
    f    function selectWinner(uint256 monuId) external whenNotPaused {
        IMonuAuction.Auction memory _auction = auction;
    
        if (!_auction.settled) {
            revert AuctionNotEnd(); // Ensure the auction has ended
        }
    
        // Calculate all bidders' winning rates
        uint256[] memory winningRates = calculateAllBiddersWinningRate(monuId);
        address[] memory bidders = _getAllBidders(monuId);
        
        // Generate a random number to select the winner
        uint256 totalWinningRate = 0;
        for (uint256 i = 0; i < winningRates.length; i++) {
            totalWinningRate += winningRates[i];
        }
    
        uint256 randomValue = (s_results[s_rollers[monuAuctionIndex]] % totalWinningRate) + 1; // Random value between 1 and total win rate
        uint256 cumulativeSum = 0;
        address winner;
    
        // Select the winner
        for (uint256 i = 0; i < bidders.length; i++) {
            cumulativeSum += winningRates[i];
            if (randomValue <= cumulativeSum) {
                winner = bidders[i];
                break;
            }
        }
    
        // Trigger the auction settlement event
        emit AuctionSettled(monuId, winner, _getHighestBid(monuId).price);
    }
```