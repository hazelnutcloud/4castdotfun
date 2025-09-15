// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

contract Markets4Cast {
    using LibBitmap for LibBitmap.Bitmap;

    uint256 public constant BPS = 1000;

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
        Outcome outcome;
    }

    struct PriceLevel {
        LimitOrder[] orders;
        uint256 totalSize;
        uint256 nextOrderIndex;
    }

    struct Market {
        LibBitmap.Bitmap yesTicks;
        LibBitmap.Bitmap noTicks;
        mapping(uint256 => PriceLevel) yesOrders;
        mapping(uint256 => PriceLevel) noOrders;
        mapping(address => uint256) yesBalances;
        mapping(address => uint256) noBalances;
        uint256 totalCollateral;
        bool resolved;
        Outcome outcome;
    }

    mapping(uint256 => Market) markets;
    address public collateral;
    uint256 private _collateralMultiplier;

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
        address indexed taker,
        uint256 indexed marketId,
        uint256 totalFulfilled,
        Outcome outcome
    );

    event OrderFilled(
        uint256 indexed marketId,
        address indexed maker,
        bytes32 orderId,
        uint256 size,
        address taker
    );

    event PriceLevelCleared(
        uint256 indexed marketId,
        uint256 price,
        Outcome outcome
    );

    event SharesTransferred(
        address indexed from,
        address indexed to,
        uint256 indexed marketId,
        uint256 amount,
        Outcome outcome
    );

    constructor(address _collateral) {
        collateral = _collateral;
        _collateralMultiplier = 10 ** ERC20(_collateral).decimals();
    }

    function limitBuy(
        uint256 marketId,
        uint256 price,
        uint256 size,
        Outcome outcome
    ) external {
        require(price > 0, "Invalid price");
        require(price < BPS, "Price too high");
        require(size > 0, "Invalid size");

        Market storage market = markets[marketId];
        LibBitmap.Bitmap storage ticks = outcome == Outcome.Yes
            ? market.yesTicks
            : market.noTicks;
        PriceLevel storage priceLevel = outcome == Outcome.Yes
            ? market.yesOrders[price]
            : market.noOrders[price];

        ticks.set(price);
        priceLevel.orders.push(
            LimitOrder({
                maker: msg.sender,
                size: size,
                side: Side.Bid,
                outcome: outcome
            })
        );
        priceLevel.totalSize += size;

        emit LimitOrderPlaced(
            marketId,
            msg.sender,
            getOrderId(marketId, price, priceLevel.orders.length - 1),
            price,
            size,
            outcome,
            Side.Bid
        );
    }

    function marketBuy(
        uint256 marketId,
        uint256 size,
        Outcome outcome
    ) external returns (uint256 fulfilled) {
        require(size > 0, "Invalid size");

        Market storage market = markets[marketId];

        require(!market.resolved, "Market is resolved");

        LibBitmap.Bitmap storage counterTicks = outcome == Outcome.Yes
            ? market.noTicks
            : market.yesTicks;
        mapping(address => uint256) storage balances = outcome == Outcome.Yes
            ? market.yesBalances
            : market.noBalances;
        uint256 collateralToTransferIn = 0;

        while (true) {
            uint256 marketPrice = counterTicks.findLastSet(BPS);

            if (marketPrice == type(uint256).max) break; // NOT_FOUND

            PriceLevel storage counterPriceLevel = outcome == Outcome.Yes
                ? market.noOrders[marketPrice]
                : market.yesOrders[marketPrice];
            uint256 collateralIncrease = 0;

            if (size >= counterPriceLevel.totalSize) {
                fulfilled += counterPriceLevel.totalSize;
                counterPriceLevel.totalSize = 0;
                counterTicks.unset(marketPrice);
                {
                    Outcome clearedOutcome = outcome == Outcome.Yes
                        ? Outcome.No
                        : Outcome.Yes;
                    emit PriceLevelCleared(
                        marketId,
                        marketPrice,
                        clearedOutcome
                    );
                }
            } else {
                counterPriceLevel.totalSize -= size;
                fulfilled += size;
            }

            for (
                uint256 i = counterPriceLevel.nextOrderIndex;
                i < counterPriceLevel.orders.length;
                i++
            ) {
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
                    mapping(address => uint256)
                        storage counterBalances = outcome == Outcome.Yes
                            ? market.noBalances
                            : market.yesBalances;
                    collateralIncrease += counterFulfilled;
                    SafeTransferLib.safeTransferFrom(
                        collateral,
                        counterOrder.maker,
                        address(this),
                        (counterFulfilled *
                            marketPrice *
                            _collateralMultiplier) / BPS
                    );
                    counterBalances[counterOrder.maker] += counterFulfilled;

                    Outcome counterOutcome = outcome == Outcome.Yes
                        ? Outcome.No
                        : Outcome.Yes;
                    emit SharesTransferred(
                        address(0),
                        counterOrder.maker,
                        marketId,
                        counterFulfilled,
                        counterOutcome
                    );
                } else {
                    SafeTransferLib.safeTransferFrom(
                        collateral,
                        msg.sender,
                        counterOrder.maker,
                        (counterFulfilled *
                            (BPS - marketPrice) *
                            _collateralMultiplier) / BPS
                    );
                    balances[counterOrder.maker] -= counterFulfilled;

                    emit SharesTransferred(
                        counterOrder.maker,
                        msg.sender,
                        marketId,
                        counterFulfilled,
                        outcome
                    );
                }

                emit OrderFilled(
                    marketId,
                    counterOrder.maker,
                    getOrderId(marketId, marketPrice, i),
                    counterFulfilled,
                    msg.sender
                );

                if (size == 0) {
                    break;
                }

                counterPriceLevel.nextOrderIndex = i + 1;
            }

            market.totalCollateral += collateralIncrease;
            collateralToTransferIn +=
                (collateralIncrease *
                    (BPS - marketPrice) *
                    _collateralMultiplier) /
                BPS;

            if (size == 0) break;
        }

        if (collateralToTransferIn > 0) {
            SafeTransferLib.safeTransferFrom(
                collateral,
                msg.sender,
                address(this),
                collateralToTransferIn
            );
        }

        if (fulfilled > 0) {
            balances[msg.sender] += fulfilled;

            emit MarketOrderExecuted(msg.sender, marketId, fulfilled, outcome);

            emit SharesTransferred(
                address(0),
                msg.sender,
                marketId,
                fulfilled,
                outcome
            );
        }
    }

    // TODOS:
    // limitSell
    // marketSell
    // cancel

    function getOrderId(
        uint256 marketId,
        uint256 price,
        uint256 orderIndex
    ) public pure returns (bytes32 orderId) {
        return EfficientHashLib.hash(marketId, price, orderIndex);
    }
}
