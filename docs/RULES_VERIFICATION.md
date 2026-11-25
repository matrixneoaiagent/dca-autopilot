# Rules, network and cost verification

Checked **2026-11-25 ~10:30–11:00 UTC** against the live DoraHacks page
(<https://dorahacks.io/hackathon/reactive-omni-buildathon/detail> and
`/tracks`) and the official Reactive docs. No account was created, no wallet
was connected, nothing was deployed or submitted by this build session.

## 1. Event

| Item | Verified value | Source |
|---|---|---|
| Event | Reactive Omni Buildathon | DoraHacks detail page |
| Organizer | Reactive Network (DoraHacks org 2445) | same |
| Window | 2026-11-05 12:00 → **2026-12-05 20:00 UTC** | detail page timeline |
| Prize pool | **$5,500, paid in REACT** | detail page |
| Field at check | **167 builds**, 386 hackers | detail page tabs |
| Entry fee | none stated; **$0** | detail page |
| KYC | **no KYC clause published** | detail page + tracks page |
| Format | virtual | detail page |

Exact text:

> "From **November 5th** to **December 5th**, we're running a month-long buildathon to put **Reactive Omni** through its paces, with **$5,500 in prizes, paid in REACT**, across three tracks."

## 2. Track — Set It and Forget It

Prize: **$2,000 for the first place, $250 for the runner-up**.

Exact brief:

> "*Build something useful for yourself, on any supported chain*
>
> Open to anyone, including people who've never written a contract and are building with AI coding tools. The brief is simple: build a reactive contract that solves a problem for you. Latency matters less here than usefulness.
>
> **Ideas**
> - A portfolio tracker
> - An alert when a liquidity position hits a price
> - Custom rebalancing rules
> - An automation nobody's thought of yet
>
> **What we're looking for**
> - A tool you'd actually keep running
> - A clear personal purpose
> - A creative take on event-driven logic
>
> **Network:** Reactive mainnet/Lasna testnet, with any supported chain"

DCA Autopilot is a personal dip-buying rule: deposit a quote budget, set a fixed base amount, a drawdown, a cooldown, a max-buy count and a total budget. The reactive contract watches the price and executes the plan; the vault makes the rule safe. The personal purpose is explicit: "I want to buy my chosen dip without watching charts or running a keeper."

## 3. Judging

> "Every entry is scored from 1 to 5 on four equally weighted criteria:
> **Execution:** Does it run? We want to see the reactive transactions and the callbacks they trigger on-chain. Entries without them aren't scored further.
> **Integration:** Does the reactive contract do real work, or is it bolted on? Each track's brief says what this means there.
> **Usefulness:** Does it solve a problem real users have?
> **Craft:** Readable code, a working demo, and documentation someone else could follow."

Consequence: a repository plus a local Foundry test is not enough. The entry needs public testnet addresses and transaction hashes for the full loop. That is why `docs/SUBMISSION_CHECKLIST.md` has an evidence table and the deploy runbook is explicit. This session intentionally did not deploy; the orchestrator will.

## 4. Submission requirements

> "Submit your build on this page with:
> - A link to your public repository
> - Deployed contract addresses
> - A few transaction hashes showing the full loop, from origin event to callback
> - A demo video under three minutes"

DoraHacks also flags "GitHub/Gitlab/Bitbucket Link Required" and "Demo Video Required".

## 5. Ground rules

> "Repositories need to be **public** and **open-source** by the time you submit."
>
> "Everything should be built during the event. Prior work can come in as a dependency, but not as the submission itself."
>
> "Base Sepolia now produces blocks every 200ms, so use timestamps rather than block counts for any timers, cooldowns, or deadlines there."

DCA Autopilot was written for this event. Its only Solidity dependencies are `reactive-lib-omni` and `forge-std`; the demo tooling uses `web3.py`. Cooldowns and the callback timeout use `block.timestamp`, not block counts.

## 6. Network

The page allows "Reactive mainnet/Lasna testnet". This build uses the **testnet pair**:

| Role | Network | Chain ID | Contract |
|---|---|---|---|
| Origin + destination (default) | Ethereum Sepolia | 11155111 | callback proxy `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4` |
| Origin + destination (alternative) | Base Sepolia | 84532 | callback proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |
| Reactive | Reactive Lasna | 5318007 | system `0x8888888888888888888888888888888888888888` |

