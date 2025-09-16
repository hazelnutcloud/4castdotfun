// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Markets4Cast} from "../src/Markets4Cast.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract MockERC20 is ERC20 {
    function name() public pure override returns (string memory) {
        return "Test Token";
    }

    function symbol() public pure override returns (string memory) {
        return "TEST";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Markets4CastTest is Test {
    Markets4Cast public markets;
    MockERC20 public token;

    address public owner = address(0x999);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    uint256 public constant MARKET_ID = 0; // First market created
    uint256 public constant BPS = 1000;

    event LimitOrderPlaced(
        uint256 indexed marketId,
        address indexed maker,
        bytes32 orderId,
        uint256 price,
        uint256 size,
        Markets4Cast.Outcome outcome,
        Markets4Cast.Side side
    );

    event MarketOrderExecuted(
        address indexed taker,
        uint256 indexed marketId,
        uint256 totalFulfilled,
        Markets4Cast.Outcome outcome,
        Markets4Cast.Side side
    );

    event OrderFilled(uint256 indexed marketId, address indexed maker, bytes32 orderId, uint256 size, address taker);

    event PriceLevelCleared(uint256 indexed marketId, uint256 price, Markets4Cast.Outcome outcome);

    event SharesTransferred(
        address indexed from, address indexed to, uint256 indexed marketId, uint256 amount, Markets4Cast.Outcome outcome
    );

    event OrderCancelled(uint256 indexed marketId, address indexed maker, bytes32 orderId);

    event RewardsClaimed(address indexed user, uint256 indexed marketId, uint256 amount);

    event MarketCreated(uint256 indexed marketId);

    event MarketResolved(uint256 indexed marketId, Markets4Cast.Outcome outcome);

    function setUp() public virtual {
        token = new MockERC20();
        
        // Deploy contract with owner
        vm.prank(owner);
        markets = new Markets4Cast(address(token));

        // Setup test accounts with tokens
        token.mint(alice, 1000e18);
        token.mint(bob, 1000e18);
        token.mint(charlie, 1000e18);

        // Approve Markets4Cast to spend tokens
        vm.prank(alice);
        token.approve(address(markets), type(uint256).max);

        vm.prank(bob);
        token.approve(address(markets), type(uint256).max);

        vm.prank(charlie);
        token.approve(address(markets), type(uint256).max);

        // Create a market for testing
        vm.prank(owner);
        markets.createMarket();
    }

    function test_Constructor() public view {
        assertEq(markets.collateral(), address(token));
        assertEq(markets.BPS(), 1000);
    }

    function test_GetOrderId() public view {
        bytes32 orderId = markets.getOrderId(MARKET_ID, 500, 0);
        assertNotEq(orderId, bytes32(0));

        // Same parameters should produce same ID
        bytes32 orderId2 = markets.getOrderId(MARKET_ID, 500, 0);
        assertEq(orderId, orderId2);

        // Different parameters should produce different IDs
        bytes32 orderId3 = markets.getOrderId(MARKET_ID, 501, 0);
        assertNotEq(orderId, orderId3);
    }
}

contract LimitBuyTest is Markets4CastTest {
    function test_LimitBuy_Yes_Basic() public {
        uint256 price = 600;
        uint256 size = 100;
        uint256 expectedCollateral = (size * price * 1e18) / BPS;

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 contractBalanceBefore = token.balanceOf(address(markets));

        vm.expectEmit(true, true, false, true);
        emit LimitOrderPlaced(
            MARKET_ID,
            alice,
            markets.getOrderId(MARKET_ID, price, 0),
            price,
            size,
            Markets4Cast.Outcome.Yes,
            Markets4Cast.Side.Bid
        );

        vm.prank(alice);
        bytes32 orderId = markets.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.Yes);

        assertEq(orderId, markets.getOrderId(MARKET_ID, price, 0));
        assertEq(token.balanceOf(alice), aliceBalanceBefore - expectedCollateral);
        assertEq(token.balanceOf(address(markets)), contractBalanceBefore + expectedCollateral);
    }

    function test_LimitBuy_No_Basic() public {
        uint256 price = 400;
        uint256 size = 50;
        uint256 expectedCollateral = (size * price * 1e18) / BPS;

        vm.prank(bob);
        bytes32 orderId = markets.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.No);

        assertEq(orderId, markets.getOrderId(MARKET_ID, price, 0));
        assertEq(token.balanceOf(bob), 1000e18 - expectedCollateral);
    }

    function test_LimitBuy_RevertInvalidPrice() public {
        vm.prank(alice);
        vm.expectRevert(Markets4Cast.InvalidPrice.selector);
        markets.limitBuy(MARKET_ID, 0, 100, Markets4Cast.Outcome.Yes);

        vm.prank(alice);
        vm.expectRevert(Markets4Cast.PriceTooHigh.selector);
        markets.limitBuy(MARKET_ID, BPS, 100, Markets4Cast.Outcome.Yes);

        vm.prank(alice);
        vm.expectRevert(Markets4Cast.PriceTooHigh.selector);
        markets.limitBuy(MARKET_ID, BPS + 1, 100, Markets4Cast.Outcome.Yes);
    }

    function test_LimitBuy_RevertInvalidSize() public {
        vm.prank(alice);
        vm.expectRevert(Markets4Cast.InvalidSize.selector);
        markets.limitBuy(MARKET_ID, 500, 0, Markets4Cast.Outcome.Yes);
    }

    function test_LimitBuy_MultipleOrdersSamePrice() public {
        uint256 price = 500;

        vm.prank(alice);
        bytes32 orderId1 = markets.limitBuy(MARKET_ID, price, 100, Markets4Cast.Outcome.Yes);

        vm.prank(bob);
        bytes32 orderId2 = markets.limitBuy(MARKET_ID, price, 200, Markets4Cast.Outcome.Yes);

        assertNotEq(orderId1, orderId2);
        assertEq(orderId1, markets.getOrderId(MARKET_ID, price, 0));
        assertEq(orderId2, markets.getOrderId(MARKET_ID, price, 1));
    }

    function test_LimitBuy_DifferentPrices() public {
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 300, 100, Markets4Cast.Outcome.Yes);

        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 700, 150, Markets4Cast.Outcome.Yes);

        // Both orders should succeed
        assertEq(token.balanceOf(alice), 1000e18 - ((100 * 300 * 1e18) / BPS) - ((150 * 700 * 1e18) / BPS));
    }
}

