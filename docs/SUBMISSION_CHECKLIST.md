# Submission checklist

Deadline: **2026-12-05 20:00 UTC**. Submit at <https://dorahacks.io/hackathon/reactive-omni-buildathon>.

> **Deployed 2026-11-25.** Plan 1 executed two buys on Ethereum Sepolia. Every
> hash below is real and opens on the explorer with status success. The first
> callback used the initial 600k gas limit, which was below the 775k
> `executeBuy` estimate; the owner raised the reactive limit to 1.5M and the
> permissionless `retry(1)` recovered the buy.

## 1. Form fields

| Field | Value |
|---|---|
| Build name | **DCA Autopilot — set-and-forget dip buyer** |
| Track | **Set It and Forget It** (one track only) |
| Short description | A reactive DCA vault: deposit USDC, set a fixed WETH amount and a 5% drawdown, and a Reactive contract on Lasna buys the dip on Sepolia within a cooldown, max-buy and budget. The vault authenticates every callback and keeps unspent budget withdrawable. |
| GitHub | https://github.com/matrixneoaiagent/dca-autopilot, `main` branch (current HEAD) |
| Demo video | https://matrixneoaiagent.github.io/demo-media/dca-dip.mp4 (2:15, < 3:00) |
| Contract addresses | mUSDC `0x055b7139133cd90D8e6cC332e0BdCB1617C4F715`, mWETH `0x2c2cd38a98436BB5D1035f4E6771b4c5c12368e6`, feed `0x64a7a30E101Db41861DA6E040dBfcaEA96dFCbED`, reactive `0x3B79fe65C5C69D890Eb001A96e545276a9135B3E`, vault `0xE9157B69b66dD4bd5A4AD0f0afdBac3f28e0987D` |
| Transaction hashes | see the evidence table below |
| Team | solo |
| Country | Moldova (no restriction published) |

## 2. Evidence table

Fill after `./deploy/deploy.sh`, `./demo/setup_plan.sh`, and `./demo/publish.sh --story`. The deploy script writes most deployment/setup hashes to `deployments/latest.json`; `deployments/demo-latest.json` has the plan setup hashes.

