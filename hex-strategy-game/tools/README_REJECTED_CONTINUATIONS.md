# Rejected continuation and sibling-ranking labels

`search_decision_continuations.gd` adds sparse counterfactual outcome labels to the search-decision dataset. `search_decision_sibling_pairs.gd` then turns selected decisions into denser response-controlled ranking supervision.

## Offline candidate capture

Normal gameplay search is unchanged. `run_self_play_dataset.sh` post-processes traces after the played game has finished.

For ordinary smoke/starter runs the historical 2x2 decision recorder is preserved. For the `diverse` value-model dataset, fast played 2x2 turns are re-captured offline as **4 own candidates x 2 modeled opponent responses**. This gives sibling training A/B/C/D alternatives while preserving the opponent-response set from the played search. Because dense ranking later holds one response fixed, widening the opponent side would add compute without increasing the number of own-plan sibling comparisons.

The wider capture is implemented by `search_decision_dataset_v2.gd`. Callers can override it explicitly with:

```bash
--decision-own-max-plans=4 --decision-opponent-max-plans=2
```

## Prioritized rejected continuations

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
2. the top two neural worst-case candidate scores are within `--neural-close-threshold`;
3. the forced first turn creates a large elimination, unit-count, health, or command-objective swing;
4. deterministic fallback ordering for the remaining rejected candidates.

Sparse rejected continuations remain useful diagnostics and provide neural-priority signals for sibling selection. They are no longer the only source of ranking pairs.

Outputs:

- `rejected_continuations.jsonl`: sparse rejected-candidate labels and provenance;
- `rejected_continuations_manifest.json`: counts, prioritization reasons, label coverage, and whether neural prioritization was enabled.

## Dense sibling-ranking pairs

The dense ranking tool selects a family-diverse set of decisions, keeping neural-priority decisions from the rejected-continuation analysis and adding fallback decisions from other scenario families. For every selected decision it:

1. takes **every stored candidate** from the offline decision matrix;
2. chooses one modeled opponent response and holds that response fixed for all candidates;
3. continues each candidate once with the real `PureStateGameRollout` / handwritten greedy policy;
4. compares every pair of terminal sibling branches;
5. emits every useful preference.

Run it with:

```bash
godot --headless --path . res://tools/search_decision_sibling_pairs.tscn -- \
  --out=/path/to/self_play \
  --max-decisions=24
```

A four-candidate decision can therefore contribute up to six pairwise comparisons instead of at most one `played vs rejected` pair.

Preference rules remain deliberately conservative:

- `win > draw > loss` with full pair weight;
- faster win > slower win with lower pair weight (`0.25`);
- loss-vs-loss receives no label, so training never rewards merely delaying defeat;
- unresolved branches remain unlabeled.

Additional outputs:

- `sibling_branches.jsonl`: every continued candidate branch and its terminal/unresolved result;
- `ranking_pairs.jsonl`: better/worse sibling leaf states, pair weight, outcome provenance, and source decision metadata;
- `ranking_pairs_manifest.json`: selected decision/family coverage, branch counts, pair counts, label types, invalid/unresolved counts, and supervision policy.

## Why this is denser

The first ranked follow-up after Value Model Experiment #79 had 652 ordinary value examples but only **4 sibling pairs**: 2 outcome pairs and 2 faster-win pairs. All four came from training families, so held-out ranking accuracy had to fall back to the training population.

Dense sibling capture attacks both problems:

- wider offline 4x2 matrices expose four own-plan alternatives from one exact parent state while preserving the played opponent-response set;
- family-diverse decision selection makes it much more likely that held-out value families also contain sibling pairs;
- every candidate is continued under the same response and all useful pairwise preferences are retained.

## Training

Train the two-objective model with:

```bash
python -m ml.value_model.train_ranked \
  --data /path/to/examples.jsonl \
  --ranking-data /path/to/ranking_pairs.jsonl \
  --output /path/to/ranked_value_model.pt \
  --ranking-weight 0.5
```

The model architecture is unchanged. The current trainer starts a **fresh `HexValueNet` from new random weights** for each experiment. It does not continue training the previous checkpoint. That keeps value-only vs value+ranking comparisons clean: both models learn from the same broad outcome dataset, while the ranked model additionally receives sibling-ordering loss.

Training minimizes terminal-outcome MSE plus weighted logistic pairwise loss that pushes `V(better) > V(worse)`. Held-out sibling-ranking accuracy is reported separately from winner-prediction accuracy.

## Experiment integration

The manual **Value Model Experiment** remains opt-in. When it completes successfully, the `Rejected Continuation Labels` workflow downloads that run's self-play shards and value-only checkpoint, merges the wider search-decision matrices, labels a sparse set of neural-priority rejected alternatives, selects up to 24 family-diverse decisions, expands every stored candidate under one fixed opponent response, builds dense sibling pairs, and retrains a fresh value + ranking checkpoint.

The follow-up compares value-only versus ranked models on held-out winner prediction, held-out sibling ordering when available, and counterfactual ranking/regret. A later frozen 4x4 Arena remains the gameplay-strength gate.
