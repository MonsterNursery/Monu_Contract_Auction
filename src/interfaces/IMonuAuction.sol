// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

abstract contract IMonuAuction {
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
}
