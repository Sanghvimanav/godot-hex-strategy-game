# AGENTS.md

## Cursor Cloud specific instructions

### Project Overview

This is a **Godot 4.6 hex strategy game** (`hex-strategy-game/`). The legacy `godot/` directory is an older WebSocket-based prototype and is not actively developed. The root `package.json` is a leftover from the Node.js era and has no meaningful dependencies.

### Running the Game

- **GUI mode**: `cd hex-strategy-game && DISPLAY=:1 godot --path .`
- The game launches to a main menu with "Host server", "Join game", and "Single player" options.

### Running Tests

- From repo root: `cd hex-strategy-game && godot --headless --path . res://tests/test_runner.tscn`
- Or use: `hex-strategy-game/tests/run_tests.sh`
- All 7 test suites (44 tests) run headlessly. See `hex-strategy-game/tests/README.md` for details.
- **PR requirement:** before creating any PR, run the full test suite (all 7 suites) locally and confirm it passes.

### Critical Setup Gotcha

Godot 4 requires a **project import** before the first headless run. Without it, global `class_name` types (e.g. `Unit`, `TurnExecutionCore`, `ServerTurnExecutor`) are not registered, causing widespread `Parse Error` failures. Run this once after cloning or after the `.godot/` directory is deleted:

```bash
cd hex-strategy-game && godot --headless --import
```

The update script handles this automatically, but be aware if you ever clear the `.godot/` cache.

### No Lint Tool

This project uses GDScript (not TypeScript/Python), and there is no separate linter configured. The Godot compiler itself catches parse and type errors when running tests or importing.
