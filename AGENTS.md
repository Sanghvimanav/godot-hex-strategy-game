# AGENTS.md

## Cursor Cloud specific instructions

### Project Overview

This is a **Godot 4.6 hex strategy game** (`hex-strategy-game/`).

### Running the Game

- **GUI mode**: `cd hex-strategy-game && DISPLAY=:1 godot --path .`
- The game launches to a main menu with "Host server", "Join game", and "Single player" options.

### Running Tests

- From repo root: `cd hex-strategy-game && godot --headless --path . res://tests/test_runner.tscn`
- Or use: `hex-strategy-game/tests/run_tests.sh`
- All test suites run headlessly. See `hex-strategy-game/tests/README.md` for details.
- **Headless LLM planning pipeline** (snapshots + metrics, no API): `cd hex-strategy-game && ./tools/run_headless_planning_pipeline.sh -- --scenario=drill_llm_vs_llm_scouts_zergling --out=user://my_run`. User args must follow `--`; Godot exposes them via `OS.get_cmdline_user_args()`. Writes `snapshot_turn_*_<group>.json` and `summary.json` under `--out`.
- **PR requirement:** before creating any PR, run the full test suite locally and confirm it passes.

### New Units / Abilities: Debug Scenario Requirement

- When adding a new unit or a new gameplay ability, also add a dedicated scenario in `src/global/scenarios.gd` for fast manual verification.
- The scenario should be named clearly (for example, `*_debug`) and include only the minimum units needed to validate the feature.
- Prefer deterministic setup for GUI checks by placing units adjacent and using explicit unit overrides (for example starting `health` / `energy`) so the feature can be validated in one turn.
- Add or update automated tests that assert the debug scenario exists and includes the expected unit setup.

### Critical Setup Gotcha

Godot 4 requires a **project import** before the first headless run. Without it, global `class_name` types (e.g. `Unit`, `TurnExecutionCore`, `ServerTurnExecutor`) are not registered, causing widespread `Parse Error` failures. Run this once after cloning or after the `.godot/` directory is deleted:

```bash
cd hex-strategy-game && godot --headless --import
```

The update script handles this automatically, but be aware if you ever clear the `.godot/` cache.

### No Lint Tool

This project uses GDScript (not TypeScript/Python), and there is no separate linter configured. The Godot compiler itself catches parse and type errors when running tests or importing.
