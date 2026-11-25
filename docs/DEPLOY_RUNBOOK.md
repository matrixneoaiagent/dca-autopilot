# Deploy runbook

Testnet only. Use a dedicated key; never the main wallet. The full path costs $0 in real funds. The deployer needs Sepolia ETH for gas and a small amount of lREACT on Lasna for the reactive transactions.

## 0. Prerequisites

- Foundry (`forge`, `cast`, `anvil`) — in this workspace: `nix-shell -p foundry --run '...'`
- `jq`
- A dedicated testnet account (hardware wallet, `cast wallet` keystore, or a throwaway key in `deploy/config.env`, never committed)
- Sepolia ETH from a faucet
- lREACT on Lasna (from the official Reactive faucet)

The demo defaults to **Ethereum Sepolia (11155111)**. `ORIGIN_CHAIN=base-sepolia` switches the whole path to Base Sepolia (84532); the same commands apply with the Base proxy and explorer.

## 1. Fund the deployer

1. Get Sepolia ETH. The no-account PoW faucet is <https://sepolia-faucet.pk910.de/>: enter the deployer address and let the browser mine for a few minutes. Public faucets change; confirm the claim before deploying.
2. Send **0.01 SepETH** to the Reactive faucet with calldata `request(address)` and the deployer address:

   ```bash
   cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
     "request(address)" "$OWNER" \
     --value 0.01ether \
     --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
     --private-key "$PRIVATE_KEY"      # or --account "$ACCOUNT"
   ```

   Official rate: **1 ETH → 100 lREACT**, so 0.01 SepETH → 1 lREACT. The demo uses 0.2 lREACT for the reactive contract; 1 lREACT is comfortable. Do not send more than 5 ETH per transaction.
3. Check both balances:

   ```bash
   cast balance "$OWNER" --rpc-url "$RPC_ORIGIN"
   cast balance "$OWNER" --rpc-url https://lasna-rpc.rnk.dev/
   ```

   The deploy script also checks these and stops with a clear message if either is zero.

## 2. Configure

```bash
cp deploy/config.env.example deploy/config.env
$EDITOR deploy/config.env
```

Minimum fields:

```bash
ORIGIN_CHAIN=sepolia
RPC_ORIGIN=https://ethereum-sepolia-rpc.publicnode.com
RPC_LASNA=https://lasna-rpc.rnk.dev/
PRIVATE_KEY=0x...          # or ACCOUNT=my-keystore
OWNER=0x...                # must be the deployer for the scripted setVault
DEMO_USER=0x...            # defaults to OWNER
```

`deploy/config.env` is gitignored. The script never prints the key.

## 3. Dry run

```bash
./deploy/deploy.sh --dry-run
```

This checks the RPC chain ids, the callback proxy code on the origin chain, the system contract code on Lasna, and prints the deployment plan without sending transactions. It skips the balance requirement in dry-run mode. A correct dry run ends with `Dry run only`.

## 4. Deploy

```bash
./deploy/deploy.sh
```

What it deploys, in order:

| # | Contract | Chain | Constructor |
|---:|---|---|---|
| 1 | `MockERC20` mUSDC (6 decimals) | origin | name, symbol, decimals, owner |
| 2 | `MockERC20` mWETH (18 decimals) | origin | name, symbol, decimals, owner |
| 3 | `PriceFeed` | origin | publisher, owner |
| 4 | `DcaReactive` | Lasna | origin chain id, feed, dest chain id, owner |
| 5 | `DcaVault` | origin | quote, base, feed, callback proxy, reactive, owner |
| 6 | `DcaReactive.setVault` | Lasna | subscribes the five vault events |
| 7 | fund reactive + vault reserve | both | `0.2 lREACT`, `0.005 SepETH` |

It verifies the bindings (`vault()`, `PRICE_FEED()`, `_CALLBACK_SENDER()`, `_SERVICE_PROVIDER()`, token addresses, owner, origin chain id) and writes:

```
deployments/<timestamp>.json
deployments/latest.json
```

Expected output (addresses will differ):

```
== 1/7 demo quote token (mUSDC, 6 decimals) ==
USDC       0x...  0x...
...
== verify bindings ==
ok  reactive.vault
ok  reactive.PRICE_FEED
ok  vault.callbackSender
...
```

If the script stops at the lREACT check, send 0.01 SepETH to the faucet as in step 1. If it stops at a binding mismatch, do not proceed; the deployment is inconsistent.

The non-dry-run path was rehearsed before this repository was committed: two local Anvils (origin 11155111, Lasna 5318007) with the mock system and callback proxy, a throwaway funded key, all seven steps and all nine binding checks. The rehearsal addresses are not submission evidence; the public deployment still has to be done with `deploy/deploy.sh`.

## 5. Create the demo plan

```bash
./demo/setup_plan.sh
```

It mints 100,000 mUSDC to `DEMO_USER` and 10 mWETH to `OWNER`, approves the vault, deposits 5,000 mUSDC, creates the plan, and funds the 2 WETH reserve. Defaults:

| Parameter | Value |
|---|---|
| `basePerBuy` | 0.01 WETH |
| `drawdownBps` | 500 (5%) |
| `cooldown` | 30 s |
| `maxBuys` | 5 |
| `quoteBudget` | 200 USDC |
| quote deposit | 5,000 USDC |
| base reserve | 2 WETH |

It writes `deployments/demo-latest.json` with the plan id and setup txs. If `DEMO_USER` differs from `OWNER`, set `DEMO_ACCOUNT` or `DEMO_PRIVATE_KEY`; the owner still mints and funds the reserve.

Wait a few seconds for the Lasna subscription to deliver `DcaPlanCreated`, then check:

```bash
cast call "$REACTIVE" "planCount()(uint256)" --rpc-url "$RPC_LASNA"
cast call "$VAULT" "planCount()(uint256)" --rpc-url "$RPC_ORIGIN"
```

Both should be `1`. If the reactive is still `0`, wait one Lasna block and check Reactscan for the `PlanMirrored` event.

## 6. Publish the demo path

```bash
./demo/publish.sh --story
```

The story has 12 ticks: calm, first 5% dip, a cooldown pause, four more dips, then a max-buy stop. `INTERVAL` defaults to 12 s (Sepolia block time); `COOLDOWN_WAIT` defaults to 35 s. For a faster rehearsal:

```bash
INTERVAL=2 COOLDOWN_WAIT=35 ./demo/publish.sh --story
```

Or split it for a video:

```bash
./demo/publish.sh --calm   # 2000, 2010, 2020, 2020, 1950
./demo/publish.sh --dip    # 1910, then 1800/1700/1600/1500/1400 with waits
```

Expected: five `DcaBuy` events, five 0.01 WETH transfers to the plan owner, 85.10 USDC spent, 114.90 USDC unspent, and no buy at 1400. The exact path is in the README and `docs/DEMO_SCRIPT.md`.

## 7. Monitor and verify

```bash
python3 demo/monitor.py --watch
```

The dashboard shows the feed tick and price, the plan's buys/budget/last buy, the reactive mirror and pending flag, the user's balances, and the vault's accounting invariant. It needs the ABIs in `out/`, so run `forge build` first.

Explorer checks:

1. `PriceFeed` address → `PriceTick` events with increasing `tickId`.
2. `DcaVault` address → `DcaPlanCreated`, `DcaBuy` (and `DcaBuySkipped` if you publish a max-buy tick).
3. Reactscan Lasna at `https://lasna.reactscan.net/address/<reactive>` → the reactive transactions that called `requestCallbackV_1_0` and the `BuyRequested` / `BuyConfirmed` events.
4. The callback transactions on Sepolia → `executeBuy` with the matching `planId`, `tickId`, and price.