contract LimitSellTest is Markets4CastTest {
    function setUp() public override {
        super.setUp();

        // Give alice some Yes shares through a limit buy
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 600, 200, Markets4Cast.Outcome.Yes);

        // Give alice some shares by minting (simulate a completed buy)
        vm.deal(address(markets), 1000e18);
        // We'll need to use a market buy to actually get shares, but for now let's create a helper
    }

    function giveShares(address user, uint256 amount, Markets4Cast.Outcome outcome) internal {
        // This is a helper to simulate having shares - in real scenarios they come from completed trades
        // For testing purposes, we'll use market orders to create shares
        vm.prank(user);
        markets.limitBuy(MARKET_ID, 600, amount, outcome);

        // Create opposite order to mint shares
        address counterparty = user == alice ? bob : alice;
        Markets4Cast.Outcome counterOutcome =
            outcome == Markets4Cast.Outcome.Yes ? Markets4Cast.Outcome.No : Markets4Cast.Outcome.Yes;

        vm.prank(counterparty);
        markets.marketBuy(MARKET_ID, amount, counterOutcome);
    }

    function test_LimitSell_RequiresShares() public {
        vm.prank(charlie); // charlie has no shares
        vm.expectRevert(Markets4Cast.InsufficientShares.selector);
        markets.limitSell(MARKET_ID, 500, 100, Markets4Cast.Outcome.Yes);
    }

    function test_LimitSell_RevertInvalidPrice() public {
        giveShares(alice, 100, Markets4Cast.Outcome.Yes);

        vm.prank(alice);
        vm.expectRevert(Markets4Cast.InvalidPrice.selector);
        markets.limitSell(MARKET_ID, 0, 50, Markets4Cast.Outcome.Yes);

        vm.prank(alice);
        vm.expectRevert(Markets4Cast.PriceTooHigh.selector);
        markets.limitSell(MARKET_ID, BPS, 50, Markets4Cast.Outcome.Yes);
    }

    function test_LimitSell_RevertInvalidSize() public {
        giveShares(alice, 100, Markets4Cast.Outcome.Yes);

        vm.prank(alice);
        vm.expectRevert(Markets4Cast.InvalidSize.selector);
        markets.limitSell(MARKET_ID, 500, 0, Markets4Cast.Outcome.Yes);
    }
}

