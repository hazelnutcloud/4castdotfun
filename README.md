# 4cast.fun 🔮

> A fully onchain prediction market platform powered by a unified orderbook

4cast.fun is a next-generation prediction market platform that brings transparent, efficient, and decentralized forecasting to RISE L2. Built with a unified orderbook architecture, it seamlessly handles both bid orders (minting shares) and ask orders (selling shares) for binary prediction markets.

## 🌟 Features

- **Unified Orderbook**: Single orderbook handles both minting (bids) and selling (asks) of prediction shares
- **Binary Markets**: Clean Yes/No prediction markets for maximum simplicity
- **USDC Collateral**: All markets use USDC as the base collateral token
- **Gas Efficient**: Optimized for RISE L2's low-cost, high-throughput environment
- **Mobile First**: Designed for seamless mobile app integration

## 🏗️ Architecture

### Core Contract: `Markets4Cast.sol`

The main contract implements a sophisticated orderbook system where:

- **Limit Orders**: Users can place limit buy orders at specific price points
- **Market Orders**: Users can execute immediate trades against existing liquidity
- **Dual Outcomes**: Each market supports both Yes and No outcome shares
- **Price Discovery**: Efficient price discovery through order matching

### Order Types

#### Bid Orders (Minting)
- Place limit buy orders for Yes/No shares
- Provide collateral upfront based on price and size
- Get matched against ask orders when prices cross

#### Ask Orders (Selling)
- Sell existing shares at market prices
- Execute immediately against available bid liquidity
- Receive collateral based on current market prices

### Market Resolution

Markets are resolved by the 4cast team to determine the final outcome (Yes or No). Upon resolution:
- Winning shares can be redeemed for full collateral value
- Losing shares become worthless
- All trades settle based on the final outcome

## 🛠️ Technical Stack

- **Smart Contracts**: Solidity ^0.8.30
- **Framework**: Foundry
- **Dependencies**: Solady (gas-optimized libraries)
- **Network**: RISE L2
- **Collateral**: USDC

## 📋 Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Git for cloning the repository

## 🚀 Getting Started

### Installation

```bash
# Clone the repository
git clone https://github.com/your-org/4cast-contracts.git
cd 4cast-contracts

# Install dependencies
forge install
```

### Build

```bash
# Compile contracts
forge build
```

### Test

```bash
# Run all tests
forge test

# Run tests with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/Markets4Cast.t.sol
```

### Deploy

```bash
# Deploy to RISE L2 (example)
forge script script/DeployAll.s.sol --rpc-url $RISE_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

## 🔧 Contract Interface

### Key Functions

#### `limitBuy(uint256 marketId, uint256 price, uint256 size, Outcome outcome)`
Place a limit buy order for prediction shares.

**Parameters:**
- `marketId`: The ID of the prediction market
- `price`: Price per share (in basis points, 0-999)
- `size`: Number of shares to buy
- `outcome`: Either `Yes` (0) or `No` (1)

#### `marketBuy(uint256 marketId, uint256 size, Outcome outcome)`
Execute a market buy order against existing liquidity.

**Parameters:**
- `marketId`: The ID of the prediction market
- `size`: Number of shares to buy
- `outcome`: Either `Yes` (0) or `No` (1)

**Returns:**
- `fulfilled`: Number of shares actually purchased

### Events

```solidity
event LimitOrderPlaced(
    address indexed maker,
    uint256 indexed marketId,
    uint256 price,
    uint256 size,
    Outcome outcome,
    Side side
);
```

## 📊 Market Economics

### Pricing Model
- Prices are expressed in basis points (0-999)
- Price of 500 = 50% probability
- Yes shares + No shares = 1000 basis points total
- If Yes price is 600, No price is 400

### Collateral Requirements
- **Bid Orders**: Collateral = `(size × price × collateralMultiplier) / 1000`
- **Market Orders**: Variable based on matched prices
- **Settlement**: Winners receive full collateral, losers get nothing

## 🔐 Security

### Current Status
- ⏳ **Audit Planned**: Professional security audit scheduled
- 🧪 **Comprehensive Tests**: 23 test cases covering edge cases and fuzz testing
- 🔒 **Admin Controls**: Permissioned market creation and resolution
- 🛡️ **Battle-tested Libraries**: Uses Solady for gas-optimized, secure utilities

### Security Best Practices
- All external functions follow Checks-Effects-Interactions pattern
- Custom errors for gas-efficient reverts
- Comprehensive input validation
- Protected against reentrancy attacks

## 🏛️ Governance

Currently, 4cast.fun operates with a simple admin model:
- **Market Creation**: Permissioned by the 4cast team
- **Market Resolution**: Handled by the 4cast team
- **Future**: May transition to more decentralized governance

## 🗺️ Roadmap

- ✅ Core orderbook implementation
- ✅ Binary market support
- ✅ Comprehensive testing suite
- 🔄 Professional security audit
- 📱 Mobile app integration
- 🔮 Enhanced market types (future consideration)
- 🏛️ Decentralized governance (future consideration)

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

We welcome contributions! Please feel free to submit issues and enhancement requests.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📞 Contact

- **Email**: contact@4cast.fun
- **App**: Coming soon to 4cast.fun

## ⚠️ Disclaimer

4cast.fun is experimental software. Users should understand the risks involved in prediction markets and only participate with funds they can afford to lose. The platform is currently in development and has not yet undergone a formal security audit.

---

*Built with ❤️ for the future of decentralized prediction markets*
