# GitHub Copilot Instructions

This file provides repository-wide context for GitHub Copilot. Read it fully
before suggesting any code, configuration, or documentation.

---

## Project overview

This repository contains:

1. **`avalon_mm_width_adapter.vhd`** — a synthesisable VHDL-2008 component
   that adapts an Avalon-MM slave port to a master port with a different data
   width (upsizing, downsizing, or pass-through).
2. **`tb_avalon_mm_width_adapter.vhd`** — a VUnit testbench that exercises all
   three operating modes.
3. **`run.py`** — a VUnit run script that loads the test plan from `test_config.toml`.
4. **`app.py`** — a Flask web application that streams live GHDL output to the
   browser, shows a waveform viewer, provides an in-browser TOML config editor,
   and embeds an AI chat assistant backed by any OpenAI-compatible LLM.
5. **`test_config.toml`** — the single source of truth for test modes,
   configurations (generics), and test-case descriptions consumed by both
   `run.py` and `app.py`.

---

## Repository layout

```
avalon-mm-width-adapter/
├── avalon_mm_width_adapter.vhd          # DUT – synthesisable RTL
├── avalon_mm_width_adapter_hw.tcl       # Platform Designer component descriptor
├── tb/
│   ├── tb_avalon_mm_width_adapter.vhd   # VUnit testbench
│   ├── run.py                           # VUnit runner script
│   ├── app.py                           # Flask UI + AI backend
│   ├── test_config.toml                 # Test plan (modes, configs, descriptions)
│   └── templates/
│       ├── index.html                   # Main page (SSE output, waveforms, AI chat)
│       ├── config_editor.html           # In-browser TOML editor
│       └── help.html                    # Help page
├── requirements.txt
└── .github/
    ├── copilot-instructions.md          # This file
    ├── CONTRIBUTING.md
    ├── pull_request_template.md
    └── ISSUE_TEMPLATE/
        ├── bug_report.md
        └── feature_request.md
```

---

## DUT: `avalon_mm_width_adapter`

### Entity generics

| Generic | Type | Default | Constraint |
|---|---|---|---|
| `ADDR_WIDTH` | `positive` | `32` | — |
| `S_DATA_WIDTH` | `positive` | `32` | Multiple of `SYMBOL_WIDTH` |
| `M_DATA_WIDTH` | `positive` | `64` | Multiple of `SYMBOL_WIDTH` |
| `SYMBOL_WIDTH` | `positive` | `8` | — |

**Width ratio** (`max(S,M) / min(S,M)`) must be a power of two.

### Ports

```
clk, reset                 – clock and synchronous active-high reset

-- Slave port (upstream)
s_address, s_read, s_write, s_writedata, s_byteenable
s_readdata, s_readdatavalid, s_waitrequest

-- Master port (downstream)
m_address, m_read, m_write, m_writedata, m_byteenable
m_readdata, m_readdatavalid, m_waitrequest
```

### Modes

| Mode | Condition | Key behaviour |
|---|---|---|
| **Upsize** | `M > S` | Narrow slave tx → one wide master tx. Sub-word slot = address LSBs. Byte-enables positioned in the wide word. |
| **Downsize** | `S > M` | Wide slave tx → `RATIO` consecutive narrow master txs. `s_waitrequest` held until all beats complete. |
| **Pass-through** | `S = M` | All signals wired combinationally. Zero latency. |

---

## Testbench structure

The testbench is a standard VUnit testbench with `runner_cfg` generic. All
DUT generics are passed through as testbench generics so each VUnit
`add_config()` call selects the mode under test.

### Existing test function names

These are the **only** valid test names. Do not invent new ones; the VUnit
runner will error if a name in `test_config.toml` does not match a `run` block
in the VHDL.

**Upsize tests** (used for any config where `M_DATA_WIDTH > S_DATA_WIDTH`):
- `test_upsize_write_slot0` — write data lands in the correct lower byte lane
- `test_upsize_write_slot1` — write data lands in the correct upper byte lane
- `test_upsize_read_slot0` — lower lane extracted correctly on read
- `test_upsize_read_slot1` — upper lane extracted correctly on read
- `test_upsize_byteenable` — byte-enable mask is positioned correctly in the wide word
- `test_upsize_waitrequest` — adapter stalls correctly on master `waitrequest`
- `test_upsize_pipelined_reads` — back-to-back reads via slot-tracking FIFO
- `test_upsize_roundtrip_slot0` — write then read-back slot 0 end-to-end via slave port
- `test_upsize_roundtrip_slot1` — write then read-back slot 1 end-to-end; verifies slot 0 not disturbed

