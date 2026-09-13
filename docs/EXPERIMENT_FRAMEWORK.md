# Experiment framework v1

This repository has several useful AI experiment workflows, but historically each workflow encoded its own seeds, budgets, artifact names, gates, and resume behavior. The v1 experiment framework provides a small common contract so new experiments can be defined once and reused by Actions jobs without changing gameplay or model code.

## 1. Commit the experiment definition

An experiment starts with a versioned JSON manifest. See `experiments/example_phase_one_v1.json`.

The manifest records:

- experiment ID and schema version;
- search candidate/response budgets, decision budget, and proposal mode;
- non-overlapping seed partitions and their role;
- diagnostic and promotion tiers;
- data-use policy;
- scorecard gates.

Do not edit a manifest after using it for a meaningful run. Copy it to a new version instead. The runner hashes the full manifest and writes that hash into the plan and every shard result, so accidental configuration drift cannot be resumed as if it were the same experiment.

A generated plan adds run-specific provenance that does not belong in the reusable manifest: the exact rules/source SHA and the checkpoint SHA-256.

## 2. Keep training, diagnostics, and frozen evaluation separate

Every seed partition has one role:

- `training`: may be used for training and mistake mining;
- `diagnostic`: cheap experiments such as radius-one tactical checks; may be mined for diagnosis but is not training data unless a future manifest deliberately changes that policy;
- `frozen_eval`: evaluation-only data.

The validator rejects any data policy that includes `frozen_eval` in training or mistake mining. It also rejects a non-promotion tier that consumes frozen evaluation seeds, and rejects a promotion tier containing anything except frozen evaluation seeds.

This means a cheap diagnostic tier can be run repeatedly while the frozen 40-game promotion population stays untouched.

## 3. Build a stable, resumable shard plan

Validate and plan an experiment locally:

```bash
python -m ml.experiments.runner validate experiments/example_phase_one_v1.json
python -m ml.experiments.runner plan experiments/example_phase_one_v1.json \
  --tier diagnostic \
  --rules-sha "$(git rev-parse HEAD)" \
  --checkpoint-sha256 "$CHECKPOINT_SHA256" \
  --output /tmp/experiment-plan.json
```

Shard IDs are deterministic from the committed manifest tier and partition. If prior shard artifacts are downloaded into a directory, pass that directory back to `plan`:

```bash
python -m ml.experiments.runner plan experiments/example_phase_one_v1.json \
  --tier diagnostic \
  --rules-sha "$(git rev-parse HEAD)" \
  --checkpoint-sha256 "$CHECKPOINT_SHA256" \
  --results-dir /tmp/prior-results \
  --output /tmp/experiment-plan.json
```

Only exact matches are resumed. A prior result must match the experiment ID, tier, manifest hash, rules SHA, checkpoint hash, shard ID, and partition. Results from another experiment can live in the same downloaded artifact directory and are ignored. Conflicting duplicate shards fail closed.

Use `missing` when debugging a partial run:

```bash
python -m ml.experiments.runner missing \
  --plan /tmp/experiment-plan.json \
  --results-dir /tmp/prior-results
```

## 4. Emit the standard shard result contract

Each workload adapter should write one JSON result per shard with this shape:

```json
{
  "schema_version": 1,
  "experiment_id": "example-phase-one-v1",
  "tier": "diagnostic",
  "manifest_sha256": "<64-char manifest hash>",
  "shard_id": "diagnostic_radius_one-00",
  "partition": "diagnostic_radius_one",
  "provenance": {
    "rules_sha": "<exact source SHA>",
    "checkpoint_sha256": "<checkpoint SHA-256 or null>"
  },
  "games": {
    "wins": 2,
    "losses": 1,
    "draws": 0,
    "unresolved": 1,
    "failures": 0
  },
  "metrics": {
    "candidate_recall": {"sum": 3.5, "count": 4},
    "selection_accuracy": {"sum": 3.0, "count": 4},
    "response_coverage": {"sum": 4.0, "count": 4}
  },
  "timing": {
    "decision_ms": [1120, 980, 1450],
    "training_seconds": 0
  }
}
```

Metrics use `sum` plus `count` rather than a pre-averaged number so shards of different sizes aggregate correctly. Workloads can add any metric name without changing the framework.

`draws` count as resolved games and remain in the denominator for `resolved_win_rate`. Failed games are included in the total attempted-game denominator and automatically fail the scorecard.

## 5. Produce one scorecard and keep failures visible

After downloading all available shard artifacts:

```bash
python -m ml.experiments.runner summarize \
  --plan /tmp/experiment-plan.json \
  --results-dir /tmp/results \
  --output /tmp/scorecard.json \
  --require-pass
```

The scorecard contains:

- wins, losses, draws, unresolved and failed games;
- resolution and resolved-win rates;
- arbitrary quality metrics such as candidate recall, selection accuracy, and response coverage;
- p50, p95, and maximum decision time;
- exact experiment/rules/checkpoint provenance;
- results by named seed partition;
- every gate, its actual value, expected threshold, pass/fail state, and failure reason;
- all missing shard IDs.

`all_shards_complete` and `no_failed_games` are automatic gates. Missing metrics fail their gate instead of disappearing from the report.

## GitHub Actions entrypoint

`.github/workflows/experiment-plan.yml` can be run manually or called by another workflow. It validates the manifest, optionally downloads artifacts from an earlier Actions run, creates the exact-provenance plan, and exports the pending-shard matrix. This lets experiment-specific workflows focus on their workload command rather than reimplementing seed partitioning and resume logic.

Existing workflows do not need to migrate in one large change. New experiments should use this contract first; existing Arena, self-play, value-model, and benchmark workflows can adopt it when they are next modified.

## Non-goals

This framework does not change the game rules, AI search, training algorithm, model architecture, or current champion. It also does not automatically promote a checkpoint. It standardizes experiment definition, provenance, sharding, result aggregation, and promotion evidence so those decisions are easier to audit.