contract MarketBuyTest is Markets4CastTest {
    function test_MarketBuy_ShareMinting_YesVsNoBid() public {
        // Bob places a No bid at 400 (expecting No at 40%)
        vm.prank(bob);
        markets.limitBuy(MARKET_ID, 400, 100, Markets4Cast.Outcome.No);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, false, true);
        emit MarketOrderExecuted(alice, MARKET_ID, 100, Markets4Cast.Outcome.Yes, Markets4Cast.Side.Bid);

        // Alice market buys Yes - should match against Bob's No bid
        vm.prank(alice);
        uint256 fulfilled = markets.marketBuy(MARKET_ID, 100, Markets4Cast.Outcome.Yes);

        assertEq(fulfilled, 100);

        // Alice should pay (BPS - marketPrice) = (1000 - 400) = 600 basis points = 60%
        uint256 expectedAliceCollateral = (100 * 600 * 1e18) / BPS;
        assertEq(token.balanceOf(alice), aliceBalanceBefore - expectedAliceCollateral);
    }

    function test_MarketBuy_ShareMinting_NoVsYesBid() public {
        // Alice places a Yes bid at 700
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 700, 150, Markets4Cast.Outcome.Yes);

        uint256 bobBalanceBefore = token.balanceOf(bob);

        // Bob market buys No - should match against Alice's Yes bid
        vm.prank(bob);
        uint256 fulfilled = markets.marketBuy(MARKET_ID, 150, Markets4Cast.Outcome.No);

        assertEq(fulfilled, 150);

        // Bob should pay (BPS - marketPrice) = (1000 - 700) = 300 basis points = 30%
        uint256 expectedBobCollateral = (150 * 300 * 1e18) / BPS;
        assertEq(token.balanceOf(bob), bobBalanceBefore - expectedBobCollateral);
    }

    function test_MarketBuy_PartialFill() public {
        // Bob places a No bid for 50 shares at 400
        vm.prank(bob);
        markets.limitBuy(MARKET_ID, 400, 50, Markets4Cast.Outcome.No);

        // Alice tries to buy 100 Yes shares but only 50 available
        vm.prank(alice);
        uint256 fulfilled = markets.marketBuy(MARKET_ID, 100, Markets4Cast.Outcome.Yes);

        assertEq(fulfilled, 50);
    }

    function test_MarketBuy_MultipleOrders() public {
        // Multiple No bids at different prices
        vm.prank(bob);
        markets.limitBuy(MARKET_ID, 500, 30, Markets4Cast.Outcome.No);

        vm.prank(charlie);
        markets.limitBuy(MARKET_ID, 400, 50, Markets4Cast.Outcome.No);

        vm.prank(bob);
        markets.limitBuy(MARKET_ID, 600, 20, Markets4Cast.Outcome.No);

        // Alice market buys 100 Yes shares - should match highest prices first
        vm.prank(alice);
        uint256 fulfilled = markets.marketBuy(MARKET_ID, 100, Markets4Cast.Outcome.Yes);

        assertEq(fulfilled, 100); // 20 + 30 + 50 = 100
    }

    function test_MarketBuy_RevertInvalidSize() public {
        vm.prank(alice);
        vm.expectRevert(Markets4Cast.InvalidSize.selector);
        markets.marketBuy(MARKET_ID, 0, Markets4Cast.Outcome.Yes);
    }

    function test_MarketBuy_NoLiquidity() public {
        // No existing orders
        vm.prank(alice);
        uint256 fulfilled = markets.marketBuy(MARKET_ID, 100, Markets4Cast.Outcome.Yes);

        assertEq(fulfilled, 0);
    }
}