**Downsize tests** (used for any config where `S_DATA_WIDTH > M_DATA_WIDTH`):
- `test_downsize_write` — wide write split into multiple narrow writes
- `test_downsize_read` — narrow reads reassembled into one wide response
- `test_downsize_partial_be` — only enabled sub-words generate master beats
- `test_downsize_waitrequest` — adapter pauses mid-burst on master `waitrequest`

**Pass-through tests** (used when `S_DATA_WIDTH = M_DATA_WIDTH`):
- `test_passthrough_write` — all signals forwarded unchanged
- `test_passthrough_read` — read response wired directly back
- `test_passthrough_waitrequest` — waitrequest wired directly back

---

## `test_config.toml` schema

```toml
# One entry per UI mode button
[modes.<key>]
label       = "Human-readable label"
description = "Shown under the mode button"
filter      = "*vunit_glob*"   # omit for "run all"

# One entry per set of generics to test
[configs.<key>]
label        = "Group header in Test Cases panel"
ADDR_WIDTH   = 32
S_DATA_WIDTH = 32
M_DATA_WIDTH = 128
SYMBOL_WIDTH = 8
tests = ["test_upsize_write_slot0", "test_upsize_byteenable"]

# Description for every test name referenced in any [configs.*]
[test_descriptions]
test_upsize_write_slot0 = "One-sentence description (≤ 120 chars)."
```

**Rules enforced at runtime:**
- `S_DATA_WIDTH` and `M_DATA_WIDTH` must be multiples of `SYMBOL_WIDTH`.
- Width ratio must be a power of two.
- Every name in `tests = [...]` must match a test runner block in the VHDL testbench.
- Every `[configs.<key>]` must have a matching `[modes.<key>]`.

---

## `run.py` — VUnit runner

- Reads `test_config.toml` via `tomllib`.
- Calls `tb.test(name).add_config(name=config_key, generics={...})` for every
  test in every config.
- Custom widths at runtime via env vars:
  `VUNIT_CUSTOM_S_WIDTH`, `VUNIT_CUSTOM_M_WIDTH`, `VUNIT_CUSTOM_ADDR_WIDTH`,
  `VUNIT_CUSTOM_SYM_WIDTH`.
- Waveform VCD output path via `VUNIT_WAVE_DIR`.
- GHDL compile/elab flags: `-frelaxed` (required for testbench shared variable).

---

## `app.py` — Flask web backend

### Key routes

| Route | Method | Purpose |
|---|---|---|
| `/` | GET | Render main page |
| `/stream` | GET (SSE) | Stream VUnit subprocess output |
| `/chat` | POST (SSE) | Stream AI assistant response tokens |
| `/ai/status` | GET | Return current model/base_url |
| `/config` | GET | Config editor page |
| `/config/apply` | POST | Apply TOML to in-memory session (never writes disk) |
| `/config/reset` | POST | Reset session config to on-disk default |
| `/waves/list` | GET | List available VCD stems |
| `/waves/data` | GET | Parse and return VCD as JSON |

### Session config model

`_SESSION_CONTENT` holds the active TOML string. `_apply_config()` parses it
and updates `MODES`, `TC_GROUPS`, and `TC_DESCRIPTIONS` in-process. The file
on disk (`test_config.toml`) is **never modified** by the web UI.

### AI chat

**Backend**: any OpenAI-compatible endpoint, configured via:
- `AI_BASE_URL` (default: `http://localhost:11434/v1` — Ollama)
- `AI_API_KEY` (default: `"ollama"`)
- `AI_MODEL` (default: `llama3.2:3b`)

**Streaming**: `/chat` streams SSE tokens. Each SSE line is either:
- `data: <token>` — a text chunk (`\n` encoded as `\\n`)
- `data: __DONE__<json>` — stream finished; json contains `proposed_config`
- `data: __ERROR__<msg>` — fatal error

