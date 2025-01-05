// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract EnhancedAuction is 
    Initializable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    AccessControlUpgradeable 
{
    // Roles
    bytes32 public constant AUCTIONEER_ROLE = keccak256("AUCTIONEER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MAINTAINER_ROLE = keccak256("MAINTAINER_ROLE");
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");

    // System states
    enum SystemState { Active, Maintenance, Emergency }
    SystemState public currentState;

    // Rate limiting
    uint256 private constant RATE_LIMIT_PERIOD = 1 hours;
    uint256 private constant MAX_ACTIONS_PER_PERIOD = 100;
    mapping(address => uint256) private lastActionTimestamp;
    mapping(address => uint256) private actionCounter;

    // Cooldown
    uint256 private constant ACTION_COOLDOWN = 15 minutes;
    mapping(address => uint256) private lastBidTimestamp;

    struct AuctionItem {
        address nftContract;
        uint256 tokenId;
        address paymentToken;  // address(0) for ETH
        uint256 reservePrice;
        uint256 buyNowPrice;
        uint256 minimumBidIncrement;
        uint256 timeExtension;
        uint256 extendableTime;
        address owner;
        bool isActive;
    }

    // Optimized struct packing
    struct Bid {
        address bidder;
        uint96 amount;
        uint32 timestamp;
        bool withdrawn;
        uint8 bidType; // For analytics
    }

    // System metrics
    struct SystemMetrics {
        uint256 totalAuctions;
        uint256 activeAuctions;
        uint256 totalVolume;
        uint256 lastUpdateTimestamp;
    }

    // State variables
    mapping(uint256 => AuctionItem) public auctions;
    mapping(uint256 => Bid[]) public auctionBids;
    mapping(uint256 => address) public highestBidders;
    mapping(uint256 => uint256) public highestBids;
    mapping(uint256 => uint256) public auctionEndTimes;
    mapping(uint256 => bool) public auctionCanceled;
    mapping(address => bool) public blacklistedBidders;
    mapping(uint256 => mapping(address => uint256)) public fundsByBidder;
    
    uint256 public platformFeePercentage;
    uint256 public constant MAX_FEE_PERCENTAGE = 1000; // 10%
    uint256 public nextAuctionId;
    
    // System metrics
    SystemMetrics private systemMetrics;

    // Events
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed nftContract,
        uint256 indexed tokenId,
        uint256 reservePrice,
        uint256 buyNowPrice
    );
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount,
        uint256 timestamp
    );
    event AuctionEnded(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 amount
    );
    event BidWithdrawn(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount
    );
    event AuctionExtended(
        uint256 indexed auctionId,
        uint256 newEndTime
    );
    event AuctionCanceled(uint256 indexed auctionId);
    event BidderBlacklisted(address indexed bidder, bool status);
    event FeeUpdated(uint256 newFee);
    event SystemStateChanged(SystemState newState);
    event SecurityAlert(address indexed user, string alert, uint256 severity);
    event MetricsUpdated(
        uint256 totalAuctions,
        uint256 activeAuctions,
        uint256 totalVolume
    );
    event EmergencyAction(string action, address indexed triggeredBy);

    // Custom errors
    error InvalidFeePercentage();
    error InvalidAuction();
    error AuctionNotActive();
    error BidTooLow();
    error AuctionEnded();
    error AuctionNotEnded();
    error BlacklistedBidder();
    error TransferFailed();
    error InvalidAmount();
    error Unauthorized();
    error RateLimitExceeded();
    error CooldownPeriod();
    error InvalidSystemState();
    error EmergencyPaused();

    constructor() {
        _disableInitializers();
    }

    // Modifiers
    modifier whenSystemActive() {
        if (currentState != SystemState.Active) revert InvalidSystemState();
        _;
    }

    modifier withRateLimit() {
        if (block.timestamp < lastActionTimestamp[msg.sender] + RATE_LIMIT_PERIOD) {
            if (actionCounter[msg.sender] >= MAX_ACTIONS_PER_PERIOD) {
                revert RateLimitExceeded();
            }
            actionCounter[msg.sender]++;
        } else {
            lastActionTimestamp[msg.sender] = block.timestamp;
            actionCounter[msg.sender] = 1;
        }
        _;
    }

    modifier withCooldown() {
        if (block.timestamp < lastBidTimestamp[msg.sender] + ACTION_COOLDOWN) {
            revert CooldownPeriod();
        }
        _;
        lastBidTimestamp[msg.sender] = block.timestamp;
    }

    function initialize(
        address initialAdmin,
        uint256 _platformFeePercentage
    ) public initializer {
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();

        if (_platformFeePercentage > MAX_FEE_PERCENTAGE) revert InvalidFeePercentage();
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(AUCTIONEER_ROLE, initialAdmin);
        _grantRole(MAINTAINER_ROLE, initialAdmin);
        _grantRole(RECOVERY_ROLE, initialAdmin);
        
        platformFeePercentage = _platformFeePercentage;
        nextAuctionId = 1;
        currentState = SystemState.Active;

        systemMetrics.lastUpdateTimestamp = block.timestamp;
    }

    function createAuction(
        address nftContract,
        uint256 tokenId,
        address paymentToken,
        uint256 reservePrice,
        uint256 buyNowPrice,
        uint256 minimumBidIncrement,
        uint256 duration,
        uint256 timeExtension,
        uint256 extendableTime
    ) external 
        whenNotPaused 
        whenSystemActive 
        withRateLimit 
        nonReentrant 
        returns (uint256) 
    {
        if (reservePrice >= buyNowPrice) revert InvalidAmount();
        
        uint256 auctionId = nextAuctionId++;
        
        AuctionItem storage auction = auctions[auctionId];
        auction.nftContract = nftContract;
        auction.tokenId = tokenId;
        auction.paymentToken = paymentToken;
        auction.reservePrice = reservePrice;
        auction.buyNowPrice = buyNowPrice;
        auction.minimumBidIncrement = minimumBidIncrement;
        auction.timeExtension = timeExtension;
        auction.extendableTime = extendableTime;
        auction.owner = msg.sender;
        auction.isActive = true;

        auctionEndTimes[auctionId] = block.timestamp + duration;
        
        // Transfer NFT to contract
        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);
        
        // Update metrics
        systemMetrics.totalAuctions++;
        systemMetrics.activeAuctions++;
        
        emit AuctionCreated(
            auctionId,
            nftContract,
            tokenId,
            reservePrice,
            buyNowPrice
        );
        
        return auctionId;
    }

    function placeBid(
        uint256 auctionId,
        uint256 bidAmount
    ) external 
        payable 
        nonReentrant 
        whenNotPaused 
        whenSystemActive 
        withRateLimit 
        withCooldown 
    {
        AuctionItem storage auction = auctions[auctionId];
        if (!auction.isActive) revert AuctionNotActive();
        if (blacklistedBidders[msg.sender]) revert BlacklistedBidder();
        if (block.timestamp >= auctionEndTimes[auctionId]) revert AuctionEnded();
        
        uint256 currentBid = highestBids[auctionId];
        if (bidAmount <= currentBid + auction.minimumBidIncrement) revert BidTooLow();

        // Handle payment
        if (auction.paymentToken == address(0)) {
            if (msg.value != bidAmount) revert InvalidAmount();
        } else {
            IERC20(auction.paymentToken).transferFrom(
                msg.sender,
                address(this),
                bidAmount
            );
        }

        // Refund previous highest bidder
        if (currentBid > 0) {
            fundsByBidder[auctionId][highestBidders[auctionId]] += currentBid;
        }

        // Update auction state
        highestBidders[auctionId] = msg.sender;
        highestBids[auctionId] = bidAmount;
        auctionBids[auctionId].push(Bid({
            bidder: msg.sender,
            amount: uint96(bidAmount),
            timestamp: uint32(block.timestamp),
            withdrawn: false,
            bidType: 0
        }));

        // Update system metrics
        systemMetrics.totalVolume += bidAmount;

        // Check for auction extension
        if (block.timestamp >= auctionEndTimes[auctionId] - auction.extendableTime) {
            auctionEndTimes[auctionId] += auction.timeExtension;
            emit AuctionExtended(auctionId, auctionEndTimes[auctionId]);
        }

        emit BidPlaced(auctionId, msg.sender, bidAmount, block.timestamp);

        // Check for buy-now price
        if (bidAmount >= auction.buyNowPrice) {
            _endAuction(auctionId);
        }
    }


    function setEmergencyState(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        currentState = enabled ? SystemState.Emergency : SystemState.Active;
        if (enabled) {
            _pause();
        } else {
            _unpause();
        }
        emit SystemStateChanged(currentState);
        emit EmergencyAction(enabled ? "EMERGENCY_ENABLED" : "EMERGENCY_DISABLED", msg.sender);
    }

    function recoverToken(
        address token,
        uint256 amount
    ) external onlyRole(RECOVERY_ROLE) {
        if (token == address(0)) {
            _safeTransferETH(msg.sender, amount);
        } else {
            IERC20(token).transfer(msg.sender, amount);
        }
        emit EmergencyAction("TOKEN_RECOVERED", msg.sender);
    }

    function getSystemMetrics() external view returns (
        uint256 totalAuctions,
        uint256 activeAuctions,
        uint256 totalVolume,
        uint256 lastUpdateTimestamp
    ) {
        return (
            systemMetrics.totalAuctions,
            systemMetrics.activeAuctions,
            systemMetrics.totalVolume,
            systemMetrics.lastUpdateTimestamp
        );
    }

    function setMaintenanceMode(bool enabled) external onlyRole(MAINTAINER_ROLE) {
        currentState = enabled ? SystemState.Maintenance : SystemState.Active;
        emit SystemStateChanged(currentState);
    }

    function checkRateLimit(address user) external view returns (
        uint256 actionsRemaining,
        uint256 cooldownEnds
    ) {
        uint256 currentActions = actionCounter[user];
        uint256 timeUntilReset = 0;
        
        if (block.timestamp < lastActionTimestamp[user] + RATE_LIMIT_PERIOD) {
            timeUntilReset = lastActionTimestamp[user] + RATE_LIMIT_PERIOD - block.timestamp;
            actionsRemaining = MAX_ACTIONS_PER_PERIOD - currentActions;
        } else {
            actionsRemaining = MAX_ACTIONS_PER_PERIOD;
        }

        cooldownEnds = lastBidTimestamp[user] + ACTION_COOLDOWN;
        return (actionsRemaining, cooldownEnds);
    }

    // Function to receive ETH
    receive() external payable {}
}