contract MarketSellTest is Markets4CastTest {
    function setUp() public override {
        super.setUp();

        // Setup: Create shares through cross-outcome matching
        // Alice places Yes bid
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 600, 200, Markets4Cast.Outcome.Yes);

        // Bob market buys No, which matches Alice's Yes bid, giving both shares
        vm.prank(bob);
        markets.marketBuy(MARKET_ID, 200, Markets4Cast.Outcome.No);

        // Now Alice has 200 Yes shares, Bob has 200 No shares
    }

    function test_MarketSell_Basic() public {
        // Charlie places a Yes bid
        vm.prank(charlie);
        markets.limitBuy(MARKET_ID, 700, 100, Markets4Cast.Outcome.Yes);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        // Alice sells 100 Yes shares to Charlie
        vm.prank(alice);
        uint256 fulfilled = markets.marketSell(MARKET_ID, 100, Markets4Cast.Outcome.Yes);

        assertEq(fulfilled, 100);

        // Alice should receive 700 basis points = 70% of collateral
        uint256 expectedCollateral = (100 * 700 * 1e18) / BPS;
        assertEq(token.balanceOf(alice), aliceBalanceBefore + expectedCollateral);
    }

    function test_MarketSell_InsufficientShares() public {
        vm.prank(charlie); // charlie has no shares
        vm.expectRevert(Markets4Cast.InsufficientShares.selector);
        markets.marketSell(MARKET_ID, 100, Markets4Cast.Outcome.Yes);
    }

    function test_MarketSell_RevertInvalidSize() public {
        vm.prank(alice);
        vm.expectRevert(Markets4Cast.InvalidSize.selector);
        markets.marketSell(MARKET_ID, 0, Markets4Cast.Outcome.Yes);
    }

    function test_MarketSell_NoMatchingBids() public {
        // No Yes bids available
        vm.prank(alice);
        uint256 fulfilled = markets.marketSell(MARKET_ID, 100, Markets4Cast.Outcome.Yes);

        assertEq(fulfilled, 0);
    }

    function test_MarketSell_IgnoresAskOrders() public {
        // First, Charlie needs to get some Yes shares
        vm.prank(charlie);
        markets.limitBuy(MARKET_ID, 500, 100, Markets4Cast.Outcome.Yes);

        vm.prank(bob);
        markets.marketBuy(MARKET_ID, 100, Markets4Cast.Outcome.No); // This gives Charlie 100 Yes shares

        // Now Alice places a Yes ask order (limit sell)
        vm.prank(alice);
        markets.limitSell(MARKET_ID, 600, 50, Markets4Cast.Outcome.Yes); // Alice places ask

        // Charlie tries to market sell Yes - should not match Alice's ask
        vm.prank(charlie);
        uint256 fulfilled = markets.marketSell(MARKET_ID, 50, Markets4Cast.Outcome.Yes);

        assertEq(fulfilled, 0); // No bids available, asks are ignored
    }
}

