// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.9.0;

contract OpenAuction {
    struct Bid {
        address bidder;
        uint amount;
    }

    address public auctioneer;
    uint public auctionEndTime;
    address public highestBidder;
    uint public highestBid;
    uint public minimumBidIncrement;
    bool public auctionCanceled;

    mapping(address => uint) public fundsByBidder;
    mapping(address => bool) public hasWithdrawnFunds;
    Bid[] public bids;

    event AuctionEnded(address winner, uint amount);
    event BidWithdrawn(address bidder, uint amount);
    event AuctionExtended(uint newEndTime);
    event AuctionCanceled();

    constructor(uint _biddingTime, uint _minimumBidIncrement) {
        auctioneer = msg.sender;
        auctionEndTime = block.timestamp + _biddingTime;
        minimumBidIncrement = _minimumBidIncrement;
    }

    modifier onlyAuctioneer() {
        require(
            msg.sender == auctioneer,
            "Only the auctioneer can perform this action"
        );
        _;
    }

    function placeBid() external payable {
        require(!auctionCanceled, "Auction has been canceled");
        require(block.timestamp <= auctionEndTime, "Auction has already ended");
        require(
            msg.value >= highestBid + minimumBidIncrement,
            "Bid amount is not high enough"
        );

        if (highestBid != 0) {
            fundsByBidder[highestBidder] += highestBid;
        }

        highestBidder = msg.sender;
        highestBid = msg.value;
        bids.push(Bid(msg.sender, msg.value));
    }

    function withdrawFunds() external {
        require(!auctionCanceled, "Auction has been canceled");
        require(block.timestamp > auctionEndTime, "Auction has not ended yet");

        uint amount = fundsByBidder[msg.sender];
        require(amount > 0, "No funds available to withdraw");

        fundsByBidder[msg.sender] = 0;
        hasWithdrawnFunds[msg.sender] = true;

        emit BidWithdrawn(msg.sender, amount);

        payable(msg.sender).transfer(amount);
    }

    function extendAuction(uint _extensionTime) external onlyAuctioneer {
        require(!auctionCanceled, "Auction has been canceled");
        require(block.timestamp <= auctionEndTime, "Auction has already ended");

        auctionEndTime += _extensionTime;

        emit AuctionExtended(auctionEndTime);
    }

    function cancelAuction() external onlyAuctioneer {
        require(!auctionCanceled, "Auction has already been canceled");

        auctionCanceled = true;

        emit AuctionCanceled();
    }

    function endAuction() external onlyAuctioneer {
        require(!auctionCanceled, "Auction has been canceled");
        require(block.timestamp >= auctionEndTime, "Auction has not ended yet");
        require(highestBidder != address(0), "Auction has no bids");

        emit AuctionEnded(highestBidder, highestBid);

        payable(auctioneer).transfer(highestBid);
    }

    function getBidCount() external view returns (uint) {
        return bids.length;
    }

    function getBid(uint index) external view returns (address, uint) {
        require(index < bids.length, "Invalid bid index");

        Bid memory bid = bids[index];
        return (bid.bidder, bid.amount);
    }
}