`ORIGIN_CHAIN=sepolia|base-sepolia` selects the pair. The reactive contract receives the matching chain id and callback proxy at deployment; the tests run the whole suite on both fixtures.

Official docs:

> "Reactive Mainnet and Lasna Testnet share the same system contract address: `0x8888888888888888888888888888888888888888`"
>
> "Origin is the chain where events originate... Mainnets and testnets must not be mixed: if the origin is a testnet, the destination must also be a testnet."

### Faucet

> "To obtain testnet lREACT, send Sepolia ETH to one of the faucet contracts:
> **Ethereum Sepolia:** `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`
> **Base Sepolia:** `0x2afaFD298b23b62760711756088F75B7409f5967`
> Exchange rate: **1 ETH → 100 lREACT**."
>
> "Don't send more than 5 ETH per transaction."

The only asset needed is testnet ETH, which is free from public faucets. **0.01 SepETH → 1 lREACT** is enough; keep the rest for gas.

## 7. Cost

| Item | Cost |
|---|---|
| Entry fee | **$0** |
| Ethereum Sepolia ETH (deploy + callbacks + demo ticks) | **$0** — public/PoW faucet |
| lREACT (reactive gas) | **$0** — 1:100 from Sepolia ETH |
| Mainnet deployment | **not required** |
| Purchase / stake / deposit | **none** |

No mainnet gas and no purchase is required. This is a testnet-only entry.

## 8. What could not be verified

- **Track enforcement on the form.** The rules do not say whether one build may enter multiple tracks. This entry is for **Set It and Forget It** only.
- **KYC at payout.** None is published, but DoraHacks or Reactive may screen winners before paying REACT. Registration was not attempted, so this is unknown.
- **Judging and results dates.** Not published on the detail page.
- **Whether Lasna deployments are prize-eligible.** The track explicitly lists "Reactive mainnet/Lasna testnet", which is the best available evidence; the prize currency is mainnet REACT regardless.
- **Exact build count.** The page reported 167 builds but the build list is hidden ("The organizer is reviewing Builds"), so quality and overlap cannot be assessed.
- **Faucet availability.** The Sepolia PoW faucet was not exercised by this session. Public faucets change requirements; confirm the claim before deploying.
- **DoraHacks WAF.** The public pages loaded normally on 2026-11-25; submission/edit endpoints have shown WAF challenges in November. The submit step may require a human browser session.

## 9. How the build maps to the criteria

| Criterion | Evidence in this repository |
|---|---|
| **Execution** | `test/E2E.t.sol` and `test/SepoliaPath.t.sol` run the full origin tick → reactive → callback → vault loop with a mock system and the official Sepolia proxy address. The deploy script produces the public transactions; the checklist has the evidence table. |
| **Integration** | The reactive contract does the plan mirroring, high-water tracking, drawdown/cooldown/max/budget pre-checks, callback request, buy confirmation and pending timeout. It is not a pass-through: the vault's `DcaBuy` events drive its state. |
| **Usefulness** | A set-and-forget DCA rule with a fixed base amount, drawdown, cooldown, max buys and a total budget — the exact controls a dip buyer needs. Unspent budget is always withdrawable; a missed callback never loses funds. |
| **Craft** | 62 unique tests (124 executions across both chain fixtures), accounting invariants, a deploy dry-run with binding verification, a local Anvil rehearsal with real log relaying, a terminal dashboard, and a runbook with failure modes. |

## 10. Live protocol checks performed

- Lasna RPC `eth_chainId` → `5318007`.
- Ethereum Sepolia RPC `eth_chainId` → `11155111`.
- Base Sepolia RPC `eth_chainId` → `84532`.
- System contract code present at `0x8888…8888` on Lasna; callback proxy code present at `0xAa14…23b4` on Ethereum Sepolia and `0x476F…3585` on Base Sepolia.
- The established callback authentication pattern (proxy + reactive address in the first payload word) is reproduced from the live Sentinel deployment and verified in the Foundry mock. The DCA build itself has **not** been deployed; no transaction hash in this repository is presented as live evidence.
