import random
from typing import Dict, Tuple, Union

from wake.testing import *
from wake.testing.fuzzing import *
from .lib.market import Market

from pytypes.contracts.AmountConverter import AmountConverter
from pytypes.contracts.Order import Order
from pytypes.contracts.Stonks import Stonks
from pytypes.node_modules.openzeppelin.contracts.token.ERC20.extensions.IERC20Metadata import IERC20Metadata


# Decimals: 18
STETH = Address("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84")
# Decimals: 18
DAI = Address("0x6B175474E89094C44Da98b954EedeAC495271d0F")
# Decimals: 6
USDT = Address("0xdAC17F958D2ee523a2206206994597C13D831ec7")
# Decimals: 6
USDC = Address("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")

# Required in the constructor of Order
COW_VAULT_RELAYER = Address("0xC92E8bdf79f0507f65a392b0ab4667716BFE0110")


def mint(token: Union[Address, Account], to: Union[Address, Account], amount: int):
    if isinstance(token, Account):
        token = token.address
    if isinstance(to, Account):
        to = to.address

    if token == DAI:
        total_supply_slot = 1
        balance_slot = int.from_bytes(keccak256(Abi.encode(["address", "uint256"], [to, 2])), byteorder="big")
    elif token == USDC:
        total_supply_slot = 11
        balance_slot = int.from_bytes(keccak256(Abi.encode(["address", "uint256"], [to, 9])), byteorder="big")
    elif token == USDT:
        total_supply_slot = 1
        balance_slot = int.from_bytes(keccak256(Abi.encode(["address", "uint256"], [to, 2])), byteorder="big")
    elif token == STETH:
        # stETH, mint shares instead of balance
        total_supply_slot = 0xe3b4b636e601189b5f4c6742edf2538ac12bb61ed03e6da26949d69838fa447e
        balance_slot = int.from_bytes(keccak256(Abi.encode(["address", "uint256"], [to, 0])), byteorder="big")
    else:
        raise ValueError(f"Unknown token {token}")

    old_total_supply = int.from_bytes(default_chain.chain_interface.get_storage_at(str(token), total_supply_slot), byteorder="big")
    default_chain.chain_interface.set_storage_at(str(token), total_supply_slot, (old_total_supply + amount).to_bytes(32, "big"))

    old_balance = int.from_bytes(default_chain.chain_interface.get_storage_at(str(token), balance_slot), byteorder="big")
    default_chain.chain_interface.set_storage_at(str(token), balance_slot, (old_balance + amount).to_bytes(32, "big"))


