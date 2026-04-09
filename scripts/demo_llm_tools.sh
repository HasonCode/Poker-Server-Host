#!/usr/bin/env bash
# Fast demo: exercises poker_tools.execute_tool + POST /actions with NO LLM provider HTTP.
# Prerequisites:
#   1. poker-server running (e.g. POKER_PORT=8080)
#   2. Table llm_bots: open frontend/llm_spectate.html, Deal cards, so hand.status=active
#
# Usage:
#   ./scripts/demo_llm_tools.sh
#   POKER_SERVER_URL=http://127.0.0.1:9090 ./scripts/demo_llm_tools.sh

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export POKER_LLM_TABLE="${POKER_LLM_TABLE:-llm_bots}"
export POKER_SERVER_URL="${POKER_SERVER_URL:-http://127.0.0.1:${POKER_PORT:-8080}}"
# Two configured player_ids so one can be the actor; no API keys required with --demo-tools
export POKER_LLM_DEMO_PLAYERS="${POKER_LLM_DEMO_PLAYERS:-gpt_5_4,claude_4_6_opus}"

echo "=== llm_players tool demo (no provider keys) ==="
echo "Server: ${POKER_SERVER_URL}  table: ${POKER_LLM_TABLE}"
echo "Players: ${POKER_LLM_DEMO_PLAYERS}"
echo "If start-hand fails with 401, set POKER_LLM_SPECTATE_PASSWORD (default server password is often 1234)."
echo ""

exec python3 -u -m llm_players \
  --single-step \
  --demo-tools \
  --table "${POKER_LLM_TABLE}" \
  --url "${POKER_SERVER_URL}" \
  --players "${POKER_LLM_DEMO_PLAYERS}" \
  --out-dir "${ROOT}"
