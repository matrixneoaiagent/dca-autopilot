# Architecture

DCA Autopilot is two production contracts and one demo price source:

| Role | Contract | Network |
|---|---|---|
| Price source | `PriceFeed` | Ethereum Sepolia (11155111) |
| Automation | `DcaReactive` | Reactive Lasna (5318007) |
| Funds and rules | `DcaVault` | Ethereum Sepolia (11155111) |
| Demo assets | `MockERC20` mUSDC / mWETH | Ethereum Sepolia |

The origin and destination chain are the same in this build; `ORIGIN_CHAIN_ID == DEST_CHAIN_ID`. The reactive contract subscribes with the selected chain id, so switching to Base Sepolia changes the chain id, proxy and feed but not the logic.

## 1. Sequence

```
User                    DcaVault (Sepolia)              DcaReactive (Lasna)                 PriceFeed (Sepolia)
 │                            │                               │                                   │
 │ approve + depositQuote     │                               │                                   │
 ├───────────────────────────▶│                               │                                   │
 │ createPlan                 │                               │                                   │
 ├───────────────────────────▶│                               │                                   │
 │                            │── DcaPlanCreated ────────────▶│ mirror plan, HWM = lastPrice      │
 │                            │                               │                                   │
 │                            │                               │◀────────── PriceTick ─────────────┤
 │                            │                               │ update HWM, evaluate drawdown     │
 │                            │                               │ cooldown / max buys / budget      │
 │                            │◀──── executeBuy(plan,tick,price) ── callback request ─────────────┤
 │                            │ auth + oracle + rules         │                                   │
 │                            │ WETH reserve ──▶ user         │                                   │
 │                            │── DcaBuy ────────────────────▶│ clear pending, update last buy    │
 │                            │                               │                                   │
 │                            │   (or DcaBuySkipped) ────────▶│ clear pending, stay eligible      │
```

There are two kinds of reactive subscriptions:

1. **Price ticks** from `PriceFeed` (one subscription, created in the constructor).
2. **Vault events** from `DcaVault` (five subscriptions, created by `setVault` after the vault exists).

The deployment order is therefore: feed → reactive → vault → `reactive.setVault(vault)`. Plans created before `setVault` are not mirrored; the deploy script creates no plans.

## 2. What the reactive contract decides vs. what the vault enforces

| Decision | Reactive | Vault | Why |
|---|---|---|---|
| Is this a drawdown vs the reference? | yes | yes, after the first buy | The reactive needs the per-plan high-water mark; the vault independently checks its own last-buy price as defence in depth. |
| Has the cooldown elapsed? | yes | yes | The reactive avoids wasted callbacks; the vault is authoritative. |
| Are there buys left? | yes | yes | Same. |
| Is the budget sufficient? | approximate (mirror) | exact (`quoteIn` vs remaining) | The reactive does not know token decimals; the vault computes the exact cost. |
| Is the base reserve sufficient? | no | yes | The reserve is a vault concern. |
| Is the callback authentic? | n/a | yes | The proxy and reactive address are the funds boundary. |
| Is the tick real and fresh? | no | yes | The vault checks `priceOf` and `publishedAt` against the feed. |
| Has this tick already executed? | pending marker | `lastTickId` | Two independent replay guards. |

This split is deliberate: the reactive contract is simple enough to audit for trigger logic, and the vault is simple enough to audit for funds. A bug in the reactive mirror can cause a missed or extra *request*, but it cannot move funds outside the vault's rules.

## 3. Callback authentication

Production Reactive callbacks are delivered by a callback proxy on the destination chain. The proxy replaces the first 32-byte argument of the payload with the address of the requesting reactive contract. `DcaVault.executeBuy` is declared as:

```solidity
function executeBuy(address reactive_, uint256 planId, uint256 tickId, uint256 price)
    external
    onlyServiceProvider        // msg.sender == callback proxy
    onlyCallbackSender(reactive_) // proxy-injected arg == configured reactive
    nonReentrant
    returns (bool)
```

The reactive contract builds the payload with `address(0)` as the placeholder:

```solidity
abi.encodeWithSignature(
    "executeBuy(address,uint256,uint256,uint256)",
    address(0), planId, tickId, price
);
```

A direct call from an EOA or another contract fails `onlyServiceProvider`. A call from the proxy with the wrong first argument fails `onlyCallbackSender`. Both paths are tested (`test_executeBuyUnauthorizedReverts`).

## 4. State machine

### Plan (vault)

