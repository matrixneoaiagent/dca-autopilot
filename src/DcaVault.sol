// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "reactive-lib/interfaces/IPayable.sol";
import { AbstractCallback } from "reactive-lib/base/AbstractCallback.sol";

import { IERC20 } from "./interfaces/IERC20.sol";
import { IPriceFeed } from "./interfaces/IPriceFeed.sol";
import { DcaConstants } from "./lib/DcaConstants.sol";
import { Owned } from "./lib/Owned.sol";
import { ReentrancyGuard } from "./lib/ReentrancyGuard.sol";
import { SafeERC20 } from "./lib/SafeERC20.sol";

/// @title DcaVault
/// @notice Holds the demo quote token (USDC) and base-token reserve (WETH) on
///         the origin/destination chain. Users allocate a quote budget to a
///         plan; the Reactive contract on Lasna asks this vault to execute a
///         buy when its drawdown rule fires.
///
///         The vault is the funds boundary. It authenticates the callback
///         proxy and the reactive contract, binds the callback price to a real
///         published tick, and independently enforces the cooldown, the
///         per-plan budget, the last-buy drawdown (after the first buy), and
///         the base reserve. A business-rule miss is a `DcaBuySkipped` event,
///         not a revert, so a failed opportunity never traps user funds.
contract DcaVault is DcaConstants, Owned, ReentrancyGuard, AbstractCallback {
    using SafeERC20 for IERC20;

    enum SkipReason {
        None,
        Paused,
        UnknownPlan,
        InactivePlan,
        StaleTick,
        StalePrice,
        MaxBuys,
        Cooldown,
        NotDipped,
        BudgetExceeded,
        InsufficientReserve
    }

    struct Plan {
        address owner;
        uint256 basePerBuy;
        uint256 drawdownBps;
        uint256 cooldown;
        uint256 maxBuys;
        uint256 quoteBudget;
        uint256 quoteSpent;
        uint256 buys;
        uint256 lastBuyAt;
        uint256 lastBuyPrice;
        uint256 lastTickId;
        uint256 createdAt;
        bool active;
    }

    IERC20 public immutable quoteToken;
    IERC20 public immutable baseToken;
    IPriceFeed public immutable priceFeed;
    uint8 public immutable quoteDecimals;
    uint8 public immutable baseDecimals;
    uint256 public immutable quoteScale;
    uint256 public immutable baseScale;

    bool public paused;

    uint256 public planCount;
    uint256 public baseReserve;
    uint256 public quoteReserve;
    uint256 public totalQuoteDeposited;
    uint256 public totalUnallocated;
    uint256 public totalPlanRemaining;
    uint256 public maxPriceAge = 1 hours;

    mapping(address => uint256) public quoteBalance;
    mapping(uint256 => Plan) private _plans;

    event QuoteDeposited(address indexed user, uint256 amount);
    event QuoteWithdrawn(address indexed user, uint256 amount);
    event BaseReserveDeposited(address indexed from, uint256 amount);
    event BaseReserveWithdrawn(address indexed to, uint256 amount);
    event QuoteReserveWithdrawn(address indexed to, uint256 amount);
    event MaxPriceAgeSet(uint256 seconds_);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event DcaPlanCreated(
        uint256 indexed planId,
        address indexed owner,
        uint256 basePerBuy,
        uint256 drawdownBps,
        uint256 cooldown,
        uint256 maxBuys,
        uint256 quoteBudget
    );
    event DcaPlanBudgetIncreased(uint256 indexed planId, uint256 added, uint256 newBudget);
    event DcaPlanCancelled(uint256 indexed planId, uint256 refund);
    event DcaBuy(
        uint256 indexed planId,
        uint256 indexed tickId,
        uint256 quoteIn,
        uint256 baseOut,
        uint256 price
    );
    event DcaBuySkipped(
        uint256 indexed planId, uint256 indexed tickId, uint8 reason, uint256 price
    );

    error InvalidBaseAmount();
    error InvalidDrawdown();
    error InvalidCooldown();
    error InvalidMaxBuys();
    error InvalidBudget();
    error InvalidAmount();
    error InvalidMaxPriceAge();
    error InsufficientQuote();
    error InsufficientReserve();
    error PlanLimit();
    error NotPlanOwner();
    error PlanNotActive();
    error UnsupportedDecimals();
    error PriceMismatch(uint256 tickId, uint256 supplied, uint256 oracle);
    error EnforcedPause();
    error ExpectedPause();

    constructor(
        IERC20 quoteToken_,
        IERC20 baseToken_,
        IPriceFeed priceFeed_,
        IPayable callbackProxy_,
        address callbackSender_,
        address owner_
    ) Owned(owner_) AbstractCallback(callbackProxy_, callbackSender_) {
        if (
            address(quoteToken_) == address(0) || address(baseToken_) == address(0)
                || address(priceFeed_) == address(0) || address(callbackProxy_) == address(0)
                || callbackSender_ == address(0)
        ) revert ZeroAddress();

        uint8 qd = quoteToken_.decimals();
        uint8 bd = baseToken_.decimals();
        if (qd > 18 || bd > 18) revert UnsupportedDecimals();

        quoteToken = quoteToken_;
        baseToken = baseToken_;
        priceFeed = priceFeed_;
        quoteDecimals = qd;
        baseDecimals = bd;
        quoteScale = 10 ** qd;
        baseScale = 10 ** bd;
    }

    // --------------------------------------------------------------------- //
    // user side
    // --------------------------------------------------------------------- //

    /// @notice Deposit quote tokens into the user's unallocated balance.
    function depositQuote(uint256 amount) external nonReentrant {
        if (paused) revert EnforcedPause();
        if (amount == 0) revert InvalidAmount();

        quoteToken.safeTransferFrom(msg.sender, address(this), amount);
        quoteBalance[msg.sender] += amount;
        totalUnallocated += amount;
        totalQuoteDeposited += amount;
        emit QuoteDeposited(msg.sender, amount);
    }

    /// @notice Withdraw quote tokens that are not allocated to a plan. Always
    ///         available, including while the vault is paused.
    function withdrawQuote(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (quoteBalance[msg.sender] < amount) revert InsufficientQuote();

        quoteBalance[msg.sender] -= amount;
        totalUnallocated -= amount;
        quoteToken.safeTransfer(msg.sender, amount);
        emit QuoteWithdrawn(msg.sender, amount);
    }

    /// @notice Create a DCA plan. `quoteBudget` is moved from the caller's
    ///         unallocated balance into the plan.
    /// @param basePerBuy Fixed base-token amount bought on each trigger.
    /// @param drawdownBps Minimum drop from the reference, in basis points.
    /// @param cooldown Minimum seconds between buys.
    /// @param maxBuys Maximum number of buys.
    /// @param quoteBudget Total quote budget allocated to the plan.
    function createPlan(
        uint256 basePerBuy,
        uint256 drawdownBps,
        uint256 cooldown,
        uint256 maxBuys,
        uint256 quoteBudget
    ) external nonReentrant returns (uint256 planId) {
        if (paused) revert EnforcedPause();
        if (basePerBuy == 0 || basePerBuy > MAX_BASE_PER_BUY) revert InvalidBaseAmount();
        if (drawdownBps == 0 || drawdownBps > MAX_DRAWDOWN_BPS) revert InvalidDrawdown();
        if (cooldown > MAX_COOLDOWN) revert InvalidCooldown();
        if (maxBuys == 0 || maxBuys > MAX_BUYS) revert InvalidMaxBuys();
        if (quoteBudget == 0) revert InvalidBudget();
        if (planCount >= MAX_PLANS) revert PlanLimit();
        if (quoteBalance[msg.sender] < quoteBudget) revert InsufficientQuote();

        quoteBalance[msg.sender] -= quoteBudget;
        totalUnallocated -= quoteBudget;
        totalPlanRemaining += quoteBudget;

        planId = ++planCount;
        _plans[planId] = Plan({
            owner: msg.sender,
            basePerBuy: basePerBuy,
            drawdownBps: drawdownBps,
            cooldown: cooldown,
            maxBuys: maxBuys,
            quoteBudget: quoteBudget,
            quoteSpent: 0,
            buys: 0,
            lastBuyAt: 0,
            lastBuyPrice: 0,
            lastTickId: 0,
            createdAt: block.timestamp,
            active: true
        });

        emit DcaPlanCreated(
            planId, msg.sender, basePerBuy, drawdownBps, cooldown, maxBuys, quoteBudget
        );
    }

    /// @notice Add quote budget to an existing plan.
    function fundPlan(uint256 planId, uint256 amount) external nonReentrant {
        if (paused) revert EnforcedPause();
        Plan storage p = _plans[planId];
        if (p.owner != msg.sender) revert NotPlanOwner();
        if (!p.active) revert PlanNotActive();
        if (amount == 0) revert InvalidAmount();
        if (quoteBalance[msg.sender] < amount) revert InsufficientQuote();

        quoteBalance[msg.sender] -= amount;
        totalUnallocated -= amount;
        totalPlanRemaining += amount;
        p.quoteBudget += amount;

        emit DcaPlanBudgetIncreased(planId, amount, p.quoteBudget);
    }

    /// @notice Cancel a plan and return its unspent budget to the caller's
    ///         unallocated balance. Always available, including while paused.
    function cancelPlan(uint256 planId) external nonReentrant {
        Plan storage p = _plans[planId];
        if (p.owner != msg.sender) revert NotPlanOwner();
        if (!p.active) revert PlanNotActive();

        uint256 refund = p.quoteBudget - p.quoteSpent;
        p.active = false;
        quoteBalance[msg.sender] += refund;
        totalPlanRemaining -= refund;
        totalUnallocated += refund;

        emit DcaPlanCancelled(planId, refund);
    }

    // --------------------------------------------------------------------- //
    // reactive callback
    // --------------------------------------------------------------------- //

    /// @notice Called by the Reactive callback proxy on behalf of the reactive
    ///         contract. The first argument is replaced by the proxy with the
    ///         requesting reactive address; both checks must pass.
    ///
    ///         Returns false and emits `DcaBuySkipped` for business-rule
    ///         misses. Reverts for an unauthorized caller or a price that does
    ///         not match the published tick.
    function executeBuy(address reactive_, uint256 planId, uint256 tickId, uint256 price)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
        nonReentrant
        returns (bool executed)
    {
        if (paused) return _skip(planId, tickId, SkipReason.Paused, price);

        Plan storage p = _plans[planId];
        if (p.owner == address(0)) {
            return _skip(planId, tickId, SkipReason.UnknownPlan, price);
        }
        if (!p.active) return _skip(planId, tickId, SkipReason.InactivePlan, price);
        if (tickId <= p.lastTickId) return _skip(planId, tickId, SkipReason.StaleTick, price);

        uint256 oraclePrice = priceFeed.priceOf(tickId);
        if (oraclePrice == 0 || oraclePrice != price) {
            revert PriceMismatch(tickId, price, oraclePrice);
        }
        uint256 published = priceFeed.publishedAt(tickId);
        if (published == 0 || block.timestamp > published + maxPriceAge) {
            return _skip(planId, tickId, SkipReason.StalePrice, price);
        }

        if (p.buys >= p.maxBuys) return _skip(planId, tickId, SkipReason.MaxBuys, price);
        if (p.buys > 0 && block.timestamp < p.lastBuyAt + p.cooldown) {
            return _skip(planId, tickId, SkipReason.Cooldown, price);
        }
        // Defence in depth: the reactive contract already checks this, but the
        // vault independently rejects a callback that is not a real dip below
        // the last confirmed buy. The first buy is checked by the reactive
        // against the plan's rolling high-water mark.
        if (p.buys > 0 && price * BPS > p.lastBuyPrice * (BPS - p.drawdownBps)) {
            return _skip(planId, tickId, SkipReason.NotDipped, price);
        }

        uint256 quoteIn = quoteFor(p.basePerBuy, price);
        if (quoteIn > p.quoteBudget - p.quoteSpent) {
            return _skip(planId, tickId, SkipReason.BudgetExceeded, price);
        }
        if (baseReserve < p.basePerBuy) {
            return _skip(planId, tickId, SkipReason.InsufficientReserve, price);
        }

        // effects
        p.quoteSpent += quoteIn;
        p.buys += 1;
        p.lastBuyAt = block.timestamp;
        p.lastBuyPrice = price;
        p.lastTickId = tickId;
        baseReserve -= p.basePerBuy;
        totalPlanRemaining -= quoteIn;
        quoteReserve += quoteIn;

        // interaction
        baseToken.safeTransfer(p.owner, p.basePerBuy);

        emit DcaBuy(planId, tickId, quoteIn, p.basePerBuy, price);
        return true;
    }

    function _skip(uint256 planId, uint256 tickId, SkipReason reason, uint256 price)
        internal
        returns (bool)
    {
        emit DcaBuySkipped(planId, tickId, uint8(reason), price);
        return false;
    }

    // --------------------------------------------------------------------- //
    // owner reserve and pause
    // --------------------------------------------------------------------- //

    /// @notice Fund the base-token reserve that backs all buys. The owner must
    ///         approve this contract first.
    function depositBaseReserve(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert InvalidAmount();
        baseToken.safeTransferFrom(msg.sender, address(this), amount);
        baseReserve += amount;
        emit BaseReserveDeposited(msg.sender, amount);
    }

    /// @notice Withdraw unused base-token reserve. Blocked while paused so the
    ///         emergency switch also protects the reserve.
    function withdrawBaseReserve(uint256 amount) external onlyOwner nonReentrant {
        if (paused) revert EnforcedPause();
        if (amount == 0) revert InvalidAmount();
        if (baseReserve < amount) revert InsufficientReserve();

        baseReserve -= amount;
        baseToken.safeTransfer(msg.sender, amount);
        emit BaseReserveWithdrawn(msg.sender, amount);
    }

    /// @notice Withdraw quote tokens received from executed buys. This is
    ///         protocol revenue, not user budget.
    function withdrawQuoteReserve(uint256 amount) external onlyOwner nonReentrant {
        if (paused) revert EnforcedPause();
        if (amount == 0) revert InvalidAmount();
        if (quoteReserve < amount) revert InsufficientReserve();

        quoteReserve -= amount;
        quoteToken.safeTransfer(msg.sender, amount);
        emit QuoteReserveWithdrawn(msg.sender, amount);
    }

    function setMaxPriceAge(uint256 seconds_) external onlyOwner {
        if (seconds_ < 60 || seconds_ > 7 days) revert InvalidMaxPriceAge();
        maxPriceAge = seconds_;
        emit MaxPriceAgeSet(seconds_);
    }

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

    // --------------------------------------------------------------------- //
    // views
    // --------------------------------------------------------------------- //

    /// @notice Quote cost of `baseAmount` at `price`, rounded up in favour of
    ///         the reserve. Price has 8 decimals; token decimals are handled
    ///         generically.
    function quoteFor(uint256 baseAmount, uint256 price) public view returns (uint256) {
        uint256 numerator = baseAmount * price * quoteScale;
        uint256 denominator = PRICE_SCALE * baseScale;
        return (numerator + denominator - 1) / denominator;
    }

    /// @notice Sum of every quote liability accounted for by the vault. It must
    ///         equal the vault's quote-token balance (absent direct transfers).
    function accountedQuote() external view returns (uint256) {
        return totalUnallocated + totalPlanRemaining + quoteReserve;
    }

    function getPlan(uint256 planId) external view returns (Plan memory) {
        return _plans[planId];
    }

    function isPlanActive(uint256 planId) external view returns (bool) {
        return _plans[planId].active;
    }
}