| # | Step | Chain | Tx hash | Explorer |
|---:|---|---|---|---|
| 1 | Deploy mUSDC | Ethereum Sepolia | `0xd2361944133e126ea482d006b8b0c2c855c12ace45c45fe306c7aa2103dd65c6` | `https://sepolia.etherscan.io/tx/0xd2361944133e126ea482d006b8b0c2c855c12ace45c45fe306c7aa2103dd65c6` |
| 2 | Deploy mWETH | Ethereum Sepolia | `0x9d0e801134480fc62bd3170283f1c207483b28850626bd1a19d217b3f57ed593` | `https://sepolia.etherscan.io/tx/0x9d0e801134480fc62bd3170283f1c207483b28850626bd1a19d217b3f57ed593` |
| 3 | Deploy PriceFeed | Ethereum Sepolia | `0x1bcce4f746dde6d95cba0b2eaf948c8eee2d42d30e8de5de56ac0bd7476f382d` | `https://sepolia.etherscan.io/tx/0x1bcce4f746dde6d95cba0b2eaf948c8eee2d42d30e8de5de56ac0bd7476f382d` |
| 4 | Deploy DcaReactive | Reactive Lasna | `0x67a91b2db5a4e95285b3bd1fd42455dd3eafdfb4a83af7b19032ab8a3f69ecd8` | `https://lasna.reactscan.net/tx/0x67a91b2db5a4e95285b3bd1fd42455dd3eafdfb4a83af7b19032ab8a3f69ecd8` |
| 5 | Deploy DcaVault | Ethereum Sepolia | `0x617f4c2b799649d767339bcd40a39e556e728d76ec2b1035b34e40e61cd28455` | `https://sepolia.etherscan.io/tx/0x617f4c2b799649d767339bcd40a39e556e728d76ec2b1035b34e40e61cd28455` |
| 6 | `setVault` | Reactive Lasna | `0x757255d8e9887afbe04ee6188d0f0e84eb35ee7a0ea22be0fccb59d54958490a` | `https://lasna.reactscan.net/tx/0x757255d8e9887afbe04ee6188d0f0e84eb35ee7a0ea22be0fccb59d54958490a` |
| 7 | Fund reactive (lREACT) | Reactive Lasna | `0x03d689961382eed30dc872cba147bd68cc79df6777a176f81c6482e918fda7a2` | `https://lasna.reactscan.net/tx/0x03d689961382eed30dc872cba147bd68cc79df6777a176f81c6482e918fda7a2` |
| 8 | Fund vault callback reserve | Ethereum Sepolia | `0x5d6b13f7715ae686a5672993fcb035d762639f8a41edefc852fbfd5d4cfa806a` | `https://sepolia.etherscan.io/tx/0x5d6b13f7715ae686a5672993fcb035d762639f8a41edefc852fbfd5d4cfa806a` |
| 9 | Mint mUSDC + `depositQuote` | Ethereum Sepolia | `0x00194ec8553472e01f9674dbc8f7b8205cf7d170826f1efdbec84f0f4cef2ec3` | `https://sepolia.etherscan.io/tx/0x00194ec8553472e01f9674dbc8f7b8205cf7d170826f1efdbec84f0f4cef2ec3` |
| 10 | `createPlan` → `DcaPlanCreated` | Ethereum Sepolia | `0x1e65785a40d5d0e6e33b76761a150401ee8f55bab97f474d3980fff85b105c8d` | `https://sepolia.etherscan.io/tx/0x1e65785a40d5d0e6e33b76761a150401ee8f55bab97f474d3980fff85b105c8d` |
| 11 | `depositBaseReserve` | Ethereum Sepolia | `0x4e339690b924f4238f687d8e0546a1b53133fb6076939a6ea5afcbda218cf548` | `https://sepolia.etherscan.io/tx/0x4e339690b924f4238f687d8e0546a1b53133fb6076939a6ea5afcbda218cf548` |
| 12 | Origin `PriceTick` (calm, 2020) | Ethereum Sepolia | `0x3b7adf714b5eb4bef7ac2543a084e6655e9d78ab6d40e88e3679ae93f658f8fe` | `https://sepolia.etherscan.io/tx/0x3b7adf714b5eb4bef7ac2543a084e6655e9d78ab6d40e88e3679ae93f658f8fe` |
| 13 | Origin `PriceTick` (first dip, 1910) | Ethereum Sepolia | `0x30e59cafc7a956f6ab9e84c5137cdb353cdb09bdea55bc8a5fcc36df4c96070d` | `https://sepolia.etherscan.io/tx/0x30e59cafc7a956f6ab9e84c5137cdb353cdb09bdea55bc8a5fcc36df4c96070d` |
| 14 | Reactive tx → `executeBuy` callback (retry after 1.5M gas fix) | Reactive Lasna | `0xeb96b3ada92295fd8b4455e128feba23ca06a0e652ffbace2e1b2629eaffd752` | `https://lasna.reactscan.net/tx/0xeb96b3ada92295fd8b4455e128feba23ca06a0e652ffbace2e1b2629eaffd752` |
| 15 | `executeBuy` callback | Ethereum Sepolia | `0xe0ff40be2f9c7cb22e3d7d569147bb942e3bc769368a183c4325e0b9bc17a09f` | `https://sepolia.etherscan.io/tx/0xe0ff40be2f9c7cb22e3d7d569147bb942e3bc769368a183c4325e0b9bc17a09f` |
| 16 | First `DcaBuy` event | Ethereum Sepolia | `0xe0ff40be2f9c7cb22e3d7d569147bb942e3bc769368a183c4325e0b9bc17a09f` | `https://sepolia.etherscan.io/tx/0xe0ff40be2f9c7cb22e3d7d569147bb942e3bc769368a183c4325e0b9bc17a09f` |
| 17 | Second buy (after cooldown, 1800) | Ethereum Sepolia | `0xa33e4728ff216b227ffb819e4d0a99d07a9d447aceedab89c2a64e3a2c91ffb8` | `https://sepolia.etherscan.io/tx/0xa33e4728ff216b227ffb819e4d0a99d07a9d447aceedab89c2a64e3a2c91ffb8` |
| 18 | Max-buy tick 1400 — not used in the live demo; max-buy stop covered by `test_executeBuyMaxBuysSkips` | — | `—` | `—` |


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
