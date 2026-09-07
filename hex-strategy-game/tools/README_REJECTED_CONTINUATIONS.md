# Rejected continuation labels

`search_decision_continuations.gd` adds sparse counterfactual outcome labels to the 2x2 search-decision dataset without rolling out every leaf.

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

## Experiment integration

The manual **Value Model Experiment** remains opt-in. When it completes successfully, the `Rejected Continuation Labels` workflow automatically downloads that run's self-play shards and trained checkpoint, merges the 2x2 search-decision matrices, and labels up to 16 of the highest-priority rejected alternatives. The labels are uploaded as a separate retained artifact so ordinary pull requests do not pay the rollout or PyTorch cost.
