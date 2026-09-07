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

The selector ranks rejected alternatives in this order:

1. the neural evaluator prefers a rejected candidate over the handwritten-selected candidate;
2. neural worst-case candidate scores are within `--neural-close-threshold` (default `100`, or `0.1` model-value units after scaling);
3. the forced first turn creates a large elimination, unit-count, health, or command-objective swing;
4. deterministic fallback ordering for the remaining rejected candidates.

Only one modeled opponent-response branch is continued for each selected rejected candidate. Neural-prioritized cases use the neural worst response; other cases use the handwritten worst response. Continuations use the canonical handwritten greedy gameplay policy and the original search budget for the remaining scenario horizon. Command-hex capture is adjudicated across the forced branch turn before the continuation begins.

Outputs:

- `rejected_continuations.jsonl`: sparse rejected-candidate labels and provenance;
- `rejected_continuations_manifest.json`: counts, prioritization reasons, label coverage, and whether neural prioritization was enabled.

A continuation that reaches an unadjudicated turn limit remains `labeled=false`; it is never converted into a fake win/loss target.
