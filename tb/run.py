"""
VUnit run script for avalon_mm_width_adapter testbench.

Usage
-----
Run all tests with GHDL (default):
    python run.py

Run a specific test:
    python run.py lib.tb_avalon_mm_width_adapter.upsize.test_upsize_write_slot0

Run all tests in verbose mode with waveforms (GHDL + GtkWave):
    python run.py --wave --gui

Run with Questasim / ModelSim:
    python run.py --sim modelsim

Run only the upsizing group:
    python run.py *upsize*
"""

import tomllib
from pathlib import Path
from vunit import VUnit

# ---------------------------------------------------------------------------
# VUnit instance – picks up simulator from VUNIT_SIMULATOR env var or --sim
# ---------------------------------------------------------------------------
vu = VUnit.from_argv(compile_builtins=False)
vu.add_vhdl_builtins()

# Suppress GHDL warnings that originate inside VUnit's own built-in VHDL
# libraries (string_ops, path, …) and are not actionable:
#   -Wno-hide     : local parameter/variable names that shadow a built-in
#                   function of the same name inside vunit_lib sources.
#   -Wno-library  : duplicate package definition warning triggered when GHDL
#                   finds vunit_lib artifacts previously compiled by a
#                   different VUnit installation on the same machine.
vu.set_compile_option("ghdl.a_flags", ["-Wno-hide", "-Wno-library"])

# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------
ROOT = Path(__file__).parent

lib = vu.add_library("lib")

# DUT source
dut_src = lib.add_source_file(ROOT.parent / "avalon_mm_width_adapter.vhd")

# Testbench
tb_src = lib.add_source_file(ROOT / "tb_avalon_mm_width_adapter.vhd")

# Apply to all files in this library (must be called after files are added).
lib.set_compile_option("ghdl.a_flags", ["-frelaxed"])

# GHDL: allow non-protected shared variable in testbench memory model.
# -frelaxed must be set for BOTH the analysis step (a_flags / compile_option)
# and the elaboration step (elab_flags / sim_option), because GHDL's
# --elab-run re-reads the library and enforces the flag independently.
for src in (dut_src, tb_src):
    src.set_compile_option("ghdl.a_flags", ["-frelaxed"])

# ---------------------------------------------------------------------------
# Test plan – loaded from test_config.toml
# ---------------------------------------------------------------------------
_CFG_FILE = ROOT / "test_config.toml"
with open(_CFG_FILE, "rb") as _f:
    _CFG = tomllib.load(_f)

_GENERIC_KEYS = ("ADDR_WIDTH", "S_DATA_WIDTH", "M_DATA_WIDTH", "SYMBOL_WIDTH")
TEST_PLAN = {
    key: {
        "generics": {k: cfg[k] for k in _GENERIC_KEYS},
        "tests":    list(cfg["tests"]),
    }
    for key, cfg in _CFG["configs"].items()
}

# Canonical test lists for custom-mode inference (first matching config of each type).
_upsize_tests   = next(v["tests"] for v in _CFG["configs"].values() if v["M_DATA_WIDTH"] > v["S_DATA_WIDTH"])
_downsize_tests = next(v["tests"] for v in _CFG["configs"].values() if v["S_DATA_WIDTH"] > v["M_DATA_WIDTH"])
_passthru_tests = next(v["tests"] for v in _CFG["configs"].values() if v["S_DATA_WIDTH"] == v["M_DATA_WIDTH"])

# ---------------------------------------------------------------------------
# Register configurations with VUnit
# ---------------------------------------------------------------------------
tb = lib.test_bench("tb_avalon_mm_width_adapter")

# Pass -frelaxed to the elaboration step as well (ghdl --elab-run reads the
# flag independently of the analysis-time a_flags).
tb.set_sim_option("ghdl.elab_flags", ["-frelaxed"])

# VCD waveform output directory (set by the Flask UI when waveforms are requested).
import os as _os
_wave_dir = _os.environ.get("VUNIT_WAVE_DIR")
if _wave_dir:
    Path(_wave_dir).mkdir(parents=True, exist_ok=True)

for config_name, plan in TEST_PLAN.items():
    for test_name in plan["tests"]:
        _vcd_opts = {}
        if _wave_dir:
            _vcd = f"{_wave_dir}/{config_name}.{test_name}.vcd"
            _vcd_opts = {"ghdl.sim_flags": [f"--vcd={_vcd}"]}
        tb.test(test_name).add_config(
            name=config_name,
            generics=plan["generics"],
            sim_options=_vcd_opts or None,
        )

# ---------------------------------------------------------------------------
# Custom configuration from environment variables
# ---------------------------------------------------------------------------
# Set VUNIT_CUSTOM_S_WIDTH and VUNIT_CUSTOM_M_WIDTH (and optionally
# VUNIT_CUSTOM_ADDR_WIDTH / VUNIT_CUSTOM_SYM_WIDTH) to inject an extra
# test configuration at run-time without editing this file.
# The Flask UI uses this mechanism for the Custom mode.
_custom_s = _os.environ.get("VUNIT_CUSTOM_S_WIDTH")
_custom_m = _os.environ.get("VUNIT_CUSTOM_M_WIDTH")

if _custom_s and _custom_m:
    _s = int(_custom_s)
    _m = int(_custom_m)
    _addr = int(_os.environ.get("VUNIT_CUSTOM_ADDR_WIDTH", "32"))
    _sym  = int(_os.environ.get("VUNIT_CUSTOM_SYM_WIDTH",  "8"))

    _custom_generics = {
        "ADDR_WIDTH":   _addr,
        "S_DATA_WIDTH": _s,
        "M_DATA_WIDTH": _m,
        "SYMBOL_WIDTH": _sym,
    }
    _config_name = f"custom_{_s}_to_{_m}"

    if _m > _s:
        _test_names = _upsize_tests
    elif _s > _m:
        _test_names = _downsize_tests
    else:
        _test_names = _passthru_tests

    for _test_name in _test_names:
        _vcd_opts = {}
        if _wave_dir:
            _vcd = f"{_wave_dir}/{_config_name}.{_test_name}.vcd"
            _vcd_opts = {"ghdl.sim_flags": [f"--vcd={_vcd}"]}
        tb.test(_test_name).add_config(
            name=_config_name,
            generics=_custom_generics,
            sim_options=_vcd_opts or None,
        )

# ---------------------------------------------------------------------------
# Optional: per-test simulator settings
# ---------------------------------------------------------------------------
# Uncomment to enable VCD / GHW waveform generation for all tests:
#
# for test in tb.get_tests():
#     test.set_sim_option("ghdl.sim_flags", ["--wave=wave.ghw"])

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
vu.main()
