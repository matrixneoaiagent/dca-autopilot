// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "reactive-lib/interfaces/ISystemContract.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";
import { AbstractReactive } from "reactive-lib/base/AbstractReactive.sol";

import { DcaConstants } from "./lib/DcaConstants.sol";
import { Owned } from "./lib/Owned.sol";

/// @title DcaReactive
/// @notice Lives on Reactive Lasna. Mirrors DCA plans from vault events, keeps
///         the rolling high-water mark and the last confirmed buy price for
///         each plan, and requests `DcaVault.executeBuy` when a plan is
///         eligible for another dip buy.
///
///         The reactive contract is trusted for trigger logic and liveness.
///         It is not trusted for funds: the vault authenticates every callback,
///         binds the price to a published tick, and re-checks the cooldown,
///         budget, reserve and (after the first buy) the drawdown.
contract DcaReactive is DcaConstants, Owned, AbstractReactive {
    struct Plan {
        address owner;
        uint256 basePerBuy;
        uint256 drawdownBps;
        uint256 cooldown;
        uint256 maxBuys;
        uint256 quoteBudget;
        uint256 quoteSpent;
        uint256 buys;
        uint256 highWater;
        uint256 lastBuyPrice;
        uint256 lastBuyAt;
        uint256 lastBuyTick;
        uint256 lastRequestTick;
        uint256 lastRequestAt;
        uint256 createdAt;
        bool active;
        bool exists;
    }

    uint256 public constant PRICE_TICK_TOPIC0 =
        uint256(keccak256("PriceTick(uint256,uint256,uint256)"));
    uint256 public constant PLAN_CREATED_TOPIC0 = uint256(
        keccak256("DcaPlanCreated(uint256,address,uint256,uint256,uint256,uint256,uint256)")
    );
    uint256 public constant PLAN_FUNDED_TOPIC0 =
        uint256(keccak256("DcaPlanBudgetIncreased(uint256,uint256,uint256)"));
    uint256 public constant PLAN_CANCELLED_TOPIC0 =
        uint256(keccak256("DcaPlanCancelled(uint256,uint256)"));
    uint256 public constant BUY_TOPIC0 =
        uint256(keccak256("DcaBuy(uint256,uint256,uint256,uint256,uint256)"));
    uint256 public constant SKIP_TOPIC0 =
        uint256(keccak256("DcaBuySkipped(uint256,uint256,uint8,uint256)"));

    uint256 public immutable ORIGIN_CHAIN_ID;
    address public immutable PRICE_FEED;
    uint256 public immutable DEST_CHAIN_ID;

    address public vault;

    uint64 public buyGasLimit = 600_000;
    uint256 public callbackTimeout = 300;

    bool public paused;

    uint256 public planCount;
    uint256 public lastPriceTickId;
    uint256 public lastPrice;
    uint256 public lastPriceAt;
    uint256 public highWater;
    uint256 public ticksSeen;

    mapping(uint256 => Plan) private _plans;
    uint256[] private _planIds;

    mapping(uint256 => bool) public pending;
    mapping(uint256 => uint256) public pendingTick;
    mapping(uint256 => uint256) public pendingSince;

    event VaultSet(address indexed vault);
    event PlanMirrored(uint256 indexed planId, address indexed owner);
    event PlanBudgetMirrored(uint256 indexed planId, uint256 newBudget);
    event PlanCancelledMirrored(uint256 indexed planId);
    event BuyRequested(uint256 indexed planId, uint256 indexed tickId, uint256 price);
    event BuyConfirmed(
        uint256 indexed planId,
        uint256 indexed tickId,
        uint256 quoteIn,
        uint256 baseOut,
        uint256 price
    );
    event BuySkipped(uint256 indexed planId, uint256 indexed tickId, uint8 reason, uint256 price);
    event BuyRetried(uint256 indexed planId, uint256 indexed tickId, uint256 price);
    event PendingExpired(uint256 indexed planId, uint256 indexed tickId);
    event PendingCleared(uint256 indexed planId, uint256 indexed tickId);
    event BuyGasLimitSet(uint64 gasLimit);
    event CallbackTimeoutSet(uint256 seconds_);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    error VaultAlreadySet();
    error BadGasLimit();
    error BadTimeout();
    error NoPendingRequest();
    error PendingNotStale();
    error PlanNotFound();
    error PlanNotActive();
    error PlanNotTriggerable();
    error NoFreshTick();
    error EnforcedPause();
    error ExpectedPause();

    constructor(uint256 originChainId_, address priceFeed_, uint256 destChainId_, address owner_)
        Owned(owner_)
    {
        if (priceFeed_ == address(0)) revert ZeroAddress();
        ORIGIN_CHAIN_ID = originChainId_;
        PRICE_FEED = priceFeed_;
        DEST_CHAIN_ID = destChainId_;

        SYSTEM.subscribe(
            originChainId_,
            priceFeed_,
            PRICE_TICK_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    // --------------------------------------------------------------------- //
    // owner configuration
    // --------------------------------------------------------------------- //

    /// @notice Bind the vault once and start the five vault-event
    ///         subscriptions. Plans created before this call are not mirrored.
    function setVault(address vault_) external onlyOwner {
        if (vault != address(0)) revert VaultAlreadySet();
        if (vault_ == address(0)) revert ZeroAddress();

        vault = vault_;
        _subscribe(vault_, PLAN_CREATED_TOPIC0);
        _subscribe(vault_, PLAN_FUNDED_TOPIC0);
        _subscribe(vault_, PLAN_CANCELLED_TOPIC0);
        _subscribe(vault_, BUY_TOPIC0);
        _subscribe(vault_, SKIP_TOPIC0);

        emit VaultSet(vault_);
    }

    function setBuyGasLimit(uint64 gasLimit_) external onlyOwner {
        if (gasLimit_ < 100_000 || gasLimit_ > 2_000_000) revert BadGasLimit();
        buyGasLimit = gasLimit_;
        emit BuyGasLimitSet(gasLimit_);
    }

    function setCallbackTimeout(uint256 seconds_) external onlyOwner {
        if (seconds_ < 30 || seconds_ > 3600) revert BadTimeout();
        callbackTimeout = seconds_;
        emit CallbackTimeoutSet(seconds_);
    }

    /// @notice Stop requesting new buys. Price tracking and HWM updates
    ///         continue, so a pause does not blind the next plan evaluation.
    function pause() external onlyOwner {
        if (paused) revert EnforcedPause();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert ExpectedPause();
        paused = false;
        emit Unpaused(msg.sender);
    }

    function coverDebt() external {
        _coverDebt();
    }

    function _subscribe(address contract_, uint256 topic0_) internal {
        SYSTEM.subscribe(
            DEST_CHAIN_ID, contract_, topic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    // --------------------------------------------------------------------- //
    // reactive entry point
    // --------------------------------------------------------------------- //

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (
            log_.chainId == ORIGIN_CHAIN_ID && log_.contractAddress == PRICE_FEED
                && log_.topic0 == PRICE_TICK_TOPIC0
        ) {
            _onPriceTick(log_);
            return;
        }

        if (vault == address(0) || log_.chainId != DEST_CHAIN_ID || log_.contractAddress != vault) {
            return;
        }

        if (log_.topic0 == PLAN_CREATED_TOPIC0) {
            _onPlanCreated(log_);
        } else if (log_.topic0 == PLAN_FUNDED_TOPIC0) {
            _onPlanFunded(log_);
        } else if (log_.topic0 == PLAN_CANCELLED_TOPIC0) {
            _onPlanCancelled(log_);
        } else if (log_.topic0 == BUY_TOPIC0) {
            _onBuy(log_);
        } else if (log_.topic0 == SKIP_TOPIC0) {
            _onBuySkipped(log_);
        }
    }

    function _onPriceTick(LogRecord calldata log_) internal {
        uint256 tickId = log_.topic1;
        if (tickId <= lastPriceTickId) return; // idempotent against replays

        (uint256 price, uint256 timestamp) = abi.decode(log_.data, (uint256, uint256));
        if (price == 0) return;

        lastPriceTickId = tickId;
        lastPrice = price;
        lastPriceAt = timestamp;
        ticksSeen++;
        if (price > highWater) highWater = price;

        uint256 length = _planIds.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 planId = _planIds[i];
            Plan storage p = _plans[planId];
            if (!p.exists) continue;
            if (price > p.highWater) p.highWater = price;
            _maybeTrigger(planId, tickId, price);
        }
    }

    function _maybeTrigger(uint256 planId, uint256 tickId, uint256 price) internal {
        Plan storage p = _plans[planId];
        if (!p.active || paused) return;

        if (pending[planId]) {
            if (block.timestamp <= pendingSince[planId] + callbackTimeout) return;
            uint256 staleTick = pendingTick[planId];
            pending[planId] = false;
            emit PendingExpired(planId, staleTick);
        }

        if (p.buys >= p.maxBuys || p.quoteSpent >= p.quoteBudget) return;
        if (p.buys > 0 && block.timestamp < p.lastBuyAt + p.cooldown) return;

        uint256 refPrice = p.lastBuyPrice > 0 ? p.lastBuyPrice : p.highWater;
        if (refPrice == 0) return;
        if (price * BPS > refPrice * (BPS - p.drawdownBps)) return;

        _requestBuy(planId, tickId, price);
    }

    function _requestBuy(uint256 planId, uint256 tickId, uint256 price) internal {
        pending[planId] = true;
        pendingTick[planId] = tickId;
        pendingSince[planId] = block.timestamp;

        Plan storage p = _plans[planId];
        p.lastRequestTick = tickId;
        p.lastRequestAt = block.timestamp;

        emit BuyRequested(planId, tickId, price);

        bytes memory payload = abi.encodeWithSignature(
            "executeBuy(address,uint256,uint256,uint256)", address(0), planId, tickId, price
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DEST_CHAIN_ID, recipient: vault, gasLimit: buyGasLimit, payload: payload
            })
        );
    }

    // --------------------------------------------------------------------- //
    // vault event mirroring
    // --------------------------------------------------------------------- //

    function _onPlanCreated(LogRecord calldata log_) internal {
        uint256 planId = log_.topic1;
        address planOwner = address(uint160(log_.topic2));
        if (planId == 0 || planId > MAX_PLANS || _plans[planId].exists) return;

        (
            uint256 basePerBuy,
            uint256 drawdownBps,
            uint256 cooldown,
            uint256 maxBuys,
            uint256 quoteBudget
        ) = abi.decode(log_.data, (uint256, uint256, uint256, uint256, uint256));

        // The vault already validated these. Mirror only sane values so a
        // malformed event cannot wedge the scan loop.
        if (
            basePerBuy == 0 || basePerBuy > MAX_BASE_PER_BUY || drawdownBps == 0
                || drawdownBps > MAX_DRAWDOWN_BPS || cooldown > MAX_COOLDOWN || maxBuys == 0
                || maxBuys > MAX_BUYS || quoteBudget == 0
        ) return;

        Plan storage p = _plans[planId];
        p.owner = planOwner;
        p.basePerBuy = basePerBuy;
        p.drawdownBps = drawdownBps;
        p.cooldown = cooldown;
        p.maxBuys = maxBuys;
        p.quoteBudget = quoteBudget;
        p.highWater = lastPrice;
        p.createdAt = block.timestamp;
        p.active = true;
        p.exists = true;

        _planIds.push(planId);
        planCount = _planIds.length;

        emit PlanMirrored(planId, planOwner);
    }

    function _onPlanFunded(LogRecord calldata log_) internal {
        uint256 planId = log_.topic1;
        Plan storage p = _plans[planId];
        if (!p.exists) return;

        (, uint256 newBudget) = abi.decode(log_.data, (uint256, uint256));
        p.quoteBudget = newBudget;
        emit PlanBudgetMirrored(planId, newBudget);
    }

    function _onPlanCancelled(LogRecord calldata log_) internal {
        uint256 planId = log_.topic1;
        Plan storage p = _plans[planId];
        if (!p.exists) return;

        p.active = false;
        pending[planId] = false;
        emit PlanCancelledMirrored(planId);
    }

    function _onBuy(LogRecord calldata log_) internal {
        uint256 planId = log_.topic1;
        uint256 tickId = log_.topic2;
        Plan storage p = _plans[planId];
        if (!p.exists) return;
        if (tickId <= p.lastBuyTick) return; // duplicate / stale log

        (uint256 quoteIn, uint256 baseOut, uint256 price) =
            abi.decode(log_.data, (uint256, uint256, uint256));

        pending[planId] = false;
        p.lastBuyPrice = price;
        p.lastBuyAt = block.timestamp;
        p.lastBuyTick = tickId;
        p.buys += 1;
        p.quoteSpent += quoteIn;
        if (price > p.highWater) p.highWater = price;

        emit BuyConfirmed(planId, tickId, quoteIn, baseOut, price);
    }

    function _onBuySkipped(LogRecord calldata log_) internal {
        uint256 planId = log_.topic1;
        uint256 tickId = log_.topic2;
        Plan storage p = _plans[planId];
        if (!p.exists) return;

        (uint8 reason, uint256 price) = abi.decode(log_.data, (uint8, uint256));
        if (tickId == pendingTick[planId]) pending[planId] = false;
        emit BuySkipped(planId, tickId, reason, price);
    }

    // --------------------------------------------------------------------- //
    // liveness fallback
    // --------------------------------------------------------------------- //

    /// @notice Permissionless recovery for a callback that never arrived. It
    ///         can only re-request a buy that still satisfies the plan's
    ///         drawdown, cooldown, budget and max-buy rules. The vault's tick
    ///         and price-age checks still apply, so a stale retry is skipped
    ///         rather than executed at an old price.
    function retry(uint256 planId) external {
        if (paused) revert EnforcedPause();

        Plan storage p = _plans[planId];
        if (!p.exists) revert PlanNotFound();
        if (!p.active) revert PlanNotActive();
        if (pending[planId] && block.timestamp <= pendingSince[planId] + callbackTimeout) {
            revert PendingNotStale();
        }
        if (p.buys >= p.maxBuys || p.quoteSpent >= p.quoteBudget) {
            revert PlanNotTriggerable();
        }
        if (p.buys > 0 && block.timestamp < p.lastBuyAt + p.cooldown) {
            revert PlanNotTriggerable();
        }

        uint256 refPrice = p.lastBuyPrice > 0 ? p.lastBuyPrice : p.highWater;
        if (lastPrice == 0 || refPrice == 0) revert PlanNotTriggerable();
        if (lastPrice * BPS > refPrice * (BPS - p.drawdownBps)) revert PlanNotTriggerable();
        if (lastPriceTickId <= p.lastBuyTick) revert NoFreshTick();

        _requestBuy(planId, lastPriceTickId, lastPrice);
        emit BuyRetried(planId, lastPriceTickId, lastPrice);
    }

    /// @notice Owner escape hatch for a pending request that the network will
    ///         never deliver. Never moves funds by itself.
    function clearPending(uint256 planId) external onlyOwner {
        if (!pending[planId]) revert NoPendingRequest();
        uint256 tickId = pendingTick[planId];
        pending[planId] = false;
        emit PendingCleared(planId, tickId);
    }

    // --------------------------------------------------------------------- //
    // views
    // --------------------------------------------------------------------- //

    function getPlan(uint256 planId) external view returns (Plan memory) {
        return _plans[planId];
    }

    function planIdAt(uint256 index) external view returns (uint256) {
        return _planIds[index];
    }

    function isTriggerable(uint256 planId) external view returns (bool) {
        Plan storage p = _plans[planId];
        if (!p.exists || !p.active || paused) return false;
        if (p.buys >= p.maxBuys || p.quoteSpent >= p.quoteBudget) return false;
        if (pending[planId] && block.timestamp <= pendingSince[planId] + callbackTimeout) {
            return false;
        }
        if (p.buys > 0 && block.timestamp < p.lastBuyAt + p.cooldown) return false;

        uint256 refPrice = p.lastBuyPrice > 0 ? p.lastBuyPrice : p.highWater;
        if (lastPrice == 0 || refPrice == 0) return false;
        return lastPrice * BPS <= refPrice * (BPS - p.drawdownBps);
    }
}