**System prompt rules** (enforced in `_build_system_prompt`):
- Do NOT generate VHDL. The testbench cannot be changed via the UI.
- Only reference test names from the known list above.
- If proposing a config change, emit a **complete** TOML (all three tables) in
  a single ` ```toml ``` ` fenced block.
- Map user requests to existing test names + generics; explain which tests
  cover the described scenario.

**Proposed config flow**:
1. `_extract_proposed_toml()` finds the first ` ```toml ``` ` block and
   validates it contains all three required tables and parses cleanly.
2. `__DONE__` payload carries `proposed_config` (string or null).
3. Frontend shows a confirmation bubble; user clicks Yes/No.
4. Yes → `fetch("/config/apply")` → in-memory session updated → page reloads.

### Logging

`logging.basicConfig` at `DEBUG` level. Key log points:
- Chat request received (message preview, history length, output size)
- Model call initiated (base URL, model, message count)
- Stream opened / done (token count, reply length)
- Proposed config detected

---

## `index.html` — Frontend

### Key JavaScript state

```js
let selectedMode   = "...";  // active mode key
let terminalOutput = "";      // accumulated text from current/last test run
let chatHistory    = [];      // [{role, content}, …] – last 16 turns sent to API
let _pendingToml   = null;    // proposed TOML waiting for user confirmation
```

### Chat streaming (SSE via `fetch` + `ReadableStream`)

`sendChat()` POSTs to `/chat`, reads the response body as a stream, appends
tokens live to the assistant bubble, then on `__DONE__` renders full markdown
and calls `_showProposedConfig()` if a config was proposed.

`_showProposedConfig(toml)` appends a **new assistant bubble** with Yes/No
buttons. `_confirmApply(bubId, apply)` either calls `/config/apply` and
reloads, or marks discarded — no external banner is used.

### Waveform viewer (`WaveformViewer` class)

Canvas-based VCD renderer. Signals ordered by `SIG_ORDER` array. Supports
zoom and pan via mouse drag / wheel. Loaded after a run with waveforms enabled.

---

## Coding conventions

### VHDL

- VHDL-2008. `ieee.std_logic_1164` + `ieee.numeric_std` only.
- DUT must be clean without `-frelaxed`. Testbench may use `-frelaxed`.
- Entity/architecture names: `snake_case`. Generics: `UPPER_SNAKE_CASE`.
- Signals: `s_` prefix for slave-side, `m_` prefix for master-side.
- Every port and generic must have an inline comment.

### Python

- Python ≥ 3.11 with `from __future__ import annotations`.
- Type-annotated throughout. Use `tomllib` (stdlib), not `toml` or `tomli`.
- Flask routes must be thin — business logic in helpers.
- No new runtime dependencies without updating `requirements.txt`.
- Use `log.info` / `log.debug` / `log.error` from the module-level `log` logger.

### TOML

- Config key names use `snake_case` (e.g. `upsize_32_to_128`).
- Every `[configs.*]` entry must have a `[modes.*]` counterpart.
- All test names in `tests = [...]` must exist in the VHDL testbench.
- Descriptions: factual, one sentence, ≤ 120 characters.

### HTML / JS

- Dark-theme CSS variables defined in `:root` (see `index.html`).
- No external JS libraries — vanilla JS only.
- New UI cards follow the `.card` / `.card-title` pattern.
- SSE endpoints use `text/event-stream` with `X-Accel-Buffering: no`.

---

## Common pitfalls to avoid

1. **Never write GHDL/VHDL test code in response to "implement a test case".**
   Map the request to existing test names and propose a TOML config.

2. **Never write a partial TOML snippet** when proposing a config change.
   Always emit all three tables: `[modes.*]`, `[configs.*]`, `[test_descriptions]`.

3. **Never use test names not in the known list.** VUnit will fail at startup
   with "no such test" if a name in the TOML doesn't match a run block in VHDL.

4. **Never write to disk from the web UI.** `_apply_config()` only updates
   in-memory state. `_CFG_FILE` on disk is read once at startup.

5. **Ratio must be a power of two.** Before proposing any new config, verify
   `max(S,M) / min(S,M)` is 1, 2, 4, 8, or 16.

6. **`llama3.2:1b` is too small** for structured output tasks. Use
   `llama3.2:3b` or larger.
