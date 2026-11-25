#!/usr/bin/env bash
# One-command local rehearsal:
#   ./demo/local_demo.sh
#   PORT=8551 PYTHON=/path/to/venv/bin/python ./demo/local_demo.sh
#
# This starts Anvil, deploys the production contracts against mock system and
# callback-proxy contracts, creates a plan, publishes the price path, relays the
# network logs, and asserts the expected buys. It is not testnet evidence.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v forge >/dev/null 2>&1; then
  if [[ -x "$HOME/.foundry/bin/forge" ]]; then
    export PATH="$HOME/.foundry/bin:$PATH"
  else
    echo "forge/anvil/cast not found. Run inside: nix-shell -p foundry --run './demo/local_demo.sh'" >&2
    exit 2
  fi
fi

OUT=${OUT:-/tmp/opencode/dca-local.json}
PORT=${PORT:-8550}
export OUT PORT

./demo/local_deploy.sh

PY=${PYTHON:-}
if [[ -z "$PY" ]]; then
  if [[ -x .venv/bin/python ]]; then
    PY=.venv/bin/python
  else
    PY=python3
  fi
fi

if ! "$PY" -c 'import web3, eth_abi' >/dev/null 2>&1; then
  echo "Python dependencies missing. Create a venv:" >&2
  echo "  python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
  exit 2
fi

"$PY" demo/local_demo.py --addresses "$OUT"
