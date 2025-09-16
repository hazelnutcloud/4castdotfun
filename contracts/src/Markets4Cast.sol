// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract Markets4Cast is Ownable {
    using LibBitmap for LibBitmap.Bitmap;

    uint256 public constant BPS = 1000;

    error InvalidPrice();
    error PriceTooHigh();
    error InvalidSize();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error MarketNotActive();
    error InsufficientShares();

    enum Outcome {
        Yes,
        No
    }

    enum Side {
        Bid,
        Ask
    }

    struct LimitOrder {
        address maker;
        uint256 size;
        Side side;
    }

    struct PriceLevel {
        LimitOrder[] orders;
        uint256 totalSize;
        uint256 nextOrderIndex;
    }

    /**
     * 1. yesUnifiedTicks - Contains:
     *     • Yes buy orders (bids) at their natural price
     *     • No sell orders (asks) at inverted price (BPS - originalPrice)
     *     2. noUnifiedTicks - Contains:
     *     • No buy orders (bids) at their natural price
     *     • Yes sell orders (asks) at inverted price (BPS - originalPrice)
     *     3. yesBidTicks/noBidTicks - Only contain bid orders
     */
    struct Market {
        LibBitmap.Bitmap yesUnifiedTicks;
        LibBitmap.Bitmap noUnifiedTicks;
        LibBitmap.Bitmap yesBidTicks;
        LibBitmap.Bitmap noBidTicks;
        mapping(uint256 => PriceLevel) yesOrders;
        mapping(uint256 => PriceLevel) noOrders;
        mapping(address => uint256) yesBalances;
        mapping(address => uint256) noBalances;
        uint256 totalCollateral;
        bool resolved;
        bool active;
        Outcome outcome;
    }

    mapping(uint256 => Market) markets;
    address public collateral;
    uint256 private _collateralMultiplier;
    uint256 private _marketIdCounter;

    event LimitOrderPlaced(
        uint256 indexed marketId,
        address indexed maker,
        bytes32 orderId,
        uint256 price,
        uint256 size,
        Outcome outcome,
        Side side
    );

    event MarketOrderExecuted(
        address indexed taker, uint256 indexed marketId, uint256 totalFulfilled, Outcome outcome, Side side
    );

    event OrderFilled(uint256 indexed marketId, address indexed maker, bytes32 orderId, uint256 size, address taker);

    event PriceLevelCleared(uint256 indexed marketId, uint256 price, Outcome outcome);

    event SharesTransferred(
        address indexed from, address indexed to, uint256 indexed marketId, uint256 amount, Outcome outcome
    );

    event OrderCancelled(uint256 indexed marketId, address indexed maker, bytes32 orderId);

    event RewardsClaimed(address indexed user, uint256 indexed marketId, uint256 amount);

    event MarketCreated(uint256 indexed marketId);

    event MarketResolved(uint256 indexed marketId, Outcome outcome);

    constructor(address _collateral) {
        collateral = _collateral;
        _collateralMultiplier = 10 ** ERC20(_collateral).decimals();

        _initializeOwner(msg.sender);
    }

    modifier marketActive(uint256 marketId) {
        Market storage market = markets[marketId];
        if (!market.active) revert MarketNotActive();
        if (market.resolved) revert MarketAlreadyResolved();
        _;
    }

    function limitBuy(uint256 marketId, uint256 price, uint256 size, Outcome outcome)
        external
        marketActive(marketId)
        returns (bytes32 orderId)
    {
        if (price == 0) revert InvalidPrice();
        if (price >= BPS) revert PriceTooHigh();
        if (size == 0) revert InvalidSize();

        Market storage market = markets[marketId];

        uint256 collateralAmount = (size * price * _collateralMultiplier) / BPS;

        SafeTransferLib.safeTransferFrom(collateral, msg.sender, address(this), collateralAmount);

        LibBitmap.Bitmap storage ticks = outcome == Outcome.Yes ? market.yesUnifiedTicks : market.noUnifiedTicks;
        LibBitmap.Bitmap storage bidTicks = outcome == Outcome.Yes ? market.yesBidTicks : market.noBidTicks;
        PriceLevel storage priceLevel = outcome == Outcome.Yes ? market.yesOrders[price] : market.noOrders[price];

        ticks.set(price);
        bidTicks.set(price);
        priceLevel.orders.push(LimitOrder({maker: msg.sender, size: size, side: Side.Bid}));
        priceLevel.totalSize += size;

        orderId = getOrderId(marketId, price, priceLevel.orders.length - 1);

        emit LimitOrderPlaced(marketId, msg.sender, orderId, price, size, outcome, Side.Bid);
    }

    function marketBuy(uint256 marketId, uint256 size, Outcome outcome)
        external
        marketActive(marketId)
        returns (uint256 fulfilled)
    {
        if (size == 0) revert InvalidSize();

        Market storage market = markets[marketId];

        LibBitmap.Bitmap storage counterTicks = outcome == Outcome.Yes ? market.noUnifiedTicks : market.yesUnifiedTicks;
        LibBitmap.Bitmap storage counterBidTicks = outcome == Outcome.Yes ? market.noBidTicks : market.yesBidTicks;
        mapping(address => uint256) storage balances = outcome == Outcome.Yes ? market.yesBalances : market.noBalances;
        uint256 collateralToTransferIn = 0;

        while (true) {
            uint256 marketPrice = counterTicks.findLastSet(BPS);

            if (marketPrice == type(uint256).max) break; // NOT_FOUND

            PriceLevel storage counterPriceLevel =
                outcome == Outcome.Yes ? market.noOrders[marketPrice] : market.yesOrders[marketPrice];
            uint256 collateralIncrease = 0;

            if (size >= counterPriceLevel.totalSize) {
                fulfilled += counterPriceLevel.totalSize;
                counterPriceLevel.totalSize = 0;
                counterTicks.unset(marketPrice);
                counterBidTicks.unset(marketPrice);
                {
                    Outcome clearedOutcome = outcome == Outcome.Yes ? Outcome.No : Outcome.Yes;
                    emit PriceLevelCleared(marketId, marketPrice, clearedOutcome);
                }
            } else {
                counterPriceLevel.totalSize -= size;
                fulfilled += size;
            }

            for (uint256 i = counterPriceLevel.nextOrderIndex; i < counterPriceLevel.orders.length; i++) {
                LimitOrder storage counterOrder = counterPriceLevel.orders[i];
                if (counterOrder.size == 0) continue;

                uint256 counterFulfilled;

                if (counterOrder.size >= size) {
                    counterOrder.size -= size;
                    counterFulfilled = size;
                    size = 0;
                } else {
                    size -= counterOrder.size;
                    counterFulfilled = counterOrder.size;
                    counterOrder.size = 0;
                }

                if (counterOrder.side == Side.Bid) {
                    mapping(address => uint256) storage counterBalances =
                        outcome == Outcome.Yes ? market.noBalances : market.yesBalances;
                    collateralIncrease += counterFulfilled;
                    counterBalances[counterOrder.maker] += counterFulfilled;

                    Outcome counterOutcome = outcome == Outcome.Yes ? Outcome.No : Outcome.Yes;
                    emit SharesTransferred(address(0), counterOrder.maker, marketId, counterFulfilled, counterOutcome);
                } else {
                    SafeTransferLib.safeTransferFrom(
                        collateral,
                        msg.sender,
                        counterOrder.maker,
                        (counterFulfilled * (BPS - marketPrice) * _collateralMultiplier) / BPS
                    );

                    emit SharesTransferred(counterOrder.maker, msg.sender, marketId, counterFulfilled, outcome);
                }

                emit OrderFilled(
                    marketId, counterOrder.maker, getOrderId(marketId, marketPrice, i), counterFulfilled, msg.sender
                );

                if (size == 0) {
                    break;
                }

                counterPriceLevel.nextOrderIndex = i + 1;
            }

            market.totalCollateral += collateralIncrease;
            collateralToTransferIn += (collateralIncrease * (BPS - marketPrice) * _collateralMultiplier) / BPS;

            if (size == 0) break;
        }

        if (collateralToTransferIn > 0) {
            SafeTransferLib.safeTransferFrom(collateral, msg.sender, address(this), collateralToTransferIn);
        }

        if (fulfilled > 0) {
            balances[msg.sender] += fulfilled;

            emit MarketOrderExecuted(msg.sender, marketId, fulfilled, outcome, Side.Bid);

            emit SharesTransferred(address(0), msg.sender, marketId, fulfilled, outcome);
        }
    }

    function limitSell(uint256 marketId, uint256 price, uint256 size, Outcome outcome)
        external
        marketActive(marketId)
        returns (bytes32 orderId)
    {
        if (price == 0) revert InvalidPrice();
        if (price >= BPS) revert PriceTooHigh();
        if (size == 0) revert InvalidSize();

        Market storage market = markets[marketId];

        mapping(address => uint256) storage balances = outcome == Outcome.Yes ? market.yesBalances : market.noBalances;

        if (balances[msg.sender] < size) revert InsufficientShares();

        balances[msg.sender] -= size;

        uint256 tickPrice = BPS - price;

        LibBitmap.Bitmap storage ticks = outcome == Outcome.Yes ? market.noUnifiedTicks : market.yesUnifiedTicks;
        PriceLevel storage priceLevel =
            outcome == Outcome.Yes ? market.noOrders[tickPrice] : market.yesOrders[tickPrice];

        ticks.set(tickPrice);
        priceLevel.orders.push(LimitOrder({maker: msg.sender, size: size, side: Side.Ask}));
        priceLevel.totalSize += size;

        orderId = getOrderId(marketId, tickPrice, priceLevel.orders.length - 1);

        emit LimitOrderPlaced(marketId, msg.sender, orderId, price, size, outcome, Side.Ask);
    }

    function marketSell(uint256 marketId, uint256 size, Outcome outcome)
        external
        marketActive(marketId)
        returns (uint256 fulfilled)
    {
        if (size == 0) revert InvalidSize();

        Market storage market = markets[marketId];

        LibBitmap.Bitmap storage counterTicks = outcome == Outcome.Yes ? market.yesBidTicks : market.noBidTicks;
        mapping(address => uint256) storage balances = outcome == Outcome.Yes ? market.yesBalances : market.noBalances;

        if (balances[msg.sender] < size) revert InsufficientShares();

        while (true) {
            uint256 marketPrice = counterTicks.findLastSet(BPS);

            if (marketPrice == type(uint256).max) break; // NOT_FOUND

            PriceLevel storage counterPriceLevel =
                outcome == Outcome.Yes ? market.yesOrders[marketPrice] : market.noOrders[marketPrice];

            bool hasAsk = false;

            for (uint256 i = counterPriceLevel.nextOrderIndex; i < counterPriceLevel.orders.length; i++) {
                LimitOrder storage counterOrder = counterPriceLevel.orders[i];
                if (counterOrder.size == 0) continue;
                if (counterOrder.side == Side.Ask) {
                    hasAsk = true;
                    continue;
                }

                uint256 counterFulfilled;

                if (counterOrder.size >= size) {
                    counterOrder.size -= size;
                    counterFulfilled = size;
                    size = 0;
                } else {
                    size -= counterOrder.size;
                    counterFulfilled = counterOrder.size;
                    counterOrder.size = 0;
                }

                SafeTransferLib.safeTransfer(
                    collateral, msg.sender, (counterFulfilled * marketPrice * _collateralMultiplier) / BPS
                );
                balances[counterOrder.maker] += counterFulfilled;
                fulfilled += counterFulfilled;

                emit SharesTransferred(msg.sender, counterOrder.maker, marketId, counterFulfilled, outcome);

                emit OrderFilled(
                    marketId, counterOrder.maker, getOrderId(marketId, marketPrice, i), counterFulfilled, msg.sender
                );

                if (size == 0) {
                    break;
                }

                if (!hasAsk) {
                    counterPriceLevel.nextOrderIndex = i + 1;
                }
            }

            if (size == 0) break;

            counterTicks.unset(marketPrice);
        }

        if (fulfilled > 0) {
            balances[msg.sender] -= fulfilled;

            emit MarketOrderExecuted(msg.sender, marketId, fulfilled, outcome, Side.Ask);
        }
    }

    function cancelOrder(uint256 marketId, uint256 price, uint256 orderIndex, Side side, Outcome outcome)
        external
        marketActive(marketId)
    {
        Market storage market = markets[marketId];

        if (side == Side.Bid) {
            PriceLevel storage priceLevel = outcome == Outcome.Yes ? market.yesOrders[price] : market.noOrders[price];
            LimitOrder storage order = priceLevel.orders[orderIndex];

            if (order.maker != msg.sender) revert Ownable.Unauthorized();

            priceLevel.totalSize -= order.size;
            uint256 collateralRefund = (order.size * price * _collateralMultiplier) / BPS;
            order.size = 0;

            if (priceLevel.totalSize == 0) {
                LibBitmap.Bitmap storage ticks = outcome == Outcome.Yes ? market.yesUnifiedTicks : market.noUnifiedTicks;
                LibBitmap.Bitmap storage bidTicks = outcome == Outcome.Yes ? market.yesBidTicks : market.noBidTicks;
                ticks.unset(price);
                bidTicks.unset(price);
            }

            SafeTransferLib.safeTransfer(collateral, msg.sender, collateralRefund);
        } else {
            uint256 tickPrice = BPS - price;
            PriceLevel storage priceLevel =
                outcome == Outcome.Yes ? market.noOrders[tickPrice] : market.yesOrders[tickPrice];
            LimitOrder storage order = priceLevel.orders[orderIndex];

            if (order.maker != msg.sender) revert Ownable.Unauthorized();

            priceLevel.totalSize -= order.size;
            mapping(address => uint256) storage balances =
                outcome == Outcome.Yes ? market.yesBalances : market.noBalances;
            balances[msg.sender] += order.size;
            order.size = 0;

            if (priceLevel.totalSize == 0) {
                LibBitmap.Bitmap storage ticks = outcome == Outcome.Yes ? market.noUnifiedTicks : market.yesUnifiedTicks;
                LibBitmap.Bitmap storage bidTicks = outcome == Outcome.Yes ? market.noBidTicks : market.yesBidTicks;
                ticks.unset(price);
                bidTicks.unset(price);
            }
        }

        bytes32 orderId =
            side == Side.Bid ? getOrderId(marketId, price, orderIndex) : getOrderId(marketId, BPS - price, orderIndex);

        emit OrderCancelled(marketId, msg.sender, orderId);
    }

    function claim(uint256 marketId) external {
        Market storage market = markets[marketId];

        if (!market.active) revert MarketNotActive();
        if (!market.resolved) revert MarketNotResolved();

        mapping(address => uint256) storage balances =
            market.outcome == Outcome.Yes ? market.yesBalances : market.noBalances;

        uint256 shares = balances[msg.sender];
        if (shares == 0) revert InsufficientShares();

        balances[msg.sender] = 0;

        SafeTransferLib.safeTransfer(collateral, msg.sender, shares * _collateralMultiplier);

        emit RewardsClaimed(msg.sender, marketId, shares);
    }

    function createMarket() external onlyOwner {
        uint256 marketId = _marketIdCounter++;

        markets[marketId].active = true;

        emit MarketCreated(marketId);
    }

    function resolveMarket(uint256 marketId, Outcome outcome) external onlyOwner {
        Market storage market = markets[marketId];

        if (!market.active) revert MarketNotActive();
        if (market.resolved) revert MarketAlreadyResolved();

        market.resolved = true;
        market.outcome = outcome;

        emit MarketResolved(marketId, outcome);
    }

    function getOrderId(uint256 marketId, uint256 price, uint256 orderIndex) public pure returns (bytes32 orderId) {
        return EfficientHashLib.hash(marketId, price, orderIndex);
    }
}
