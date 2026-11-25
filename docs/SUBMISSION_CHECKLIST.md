# Submission checklist

Deadline: **2026-12-05 20:00 UTC**. Submit at <https://dorahacks.io/hackathon/reactive-omni-buildathon>.

> **This repository is pre-deployment.** Every `________` below is a placeholder.
> Do not submit until the orchestrator has run `deploy/deploy.sh`, created the
> demo plan, published the story, and replaced every placeholder with a real
> address or transaction hash. Never invent a hash; every row must open on the
> right explorer with status success.

## 1. Form fields

| Field | Value |
|---|---|
| Build name | **DCA Autopilot — set-and-forget dip buyer** |
| Track | **Set It and Forget It** (one track only) |
| Short description | A reactive DCA vault: deposit USDC, set a fixed WETH amount and a 5% drawdown, and a Reactive contract on Lasna buys the dip on Sepolia within a cooldown, max-buy and budget. The vault authenticates every callback and keeps unspent budget withdrawable. |
| GitHub | public repo URL, `main` branch, commit `________` |
| Demo video | URL, duration `__:__` (< 3:00) |
| Contract addresses | mUSDC `________`, mWETH `________`, feed `________`, reactive `________`, vault `________` |
| Transaction hashes | see the evidence table below |
| Team | solo |
| Country | Moldova (no restriction published) |

## 2. Evidence table

Fill after `./deploy/deploy.sh`, `./demo/setup_plan.sh`, and `./demo/publish.sh --story`. The deploy script writes most deployment/setup hashes to `deployments/latest.json`; `deployments/demo-latest.json` has the plan setup hashes.

| # | Step | Chain | Tx hash | Explorer |
|---:|---|---|---|---|
| 1 | Deploy mUSDC | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 2 | Deploy mWETH | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 3 | Deploy PriceFeed | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 4 | Deploy DcaReactive | Reactive Lasna | `________` | `https://lasna.reactscan.net/tx/________` |
| 5 | Deploy DcaVault | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 6 | `setVault` | Reactive Lasna | `________` | `https://lasna.reactscan.net/tx/________` |
| 7 | Fund reactive (lREACT) | Reactive Lasna | `________` | `https://lasna.reactscan.net/tx/________` |
| 8 | Fund vault callback reserve | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 9 | Mint mUSDC + `depositQuote` | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 10 | `createPlan` → `DcaPlanCreated` | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 11 | `depositBaseReserve` | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 12 | Origin `PriceTick` (calm, 2020) | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 13 | Origin `PriceTick` (first dip, 1910) | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 14 | Reactive tx → `executeBuy` callback | Reactive Lasna | `________` | `https://lasna.reactscan.net/tx/________` |
| 15 | `executeBuy` callback | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 16 | First `DcaBuy` event | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 17 | Second buy (after cooldown) | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |
| 18 | Max-buy tick 1400 (no `DcaBuy`; reactive stops) | Ethereum Sepolia | `________` | `https://sepolia.etherscan.io/tx/________` |

The minimum the form asks for is "a few transaction hashes showing the full loop, from origin event to callback". Rows **12–16** are the irreducible set; rows 1–11 prove deployment and plan setup; row 17 shows the repeatable automation. Row 18 is a `PriceTick` at 1400; the evidence is that **no** `DcaBuy` follows it. The vault's `MaxBuys` skip path itself is covered by `test_executeBuyMaxBuysSkips`.

`docs/DEPLOY_RUNBOOK.md` §7 lists the exact explorer checks. The tx page for row 15 should show an `executeBuy` call whose first decoded argument is the reactive address (injected by the proxy) and whose `DcaBuy` log has the matching `planId`, `tickId`, `quoteIn`, `baseOut` and price.

## 3. Repository checklist

