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

This PR does **not** wire the network back into gameplay yet. First we want to measure whether it can predict eventual winners better than the current handwritten evaluator.

## Train

```bash
python -m pip install -r ml/requirements.txt
python -m ml.value_model.train \
  --data path/to/self_play.jsonl \
  --output artifacts/value_model.pt
```

The trainer splits by `game_id`, never by individual rows, so states and opposite-perspective copies from the same game cannot leak between training and validation sets.

The printed report includes model MSE/sign accuracy and the current `PureStateEvaluator` sign accuracy on nonterminal evaluation states.

## Test

```bash
python -m unittest discover -s ml/tests -v
```

Tests use synthetic schema-v1 examples only; they do not generate self-play games or call an API.