class StonksTest(FuzzTest):
    agent: Account
    amount_converter: AmountConverter
    market: Market
    stonks: Dict[Tuple[Address, Address], Stonks]

    order_duration: int
    margin_basis_points: int
    price_tolerance_basis_points: int

    def pre_sequence(self):
        # The agent is a random account
        self.agent = Account.new()
        # The manager is the deployer
        manager = default_chain.accounts[0]

        # Randomize the order duration, margin and price tolerance
        self.order_duration = random_int(60, 60 * 60 * 24)
        self.margin_basis_points = random_int(0, 1_000, edge_values_prob=0.33)  # 0% - 10%
        self.price_tolerance_basis_points = random_int(0, 1_000, edge_values_prob=0.33)  # 0% - 10%

        # Create the AmountConverter and create the market instance, which will set price conversion rates
        self.amount_converter = AmountConverter.deploy()
        self.market = Market(self.amount_converter, STETH, [DAI, USDC, USDT])

        # Deploy a sample order contract
        sample_order = Order.deploy(
            self.agent,
            COW_VAULT_RELAYER,
            # ICoWSwapSettlement(COW_SETTLEMENT).domainSeparator()
            # COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41
            bytes.fromhex("c078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943"),
        )
        
        self.stonks = {}
        for sell_token in [STETH, DAI, USDT, USDC]:
            for buy_token in [DAI, USDT, USDC]:
                if sell_token == buy_token:
                    continue

                self.stonks[(sell_token, buy_token)] = Stonks.deploy(
                    self.agent,
                    manager,
                    sell_token,
                    buy_token,
                    self.amount_converter,
                    sample_order,
                    self.order_duration,
                    self.margin_basis_points,
                    self.price_tolerance_basis_points,
                )

    def _compute_buy_amount_without_margin(self, sell_amount: int, price: int, sell_decimals: int, price_decimals: int, buy_decimals: int) -> int:
        """
        Example:
        ETH / USDT = 10_000_000_000_000_000_000_000
        USDT / ETH = 100_000_000_000_000

        USDT.decimals = 6
        ETH.decimals = 18

        ##############
        # Sell 1 ETH #
        ##############

        sell decimals: 18
        buy decimals: 6
        price decimals: 18
        
        sell amount: 1 ETH = 1_000_000_000_000_000_000 wei
        target buy amount: 10_000_000_000 USDTwei

        buy amount = 1_000_000_000_000_000_000 * 10_000_000_000_000_000_000_000 // 10 ** (18 + 18 - 6)
                   = 1_000_000_000_000_000_000 * 10_000_000_000_000_000_000_000 // 10 ** 30
                   = 10**18 * 10**22 // 10**30
                   = 10**40 // 10**30
                   = 10**10
                   = 10_000_000_000 USDTwei
                   = 10_000 USDT

        ################
        # Sell 10 USDT #
        ################

        sell decimals: 6
        buy decimals: 18
        price decimals: 18

        sell amount: 10 USDT = 10_000_000 USDTwei
        target buy amount: 1_000_000_000_000_000 wei

        buy amount = 10_000_000 * 100_000_000_000_000 // 10 ** (6 + 18 - 18)
                   = 10**7 * 10**14 // 10**6
                   = 10**15
                   = 1_000_000_000_000_000 wei
                   = 0.001 ETH
        """
        # mirrors the logic in AmountConverter.getExpectedOut()
        if sell_decimals + price_decimals >= buy_decimals:
            buy_amount = sell_amount * price // 10 ** (sell_decimals + price_decimals - buy_decimals)
        else:
            buy_amount = sell_amount * price * 10 ** (buy_decimals - sell_decimals - price_decimals)

        return buy_amount

    def _compute_buy_amount(self, sell_amount: int, price: int, sell_decimals: int, price_decimals: int, buy_decimals: int) -> int:
        buy_amount = self._compute_buy_amount_without_margin(sell_amount, price, sell_decimals, price_decimals, buy_decimals)
        return buy_amount * (10_000 - self.margin_basis_points) // 10_000
    
    @flow()
    def flow_place_order(self):
        # Randomly select a token pair
        sell_token = random.choice([STETH, DAI, USDT, USDC])
        buy_token = random.choice(list({DAI, USDT, USDC} - {sell_token}))
        
        # Different tokens have different decimals, we need to be careful with the amounts
        sell_decimals = IERC20Metadata(sell_token).decimals()
        buy_decimals = IERC20Metadata(buy_token).decimals()

        # Randomly select a sell amount
        sell_amount = random_int(1, 10_000 * 10**sell_decimals)
        
        # Update the market rates
        # Get the current price of the token pair with correct decimals
        self.market.tick()
        price = self.amount_converter.getConversionRate(sell_token, buy_token)
        price_decimals = self.amount_converter.RATE_DECIMALS()

        # Mint some tokens to the stonks contract
        mint(sell_token, self.stonks[(sell_token, buy_token)], sell_amount)
        
        # Sell the whole Stonks balance
        sell_amount = IERC20Metadata(sell_token).balanceOf(self.stonks[(sell_token, buy_token)])
        
        # Compute the expected buy amount including the margin
        buy_amount = self._compute_buy_amount(sell_amount, price, sell_decimals, price_decimals, buy_decimals)
        
        # The lower boundary for the buy amount
        # Used to prevent buying for high prices in cases of drastic changes in the price
        # Here, we randomize it on the interval [1, 1.1 * buy_amount]
        min_buy_amount = random_int(1, round(buy_amount * 1.1)) if buy_amount >= 1 else 1
        
        # Final buy amount is the maximum between the expected buy amount and the boundary
        buy_amount = max(buy_amount, min_buy_amount)

        # Stonks forbids dust trades and has a hard limit of minimum of 10 tokens
        if sell_amount <= 10:
            # TODO
            return
        # If the expected buy (output) amount is 0, Stonks should revert
        elif False:
            # TODO
            return
        # Otherwise, the order should be placed successfully
        else:
            pass
            # Call the function
            # TODO

            # Validate events
            # TODO
            
            # Update values with amounts from event
            # TODO

            # Validate the signature
            # TODO

            # The order is created and not expired, token recovery is not possible
            # TODO
            
            # Mine a new block with a timestamp after the order expiration
            # TODO

            # Must succeed - order expired
            # TODO


def test_stonks():
    for _ in range(100):
        with default_chain.connect(fork=f"https://ethereum-rpc.publicnode.com"):
            try:
                StonksTest().run(1, 100)
            except TransactionRevertedError as e:
                print(e.tx.call_trace if e.tx else "Call reverted")
                raise
            print("sequence passed")
