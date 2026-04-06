"""
Flask web UI for the avalon_mm_width_adapter VUnit test runner.

Usage
-----
    python tb/app.py
    # Open http://localhost:5000 in your browser.

The UI lets you pick an operational mode (upsizing / downsizing /
pass-through / all) and streams live VUnit output to the browser via
Server-Sent Events (SSE), then shows a colour-coded final summary.
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import tomllib
from pathlib import Path

from flask import Flask, Response, jsonify, render_template, request, stream_with_context

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
TB_DIR         = Path(__file__).parent          # …/tb/
WORKSPACE_ROOT = TB_DIR.parent                  # …/avalon-mm-width-adapter/
PYTHON         = WORKSPACE_ROOT / ".venv" / "bin" / "python"
RUN_PY         = TB_DIR / "run.py"
WAVE_DIR       = WORKSPACE_ROOT / "vunit_out" / "waves"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
_CFG_FILE = TB_DIR / "test_config.toml"

# _DEFAULT_CONTENT is the on-disk TOML text, read once at startup and never
# modified. It is the permanent fallback / reference config.
_DEFAULT_CONTENT: str = _CFG_FILE.read_text(encoding="utf-8")

# _SESSION_CONTENT holds the TOML text that is actually active for this server
# process. Starts equal to the default; replaced by /config/apply or
# /config/reset. The file on disk is NEVER written by the web UI.
_SESSION_CONTENT: str = _DEFAULT_CONTENT

# These three globals are replaced in-place by _apply_config().
MODES:           dict[str, dict] = {}
TC_GROUPS:       list[dict]      = []
TC_DESCRIPTIONS: dict[str, str]  = {}


def _apply_config(content: str) -> None:
    """Parse TOML text and update in-process globals. Never writes to disk."""
    global MODES, TC_GROUPS, TC_DESCRIPTIONS, _SESSION_CONTENT
    cfg = tomllib.loads(content)
    MODES = {
        key: {
            "label":       info["label"],
            "description": info["description"],
            "filter":      info.get("filter"),
        }
        for key, info in cfg["modes"].items()
    }
    TC_GROUPS = [
        {
            "config": key,
            "label":  info["label"],
            "modes":  ["all", key],
            "tests":  info["tests"],
        }
        for key, info in cfg["configs"].items()
    ]
    TC_DESCRIPTIONS = cfg["test_descriptions"]
    _SESSION_CONTENT = content


_apply_config(_DEFAULT_CONTENT)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("app")
# Quieten noisy third-party loggers
logging.getLogger("werkzeug").setLevel(logging.WARNING)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("openai").setLevel(logging.WARNING)

# ---------------------------------------------------------------------------
# Flask app
# ---------------------------------------------------------------------------
app = Flask(__name__)


# Regex that matches any ANSI/VT100 escape sequence.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b[()][A-B]")


def _strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


@app.route("/")
def index() -> str:
    return render_template(
        "index.html",
        modes=MODES,
        tc_groups=TC_GROUPS,
        tc_descriptions=TC_DESCRIPTIONS,
    )


@app.route("/stream")
def stream() -> Response:
    """
    SSE endpoint.  Query parameters:
        mode       – one of the keys in MODES (default: "all")
        clean      – "1" to wipe vunit_out before running (default: "0")
        s_width    – S_DATA_WIDTH for custom mode (bits, power-of-two multiple of sym_width)
        m_width    – M_DATA_WIDTH for custom mode
        addr_width – ADDR_WIDTH  for custom mode (default 32)
        sym_width  – SYMBOL_WIDTH for custom mode (default 8)

    Each event is a plain text line from the VUnit process.
    Special sentinel lines:
        __EXIT__<code>   – process finished; code is the exit code
    """
    mode_key  = request.args.get("mode", "all")
    clean     = request.args.get("clean", "0") == "1"
    waves     = request.args.get("waves", "0") == "1"
    tests_param = request.args.get("tests", "")   # comma-sep "config.test" pairs
    mode_info = MODES.get(mode_key, MODES["all"])

    is_custom = (mode_key == "custom")
    s_width    = request.args.get("s_width", "32")
    m_width    = request.args.get("m_width", "128")
    addr_width = request.args.get("addr_width", "32")
    sym_width  = request.args.get("sym_width", "8")

    # Build the VUnit filter glob for custom mode
    if is_custom:
        s, m = int(s_width), int(m_width)
        config_name = f"custom_{s}_to_{m}"
        filter_glob = f"*{config_name}*"
    else:
        filter_glob = mode_info["filter"]

    cmd: list[str] = [str(PYTHON), str(RUN_PY)]
    if tests_param:
        # Explicit per-test selection: build one VUnit glob per "config.test" pair
        for ct in tests_param.split(","):
            ct = ct.strip()
            if ct:
                cmd.append(f"*{ct}*")
    elif filter_glob:
        cmd.append(filter_glob)

    # Extra environment for custom mode
    extra_env: dict[str, str] = {}
    if is_custom:
        extra_env["VUNIT_CUSTOM_S_WIDTH"]    = s_width
        extra_env["VUNIT_CUSTOM_M_WIDTH"]    = m_width
        extra_env["VUNIT_CUSTOM_ADDR_WIDTH"] = addr_width
        extra_env["VUNIT_CUSTOM_SYM_WIDTH"]  = sym_width
    if waves:
        extra_env["VUNIT_WAVE_DIR"] = str(WAVE_DIR)

    def generate():
        # Clear previous wave files so stale VCDs don’t appear in the UI.
        if waves:
            import shutil as _shutil
            if WAVE_DIR.exists():
                _shutil.rmtree(WAVE_DIR)
            WAVE_DIR.mkdir(parents=True, exist_ok=True)
            yield "data: [UI] Waveform capture enabled\n\n"

        # Optionally delete previous artefacts so GHDL recompiles from scratch.
        if clean:
            import shutil
            vunit_out = WORKSPACE_ROOT / "vunit_out"
            if vunit_out.exists():
                shutil.rmtree(vunit_out)
            yield "data: [UI] Cleaned vunit_out\n\n"

        if is_custom:
            yield f"data: [UI] Custom config: S_DATA_WIDTH={s_width}  M_DATA_WIDTH={m_width}  ADDR_WIDTH={addr_width}  SYMBOL_WIDTH={sym_width}\n\n"

        import os as _os
        env = {**_os.environ, **extra_env}

        try:
            proc = subprocess.Popen(
                cmd,
                cwd=str(WORKSPACE_ROOT),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,          # line-buffered
                env=env,
            )
        except FileNotFoundError as exc:
            yield f"data: [ERROR] Could not start process: {exc}\n\n"
            yield "data: __EXIT__1\n\n"
            return

        assert proc.stdout is not None
        for raw_line in proc.stdout:
            line = _strip_ansi(raw_line.rstrip("\n"))
            # SSE data lines must not contain bare newlines; escape them.
            yield f"data: {line}\n\n"

        proc.wait()
        yield f"data: __EXIT__{proc.returncode}\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={
            "Cache-Control":    "no-cache",
            "X-Accel-Buffering": "no",   # disable nginx buffering if proxied
        },
    )


# ---------------------------------------------------------------------------
# VCD parser
# ---------------------------------------------------------------------------
def parse_vcd(path: Path) -> dict:
    """
    Tokenise a VCD file and return:
        {
          "timescale": str,
          "endtime":   int,
          "signals":   [{"name": str, "width": int, "data": [[t, v], ...]}, ...]
        }

    Scope filtering: skip VUnit-internal scopes (runner, vunit_lib, …).
    Keep signals at scope depth ≤ 2 (TB level and one DUT level).
    """
    SKIP_SCOPES = {"runner", "vunit_lib", "vunit_conf", "vunit_error",
                   "vunit_stop", "vunit_check", "pkg"}

    text       = path.read_text(errors="replace")
    tokens     = iter(text.split())

    timescale  = "1 ns"
    id_to_sig: dict[str, dict]   = {}   # vcd_id -> {name, width, data}
    scope_stack: list[str]       = []
    active_scopes: set[str]      = set()   # scope names currently "open"
    cur_time   = 0
    endtime    = 0

    def in_good_scope() -> bool:
        if len(scope_stack) > 2:
            return False
        return not (set(scope_stack) & SKIP_SCOPES)

    tok = next(tokens, None)
    while tok is not None:
        if tok == "$timescale":
            parts = []
            for t in tokens:
                if t == "$end":
                    break
                parts.append(t)
            timescale = " ".join(parts)

        elif tok == "$scope":
            kind  = next(tokens, "")   # module / begin / …
            name  = next(tokens, "")
            _end  = next(tokens, "")   # $end
            scope_stack.append(name)

        elif tok == "$upscope":
            _end = next(tokens, "")    # $end
            if scope_stack:
                scope_stack.pop()

        elif tok == "$var":
            # $var <type> <width> <id> <name> [$end | [<range>] $end]
            _vtype = next(tokens, "")
            width  = int(next(tokens, "1"))
            vid    = next(tokens, "")
            vname  = next(tokens, "").split("[")[0]   # strip [n:0] suffix
            # consume optional range + $end
            for t in tokens:
                if t == "$end":
                    break
            # Only keep TB-level signals (depth==1); skip DUT internals & duplicates
            if len(scope_stack) == 1 and not (set(scope_stack) & SKIP_SCOPES):
                if vname not in {s["name"].split(".")[-1] for s in id_to_sig.values()}:
                    full_name = ".".join(scope_stack + [vname])
                    id_to_sig[vid] = {"name": full_name, "width": width, "data": []}

        elif tok.startswith("#"):
            try:
                cur_time = int(tok[1:])
                endtime  = max(endtime, cur_time)
            except ValueError:
                pass

        elif tok and tok[0] in "01xzXZuU" and len(tok) >= 2:
            # scalar value change: e.g. "1#"  value=tok[0]  id=tok[1:]
            val = tok[0].lower()
            if val == "u": val = "x"   # VHDL uninitialized → treat as unknown
            vid = tok[1:]
            if vid in id_to_sig:
                d = id_to_sig[vid]["data"]
                if not d or d[-1][0] != cur_time:
                    d.append([cur_time, val])
                else:
                    d[-1][1] = val

        elif tok and tok[0] in "bB":
            raw = tok[1:].lower().replace("u", "x")   # normalise VHDL 'u' → 'x'
            vid = next(tokens, "")
            if vid in id_to_sig:
                d = id_to_sig[vid]["data"]
                if not d or d[-1][0] != cur_time:
                    d.append([cur_time, raw])
                else:
                    d[-1][1] = raw

        tok = next(tokens, None)

    # Strip scope prefix down to just the leaf name for display
    signals = []
    for sig in id_to_sig.values():
        leaf = sig["name"].split(".")[-1]
        signals.append({"name": leaf, "width": sig["width"], "data": sig["data"]})

    return {"timescale": timescale, "endtime": endtime, "signals": signals}


# ---------------------------------------------------------------------------
# Wave data API
# ---------------------------------------------------------------------------
@app.route("/waves/list")
def waves_list() -> Response:
    """Return JSON list of available VCD stem names."""
    from flask import jsonify
    if not WAVE_DIR.exists():
        return jsonify([])
    files = sorted(p.stem for p in WAVE_DIR.glob("*.vcd") if p.stat().st_size > 0)
    return jsonify(files)


@app.route("/waves/data")
def waves_data() -> Response:
    """Parse and return a VCD file as JSON signal data."""
    from flask import jsonify, abort
    name = request.args.get("name", "")
    if not name or "/" in name or ".." in name:
        abort(400)
    path = WAVE_DIR / f"{name}.vcd"
    if not path.exists():
        abort(404)
    return jsonify(parse_vcd(path))


# ---------------------------------------------------------------------------
# Config editor
# ---------------------------------------------------------------------------
@app.route("/config", methods=["GET"])
def config_editor() -> str:
    return render_template(
        "config_editor.html",
        session_content=_SESSION_CONTENT,
        default_content=_DEFAULT_CONTENT,
        is_default=(_SESSION_CONTENT == _DEFAULT_CONTENT),
    )


@app.route("/config/apply", methods=["POST"])
def config_apply():
    """Validate TOML and apply it to the current session. Never writes to disk."""
    payload = request.get_json(force=True, silent=True) or {}
    content = payload.get("content", "")
    try:
        _apply_config(content)
    except Exception as exc:
        return jsonify(ok=False, error=str(exc)), 400
    return jsonify(ok=True)


@app.route("/config/reset", methods=["POST"])
def config_reset():
    """Reset the session config back to the on-disk default."""
    _apply_config(_DEFAULT_CONTENT)
    return jsonify(ok=True, content=_DEFAULT_CONTENT)


# ---------------------------------------------------------------------------
# AI Chat
# ---------------------------------------------------------------------------
# Configure the LLM backend via environment variables:
#   AI_BASE_URL  – OpenAI-compatible base URL
#                  Ollama (local, default): http://localhost:11434/v1
#                  GitHub Models (free):   https://models.inference.ai.azure.com
#                  Groq (free tier):       https://api.groq.com/openai/v1
#   AI_API_KEY   – API key ("ollama" for Ollama; GitHub PAT; Groq API key)
#   AI_MODEL     – model name, e.g. "llama3.2", "phi4", "gpt-4o-mini"

AI_BASE_URL: str = os.environ.get("AI_BASE_URL", "http://localhost:11434/v1")
AI_API_KEY:  str = os.environ.get("AI_API_KEY",  "ollama")
AI_MODEL:    str = os.environ.get("AI_MODEL",    "llama3.2:3b")

_TOML_BLOCK_RE = re.compile(r"```toml\s*([\s\S]*?)```", re.IGNORECASE)


def _get_openai_client():
    """Return an openai.OpenAI client pointed at the configured backend."""
    try:
        from openai import OpenAI  # type: ignore[import]
    except ImportError as exc:
        raise ImportError(
            "The 'openai' package is required for AI chat. "
            "Install it with:  pip install openai"
        ) from exc
    return OpenAI(base_url=AI_BASE_URL, api_key=AI_API_KEY, timeout=60.0)


def _build_system_prompt(test_output: str) -> str:
    """Build the system prompt injecting current session config and test output."""
    config_section = _SESSION_CONTENT

    # Collect all known test function names from the session config.
    all_test_names: list[str] = []
    for g in TC_GROUPS:
        all_test_names.extend(g["tests"])
    unique_tests = sorted(set(all_test_names))

    output_section = (
        f"""\n\n## Most-recent test run output (last 6000 chars):