The minimum evidence set for the submission is: one origin `PriceTick`, the reactive Lasna tx, the callback tx that called `executeBuy`, and a `DcaBuy` event. Add the plan creation and the five-buy sequence for the full story.

## 8. Pause, retry, and recovery

```bash
# pause buys and new plans (withdrawals and cancel still work)
cast send "$VAULT" "pause()" --rpc-url "$RPC_ORIGIN" <auth>
cast send "$VAULT" "unpause()" --rpc-url "$RPC_ORIGIN" <auth>

# pause new reactive requests
cast send "$REACTIVE" "pause()" --rpc-url "$RPC_LASNA" <auth>
cast send "$REACTIVE" "unpause()" --rpc-url "$RPC_LASNA" <auth>

# after a missed callback and the 300 s timeout
cast send "$REACTIVE" "retry(uint256)" "$PLAN_ID" --rpc-url "$RPC_LASNA" <auth>

# owner can clear a stuck pending marker without moving funds
cast send "$REACTIVE" "clearPending(uint256)" "$PLAN_ID" --rpc-url "$RPC_LASNA" <auth>

# user can always cancel and withdraw
cast send "$VAULT" "cancelPlan(uint256)" "$PLAN_ID" --rpc-url "$RPC_ORIGIN" <user-auth>
cast send "$VAULT" "withdrawQuote(uint256)" "$AMOUNT" --rpc-url "$RPC_ORIGIN" <user-auth>
```

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `no callback proxy code` | wrong chain/proxy, or RPC is not the expected testnet | check `ORIGIN_CHAIN`, `ORIGIN_CHAIN_ID`, `CALLBACK_PROXY` |
| `deployer has no lREACT` | faucet not claimed | send 0.01 SepETH to the Reactive faucet with `request(address)` |
| `planCount()` on Lasna stays 0 | `setVault` not called, or the plan event has not been delivered yet | check the deploy tx; wait a block; verify `reactive.vault()` |
| No buy at 1910 | high-water mark not built (no calm ticks), or the plan event was missed | publish `--calm` first; check `reactive.getPlan(1).highWater` |
| Buy at 1910 but not 1800 | cooldown not elapsed | wait 30 s; `COOLDOWN_WAIT=35` |
| `DcaBuySkipped(BudgetExceeded)` | plan budget too small for the fixed base amount | `fundPlan` or create a larger plan |
| `DcaBuySkipped(InsufficientReserve)` | WETH reserve below `basePerBuy` | `depositBaseReserve` |
| Callback reverts `PriceMismatch` | the reactive used a tick the feed does not have, or the wrong tick/price | inspect the feed and the reactive payload; do not retry blindly |
| `retry` reverts `PendingNotStale` | a callback is still in flight | wait `callbackTimeout` (300 s) |
| `retry` reverts `PlanNotTriggerable` | price has recovered or the cooldown/budget/max rules block it | expected; wait for a new dip or cancel |

## 10. Cost

| Item | Cost |
|---|---|
| Entry fee | $0 |
| Sepolia ETH for deployment, callbacks and demo ticks | $0 (faucet) |
| lREACT for the reactive contract | $0 (0.01 SepETH → 1 lREACT) |
| Mainnet deployment | not required |
| Purchase / stake / deposit | none |

The deployer needs roughly `0.001 SepETH` for deployment gas plus `0.005 SepETH` for the vault's callback reserve. `0.01–0.02 SepETH` is comfortable. On Lasna, `0.2 lREACT` funds the reactive contract; `1 lREACT` covers the whole demo.

## 11. What not to do

- Do not use the main wallet key. The deploy script reads `PRIVATE_KEY` or `ACCOUNT` from the environment; use a dedicated testnet key.
- Do not commit `deploy/config.env`, `deployments/*.local.json`, or any file containing a key.
- Do not deploy to mainnet. The contracts are unaudited and the tokens are mocks.
- Do not submit a repo-only entry: the buildathon's Execution score requires public addresses and transaction hashes showing the full loop.
