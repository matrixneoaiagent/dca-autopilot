// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { BaseTest } from "./BaseTest.sol";
import { DcaVault } from "../src/DcaVault.sol";
import { Owned } from "../src/lib/Owned.sol";

contract DcaVaultTest is BaseTest {
    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        vault.depositQuote(amount);
    }

    function _plan(address user, uint256 budget) internal returns (uint256 planId) {
        _deposit(user, budget);
        vm.prank(user);
        planId = vault.createPlan(0.01e18, 500, 3600, 10, budget);
    }

    function _buy(uint256 planId, uint256 tickId, uint256 price) internal returns (bool ok) {
        vm.prank(address(proxy));
        ok = vault.executeBuy(address(reactive), planId, tickId, price);
    }

    // --------------------------------------------------------------------- //
    // construction and wiring
    // --------------------------------------------------------------------- //

    function test_constructorWiring() public view {
        assertEq(address(vault.quoteToken()), address(usdc));
        assertEq(address(vault.baseToken()), address(weth));
        assertEq(address(vault.priceFeed()), address(feed));
        assertEq(vault.quoteDecimals(), 6);
        assertEq(vault.baseDecimals(), 18);
        assertEq(vault.quoteScale(), 1e6);
        assertEq(vault.baseScale(), 1e18);
        assertEq(vault.owner(), address(this));
        assertEq(vault._CALLBACK_SENDER(), address(reactive));
        assertEq(address(vault._SERVICE_PROVIDER()), callbackProxy());
        assertEq(vault.planCount(), 0);
        assertFalse(vault.paused());
        assertEq(vault.maxPriceAge(), 1 hours);
    }

    function test_quoteForDecimals() public view {
        assertEq(vault.quoteFor(0.01e18, 2000e8), 20e6);
        assertEq(vault.quoteFor(1e18, 2000e8), 2000e6);
        assertEq(vault.quoteFor(0.01e18, 2050e8), 20.5e6);
        assertEq(vault.quoteFor(1e18, 1e8), 1e6);
        // Rounds up: 1 wei of base at $1 is far below one USDC unit.
        assertEq(vault.quoteFor(1, 1e8), 1);
    }

    function testFuzz_quoteForRoundsUp(uint256 baseAmount, uint256 price) public view {
        baseAmount = bound(baseAmount, 1, 1e20);
        price = bound(price, 1, 1e20);

        uint256 quoteIn = vault.quoteFor(baseAmount, price);
        assertGt(quoteIn, 0);
        assertGe(quoteIn * 1e8 * 1e18, baseAmount * price * 1e6);
    }

    // --------------------------------------------------------------------- //
    // deposits, withdrawals, plans
    // --------------------------------------------------------------------- //

    function test_depositAndWithdrawQuote() public {
        _deposit(ALICE, 1000e6);
        assertEq(vault.quoteBalance(ALICE), 1000e6);
        assertEq(vault.totalUnallocated(), 1000e6);
        assertEq(vault.totalQuoteDeposited(), 1000e6);
        assertEq(usdc.balanceOf(address(vault)), 1000e6);
        assertAccounting();

        vm.prank(ALICE);
        vault.withdrawQuote(400e6);
        assertEq(vault.quoteBalance(ALICE), 600e6);
        assertEq(vault.totalUnallocated(), 600e6);
        assertEq(usdc.balanceOf(address(vault)), 600e6);
        assertAccounting();
    }

    function test_zeroAmountsRevert() public {
        vm.prank(ALICE);
        vm.expectRevert(DcaVault.InvalidAmount.selector);
        vault.depositQuote(0);

        vm.prank(ALICE);
        vm.expectRevert(DcaVault.InvalidAmount.selector);
        vault.withdrawQuote(0);
    }

    function test_withdrawQuoteRejectsInsufficient() public {
        vm.prank(ALICE);
        vm.expectRevert(DcaVault.InsufficientQuote.selector);
        vault.withdrawQuote(1);
    }

    function test_createPlanAllocatesBudget() public {
        _deposit(ALICE, 1000e6);
        vm.prank(ALICE);
        uint256 planId = vault.createPlan(0.01e18, 500, 60, 5, 200e6);

        DcaVault.Plan memory p = vault.getPlan(planId);
        assertEq(planId, 1);
        assertEq(p.owner, ALICE);
        assertEq(p.basePerBuy, 0.01e18);
        assertEq(p.drawdownBps, 500);
        assertEq(p.cooldown, 60);
        assertEq(p.maxBuys, 5);
        assertEq(p.quoteBudget, 200e6);
        assertEq(p.quoteSpent, 0);
        assertEq(p.buys, 0);
        assertTrue(p.active);
        assertGt(p.createdAt, 0);

        assertEq(vault.quoteBalance(ALICE), 800e6);
        assertEq(vault.totalUnallocated(), 800e6);
        assertEq(vault.totalPlanRemaining(), 200e6);
        assertEq(vault.planCount(), 1);
        assertAccounting();
    }

    function test_createPlanEmitsEvent() public {
        _deposit(ALICE, 1000e6);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaPlanCreated(1, ALICE, 0.01e18, 500, 60, 5, 200e6);
        vm.prank(ALICE);
        vault.createPlan(0.01e18, 500, 60, 5, 200e6);
    }

    function test_createPlanRejectsInsufficientBudget() public {
        vm.prank(ALICE);
        vm.expectRevert(DcaVault.InsufficientQuote.selector);
        vault.createPlan(0.01e18, 500, 60, 5, 200e6);
    }

    function test_createPlanRejectsBadParams() public {
        _deposit(ALICE, 1000e6);
        vm.startPrank(ALICE);

        vm.expectRevert(DcaVault.InvalidBaseAmount.selector);
        vault.createPlan(0, 500, 60, 5, 200e6);
        vm.expectRevert(DcaVault.InvalidBaseAmount.selector);
        vault.createPlan(1e24 + 1, 500, 60, 5, 200e6);

        vm.expectRevert(DcaVault.InvalidDrawdown.selector);
        vault.createPlan(0.01e18, 0, 60, 5, 200e6);
        vm.expectRevert(DcaVault.InvalidDrawdown.selector);
        vault.createPlan(0.01e18, 5001, 60, 5, 200e6);

        vm.expectRevert(DcaVault.InvalidCooldown.selector);
        vault.createPlan(0.01e18, 500, 31 days, 5, 200e6);

        vm.expectRevert(DcaVault.InvalidMaxBuys.selector);
        vault.createPlan(0.01e18, 500, 60, 0, 200e6);
        vm.expectRevert(DcaVault.InvalidMaxBuys.selector);
        vault.createPlan(0.01e18, 500, 60, 1001, 200e6);

        vm.expectRevert(DcaVault.InvalidBudget.selector);
        vault.createPlan(0.01e18, 500, 60, 5, 0);

        vm.stopPrank();
    }

    function test_createPlanPlanLimit() public {
        _deposit(ALICE, 100e6);
        vm.startPrank(ALICE);
        for (uint256 i = 0; i < 32; i++) {
            vault.createPlan(1e15, 500, 60, 5, 1e6);
        }
        vm.expectRevert(DcaVault.PlanLimit.selector);
        vault.createPlan(1e15, 500, 60, 5, 1e6);
        vm.stopPrank();

        assertEq(vault.planCount(), 32);
        assertAccounting();
    }

    function test_fundPlanIncreasesBudget() public {
        uint256 planId = _plan(ALICE, 200e6);
        _deposit(ALICE, 100e6);

        vm.expectEmit(true, false, false, true, address(vault));
        emit DcaVault.DcaPlanBudgetIncreased(planId, 100e6, 300e6);
        vm.prank(ALICE);
        vault.fundPlan(planId, 100e6);

        DcaVault.Plan memory p = vault.getPlan(planId);
        assertEq(p.quoteBudget, 300e6);
        assertEq(vault.quoteBalance(ALICE), 0);
        assertEq(vault.totalPlanRemaining(), 300e6);
        assertAccounting();
    }

    function test_onlyPlanOwnerCanFundOrCancel() public {
        uint256 planId = _plan(ALICE, 200e6);

        vm.prank(BOB);
        vm.expectRevert(DcaVault.NotPlanOwner.selector);
        vault.fundPlan(planId, 10e6);

        vm.prank(BOB);
        vm.expectRevert(DcaVault.NotPlanOwner.selector);
        vault.cancelPlan(planId);
    }

    function test_cancelPlanRefundsUnspent() public {
        uint256 planId = _plan(ALICE, 200e6);
        fundReserve(10e18);
        uint256 tickId = feed.publish(2000e8);
        assertTrue(_buy(planId, tickId, 2000e8));

        assertEq(vault.getPlan(planId).quoteSpent, 20e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit DcaVault.DcaPlanCancelled(planId, 180e6);
        vm.prank(ALICE);
        vault.cancelPlan(planId);

        DcaVault.Plan memory p = vault.getPlan(planId);
        assertFalse(p.active);
        assertEq(vault.quoteBalance(ALICE), 180e6);
        assertEq(vault.totalPlanRemaining(), 0);
        assertEq(vault.totalUnallocated(), 180e6);
        assertEq(vault.quoteReserve(), 20e6);
        assertAccounting();

        vm.prank(ALICE);
        vm.expectRevert(DcaVault.PlanNotActive.selector);
        vault.cancelPlan(planId);
    }

    // --------------------------------------------------------------------- //
    // executeBuy: happy path and authentication
    // --------------------------------------------------------------------- //

    function test_executeBuyHappyPath() public {
        uint256 planId = _plan(ALICE, 200e6);
        fundReserve(10e18);
        uint256 tickId = feed.publish(2000e8);

        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuy(planId, tickId, 20e6, 0.01e18, 2000e8);
        assertTrue(_buy(planId, tickId, 2000e8));

        DcaVault.Plan memory p = vault.getPlan(planId);
        assertEq(p.quoteSpent, 20e6);
        assertEq(p.buys, 1);
        assertEq(p.lastBuyAt, block.timestamp);
        assertEq(p.lastBuyPrice, 2000e8);
        assertEq(p.lastTickId, tickId);

        assertEq(weth.balanceOf(ALICE), 0.01e18);
        assertEq(vault.baseReserve(), 9.99e18);
        assertEq(vault.quoteReserve(), 20e6);
        assertEq(vault.totalPlanRemaining(), 180e6);
        assertAccounting();
    }

    function test_executeBuyUnauthorizedReverts() public {
        uint256 planId = _plan(ALICE, 200e6);
        uint256 tickId = feed.publish(2000e8);

        vm.expectRevert();
        vault.executeBuy(address(reactive), planId, tickId, 2000e8);

        vm.prank(address(proxy));
        vm.expectRevert();
        vault.executeBuy(address(0xBAD), planId, tickId, 2000e8);

        vm.prank(BOB);
        vm.expectRevert();
        vault.executeBuy(address(reactive), planId, tickId, 2000e8);

        assertEq(vault.getPlan(planId).buys, 0);
        assertEq(weth.balanceOf(ALICE), 0);
    }

    function test_executeBuyPriceMismatchReverts() public {
        uint256 planId = _plan(ALICE, 200e6);
        uint256 tickId = feed.publish(2000e8);

        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(DcaVault.PriceMismatch.selector, tickId, 1999e8, 2000e8)
        );
        vault.executeBuy(address(reactive), planId, tickId, 1999e8);

        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(DcaVault.PriceMismatch.selector, 999, 2000e8, 0));
        vault.executeBuy(address(reactive), planId, 999, 2000e8);
    }

    function test_executeBuyUnknownPlanSkips() public {
        uint256 tickId = feed.publish(2000e8);

        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuySkipped(999, tickId, uint8(DcaVault.SkipReason.UnknownPlan), 2000e8);
        assertFalse(_buy(999, tickId, 2000e8));
    }

    function test_executeBuyStaleTickSkips() public {
        uint256 planId = _plan(ALICE, 200e6);
        fundReserve(10e18);
        uint256 tickId = feed.publish(2000e8);
        assertTrue(_buy(planId, tickId, 2000e8));

        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuySkipped(planId, tickId, uint8(DcaVault.SkipReason.StaleTick), 2000e8);
        assertFalse(_buy(planId, tickId, 2000e8));

        assertEq(vault.getPlan(planId).buys, 1);
        assertEq(weth.balanceOf(ALICE), 0.01e18);
    }

    function test_executeBuyInactivePlanSkips() public {
        uint256 planId = _plan(ALICE, 200e6);
        fundReserve(10e18);
        vm.prank(ALICE);
        vault.cancelPlan(planId);

        uint256 tickId = feed.publish(2000e8);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuySkipped(planId, tickId, uint8(DcaVault.SkipReason.InactivePlan), 2000e8);
        assertFalse(_buy(planId, tickId, 2000e8));
    }

    // --------------------------------------------------------------------- //
    // executeBuy: business rules
    // --------------------------------------------------------------------- //

    function test_executeBuyCooldownSkips() public {
        uint256 planId = _plan(ALICE, 200e6);
        fundReserve(10e18);
        uint256 first = feed.publish(2000e8);
        assertTrue(_buy(planId, first, 2000e8));

        uint256 second = feed.publish(1900e8);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuySkipped(planId, second, uint8(DcaVault.SkipReason.Cooldown), 1900e8);
        assertFalse(_buy(planId, second, 1900e8));

        assertEq(vault.getPlan(planId).buys, 1);
    }

    function test_executeBuyMaxBuysSkips() public {
        _deposit(ALICE, 200e6);
        vm.prank(ALICE);
        uint256 planId = vault.createPlan(0.01e18, 500, 0, 1, 200e6);
        fundReserve(10e18);

        uint256 first = feed.publish(2000e8);
        assertTrue(_buy(planId, first, 2000e8));

        vm.warp(block.timestamp + 3601);
        uint256 second = feed.publish(1900e8);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuySkipped(planId, second, uint8(DcaVault.SkipReason.MaxBuys), 1900e8);
        assertFalse(_buy(planId, second, 1900e8));

        assertEq(vault.getPlan(planId).buys, 1);
    }

    function test_executeBuyBudgetSkips() public {
        _deposit(ALICE, 200e6);
        vm.prank(ALICE);
        uint256 planId = vault.createPlan(0.01e18, 500, 0, 10, 25e6);
        fundReserve(10e18);

        uint256 first = feed.publish(2000e8);
        assertTrue(_buy(planId, first, 2000e8));

        uint256 second = feed.publish(1900e8);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuySkipped(
            planId, second, uint8(DcaVault.SkipReason.BudgetExceeded), 1900e8
        );
        assertFalse(_buy(planId, second, 1900e8));

        assertEq(vault.getPlan(planId).quoteSpent, 20e6);
    }

    function test_executeBuyInsufficientReserveSkips() public {
        uint256 planId = _plan(ALICE, 200e6);
        fundReserve(0.005e18);
        uint256 tickId = feed.publish(2000e8);

        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuySkipped(
            planId, tickId, uint8(DcaVault.SkipReason.InsufficientReserve), 2000e8
        );
        assertFalse(_buy(planId, tickId, 2000e8));

        assertEq(vault.getPlan(planId).buys, 0);
        assertEq(vault.baseReserve(), 0.005e18);
        assertAccounting();
    }

    function test_executeBuyNotDippedSkips() public {
        _deposit(ALICE, 200e6);
        vm.prank(ALICE);
        uint256 planId = vault.createPlan(0.01e18, 500, 0, 10, 200e6);
        fundReserve(10e18);

        uint256 first = feed.publish(2000e8);
        assertTrue(_buy(planId, first, 2000e8));

        // Only 1% below the last buy; the reactive would not request this, but
        // the vault independently rejects it.
        uint256 second = feed.publish(1980e8);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuySkipped(planId, second, uint8(DcaVault.SkipReason.NotDipped), 1980e8);
        assertFalse(_buy(planId, second, 1980e8));

        assertEq(vault.getPlan(planId).buys, 1);
    }

    function test_executeBuyStalePriceSkips() public {
        uint256 planId = _plan(ALICE, 200e6);
        fundReserve(10e18);
        uint256 tickId = feed.publish(2000e8);

        vm.warp(block.timestamp + 3601);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuySkipped(planId, tickId, uint8(DcaVault.SkipReason.StalePrice), 2000e8);
        assertFalse(_buy(planId, tickId, 2000e8));

        assertEq(vault.getPlan(planId).buys, 0);
    }

    function test_executeBuyPausedSkipsAndWithdrawalsWork() public {
        _deposit(ALICE, 1000e6);
        vm.prank(ALICE);
        uint256 planId = vault.createPlan(0.01e18, 500, 3600, 10, 200e6);
        fundReserve(10e18);
        vault.pause();

        uint256 tickId = feed.publish(2000e8);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DcaVault.DcaBuySkipped(planId, tickId, uint8(DcaVault.SkipReason.Paused), 2000e8);
        assertFalse(_buy(planId, tickId, 2000e8));
        assertEq(vault.getPlan(planId).buys, 0);

        vm.prank(ALICE);
        vm.expectRevert(DcaVault.EnforcedPause.selector);
        vault.depositQuote(100e6);

        vm.prank(ALICE);
        vm.expectRevert(DcaVault.EnforcedPause.selector);
        vault.createPlan(0.01e18, 500, 3600, 10, 100e6);

        // Withdrawals and cancellation always work, even while paused.
        vm.prank(ALICE);
        vault.withdrawQuote(100e6);
        vm.prank(ALICE);
        vault.cancelPlan(planId);
        assertFalse(vault.getPlan(planId).active);
        assertAccounting();

        vault.unpause();
    }

    // --------------------------------------------------------------------- //
    // pause, ownership, reserves
    // --------------------------------------------------------------------- //

    function test_pauseOnlyOwner() public {
        vm.prank(BOB);
        vm.expectRevert(Owned.NotOwner.selector);
        vault.pause();

        vault.pause();
        assertTrue(vault.paused());

        vm.expectRevert(DcaVault.EnforcedPause.selector);
        vault.pause();

        vault.unpause();
        assertFalse(vault.paused());

        vm.expectRevert(DcaVault.ExpectedPause.selector);
        vault.unpause();
    }

    function test_baseReserveOwnerFunctions() public {
        vault.depositBaseReserve(10e18);
        assertEq(vault.baseReserve(), 10e18);
        assertEq(weth.balanceOf(address(vault)), 10e18);

        vm.prank(BOB);
        vm.expectRevert(Owned.NotOwner.selector);
        vault.depositBaseReserve(1e18);

        vm.prank(BOB);
        vm.expectRevert(Owned.NotOwner.selector);
        vault.withdrawBaseReserve(1e18);

        vault.withdrawBaseReserve(4e18);
        assertEq(vault.baseReserve(), 6e18);
        assertEq(weth.balanceOf(address(vault)), 6e18);
        assertAccounting();

        vm.expectRevert(DcaVault.InsufficientReserve.selector);
        vault.withdrawBaseReserve(7e18);

        vault.pause();
        vm.expectRevert(DcaVault.EnforcedPause.selector);
        vault.withdrawBaseReserve(1e18);
        vault.unpause();
    }

    function test_quoteReserveOwnerFunctions() public {
        uint256 planId = _plan(ALICE, 200e6);
        fundReserve(10e18);
        uint256 tickId = feed.publish(2000e8);
        assertTrue(_buy(planId, tickId, 2000e8));
        assertEq(vault.quoteReserve(), 20e6);

        vm.prank(BOB);
        vm.expectRevert(Owned.NotOwner.selector);
        vault.withdrawQuoteReserve(1e6);

        vault.withdrawQuoteReserve(10e6);
        assertEq(vault.quoteReserve(), 10e6);
        assertEq(usdc.balanceOf(address(this)), 10e6);
        assertAccounting();

        vm.expectRevert(DcaVault.InsufficientReserve.selector);
        vault.withdrawQuoteReserve(11e6);
    }

    function test_setMaxPriceAgeBounds() public {
        vm.expectRevert(DcaVault.InvalidMaxPriceAge.selector);
        vault.setMaxPriceAge(59);
        vm.expectRevert(DcaVault.InvalidMaxPriceAge.selector);
        vault.setMaxPriceAge(7 days + 1);

        vault.setMaxPriceAge(2 hours);
        assertEq(vault.maxPriceAge(), 2 hours);
    }

    function test_transferOwnership() public {
        vm.prank(BOB);
        vm.expectRevert(Owned.NotOwner.selector);
        vault.transferOwnership(BOB);

        vault.transferOwnership(BOB);
        assertEq(vault.owner(), BOB);

        vm.prank(BOB);
        vault.pause();
        assertTrue(vault.paused());
    }

    // --------------------------------------------------------------------- //
    // accounting
    // --------------------------------------------------------------------- //

    function test_accountingInvariantAcrossLifecycle() public {
        _deposit(ALICE, 1000e6);
        _deposit(BOB, 500e6);
        assertAccounting();

        vm.prank(ALICE);
        uint256 planA = vault.createPlan(0.01e18, 500, 0, 10, 200e6);
        vm.prank(BOB);
        uint256 planB = vault.createPlan(0.01e18, 500, 0, 10, 100e6);
        assertAccounting();

        fundReserve(10e18);
        uint256 tickId = feed.publish(2000e8);
        assertTrue(_buy(planA, tickId, 2000e8));
        assertAccounting();

        vm.prank(BOB);
        vault.cancelPlan(planB);
        assertAccounting();

        vm.prank(ALICE);
        vault.withdrawQuote(300e6);
        assertAccounting();

        vault.withdrawQuoteReserve(20e6);
        vault.withdrawBaseReserve(1e18);
        assertAccounting();

        assertEq(vault.planCount(), 2);
        assertEq(vault.baseReserve(), 8.99e18);
        assertEq(vault.quoteReserve(), 0);
    }
}
