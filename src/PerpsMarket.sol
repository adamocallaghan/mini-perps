// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice Minimal ERC20 interface
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract PerpsMarket {
    // ========== ERRORS ==========
    error ZeroAmount();
    error InvalidLeverage();
    error InsufficientMargin();
    error NoOpenPosition();
    error NotEnoughLiquidity();
    error Unauthorized();
    error NothingToWithdraw();
    error TransferFailed();
    error NotLiquidatable();

    // ========== STRUCTS & ENUMS ==========
    enum PositionType { LONG, SHORT }

    struct Position {
        uint256 size;              // total notional size of the position (margin * leverage)
        uint256 leverage;          // leverage multiplier (e.g., 5x)
        PositionType direction;    // long or short
        uint256 entryPrice;        // price at which position was opened
        int256 fundingSnapshot;    // snapshot of cumulative funding at entry
        bool isOpen;               // position status
    }

    // ========== STATE VARIABLES ==========
    uint256 public constant PRECISION = 1e18;
    uint256 public constant FUNDING_INTERVAL = 1 hours;
    uint256 public constant MAINTENANCE_MARGIN_RATIO = 5e16; // 5% MMR
    uint256 public constant LIQUIDATION_PENALTY = 1e16;       // 1% reward to liquidator

    IERC20 public immutable usdc; // Collateral token (USDC assumed to be 6 decimals, but scaled to 1e18 internally)
    address public owner;

    mapping(address => Position) public positions;          // trader address => position
    mapping(address => uint256) public marginBalances;      // trader margin balances

    uint256 public vBaseReserves = 1000 ether;              // virtual base asset reserves in vAMM
    uint256 public vQuoteReserves = 1_000_000 ether;        // virtual quote asset reserves in vAMM

    uint256 public oraclePrice;                             // manually set oracle price
    int256 public cumulativeFunding;                        // global cumulative funding rate
    uint256 public lastFundingTime;                         // timestamp of last funding update

    uint256 public totalLiquidity;                          // total LP liquidity
    mapping(address => uint256) public lpShares;            // LP address => share amount

    // ========== CONSTRUCTOR ==========
    constructor(address _usdc) {
        usdc = IERC20(_usdc);
        owner = msg.sender;
        lastFundingTime = block.timestamp;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ========== REENTRANCY GUARD ==========
    uint256 private unlocked = 1;
    modifier nonReentrant() {
        require(unlocked == 1, "ReentrancyGuard: reentrant call");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // ========== ORACLE ==========
    function setOraclePrice(uint256 _price) external onlyOwner {
        oraclePrice = _price;
    }

    // ========== FUNDING RATE ==========
    function updateFundingRate() public {
        if (block.timestamp <= lastFundingTime + FUNDING_INTERVAL) return;

        uint256 timeElapsed = block.timestamp - lastFundingTime;
        uint256 vammPrice = getVammPrice();

        int256 fundingRate = int256(vammPrice) - int256(oraclePrice);
        int256 fundingDelta = fundingRate * int256(timeElapsed) / int256(1 hours);

        cumulativeFunding += fundingDelta;
        lastFundingTime = block.timestamp;
    }

    // ========== LIQUIDITY PROVIDERS ==========
    function provideLiquidity(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        lpShares[msg.sender] += amount;
        totalLiquidity += amount;
    }

    function withdrawLiquidity(uint256 amount) external {
        if (lpShares[msg.sender] < amount) revert NotEnoughLiquidity();
        lpShares[msg.sender] -= amount;
        totalLiquidity -= amount;
        if (!usdc.transfer(msg.sender, amount)) revert TransferFailed();
    }

    // ========== MARGIN MANAGEMENT ==========
    function depositMargin(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        marginBalances[msg.sender] += amount;
    }

    function withdrawMargin(uint256 amount) external {
        if (marginBalances[msg.sender] < amount) revert InsufficientMargin();
        marginBalances[msg.sender] -= amount;
        if (!usdc.transfer(msg.sender, amount)) revert TransferFailed();
    }

    // ========== POSITION OPENING ==========
    function openLong(uint256 margin, uint256 leverage) external {
        _openPosition(margin, leverage, PositionType.LONG);
    }

    function openShort(uint256 margin, uint256 leverage) external {
        _openPosition(margin, leverage, PositionType.SHORT);
    }

    function _openPosition(uint256 margin, uint256 leverage, PositionType direction) internal {
        if (margin == 0) revert ZeroAmount();
        if (leverage < 1 || leverage > 10) revert InvalidLeverage();
        if (marginBalances[msg.sender] < margin) revert InsufficientMargin();

        updateFundingRate();

        uint256 size = margin * leverage;
        uint256 price = getVammPrice();

        // vAMM slippage simulation
        if (direction == PositionType.LONG) {
            vBaseReserves -= size / price;
            vQuoteReserves += size;
        } else {
            vBaseReserves += size / price;
            vQuoteReserves -= size;
        }

        positions[msg.sender] = Position({
            size: size,
            leverage: leverage,
            direction: direction,
            entryPrice: price,
            fundingSnapshot: cumulativeFunding,
            isOpen: true
        });

        marginBalances[msg.sender] -= margin;
    }

    // ========== CLOSE POSITION ==========
    function closePosition() external nonReentrant {
        Position storage pos = positions[msg.sender];
        if (!pos.isOpen) revert NoOpenPosition();

        updateFundingRate();

        uint256 currentPrice = getVammPrice();
        int256 fundingDiff = cumulativeFunding - pos.fundingSnapshot;

        int256 pnl;
        if (pos.direction == PositionType.LONG) {
            pnl = int256(currentPrice) - int256(pos.entryPrice);
        } else {
            pnl = int256(pos.entryPrice) - int256(currentPrice);
        }
        pnl = pnl * int256(pos.size) / int256(pos.entryPrice);
        pnl -= fundingDiff * int256(pos.size) / int256(PRECISION);

        uint256 margin = pos.size / pos.leverage;
        int256 finalBalance = int256(margin) + pnl;

        delete positions[msg.sender];

        if (finalBalance > 0) {
            marginBalances[msg.sender] += uint256(finalBalance);
        }
    }

    // ========== LIQUIDATION ==========
    function isLiquidatable(address user) public view returns (bool) {
        Position memory pos = positions[user];
        if (!pos.isOpen) return false;

        uint256 price = getVammPrice();
        int256 fundingDiff = cumulativeFunding - pos.fundingSnapshot;

        int256 pnl = pos.direction == PositionType.LONG
            ? int256(price) - int256(pos.entryPrice)
            : int256(pos.entryPrice) - int256(price);

        pnl = pnl * int256(pos.size) / int256(pos.entryPrice);
        pnl -= fundingDiff * int256(pos.size) / int256(PRECISION);

        uint256 margin = pos.size / pos.leverage;
        int256 equity = int256(margin) + pnl;

        return equity < int256((pos.size * MAINTENANCE_MARGIN_RATIO) / PRECISION);
    }

    function liquidate(address user) external nonReentrant {
        Position storage pos = positions[user];
        if (!pos.isOpen) revert NoOpenPosition();

        updateFundingRate();
        if (!isLiquidatable(user)) revert NotLiquidatable();

        uint256 price = getVammPrice();
        int256 fundingDiff = cumulativeFunding - pos.fundingSnapshot;

        int256 pnl = pos.direction == PositionType.LONG
            ? int256(price) - int256(pos.entryPrice)
            : int256(pos.entryPrice) - int256(price);

        pnl = pnl * int256(pos.size) / int256(pos.entryPrice);
        pnl -= fundingDiff * int256(pos.size) / int256(PRECISION);

        uint256 margin = pos.size / pos.leverage;
        int256 finalBalance = int256(margin) + pnl;

        delete positions[user];

        if (finalBalance > 0) {
            uint256 reward = (uint256(finalBalance) * LIQUIDATION_PENALTY) / PRECISION;
            marginBalances[msg.sender] += reward;
            marginBalances[user] += uint256(finalBalance) - reward;
        }
    }

    // ========== VIEW HELPERS ==========
    function getVammPrice() public view returns (uint256) {
        return (vQuoteReserves * PRECISION) / vBaseReserves;
    }

    function getMargin(address user) external view returns (uint256) {
        Position memory pos = positions[user];
        if (!pos.isOpen) return 0;
        return pos.size / pos.leverage;
    }
}