```
{test_output[-6000:]}
```"""
        if test_output.strip()
        else "\n\n## Most-recent test run output: (none yet)"
    )

    return f"""You are an AI assistant embedded in a VUnit/GHDL test-runner web UI for the \
avalon_mm_width_adapter VHDL component.

## Your responsibilities

1. **Explain test results** – analyse failures, warnings, and pass/fail patterns from the
   test output; give concise, engineer-level explanations.
2. **Propose new test configurations** – when the user asks to add, change, or simulate
   new test scenarios, respond by updating the TOML session config (see format below).

## Critical constraints – read carefully

- **DO NOT write or generate VHDL code.** The VHDL testbench already exists and cannot
  be changed through this UI.  When a user asks you to "implement a test case" or
  "simulate behaviour", your job is to select the correct generics (S_DATA_WIDTH,
  M_DATA_WIDTH, ADDR_WIDTH, SYMBOL_WIDTH) and pick existing test function names from the
  list below that exercise the described behaviour.  Explain which existing tests cover
  the requested scenario and why.
- Only use test function names from the **Known test function names** list.  Never invent
  new test names that are not in that list.
- S_DATA_WIDTH and M_DATA_WIDTH must be multiples of SYMBOL_WIDTH (default 8).
- Width ratio (larger÷smaller) must be a power of two.
- Always emit the **complete** TOML (all three tables) — never a partial snippet.

