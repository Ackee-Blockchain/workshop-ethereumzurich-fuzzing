import random
from typing import Dict, List, Tuple

from pytypes.contracts.AmountConverter import AmountConverter
from wake.testing import Address

class Market:
    """This class simulates a market for stETH and stablecoins.

    On each tick, the market updates the exchange rates between
    stETH and stablecoins based on the base ETH price ($4500 by
    default) and some random noise.
    """
    def __init__(
        self,
        converter: AmountConverter,
        stETH: Address,
        stables: List[Address],
        eth_price: float = 10000.0,
    ) -> None:
        self.amount_converted: AmountConverter = converter
        self.decimals = converter.RATE_DECIMALS()
        # rates[base][quote] = rate * 10**18
        # E.g. rates[ETH][USDC] = 10000 * 10**18
        self.base_rates: Dict[Tuple[Address, Address], float] = {
            (stETH, stable): int(eth_price * 10**self.decimals)
            for stable in stables
        }
        # Add reverse rates
        # E.g. rates[USDC][ETH] = (1 / 10000) * 10**18)
        self.base_rates.update({
            (stable, stETH): int(1 / eth_price * 10**self.decimals)
            for stable in stables
        })
        # Add rates between stablecoins
        # E.g. rates[USDC][USDT] = 1 * 10**18
        self.base_rates.update({
            (base, quote): 1 * 10**self.decimals
            for base in stables
            for quote in stables
            if base != quote
        })
        self.tick()
    
    def tick(self) -> None:
        for (base, quote), rate in self.base_rates.items():
            # +/- 10% difference from the base rate
            rate *= 1 + random.uniform(-0.1, 0.1)
            self._update_converter(base, quote, int(rate))

    def _update_converter(self, base: Address, quote: Address, rate: int) -> None:
        self.amount_converted.setConversionRate(base, quote, rate)
