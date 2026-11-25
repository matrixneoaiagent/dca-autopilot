#!/usr/bin/env python3
"""Terminal dashboard for a deployed or local DCA Autopilot.

    python3 demo/monitor.py --once
    python3 demo/monitor.py --watch
    python3 demo/monitor.py --addresses /tmp/opencode/dca-local.json --plan 1 --watch
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from web3 import Web3

ROOT = Path(__file__).resolve().parent.parent
BPS = 10_000


def load_abi(path: str) -> list:
    return json.loads((ROOT / path).read_text())["abi"]


def load_deployment(path: str) -> dict:
    dep = json.loads(Path(path).read_text())
    if "contracts" in dep:
        contracts = dep["contracts"]
        rpc = dep.get("rpc_origin")
        rpc_lasna = dep.get("rpc_lasna") or rpc
    else:
        contracts = dep
        rpc = dep.get("rpc")
        rpc_lasna = dep.get("rpc_lasna") or rpc
    return {
        "usdc": contracts["usdc"],
        "weth": contracts["weth"],
        "feed": contracts["price_feed"] if "price_feed" in contracts else contracts["feed"],
        "reactive": contracts["reactive"],
        "vault": contracts["vault"],
        "rpc": rpc,
        "rpc_lasna": rpc_lasna,
        "owner": dep.get("owner") or dep.get("demo_user"),
        "demo_user": dep.get("demo_user") or dep.get("owner"),
        "explorer": dep.get("explorer", ""),
    }


def fmt(x: int, decimals: int) -> str:
    return f"{x / 10**decimals:,.4f}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--addresses", default="deployments/latest.json")
    ap.add_argument("--plan", type=int, default=0)
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--once", action="store_true", help="print one snapshot (default)")
    ap.add_argument("--interval", type=float, default=3.0)
    args = ap.parse_args()
    if args.once:
        args.watch = False

    dep = load_deployment(args.addresses)
    if not dep["rpc"]:
        raise SystemExit("no rpc in deployment file")
    w3 = Web3(Web3.HTTPProvider(dep["rpc"], request_kwargs={"timeout": 30}))
    w3l = Web3(Web3.HTTPProvider(dep["rpc_lasna"], request_kwargs={"timeout": 30}))

    usdc = w3.eth.contract(
        address=Web3.to_checksum_address(dep["usdc"]), abi=load_abi("out/MockERC20.sol/MockERC20.json")
    )
    weth = w3.eth.contract(
        address=Web3.to_checksum_address(dep["weth"]), abi=load_abi("out/MockERC20.sol/MockERC20.json")
    )
    feed = w3.eth.contract(
        address=Web3.to_checksum_address(dep["feed"]), abi=load_abi("out/PriceFeed.sol/PriceFeed.json")
    )
    vault = w3.eth.contract(
        address=Web3.to_checksum_address(dep["vault"]), abi=load_abi("out/DcaVault.sol/DcaVault.json")
    )
    reactive = w3l.eth.contract(
        address=Web3.to_checksum_address(dep["reactive"]),
        abi=load_abi("out/DcaReactive.sol/DcaReactive.json"),
    )

    qd = usdc.functions.decimals().call()
    bd = weth.functions.decimals().call()

    while True:
        block = w3.eth.block_number
        tick_id = feed.functions.tickId().call()
        price = feed.functions.priceOf(tick_id).call() if tick_id else 0
        plan_id = args.plan or vault.functions.planCount().call()
        vp = vault.functions.getPlan(plan_id).call() if plan_id else None
        rp = reactive.functions.getPlan(plan_id).call() if plan_id else None
        pending = reactive.functions.pending(plan_id).call() if plan_id else False

        print("\033[2J\033[H", end="")
        print(f"DCA Autopilot  origin chain {w3.eth.chain_id} block {block}  feed tick {tick_id}")
        print(f"vault {dep['vault']}  reactive {dep['reactive']}")
        print(f"price ${fmt(price, 8) if price else '—'}")

        if vp:
            owner, base_per_buy, drawdown, cooldown, max_buys, budget, spent, buys, last_at, last_price, _, _, active = vp
            ref = last_price if last_price else (rp[8] if rp else 0)
            trigger = ref * (BPS - drawdown) // BPS if ref else 0
            rem = max(0, last_at + cooldown - w3.eth.get_block("latest")["timestamp"]) if buys and cooldown else 0
            print()
            print(f"plan {plan_id}  {'ACTIVE' if active else 'INACTIVE'}  owner {owner}")
            print(
                f"  buys {buys}/{max_buys}   spent {fmt(spent, qd)} / {fmt(budget, qd)} USDC   "
                f"last buy ${fmt(last_price, 8) if last_price else '—'}"
            )
            print(
                f"  trigger <= ${fmt(trigger, 8) if trigger else '—'}  (drawdown {drawdown / 100:.2f}%)   "
                f"cooldown {cooldown}s" + (f"   wait {rem}s" if rem else "")
            )
            print(
                f"  mirrored: buys {rp[7]}  spent {fmt(rp[6], qd)}  hwm ${fmt(rp[8], 8) if rp[8] else '—'}  "
                f"pending {pending}"
            )
            print(
                f"  wallet: {fmt(usdc.functions.balanceOf(owner).call(), qd)} USDC  "
                f"{fmt(weth.functions.balanceOf(owner).call(), bd)} WETH"
            )
            print(
                f"  vault:  reserve {fmt(vault.functions.baseReserve().call(), bd)} WETH  "
                f"quoteReserve {fmt(vault.functions.quoteReserve().call(), qd)} USDC  "
                f"accounted {fmt(vault.functions.accountedQuote().call(), qd)} USDC  "
                f"paused {vault.functions.paused().call()}"
            )
        else:
            print("\nno plan yet")

        if not args.watch:
            break
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
