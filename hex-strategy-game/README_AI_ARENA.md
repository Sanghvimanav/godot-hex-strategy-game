# AI Arena

The AI Arena is the reproducible head-to-head test for comparing two search/evaluator configurations on frozen mirrored scenarios.

## Interactive human playtest

From the Godot main menu choose **Arena Playtest** to play one side of the official frozen `fast` Arena seeds yourself.

1. Pick one of the eight frozen fast seeds.
2. Choose Terran or Zerg.
3. Choose the handwritten AI search budget: `fast` (2x2), `balanced` (4x4), `wide` (6x6), or `broad` (8x8).
4. Play with the normal simultaneous-turn battle UI.

The opponent uses the same canonical `GameplayAI` + handwritten evaluator as the headless Arena. Its whole turn is chosen from the frozen pre-turn pure state before the human commits any actions, so it cannot inspect the human's simultaneous plan.

Interactive Arena also uses the headless Arena's compact board radius and command-hex rule: win by eliminating the opponent or by keeping the same living unit on the enemy command hex across one complete resolved turn. Command hexes are marked in the battle view.

Each completed match writes a local session under:

`user://arena_playtests/<game-id>/`

The session contains:

- `manifest.json` — outcome, provenance, Arena seed/family, search profile/evaluator, faction ownership, and example counts;
- `trace.json` — every pre/post-turn pure state, both submitted simultaneous plans, command-hex state, execution recording, and the AI search diagnostics;
- `human_policy_examples.jsonl` — one human demonstration per completed turn for future imitation/policy training; the opponent's simultaneous action is retained only as an analysis field, not as an input feature;
- `value_examples.jsonl` — terminal state-value examples using the existing `PureStateTrainingData` schema.

Turn-limit games still produce human-policy demonstrations and full traces, but intentionally produce no value labels because the eventual winner is unknown.

## Manual model promotion run

In **Actions → AI Arena → Run workflow**:

1. Choose the frozen scenario set. `fast` is the normal promotion set; `full` is the larger follow-up.
2. Choose search budgets directly as `2x2`, `4x4`, `6x6`, or `8x8`. For evaluator comparisons, use the same budget on both sides.
3. Keep the champion as `handwritten` and challenger as `neural` for neural promotion checks.
4. Identify the exact neural checkpoint using either:
   - `checkpoint_artifact_id` — preferred because it identifies one immutable Actions artifact exactly, or
   - `checkpoint_run_id` — the Arena searches that run's unexpired artifacts for `checkpoint_filename`.
5. Set `checkpoint_filename`. Ranked follow-ups produce `ranked_value_model.pt`; base value-model experiments normally produce `value_model.pt`.

The Arena copies the selected checkpoint to the runtime's canonical model path and validates that its encoder/model configuration matches the current code before any games run.

## Search budget mapping

| UI budget | Internal profile | Own plans | Opponent plans |
| --- | --- | ---: | ---: |
| `2x2` | `fast` | 2 | 2 |
| `4x4` | `balanced` | 4 | 4 |
| `6x6` | `wide` | 6 | 6 |
| `8x8` | `broad` | 8 | 8 |

## Result summary

Merged Arena artifacts include:

- neural/challenger and handwritten/champion wins;
- mirrored pair wins and ties;
- results by scenario family;
- neural results when playing Terran vs Zerg;
- winning-faction counts;
- unresolved games and termination reasons;
- mean turns;
- search time and simulations per decision;
- the exact checkpoint source used by the run.

This makes a result reproducible as **checkpoint source + frozen preset/seeds + search budgets + evaluator assignments + rules commit**.

## Optional automatic promotion Arena

A successful **Rejected Continuation Labels** run can automatically launch a frozen `fast`, equal-budget `4x4`, handwritten-vs-neural Arena using that run's `ranked_value_model.pt`.

This is opt-in. Set the repository Actions variable:

`AUTO_PROMOTION_ARENA=true`

If the variable is absent or not `true`, ranked training finishes normally and no Arena is launched. The promotion dispatch is intentionally a separate workflow so an Arena infrastructure/game failure does not turn successful model training red.

## Pull-request Arena

Pull requests that touch gameplay/search/evaluator code keep the existing cheap frozen `2x2` neural-vs-handwritten Arena. That PR check intentionally uses its historical frozen checkpoint preparation so PR results remain comparable across code changes.