contract FuzzTest is Markets4CastTest {
    function testFuzz_LimitBuy(uint256 price, uint256 size) public {
        price = bound(price, 1, BPS - 1);
        size = bound(size, 1, 1000);

        uint256 expectedCollateral = (size * price * 1e18) / BPS;
        vm.assume(expectedCollateral <= 1000e18); // Alice has 1000 tokens

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        markets.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.Yes);

        assertEq(token.balanceOf(alice), balanceBefore - expectedCollateral);
    }

    function testFuzz_MarketBuyShareMinting(uint256 bidPrice, uint256 bidSize, uint256 buySize) public {
        bidPrice = bound(bidPrice, 1, BPS - 1);
        bidSize = bound(bidSize, 1, 1000);
        buySize = bound(buySize, 1, bidSize); // Can't buy more than available

        uint256 bidCollateral = (bidSize * bidPrice * 1e18) / BPS;
        uint256 buyCollateral = (buySize * (BPS - bidPrice) * 1e18) / BPS;

        vm.assume(bidCollateral <= 1000e18);
        vm.assume(buyCollateral <= 1000e18);

        // Bob places No bid
        vm.prank(bob);
        markets.limitBuy(MARKET_ID, bidPrice, bidSize, Markets4Cast.Outcome.No);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        // Alice market buys Yes
        vm.prank(alice);
        uint256 fulfilled = markets.marketBuy(MARKET_ID, buySize, Markets4Cast.Outcome.Yes);

        assertEq(fulfilled, buySize);
        assertEq(token.balanceOf(alice), aliceBalanceBefore - buyCollateral);
    }
}

contract EdgeCaseTest is Markets4CastTest {
    function test_PriceLevelClearing() public {
        uint256 price = 500;
        uint256 size = 100;

        // Bob places No bid
        vm.prank(bob);
        markets.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.No);

        vm.expectEmit(true, false, false, true);
        emit PriceLevelCleared(MARKET_ID, price, Markets4Cast.Outcome.No);

        // Alice completely fills the price level
        vm.prank(alice);
        markets.marketBuy(MARKET_ID, size, Markets4Cast.Outcome.Yes);
    }

    function test_FIFOOrderProcessing() public {
        uint256 price = 600;

        // Create a scenario where we can test FIFO order processing
        // First, let's give someone shares to sell
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 500, 100, Markets4Cast.Outcome.Yes);

        vm.prank(bob);
        markets.marketBuy(MARKET_ID, 100, Markets4Cast.Outcome.No); // Alice gets Yes shares

        // Now create multiple buy orders at the same price that Alice can sell into
        vm.prank(bob);
        markets.limitBuy(MARKET_ID, price, 50, Markets4Cast.Outcome.Yes);

        vm.prank(charlie);
        markets.limitBuy(MARKET_ID, price, 30, Markets4Cast.Outcome.Yes);

        // Alice sells 40 shares - should fill Bob's order first (FIFO)
        vm.prank(alice);
        uint256 fulfilled = markets.marketSell(MARKET_ID, 40, Markets4Cast.Outcome.Yes);

        assertEq(fulfilled, 40);
    }

    function test_MaxPriceBounds() public {
        // Test at price boundaries
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 1, 100, Markets4Cast.Outcome.Yes);

        vm.prank(alice);
        markets.limitBuy(MARKET_ID, BPS - 1, 100, Markets4Cast.Outcome.Yes);

        // Both should succeed
        uint256 expectedCollateral = (100 * 1 * 1e18) / BPS + (100 * (BPS - 1) * 1e18) / BPS;
        assertEq(token.balanceOf(alice), 1000e18 - expectedCollateral);
    }
}

