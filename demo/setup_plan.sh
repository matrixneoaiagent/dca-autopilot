#!/usr/bin/env bash
# Create the demo DCA plan and fund the vault's base-token reserve.
#
#   ./demo/setup_plan.sh
#
# Defaults to the deployer as both owner and demo user. If DEMO_USER differs,
# set DEMO_ACCOUNT or DEMO_PRIVATE_KEY so the user's approve/deposit/create
# transactions can be signed. The owner still mints the mock tokens and funds
# the reserve.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v cast >/dev/null 2>&1; then
  if [[ -x "$HOME/.foundry/bin/cast" ]]; then
    export PATH="$HOME/.foundry/bin:$PATH"
  else
    echo "cast not found. Run inside: nix-shell -p foundry --run './demo/setup_plan.sh'" >&2
    exit 2
  fi
fi
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

CONFIG=${CONFIG:-deploy/config.env}
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$CONFIG"; set +a
fi

ORIGIN_CHAIN=${ORIGIN_CHAIN:-sepolia}
case "$ORIGIN_CHAIN" in
  sepolia) DEFAULT_RPC=https://ethereum-sepolia-rpc.publicnode.com ;;
  base-sepolia) DEFAULT_RPC=https://sepolia.base.org ;;
  *) echo "ORIGIN_CHAIN must be sepolia or base-sepolia" >&2; exit 2 ;;
esac
: "${RPC_ORIGIN:=${RPC_BASE:-$DEFAULT_RPC}}"
: "${RPC_LASNA:=https://lasna-rpc.rnk.dev/}"
: "${DEMO_QUOTE_MINT:=100000000000}"          # 100,000 USDC
: "${DEMO_BASE_MINT:=10000000000000000000}"   # 10 WETH
: "${PLAN_BASE_PER_BUY:=10000000000000000}"   # 0.01 WETH
: "${PLAN_DRAWDOWN_BPS:=500}"                 # 5%
: "${PLAN_COOLDOWN:=30}"
: "${PLAN_MAX_BUYS:=5}"
: "${PLAN_BUDGET:=200000000}"                 # 200 USDC
: "${DEMO_QUOTE_DEPOSIT:=5000000000}"         # 5,000 USDC
: "${DEMO_BASE_RESERVE:=2000000000000000000}" # 2 WETH

DEPLOY=${DEPLOY:-deployments/latest.json}
[[ -f "$DEPLOY" ]] || { echo "missing $DEPLOY; run ./deploy/deploy.sh first" >&2; exit 2; }

USDC=$(jq -r .contracts.usdc "$DEPLOY")
WETH=$(jq -r .contracts.weth "$DEPLOY")
VAULT=$(jq -r .contracts.vault "$DEPLOY")
FEED=$(jq -r .contracts.price_feed "$DEPLOY")
REACTIVE=$(jq -r .contracts.reactive "$DEPLOY")
EXPLORER=$(jq -r .explorer "$DEPLOY")
OWNER_JSON=$(jq -r .owner "$DEPLOY")
: "${OWNER:=$OWNER_JSON}"
: "${DEMO_USER:=$(jq -r .demo_user "$DEPLOY")}"
: "${DEMO_USER:=$OWNER}"

AUTH=()
if [[ -n "${ACCOUNT:-}" ]]; then
  AUTH=(--account "$ACCOUNT")
elif [[ -n "${PRIVATE_KEY:-}" ]]; then
  AUTH=(--private-key "$PRIVATE_KEY")
else
  echo "set ACCOUNT or PRIVATE_KEY (see deploy/config.env.example)" >&2
  exit 2
fi

USER_AUTH=("${AUTH[@]}")
if [[ "$DEMO_USER" != "$OWNER" ]]; then
  if [[ -n "${DEMO_ACCOUNT:-}" ]]; then
    USER_AUTH=(--account "$DEMO_ACCOUNT")
  elif [[ -n "${DEMO_PRIVATE_KEY:-}" ]]; then
    USER_AUTH=(--private-key "$DEMO_PRIVATE_KEY")
  else
    echo "DEMO_USER=$DEMO_USER differs from OWNER; set DEMO_ACCOUNT or DEMO_PRIVATE_KEY" >&2
    exit 2
  fi
fi

MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935
say() { printf '\n== %s ==\n' "$*"; }

