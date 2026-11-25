// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Vm.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";

import { BaseTest } from "./BaseTest.sol";
import { DcaReactive } from "../src/DcaReactive.sol";
import { DcaVault } from "../src/DcaVault.sol";
import { Owned } from "../src/lib/Owned.sol";
import { MockSystem } from "./mocks/MockReactive.sol";

contract DcaReactiveTest is BaseTest {
    bytes4 internal constant EXECUTE_BUY_SELECTOR =
        bytes4(keccak256("executeBuy(address,uint256,uint256,uint256)"));

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        vault.depositQuote(amount);
    }

    function _planWith(address user, uint256 budget, uint256 cooldown, uint256 maxBuys)
        internal
        returns (uint256 planId)
    {
        vm.prank(user);
        vault.depositQuote(budget);
        planId = createPlanAndRelay(user, 0.01e18, 500, cooldown, maxBuys, budget);
    }

    // --------------------------------------------------------------------- //
    // subscriptions and access control
    // --------------------------------------------------------------------- //

    function test_subscriptions() public view {
        assertEq(sys.subscribeCount(), 6);
        assertEq(sys.subscriptionCount(), 6);
        assertEq(reactive.owner(), address(this));
        assertEq(reactive.vault(), address(vault));
        assertEq(reactive.PRICE_FEED(), address(feed));
        assertEq(reactive.ORIGIN_CHAIN_ID(), originChain);
        assertEq(reactive.DEST_CHAIN_ID(), originChain);
        assertEq(reactive.callbackTimeout(), 300);
        assertEq(reactive.buyGasLimit(), 600_000);
        assertFalse(reactive.paused());
        assertEq(reactive.planCount(), 0);

        MockSystem.Subscription memory priceSub = sys.subscriptionAt(0);
        assertEq(priceSub.chainId, originChain);
        assertEq(priceSub.contractAddress, address(feed));
        assertEq(priceSub.topic0, reactive.PRICE_TICK_TOPIC0());

        assertEq(sys.subscriptionAt(1).contractAddress, address(vault));
        assertEq(sys.subscriptionAt(1).topic0, reactive.PLAN_CREATED_TOPIC0());
        assertEq(sys.subscriptionAt(2).topic0, reactive.PLAN_FUNDED_TOPIC0());
        assertEq(sys.subscriptionAt(3).topic0, reactive.PLAN_CANCELLED_TOPIC0());
        assertEq(sys.subscriptionAt(4).topic0, reactive.BUY_TOPIC0());
        assertEq(sys.subscriptionAt(5).topic0, reactive.SKIP_TOPIC0());
    }

    function test_reactIsSystemOnly() public {
        IReactive.LogRecord memory empty;
        vm.expectRevert();
        reactive.react(empty);
    }

    function test_setVaultOnlyOnceAndOwnerOnly() public {
        vm.prank(BOB);
        vm.expectRevert(Owned.NotOwner.selector);
        reactive.setVault(address(0x1234));

        vm.expectRevert(DcaReactive.VaultAlreadySet.selector);
        reactive.setVault(address(0x1234));
    }

    function test_pauseOnlyOwner() public {
        vm.prank(BOB);
        vm.expectRevert(Owned.NotOwner.selector);
        reactive.pause();

        reactive.pause();
        assertTrue(reactive.paused());

        vm.expectRevert(DcaReactive.EnforcedPause.selector);
        reactive.pause();

        reactive.unpause();
        assertFalse(reactive.paused());

        vm.expectRevert(DcaReactive.ExpectedPause.selector);
        reactive.unpause();
    }

    function test_ownerConfigBounds() public {
        vm.expectRevert(DcaReactive.BadTimeout.selector);
        reactive.setCallbackTimeout(29);
        vm.expectRevert(DcaReactive.BadTimeout.selector);
        reactive.setCallbackTimeout(3601);

        reactive.setCallbackTimeout(600);
        assertEq(reactive.callbackTimeout(), 600);

        vm.expectRevert(DcaReactive.BadGasLimit.selector);
        reactive.setBuyGasLimit(99_999);
        vm.expectRevert(DcaReactive.BadGasLimit.selector);
        reactive.setBuyGasLimit(2_000_001);

        reactive.setBuyGasLimit(800_000);
        assertEq(reactive.buyGasLimit(), 800_000);

        vm.prank(BOB);
        vm.expectRevert(Owned.NotOwner.selector);
        reactive.setCallbackTimeout(300);
    }

    // --------------------------------------------------------------------- //
    // plan mirroring
    // --------------------------------------------------------------------- //

    function test_planCreatedMirror() public {
        uint256 planId = _planWith(ALICE, 200e6, 60, 5);

        assertEq(reactive.planCount(), 1);
        assertEq(reactive.planIdAt(0), planId);

        DcaReactive.Plan memory p = reactive.getPlan(planId);
        assertEq(p.owner, ALICE);
        assertEq(p.basePerBuy, 0.01e18);
        assertEq(p.drawdownBps, 500);
        assertEq(p.cooldown, 60);
        assertEq(p.maxBuys, 5);
        assertEq(p.quoteBudget, 200e6);
        assertEq(p.quoteSpent, 0);
        assertEq(p.buys, 0);
        assertEq(p.highWater, 0);
        assertTrue(p.active);
        assertTrue(p.exists);

        pushTickAndRelay(2000e8);
        assertEq(reactive.lastPrice(), 2000e8);
        assertEq(reactive.getPlan(planId).highWater, 2000e8);
        assertEq(reactive.ticksSeen(), 1);
    }

    function test_planFundedMirror() public {
        uint256 planId = _planWith(ALICE, 100e6, 60, 5);
        _deposit(ALICE, 50e6);
        fundPlanAndRelay(ALICE, planId, 50e6);

        assertEq(vault.getPlan(planId).quoteBudget, 150e6);
        assertEq(reactive.getPlan(planId).quoteBudget, 150e6);
    }

    function test_planCancelledMirror() public {
        uint256 planId = _planWith(ALICE, 200e6, 0, 5);
        cancelPlanAndRelay(ALICE, planId);

        assertFalse(reactive.getPlan(planId).active);
        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);
        pushTickAndRelay(1910e8);

        assertEq(sys.callCount(), 0);
        assertEq(vault.getPlan(planId).buys, 0);
    }

    function test_priceStatsAndHighWater() public {
        _planWith(ALICE, 200e6, 0, 5);

        pushTick(2000e8);
        assertEq(reactive.lastPrice(), 2000e8);
        assertEq(reactive.highWater(), 2000e8);
        assertEq(reactive.lastPriceAt(), block.timestamp);
        assertEq(reactive.ticksSeen(), 1);

        pushTick(1900e8);
        assertEq(reactive.lastPrice(), 1900e8);
        assertEq(reactive.highWater(), 2000e8);
        assertEq(reactive.ticksSeen(), 2);
    }

    // --------------------------------------------------------------------- //
    // trigger logic
    // --------------------------------------------------------------------- //

    function test_noTriggerAboveThreshold() public {
        _planWith(ALICE, 200e6, 0, 10);
        fundReserve(10e18);

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2010e8);
        pushTickAndRelay(1950e8); // only 2.99% below the high

        assertEq(sys.callCount(), 0);
        assertEq(vault.getPlan(1).buys, 0);
        assertFalse(reactive.pending(1));
    }

    function test_firstBuyUsesHighWater() public {
        _planWith(ALICE, 200e6, 0, 10);
        fundReserve(10e18);

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);
        assertEq(sys.callCount(), 0);

        pushTickAndRelay(1910e8); // 5.45% below the high-water mark
        assertEq(sys.callCount(), 1);
        assertEq(vault.getPlan(1).buys, 1);
        assertEq(vault.getPlan(1).lastBuyPrice, 1910e8);
        assertEq(vault.getPlan(1).quoteSpent, 19.1e6);
        assertEq(reactive.getPlan(1).buys, 1);
        assertEq(reactive.getPlan(1).lastBuyPrice, 1910e8);
    }

    function test_drawdownTriggersCallback() public {
        uint256 planId = _planWith(ALICE, 200e6, 0, 10);
        fundReserve(10e18);

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);

        vm.recordLogs();
        uint256 tickId = pushTick(1910e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(sys.callCount(), 1);
        MockSystem.Call memory call_ = sys.lastCall();
        assertEq(call_.chainId, originChain);
        assertEq(call_.recipient, address(vault));
        assertEq(call_.gasLimit, 600_000);
        assertEq(bytes4(call_.payload), EXECUTE_BUY_SELECTOR);
        assertTrue(reactive.pending(planId));
        assertEq(reactive.pendingTick(planId), tickId);
        assertEq(reactive.getPlan(planId).buys, 0);

        vm.expectEmit(true, true, false, true, address(reactive));
        emit DcaReactive.BuyConfirmed(planId, tickId, 19.1e6, 0.01e18, 1910e8);
        _relayVaultLogs(logs);

        assertFalse(reactive.pending(planId));
        DcaReactive.Plan memory p = reactive.getPlan(planId);
        assertEq(p.buys, 1);
        assertEq(p.quoteSpent, 19.1e6);
        assertEq(p.lastBuyPrice, 1910e8);
        assertEq(p.lastBuyTick, tickId);
    }

    function test_cooldownPreventsTrigger() public {
        _planWith(ALICE, 500e6, 3600, 10);
        fundReserve(10e18);

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);
        pushTickAndRelay(1910e8);
        assertEq(sys.callCount(), 1);
        assertEq(vault.getPlan(1).buys, 1);

        pushTickAndRelay(1800e8); // 5.76% below 1910, but cooldown is active
        assertEq(sys.callCount(), 1);
        assertEq(vault.getPlan(1).buys, 1);

        vm.warp(block.timestamp + 3601);
        pushTickAndRelay(1800e8);
        assertEq(sys.callCount(), 2);
        assertEq(vault.getPlan(1).buys, 2);
    }

    function test_maxBuysPreventsTrigger() public {
        _planWith(ALICE, 500e6, 0, 1);
        fundReserve(10e18);

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);
        pushTickAndRelay(1910e8);
        assertEq(sys.callCount(), 1);
        assertEq(vault.getPlan(1).buys, 1);

        pushTickAndRelay(1800e8);
        assertEq(sys.callCount(), 1);
        assertEq(vault.getPlan(1).buys, 1);
    }

    function test_budgetExhaustedPreventsTrigger() public {
        _planWith(ALICE, 20e6, 0, 10);
        fundReserve(10e18);

        pushTickAndRelay(2110e8);
        pushTickAndRelay(2000e8); // 5.21% below 2110; costs exactly 20 USDC
        assertEq(sys.callCount(), 1);
        assertEq(vault.getPlan(1).quoteSpent, 20e6);
        assertEq(reactive.getPlan(1).quoteSpent, 20e6);

        pushTickAndRelay(1900e8);
        assertEq(sys.callCount(), 1);
        assertEq(vault.getPlan(1).buys, 1);
    }

    function test_pendingBlocksDuplicateRequest() public {
        uint256 planId = _planWith(ALICE, 500e6, 0, 10);
        fundReserve(10e18);

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);

        vm.recordLogs();
        pushTick(1910e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(sys.callCount(), 1);
        assertTrue(reactive.pending(planId));

        pushTick(1800e8); // pending, so no second request
        assertEq(sys.callCount(), 1);

        _relayVaultLogs(logs);
        assertFalse(reactive.pending(planId));
        assertEq(reactive.getPlan(planId).buys, 1);
    }

    function test_skipLogClearsPending() public {
        uint256 planId = _planWith(ALICE, 200e6, 0, 10);
        fundReserve(10e18);
        vault.pause();

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);

        vm.recordLogs();
        uint256 tickId = pushTick(1910e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(reactive.pending(planId));

        vm.expectEmit(true, true, false, true, address(reactive));
        emit DcaReactive.BuySkipped(planId, tickId, uint8(DcaVault.SkipReason.Paused), 1910e8);
        _relayVaultLogs(logs);

        assertFalse(reactive.pending(planId));
        assertEq(reactive.getPlan(planId).buys, 0);
        assertTrue(reactive.isTriggerable(planId));

        vault.unpause();
    }

    function test_pauseStopsTriggers() public {
        _planWith(ALICE, 500e6, 0, 10);
        fundReserve(10e18);

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);

        reactive.pause();
        pushTickAndRelay(1910e8);
        assertEq(sys.callCount(), 0);
        assertFalse(reactive.isTriggerable(1));

        reactive.unpause();
        pushTickAndRelay(1900e8);
        assertEq(sys.callCount(), 1);
        assertEq(vault.getPlan(1).buys, 1);
    }

    // --------------------------------------------------------------------- //
    // liveness fallback
    // --------------------------------------------------------------------- //

    function test_pendingTimeoutAllowsNewRequest() public {
        uint256 planId = _planWith(ALICE, 500e6, 0, 10);
        fundReserve(10e18);
        sys.setProxy(address(0));

        pushTick(2000e8);
        pushTick(2020e8);
        pushTick(1910e8);
        assertEq(sys.callCount(), 1);
        assertTrue(reactive.pending(planId));

        vm.warp(block.timestamp + 301);
        uint256 secondTick = pushTick(1900e8);

        assertEq(sys.callCount(), 2);
        assertTrue(reactive.pending(planId));
        assertEq(reactive.pendingTick(planId), secondTick);
    }

    function test_retryAfterMissedCallback() public {
        uint256 planId = _planWith(ALICE, 500e6, 0, 10);
        fundReserve(10e18);
        sys.setProxy(address(0));

        pushTick(2000e8);
        pushTick(2020e8);
        pushTick(1910e8);
        assertEq(sys.callCount(), 1);
        assertTrue(reactive.pending(planId));

        sys.setProxy(callbackProxy());
        vm.warp(block.timestamp + 301);

        vm.recordLogs();
        reactive.retry(planId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(sys.callCount(), 2);
        assertTrue(reactive.pending(planId));
        assertEq(vault.getPlan(planId).buys, 1);
        assertEq(weth.balanceOf(ALICE), 0.01e18);

        _relayVaultLogs(logs);
        assertFalse(reactive.pending(planId));
        assertEq(reactive.getPlan(planId).buys, 1);
    }

    function test_retryRevertsWhenNotStale() public {
        _planWith(ALICE, 500e6, 0, 10);
        fundReserve(10e18);
        sys.setProxy(address(0));

        pushTick(2000e8);
        pushTick(2020e8);
        pushTick(1910e8);
        assertTrue(reactive.pending(1));

        vm.expectRevert(DcaReactive.PendingNotStale.selector);
        reactive.retry(1);
    }

    function test_retryRevertsWhenNotTriggered() public {
        _planWith(ALICE, 500e6, 0, 10);
        pushTick(2000e8);
        pushTick(2020e8);

        vm.expectRevert(DcaReactive.PlanNotTriggerable.selector);
        reactive.retry(1);
    }

    function test_ownerClearPending() public {
        _planWith(ALICE, 500e6, 0, 10);
        fundReserve(10e18);
        sys.setProxy(address(0));

        pushTick(2000e8);
        pushTick(2020e8);
        pushTick(1910e8);
        assertTrue(reactive.pending(1));

        vm.prank(BOB);
        vm.expectRevert(Owned.NotOwner.selector);
        reactive.clearPending(1);

        reactive.clearPending(1);
        assertFalse(reactive.pending(1));

        vm.expectRevert(DcaReactive.NoPendingRequest.selector);
        reactive.clearPending(1);
    }

    // --------------------------------------------------------------------- //
    // replay protection
    // --------------------------------------------------------------------- //

    function test_duplicateTickIgnored() public {
        _planWith(ALICE, 200e6, 0, 10);
        pushTick(2000e8);
        pushTick(2020e8);
        uint256 seen = reactive.ticksSeen();

        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: originChain,
            contractAddress: address(feed),
            topic0: reactive.PRICE_TICK_TOPIC0(),
            topic1: 2,
            topic2: 0,
            topic3: 0,
            data: abi.encode(2020e8, block.timestamp),
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        sys.trigger(address(reactive), log_);

        assertEq(reactive.ticksSeen(), seen);
        assertEq(reactive.lastPrice(), 2020e8);
    }

    function test_wrongChainTickIgnored() public {
        _planWith(ALICE, 200e6, 0, 10);

        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: 1,
            contractAddress: address(feed),
            topic0: reactive.PRICE_TICK_TOPIC0(),
            topic1: 1,
            topic2: 0,
            topic3: 0,
            data: abi.encode(2000e8, block.timestamp),
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        sys.trigger(address(reactive), log_);

        assertEq(reactive.ticksSeen(), 0);
        assertEq(reactive.lastPrice(), 0);
    }

    function test_staleBuyLogIgnored() public {
        uint256 planId = _planWith(ALICE, 500e6, 0, 10);
        fundReserve(10e18);

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);

        vm.recordLogs();
        pushTick(1910e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _relayVaultLogs(logs);
        assertEq(reactive.getPlan(planId).buys, 1);

        // Replaying the same DcaBuy log must not count the buy twice.
        _relayVaultLogs(logs);
        assertEq(reactive.getPlan(planId).buys, 1);
    }
}
