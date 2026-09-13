from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

import torch

from ml.pretrained_value.data import serialize_value_example
from ml.value_model.data import load_jsonl_examples
from ml.value_model.evaluate_counterfactual import (
    _interval_fit_metrics,
    _metric_set,
    _sample_example,
    _weighted_average,
)


def _load_pretrained(checkpoint_dir: str | Path, device: torch.device):
    try:
        from peft import PeftModel
        from transformers import AutoModelForSequenceClassification, AutoTokenizer
    except ImportError as exc:
        raise RuntimeError(
            "pretrained experiment dependencies are missing; install ml/pretrained_value/requirements.txt"
        ) from exc

    checkpoint = Path(checkpoint_dir)
    experiment_config = json.loads((checkpoint / "experiment_config.json").read_text())
    base_model_name = str(experiment_config["base_model_name"])
    tokenizer = AutoTokenizer.from_pretrained(checkpoint, use_fast=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    base = AutoModelForSequenceClassification.from_pretrained(
        base_model_name, num_labels=1, problem_type="regression"
    )
    base.config.pad_token_id = tokenizer.pad_token_id
    model = PeftModel.from_pretrained(base, checkpoint).to(device)
    model.eval()
    return model, tokenizer, int(experiment_config.get("max_length", 384)), base_model_name


def _score_examples(
    model,
    tokenizer,
    examples: Sequence[dict[str, Any]],
    batch_size: int,
    max_length: int,
    device: torch.device,
) -> list[float]:
    results: list[float] = []
    model.eval()
    with torch.no_grad():
        for start in range(0, len(examples), batch_size):
            texts = [serialize_value_example(example) for example in examples[start : start + batch_size]]
            encoded = tokenizer(
                texts,
                padding=True,
                truncation=True,
                max_length=max_length,
                return_tensors="pt",
            )
            encoded = {key: value.to(device) for key, value in encoded.items()}
            scores = torch.tanh(model(**encoded).logits.squeeze(-1))
            results.extend(float(value) for value in scores.cpu().tolist())
    return results


def evaluate_rows(
    rows: Sequence[dict[str, Any]],
    checkpoint_dir: str | Path,
    batch_size: int = 8,
    device_name: str = "cpu",
) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    labeled_examples: list[dict[str, Any]] = []
    labeled_weights: list[float] = []
    all_examples: list[dict[str, Any]] = []
    all_weights: list[float] = []

    for row in rows:
        if not isinstance(row, dict):
            continue
        estimate = row.get("target_estimate", {})
        if not isinstance(estimate, dict) or int(estimate.get("return_count", 0)) <= 0:
            continue
        assumptions = row.get("assumptions", {})
        if not isinstance(assumptions, dict):
            assumptions = {}
        labeled_start = len(labeled_examples)
        all_start = len(all_examples)
        for sample in row.get("samples", []):
            if not isinstance(sample, dict):
                continue
            weight = max(0.0, float(sample.get("weight", 0.0)))
            state = sample.get("state_after_first_turn")
            if (
                not bool(sample.get("valid", True))
                or weight <= 0.0
                or not isinstance(state, dict)
                or not state
            ):
                continue
            example = _sample_example(row, sample)
            all_examples.append(example)
            all_weights.append(weight)
            if bool(sample.get("labeled", False)):
                labeled_examples.append(example)
                labeled_weights.append(weight)
        labeled_stop = len(labeled_examples)
        all_stop = len(all_examples)
        if labeled_stop == labeled_start or all_stop == all_start:
            continue
        conditional_target = float(
            estimate.get("conditional_labeled_mean_return", estimate.get("mean_return", 0.0))
        )
        candidates.append(
            {
                "decision_id": str(row.get("decision_id", "")),
                "candidate_id": str(row.get("candidate_id", "")),
                "candidate_label": str(row.get("candidate_label", row.get("candidate_id", ""))),
                "target": conditional_target,
                "target_lower_bound": float(estimate.get("full_mixture_lower_bound", conditional_target)),
                "target_upper_bound": float(estimate.get("full_mixture_upper_bound", conditional_target)),
                "target_standard_error": max(0.0, float(estimate.get("estimated_standard_error", 0.0))),
                "coverage": float(estimate.get("labeled_weight_fraction", 0.0)),
                "separation_z": max(0.0, float(assumptions.get("separation_z", 1.96))),
                "labeled_sample_start": labeled_start,
                "labeled_sample_stop": labeled_stop,
                "all_sample_start": all_start,
                "all_sample_stop": all_stop,
            }
        )

    if not candidates:
        raise ValueError("counterfactual data contains no labeled candidates with first-turn states")
    separation_values = {float(candidate["separation_z"]) for candidate in candidates}
    if len(separation_values) != 1:
        raise ValueError("counterfactual candidates disagree on separation_z")
    separation_z = next(iter(separation_values))

    device = torch.device(device_name)
    model, tokenizer, max_length, base_model_name = _load_pretrained(checkpoint_dir, device)
    labeled_scores = _score_examples(model, tokenizer, labeled_examples, batch_size, max_length, device)
    all_scores = _score_examples(model, tokenizer, all_examples, batch_size, max_length, device)

    labeled_candidate_scores: list[float] = []
    all_candidate_scores: list[float] = []
    for candidate in candidates:
        ls = int(candidate["labeled_sample_start"])
        le = int(candidate["labeled_sample_stop"])
        alls = int(candidate["all_sample_start"])
        alle = int(candidate["all_sample_stop"])
        labeled_candidate_scores.append(_weighted_average(labeled_weights[ls:le], labeled_scores[ls:le]))
        all_candidate_scores.append(_weighted_average(all_weights[alls:alle], all_scores[alls:alle]))

    targets = [float(candidate["target"]) for candidate in candidates]
    lower_bounds = [float(candidate["target_lower_bound"]) for candidate in candidates]
    upper_bounds = [float(candidate["target_upper_bound"]) for candidate in candidates]
    standard_errors = [float(candidate["target_standard_error"]) for candidate in candidates]
    decision_ids = [str(candidate["decision_id"]) for candidate in candidates]
    decision_counts: dict[str, int] = {}
    for decision_id in decision_ids:
        decision_counts[decision_id] = decision_counts.get(decision_id, 0) + 1
    evaluated_decisions = sum(count >= 2 for count in decision_counts.values())
    if evaluated_decisions == 0:
        raise ValueError("counterfactual data contains no decision with at least two labeled candidates")

    details = []
    for candidate, labeled_score, all_score in zip(candidates, labeled_candidate_scores, all_candidate_scores):
        details.append(
            {
                "decision_id": candidate["decision_id"],
                "candidate_id": candidate["candidate_id"],
                "candidate_label": candidate["candidate_label"],
                "target_return": candidate["target"],
                "target_full_mixture_lower_bound": candidate["target_lower_bound"],
                "target_full_mixture_upper_bound": candidate["target_upper_bound"],
                "target_standard_error": candidate["target_standard_error"],
                "target_coverage": candidate["coverage"],
                "pretrained_score_labeled_policy": labeled_score,
                "pretrained_score_all_policy": all_score,
            }
        )

    return {
        "base_model_name": base_model_name,
        "evaluated_candidates": len(candidates),
        "evaluated_decisions": evaluated_decisions,
        "mean_target_coverage": sum(float(candidate["coverage"]) for candidate in candidates) / len(candidates),
        "candidate_details": details,
        "interval_diagnostics": {
            "pretrained_value_model_all_policy": _interval_fit_metrics(all_candidate_scores, lower_bounds, upper_bounds)
        },
        "evaluators": {
            "pretrained_value_model": _metric_set(
                labeled_candidate_scores, targets, standard_errors, decision_ids, separation_z
            )
        },
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Evaluate the LoRA pretrained value model on frozen counterfactual candidates."
    )
    parser.add_argument("--candidates", required=True)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--device", default="cpu")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    rows = load_jsonl_examples(args.candidates)
    result = evaluate_rows(rows, args.checkpoint, args.batch_size, args.device)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