contract IntegrationTest is Markets4CastTest {
    function test_ComplexTradingScenario() public {
        // Scenario: Multiple participants, mixed order types

        // 1. Alice places Yes bid at 600 for 100 shares
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 600, 100, Markets4Cast.Outcome.Yes);

        // 2. Bob places No bid at 300 for 150 shares
        vm.prank(bob);
        markets.limitBuy(MARKET_ID, 300, 150, Markets4Cast.Outcome.No);

        // 3. Charlie market buys 100 Yes (matches Bob's No bid)
        vm.prank(charlie);
        uint256 fulfilled1 = markets.marketBuy(MARKET_ID, 100, Markets4Cast.Outcome.Yes);
        assertEq(fulfilled1, 100);

        // 4. Now Bob has 100 No shares from the match, Alice still has her bid
        // Charlie market buys 50 No (matches Alice's Yes bid)
        vm.prank(charlie);
        uint256 fulfilled2 = markets.marketBuy(MARKET_ID, 50, Markets4Cast.Outcome.No);
        assertEq(fulfilled2, 50);

        // 5. Now Charlie has both Yes and No shares, let's have him sell some Yes shares
        vm.prank(bob); // Bob places a new Yes bid
        markets.limitBuy(MARKET_ID, 700, 50, Markets4Cast.Outcome.Yes);

        vm.prank(charlie);
        uint256 fulfilled3 = markets.marketSell(MARKET_ID, 50, Markets4Cast.Outcome.Yes);
        assertEq(fulfilled3, 50);
    }

    function test_PriceInversionMechanics() public {
        // Test that Yes buy at price P matches No bid at price P
        uint256 price = 400;
        uint256 size = 100;

        // Bob places No bid at 400 (40% probability No)
        vm.prank(bob);
        markets.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.No);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        // Alice market buys Yes - inverted price should be (1000 - 400) = 600
        vm.prank(alice);
        uint256 fulfilled = markets.marketBuy(MARKET_ID, size, Markets4Cast.Outcome.Yes);

        assertEq(fulfilled, size);

        // Alice pays (BPS - price) = 600 basis points
        uint256 expectedCost = (size * 600 * 1e18) / BPS;
        assertEq(token.balanceOf(alice), aliceBalanceBefore - expectedCost);
    }
}

contract CreateMarketTest is Markets4CastTest {
    function test_CreateMarket_OnlyOwner() public {
        vm.expectEmit(true, false, false, false);
        emit MarketCreated(1);
        
        vm.prank(owner);
        markets.createMarket();
    }
    
    function test_CreateMarket_RevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        markets.createMarket();
    }
    
    function test_CreateMarket_IncrementsId() public {
        vm.prank(owner);
        markets.createMarket(); // Should create market ID 1
        
        vm.expectEmit(true, false, false, false);
        emit MarketCreated(2);
        
        vm.prank(owner);
        markets.createMarket(); // Should create market ID 2
    }
}

contract ResolveMarketTest is Markets4CastTest {
    function test_ResolveMarket_Yes() public {
        vm.expectEmit(true, false, false, true);
        emit MarketResolved(MARKET_ID, Markets4Cast.Outcome.Yes);
        
        vm.prank(owner);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.Yes);
    }
    
    function test_ResolveMarket_No() public {
        vm.expectEmit(true, false, false, true);
        emit MarketResolved(MARKET_ID, Markets4Cast.Outcome.No);
        
        vm.prank(owner);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.No);
    }
    
    function test_ResolveMarket_RevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.Yes);
    }
    
    function test_ResolveMarket_RevertAlreadyResolved() public {
        vm.prank(owner);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.Yes);
        
        vm.prank(owner);
        vm.expectRevert(Markets4Cast.MarketAlreadyResolved.selector);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.No);
    }
    
    function test_ResolveMarket_RevertNonexistentMarket() public {
        // Try to resolve a market that was never created (ID 999)
        vm.prank(owner);
        vm.expectRevert(Markets4Cast.MarketNotActive.selector);
        markets.resolveMarket(999, Markets4Cast.Outcome.Yes);
    }
}

