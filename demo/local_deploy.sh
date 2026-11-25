#!/usr/bin/env bash
# Local rehearsal only: deploy DCA Autopilot on Anvil with a mock Reactive
# system contract and a mock callback proxy. Generates throwaway addresses and
# transactions -- never submit these as hackathon evidence.
#
#   ./demo/local_deploy.sh
#   PORT=8551 ./demo/local_deploy.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v forge >/dev/null 2>&1; then
  if [[ -x "$HOME/.foundry/bin/forge" ]]; then
    export PATH="$HOME/.foundry/bin:$PATH"
  else
    echo "forge/anvil/cast not found. Run inside: nix-shell -p foundry --run './demo/local_deploy.sh'" >&2
    exit 2
  fi
fi

PORT=${PORT:-8550}
RPC=http://127.0.0.1:$PORT
CHAIN_ID=11155111
PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4
OUT=${OUT:-/tmp/opencode/dca-local.json}

if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  (anvil --chain-id "$CHAIN_ID" --port "$PORT" --silent >"/tmp/opencode/anvil-$PORT.log" 2>&1 &)
  sleep 2
fi

ACTUAL_ID=$(cast chain-id --rpc-url "$RPC")
if [[ "$ACTUAL_ID" != "$CHAIN_ID" ]]; then
  echo "Anvil on port $PORT is chain $ACTUAL_ID, expected $CHAIN_ID; use a different PORT" >&2
  exit 2
fi

A=$(cast rpc eth_accounts --rpc-url "$RPC" | jq -r '.[0]')
echo "anvil $RPC  chain $CHAIN_ID  account $A"

create() { forge create --json --broadcast --rpc-url "$RPC" --unlocked --from "$A" "$@"; }

# --- mock Reactive system + callback proxy -------------------------------- #
SYS_IMPL=$(create test/mocks/MockReactive.sol:MockSystem | jq -r .deployedTo)
PROXY_IMPL=$(create test/mocks/MockReactive.sol:MockProxy | jq -r .deployedTo)
cast rpc anvil_setCode 0x8888888888888888888888888888888888888888 \
  "$(cast code "$SYS_IMPL" --rpc-url "$RPC")" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setCode "$PROXY" \
  "$(cast code "$PROXY_IMPL" --rpc-url "$RPC")" --rpc-url "$RPC" >/dev/null
cast send --unlocked --from "$A" --rpc-url "$RPC" \
  0x8888888888888888888888888888888888888888 "setProxy(address)" "$PROXY" >/dev/null

# --- demo tokens ---------------------------------------------------------- #
USDC=$(create src/mocks/MockERC20.sol:MockERC20 \
  --constructor-args "Mock USD Coin" "mUSDC" 6 "$A" | jq -r .deployedTo)
WETH=$(create src/mocks/MockERC20.sol:MockERC20 \
  --constructor-args "Mock Wrapped Ether" "mWETH" 18 "$A" | jq -r .deployedTo)

# --- production contracts ------------------------------------------------- #
FEED=$(create src/PriceFeed.sol:PriceFeed --constructor-args "$A" "$A" | jq -r .deployedTo)
REACTIVE=$(create src/DcaReactive.sol:DcaReactive \
  --constructor-args "$CHAIN_ID" "$FEED" "$CHAIN_ID" "$A" | jq -r .deployedTo)
VAULT=$(create src/DcaVault.sol:DcaVault \
  --constructor-args "$USDC" "$WETH" "$FEED" "$PROXY" "$REACTIVE" "$A" | jq -r .deployedTo)
cast send --unlocked --from "$A" --rpc-url "$RPC" "$REACTIVE" "setVault(address)" "$VAULT" >/dev/null

jq -n \
  --arg system "0x8888888888888888888888888888888888888888" \
  --arg proxy "$PROXY" --arg usdc "$USDC" --arg weth "$WETH" \
  --arg feed "$FEED" --arg reactive "$REACTIVE" --arg vault "$VAULT" \
  --arg rpc "$RPC" --arg rpc_lasna "$RPC" --arg owner "$A" \
  --argjson chain_id "$CHAIN_ID" \
  '{system:$system, proxy:$proxy, usdc:$usdc, weth:$weth,
    feed:$feed, reactive:$reactive, vault:$vault,
    rpc:$rpc, rpc_lasna:$rpc_lasna, owner:$owner, chain_id:$chain_id}' >"$OUT"

echo "usdc      $USDC"
echo "weth      $WETH"
echo "feed      $FEED"
echo "reactive  $REACTIVE"
echo "vault     $VAULT"
echo "wrote $OUT"
