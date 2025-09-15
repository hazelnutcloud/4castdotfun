// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Markets4Cast} from "../src/Markets4Cast.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

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
    Markets4Cast public market;
    MockERC20 public token;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 public constant MARKET_ID = 1;
    uint256 public constant INITIAL_BALANCE = 1000e18;

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
        Markets4Cast.Outcome outcome
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
        Markets4Cast.Outcome outcome
    );

    event SharesTransferred(
        address indexed from,
        address indexed to,
        uint256 indexed marketId,
        uint256 amount,
        Markets4Cast.Outcome outcome
    );

    error InvalidPrice();
    error PriceTooHigh();
    error InvalidSize();
    error MarketIsResolved();

    function getOrderId(
        uint256 marketId,
        uint256 price,
        uint256 orderIndex
    ) internal pure returns (bytes32) {
        return EfficientHashLib.hash(marketId, price, orderIndex);
    }

    function setUp() public {
        token = new MockERC20();
        market = new Markets4Cast(address(token));

        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        token.mint(charlie, INITIAL_BALANCE);

        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(market), type(uint256).max);
    }

    function test_Constructor() public view {
        assertEq(market.collateral(), address(token));
        assertEq(market.BPS(), 1000);
    }

    function test_LimitBuy_Success() public {
        uint256 price = 500;
        uint256 size = 100;

        vm.expectEmit(true, true, false, true);
        emit LimitOrderPlaced(
            MARKET_ID,
            alice,
            getOrderId(MARKET_ID, price, 0),
            price,
            size,
            Markets4Cast.Outcome.Yes,
            Markets4Cast.Side.Bid
        );

        vm.prank(alice);
        market.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.Yes);
    }

    function test_LimitBuy_InvalidPrice_Zero() public {
        vm.prank(alice);
        vm.expectRevert("Invalid price");
        market.limitBuy(MARKET_ID, 0, 100, Markets4Cast.Outcome.Yes);
    }

    function test_LimitBuy_PriceTooHigh() public {
        vm.prank(alice);
        vm.expectRevert("Price too high");
        market.limitBuy(MARKET_ID, 1000, 100, Markets4Cast.Outcome.Yes);
    }

    function test_LimitBuy_InvalidSize() public {
        vm.prank(alice);
        vm.expectRevert("Invalid size");
        market.limitBuy(MARKET_ID, 500, 0, Markets4Cast.Outcome.Yes);
    }

    function test_LimitBuy_YesOutcome() public {
        uint256 price = 600;
        uint256 size = 200;

        vm.prank(alice);
        market.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.Yes);

        vm.prank(bob);
        market.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.Yes);
    }

    function test_LimitBuy_NoOutcome() public {
        uint256 price = 400;
        uint256 size = 150;

        vm.prank(alice);
        market.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.No);
    }

    function test_LimitBuy_MultipleOrders_SamePrice() public {
        uint256 price = 500;
        uint256 size1 = 100;
        uint256 size2 = 200;

        vm.prank(alice);
        market.limitBuy(MARKET_ID, price, size1, Markets4Cast.Outcome.Yes);

        vm.prank(bob);
        market.limitBuy(MARKET_ID, price, size2, Markets4Cast.Outcome.Yes);
    }

    function test_LimitBuy_DifferentPrices() public {
        vm.prank(alice);
        market.limitBuy(MARKET_ID, 300, 100, Markets4Cast.Outcome.Yes);

        vm.prank(bob);
        market.limitBuy(MARKET_ID, 600, 150, Markets4Cast.Outcome.Yes);

        vm.prank(charlie);
        market.limitBuy(MARKET_ID, 450, 200, Markets4Cast.Outcome.No);
    }

    function test_MarketBuy_InvalidSize() public {
        vm.prank(alice);
        vm.expectRevert("Invalid size");
        market.marketBuy(MARKET_ID, 0, Markets4Cast.Outcome.Yes);
    }

    function test_MarketBuy_NoCounterOrders() public {
        vm.prank(alice);
        uint256 fulfilled = market.marketBuy(
            MARKET_ID,
            100,
            Markets4Cast.Outcome.Yes
        );

        assertEq(fulfilled, 0);
    }

    function test_MarketBuy_PartialFill() public {
        vm.prank(alice);
        market.limitBuy(MARKET_ID, 400, 50, Markets4Cast.Outcome.No);

        vm.expectEmit(true, true, false, true);
        emit OrderFilled(MARKET_ID, alice, getOrderId(MARKET_ID, 400, 0), 50, bob);
        
        vm.expectEmit(true, true, false, true);
        emit MarketOrderExecuted(bob, MARKET_ID, 50, Markets4Cast.Outcome.Yes);

        vm.prank(bob);
        uint256 fulfilled = market.marketBuy(
            MARKET_ID,
            100,
            Markets4Cast.Outcome.Yes
        );

        assertEq(fulfilled, 50);
    }

    function test_MarketBuy_ExactFill() public {
        uint256 price = 400;
        uint256 size = 100;

        vm.prank(alice);
        market.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.No);

        vm.expectEmit(true, true, false, true);
        emit PriceLevelCleared(MARKET_ID, price, Markets4Cast.Outcome.No);
        
        vm.expectEmit(true, true, false, true);
        emit OrderFilled(MARKET_ID, alice, getOrderId(MARKET_ID, price, 0), size, bob);
        
        vm.expectEmit(true, true, false, true);
        emit MarketOrderExecuted(bob, MARKET_ID, size, Markets4Cast.Outcome.Yes);

        vm.prank(bob);
        uint256 fulfilled = market.marketBuy(
            MARKET_ID,
            size,
            Markets4Cast.Outcome.Yes
        );

        assertEq(fulfilled, size);
    }

    function test_MarketBuy_MultiplePriceLevels() public {
        vm.prank(alice);
        market.limitBuy(MARKET_ID, 300, 50, Markets4Cast.Outcome.No);

        vm.prank(bob);
        market.limitBuy(MARKET_ID, 600, 100, Markets4Cast.Outcome.No);

        vm.prank(charlie);
        market.limitBuy(MARKET_ID, 450, 75, Markets4Cast.Outcome.No);

        vm.prank(alice);
        uint256 fulfilled = market.marketBuy(
            MARKET_ID,
            200,
            Markets4Cast.Outcome.Yes
        );

        assertEq(fulfilled, 200);
    }

    function test_MarketBuy_BidCounterOrder_TransfersCollateral() public {
        uint256 price = 400;
        uint256 size = 100;
        uint256 expectedAliceCost = (size * price * 1e18) / 1000;
        uint256 expectedBobCost = (size * (1000 - price) * 1e18) / 1000;

        vm.prank(alice);
        market.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.No);

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 bobBalanceBefore = token.balanceOf(bob);
        uint256 contractBalanceBefore = token.balanceOf(address(market));

        vm.prank(bob);
        uint256 fulfilled = market.marketBuy(
            MARKET_ID,
            size,
            Markets4Cast.Outcome.Yes
        );

        assertEq(fulfilled, size);
        assertEq(
            token.balanceOf(alice),
            aliceBalanceBefore - expectedAliceCost
        );
        assertEq(token.balanceOf(bob), bobBalanceBefore - expectedBobCost);
        assertEq(
            token.balanceOf(address(market)),
            contractBalanceBefore + expectedAliceCost + expectedBobCost
        );
    }

    function test_MarketBuy_MultipleOrdersSamePrice() public {
        uint256 price = 500;
        uint256 size1 = 60;
        uint256 size2 = 40;
        uint256 totalSize = size1 + size2;

        vm.prank(alice);
        market.limitBuy(MARKET_ID, price, size1, Markets4Cast.Outcome.No);

        vm.prank(bob);
        market.limitBuy(MARKET_ID, price, size2, Markets4Cast.Outcome.No);

        vm.prank(charlie);
        uint256 fulfilled = market.marketBuy(
            MARKET_ID,
            totalSize,
            Markets4Cast.Outcome.Yes
        );

        assertEq(fulfilled, totalSize);
    }

    function test_FuzzLimitBuy_ValidInputs(
        uint256 price,
        uint256 size,
        uint8 outcomeRaw
    ) public {
        price = bound(price, 1, 999);
        size = bound(size, 1, 1e6);
        Markets4Cast.Outcome outcome = outcomeRaw % 2 == 0
            ? Markets4Cast.Outcome.Yes
            : Markets4Cast.Outcome.No;

        vm.prank(alice);
        market.limitBuy(MARKET_ID, price, size, outcome);
    }

    function test_FuzzMarketBuy_ValidInputs(
        uint256 size,
        uint8 outcomeRaw
    ) public {
        size = bound(size, 1, 1e6);
        Markets4Cast.Outcome outcome = outcomeRaw % 2 == 0
            ? Markets4Cast.Outcome.Yes
            : Markets4Cast.Outcome.No;

        vm.prank(alice);
        uint256 fulfilled = market.marketBuy(MARKET_ID, size, outcome);

        assertEq(fulfilled, 0);
    }

    function test_FuzzMarketBuy_WithCounterOrders(
        uint256 limitPrice,
        uint256 limitSize,
        uint256 marketSize,
        uint8 outcomeRaw
    ) public {
        limitPrice = bound(limitPrice, 1, 999);
        limitSize = bound(limitSize, 1, 1e6);
        marketSize = bound(marketSize, 1, 1e6);

        Markets4Cast.Outcome limitOutcome = outcomeRaw % 2 == 0
            ? Markets4Cast.Outcome.Yes
            : Markets4Cast.Outcome.No;
        Markets4Cast.Outcome marketOutcome = limitOutcome ==
            Markets4Cast.Outcome.Yes
            ? Markets4Cast.Outcome.No
            : Markets4Cast.Outcome.Yes;

        uint256 requiredCollateral = (limitSize * limitPrice * 1e18) / 1000;
        vm.assume(requiredCollateral <= INITIAL_BALANCE);

        uint256 marketRequiredCollateral = (marketSize *
            (1000 - limitPrice) *
            1e18) / 1000;
        vm.assume(marketRequiredCollateral <= INITIAL_BALANCE);

        vm.prank(alice);
        market.limitBuy(MARKET_ID, limitPrice, limitSize, limitOutcome);

        vm.prank(bob);
        uint256 fulfilled = market.marketBuy(
            MARKET_ID,
            marketSize,
            marketOutcome
        );

        uint256 expectedFulfilled = marketSize > limitSize
            ? limitSize
            : marketSize;
        assertEq(fulfilled, expectedFulfilled);
    }

    function test_EdgeCase_MaxPrice() public {
        vm.prank(alice);
        market.limitBuy(MARKET_ID, 999, 100, Markets4Cast.Outcome.Yes);
    }

    function test_EdgeCase_MinPrice() public {
        vm.prank(alice);
        market.limitBuy(MARKET_ID, 1, 100, Markets4Cast.Outcome.Yes);
    }

    function test_EdgeCase_LargeSize() public {
        uint256 largeSize = type(uint128).max;

        vm.prank(alice);
        market.limitBuy(MARKET_ID, 500, largeSize, Markets4Cast.Outcome.Yes);
    }

    function test_MarketBuy_EmitsSharesTransferredEvent() public {
        uint256 price = 500;
        uint256 size = 100;
        
        vm.prank(alice);
        market.limitBuy(MARKET_ID, price, size, Markets4Cast.Outcome.No);
        
        vm.expectEmit(true, true, true, true);
        emit SharesTransferred(address(0), alice, MARKET_ID, size, Markets4Cast.Outcome.No);
        
        vm.expectEmit(true, true, true, true);
        emit SharesTransferred(address(0), bob, MARKET_ID, size, Markets4Cast.Outcome.Yes);
        
        vm.prank(bob);
        market.marketBuy(MARKET_ID, size, Markets4Cast.Outcome.Yes);
    }

    function test_Integration_ComplexScenario() public {
        vm.prank(alice);
        market.limitBuy(MARKET_ID, 200, 100, Markets4Cast.Outcome.No);

        vm.prank(bob);
        market.limitBuy(MARKET_ID, 300, 150, Markets4Cast.Outcome.No);

        vm.prank(charlie);
        market.limitBuy(MARKET_ID, 250, 75, Markets4Cast.Outcome.No);

        vm.prank(alice);
        market.limitBuy(MARKET_ID, 600, 200, Markets4Cast.Outcome.Yes);

        vm.prank(bob);
        uint256 fulfilled1 = market.marketBuy(
            MARKET_ID,
            100,
            Markets4Cast.Outcome.Yes
        );

        vm.prank(charlie);
        uint256 fulfilled2 = market.marketBuy(
            MARKET_ID,
            50,
            Markets4Cast.Outcome.No
        );

        assertEq(fulfilled1, 100);
        assertEq(fulfilled2, 50);
    }
}
