# Rejected continuation and sibling-ranking labels

`search_decision_continuations.gd` adds sparse counterfactual outcome labels to the search-decision dataset without rolling out every leaf.

Run after `search_decisions.jsonl` has been generated:

```bash
bash tools/run_rejected_continuations.sh \
  --out=/path/to/self_play \
  --max-continuations=64
```

For the intended prioritization, pass the current neural checkpoint:

```bash
bash tools/run_rejected_continuations.sh \
  --out=/path/to/self_play \
  --neural-checkpoint=/path/to/value_model.pt \
  --max-continuations=64
```

The selector separately tracks the actually played self-play choice, the greedy handwritten choice, and the greedy neural choice. This matters when an exploration policy deliberately plays a candidate that neither greedy evaluator would have selected.

Rejected alternatives are ranked in this order:

1. neural and handwritten greedy rankings disagree and the rejected candidate participates in that disagreement;
2. the top two neural worst-case candidate scores are within `--neural-close-threshold` (default `100`, or `0.1` model-value units after scaling);
3. the forced first turn creates a large elimination, unit-count, health, or command-objective swing;
4. deterministic fallback ordering for the remaining rejected candidates.

Only one modeled opponent-response branch is continued for each selected rejected candidate. Neural-prioritized cases use that candidate's neural worst response; other cases use its handwritten worst response. Neural leaf scoring uses the decision's real turn index. Continuations use the canonical handwritten greedy gameplay policy and the original search budget for the remaining scenario horizon. Command-hex capture is adjudicated across the forced branch turn before the continuation begins.

A user-supplied shorter continuation cap is treated only as a compute budget; it never triggers the scenario's official turn-limit winner early. Any unadjudicated turn limit remains `labeled=false` rather than becoming a fake win/loss target.

Outputs:

- `rejected_continuations.jsonl`: sparse rejected-candidate labels and provenance;
- `rejected_continuations_manifest.json`: counts, prioritization reasons, label coverage, and whether neural prioritization was enabled.

## Build sibling-ranking pairs

After the rejected continuations exist, run:

```bash
godot --headless --path . res://tools/search_decision_ranking_pairs.tscn -- \
  --out=/path/to/self_play
```

For every terminal rejected continuation, the ranking-pair tool finds the actually played candidate from the same recorded decision and continues it under the **same modeled opponent response**. That creates a response-controlled sibling comparison rather than comparing a real continuation with a handwritten leaf score.

Preference rules are deliberately conservative:

- `win > draw > loss` with full pair weight;
- faster win > slower win with lower pair weight (`0.25`);
- loss-vs-loss receives no label, so training never rewards merely delaying defeat;
- unresolved branches remain unlabeled.

Additional outputs:

- `ranking_pairs.jsonl`: better/worse sibling leaf states, pair weight, outcome provenance, and source decision metadata;
- `ranking_pairs_manifest.json`: pair counts, label types, invalid/unresolved counts, and the supervision policy.

Train the two-objective model with:

```bash
python -m ml.value_model.train_ranked \
  --data /path/to/examples.jsonl \
  --ranking-data /path/to/ranking_pairs.jsonl \
  --output /path/to/ranked_value_model.pt \
  --ranking-weight 0.5
```

The model architecture is unchanged. Training minimizes the existing terminal-outcome MSE plus a weighted logistic pairwise loss that pushes `V(better) > V(worse)`. Held-out sibling-ranking accuracy is reported separately from winner-prediction accuracy.

## Experiment integration

The manual **Value Model Experiment** remains opt-in. When it completes successfully, the `Rejected Continuation Labels` workflow downloads that run's self-play shards and value-only checkpoint, merges the search-decision matrices, labels up to 16 high-priority rejected alternatives, builds same-response sibling pairs, and retrains a value + ranking checkpoint. The follow-up compares value-only versus ranked models on held-out winner prediction and counterfactual ranking/regret, then uploads the ranking data and ranked checkpoint as a retained artifact.
