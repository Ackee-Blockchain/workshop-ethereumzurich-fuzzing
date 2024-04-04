// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import {AmountConverter} from "../contracts/AmountConverter.sol";

contract Market {
    AmountConverter public immutable amountConverter;
    uint8 public immutable DECIMALS;
    uint256 public constant ETH_PRICE = 10000;

    mapping(address => mapping(address => uint256)) public baseRates;
    address[] public baseTokens;
    address[] public quoteTokens;

    constructor(
        AmountConverter _amountConverter,
        address stETH,
        address[] memory stables
    ) {
        amountConverter = _amountConverter;
        DECIMALS = _amountConverter.RATE_DECIMALS();
        // rates[base][quote] = rate * 10**18
        // E.g. rates[ETH][USDC] = 10000 * 10**18\
        // E.g. rates[USDC][ETH] = (1 / 10000) * 10**18)
        for (uint256 i = 0; i < stables.length; i++) {
            baseRates[stETH][stables[i]] = 10000 * 10**DECIMALS;
            baseTokens.push(stETH);
            quoteTokens.push(stables[i]);
            baseRates[stables[i]][stETH] = 1 * 10**DECIMALS / ETH_PRICE;
            baseTokens.push(stables[i]);
            quoteTokens.push(stETH);
        }
        // Add rates between stablecoins
        // E.g. rates[USDC][USDT] = 1 * 10**18
        for (uint256 i = 0; i < stables.length; i++) {
            for (uint256 j = i + 1; j < stables.length; j++) {
                baseRates[stables[i]][stables[j]] = 1 * 10**DECIMALS;
                baseTokens.push(stables[i]);
                quoteTokens.push(stables[j]);
                baseRates[stables[j]][stables[i]] = 1 * 10**DECIMALS;
                baseTokens.push(stables[j]);
                quoteTokens.push(stables[i]);
            }
        }
        tick();
    }

    function tick() public {
        for (uint256 i = 0; i < baseTokens.length; i++) {
            address base = baseTokens[i];
            address quote = quoteTokens[i];
            uint256 rate = baseRates[base][quote];

            // Generate "random" number from 0.9 to 1.1
            uint256 random = uint256(keccak256(abi.encodePacked(block.timestamp, block.number))) % 2000 + 9000;
            rate = rate * random / 10000;
            _updateConverter(base, quote, rate);
        }
    }

    function _updateConverter(address base, address quote, uint256 rate) internal {
        amountConverter.setConversionRate(base, quote, rate);
    }
}