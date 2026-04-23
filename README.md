# RamaLama OpenVINO Backend Testing

This project uses [RamaLama](https://github.com/containers/ramalama) to test [OpenVINO](https://github.com/openvinotoolkit/openvino) backend performance for LLM inference. The test scripts serve a model under three configurations — default baseline, OpenVINO on CPU, and OpenVINO on GPU — then compare tokens-per-second across all three.

## What the Test Does

The script runs three back-to-back inference tests using the `llama3.2:1b-instruct-q4_0` model:

| Test | Backend | Device | Image |
|------|---------|--------|-------|
| Baseline | default | — | `quay.io/ramalama/ramalama:latest` |
| OpenVINO CPU | `openvino` | CPU | `quay.io/ramalama/openvino:latest` |
| OpenVINO GPU | `openvino` | GPU | `quay.io/ramalama/openvino:latest` |

For each test, the script:

1. Starts a `ramalama serve` instance in detached mode on a dedicated port
2. Waits for the server health check to pass (up to 120 seconds)
3. Sends a chat completion request to the `/v1/chat/completions` endpoint
4. Extracts `prompt_per_second` and `predicted_per_second` from the response timings
5. Stops the server and moves on to the next test

At the end, a summary table shows the tokens-per-second comparison across all three configurations.

### Key Flags

- **`--backend openvino`** — Tells RamaLama to use the OpenVINO backend. This is required so the correct environment variables (e.g. `GGML_OPENVINO_DEVICE`) are picked up inside the container.
- **`--image quay.io/ramalama/openvino:latest`** — Points to the container image built with OpenVINO support. In the future, `--image` will not be needed as the OpenVINO image will be resolved automatically by RamaLama.

## Prerequisites

- **Python 3.10+**
- **pip**
- **Podman** (Linux) or **Podman Desktop** (Windows)

## Installation

### 1. Install RamaLama

RamaLama requires Python 3.10 or later. Install it with pip:

```bash
pip install ramalama
```

Verify the installation:

```bash
ramalama version
```

### 2. Install Podman

RamaLama uses a container engine to serve models. Podman is the supported engine.

#### Linux

Install podman using your distribution's package manager:

```bash
# Fedora / RHEL
sudo dnf install -y podman

# Debian / Ubuntu
sudo apt install -y podman

# Arch
sudo pacman -S podman

# openSUSE
sudo zypper install -y podman
```

#### Windows

On Windows, install **Podman Desktop** which includes the podman CLI:

1. Download and install [Podman Desktop](https://podman-desktop.io)
2. Open Podman Desktop
3. Create and start a Podman machine through the GUI — follow the [Creating a Podman machine](https://podman-desktop.io/docs/podman/creating-a-podman-machine) guide
4. Verify the machine is running before proceeding

## Running the Tests

### Linux

```bash
chmod +x test-openvino.sh
./test-openvino.sh
```

### Windows (PowerShell)

```powershell
.\test-openvino.ps1
```

The script will:

1. Check that RamaLama, Python, and Podman are installed (installing RamaLama via pip if needed)
2. Pause and wait for you to press Enter before starting the comparison
3. Run all three tests sequentially and print a comparison table at the end
