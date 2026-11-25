#!/usr/bin/env python3
"""Local end-to-end rehearsal on Anvil.

Anvil has no Reactive Network, so this script plays the two watchers the real
network provides:

  * PriceTick logs from PriceFeed are forwarded into DcaReactive.react();
  * DcaPlanCreated / DcaBuy / DcaBuySkipped logs from DcaVault are forwarded
    back into DcaReactive.react().

Everything else -- contracts, callback proxy auth, the vault's checks, the
budget accounting -- is the production code. The script prints the state after
every tick and asserts the expected number of buys.

    ./demo/local_deploy.sh
    python3 demo/local_demo.py --addresses /tmp/opencode/dca-local.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from eth_abi import encode
from eth_utils import keccak
from web3 import Web3

ROOT = Path(__file__).resolve().parent.parent

PRICE_TOPIC = int.from_bytes(keccak(text="PriceTick(uint256,uint256,uint256)"), "big")
BPS = 10_000


def load_abi(path: str) -> list:
    return json.loads((ROOT / path).read_text())["abi"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--addresses", default="/tmp/opencode/dca-local.json")
    ap.add_argument("--rpc", default=None)
    ap.add_argument("--from", dest="sender", default=None)
    ap.add_argument("--no-assert", action="store_true")
    args = ap.parse_args()

    addrs = json.loads(Path(args.addresses).read_text())
    rpc = args.rpc or addrs["rpc"]
    chain_id = int(addrs["chain_id"])
    w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 30}))
    if not w3.is_connected():
        raise SystemExit(f"cannot connect to {rpc}")

    sender = Web3.to_checksum_address(args.sender or w3.eth.accounts[0])
    owner = Web3.to_checksum_address(addrs["owner"])
    if sender != owner:
        raise SystemExit("local_demo.py uses the deployer (owner) for minting and the demo plan")

    usdc = w3.eth.contract(
        address=Web3.to_checksum_address(addrs["usdc"]), abi=load_abi("out/MockERC20.sol/MockERC20.json")
    )
    weth = w3.eth.contract(
        address=Web3.to_checksum_address(addrs["weth"]), abi=load_abi("out/MockERC20.sol/MockERC20.json")
    )
    feed = w3.eth.contract(
        address=Web3.to_checksum_address(addrs["feed"]), abi=load_abi("out/PriceFeed.sol/PriceFeed.json")
    )
    reactive = w3.eth.contract(
        address=Web3.to_checksum_address(addrs["reactive"]),
        abi=load_abi("out/DcaReactive.sol/DcaReactive.json"),
    )
    vault = w3.eth.contract(
        address=Web3.to_checksum_address(addrs["vault"]), abi=load_abi("out/DcaVault.sol/DcaVault.json")
    )
    system = w3.eth.contract(
        address=Web3.to_checksum_address(addrs["system"]),
        abi=load_abi("out/MockReactive.sol/MockSystem.json"),
    )
    vault_addr = vault.address.lower()
    reactive_addr = reactive.address
    plan_id = 0

    def send(fn, gas: int = 4_000_000):
        tx = fn.transact({"from": sender, "gas": gas})
        receipt = w3.eth.wait_for_transaction_receipt(tx)
        if receipt.status != 1:
            raise SystemExit(f"transaction reverted: {tx.hex()}")
        return receipt

    def trigger(log_tuple) -> dict:
        return send(system.functions.trigger(reactive_addr, log_tuple))

    def relay_vault_logs(receipt) -> int:
        relayed = 0
        for log in receipt["logs"]:
            if log["address"].lower() != vault_addr:
                continue
            topics = [int(t.hex(), 16) if hasattr(t, "hex") else int(t, 16) for t in log["topics"]]
            topics += [0] * (4 - len(topics))
            log_tuple = (
                chain_id,
                vault.address,
                topics[0],
                topics[1],
                topics[2],
                topics[3],
                bytes(log["data"]),
                int(receipt["blockNumber"]),
                3,
                0,
                0,
                0,
            )
            trigger(log_tuple)
            relayed += 1
        return relayed

    def tick(price: int) -> int:
        receipt = send(feed.functions.publish(price))
        tick_id = feed.functions.tickId().call()
        block = w3.eth.get_block(receipt["blockNumber"])
        price_log = (
            chain_id,
            feed.address,
            PRICE_TOPIC,
            tick_id,
            0,
            0,
            encode(["uint256", "uint256"], [price, block["timestamp"]]),
            int(receipt["blockNumber"]),
            2,
            0,
            0,
            0,
        )
        react_receipt = trigger(price_log)
        relayed = relay_vault_logs(react_receipt)
        print_tick(tick_id, price, relayed)
        return tick_id

    def plan_tuple():
        return reactive.functions.getPlan(plan_id).call()

    def print_tick(tick_id: int, price: int, relayed: int) -> None:
        if plan_id == 0:
            print(f"tick {tick_id:2d}  price ${price / 1e8:,.2f}  (no plan yet)")
            return
        rp = plan_tuple()
        # owner, basePerBuy, drawdownBps, cooldown, maxBuys, quoteBudget,
        # quoteSpent, buys, highWater, lastBuyPrice, ...
        buys = rp[7]
        hwm = rp[8]
        last_buy = rp[9]
        pending = reactive.functions.pending(plan_id).call()
        msg = (
            f"tick {tick_id:2d}  price ${price / 1e8:,.2f}  hwm ${hwm / 1e8:,.2f}  "
            f"last buy ${last_buy / 1e8:,.2f}  buys {buys}  pending {str(pending):5s}"
        )
        if relayed:
            msg += f"  relayed {relayed}"
        print(msg)

    def advance(seconds: int) -> None:
        w3.provider.make_request("evm_increaseTime", [seconds])
        w3.provider.make_request("evm_mine", [])
        print(f"         advanced {seconds}s")

    def show_status(label: str) -> None:
        vp = vault.functions.getPlan(plan_id).call()
        rp = reactive.functions.getPlan(plan_id).call()
        quote_bal = vault.functions.quoteBalance(sender).call() / 1e6
        print(f"\n== {label} ==")
        print(
            f"plan {plan_id}: active {vp[12]}  buys {vp[7]}/{vp[4]}  "
            f"spent {vp[6] / 1e6:.2f}/{vp[5] / 1e6:.2f} USDC  "
            f"last buy ${vp[9] / 1e8:,.2f}"
        )
        print(
            f"reactive:      buys {rp[7]}  spent {rp[6] / 1e6:.2f} USDC  "
            f"hwm ${rp[8] / 1e8:,.2f}  pending {reactive.functions.pending(plan_id).call()}"
        )
        print(
            f"balances:      user USDC {quote_bal:,.2f}  wallet WETH "
            f"{weth.functions.balanceOf(sender).call() / 1e18:.4f}  "
            f"vault WETH reserve {vault.functions.baseReserve().call() / 1e18:.4f}"
        )
        print(
            f"accounting:    quote {vault.functions.accountedQuote().call() / 1e6:,.2f} USDC  "
            f"quoteReserve {vault.functions.quoteReserve().call() / 1e6:,.2f} USDC"
        )

    # ---- setup ----------------------------------------------------------- #
    print("DCA Autopilot local rehearsal")
    print(f"rpc {rpc}  chain {chain_id}  owner {sender}")
    send(usdc.functions.mint(sender, 100_000 * 10**6))
    send(weth.functions.mint(sender, 10 * 10**18))
    send(usdc.functions.approve(vault.address, 2**256 - 1))
    send(weth.functions.approve(vault.address, 2**256 - 1))
    send(vault.functions.depositQuote(5_000 * 10**6))
    send(vault.functions.depositBaseReserve(2 * 10**18))
    receipt = send(vault.functions.createPlan(10**16, 500, 30, 5, 200 * 10**6))
    relayed = relay_vault_logs(receipt)
    plan_id = vault.functions.planCount().call()
    print(f"created plan {plan_id}, relayed {relayed} plan event(s)")
    show_status("after setup")

    # ---- the price path -------------------------------------------------- #
    # 2000 -> 2020 builds the high-water mark; 1950 is only a 3.5% dip.
    # 1910 is the first 5% dip; each later buy waits out the 30 s cooldown.
    path = [
        (2000, None),
        (2010, None),
        (2020, None),
        (1950, None),
        (1910, 1),
        (1850, None),
        (1800, 2),
        (1700, 3),
        (1600, 4),
        (1500, 5),
        (1400, None),  # max buys reached
    ]
    for price, expected in path:
        if price in (1800, 1700, 1600, 1500, 1400):
            advance(31)
        tick(price * 10**8)
        if expected is not None and not args.no_assert:
            buys = vault.functions.getPlan(plan_id).call()[7]
            if buys != expected:
                raise SystemExit(f"expected {expected} buys after ${price}, got {buys}")

    show_status("after 5 buys and a max-buy tick")

    # ---- cancel and refund ----------------------------------------------- #
    vp = vault.functions.getPlan(plan_id).call()
    refund = vp[5] - vp[6]
    print(f"\ncancelling plan; expected refund {refund / 1e6:.2f} USDC")
    receipt = send(vault.functions.cancelPlan(plan_id))
    relay_vault_logs(receipt)
    show_status("after cancel")

    bal = vault.functions.quoteBalance(sender).call()
    send(vault.functions.withdrawQuote(bal))
    print(f"withdrew {bal / 1e6:.2f} USDC of unallocated budget")
    show_status("after withdraw")

    if not args.no_assert:
        if vp[7] != 5:
            raise SystemExit(f"expected 5 buys, got {vp[7]}")
        if vault.functions.getPlan(plan_id).call()[12]:
            raise SystemExit("plan should be inactive after cancel")
        if vault.functions.accountedQuote().call() != usdc.functions.balanceOf(vault.address).call():
            raise SystemExit("quote accounting invariant broken")
        if vault.functions.baseReserve().call() != weth.functions.balanceOf(vault.address).call():
            raise SystemExit("base reserve invariant broken")
    print("\nlocal rehearsal passed")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
