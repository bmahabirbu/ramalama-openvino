#Requires -Version 5.1

<#
.SYNOPSIS
    Test script for the RamaLama OpenVINO backend on Windows.
.DESCRIPTION
    Part 1: Checks/installs ramalama and verifies podman is available.
    Part 2: Serves the model, queries it, and reports tokens per second.
#>

$ErrorActionPreference = "Stop"

$MODEL      = "llama3.2:1b-instruct-q4_0"
$SERVE_NAME = "openvino-test"

# --- helpers ----------------------------------------------------------------

function Write-Info    { param([string]$Msg) Write-Host "[INFO] " -ForegroundColor Cyan -NoNewline; Write-Host $Msg }
function Write-Ok      { param([string]$Msg) Write-Host "[OK]   " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Warn    { param([string]$Msg) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err     { param([string]$Msg) Write-Host "[ERROR] " -ForegroundColor Red -NoNewline; Write-Host $Msg }

function Write-Fatal {
    param([string]$Msg)
    Write-Err $Msg
    exit 1
}

function Write-Step {
    param([string]$Msg)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkGray
    Write-Info $Msg
    Write-Host ("=" * 60) -ForegroundColor DarkGray
    Write-Host ""
}

function Write-RunCmd {
    param([string]$Cmd)
    Write-Host "$ $Cmd" -ForegroundColor White
}

function Pause-Continue {
    Write-Host ""
    Write-Host "Press Enter to continue..." -ForegroundColor DarkGray -NoNewline
    Read-Host
}

# ============================================================================
# PART 1 : Installation & Environment Setup
# ============================================================================

function Install-Ramalama {
    Write-Step "Part 1: Installation & Environment Setup"

    # -- check ramalama -------------------------------------------------------
    if (Get-Command ramalama -ErrorAction SilentlyContinue) {
        Write-Ok "ramalama is already installed: $((Get-Command ramalama).Source)"
        Write-RunCmd "ramalama version"
        ramalama version
    }
    else {
        Write-Warn "ramalama not found. Installing via pip..."

        if (-not (Get-Command python -ErrorAction SilentlyContinue) -and
            -not (Get-Command python3 -ErrorAction SilentlyContinue)) {
            Write-Fatal "Python is required but not found. Please install Python 3.10+ from https://python.org"
        }

        $py = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } else { "python" }
        $ver = & $py -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        $parts = $ver -split '\.'
        if ([int]$parts[0] -lt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -lt 10)) {
            Write-Fatal "Python 3.10+ is required. Found: $ver"
        }

        if (Get-Command pip3 -ErrorAction SilentlyContinue) {
            Write-RunCmd "pip3 install ramalama"
            pip3 install ramalama
        }
        elseif (Get-Command pip -ErrorAction SilentlyContinue) {
            Write-RunCmd "pip install ramalama"
            pip install ramalama
        }
        else {
            Write-Fatal "pip is not installed. Please install pip for Python 3."
        }

        # refresh PATH so we can find ramalama
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")

        if (-not (Get-Command ramalama -ErrorAction SilentlyContinue)) {
            Write-Fatal "ramalama installation failed. Check the pip output above."
        }

        Write-Ok "ramalama installed successfully."
        Write-RunCmd "ramalama version"
        ramalama version
    }

    Write-Host ""

    # -- check container engine -----------------------------------------------
    Test-ContainerEngine
}

function Test-ContainerEngine {
    Write-Info "Checking for a container engine..."
    Write-Host ""

    if (Get-Command podman -ErrorAction SilentlyContinue) {
        Write-Ok "podman is available: $(podman --version)"

        # check if a podman machine is running
        $machines = podman machine list --format "{{.Running}}" --noheading 2>$null
        if ($machines -match "true") {
            Write-Ok "A podman machine is running."
            Write-RunCmd "podman machine list"
            podman machine list
        }
        else {
            Write-Warn "No podman machine is currently running."
            Write-Warn "Please open Podman Desktop and start (or create) a machine."
            Write-Warn "  Download: https://podman-desktop.io"
            Write-Host ""
            Write-Info "Once the machine is running, re-run this script."
            exit 1
        }
    }
    else {
        Write-Err "podman is not installed."
        Write-Host ""
        Write-Info "Please install Podman Desktop, which includes the podman CLI."
        Write-Info "  Download: https://podman-desktop.io"
        Write-Host ""
        Write-Info "After installing, create and start a podman machine, then re-run this script."
        exit 1
    }
}