contract CancelOrderTest is Markets4CastTest {
    function test_CancelOrder_BidOrder() public {
        uint256 price = 600;
        uint256 size = 100;
        uint256 orderIndex = 0;
        
        // Alice places a limit buy order
        vm.prank(alice);
        bytes32 orderId = markets.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.Yes);
        
        uint256 aliceBalanceBefore = token.balanceOf(alice);
        
        vm.expectEmit(true, true, false, true);
        emit OrderCancelled(MARKET_ID, alice, orderId);
        
        // Alice cancels her order
        vm.prank(alice);
        markets.cancelOrder(MARKET_ID, price, orderIndex, Markets4Cast.Side.Bid, Markets4Cast.Outcome.Yes);
        
        // Alice should get her collateral back
        uint256 expectedRefund = (size * price * 1e18) / BPS;
        assertEq(token.balanceOf(alice), aliceBalanceBefore + expectedRefund);
    }
    
    function test_CancelOrder_AskOrder() public {
        uint256 price = 600;
        uint256 size = 100;
        uint256 orderIndex = 0;
        
        // First give Alice shares
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 500, 200, Markets4Cast.Outcome.Yes);
        
        vm.prank(bob);
        markets.marketBuy(MARKET_ID, 200, Markets4Cast.Outcome.No); // Alice gets shares
        
        // Alice places a limit sell order
        vm.prank(alice);
        bytes32 orderId = markets.limitSell(MARKET_ID, price, size, Markets4Cast.Outcome.Yes);
        
        vm.expectEmit(true, true, false, true);
        emit OrderCancelled(MARKET_ID, alice, orderId);
        
        // Alice cancels her sell order - should get shares back
        vm.prank(alice);
        markets.cancelOrder(MARKET_ID, price, orderIndex, Markets4Cast.Side.Ask, Markets4Cast.Outcome.Yes);
    }
    
    function test_CancelOrder_RevertUnauthorized() public {
        uint256 price = 600;
        uint256 size = 100;
        uint256 orderIndex = 0;
        
        // Alice places a limit buy order
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.Yes);
        
        // Bob tries to cancel Alice's order
        vm.prank(bob);
        vm.expectRevert(Ownable.Unauthorized.selector);
        markets.cancelOrder(MARKET_ID, price, orderIndex, Markets4Cast.Side.Bid, Markets4Cast.Outcome.Yes);
    }
    
    function test_CancelOrder_RevertMarketResolved() public {
        uint256 price = 600;
        uint256 size = 100;
        uint256 orderIndex = 0;
        
        // Alice places a limit buy order
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.Yes);
        
        // Resolve the market
        vm.prank(owner);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.Yes);
        
        // Alice tries to cancel order after resolution
        vm.prank(alice);
        vm.expectRevert(Markets4Cast.MarketAlreadyResolved.selector);
        markets.cancelOrder(MARKET_ID, price, orderIndex, Markets4Cast.Side.Bid, Markets4Cast.Outcome.Yes);
    }
}

