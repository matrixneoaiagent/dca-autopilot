// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "./BaseTest.sol";
import { DcaVault } from "../src/DcaVault.sol";

/// @notice The demo story, end to end: calm, first dip, cooldown, four more
///         dips, max-buy stop, cancel and refund. Every state change below is
///         produced by the reactive contract and a callback; the test only
///         plays the role of the price feed and the network's log relay.
contract E2ETest is BaseTest {
    function test_dcaStory() public {
        vm.prank(ALICE);
        vault.depositQuote(1000e6);
        uint256 planId = createPlanAndRelay(ALICE, 0.01e18, 500, 60, 5, 200e6);
        fundReserve(10e18);
        assertEq(reactive.planCount(), 1);

        // ---- calm ------------------------------------------------------ //
        pushTickAndRelay(2000e8);
        pushTickAndRelay(2010e8);
        pushTickAndRelay(2020e8);
        pushTickAndRelay(1950e8); // 3.47% below the high
        assertEq(vault.getPlan(planId).buys, 0);
        assertEq(sys.callCount(), 0);

        // ---- first dip ------------------------------------------------- //
        pushTickAndRelay(1910e8); // 5.45% below 2020
        assertEq(vault.getPlan(planId).buys, 1);
        assertEq(vault.getPlan(planId).lastBuyPrice, 1910e8);
        assertEq(weth.balanceOf(ALICE), 0.01e18);
        assertFalse(reactive.pending(planId));

        // ---- cooldown -------------------------------------------------- //
        pushTickAndRelay(1850e8); // 3.14% below 1910, no trigger
        assertEq(vault.getPlan(planId).buys, 1);

        // ---- four more dips, each after the 60 s cooldown ------------- //
        vm.warp(block.timestamp + 61);
        pushTickAndRelay(1800e8); // 5.76% below 1910
        assertEq(vault.getPlan(planId).buys, 2);

        vm.warp(block.timestamp + 61);
        pushTickAndRelay(1700e8); // 5.56% below 1800
        assertEq(vault.getPlan(planId).buys, 3);

        vm.warp(block.timestamp + 61);
        pushTickAndRelay(1600e8); // 5.88% below 1700
        assertEq(vault.getPlan(planId).buys, 4);

        vm.warp(block.timestamp + 61);
        pushTickAndRelay(1500e8); // 6.25% below 1600
        assertEq(vault.getPlan(planId).buys, 5);
        assertEq(sys.callCount(), 5);

        // max buys reached: a lower tick is ignored by the reactive contract
        vm.warp(block.timestamp + 61);
        pushTickAndRelay(1400e8);
        assertEq(vault.getPlan(planId).buys, 5);
        assertEq(sys.callCount(), 5);

        // ---- budget and refund ---------------------------------------- //
        uint256 spent = vault.getPlan(planId).quoteSpent;
        assertEq(spent, 19.1e6 + 18e6 + 17e6 + 16e6 + 15e6);
        assertEq(vault.getPlan(planId).quoteBudget - spent, 114.9e6);

        cancelPlanAndRelay(ALICE, planId);
        assertFalse(vault.getPlan(planId).active);
        assertFalse(reactive.getPlan(planId).active);
        assertEq(vault.quoteBalance(ALICE), 914.9e6);
        assertEq(weth.balanceOf(ALICE), 0.05e18);
        assertAccounting();
    }

    function test_missedCallbackRecovers() public {
        vm.prank(ALICE);
        vault.depositQuote(500e6);
        uint256 planId = createPlanAndRelay(ALICE, 0.01e18, 500, 0, 5, 200e6);
        fundReserve(10e18);

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);

        // The callback is recorded on Lasna but never delivered. No funds move.
        sys.setProxy(address(0));
        pushTick(1910e8);
        assertEq(sys.callCount(), 1);
        assertTrue(reactive.pending(planId));
        assertEq(vault.getPlan(planId).buys, 0);
        assertEq(weth.balanceOf(ALICE), 0);

        // Restore delivery, wait past the pending timeout, and retry.
        sys.setProxy(callbackProxy());
        vm.warp(block.timestamp + 301);

        vm.recordLogs();
        reactive.retry(planId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(sys.callCount(), 2);
        assertEq(vault.getPlan(planId).buys, 1);
        assertEq(weth.balanceOf(ALICE), 0.01e18);
        assertEq(usdc.balanceOf(address(vault)), 500e6);

        _relayVaultLogs(logs);
        assertFalse(reactive.pending(planId));
        assertEq(reactive.getPlan(planId).buys, 1);
        assertAccounting();
    }

    function test_missedCallbackCanBeCancelled() public {
        vm.prank(ALICE);
        vault.depositQuote(500e6);
        uint256 planId = createPlanAndRelay(ALICE, 0.01e18, 500, 0, 5, 200e6);

        pushTickAndRelay(2000e8);
        pushTickAndRelay(2020e8);

        sys.setProxy(address(0));
        pushTick(1910e8);
        assertTrue(reactive.pending(planId));
        assertEq(vault.getPlan(planId).buys, 0);

        // A missed callback does not lock the budget. Cancelling refunds the
        // unspent plan budget to the user's unallocated balance.
        cancelPlanAndRelay(ALICE, planId);
        assertFalse(vault.getPlan(planId).active);
        assertFalse(reactive.pending(planId));
        assertEq(vault.quoteBalance(ALICE), 500e6);

        vm.prank(ALICE);
        vault.withdrawQuote(500e6);
        assertEq(usdc.balanceOf(ALICE), 1_000_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertAccounting();
    }
}