- [ ] Public and open source (MIT `LICENSE` present)
- [ ] `README.md` has the architecture, addresses, tx hashes, test output, limitations
- [ ] `deployments/latest.json` committed with the real addresses and deploy txs
- [ ] `deployments/demo-latest.json` committed with the plan id and setup txs
- [ ] No `.env`, private keys, seed phrases, API keys, or `deploy/config.env`
- [ ] No `out/`, `cache/`, `.venv/`, `__pycache__/`
- [ ] `forge test` is green on a clean clone
- [ ] `./demo/local_demo.sh` passes on a clean clone (with Python deps)
- [ ] README quickstart works from a clean clone
- [ ] Commit is tagged or the commit hash is recorded
- [ ] The README's status section says "deployed" only after the real deployment

## 4. Judging evidence map

| Criterion | Where the judge sees it |
|---|---|
| **Execution** | Rows 12–16 show the origin event, the reactive transaction, the callback, and the `DcaBuy` event. `forge test` reproduces the same loop deterministically, including the Sepolia-path suite. |
| **Integration** | `DcaReactive` mirrors plans from vault events, tracks the high-water mark, evaluates drawdown/cooldown/max/budget, requests the callback, consumes `DcaBuy`/`DcaBuySkipped`, and handles pending timeouts. The vault's `lastTickId` and last-buy drawdown are independent checks. |
| **Usefulness** | A real DCA rule a user can leave running: fixed base amount, drawdown, cooldown, max buys, total budget, pause, and a refund path. The demo shows five buys and a max-buy stop. |
| **Craft** | 62 unique tests (124 executions on two chain fixtures), accounting invariants, a deploy dry-run with binding verification, a local Anvil rehearsal with real log relaying, a monitor, a runbook with failure modes, and a 2:30 shot list. |

## 5. Video checklist

- [ ] < 3:00 (hard limit; target 2:30)
- [ ] Shows the origin `PriceTick` → reactive Lasna tx → callback → `DcaBuy`
- [ ] Shows the plan parameters (0.01 WETH, 5%, 30 s, 5 buys, 200 USDC)
- [ ] Shows the first buy and the max-buy stop
- [ ] Shows a cancel/refund or the missed-callback test
- [ ] No keys, `deploy/config.env`, or personal data on screen
- [ ] Public or unlisted URL that works in incognito
- [ ] All shown hashes match the evidence table

## 6. Final pre-submit checks

- [ ] `curl -s <repo-url>` returns 200 in a logged-out browser
- [ ] The commit on GitHub is the one that was tested
- [ ] Addresses on the form match `deployments/latest.json`
- [ ] The plan id on the form matches `deployments/demo-latest.json`
- [ ] Every tx hash opens on the right explorer and has status success
- [ ] The vault's `accountedQuote()` equals its mUSDC balance; `baseReserve()` equals its mWETH balance
- [ ] The video URL opens in incognito
- [ ] Track is **Set It and Forget It**, not a second track
- [ ] Deadline buffer: submit by **2026-12-04 20:00 UTC**, 24 h early
- [ ] If DoraHacks shows a CAPTCHA after the consent checkbox, stop and hand off to the human; never solve or outsource it

## 7. If deployment is blocked

The entry fails the Execution gate without on-chain evidence. Do not submit a repo-only build as a Set It and Forget It entry. Options, in order:

1. Claim Sepolia ETH from the free PoW faucet (<https://sepolia-faucet.pk910.de/>), send 0.01 SepETH to the Reactive faucet, and deploy with `ORIGIN_CHAIN=sepolia` (preferred; $0).
2. Ask the organizer in the DoraHacks Q&A whether a Lasna-only or local trace is acceptable (unlikely; the page requires deployed addresses and tx hashes).
3. Withdraw rather than submit an entry that cannot be scored.

## 8. What is intentionally not done in this repository

- No public deployment, no addresses, no transaction hashes.
- No DoraHacks build, no registration, no submission.
- No GitHub push; the orchestrator reviews and pushes.
- No demo video; `docs/DEMO_SCRIPT.md` is the shot list for it.