contract ClaimTest is Markets4CastTest {
    function test_Claim_WinningShares() public {
        uint256 size = 100;
        
        // Setup: Alice gets Yes shares through trading
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 600, size, Markets4Cast.Outcome.Yes);
        
        vm.prank(bob);
        markets.marketBuy(MARKET_ID, size, Markets4Cast.Outcome.No); // Alice gets Yes shares
        
        // Resolve market with Yes outcome
        vm.prank(owner);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.Yes);
        
        uint256 aliceBalanceBefore = token.balanceOf(alice);
        
        vm.expectEmit(true, true, false, true);
        emit RewardsClaimed(alice, MARKET_ID, size);
        
        // Alice claims her winnings
        vm.prank(alice);
        markets.claim(MARKET_ID);
        
        // Alice should receive full collateral value
        uint256 expectedPayout = size * 1e18;
        assertEq(token.balanceOf(alice), aliceBalanceBefore + expectedPayout);
    }
    
    function test_Claim_LosingShares() public {
        uint256 size = 100;
        
        // Setup: Alice gets Yes shares, Bob gets No shares
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 600, size, Markets4Cast.Outcome.Yes);
        
        vm.prank(bob);
        markets.marketBuy(MARKET_ID, size, Markets4Cast.Outcome.No);
        
        // Resolve market with No outcome (Alice loses)
        vm.prank(owner);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.No);
        
        // Alice tries to claim - should revert
        vm.prank(alice);
        vm.expectRevert(Markets4Cast.InsufficientShares.selector);
        markets.claim(MARKET_ID);
        
        // Bob should be able to claim
        uint256 bobBalanceBefore = token.balanceOf(bob);
        
        vm.prank(bob);
        markets.claim(MARKET_ID);
        
        uint256 expectedPayout = size * 1e18;
        assertEq(token.balanceOf(bob), bobBalanceBefore + expectedPayout);
    }
    
    function test_Claim_RevertMarketNotResolved() public {
        // Alice has shares but market not resolved
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 600, 100, Markets4Cast.Outcome.Yes);
        
        vm.prank(alice);
        vm.expectRevert(Markets4Cast.MarketNotResolved.selector);
        markets.claim(MARKET_ID);
    }
    
    function test_Claim_RevertNoShares() public {
        // Resolve market
        vm.prank(owner);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.Yes);
        
        // Charlie has no shares
        vm.prank(charlie);
        vm.expectRevert(Markets4Cast.InsufficientShares.selector);
        markets.claim(MARKET_ID);
    }
    
    function test_Claim_OnlyOnce() public {
        uint256 size = 100;
        
        // Setup and resolve market
        vm.prank(alice);
        markets.limitBuy(MARKET_ID, 600, size, Markets4Cast.Outcome.Yes);
        
        vm.prank(bob);
        markets.marketBuy(MARKET_ID, size, Markets4Cast.Outcome.No);
        
        vm.prank(owner);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.Yes);
        
        // Alice claims once
        vm.prank(alice);
        markets.claim(MARKET_ID);
        
        // Alice tries to claim again
        vm.prank(alice);
        vm.expectRevert(Markets4Cast.InsufficientShares.selector);
        markets.claim(MARKET_ID);
    }
}

contract MarketLifecycleTest is Markets4CastTest {
    function test_FullMarketLifecycle() public {
        // 1. Create market
        vm.prank(owner);
        markets.createMarket();
        uint256 marketId = 1;
        
        // 2. Trading phase
        vm.prank(alice);
        markets.limitBuy(marketId, 600, 100, Markets4Cast.Outcome.Yes);
        
        vm.prank(bob);
        markets.limitBuy(marketId, 400, 150, Markets4Cast.Outcome.No);
        
        vm.prank(charlie);
        markets.marketBuy(marketId, 100, Markets4Cast.Outcome.Yes); // Matches Bob's No bid
        
        // 3. Resolve market
        vm.prank(owner);
        markets.resolveMarket(marketId, Markets4Cast.Outcome.Yes);
        
        // 4. Claims
        uint256 charlieBalanceBefore = token.balanceOf(charlie);
        
        vm.prank(charlie);
        markets.claim(marketId);
        
        // Charlie should receive full payout for his Yes shares
        assertEq(token.balanceOf(charlie), charlieBalanceBefore + 100 * 1e18);
        
        // Bob should not be able to claim (he has No shares but outcome was Yes)
        vm.prank(bob);
        vm.expectRevert(Markets4Cast.InsufficientShares.selector);
        markets.claim(marketId);
    }
    
    function test_NoTradingAfterResolution() public {
        // Resolve market
        vm.prank(owner);
        markets.resolveMarket(MARKET_ID, Markets4Cast.Outcome.Yes);
        
        // Try to trade after resolution
        vm.prank(alice);
        vm.expectRevert(Markets4Cast.MarketAlreadyResolved.selector);
        markets.limitBuy(MARKET_ID, 600, 100, Markets4Cast.Outcome.Yes);
        
        vm.prank(alice);
        vm.expectRevert(Markets4Cast.MarketAlreadyResolved.selector);
        markets.marketBuy(MARKET_ID, 100, Markets4Cast.Outcome.Yes);
    }
}
