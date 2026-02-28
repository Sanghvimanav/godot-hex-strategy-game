# Tests

Scenario and behavior tests for the hex strategy game. Run on commit or as needed.

## Run tests

You need **Godot 4** installed and the `godot` binary on your PATH (or use the full path to the executable).

From the **hex-strategy-game** project directory:

```bash
godot --headless --path . res://tests/test_runner.tscn
```

Or from repo root: `cd hex-strategy-game && godot --headless --path . res://tests/test_runner.tscn`

Or use the script (from hex-strategy-game): `./tests/run_tests.sh`

Exit code: `0` on success, `1` on failure. If `godot` is not found, add Godot to PATH or run with the full path (e.g. on macOS: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path . res://tests/test_runner.tscn`).

## Run on PR / merge (CI)

CI test workflow is currently disabled. Run the test command manually before creating a PR:

```bash
cd hex-strategy-game
godot --headless --path . res://tests/test_runner.tscn
```

Or use the script: `hex-strategy-game/tests/run_tests.sh`

## What's covered

- **Actions** – `get_action_type()` and `get_action_config()` callable on script class (static; avoids parser error), `ACTION_ORDER`, `energy_consumption` / `recharge` config, reload/recharge as slow ability.
- **HexGrid** – `cell_equal`, `hex_distance`, `are_adjacent`, `get_hexes_at_distance`, `build_path_to`.
- **TurnExecutor** – `ABILITY_TYPES` and `MOVE_TYPES`; `attack_passive` has pattern `"self"`; `get_damage_cells()` uses attacker's current cell for self-pattern (so Zergling can move then attack and hit Marine); fast ability before move in `ACTION_ORDER`.
- **EventBus** – `show_units_panel` signal exists and can be connected/emitted (avoids UNUSED_SIGNAL regression).
- **TurnExecutionCore** – `find_unit_by_id`, `get_units_at_cell`, `get_unit_def`, `get_damage_cells_for_config` (self, ray, target, area_adjacent), `execute_turn` (move + attack, recording structure, died_ids), `check_win_condition`.
- **ServerTurnExecutor** – `validate_action` (valid move, invalid path, unit not found, dead unit, target out of range), `execute_turn` delegates to core.
- **Unified pipeline** – TurnExecutor.get_damage_cells matches TurnExecutionCore.get_damage_cells_for_config for self/ray/target; execute_turn produces valid recording structure.

The tests use the real autoloads and scripts: **EventBus**, **TurnExecutor**, **Actions**, **HexGrid**, **TurnExecutionCore**, **ServerTurnExecutor**.

## Adding tests

Add scripts under `tests/` that extend `RefCounted` and define `static func run_all(tests: Node) -> bool`; register in `run_tests.gd`.
