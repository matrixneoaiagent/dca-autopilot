# Demo video — 2:30 shot list

Target length **2:20–2:40**. The DoraHacks limit is three minutes. Record at 1080p, 30 fps, terminal font ≥ 18 pt. Two scenes: terminal + pre-opened explorer tabs.

Ethereum Sepolia produces ~12 s blocks, so the raw 12-tick story takes ~2–3 minutes before edits. Record one take, then cut the waits; the explorer timestamps prove the order.

## Pre-flight (before recording)

```bash
# deployed, addresses in deployments/latest.json
export VAULT=$(jq -r .contracts.vault deployments/latest.json)
export FEED=$(jq -r .contracts.price_feed deployments/latest.json)
export REACTIVE=$(jq -r .contracts.reactive deployments/latest.json)
forge build   # the monitor loads ABIs from out/
```

Tabs to have open:

1. Etherscan: `https://sepolia.etherscan.io/address/$FEED`
2. Reactscan Lasna: `https://lasna.reactscan.net/address/$REACTIVE`
3. Etherscan: `https://sepolia.etherscan.io/address/$VAULT`
4. The repository README architecture diagram.

Kill background noise, hide notifications, clear the terminal, set `PS1='$ '`.

## 0:00–0:20 — Hook

**On screen:** README architecture diagram, cursor on the `PriceTick → DcaReactive → callback` arrow.

**Voice:** "Dollar-cost averaging is easy to plan and hard to stick to. You have to watch the chart, remember your last buy, respect a cooldown, and not overspend. DCA Autopilot puts the rule on-chain: deposit USDC, set a dip threshold and a budget, and a Reactive contract on Lasna watches the price and buys the dip on Sepolia while you sleep."

Show the plan parameters for five seconds:

```
0.01 WETH per buy · 5% drawdown · 30 s cooldown · 5 buys max · 200 USDC budget
```

## 0:20–0:40 — The loop

**On screen:** scroll the diagram; highlight Sepolia → Lasna → Sepolia.

**Voice:** "A price event on Sepolia wakes the reactive contract on Lasna. It mirrors the plan, updates the rolling high, and checks the drawdown, cooldown and budget. When the plan is eligible it sends a callback to the vault. The vault checks the proxy, the reactive address, the exact published tick, the budget and the reserve, then sends the fixed WETH amount to the user. Every hop is an on-chain transaction."

Show `deployments/latest.json` addresses for five seconds.

## 0:40–1:10 — Plan setup

```bash
./demo/setup_plan.sh
python3 demo/monitor.py --once
```

**On screen:** `plan id 1`, `buys 0/5`, `spent 0/200`, `wallet 5,000 USDC`, `vault reserve 2 WETH`.

**Voice:** "The user deposits 5,000 USDC and allocates 200 to the plan. The vault holds the quote and a 2 WETH reserve that backs the buys. The plan is one event; the reactive contract mirrors it on Lasna."

## 1:10–1:35 — Calm, then the first dip

```bash
./demo/publish.sh --calm
```

**On screen:** ticks 2000, 2010, 2020, 1950; monitor shows `hwm 2020`, `buys 0`.

**Voice:** "The first four ticks build the high-water mark. 1950 is only a 3.5% dip, so the bot waits. Then 1910 — 5.45% below the high."

```bash
./demo/publish.sh --price 191000000000
python3 demo/monitor.py --once
```

**On screen:** `buys 1/5`, `last buy $1,910`, `spent 19.10`, `wallet WETH 0.0100`. Open the vault's `DcaBuy` event and the reactive's `BuyRequested` / `BuyConfirmed` on Reactscan.

**Voice:** "The reactive contract requests the callback. The vault verifies the tick price against the feed, moves 0.01 WETH from the reserve to the user, and records the buy at $1,910. The reactive sees the confirmation and updates the last buy."

## 1:35–2:00 — Cooldown and the next buys

```bash
./demo/publish.sh --price 185000000000   # 3.1% below 1910: no buy
./demo/publish.sh --dip                  # 1800, 1700, 1600, 1500, 1400 with waits
```

**On screen:** the monitor advances `buys 2 → 3 → 4 → 5`; each buy is 0.01 WETH; `spent 85.10`; the 1400 tick shows `buys 5/5` and no new `DcaBuy`.

**Voice:** "The immediate 1850 tick is inside the 30-second cooldown, so nothing happens. After the cooldown, each 5% drop buys again. When the fifth buy lands, the max-buy rule stops the plan. The 1400 tick is ignored — the budget is not spent, and no callback is sent."

## 2:00–2:20 — The fallback and the refund

Cut to the Foundry tests:

```bash
forge test --match-test test_missedCallbackRecovers -vv
forge test --match-test test_missedCallbackCanBeCancelled -vv
```

**Voice:** "If a callback is dropped, no funds move. The pending request expires, anyone can retry a valid buy, and the user can always cancel. Cancelling refunds the unspent 114.90 USDC to the user's balance."

```bash
# back in the terminal, if you want the live version
cast send "$VAULT" "cancelPlan(uint256)" 1 --rpc-url "$RPC_ORIGIN" <auth>
cast send "$VAULT" "withdrawQuote(uint256)" 4914900000 --rpc-url "$RPC_ORIGIN" <auth>
```

**On screen:** `plan INACTIVE`, `quoteBalance 4,914.90`, `accountedQuote == USDC balance`.

**Voice:** "The unspent budget is always the user's. The vault's accounting invariant holds before and after the cancel."

## 2:20–2:35 — Close

**On screen:** README top, repo URL, test summary.

**Voice:** "DCA Autopilot is open source, runs on Ethereum Sepolia and Reactive Lasna, and the full loop is covered by 62 tests, each run on both chain fixtures — 124 passing executions, including budget, cooldown, double-execution, pause and missed-callback paths. Repo, addresses and transactions are in the submission. Thanks."

## Contingencies

| Problem | Fix |
|---|---|
| Sepolia is slow (~12 s blocks) | Publish one tick per block; cut the waits in editing, keep timestamps visible |
| The first buy does not fire | Publish `--calm` first so the high-water mark is 2020; check `reactive.getPlan(1).highWater` |
| A buy is skipped `Cooldown` | Wait 35 s after the previous buy; `COOLDOWN_WAIT=35` |
| A buy is skipped `BudgetExceeded` | The plan budget is 200 USDC; five buys cost 85.10, so this should not happen unless the plan was changed |
| A callback is dropped | Wait 300 s and `retry(1)`; or show the test instead |
| Explorer tabs fail | Use `cast tx` / `cast receipt`; the hashes are the evidence |
| Video runs long | Cut the calm shot to 5 s and the 1850 no-buy to 2 s; the first buy and the max-buy stop are the core |

## Post-recording checks

- [ ] < 3:00 (hard limit; target 2:30)
- [ ] Shows origin `PriceTick` → reactive Lasna tx → callback → `DcaBuy`
- [ ] Shows the first buy and the max-buy stop
- [ ] Shows a cancel/refund or the missed-callback test
- [ ] No keys, `deploy/config.env`, or personal data on screen
- [ ] Public or unlisted URL that works in incognito
- [ ] All shown hashes match `docs/SUBMISSION_CHECKLIST.md`
