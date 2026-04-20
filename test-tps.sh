#!/bin/bash

set -euo pipefail

bold=$(tput bold 2>/dev/null || true)
cyan=$(tput setaf 6 2>/dev/null || true)
green=$(tput setaf 2 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)

MODEL="llama3.2:1b-instruct-q4_0"
PORT="8080"
SERVE_NAME="tps-test"

info()  { echo "${cyan}[INFO]${reset} $*"; }
ok()    { echo "${green}[OK]${reset} $*"; }
warn()  { echo "${yellow}[WARN]${reset} $*"; }
fatal() { echo "${red}[ERROR]${reset} $*" >&2; exit 1; }

run_cmd() {
    echo "${bold}\$ $*${reset}"
    "$@"
}

cleanup() {
    ramalama stop "$SERVE_NAME" 2>/dev/null || true
}
trap cleanup EXIT

info "Starting ramalama serve (detached, -c 4000)..."
run_cmd ramalama serve "$MODEL" --port "$PORT" --name "$SERVE_NAME" -c 4000 -d

info "Waiting for server to be ready..."
elapsed=0
while ! curl -sf http://127.0.0.1:"$PORT"/health &>/dev/null; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [[ $elapsed -ge 120 ]]; then
        fatal "Server did not become ready within 120s."
    fi
done
ok "Server is ready on http://127.0.0.1:${PORT}"
echo

info "Querying model..."

RESPONSE=$(curl -s http://127.0.0.1:"$PORT"/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "model",
        "messages": [
            {"role": "user", "content": "Give me a short story with exactly 300 words"}
        ]
    }')

PROMPT_TPS=$(echo "$RESPONSE" | python3 -c "import sys,json; t=json.load(sys.stdin).get('timings',{}); print(f\"{t.get('prompt_per_second',0):.2f}\")" 2>/dev/null || echo "N/A")
PREDICTED_TPS=$(echo "$RESPONSE" | python3 -c "import sys,json; t=json.load(sys.stdin).get('timings',{}); print(f\"{t.get('predicted_per_second',0):.2f}\")" 2>/dev/null || echo "N/A")

echo
echo "${bold}========== Performance ==========${reset}"
echo "  Prompt tokens/sec:     ${green}${PROMPT_TPS}${reset}"
echo "  Generation tokens/sec: ${green}${PREDICTED_TPS}${reset}"
echo "${bold}=================================${reset}"
echo

info "Stopping server..."
ramalama stop "$SERVE_NAME" >/dev/null 2>&1
ok "Done."
