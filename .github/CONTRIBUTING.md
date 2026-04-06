# Contributing to avalon_mm_width_adapter

Thank you for taking the time to contribute! This document covers everything
you need to get started.

---

## Table of Contents

- [Code of conduct](#code-of-conduct)
- [Getting started](#getting-started)
- [How to report a bug](#how-to-report-a-bug)
- [How to request a feature](#how-to-request-a-feature)
- [Development workflow](#development-workflow)
- [Coding standards](#coding-standards)
- [Adding or changing tests](#adding-or-changing-tests)
- [Commit message style](#commit-message-style)
- [Pull request checklist](#pull-request-checklist)

---

## Code of conduct

Be respectful and constructive. We follow the
[Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).

---

## Getting started

```bash
git clone https://github.com/<your-org>/avalon_mm_width_adapter.git
cd avalon_mm_width_adapter

# Python environment
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# Verify the test suite passes
python avalon_mm_width_adapter/tb/run.py
```

You need **GHDL ≥ 4.0** on your `$PATH`. Install instructions:
https://ghdl.github.io/ghdl/getting.html

---

## How to report a bug

Use the **Bug report** issue template. Include:

- GHDL version (`ghdl --version`)
- Python version (`python --version`)
- Exact command and full terminal output
- Expected vs. actual behaviour

---

## How to request a feature

Use the **Feature request** issue template. Describe the use case, not just
the solution you have in mind. If you can point to a section of the Avalon-MM
specification that motivates the request, please include a reference.

---

## Development workflow

1. **Fork** the repository and create a branch from `main`:
   ```bash
   git checkout -b feat/my-feature
   # or
   git checkout -b fix/issue-123
   ```

2. **Make your changes** following the coding standards below.

3. **Run the full test suite** before opening a PR:
   ```bash
   python avalon_mm_width_adapter/tb/run.py --clean
   ```
   All tests must pass.

4. **Open a pull request** against `main` and fill in the PR template.

---

## Coding standards

### VHDL

- VHDL-2008 syntax (GHDL is invoked with `-frelaxed` for the testbench only;
  the DUT itself should be clean without relaxed flags).
- Use `ieee.std_logic_1164` and `ieee.numeric_std`; do **not** use
  `std_logic_arith` or `std_logic_unsigned`.
- Signal names: `snake_case`. Generic names: `UPPER_SNAKE_CASE`.
- Keep the DUT free of simulation-only constructs (`report`, `assert`,
  `wait` statements, `std.textio`).
- Every port and generic must have a comment on the line where it is declared.

### Python (`run.py`, `app.py`)

- Python ≥ 3.11, type-annotated (`from __future__ import annotations` at top).
- Follow [PEP 8](https://peps.python.org/pep-0008/).
- Keep Flask route handlers thin — move logic into helper functions.
- No new runtime dependencies without updating `requirements.txt`.

### TOML (`test_config.toml`)

- Every entry in `[configs.*]` must have a corresponding entry in
  `[modes.*]` and at least one entry in `[test_descriptions]`.
- Keep descriptions factual and concise (one sentence, ≤ 120 characters).

---

## Adding or changing tests

The testbench (`tb_avalon_mm_width_adapter.vhd`) contains all VHDL test
procedures. To add a scenario:

1. Add a procedure in the testbench VHDL and call it from the appropriate
   test runner `run` block.
2. Add the new test function name to the relevant `tests = [...]` list in
   `test_config.toml`.
3. Add a description to `[test_descriptions]`.
4. Verify the test appears and passes:
   ```bash
   python avalon_mm_width_adapter/tb/run.py "*your_new_test*"
   ```

Do **not** add test function names to the TOML that do not exist in the VHDL
testbench — VUnit will error with a "no such test" failure.

---

## Commit message style

```
<type>(<scope>): <short summary>

<optional body – wrap at 72 chars>

<optional footer: Closes #123>
```

| Type | When to use |
|---|---|
| `feat` | New feature or test |
| `fix` | Bug fix |
| `test` | Test-only change |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `docs` | Documentation only |
| `chore` | Build scripts, CI, dependencies |

Examples:
```
feat(tb): add test_downsize_unaligned_be for partial byte-enable downsizing
fix(dut): correct waitrequest de-assertion timing for ratio-4 downsize
docs(readme): add Groq AI backend setup instructions
```

---

## Pull request checklist

- [ ] Branch is up-to-date with `main`
- [ ] `python avalon_mm_width_adapter/tb/run.py --clean` passes with zero failures
- [ ] New/changed VHDL is clean without `-frelaxed` (DUT only)
- [ ] `test_config.toml` updated if new test names were added
- [ ] `requirements.txt` updated if new Python packages were added
- [ ] PR description explains *why*, not just *what*
