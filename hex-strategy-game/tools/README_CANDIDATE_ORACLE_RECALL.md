# Candidate Oracle Recall benchmark

This is an **offline teacher diagnostic**, not a gameplay policy. It answers whether a bad decision came from failing to generate a strong plan or from ranking a strong generated plan incorrectly.

## What it does

For each decision state it:

1. runs the production candidate search budget;
2. runs a deliberately wider offline search budget;
3. deduplicates the union of both candidate sets;
4. evaluates that union once with the coverage-aware counterfactual answer key, so every candidate uses the same opponent policy and continuation semantics;
5. treats production recall as **value based**, not exact-action based.

A production candidate is recalled when its shared oracle-controlled value is within `near_best_tolerance` of the best union candidate. The default tolerance is `0.10` on the `[-1,+1]` terminal-return scale. A severe miss defaults to a generation miss with an oracle gap of at least `0.50`. Both thresholds are configurable.

The scalar value used for tolerance/gap calculations is the midpoint of the answer key's full-mixture lower/upper bounds. The output also preserves the oracle winner's bounds and labeled coverage so midpoint uncertainty remains visible.

## Metrics

`manifest.json` reports globally and by scenario/behavior family:

- `near_oracle_candidate_recall`
- `mean_oracle_value_gap` and `max_oracle_value_gap`
- `severe_miss_rate`
- `selection_accuracy_conditional_on_recall`
- candidate-generation failure count vs ranking failure count
- production/oracle simulation and elapsed-time totals/ratios

Every decision is written to `decisions.jsonl`. Material candidate misses are also copied to `severe_misses.jsonl` for later mining/training.

For generation misses, the benchmark runs exact-oracle-winner recovery probes with a wider final plan cap, wider per-unit action budget, and wider opponent-conditioning budget. These probes localize likely pruning pressure but are explicitly diagnostic rather than causal proof.

## Frozen benchmark states

```bash
cd hex-strategy-game
bash tools/run_candidate_oracle_recall.sh \
  --preset=curated \
  --out=/tmp/candidate-oracle
```

Useful overrides:

```bash
--production-own-max-plans=4
--production-opponent-max-plans=4
--oracle-own-max-actions-per-unit=12
--oracle-own-max-plans=48
--oracle-opponent-max-actions-per-unit=12
--oracle-opponent-max-plans=16
--near-best-tolerance=0.10
--severe-miss-threshold=0.50
--decision-id=curated-coordinate-fire-lanes
```

## Self-play decisions

The same runner accepts the `search_decisions.jsonl` emitted by `search_decision_dataset_v2.gd`. The recorded source budget becomes the production budget for each state:

```bash
bash tools/run_candidate_oracle_recall.sh \
  --input-jsonl=/path/to/search_decisions.jsonl \
  --max-decisions=20 \
  --out=/tmp/self-play-oracle
```

Use `--shard-index` / `--shard-count` to split expensive offline runs deterministically.