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

## Generate self-play data

The game rules are still evolving, so generated datasets should be treated as disposable, versioned artifacts. The batch generator records the current git SHA in both `manifest.json` and every training example's `source.rules_version` field.

From the Godot project directory:

```bash
./tools/run_self_play_dataset.sh \
  --preset=starter \
  --out=user://self_play_dataset
```

Outputs:

- `examples.jsonl` — terminal-outcome-supervised value examples
- `manifest.json` — rules SHA, suite version, search budgets, per-game status/outcome, and example counts

The `starter` preset currently uses 10 deterministic jobs across four tactical setups. It mixes 2x2, 4x4, and limited 8x8 opponent-response search, plus rotated starting positions. Broad 8x8 jobs are intentionally limited to short decisive situations because they are expensive.

Campaign scenarios are intentionally excluded for now. The pure rollout currently ends on unit elimination, while some campaigns have scenario-specific objectives; those should become first-class value-model inputs before campaign self-play is used for training.

For a cheap pipeline check:

```bash
./tools/run_self_play_dataset.sh \
  --preset=smoke \
  --out=user://self_play_smoke
```

Repeated identical deterministic games are not useful training data, so the generator varies curated starting states/rotations rather than blindly replaying the same job N times.

## Train

```bash
python -m pip install -r ml/requirements.txt
python -m ml.value_model.train \
  --data path/to/examples.jsonl \
  --output artifacts/value_model.pt
```

The default trainer splits by `game_id`, never by individual rows, so states and opposite-perspective copies from the same game cannot leak between training and validation sets.

For experiments where multiple games are transformed variants of the same tactical setup, use a broader grouping key so those variants stay together. The starter self-play suite records `source.base_scenario_id`, so the first real comparison uses:

```bash
python -m ml.value_model.train \
  --data artifacts/self_play/examples.jsonl \
  --output artifacts/value_model.pt \
  --validation-fraction 0.25 \
  --split-key source.base_scenario_id
```

This holds out entire tactical scenario families rather than allowing rotated versions of the same setup to appear on both sides of the split.

The printed report includes model MSE/sign accuracy, train/validation split groups, and the current `PureStateEvaluator` sign accuracy on the same held-out nonterminal evaluation states.

## First real comparison

`.github/workflows/value-model-experiment.yml` is an on-demand experiment runner. It also runs when experiment-related files change in a pull request, which gives the first implementation PR one real comparison without making ordinary gameplay PRs pay for self-play/training.

It performs the complete pipeline:

1. generate the versioned `starter` self-play dataset
2. audit terminal/unlabeled/failed game counts
3. train `HexValueNet` on CPU
4. hold out whole `source.base_scenario_id` families
5. compare neural and handwritten evaluator sign accuracy on the held-out states
6. upload `examples.jsonl`, `manifest.json`, `metrics.json`, `summary.md`, and the PyTorch checkpoint as a 14-day workflow artifact

This starter experiment is intentionally small and should be interpreted as directional evidence only. If it shows useful signal, the next step is a larger, more diverse dataset and then an actual gameplay arena where search using the neural evaluator plays against search using the handwritten evaluator.

## Test

```bash
python -m unittest discover -s ml/tests -v
```

Python tests use synthetic schema-v1 examples only; they do not generate self-play games or call an API. Godot's normal headless suite includes one cheap self-play smoke regression that verifies dataset provenance and terminal labeling semantics.
