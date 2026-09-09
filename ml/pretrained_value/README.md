# Pretrained value-transfer experiment

This experiment asks one narrow question: **does a pretrained transformer learn the current game-value/ranking task with less game supervision than the scratch `HexValueNet`?**

It deliberately does not change candidate generation, opponent-response search, minimax, gameplay integration, or promotion rules.

## Fair comparison

Both arms use the same:

- frozen value examples and sibling-ranking pairs from a neural-policy artifact
- frozen held-out scenario families (`baneling_finish`, `mixed_force`, `scout_kite` by default)
- terminal-value MSE objective
- weighted logistic sibling-ranking objective
- ranking weight (`0.5` by default)
- frozen counterfactual candidate benchmark

The pretrained arm serializes **only information exposed by `HexStateEncoder`**. It omits winners, actions, handwritten/neural scores, unit ids, effects, and other raw-state fields that would give it extra information.

The default pretrained model is `Qwen/Qwen3-0.6B` with LoRA on `q_proj`/`v_proj` (rank 8, alpha 16). The scratch baseline remains the 32-channel, two-block `HexValueNet`.

## Data curve

The full sweep trains both arms on nested whole-game subsets of the training population:

- 10%
- 25%
- 50%
- 100%

The validation families never change between fractions. The primary sample-efficiency question is whether a lower-data pretrained run matches or exceeds the 100%-data CNN's held-out sibling-ranking accuracy. Counterfactual ranking/regret is the stronger secondary check.

Candidate Oracle Recall is not expected to change because this experiment does not alter candidate generation.

## GitHub Actions

Run **Pretrained Value Transfer** manually.

- `pilot` (default): 25% only
- `full`: 10/25/50/100% in parallel

The workflow defaults to the current iteration-3 supervision artifact and the frozen counterfactual artifact, but both source run IDs/artifact names are explicit inputs so results remain reproducible.

Ordinary PR CI does **not** download or fine-tune the pretrained model. It only runs the lightweight serializer/subsampling tests through the existing value-model test workflow.

## Local run

```bash
python -m pip install torch --index-url https://download.pytorch.org/whl/cpu
python -m pip install -r ml/pretrained_value/requirements.txt

python -m ml.pretrained_value.experiment \
  --data /path/to/combined_examples.jsonl \
  --ranking-data /path/to/combined_ranking_pairs.jsonl \
  --output-dir artifacts/pretrained-transfer-25 \
  --training-fraction 0.25
```

Then score the same frozen counterfactual candidates:

```bash
python -m ml.value_model.evaluate_counterfactual \
  --candidates /path/to/candidates_with_handwritten.jsonl \
  --checkpoint artifacts/pretrained-transfer-25/cnn_value_model.pt \
  --output artifacts/pretrained-transfer-25/cnn_counterfactual_metrics.json

python -m ml.pretrained_value.evaluate_counterfactual \
  --candidates /path/to/candidates_with_handwritten.jsonl \
  --checkpoint artifacts/pretrained-transfer-25/pretrained_adapter \
  --output artifacts/pretrained-transfer-25/pretrained_counterfactual_metrics.json
```

The aggregate report compares held-out value/sign accuracy, sibling ranking, counterfactual ranking/regret, and training wall time.
