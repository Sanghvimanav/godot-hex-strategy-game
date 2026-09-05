# Seeded AI Arena

The arena compares two `GameplayAI` configurations on reproducible procedurally varied full-game positions.

## Why generated-but-seeded scenarios

Purely hand-authored fixtures can overfit to one geometry, while unconstrained randomness produces many trivial or hard-to-debug games. The arena uses a middle ground:

1. choose a proven tactical scenario family from a deterministic seed;
2. apply small seeded position/HP/resource perturbations;
3. rotate the deployment;
4. play the exact same state twice, swapping which AI configuration controls Terran and Zerg.

Every result records the scenario seed, base family, rotation, variation seed, and side assignment so a surprising game is exactly reproducible.

## Efficiency

The fast preset has 8 generated pairs (16 games) and is sharded across 4 workers in CI. Pair members stay on the same shard. The default PR comparison is `fast` search versus `balanced` search, which provides an immediate strength-vs-compute sanity check.

The full preset has 32 generated pairs (64 games), uses 8 shards, and is manual so larger experiments do not tax every PR. Increase the number of seeds before widening plan budgets when the goal is robustness rather than search-depth measurement.

## Local examples

```bash
./tools/run_ai_arena.sh \
  --preset=smoke \
  --champion-profile=fast \
  --challenger-profile=balanced \
  --out=user://arena_smoke
```

Run one deterministic shard:

```bash
./tools/run_ai_arena.sh \
  --preset=fast \
  --champion-profile=fast \
  --challenger-profile=balanced \
  --shard-index=0 \
  --shard-count=4 \
  --out=user://arena_shard_0
```

The runner emits `manifest.json` and `traces.jsonl`. CI merges shard manifests with `tools/merge_ai_arena.py` and publishes a tournament summary with wins, mirrored-pair results, unresolved games, termination reasons, non-progress, decision time, and search simulations.

## Current scope

The first arena compares agent configurations available inside one code revision. This is enough for search-budget experiments and for upcoming handwritten-vs-neural evaluator/model comparisons. A true cross-Git-revision match requires a frozen champion policy/model implementation that can coexist with the challenger in one process; do not interpret same-revision configuration matches as a direct PR-code-vs-main tournament.
