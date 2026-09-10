# AGENTS.md

## Cursor Cloud specific instructions

### Project Overview

This is a **Godot 4.6 hex strategy game** (`hex-strategy-game/`).

### AI Work: Start Here

- Read the root `AI_ROADMAP.md` before changing gameplay AI, search, self-play, value-model training, benchmarks, or arena evaluation. It is the strategic source of truth for what the AI is trying to achieve and how improvements are measured.
- The canonical gameplay AI entry point is `hex-strategy-game/src/battle/ai/gameplay_ai.gd`. Keep gameplay callers routed through it rather than creating parallel AI entry points.
- The handwritten evaluator is the current default/champion. Neural leaf evaluation is explicit opt-in, fail-closed when its runtime/checkpoint is unavailable, and should be compared against handwritten evaluation at the **same search budget** before promotion.
- Treat the curated counterfactual suite as a small tactical regression guardrail, not as the primary definition of good strategy. Arena strength, self-play outcomes, and held-out value-model performance are the primary evolving-game measurements.
- Keep training seeds separate from frozen arena evaluation seeds so training changes cannot leak into the evaluation set.
- **CI policy:** `Godot Tests` and `Value Model Tests` are normal PR checks. `AI Arena` is the expensive gameplay/value-model check and must stay path-filtered to changes that can affect arena behavior; do not broaden it for offline data export, CI-only, docs, or other non-gameplay changes. The full `Value Model Experiment` is intentionally manual/opt-in (`workflow_dispatch`) and should be run for report-card/promotion work rather than every small PR.
- For the latest implementation state, inspect the newest relevant `ai/*` PRs and their CI in addition to `AI_ROADMAP.md`. Do not infer current AI status from `hex-strategy-game/README.md`; that file is historical prototype context.

### Human Playtest Escalation

- Automated tests, counterfactual benchmarks, candidate-oracle diagnostics, and headless Arena runs remain the default evidence. Do not substitute casual manual play for reproducible automated checks.
- When automated metrics cannot explain a qualitative weakness, a suspected exploit/dominant strategy, a candidate-recall vs evaluator disagreement, or whether a benchmark improvement actually feels stronger, the agent may explicitly ask the user for a **small targeted Arena Playtest batch** (normally 3–10 games).
- Make the request specific: name the opponent AI variant, search profile, human faction, seed/family when relevant, and the behavior or hypothesis to probe. Prefer mirrored/repeated seeds when they create a useful controlled comparison.
- Ask the user to upload the resulting `arena_playtests` folder or zip. Analyze the saved pre-turn states, both simultaneous plans, search diagnostics, terminal outcomes, and human-policy examples instead of relying only on the user's summary of the games.
- Treat human actions as **adversarial evidence, not perfect ground truth**. A human move can expose a real search/evaluation weakness without being globally optimal, and bounded joint-plan search is not expected to reproduce the exact human action combination.
- Keep frozen human evaluation sets out of training and tuning. `human_playtest_v1` is the first frozen holdout: all 7 games / 40 turns are retained, while the default exploit benchmark scores the 35 post-discovery `adversarial` turns and marks the first 5 turns `exploratory` because the command-hex rule was still being learned.
- Run the frozen human-response benchmark with `cd hex-strategy-game && bash tools/run_human_playtest_benchmark.sh --quality=adversarial --out=user://human_playtest_benchmark`. Its headline response metric is **downside coverage**, not exact-plan recall: for the AI-selected plan, ask whether the broader source pool and final bounded response set contain any response that punishes the AI to roughly the same evaluated value as the human response actually did. Combine that with selected-plan regret under the real human response to distinguish consequential response-generation/selection gaps from cases where an exact human plan was absent but did not matter. Exact human-plan recall remains a secondary diagnostic only.
- For neural training, collect a **separate** human-playtest batch. Human policy examples can be modestly weighted imitation/policy data; actual human responses are especially valuable hard examples for opponent-response proposal/ranking; terminal-only value examples may feed the value model. Split/hold out by whole game/seed/family rather than random turns, and do not let a small human batch dominate self-play data.

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
