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

Exit code: `0` on success, `1` on failure.

### Headless LLM planning pipeline (no API)

Dump `LlmPlanningSnapshot` JSON and a small `summary.json` for a scenario (fast iteration on prompts / snapshot fields):

```bash
cd hex-strategy-game
./tools/run_headless_planning_pipeline.sh -- --scenario=drill_llm_vs_llm_scouts_zergling --out=user://pipeline_run_1
```

Pass `--` before custom flags so Godot puts them in `OS.get_cmdline_user_args()`. Optional: `--perspectives=terran` or `zerg` (default: all LLM perspectives). Output: `snapshot_turn_<n>_<group>.json`, `summary.json` under `--out`.

### Headless planning eval case (no API)

Run a single deterministic eval case from `tools/evals/planning_eval_cases.json`:

```bash
cd hex-strategy-game
./tools/run_planning_eval.sh --case=phase_fastmove_contact_zergling_vs_scout_t0 --out=user://planning_eval_result.json
```

Exit code is `0` on pass and non-zero on failure.

Live LLM mode (uses saved `LlmAiSettings`, including model/base URL/API key):

```bash
cd hex-strategy-game
./tools/run_planning_eval.sh --case=prediction_3scouts_vs_zergling_shoot_10_t0 --mode=live_llm --out=user://planning_eval_result_live.json
```

Default mode is `snapshot` (no API call). Use `--mode=live_llm` to score actual model-chosen actions.

Version metadata can be attached to each eval artifact:

```bash
./tools/run_planning_eval.sh --case=phase_fastmove_contact_zergling_vs_scout_t0 --mode=live_llm \
  --prompt_version=p_v001 --eval_set_version=eval_v001 --run_id=my_run_001 \
  --thinking_level=medium --planning_prompt_version=minimal
```

Optional overrides for live mode:
- `--model=<model_id>`: override model for this run only (does not persist settings)
- `--thinking_level=<none|minimal|low|medium|high|xhigh>`: override reasoning effort for this run only
- `--planning_prompt_version=<legacy|minimal>`: choose prompt family for this run only

### Eval suite runner (all cases + leaderboard)

Run all eval cases and store versioned artifacts under `tools/evals/runs/<run_id>/`:

```bash
cd hex-strategy-game
python3 tools/evals/run_eval_suite.py --mode live_llm --prompt-version p_v001 --eval-set-version eval_v001 --thinking-level medium
```

Or use a manifest file:

```bash
python3 tools/evals/run_eval_suite.py --mode live_llm --manifest tools/evals/experiment_manifest.example.json
```

Self-evolving loop (auto rerun + prompt improvement from failures):

```bash
cd hex-strategy-game
OPENAI_API_KEY=sk-... python3 tools/evals/run_self_evolve.py \
  --prompt-version p_current_settings \
  --eval-set-version eval_v001 \
  --thinking-level low \
  --planning-prompt-version minimal \
  --payload-profile baseline \
  --optimizer-model gpt-5.4 \
  --optimizer-thinking-level medium \
  --target-avg-final-score 0.9 \
  --max-iters 4
```

Artifacts are written under `tools/evals/self_evolve/<session_id>/` (iteration history, generated prompt files, optimizer outputs).
The self-evolve run also writes `snapshot_field_suggestions.json` with recommended new engine-computed snapshot fields to consider adding in code.
Prompt versioning for self-evolve is tracked in `tools/evals/self_evolve/prompt_versions.json` (`minimal` is seeded as v0). New runs start from the latest version by default, or from a specific version via `--start-version=<n>`.

Payload profile options for live evals/self-evolve:
- `baseline`: send the full default snapshot payload as-is.
- `timing_heavy`: keeps timing/phase and predicted-damage fields, but removes distance-only vectors (`distances_to_visible_enemies`, `distances_to_last_known_enemies`) from `ai_units[].legal_options`.
- `targeting_heavy`: keeps hit/damage and distance vectors, but removes phase-explanation prose fields (`pred_damage_resolution_note`, `predicted_enemy_damage_timing_vs_our_action`) from `ai_units[].legal_options`.

Fine-grained payload mutation (optional):
- `run_eval_suite.py` and `planning_eval.gd` accept `--payload-mutation-file=<path>`.
- The file is JSON with optional keys:
  - `remove_paths`: array of dot paths to erase (supports `[]` wildcard)
  - `set_values`: object mapping dot path -> JSON value
  - `copy_paths`: array of `{ "from": "path", "to": "path" }`
- `run_self_evolve.py` now asks the optimizer to emit `payload_mutation_spec` and writes it per iteration under `tools/evals/self_evolve/<session_id>/prompts/`.

Backfill estimated costs for existing historical runs:

```bash
cd hex-strategy-game
python3 tools/evals/backfill_estimated_costs.py
```

Outputs:
- `tools/evals/runs/<run_id>/run_meta.json`
- `tools/evals/runs/<run_id>/summary.json`
- `tools/evals/runs/<run_id>/cases/<case_id>.json`
- Appends one row to `tools/evals/leaderboard.jsonl`
- In live mode, effective LLM settings (model/thinking/prompt/API mode/two-call) are populated into the normal metadata fields (`run_meta` and leaderboard row) even without CLI overrides.
- `summary.json` and leaderboard rows include `estimated_cost_usd` (token-based estimate from model pricing table in the eval scripts).
- `summary.json` includes `failed_case_ids` and `failed_case_reasons` for quick triage.

Review helpers:
- Each live eval case includes `llm.prompt_debug` with the actual prompt text used and input preview snippet.

If `godot` is not found, add Godot to PATH or use the full path (e.g. on macOS: `/Applications/Godot.app/Contents/MacOS/Godot`).

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
- **EventBus** – `show_units_panel` and `llm_planning_status` signals exist and can be connected/emitted (avoids UNUSED_SIGNAL regression).
- **TurnExecutionCore** – `find_unit_by_id`, `get_units_at_cell`, `get_unit_def`, `get_damage_cells_for_config` (self, ray, target, area_adjacent), `execute_turn` (move + attack, recording structure, died_ids), `check_win_condition`; ability phases resolve health/energy from net deltas (damage+heal, spend+recharge) at phase end.
- **ServerTurnExecutor** – `validate_action` (valid move, invalid path, unit not found, dead unit, target out of range), `execute_turn` delegates to core.
- **Unified pipeline** – TurnExecutor.get_damage_cells matches TurnExecutionCore.get_damage_cells_for_config for self/ray/target; execute_turn produces valid recording structure.
- **Stun effects** – stun application is recorded during execution, persists through immediate end-turn tick to the next planning turn, and replays back to the same stunned next-turn state.
- **LLM planning** – `LlmPlanningResponseParser` parses model JSON (including fenced/partial text); no live API in CI.
- **LLM learnings ingest** – `LlmLearningsIngest` parses §7.7 Markdown sections for `prior_learnings` in the planning snapshot.
- **LLM recent turns** – `LlmPlanningRecentTurns` compacts last five replay entries into `recent_turns` in the planning snapshot.

The tests use the real autoloads and scripts: **EventBus**, **TurnExecutor**, **Actions**, **HexGrid**, **TurnExecutionCore**, **ServerTurnExecutor**.

## Adding tests

Add scripts under `tests/` that extend `RefCounted` and define `static func run_all(tests: Node) -> bool`; register in `run_tests.gd`.
