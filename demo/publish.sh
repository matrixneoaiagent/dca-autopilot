#!/usr/bin/env bash
# Publish the demo price path to PriceFeed on the origin chain.
#
#   ./demo/publish.sh --calm
#   ./demo/publish.sh --dip
#   ./demo/publish.sh --story
#   ./demo/publish.sh --price 191000000000
#   INTERVAL=2 COOLDOWN_WAIT=35 ./demo/publish.sh --story
#
# Prices are 8-decimal USD per base token, e.g. 2000e8 = 200000000000.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v cast >/dev/null 2>&1; then
  if [[ -x "$HOME/.foundry/bin/cast" ]]; then
    export PATH="$HOME/.foundry/bin:$PATH"
  else
    echo "cast not found. Run inside: nix-shell -p foundry --run './demo/publish.sh --story'" >&2
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

AUTH=()
if [[ -n "${ACCOUNT:-}" ]]; then
  AUTH=(--account "$ACCOUNT")
elif [[ -n "${PRIVATE_KEY:-}" ]]; then
  AUTH=(--private-key "$PRIVATE_KEY")
else
  echo "set ACCOUNT or PRIVATE_KEY (see deploy/config.env.example)" >&2
  exit 2
fi

DEPLOY=${DEPLOY:-deployments/latest.json}
[[ -f "$DEPLOY" ]] || { echo "missing $DEPLOY; run ./deploy/deploy.sh first" >&2; exit 2; }
FEED=${PRICE_FEED:-$(jq -r .contracts.price_feed "$DEPLOY")}
INTERVAL=${INTERVAL:-12}
COOLDOWN_WAIT=${COOLDOWN_WAIT:-35}

MODE=${1:---story}
if [[ "$MODE" == "--price" ]]; then
  PRICE=${2:?--price requires an 8-decimal integer}
  PRICES=("$PRICE")
  WAITS=(0)
else
  case "$MODE" in
    --calm)
      PRICES=(200000000000 201000000000 202000000000 202000000000 195000000000)
      WAITS=(0 0 0 0 0)
      ;;
    --dip)
      PRICES=(191000000000 180000000000 170000000000 160000000000 150000000000 140000000000)
      WAITS=(0 "$COOLDOWN_WAIT" "$COOLDOWN_WAIT" "$COOLDOWN_WAIT" "$COOLDOWN_WAIT" 0)
      ;;
    --story)
      PRICES=(
        200000000000 201000000000 202000000000 202000000000
        195000000000 191000000000 185000000000 180000000000
        170000000000 160000000000 150000000000 140000000000
      )
      WAITS=(0 0 0 0 0 0 0 "$COOLDOWN_WAIT" "$COOLDOWN_WAIT" "$COOLDOWN_WAIT" "$COOLDOWN_WAIT" 0)
      ;;
    *)
      echo "usage: $0 [--calm|--dip|--story|--price N] [--interval N]" >&2
      exit 2
      ;;
  esac
fi

# allow --interval N as the second/third argument
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--interval" ]]; then
    j=$((i + 1))
    INTERVAL=${!j:?--interval requires a value}
  fi
done

price_usd() { awk -v p="$1" 'BEGIN { printf "%.2f", p / 100000000 }'; }

echo "feed $FEED  mode $MODE  interval ${INTERVAL}s  cooldown-wait ${COOLDOWN_WAIT}s"
for i in "${!PRICES[@]}"; do
  wait_s=${WAITS[$i]:-0}
  if ((wait_s > 0)); then
    echo "waiting ${wait_s}s for the plan cooldown..."
    sleep "$wait_s"
  fi
  price=${PRICES[$i]}
  tx=$(cast send --json --rpc-url "$RPC_ORIGIN" "${AUTH[@]}" "$FEED" "publish(uint256)" "$price" | jq -r .transactionHash)
  tick=$(cast call "$FEED" "tickId()(uint256)" --rpc-url "$RPC_ORIGIN" | tr -d ' ')
  printf 'tick %2s  price $%s  tx %s\n' "$tick" "$(price_usd "$price")" "$tx"
  if ((i + 1 < ${#PRICES[@]} && INTERVAL > 0)); then
    sleep "$INTERVAL"
  fi
done

echo
echo "Open the feed and vault on the explorer, then filter the vault for DcaBuy:"
echo "  $(jq -r .explorer "$DEPLOY")/address/$FEED"
echo "  $(jq -r .explorer "$DEPLOY")/address/$(jq -r .contracts.vault "$DEPLOY")"