## TOML configuration format

Three top-level tables:
  [modes.<key>]        – UI mode buttons  (label, description, optional filter glob)
  [configs.<key>]      – ADDR_WIDTH, S_DATA_WIDTH, M_DATA_WIDTH, SYMBOL_WIDTH, tests=[...]
  [test_descriptions]  – key = test function name, value = human-readable description

## Known test function names (the ONLY valid values for tests=[...])
{', '.join(f'`{t}`' for t in unique_tests)}

## Current session configuration (TOML)
```toml
{config_section}
```{output_section}

## How to propose a config change
Wrap the complete replacement TOML in a single fenced block tagged `toml`.
The UI detects it, shows a confirmation bubble, and the user can apply it in one click.

## Answering style
- When the user describes a behaviour to test, map it to existing test names + generics.
- Be concise; use bullet points.
- If none of the existing tests match, say so clearly and explain what the closest tests do."""


def _extract_proposed_toml(reply: str) -> str | None:
    """Return the first ```toml block in the reply, or None."""
    m = _TOML_BLOCK_RE.search(reply)
    if not m:
        return None
    candidate = m.group(1).strip()
    # Quick sanity check: must have all three required tables
    if not ("[modes." in candidate and "[configs." in candidate and "[test_descriptions]" in candidate):
        return None
    # Validate it parses as TOML
    try:
        tomllib.loads(candidate)
        return candidate
    except Exception:
        return None


@app.route("/chat", methods=["POST"])
def chat() -> Response:
    """
    Streaming AI chat endpoint (Server-Sent Events).
    Request JSON:  {message, history, output}
    SSE events:
      data: <token>          – a streamed text chunk ('\\n' encodes a newline)
      data: __DONE__<json>   – stream finished;  json = {proposed_config: str|null}
      data: __ERROR__<msg>   – fatal error before/during streaming
    """
    payload = request.get_json(force=True, silent=True) or {}
    message: str     = (payload.get("message") or "").strip()
    history: list    = payload.get("history") or []
    test_output: str = payload.get("output") or ""

    if not message:
        return jsonify(ok=False, error="Empty message"), 400  # type: ignore[return-value]

    log.info("Chat request  | message=%r  history_turns=%d  output_chars=%d",
             message[:120], len(history), len(test_output))

    try:
        client = _get_openai_client()
    except ImportError as exc:
        log.error("openai import failed: %s", exc)
        return jsonify(ok=False, error=str(exc)), 500  # type: ignore[return-value]

    system_prompt = _build_system_prompt(test_output)

    messages: list[dict] = [{"role": "system", "content": system_prompt}]
    for turn in history[-16:]:
        role    = turn.get("role", "")    if isinstance(turn, dict) else ""
        content = turn.get("content", "") if isinstance(turn, dict) else ""
        if role in ("user", "assistant") and content:
            messages.append({"role": role, "content": content})
    messages.append({"role": "user", "content": message})

    log.debug("Calling %s  model=%s  messages=%d", AI_BASE_URL, AI_MODEL, len(messages))

    def generate():
        full_reply = ""
        token_count = 0
        try:
            stream = client.chat.completions.create(
                model=AI_MODEL,
                messages=messages,  # type: ignore[arg-type]
                max_tokens=2048,
                temperature=0.4,
                stream=True,
            )
            log.debug("Stream opened – receiving tokens…")
            for chunk in stream:
                delta: str = (chunk.choices[0].delta.content or "") if chunk.choices else ""
                if delta:
                    full_reply  += delta
                    token_count += 1
                    # Encode newlines so the SSE line stays on one physical line
                    safe = delta.replace("\\", "\\\\").replace("\n", "\\n")
                    yield f"data: {safe}\n\n"
        except Exception as exc:
            log.error("Streaming error: %s", exc, exc_info=True)
            yield f"data: __ERROR__{exc}\n\n"
            return

        log.info("Stream done   | tokens=%d  reply_chars=%d", token_count, len(full_reply))

        proposed_config = _extract_proposed_toml(full_reply)
        if proposed_config:
            log.info("Proposed config detected (%d chars)", len(proposed_config))
        done_payload = json.dumps({"proposed_config": proposed_config})
        yield f"data: __DONE__{done_payload}\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={
            "Cache-Control":     "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


# ---------------------------------------------------------------------------
# AI status
# ---------------------------------------------------------------------------
@app.route("/ai/status")
def ai_status() -> Response:
    """Return current AI backend config (safe to expose – no secret values)."""
    return jsonify(
        base_url=AI_BASE_URL,
        model=AI_MODEL,
        key_set=(AI_API_KEY not in ("", "ollama")),
    )


# ---------------------------------------------------------------------------
# Help page
# ---------------------------------------------------------------------------
@app.route("/help")
def help_page() -> str:
    return render_template("help.html")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    app.jinja_env.auto_reload = True
    app.config["TEMPLATES_AUTO_RELOAD"] = True
    log.info("Starting avalon_mm_width_adapter test runner")
    log.info("AI backend : %s", AI_BASE_URL)
    log.info("AI model   : %s", AI_MODEL)
    log.info("Open http://localhost:5000 in your browser")
    print("Open http://localhost:5000 in your browser")
    app.run(debug=False, threaded=True, port=5000)
