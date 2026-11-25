// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";
import { IPayable } from "reactive-lib/interfaces/IPayable.sol";

import { PriceFeed } from "../src/PriceFeed.sol";
import { DcaReactive } from "../src/DcaReactive.sol";
import { DcaVault } from "../src/DcaVault.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IPriceFeed } from "../src/interfaces/IPriceFeed.sol";
import { MockSystem, MockProxy } from "./mocks/MockReactive.sol";

/// @notice Shared fixture. The origin/destination chain is a virtual so the
///         same suites run on Base Sepolia (default, fast variant) and
///         Ethereum Sepolia (the deployment target, see SepoliaPath.t.sol).
abstract contract BaseTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockSystem internal sys;
    MockProxy internal proxy;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    PriceFeed internal feed;
    DcaReactive internal reactive;
    DcaVault internal vault;

    uint256 internal originChain;

    /// @notice Chain where the feed and vault live, and where callbacks land.
    function originChainId() internal pure virtual returns (uint256) {
        return 84532; // Base Sepolia, fast variant
    }

    /// @notice Reactive callback proxy on the origin/destination chain.
    function callbackProxy() internal pure virtual returns (address) {
        return 0x476F44b11F5C942c58f4c8E3d0300E5710743585; // Base Sepolia
    }

    function setUp() public virtual {
        originChain = originChainId();

        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        sys = MockSystem(SYSTEM_ADDR);

        vm.etch(callbackProxy(), address(new MockProxy()).code);
        proxy = MockProxy(callbackProxy());
        sys.setProxy(callbackProxy());

        usdc = new MockERC20("Mock USD Coin", "mUSDC", 6, address(this));
        weth = new MockERC20("Mock Wrapped Ether", "mWETH", 18, address(this));
        feed = new PriceFeed(address(this), address(this));

        reactive = new DcaReactive(originChain, address(feed), originChain, address(this));
        vault = new DcaVault(
            IERC20(address(usdc)),
            IERC20(address(weth)),
            IPriceFeed(address(feed)),
            IPayable(payable(callbackProxy())),
            address(reactive),
            address(this)
        );
        reactive.setVault(address(vault));

        usdc.mint(ALICE, 1_000_000e6);
        usdc.mint(BOB, 1_000_000e6);
        weth.mint(address(this), 1_000e18);

        vm.prank(ALICE);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        usdc.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
    }

    // --------------------------------------------------------------------- //
    // event relay helpers
    // --------------------------------------------------------------------- //

    /// @notice Publish a price on the origin feed and deliver the resulting log
    ///         to the reactive contract, as the network would.
    function pushTick(uint256 price) internal returns (uint256 id) {
        id = feed.publish(price);
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: originChain,
            contractAddress: address(feed),
            topic0: reactive.PRICE_TICK_TOPIC0(),
            topic1: id,
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, block.timestamp),
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        sys.trigger(address(reactive), log_);
    }

    /// @notice Publish a tick, then forward any vault events produced by the
    ///         resulting callback back into the reactive contract. This is the
    ///         production loop, compressed into one test block.
    function pushTickAndRelay(uint256 price) internal returns (uint256 id) {
        vm.recordLogs();
        id = pushTick(price);
        _relayVaultLogs(vm.getRecordedLogs());
    }

    function createPlanAndRelay(
        address user,
        uint256 basePerBuy,
        uint256 drawdownBps,
        uint256 cooldown,
        uint256 maxBuys,
        uint256 quoteBudget
    ) internal returns (uint256 planId) {
        vm.recordLogs();
        vm.prank(user);
        planId = vault.createPlan(basePerBuy, drawdownBps, cooldown, maxBuys, quoteBudget);
        _relayVaultLogs(vm.getRecordedLogs());
    }

    function fundPlanAndRelay(address user, uint256 planId, uint256 amount) internal {
        vm.recordLogs();
        vm.prank(user);
        vault.fundPlan(planId, amount);
        _relayVaultLogs(vm.getRecordedLogs());
    }

    function cancelPlanAndRelay(address user, uint256 planId) internal {
        vm.recordLogs();
        vm.prank(user);
        vault.cancelPlan(planId);
        _relayVaultLogs(vm.getRecordedLogs());
    }

    function _relayVaultLogs(Vm.Log[] memory logs) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault)) {
                relayLog(logs[i]);
            }
        }
    }

    function relayLog(Vm.Log memory log_) internal {
        IReactive.LogRecord memory rec = IReactive.LogRecord({
            chainId: originChain,
            contractAddress: log_.emitter,
            topic0: _topic(log_.topics, 0),
            topic1: _topic(log_.topics, 1),
            topic2: _topic(log_.topics, 2),
            topic3: _topic(log_.topics, 3),
            data: log_.data,
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        sys.trigger(address(reactive), rec);
    }

    function _topic(bytes32[] memory topics, uint256 i) internal pure returns (uint256) {
        if (i >= topics.length) return 0;
        return uint256(topics[i]);
    }

    // --------------------------------------------------------------------- //
    // convenience
    // --------------------------------------------------------------------- //

    function setupPlan(address user, uint256 quoteBudget) internal returns (uint256 planId) {
        vm.prank(user);
        vault.depositQuote(quoteBudget);
        planId = createPlanAndRelay(user, 0.01e18, 500, 3600, 10, quoteBudget);
    }

    function fundReserve(uint256 amount) internal {
        vault.depositBaseReserve(amount);
    }

    function assertAccounting() internal view {
        assertEq(usdc.balanceOf(address(vault)), vault.accountedQuote(), "quote accounting");
        assertEq(weth.balanceOf(address(vault)), vault.baseReserve(), "base reserve");
    }

    function planBuys(uint256 planId) internal view returns (uint256) {
        return vault.getPlan(planId).buys;
    }
}
