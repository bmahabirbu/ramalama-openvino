#!/bin/bash

set -euo pipefail

bold=$(tput bold 2>/dev/null || true)
cyan=$(tput setaf 6 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true)
green=$(tput setaf 2 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)

MODEL="llama3.2:1b-instruct-q4_0"
SERVE_NAME="openvino-test"

info()  { echo "${cyan}[INFO]${reset} $*"; }
ok()    { echo "${green}[OK]${reset} $*"; }
warn()  { echo "${yellow}[WARN]${reset} $*"; }
error() { echo "${red}[ERROR]${reset} $*" >&2; }
fatal() { error "$@"; exit 1; }

run_cmd() {
    echo "${bold}\$ $*${reset}"
    "$@"
}

pause_continue() {
    echo
    read -r -p "Press Enter to continue..."
}

OS="$(uname -s)"

if [[ "$OS" != "Linux" ]]; then
    fatal "This script supports Linux only. Use test-openvino.ps1 for Windows."
fi

# ============================================================================
# PART 1: Installation & Environment Setup
# ============================================================================

install_ramalama() {
    info "============================================"
    info "Part 1: Installation & Environment Setup"
    info "============================================"
    echo

    if command -v ramalama &>/dev/null; then
        ok "ramalama is already installed: $(command -v ramalama)"
        run_cmd ramalama version
        echo
    else
        warn "ramalama not found. Installing via pip..."
        echo

        if ! command -v python3 &>/dev/null; then
            fatal "python3 is required but not found. Please install Python 3.10+."
        fi

        python3 -c 'import sys; exit(0 if sys.version_info >= (3, 10) else 1)' || \
            fatal "Python 3.10+ is required. Found: $(python3 --version)"

        if command -v pip3 &>/dev/null; then
            run_cmd pip3 install ramalama
        elif command -v pip &>/dev/null; then
            run_cmd pip install ramalama
        else
            fatal "pip is not installed. Please install pip for Python 3."
        fi

        if ! command -v ramalama &>/dev/null; then
            fatal "ramalama installation failed. Please check pip output above."
        fi

        ok "ramalama installed successfully."
        run_cmd ramalama version
        echo
    fi

    setup_container_engine
}

setup_container_engine() {
    info "Checking for a container engine..."
    echo

    if command -v podman &>/dev/null; then
        ok "podman is available: $(podman --version)"
        echo

    else
        error "podman is not installed."
        echo
        info "Please install podman for your distribution:"
        info "  Fedora/RHEL:   sudo dnf install -y podman"
        info "  Debian/Ubuntu: sudo apt install -y podman"
        info "  Arch:          sudo pacman -S podman"
        info "  openSUSE:      sudo zypper install -y podman"
        echo
        info "Then re-run this script."
        exit 1
    fi
}

# ============================================================================
# PART 2: Serve, Query & Compare
# ============================================================================

serve_and_query() {
    local label="$1"
    local port="$2"
    local serve_args=("${@:3}")

    info "--- Test: ${label} (port ${port}) ---"
    echo "${bold}\$ ramalama serve ${serve_args[*]} --port ${port} --name ${SERVE_NAME} -c 4000 -d${reset}"

    ramalama serve "${serve_args[@]}" \
        --port "$port" \
        --name "$SERVE_NAME" \
        -c 4000 \
        -d

    local max_wait=120
    local elapsed=0
    while ! curl -sf http://127.0.0.1:"$port"/health &>/dev/null; do
        sleep 2
        elapsed=$((elapsed + 2))
        if [[ $elapsed -ge $max_wait ]]; then
            ramalama stop "$SERVE_NAME" 2>/dev/null || true
            fatal "Server did not become ready within ${max_wait}s."
        fi
    done

    info "Querying model with prompt: \"Give me a short story with exactly 300 words\""

    RESPONSE=$(curl -s http://127.0.0.1:"$port"/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{
            "model": "model",
            "messages": [
                {"role": "user", "content": "Give me a short story with exactly 300 words"}
            ]
        }')

    local prompt_tps predicted_tps
    prompt_tps=$(echo "$RESPONSE" | python3 -c "import sys,json; t=json.load(sys.stdin).get('timings',{}); print(f\"{t.get('prompt_per_second',0):.2f}\")" 2>/dev/null || echo "N/A")
    predicted_tps=$(echo "$RESPONSE" | python3 -c "import sys,json; t=json.load(sys.stdin).get('timings',{}); print(f\"{t.get('predicted_per_second',0):.2f}\")" 2>/dev/null || echo "N/A")

    # store results for summary table
    RESULTS+=("${label}|${prompt_tps}|${predicted_tps}")

    info "Stopping server..."
    ramalama stop "$SERVE_NAME" >/dev/null 2>&1
    ok "${label} done.  Prompt: ${prompt_tps} t/s  |  Generation: ${predicted_tps} t/s"
    echo
}

run_comparison() {
    info "============================================"
    info "Part 2: OpenVINO Backend Comparison"
    info "============================================"
    echo

    RESULTS=()

    # Test 1: Baseline (default backend, default image)
    serve_and_query "Baseline (default)" 8080 \
        "$MODEL" --image "quay.io/ramalama/ramalama:latest"

    # Test 2: OpenVINO CPU
    export GGML_OPENVINO_DEVICE=CPU
    serve_and_query "OpenVINO CPU" 8085 \
        "$MODEL" --backend openvino --image "quay.io/ramalama/openvino:latest"

    # Test 3: OpenVINO GPU
    export GGML_OPENVINO_DEVICE=GPU
    serve_and_query "OpenVINO GPU" 8090 \
        "$MODEL" --backend openvino --image "quay.io/ramalama/openvino:latest"
    unset GGML_OPENVINO_DEVICE

    # -- summary table --------------------------------------------------------
    echo
    echo "${bold}==================== Comparison Results ====================${reset}"
    printf "${bold}  %-20s  %18s  %18s${reset}\n" "Backend" "Prompt (t/s)" "Generation (t/s)"
    echo "  -----------------------------------------------------------"
    for entry in "${RESULTS[@]}"; do
        IFS='|' read -r label prompt_tps predicted_tps <<< "$entry"
        printf "  %-20s  ${green}%18s${reset}  ${green}%18s${reset}\n" "$label" "$prompt_tps" "$predicted_tps"
    done
    echo "${bold}=============================================================${reset}"
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo
    echo "${bold}===== RamaLama OpenVINO Backend Test Script =====${reset}"
    echo

    install_ramalama
    echo
    ok "Part 1 complete. Environment is ready."

    pause_continue

    run_comparison
    echo
    ok "All done!"
    echo
}

main "$@"