tx() {
  local auth_name=$1; shift
  local auth=()
  if [[ "$auth_name" == "user" ]]; then auth=("${USER_AUTH[@]}"); else auth=("${AUTH[@]}"); fi
  cast send --json --rpc-url "$RPC_ORIGIN" "${auth[@]}" "$@" | jq -r .transactionHash
}

say "mint demo tokens"
USDC_MINT_TX=$(tx owner "$USDC" "mint(address,uint256)" "$DEMO_USER" "$DEMO_QUOTE_MINT")
WETH_MINT_TX=$(tx owner "$WETH" "mint(address,uint256)" "$OWNER" "$DEMO_BASE_MINT")
echo "mint USDC  $USDC_MINT_TX"
echo "mint WETH  $WETH_MINT_TX"

say "approve vault"
USDC_APPROVE_TX=$(tx user "$USDC" "approve(address,uint256)" "$VAULT" "$MAX")
WETH_APPROVE_TX=$(tx owner "$WETH" "approve(address,uint256)" "$VAULT" "$MAX")
echo "approve USDC $USDC_APPROVE_TX"
echo "approve WETH $WETH_APPROVE_TX"

say "deposit quote and create plan"
DEPOSIT_TX=$(tx user "$VAULT" "depositQuote(uint256)" "$DEMO_QUOTE_DEPOSIT")
CREATE_TX=$(tx user "$VAULT" \
  "createPlan(uint256,uint256,uint256,uint256,uint256)" \
  "$PLAN_BASE_PER_BUY" "$PLAN_DRAWDOWN_BPS" "$PLAN_COOLDOWN" "$PLAN_MAX_BUYS" "$PLAN_BUDGET")
PLAN_ID=$(cast call "$VAULT" "planCount()(uint256)" --rpc-url "$RPC_ORIGIN" | tr -d ' ')
echo "deposit    $DEPOSIT_TX"
echo "createPlan $CREATE_TX  plan $PLAN_ID"

say "fund base reserve"
RESERVE_TX=$(tx owner "$VAULT" "depositBaseReserve(uint256)" "$DEMO_BASE_RESERVE")
echo "reserve    $RESERVE_TX"

say "verify"
echo "plan id         $PLAN_ID"
echo "vault paused    $(cast call "$VAULT" "paused()(bool)" --rpc-url "$RPC_ORIGIN")"
RPLAN=$(cast call "$REACTIVE" "planCount()(uint256)" --rpc-url "$RPC_LASNA" 2>/dev/null || echo "?")
echo "reactive plan   $RPLAN  (0 = DcaPlanCreated not delivered yet; check Reactscan)"
echo "feed tick       $(cast call "$FEED" "tickId()(uint256)" --rpc-url "$RPC_ORIGIN")"

TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p deployments
jq -n \
  --arg ts "$TS" --argjson plan_id "${PLAN_ID:-0}" \
  --arg owner "$OWNER" --arg demo_user "$DEMO_USER" \
  --arg usdc_mint "$USDC_MINT_TX" --arg weth_mint "$WETH_MINT_TX" \
  --arg usdc_approve "$USDC_APPROVE_TX" --arg weth_approve "$WETH_APPROVE_TX" \
  --arg deposit "$DEPOSIT_TX" --arg create "$CREATE_TX" --arg reserve "$RESERVE_TX" \
  --argjson base_per_buy "$PLAN_BASE_PER_BUY" --argjson drawdown_bps "$PLAN_DRAWDOWN_BPS" \
  --argjson cooldown "$PLAN_COOLDOWN" --argjson max_buys "$PLAN_MAX_BUYS" --argjson budget "$PLAN_BUDGET" \
  --arg explorer "$EXPLORER" \
  '{ts:$ts, plan_id:$plan_id, owner:$owner, demo_user:$demo_user,
    params:{base_per_buy:$base_per_buy, drawdown_bps:$drawdown_bps, cooldown:$cooldown,
            max_buys:$max_buys, quote_budget:$budget},
    txs:{mint_usdc:$usdc_mint, mint_weth:$weth_mint, approve_usdc:$usdc_approve,
         approve_weth:$weth_approve, deposit_quote:$deposit, create_plan:$create,
         deposit_base_reserve:$reserve},
    explorer:$explorer}' >deployments/demo-latest.json
echo "wrote deployments/demo-latest.json"

say "next"
echo "./demo/publish.sh --story          # publish the demo price path"
echo "python3 demo/monitor.py --watch     # terminal dashboard"