```
                 createPlan
                    │
                    ▼
   ┌─────────── ACTIVE ───────────┐
   │  executeBuy:                 │
   │    quoteSpent += quoteIn     │
   │    buys += 1                 │
   │    lastBuyPrice = price      │
   │    lastTickId = tickId       │
   │                              │
   │  executeBuy skip:            │
   │    no state change, event    │
   └──────────────┬───────────────┘
                  │ cancelPlan (owner)
                  ▼
              INACTIVE
        refund = quoteBudget - quoteSpent
        to the owner's unallocated balance
```

`quoteBudget` stays as the historical funded amount after cancellation; `active = false` means the remainder has been refunded. A late callback for an inactive plan emits `DcaBuySkipped(InactivePlan)`.

### Pending request (reactive)

```
   no pending ── eligible tick ──▶ pending(plan, tick, since)
        ▲                                      │
        │                                      ├── DcaBuy(tick) ────────▶ clear, update mirror
        │                                      ├── DcaBuySkipped(tick) ──▶ clear
        │                                      ├── block.timestamp > since + timeout
        │                                      │      └─▶ clear, emit PendingExpired,
        │                                      │          re-evaluate the same tick
        │                                      └── owner clearPending
        └──────────────────────────────────────────────────────────────────
```

One pending request per plan prevents a fast price move from flooding the callback proxy. The timeout is the liveness fallback; a late callback for the same tick is still safe because the vault's `lastTickId` rejects it.

## 5. Events and topics

| Event | Emitter | Indexed | Data | Used by |
|---|---|---|---|---|
| `PriceTick(uint256,uint256,uint256)` | `PriceFeed` | `tickId` | `price, timestamp` | reactive price subscription |
| `DcaPlanCreated(uint256,address,uint256,uint256,uint256,uint256,uint256)` | `DcaVault` | `planId, owner` | `basePerBuy, drawdownBps, cooldown, maxBuys, quoteBudget` | reactive plan mirror |
| `DcaPlanBudgetIncreased(uint256,uint256,uint256)` | `DcaVault` | `planId` | `added, newBudget` | reactive budget mirror |
| `DcaPlanCancelled(uint256,uint256)` | `DcaVault` | `planId` | `refund` | reactive deactivation |
| `DcaBuy(uint256,uint256,uint256,uint256,uint256)` | `DcaVault` | `planId, tickId` | `quoteIn, baseOut, price` | reactive confirmation, evidence |
| `DcaBuySkipped(uint256,uint256,uint8,uint256)` | `DcaVault` | `planId, tickId` | `reason, price` | reactive pending clear, monitoring |

`DcaReactive` hard-codes the topic0 hashes as public constants (`PRICE_TICK_TOPIC0`, `PLAN_CREATED_TOPIC0`, ...). The tests deliver real logs from the vault into `react()`, so a signature drift fails the suite.

Skip reasons:

| Value | Reason | Meaning |
|---:|---|---|
| 0 | `None` | unused |
| 1 | `Paused` | vault owner paused buys |
| 2 | `UnknownPlan` | no plan with this id |
| 3 | `InactivePlan` | cancelled plan |
| 4 | `StaleTick` | `tickId <= plan.lastTickId` |
| 5 | `StalePrice` | tick older than `maxPriceAge` |
| 6 | `MaxBuys` | `buys >= maxBuys` |
| 7 | `Cooldown` | less than `cooldown` since the last buy |
| 8 | `NotDipped` | price not `drawdownBps` below the last buy |
| 9 | `BudgetExceeded` | exact quote cost exceeds the remaining budget |
| 10 | `InsufficientReserve` | WETH reserve below `basePerBuy` |

A skip is a successful callback: the proxy does not revert, the reactive sees `DcaBuySkipped`, and funds stay where they were. An invalid callback (unauthorised caller or price mismatch) reverts; the reactive's pending timeout covers a dropped revert.

## 6. Accounting

The vault tracks four quote buckets:

| Bucket | Meaning |
|---|---|
| `quoteBalance[user]` | unallocated, withdrawable at any time |
| `totalUnallocated` | sum of all unallocated balances |
| `totalPlanRemaining` | sum of `quoteBudget - quoteSpent` across active plans |
| `quoteReserve` | quote received from executed buys (protocol revenue) |

Invariant:

```
mUSDC.balanceOf(vault) == totalUnallocated + totalPlanRemaining + quoteReserve
```

Base side:

```
mWETH.balanceOf(vault) == baseReserve
```