# ============================================================================
# PART 2 : Serve, Query & Compare
# ============================================================================

$script:Results = @()

function Invoke-ServeAndQuery {
    param(
        [string]$Label,
        [int]$Port,
        [string[]]$ServeArgs
    )

    Write-Info "--- Test: $Label (port $Port) ---"
    Write-RunCmd "ramalama serve $($ServeArgs -join ' ') --port $Port --name $SERVE_NAME -c 4000 -d"

    & ramalama serve @ServeArgs --port $Port --name $SERVE_NAME -c 4000 -d

    $maxWait = 120
    $elapsed = 0
    while ($elapsed -lt $maxWait) {
        try {
            $health = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
            if ($health.StatusCode -eq 200) { break }
        } catch {}
        Start-Sleep -Seconds 2
        $elapsed += 2
    }

    if ($elapsed -ge $maxWait) {
        ramalama stop $SERVE_NAME 2>$null
        Write-Fatal "Server did not become ready within ${maxWait}s."
    }

    Write-Info 'Querying model with prompt: "Give me a short story with exactly 300 words"'

    $body = @{
        model    = "model"
        messages = @(
            @{ role = "user"; content = "Give me a short story with exactly 300 words" }
        )
    } | ConvertTo-Json -Depth 4

    $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" `
        -Method Post `
        -ContentType "application/json" `
        -Body $body

    $promptTps    = "N/A"
    $predictedTps = "N/A"

    if ($response.timings) {
        if ($response.timings.prompt_per_second) {
            $promptTps = "{0:N2}" -f $response.timings.prompt_per_second
        }
        if ($response.timings.predicted_per_second) {
            $predictedTps = "{0:N2}" -f $response.timings.predicted_per_second
        }
    }

    $script:Results += [PSCustomObject]@{
        Label        = $Label
        PromptTps    = $promptTps
        PredictedTps = $predictedTps
    }

    Write-Info "Stopping server..."
    & ramalama stop $SERVE_NAME 2>$null
    Write-Ok "$Label done.  Prompt: $promptTps t/s  |  Generation: $predictedTps t/s"
    Write-Host ""
}

function Run-Comparison {
    Write-Step "Part 2: OpenVINO Backend Comparison"

    # Test 1: Baseline (default backend, default image)
    Invoke-ServeAndQuery -Label "Baseline (default)" -Port 8080 `
        -ServeArgs @($MODEL, "--image", "quay.io/ramalama/ramalama:latest")

    # Test 2: OpenVINO CPU
    $env:GGML_OPENVINO_DEVICE = "CPU"
    Invoke-ServeAndQuery -Label "OpenVINO CPU" -Port 8085 `
        -ServeArgs @($MODEL, "--backend", "openvino", "--image", "quay.io/ramalama/openvino:latest")

    # Test 3: OpenVINO GPU
    $env:GGML_OPENVINO_DEVICE = "GPU"
    Invoke-ServeAndQuery -Label "OpenVINO GPU" -Port 8090 `
        -ServeArgs @($MODEL, "--backend", "openvino", "--image", "quay.io/ramalama/openvino:latest")
    Remove-Item Env:\GGML_OPENVINO_DEVICE

    # -- summary table --------------------------------------------------------
    Write-Host ""
    Write-Host "==================== Comparison Results ====================" -ForegroundColor White
    Write-Host ("{0,-22} {1,18} {2,18}" -f "Backend", "Prompt (t/s)", "Generation (t/s)") -ForegroundColor White
    Write-Host "  -----------------------------------------------------------"
    foreach ($r in $script:Results) {
        Write-Host ("  {0,-20} " -f $r.Label) -NoNewline
        Write-Host ("{0,18} " -f $r.PromptTps) -ForegroundColor Green -NoNewline
        Write-Host ("{0,18}" -f $r.PredictedTps) -ForegroundColor Green
    }
    Write-Host "=============================================================" -ForegroundColor White
}

# ============================================================================
# Main
# ============================================================================

Write-Host ""
Write-Host "===== RamaLama OpenVINO Backend Test Script =====" -ForegroundColor White
Write-Host ""

Install-Ramalama
Write-Host ""
Write-Ok "Part 1 complete. Environment is ready."

Pause-Continue

Run-Comparison

Write-Host ""
Write-Ok "All done!"
Write-Host ""
