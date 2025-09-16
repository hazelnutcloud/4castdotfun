# 4Cast Unified Orderbook Mechanics

## Overview

4Cast implements a unified orderbook that handles both minting of new shares and trading of existing shares. The orderbook supports binary prediction markets with Yes/No outcomes and uses a unique price inversion mechanism to create liquidity between opposing outcomes.

## Core Data Structures

### Market Structure
```solidity
struct Market {
    LibBitmap.Bitmap yesUnifiedTicks;     // All Yes orders (bid + ask)
    LibBitmap.Bitmap noUnifiedTicks;      // All No orders (bid + ask)
    LibBitmap.Bitmap yesBidTicks;         // Yes bid orders only
    LibBitmap.Bitmap noBidTicks;          // No bid orders only
    mapping(uint256 => PriceLevel) yesOrders;
    mapping(uint256 => PriceLevel) noOrders;
    mapping(address => uint256) yesBalances;
    mapping(address => uint256) noBalances;
    uint256 totalCollateral;
    bool resolved;
    Outcome outcome;
}
```

### Order Types
- **Limit Buy (limitBuy)**: Bid orders that place liquidity
- **Limit Sell (limitSell)**: Ask orders that place liquidity
- **Market Buy (marketBuy)**: Aggressive orders that consume liquidity
- **Market Sell (marketSell)**: Aggressive orders that consume liquidity

## Key Innovation: Price Inversion

The orderbook uses price inversion to create cross-outcome liquidity:
- A Yes bid at price P is equivalent to a No ask at price (1000 - P)
- A No bid at price P is equivalent to a Yes ask at price (1000 - P)

This allows Yes buyers to be matched against No bids, enabling share minting.

## Order Matching Mechanics

### Market Buy Orders

When placing a **market BUY order** for shares of a particular outcome, the order may be matched against:

#### 1. Limit BUY orders of the OPPOSITE outcome (Share Minting)
```solidity
// Market buy Yes matches against No bids
LibBitmap.Bitmap storage counterTicks = outcome == Outcome.Yes
    ? market.noUnifiedTicks  // Look for No orders
    : market.yesUnifiedTicks; // Look for Yes orders
```

**Mechanics:**
- **Share Creation**: New shares are minted for both parties
- **Collateral Flow**: Market buyer transfers collateral to contract
- **Price Calculation**: Uses inverted pricing `(BPS - marketPrice)`
- **Result**: Both buyer and matched bidder receive shares of their respective outcomes

**Example**:
- Alice places market buy for 100 Yes shares
- Matches against Bob's limit buy for 100 No shares at price 600
- Alice gets 100 Yes shares, Bob gets 100 No shares
- Alice pays 40% of collateral, Bob already deposited 60%

#### 2. Limit SELL orders of the SAME outcome (Share Transfer)
```solidity
if (counterOrder.side == Side.Ask) {
    // Direct share transfer from seller to buyer
    SafeTransferLib.safeTransferFrom(
        collateral,
        msg.sender,
        counterOrder.maker,
        (counterFulfilled * (BPS - marketPrice) * _collateralMultiplier) / BPS
    );
}
```

**Mechanics:**
- **Share Transfer**: Existing shares transfer from seller to buyer
- **Collateral Flow**: Buyer pays seller directly
- **No Minting**: No new shares created
- **Result**: Buyer receives shares, seller receives collateral

### Market Sell Orders

When placing a **market SELL order** for shares of a particular outcome, the order may **ONLY** be matched against:

#### Limit BUY orders of the SAME outcome
```solidity
// Market sell only matches same outcome bids
LibBitmap.Bitmap storage counterTicks = outcome == Outcome.Yes
    ? market.yesBidTicks  // Only Yes bids
    : market.noBidTicks;  // Only No bids
```

**Mechanics:**
- **Share Transfer**: Shares transfer from seller to buyer
- **Collateral Flow**: Buyer's escrowed collateral transfers to seller
- **Validation**: Seller must have sufficient shares
- **Result**: Seller receives collateral, buyer receives shares

**Key Constraint**: Market sells cannot create new shares - they only facilitate transfer of existing shares.

## Price Level Management

### Bid Tracking
The contract maintains separate bitmap tracking for bids:
```solidity
LibBitmap.Bitmap storage bidTicks = outcome == Outcome.Yes
    ? market.yesBidTicks
    : market.noBidTicks;
```

This allows market sell orders to efficiently find only bid orders of the same outcome.

### Order Processing
Orders within a price level are processed FIFO (First In, First Out):
```solidity
for (uint256 i = counterPriceLevel.nextOrderIndex; i < counterPriceLevel.orders.length; i++) {
    // Process orders in sequence
}
```

### Price Level Clearing
When all orders at a price level are filled:
```solidity
if (size >= counterPriceLevel.totalSize) {
    counterPriceLevel.totalSize = 0;
    counterTicks.unset(marketPrice);
    counterBidTicks.unset(marketPrice);
    emit PriceLevelCleared(marketId, marketPrice, clearedOutcome);
}
```

## Collateral Management

### For Limit Buy Orders
```solidity
uint256 collateralAmount = (size * price * _collateralMultiplier) / BPS;
SafeTransferLib.safeTransferFrom(collateral, msg.sender, address(this), collateralAmount);
```

Collateral required = Share quantity × Price × Collateral multiplier / 1000

### For Limit Sell Orders
```solidity
require(balances[msg.sender] >= size, "Insufficient shares");
balances[msg.sender] -= size;
```

No collateral required - shares are escrowed instead.

### For Market Orders
- **Market Buy**: Collateral transferred based on matched orders
- **Market Sell**: Receives collateral from matched buyers

## Summary

The unified orderbook enables:

1. **Liquidity Aggregation**: Yes buyers can match against No bids (minting) or Yes asks (transfer)
2. **Efficient Price Discovery**: Cross-outcome matching creates deeper liquidity
3. **Flexible Trading**: Supports both share creation and transfer in single orderbook
4. **Capital Efficiency**: Shared liquidity between outcomes reduces required capital

The key innovation is allowing market buy orders to match against opposite outcome bids for share minting, while restricting market sell orders to same outcome bids for share transfer only. This asymmetry ensures proper collateral backing while maximizing liquidity utilization.
