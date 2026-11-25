# Test matrix

Every row below is a real Foundry test in this repository. The suite is run twice: once with the Base Sepolia fixture and once with the Ethereum Sepolia fixture (`test/SepoliaPath.t.sol`). `forge test` reports **124 passing executions, 0 failed** (62 unique tests × 2 fixtures; the fuzz test runs 256 cases per fixture).

| Requirement | Tests |
|---|---|
| Plan creation and parameters | `test_createPlanAllocatesBudget`, `test_createPlanEmitsEvent`, `test_createPlanRejectsBadParams`, `test_createPlanRejectsInsufficientBudget`, `test_createPlanPlanLimit`, `test_constructorWiring` |
| Budget | `test_executeBuyBudgetSkips`, `test_budgetExhaustedPreventsTrigger`, `test_fundPlanIncreasesBudget`, `test_cancelPlanRefundsUnspent`, `test_accountingInvariantAcrossLifecycle` |
| Cooldown | `test_executeBuyCooldownSkips`, `test_cooldownPreventsTrigger` |
| Drawdown trigger | `test_firstBuyUsesHighWater`, `test_drawdownTriggersCallback`, `test_executeBuyHappyPath`, `test_planCreatedMirror` |
| No-trigger cases | `test_noTriggerAboveThreshold`, `test_executeBuyNotDippedSkips`, `test_executeBuyInsufficientReserveSkips`, `test_executeBuyStalePriceSkips` |
| Unauthorized callback | `test_executeBuyUnauthorizedReverts` |
| Pause / unpause | `test_executeBuyPausedSkipsAndWithdrawalsWork`, `test_pauseOnlyOwner`, `test_pauseStopsTriggers` |
| Double-execution protection | `test_executeBuyStaleTickSkips`, `test_pendingBlocksDuplicateRequest`, `test_staleBuyLogIgnored`, `test_duplicateTickIgnored` |
| Max buys | `test_executeBuyMaxBuysSkips`, `test_maxBuysPreventsTrigger` |
| Missed callback / liveness | `test_missedCallbackRecovers`, `test_missedCallbackCanBeCancelled`, `test_retryAfterMissedCallback`, `test_pendingTimeoutAllowsNewRequest`, `test_ownerClearPending` |
| Plan cancel / budget refund | `test_cancelPlanRefundsUnspent`, `test_planCancelledMirror`, `test_missedCallbackCanBeCancelled` |
| Reserve / accounting | `test_baseReserveOwnerFunctions`, `test_quoteReserveOwnerFunctions`, `test_depositAndWithdrawQuote`, `test_accountingInvariantAcrossLifecycle` |
| Decimal and quote math | `test_quoteForDecimals`, `testFuzz_quoteForRoundsUp` |
| Oracle binding | `test_executeBuyPriceMismatchReverts`, `test_executeBuyStalePriceSkips` |
| Reactive subscriptions / mirror | `test_subscriptions`, `test_planCreatedMirror`, `test_planFundedMirror`, `test_planCancelledMirror`, `test_priceStatsAndHighWater` |
| Reactive access control | `test_reactIsSystemOnly`, `test_setVaultOnlyOnceAndOwnerOnly`, `test_pauseOnlyOwner`, `test_ownerConfigBounds` |
| Replay / wrong chain | `test_duplicateTickIgnored`, `test_wrongChainTickIgnored`, `test_staleBuyLogIgnored` |
| Sepolia-path E2E | `SepoliaE2ETest.test_dcaStory`, `SepoliaE2ETest.test_missedCallbackRecovers`, `SepoliaE2ETest.test_missedCallbackCanBeCancelled`; plus `SepoliaVaultTest` and `SepoliaReactiveTest` re-run every unit test with chain 11155111 and proxy `0xAa14…23b4` |

## Run a focused test

```bash
forge test --match-contract E2ETest -vv
forge test --match-test test_missedCallbackRecovers -vvv
forge test --match-contract SepoliaE2ETest -vv
forge test --match-test testFuzz_quoteForRoundsUp -vv
```

## What "124 passed" means

The raw output is `docs/test-output.txt`. The last line is:

```
Ran 6 test suites in ...: 124 tests passed, 0 failed, 0 skipped (124 total tests)
```

The six suites are:

- `DcaVaultTest` — 33 tests
- `DcaReactiveTest` — 26 tests
- `E2ETest` — 3 tests
- `SepoliaVaultTest` — 33 tests
- `SepoliaReactiveTest` — 26 tests
- `SepoliaE2ETest` — 3 tests

62 unique tests, each executed on both chain fixtures.
