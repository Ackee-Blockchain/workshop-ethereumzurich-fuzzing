// SPDX-FileCopyrightText: 2024 Ackee Blockchain
// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAmountConverter} from "./interfaces/IAmountConverter.sol";

/**
 * @title AmountConverter
 * @dev This contract mocks the original AmountConverter contract created by Lido.
 *      It is not meant to be used in production and is created for educational purposes only.
 *      The original contract uses Chainlink price feeds to convert the amount of one token to another.
 *      Here, we have removed the Chainlink price feed functionality and kept the contract simple.
 *      The price of the asset is set manually.
 */
contract AmountConverter is IAmountConverter {
    /// @dev Conversion rate decimals
    uint8 constant public RATE_DECIMALS = 18;

    /// @dev conversionRates[base][quote] = (rate * 10**RATE_DECIMALS)
    mapping(address => mapping(address => uint256)) private conversionRates;

    error ZeroAddress();
    error SameTokensConvertion();
    error RateNotSet(address tokenFrom, address tokenTo);
    error InvalidAmount(uint256 amount);
    error InvalidExpectedOutAmount(uint256 amount);

    /**
     * @notice Sets the conversion rate for the given token pair.
     *
     * @param base_ The address of the base token.
     * @param quote_ The address of the quote token.
     * @param rate_ The conversion rate for the token pair.
     */
    function setConversionRate(address base_, address quote_, uint256 rate_) external {
        conversionRates[base_][quote_] = rate_;
    }

    /**
     * @notice Fetch the conversion rate for the given token pair.
     * 
     * @param base_ The address of the base token.
     * @param quote_ The address of the quote token.
     * @return rate The conversion rate for the token pair.
     */
    function getConversionRate(address base_, address quote_) external view returns (uint256 rate) {
        return conversionRates[base_][quote_];
    }

    /**
     * @notice Calculates the expected amount of `tokenTo_` that one would receive for a given amount of `tokenFrom_`.
     *
     * @param tokenFrom_ The address of the token being sold.
     * @param tokenTo_ The address of the token being bought.
     * @param amountFrom_ The amount of `tokenFrom_` that is being sold.
     * @return expectedOutputAmount The expected amount of `tokenTo_` that will be received.
     */
    function getExpectedOut(address tokenFrom_, address tokenTo_, uint256 amountFrom_)
        external
        view
        returns (uint256 expectedOutputAmount)
    {
        if (tokenFrom_ == tokenTo_) revert SameTokensConvertion();
        if (conversionRates[tokenFrom_][tokenTo_] == 0) revert RateNotSet(tokenFrom_, tokenTo_);
        if (amountFrom_ == 0) revert InvalidAmount(amountFrom_);

        uint256 decimalsOfSellToken = IERC20Metadata(tokenFrom_).decimals();
        uint256 decimalsOfBuyToken = IERC20Metadata(tokenTo_).decimals();
        int256 effectiveDecimalDifference = int256(decimalsOfSellToken + RATE_DECIMALS) - int256(decimalsOfBuyToken);

        if (effectiveDecimalDifference >= 0) {
            expectedOutputAmount = (amountFrom_ * conversionRates[tokenFrom_][tokenTo_]) / 10 ** uint256(effectiveDecimalDifference);
        } else {
            expectedOutputAmount = (amountFrom_ * conversionRates[tokenFrom_][tokenTo_]) * 10 ** uint256(-effectiveDecimalDifference);
        }

        if (expectedOutputAmount == 0) revert InvalidExpectedOutAmount(expectedOutputAmount);
    }
}
