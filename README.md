# Avalon-MM Configurable Width Adapter

A synthesisable VHDL component that bridges two Avalon-MM ports operating at
different data widths, together with a VUnit/GHDL test suite and a Flask-based
web UI with live streaming output, waveform viewer, and an AI assistant.

---

## Table of Contents

- [Component overview](#component-overview)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Installing non-Python dependencies](#installing-non-python-dependencies)
- [Quick start](#quick-start)
- [Running tests from the command line](#running-tests-from-the-command-line)
- [Web UI](#web-ui)
- [AI Assistant](#ai-assistant)
- [Test configuration (TOML)](#test-configuration-toml)
- [Platform Designer (Qsys) integration](#platform-designer-qsys-integration)
- [Contributing](#contributing)
- [License](#license)

---

## Component overview

`avalon_mm_width_adapter` adapts a narrow Avalon-MM slave port to a wider
master port (or vice-versa). The width ratio must be a power of two (1×, 2×,
4×, 8×, …).

| Mode | Condition | Behaviour |
|---|---|---|
| **Upsize** | `M_DATA_WIDTH > S_DATA_WIDTH` | One narrow slave transaction → one wide master transaction; sub-word slot selected by address LSBs |
| **Downsize** | `S_DATA_WIDTH > M_DATA_WIDTH` | One wide slave transaction → RATIO consecutive narrow master transactions; slave `waitrequest` held until all beats complete |
| **Pass-through** | `S_DATA_WIDTH = M_DATA_WIDTH` | All signals wired combinationally |

### Generics

| Generic | Default | Description |
|---|---|---|
| `ADDR_WIDTH` | `32` | Address bus width (bits) |
| `S_DATA_WIDTH` | `32` | Slave-side data bus width (bits) |
| `M_DATA_WIDTH` | `64` | Master-side data bus width (bits) |
| `SYMBOL_WIDTH` | `8` | Bits per addressable symbol |

### Constraints

- `S_DATA_WIDTH` and `M_DATA_WIDTH` must be multiples of `SYMBOL_WIDTH`.
- The larger of the two widths must be an exact power-of-two multiple of the
  smaller one.

---

## Repository layout

```
avalOn-mm-width-adapter/
├── avalon_mm_width_adapter.vhd       # Synthesisable RTL
├── avalon_mm_width_adapter_hw.tcl    # Platform Designer component descriptor
├── tb/
│   ├── tb_avalon_mm_width_adapter.vhd  # VUnit testbench
│   ├── run.py                          # VUnit run script
│   ├── app.py                          # Flask web UI + AI chat backend
│   ├── test_config.toml                # Test plan (modes, configs, descriptions)
│   └── templates/
│       ├── index.html                  # Main UI page
│       ├── config_editor.html          # In-browser TOML editor
│       └── help.html                   # Help page
└── requirements.txt                    # Python dependencies
```

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Python | ≥ 3.11 | `tomllib` is part of stdlib from 3.11 |
| GHDL | ≥ 4.0 | Must be on `$PATH` |
| pip packages | see [requirements.txt](requirements.txt) | install into a venv |
| Ollama *(optional)* | ≥ 0.19 | For the local AI assistant |

Install pip dependencies:

```bash
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

---

## Installing non-Python dependencies

### GHDL

GHDL is the open-source VHDL simulator used to compile and run the testbench.
It must be present on `$PATH` before running tests or starting the web UI.

**Ubuntu / Debian**
```bash
sudo apt update
sudo apt install ghdl
# Verify:
ghdl --version
```

**Fedora / RHEL**
```bash
sudo dnf install ghdl
```

**macOS (Homebrew)**
```bash
brew install ghdl
```

**Windows**
Download the latest pre-built release from the
[GHDL GitHub releases page](https://github.com/ghdl/ghdl/releases), extract
the archive, and add the `bin/` directory to your `PATH`.

> **Note:** GHDL ≥ 4.0 with the LLVM or GCC backend is recommended for best
> performance. The mcode backend (Windows default) also works for this project.

---

### Ollama (AI assistant — optional)

Ollama runs large-language models locally. It is only required if you want to
use the in-browser AI chat assistant.

**Linux**
```bash
curl -fsSL https://ollama.com/install.sh | sh
# The installer starts the Ollama service automatically.
# Verify:
ollama --version
```

**macOS**
Download the desktop app from <https://ollama.com/download/mac> and run it, or
use Homebrew:
```bash
brew install ollama
ollama serve   # start the background server
```

**Windows**
Download the installer from <https://ollama.com/download/windows> and run it.
The service starts automatically at login.

**Pull the default model**

Once Ollama is installed and running, pull the model used by the AI assistant:
```bash
ollama pull llama3.2:3b
```

The model file is ~2 GB. You can substitute any model supported by Ollama by
setting the `AI_MODEL` environment variable before starting the Flask app:
```bash
AI_MODEL=mistral:7b python tb/app.py
```

> **Tip:** Keep Ollama running in the background (`ollama serve`) while the
> Flask app is active. The AI chat will error if it cannot reach
> `http://localhost:11434`.

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/<your-org>/avalon-mm-width-adapter.git
cd avalon-mm-width-adapter

# 2. Create venv & install deps
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 3. Run all tests from the CLI
python tb/run.py

# 4.  — or — launch the web UI
python tb/app.py
# Open http://localhost:5000
```

---

## Running tests from the command line

```bash
# All tests
python tb/run.py

# One configuration
python tb/run.py "*upsize_32_to_128*"

# One specific test
python tb/run.py \
  "lib.tb_avalon_mm_width_adapter.upsize_32_to_64.test_upsize_write_slot0"

# Clean rebuild
python tb/run.py --clean

# Custom widths via environment variables
VUNIT_CUSTOM_S_WIDTH=32 VUNIT_CUSTOM_M_WIDTH=256 \
  python tb/run.py "*custom_32_to_256*"
```

---

## Web UI

```bash
python tb/app.py
# Open http://localhost:5000
```

Features:

- **Mode selector** — pre-built configurations plus a Custom Widths panel
- **Test Cases panel** — per-test checkbox selection with inline descriptions
- **Live output** — streamed from the GHDL process via Server-Sent Events
- **Result banner** — pass/fail summary with counts
- **Waveform viewer** — built-in VCD renderer (no external tool needed); enable
  with the *Show Waveforms* checkbox before running
- **Config editor** — edit the TOML test plan within the browser; changes apply
  to the running session only (disk file is never modified)
- **AI Assistant** — see below

---

## AI Assistant

The AI panel is embedded at the bottom of the main page. It can:

1. **Explain test results** — paste or run tests first; the AI reads the
   streamed output automatically.
2. **Propose configuration changes** — ask it to add a new width configuration
   or focus tests on a particular scenario.  When it produces a valid TOML
   proposal it asks *"Would you like me to apply it?"*; answering Yes applies
   the change to the current session immediately.

### Configuring the LLM backend

The backend is selected with three environment variables:

| Variable | Default | Description |
|---|---|---|
| `AI_BASE_URL` | `http://localhost:11434/v1` | OpenAI-compatible endpoint |
| `AI_API_KEY` | `ollama` | API key (`"ollama"` for Ollama) |
| `AI_MODEL` | `llama3.2:3b` | Model name |

#### Ollama (local, free — default)

```bash
# Install: https://ollama.com
ollama pull llama3.2:3b   # ~2 GB, one-time download
ollama serve               # keep running in a separate terminal
python tb/app.py
```

#### GitHub Models (free tier, requires GitHub account)

```bash
# Generate a PAT at https://github.com/settings/tokens (no special scope needed)
AI_BASE_URL=https://models.inference.ai.azure.com \
AI_API_KEY=<your-PAT> \
AI_MODEL=gpt-4o-mini \
python tb/app.py
```

#### Groq (free tier, fastest inference)

```bash
# API key from https://console.groq.com
AI_BASE_URL=https://api.groq.com/openai/v1 \
AI_API_KEY=<groq-key> \
AI_MODEL=llama-3.3-70b-versatile \
python tb/app.py
```

---

## Test configuration (TOML)

`tb/test_config.toml` is the single source of truth
consumed by both `run.py` (test plan) and `app.py` (UI modes and descriptions).

```toml
[modes.<key>]
label       = "Human-readable label"
description = "Shown under the mode button"
filter      = "*glob_for_vunit_cli*"   # omit for "run all"

[configs.<key>]
label        = "Group header in Test Cases panel"
ADDR_WIDTH   = 32
S_DATA_WIDTH = 32
M_DATA_WIDTH = 128
SYMBOL_WIDTH = 8
tests = ["test_upsize_write_slot0", "test_upsize_byteenable"]

[test_descriptions]
test_upsize_write_slot0 = "One-line description shown in the UI."
```

To add a new built-in configuration:

1. Add a `[configs.<key>]` section with generics + test list.
2. Add a matching `[modes.<key>]` section.
3. Add descriptions for any new test names in `[test_descriptions]`.

The AI Assistant can also generate and apply config changes interactively.

---

## Platform Designer (Qsys) integration

Copy the `avalon_mm_width_adapter.vhd` and `avalon_mm_width_adapter_hw.tcl`
files into your Quartus project directory and add it to the IP search path:

```tcl
# In your Qsys script
set_global_assignment -name IP_SEARCH_PATHS "<path>/avalon-mm-width-adapter"
```

Or use the GUI: **Tools → Platform Designer → IP Catalog → Add search path**.

The component appears under **Bridges and Adapters** as
*Avalon-MM Configurable Width Adapter*.

---

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md).

---

## License

This project is released under the [MIT License](LICENSE).
