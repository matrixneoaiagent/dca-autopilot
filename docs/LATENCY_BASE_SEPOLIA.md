# Every Second Counts — DCA Autopilot on Base Sepolia

This is the latency demo for the **Every Second Counts** track: the same DCA
Autopilot, deployed on **Base Sepolia (chain 84532, 200 ms blocks since the
Denim upgrade)** with the reactive contract on **Reactive Lasna (5318007)**.

The point of the track is the loop, not the DCA rule: a `PriceTick` event on
Base Sepolia travels to Reactive Lasna, the reactive contract decides that the
drawdown rule is met, and it requests an `executeBuy` callback back on Base
Sepolia. No keeper, no off-chain bot.

## Live deployment (2026-11-25)

| Contract | Address |
|---|---|
| mUSDC (Base Sepolia) | `0x78c4Fca284cd36408d5395ABfA738B9CAd7A6aec` |
| mWETH (Base Sepolia) | `0x790e35eF3F2aCA3Bec0418fBe14973CDC80F89D9` |
| PriceFeed (Base Sepolia) | `0x89A289d29f1909dA0f6d8b0d6E002e49098Bcb39` |
| DcaReactive (Reactive Lasna) | `0x44F8aAA4F98B7Aa04EebeBCf7d43d622aAaa9334` |
| DcaVault (Base Sepolia) | `0xf8D0a3e80524D4f9B63c67e6153Ba45637dFb518` |
| Callback proxy (Base Sepolia) | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |

Deployment txs: `0x74772ff3…` (mUSDC), `0x1ae39c80…` (mWETH), `0x8b50e5a5…`
(feed), `0xec3e283d…` (reactive), `0x8ebe7669…` (vault), `0x3d7b49e5…`
(setVault), `0xa7017f55…` (fund reactive), `0x7ded8d69…` (fund vault).
Full record: `deployments/base-sepolia-20261125T212225Z.json`.

Plan 1: 0.01 mWETH per buy, 5% drawdown, 30 s cooldown, 5 max buys, 200 mUSDC
budget, 2 mWETH reserve. The reactive mirrored the plan (`planCount == 1`)
immediately after `createPlan`.

## Measured full-loop latency

Method: the script sends the `PriceTick` transaction, then polls the vault's
`DcaBuy` logs every 200 ms. The number is wall-clock from the tick send to the
first observed `DcaBuy`; it therefore includes the Base Sepolia inclusion
(~0.41 s send-to-receipt), the Lasna reactive inference, and the callback
inclusion.

| Step | Tick 3 (1900) | Tick 4 (1800) |
|---|---:|---:|
| Origin tick tx | `0x1c629b3e146a4c3b8312c192ef29b4c6de778832719f2eb843f2eaa7d27a0db5` | `0xe65aca160d071af0f4601a0f82150ddc62843486cbfe642e156811549f870c39` |
| Origin block | 63,599,734 | 63,599,905 |
| `DcaBuy` tx | `0xdfe222c8179c04732dc7d7b19a18804e7e6d0536af536b6b5b74e141da98601f` | `0xee9a7e2d5b3d2211adb54b263308ea956ad2abd6a2e254a5e5c76f9301ca222c` |
| `DcaBuy` block | 63,599,739 | 63,599,910 |
| Buy | 0.01 WETH for 19.00 USDC @ 1900 | 0.01 WETH for 18.00 USDC @ 1800 |
| **Full-loop latency** | **1.94 s** | **1.82 s** |

The first buy used the high-water mark (2000) as the reference; the second used
the last buy price (1900). Both callbacks were authenticated by the vault
(callback proxy + injected reactive address) and bound to the oracle price in
`PriceFeed.priceOf(tickId)`.

## Why this needs Reactive Omni

The trigger is an on-chain event and the callback is an on-chain transaction.
There is no server to poll, no keeper key, and no trust in an off-chain bot. On
Base Sepolia's 200 ms blocks the origin inclusion is ~0.4 s; Reactive Lasna adds
the inference and the callback, and the measured loop is under 2 s. A cron job
or a keeper would add a polling interval and an external key to the same rule.

## Reproduce

```bash
cd dca-autopilot
# the deployment is already live on Base Sepolia + Lasna
python3 demo/monitor.py --watch
# publish a new tick through the feed (owner key)
# the reactive decides and the vault emits DcaBuy
```

The deploy/setup scripts support `ORIGIN_CHAIN=base-sepolia`; the config used
here is `deploy/config.base.env`. The contracts and tests are the same Solidity
as the Ethereum Sepolia entry (`github.com/matrixneoaiagent/dca-autopilot`).

## Limits

Mock mUSDC/mWETH and a publisher oracle, as in the main entry. The latency is a
testnet measurement; Base Sepolia's 200 ms block time is a Denim feature and
Reactive Lasna is a testnet. The measurement is wall-clock from a Python client
on one host, not an instrumented validator.

## Lasna reactive transactions (the missing half of the loop)

The `DcaBuy` transactions above are the destination callbacks. The reactive
transactions that requested them are on Lasna (chain 5318007), sent to the
system contract `0x8888…8888`, both status 1, each emitting the reactive
contract's `BuyRequested` event and the system `CallbackRequest`:

| Buy | Lasna tx | Block | Lasna time (UTC) | DcaBuy (Base Sepolia) |
|---|---|---|---|---|
| #1 | `0xda619dad093fb069225322170c191b59bd23ab3e25b6386d76aa663f2a16c05a` | 9,246,624 | 21:23:34 | `0xdfe222c8…` at 21:23:37 |
| #2 | `0xb59af50744295b1b85b468dae3f333383f8abe7143864bdf46359b4794c66b71` | 9,246,655 | 21:24:09 | `0xee9a7e2d…` at 21:24:11 |

Ordering (block timestamps on the two chains can differ by about a second): the 1900 tick
was included on Base Sepolia at 21:23:35, the Lasna reactive transaction emitted
`BuyRequested(planId=1, tickId=3, price=1900)` at 21:23:34 Lasna time and the `DcaBuy`
callback landed at 21:23:36. For buy #2: the 1800 tick at 21:24:09, the Lasna
`BuyRequested` at 21:24:09 and the `DcaBuy` callback at 21:24:10. The 1.94 s figure is measured wall-clock from the client's tick send to the
first observed `DcaBuy`, so it includes the origin inclusion, the Lasna
inference and the callback inclusion.

