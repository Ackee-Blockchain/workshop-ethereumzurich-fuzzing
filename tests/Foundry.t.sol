// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {AmountConverter} from "../contracts/AmountConverter.sol";
import {GPv2Order} from "../contracts/lib/GPv2Order.sol";
import {Market} from "./lib/Market.sol";
import {Order} from "../contracts/Order.sol";
import {Stonks} from "../contracts/Stonks.sol";

contract StonksTest is Test {
    // Decimals: 18
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    // Decimals: 18
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    // Decimals: 6
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    // Decimals: 6
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address[4] SELL_TOKENS = [STETH, DAI, USDT, USDC];
    address[3] BUY_TOKENS = [DAI, USDT, USDC];

    // Required in the constructor of Order
    address public constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    bytes32 public constant COW_SETTLEMENT_DOMAIN_SEPARATOR = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;

    // Required in the constructor of Stonks
    address public agent;
    AmountConverter public amountConverter;
    Market public market;
    mapping(address => mapping(address => Stonks)) stonks;

    uint256 public orderDuration;
    uint256 public marginBasisPoints;
    uint256 public priceToleranceBasisPoints;

    /**
     * @notice Deploy the contracts and set up the test environment
     */
    function setUp() public {
        agent = makeAddr("agent");
        address manager = makeAddr("manager");

        // Randomize the order duration, margin and price tolerance
        orderDuration = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % (60 * 60 * 24) + 60;
        marginBasisPoints = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % 1001; // 0% - 10%
        priceToleranceBasisPoints = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % 1001; // 0% - 10%

        amountConverter = new AmountConverter();
        address[] memory stables = new address[](3);
        stables[0] = DAI;
        stables[1] = USDT;
        stables[2] = USDC;
        market = new Market(amountConverter, STETH, stables);

        Order sampleOrder = new Order(agent, COW_VAULT_RELAYER, COW_SETTLEMENT_DOMAIN_SEPARATOR);
        
        for (uint256 i = 0; i < SELL_TOKENS.length; i++) {
            for (uint256 j = 0; j < BUY_TOKENS.length; j++) {
                if (SELL_TOKENS[i] == BUY_TOKENS[j]) {
                    continue;
                }
                stonks[SELL_TOKENS[i]][BUY_TOKENS[j]] = new Stonks(
                    agent,
                    manager,
                    SELL_TOKENS[i],
                    BUY_TOKENS[j],
                    address(amountConverter),
                    address(sampleOrder),
                    orderDuration,
                    marginBasisPoints,
                    priceToleranceBasisPoints
                );
            }
        }
    }

    /**
     * @notice Generic mint function for the tokens used in the tests
     * @param token The token to mint
     * @param to The address to mint to
     * @param amount The amount to mint
     * @dev The function is used to mint tokens to stablecoins and StETH
     *      used in the test. It directly modifies the storage of the
     *      tokens and changes the total supply and the balance of the
     *      target address.
     */
    function _mint(address token, address to, uint256 amount) internal {
        bytes32 totalSupplySlot;
        bytes32 balanceSlot;

        if (token == DAI) {
            totalSupplySlot = bytes32(uint256(1));
            balanceSlot = keccak256(abi.encode(to, 2));
        } else if (token == USDC) {
            totalSupplySlot = bytes32(uint256(11));
            balanceSlot = keccak256(abi.encode(to, 9));
        } else if (token == USDT) {
            totalSupplySlot = bytes32(uint256(1));
            balanceSlot = keccak256(abi.encode(to, 2));
        } else if (token == STETH) {
            totalSupplySlot = 0xe3b4b636e601189b5f4c6742edf2538ac12bb61ed03e6da26949d69838fa447e;
            balanceSlot = keccak256(abi.encode(to, 0));
        } else {
            revert("Unsupported token");
        }

        uint256 oldTotalSupply = uint256(vm.load(token, totalSupplySlot));
        uint256 oldBalance = uint256(vm.load(token, balanceSlot));

        vm.store(token, totalSupplySlot, bytes32(oldTotalSupply + amount));
        vm.store(token, balanceSlot, bytes32(oldBalance + amount));
    }

    /**
     * @notice Compute the buy amount without the margin
     * @param sellAmount The amount of the sell token
     * @param price The price of the token pair
     * @param sellDecimals The decimals of the sell token
     * @param priceDecimals The decimals of the price
     * @param buyDecimals The decimals of the buy token
     * @return The buy amount without the margin
     */
    function _computeBuyAmountWithoutMargin(
        uint256 sellAmount,
        uint256 price,
        uint256 sellDecimals,
        uint256 priceDecimals,
        uint256 buyDecimals
    ) internal pure returns (uint256) {
        int256 effectiveDecimalDifference = int256(sellDecimals + priceDecimals) - int256(buyDecimals);
        if (sellDecimals + priceDecimals >= buyDecimals) {
            return (sellAmount * price) / 10**uint256(effectiveDecimalDifference);
        } else {
            return (sellAmount * price) * 10**uint256(-effectiveDecimalDifference);
        }
    }

    /**
     * @notice Compute the buy amount with the margin
     * @param sellAmount The amount of the sell token
     * @param price The price of the token pair
     * @param sellDecimals The decimals of the sell token
     * @param priceDecimals The decimals of the price
     * @param buyDecimals The decimals of the buy token
     * @return The buy amount with the margin
     */
    function _computeBuyAmount(
        uint256 sellAmount,
        uint256 price,
        uint256 sellDecimals,
        uint256 priceDecimals,
        uint256 buyDecimals
    ) internal view returns (uint256) {
        uint256 buyAmountWithoutMargin = _computeBuyAmountWithoutMargin(sellAmount, price, sellDecimals, priceDecimals, buyDecimals);
        return (buyAmountWithoutMargin * (10000 - marginBasisPoints)) / 10000;
    }

    /**
     * @notice Fuzz-est the placeOrder function of the Stonks contract
     * @param sellTokenIndex The index of the sell token (bound to [0, SELL_TOKENS.length - 1])
     * @param buyTokenIndex The index of the buy token (bound to [0, BUY_TOKENS.length - 1])
     * @param sellAmount The amount of the sell token (bound to [11, 10000 ether])
     * @param minBuyAmountPct The minimum buy amount in percentage (bound to [1, 10000])
     */
    function test_placeOrder(
        uint256 sellTokenIndex,
        uint256 buyTokenIndex,
        uint256 sellAmount,
        uint256 minBuyAmountPct
    ) public {
        sellTokenIndex = bound(sellTokenIndex, 0, SELL_TOKENS.length - 1);
        buyTokenIndex = bound(buyTokenIndex, 0, BUY_TOKENS.length - 1);
        // Small amounts [0, 10] are not allowed by Stonks
        sellAmount = bound(sellAmount, 11, 10000 ether);
        minBuyAmountPct = bound(minBuyAmountPct, 1, 10000);

        address sellToken = SELL_TOKENS[sellTokenIndex];
        address buyToken = BUY_TOKENS[buyTokenIndex];
        // Skipping same token pairs
        vm.assume(sellToken != buyToken);

        // Different tokens have different decimals, we need to be careful with the amounts
        uint8 sellDecimals = IERC20Metadata(sellToken).decimals();
        uint8 buyDecimals = IERC20Metadata(buyToken).decimals();

        // Update the market rates
        // Get the current price of the token pair with correct decimals
        // wake-disable-next-line
        market.tick();
        uint256 price = amountConverter.getConversionRate(sellToken, buyToken);
        uint8 priceDecimals = amountConverter.RATE_DECIMALS();

        // Mint some tokens to the stonks contract
        address stonksAddress = address(stonks[sellToken][buyToken]);
        _mint(sellToken, stonksAddress, sellAmount);

        // Sell the whole Stonks balance
        sellAmount = IERC20Metadata(sellToken).balanceOf(stonksAddress);
        
        // Compute the expected buy amount including the margin
        uint256 buyAmount = _computeBuyAmount(sellAmount, price, sellDecimals, priceDecimals, buyDecimals);

        // The lower boundary for the buy amount
        // Used to prevent buying for high prices in cases of drastic changes in the price
        // Here, we randomize it on the interval [1, 1.1 * buy_amount]
        uint256 minBuyAmount = buyAmount >= 1 ? bound(buyAmount * 11000 * minBuyAmountPct / 10000 / 10000, 1, type(uint256).max) : 1;

        // Final buy amount is the maximum between the expected buy amount and the boundary
        buyAmount = Math.max(buyAmount, minBuyAmount);

        address orderAddress;
        vm.startPrank(makeAddr("manager"));
        
        if (sellAmount <= 10) {
            // Dust trades are not allowed, Stonks will revert
            vm.expectRevert(/*Stonks.MinimumPossibleBalanceNotMet.selector*/);
            orderAddress = Stonks(stonksAddress).placeOrder(minBuyAmount);
            return;
        } else if (0 == _computeBuyAmountWithoutMargin(
            sellAmount,
            price,
            sellDecimals,
            priceDecimals,
            buyDecimals
        )) {
            // The buy amount should be greater than zero, otherwise Stonks reverts
            vm.expectRevert(/*AmountConverter.InvalidExpectedOutAmount.selector*/);
            orderAddress = Stonks(stonksAddress).placeOrder(minBuyAmount);
            return;
        }

        // Otherwise, place the order
        vm.recordLogs();
        // wake-disable-next-line
        orderAddress = Stonks(stonksAddress).placeOrder(minBuyAmount);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 orderHash;
        GPv2Order.Data memory orderData;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].emitter == orderAddress && entries[i].topics[0] == keccak256(
                "OrderCreated(address,bytes32,(address,address,address,uint256,uint256,uint32,bytes32,uint256,bytes32,bool,bytes32,bytes32))"
            )) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), orderAddress);
                (orderHash, orderData) = abi.decode(entries[i].data, (bytes32, GPv2Order.Data));
                break;
            }
        }

        uint256 eventSellAmount = orderData.sellAmount;
        uint256 expectedEventBuyAmount = Math.max(_computeBuyAmount(eventSellAmount, price, sellDecimals, priceDecimals, buyDecimals), minBuyAmount);
        assertEq(orderData.buyAmount, expectedEventBuyAmount);

        // Validate the signature
        bytes4 expectedSignature = 0x1626ba7e;
        bytes4 actualSignature = Order(orderAddress).isValidSignature(orderHash, "");
        assertEq(bytes32(actualSignature), bytes32(expectedSignature));

        // The order is created and not expired, token recovery is not possible
        vm.expectRevert(/*Order.OrderNotExpired.selector*/);
        // wake-disable-next-line
        Order(orderAddress).recoverTokenFrom();

        // Set the timestamp after the order expiration
        vm.warp(block.timestamp + orderDuration + 1);
        vm.expectRevert(/*Order.OrderNotExpired.selector*/);
        // wake-disable-next-line
        Order(orderAddress).isValidSignature(orderHash, "");

        // Must succeed - order expired
        vm.startPrank(makeAddr("randomActor"));
        // wake-disable-next-line
        Order(orderAddress).recoverTokenFrom();
        vm.stopPrank();
    }

    /**
     * @notice Test if minting works correctly
     */
    function test_mint() public {
        _mint(STETH, address(this), 1000 ether);
        _mint(DAI, address(this), 1000 ether);
        _mint(USDT, address(this), 1000 ether);
        _mint(USDC, address(this), 1000 ether);

        // StETH has shares, not balance
        (bool success, bytes memory data) = STETH.call(abi.encodeWithSignature("sharesOf(address)", address(this)));
        require(success, "Call failed");
        uint256 shares = abi.decode(data, (uint256));
        require(shares == 1000 ether, "StETH: Incorrect shares");

        require(IERC20(DAI).balanceOf(address(this)) == 1000 ether, "DAI: Incorrect balance");
        require(IERC20(USDT).balanceOf(address(this)) == 1000 ether, "USDT: Incorrect balance");
        require(IERC20(USDC).balanceOf(address(this)) == 1000 ether, "USDC: Incorrect balance");
    }
}
