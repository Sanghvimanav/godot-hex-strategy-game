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