The vault moves no quote tokens on a buy: the quote was already in the vault; the buy converts `totalPlanRemaining` into `quoteReserve` and sends the fixed WETH amount from `baseReserve` to the user. A cancel moves `quoteBudget - quoteSpent` from `totalPlanRemaining` to `totalUnallocated`. A withdrawal moves from `totalUnallocated` to the user. The tests assert both invariants after deposits, plan creation, buys, cancels, reserve withdrawals, and pause/unpause.

## 7. Price and decimal handling

The feed reports USD per base token with 8 decimals. The vault reads the token decimals at construction (both must be ≤ 18) and stores `quoteScale = 10^quoteDecimals`, `baseScale = 10^baseDecimals`. The quote cost is:

```
numerator   = basePerBuy * price * quoteScale
denominator = 1e8 * baseScale
quoteIn     = (numerator + denominator - 1) / denominator   // round up
```

For mUSDC (6) / mWETH (18) at $2,000 and 0.01 WETH:

```
numerator   = 1e16 * 2e11 * 1e6 = 2e33
denominator = 1e8 * 1e18        = 1e26
quoteIn     = 2e7               = 20 USDC
```

`MAX_BASE_PER_BUY = 1e24` and `PriceFeed.MAX_PRICE = 1e30` keep the product far below `uint256` overflow. The public `quoteFor` view is also fuzz-tested for the round-up property.

## 8. Failure modes

| Failure | Effect | Recovery |
|---|---|---|
| Price feed stops publishing | No ticks, no new buys. Funds remain in the vault. | User cancels and withdraws; owner can rotate the publisher. |
| Reactive contract stops / runs out of lREACT | No new callbacks. The vault is unchanged. | Fund the reactive (`depositTo`), or cancel/withdraw. Missed callbacks can be retried after the timeout. |
| Callback proxy drops a callback | The reactive's pending marker stays until `callbackTimeout`; no funds move. | `retry(planId)` after the timeout, or cancel/withdraw. |
| Callback reverts on the destination | Same as a drop; the pending marker times out. | Retry or cancel. |
| Vault paused | `executeBuy` emits `DcaBuySkipped(Paused)`; new plans/deposits blocked; withdrawals/cancel work. | Owner unpauses. |
| Reactive paused | No new requests; price/HWM tracking continues. | Owner unpauses. |
| Budget exhausted | Vault emits `DcaBuySkipped(BudgetExceeded)`; no tokens move. | `fundPlan` adds budget; the reactive mirrors `DcaPlanBudgetIncreased`. |
| WETH reserve too low | Vault emits `DcaBuySkipped(InsufficientReserve)`; no tokens move. | Owner `depositBaseReserve`. |
| Stale price / old tick | Vault emits `DcaBuySkipped(StalePrice)`; no tokens move. | Wait for a fresh tick; retry. |
| Replay of a tick | Vault emits `DcaBuySkipped(StaleTick)`; reactive ignores duplicate `DcaBuy`. | None needed. |
| Price mismatch | Vault reverts `PriceMismatch`; no tokens move. | The callback is invalid; investigate the reactive/feed. |

## 9. Gas and scaling

- The reactive scans every mirrored plan on every price tick: `O(plans)`, capped at 32. With a handful of plans this is cheap on Lasna; the cap keeps the loop bounded. Production would shard plans across multiple reactive contracts or use a cursor.
- A buy callback is a token transfer plus about a dozen storage reads/writes. The requested gas limit is 600,000. For reference, `docs/test-output.txt` reports 638,603 gas for the entire `test_executeBuyHappyPath` scenario, which includes the plan deposit/creation, the reserve deposit, the oracle tick and the buy itself (the token mints are in `setUp` and are not counted); the callback is a subset of that. The deploy script can raise the limit with `setBuyGasLimit` up to 2,000,000.
- The vault uses `via_ir = false`; the contracts are small. `forge test` compiles in a few seconds.

## 10. Trust model

| Actor | Trusted for | Not trusted for |
|---|---|---|
| Vault owner | Pause, reserve funding, max price age, ownership | Moving user budget without a plan/cancel; bypassing callback auth |
| Reactive contract | Trigger logic, first-buy high-water mark, liveness | Price (vault checks the feed), budget (vault computes exact cost), reserve (vault checks), replay (vault checks tick) |
| Price feed publisher | Publishing observations | Choosing the DCA rule; the vault binds the callback to a stored tick |
| Plan owner | Choosing the plan and funding it | Executing arbitrary transfers; the vault only sends the fixed `basePerBuy` to the plan owner |

The vault owner is a testnet demo key. A production deployment would put pause/reserve controls behind a multisig or timelock, and the price feed behind a decentralized oracle.
