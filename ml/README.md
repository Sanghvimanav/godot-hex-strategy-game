# Neural value model (V1)

This package is the first learned evaluator for the game. It consumes schema-v1 JSONL emitted by `PureStateTrainingData` and learns a perspective-relative value in `[-1, 1]`.

## Representation

- fixed 11x11 padded axial grid (supports current maps up to radius 5)
- valid-hex mask
- own/enemy unit-type channels, relative to `perspective_group`
- own/enemy normalized HP and energy channels
- compact global material/resource/turn features
- unknown future unit definitions map to an `other` channel so old encoders do not immediately break

The raw JSONL remains the canonical dataset. Tensor encoding is deliberately outside Godot so the representation can evolve without regenerating self-play games.

## Model

`HexValueNet` is intentionally small: a convolutional stem, two residual blocks by default, masked global pooling over valid hexes, and an MLP value head with `tanh` output.

The network is not wired back into gameplay yet. First we want to measure whether it can predict eventual winners better than the current handwritten evaluator.

## What a value target means

A training label is the **observed terminal result of a self-play rollout**, not an oracle saying which faction is objectively supposed to win the starting position. If Zerg wins a generated game, every visited state gets `+1` from Zerg's perspective and `-1` from Terran's perspective.

That means dataset quality depends on the policies that generate it. The current suite deliberately mixes search budgets and tactical states so the network does not learn only one deterministic policy's narrow behavior. Future datasets should broaden this further with additional policies/exploration and repeated position families.

## Generate self-play data

The game rules are still evolving, so generated datasets should be treated as disposable, versioned artifacts. The batch generator records the current git SHA in both `manifest.json` and every training example's `source.rules_version` field.

For the current richer experiment, from the Godot project directory:

```bash
./tools/run_self_play_dataset.sh \
  --preset=diverse \
  --out=user://self_play_dataset
```

Outputs:

- `examples.jsonl` — terminal-outcome-supervised value examples
- `manifest.json` — rules SHA, suite version, search budgets, deterministic variation seeds, per-game status/outcome, and example counts

Presets:

- `smoke` — one cheap terminal pipeline check
- `starter` — the original 10-job / four-family benchmark retained for historical comparison
- `diverse` — 24 jobs across 10 tactical families, including Hydralisk range/stun, Medic sustain, Scout kiting, worker/economy screens, Baneling flanks, and mixed attrition

The 14 added `diverse` jobs use fixed variation seeds. Each seed can perturb unit positions by at most one legal hex and vary HP, energy, and resource context. The same rules commit + suite version + seed reproduces the same starting state.

Campaign scenarios are intentionally excluded for now. The pure rollout currently ends on unit elimination, while some campaigns have scenario-specific objectives; those should become first-class value-model inputs before campaign self-play is used for training.

Repeated identical deterministic games are not useful training data, so the generator varies curated starting states/rotations rather than blindly replaying the same job N times.

## Train

```bash
python -m pip install -r ml/requirements.txt
python -m ml.value_model.train \
  --data path/to/examples.jsonl \
  --output artifacts/value_model.pt
```

The default trainer splits by `game_id`, never by individual rows, so states and opposite-perspective copies from the same game cannot leak between training and validation sets.

For experiments where multiple games are transformed variants of the same tactical setup, use a broader grouping key so those variants stay together:

```bash
python -m ml.value_model.train \
  --data artifacts/self_play/examples.jsonl \
  --output artifacts/value_model.pt \
  --validation-fraction 0.25 \
  --split-key source.base_scenario_id
```

This holds out entire tactical scenario families rather than allowing rotations/seeded variants of the same setup to appear on both sides of the split.

The printed report includes model MSE/sign accuracy, train/validation split groups, and the current `PureStateEvaluator` sign accuracy on the same held-out nonterminal evaluation states.

### Decision-quality metrics

Winner-sign accuracy is a coarse state metric: it asks only whether an evaluator predicts the eventual winner's side of zero. Search needs a stricter benchmark because it uses values to choose among candidate plans at the same decision.

`candidate_ranking_metrics` compares every candidate pair with different target values inside a shared `decision_id`. Correct ordering earns one point, a predicted tie earns half credit, and target ties are omitted.

`top_plan_regret_metrics` measures the target value lost by executing the highest-predicted candidate instead of an oracle-best candidate:

```text
regret = max(candidate target values) - target value of argmax(predicted values)
```

Zero regret means the evaluator selected an actually optimal candidate. Mean regret measures typical decision loss, maximum regret catches catastrophic choices, and the optimal-selection rate reports how often regret is zero.

The counterfactual benchmark exporter now emits alternative candidates sharing a stable `decision_id`. From the Godot project directory:

```bash
bash tools/run_counterfactual_benchmark.sh \
  --preset=starter \
  --out=user://counterfactual_benchmark
```

It writes `candidates.jsonl` plus a `manifest.json`. A candidate target is the weighted terminal return under two explicit assumptions:

- an opponent-plan proposal mixture for the simultaneous first turn
- a continuation-search-budget mixture for play after that joint turn

This is a policy-conditional counterfactual estimate, not an objectively correct or oracle value. The rules SHA, suite version, opponent-mixture version, continuation-mixture version, individual sample weights, and plan signatures are exported so a target can be reproduced and compared only under the assumptions that produced it.

Turn-limit and failed rollouts stay unlabeled. Each candidate therefore reports `labeled_weight_fraction` as coverage rather than treating missing outcomes as draws. `return_stddev` and `estimated_standard_error` summarize disagreement among the weighted policy samples; they are descriptive sensitivity heuristics, not calibrated confidence intervals. Pairwise comparisons use that spread to leave close candidates `uncertain`, and `estimated_best_candidate_ids` may contain more than one candidate.

The `starter` suite currently covers three tactical decisions from both faction perspectives. It is deliberately small: its immediate purpose is to validate the target definition and exercise candidate-ranking/top-plan-regret metrics before scaling the scenario set.

## Generalization experiment

`.github/workflows/value-model-experiment.yml` is an on-demand experiment runner and runs when experiment-related files change in a pull request. Its default preset is now `diverse`.

It performs the complete pipeline:

1. generate the versioned self-play dataset
2. audit terminal/unlabeled/failed game counts and require multiple labeled tactical families
3. train `HexValueNet` on CPU
4. hold out whole `source.base_scenario_id` families
5. compare neural and handwritten evaluator sign accuracy on the held-out states
6. upload `examples.jsonl`, `manifest.json`, `metrics.json`, `summary.md`, and the PyTorch checkpoint as a 14-day workflow artifact

These experiments are still directional, not production-quality benchmarks. The eventual strength benchmark is direct gameplay: identical search driven by the neural evaluator versus identical search driven by the handwritten evaluator. Opponent interestingness should be tracked separately from strength.

## Test

```bash
python -m unittest discover -s ml/tests -v
```

Python tests use synthetic schema-v1 examples only; they do not generate self-play games or call an API. Godot's normal headless suite includes cheap self-play structure/provenance regressions.
