from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader

from .data import (
    HexStateEncoder,
    ValueExampleDataset,
    example_group_value,
    load_jsonl_examples,
    split_examples_by_group,
)
from .metrics import handwritten_evaluator_score, sign_accuracy
from .model import HexValueNet


def _seed_everything(seed: int) -> None:
    random.seed(seed)
    torch.manual_seed(seed)


def _evaluate(model: HexValueNet, dataset: ValueExampleDataset, batch_size: int, device: torch.device) -> dict[str, float]:
    if len(dataset) == 0:
        return {"mse": float("nan"), "sign_accuracy": float("nan")}
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False)
    predictions: list[torch.Tensor] = []
    targets: list[torch.Tensor] = []
    model.eval()
    with torch.no_grad():
        for board, globals_, target in loader:
            prediction = model(board.to(device), globals_.to(device)).cpu()
            predictions.append(prediction)
            targets.append(target)
    pred = torch.cat(predictions)
    truth = torch.cat(targets)
    return {
        "mse": float(nn.functional.mse_loss(pred, truth).item()),
        "sign_accuracy": sign_accuracy(pred, truth),
    }


def _split_groups(examples: list[dict], split_key: str) -> list[str]:
    return sorted({example_group_value(example, split_key) for example in examples})


def _input_conflict_metrics(
    examples: list[dict], encoder: HexStateEncoder
) -> dict[str, int]:
    """Count identical encoded model inputs that carry incompatible value targets."""
    grouped: dict[str, list[float]] = {}
    for example in examples:
        encoded = encoder.encode(example)
        digest = hashlib.sha256()
        digest.update(encoded.board.contiguous().numpy().tobytes())
        digest.update(encoded.global_features.contiguous().numpy().tobytes())
        grouped.setdefault(digest.hexdigest(), []).append(float(encoded.target.item()))

    duplicate_groups = 0
    duplicate_examples = 0
    conflicting_groups = 0
    conflicting_examples = 0
    for targets in grouped.values():
        if len(targets) <= 1:
            continue
        duplicate_groups += 1
        duplicate_examples += len(targets)
        distinct = {round(value, 8) for value in targets}
        if len(distinct) > 1:
            conflicting_groups += 1
            conflicting_examples += len(targets)
    return {
        "duplicate_input_groups": duplicate_groups,
        "duplicate_input_examples": duplicate_examples,
        "conflicting_input_groups": conflicting_groups,
        "conflicting_input_examples": conflicting_examples,
    }


def train(args: argparse.Namespace) -> dict[str, float | int | str | list[str]]:
    _seed_everything(args.seed)
    all_examples = load_jsonl_examples(args.data)
    if not all_examples:
        raise ValueError("dataset is empty")
    train_examples, validation_examples = split_examples_by_group(
        all_examples,
        validation_fraction=args.validation_fraction,
        seed=args.seed,
        group_key=args.split_key,
    )
    encoder = HexStateEncoder()
    all_conflicts = _input_conflict_metrics(all_examples, encoder)
    train_conflicts = _input_conflict_metrics(train_examples, encoder)
    validation_conflicts = _input_conflict_metrics(validation_examples, encoder)
    train_dataset = ValueExampleDataset(train_examples, encoder)
    validation_dataset = ValueExampleDataset(validation_examples, encoder)
    train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True)

    device = torch.device(args.device)
    model = HexValueNet(hidden_channels=args.hidden_channels, residual_blocks=args.residual_blocks).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=args.weight_decay)
    loss_fn = nn.MSELoss()

    model.train()
    for _ in range(args.epochs):
        for board, globals_, target in train_loader:
            optimizer.zero_grad(set_to_none=True)
            prediction = model(board.to(device), globals_.to(device))
            loss = loss_fn(prediction, target.to(device))
            loss.backward()
            optimizer.step()

    train_metrics = _evaluate(model, train_dataset, args.batch_size, device)
    eval_examples = validation_examples if validation_examples else train_examples
    eval_dataset = validation_dataset if validation_examples else train_dataset
    eval_metrics = _evaluate(model, eval_dataset, args.batch_size, device)

    # Compare neural and handwritten evaluators on exactly the same held-out
    # nonterminal examples. Terminal positions remain useful for overall model
    # metrics, but their winner is already exposed by the board state and terminal
    # feature, so mixing them into only one side of the comparison is misleading.
    nonterminal_eval = [example for example in eval_examples if not bool(example.get("terminal", False))]
    nonterminal_dataset = ValueExampleDataset(nonterminal_eval, encoder)
    neural_nonterminal_metrics = _evaluate(model, nonterminal_dataset, args.batch_size, device)
    baseline_scores = [handwritten_evaluator_score(example) for example in nonterminal_eval]
    baseline_targets = [float(example.get("outcome", 0.0)) for example in nonterminal_eval]
    baseline_accuracy = sign_accuracy(baseline_scores, baseline_targets)
    comparison_delta = neural_nonterminal_metrics["sign_accuracy"] - baseline_accuracy

    checkpoint = {
        "model_state_dict": model.state_dict(),
        "model_config": {
            "hidden_channels": args.hidden_channels,
            "residual_blocks": args.residual_blocks,
            "board_channels": encoder.board_channels,
            "global_features": encoder.global_features,
            "board_size": encoder.board_size,
            "max_radius": encoder.max_radius,
            "unit_types": list(encoder.unit_types),
        },
        "training_config": vars(args),
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(checkpoint, output)

    train_groups = _split_groups(train_examples, args.split_key)
    validation_groups = _split_groups(validation_examples, args.split_key)
    result: dict[str, float | int | str | list[str]] = {
        "examples": len(all_examples),
        "train_examples": len(train_examples),
        "validation_examples": len(validation_examples),
        "split_key": args.split_key,
        "train_split_groups": train_groups,
        "validation_split_groups": validation_groups,
        "all_duplicate_input_groups": all_conflicts["duplicate_input_groups"],
        "all_duplicate_input_examples": all_conflicts["duplicate_input_examples"],
        "all_conflicting_input_groups": all_conflicts["conflicting_input_groups"],
        "all_conflicting_input_examples": all_conflicts["conflicting_input_examples"],
        "train_duplicate_input_groups": train_conflicts["duplicate_input_groups"],
        "train_duplicate_input_examples": train_conflicts["duplicate_input_examples"],
        "train_conflicting_input_groups": train_conflicts["conflicting_input_groups"],
        "train_conflicting_input_examples": train_conflicts["conflicting_input_examples"],
        "validation_conflicting_input_groups": validation_conflicts["conflicting_input_groups"],
        "validation_conflicting_input_examples": validation_conflicts["conflicting_input_examples"],
        "train_mse": train_metrics["mse"],
        "train_sign_accuracy": train_metrics["sign_accuracy"],
        "eval_mse": eval_metrics["mse"],
        "eval_sign_accuracy": eval_metrics["sign_accuracy"],
        "eval_nonterminal_examples": len(nonterminal_eval),
        "neural_eval_mse_nonterminal": neural_nonterminal_metrics["mse"],
        "neural_eval_sign_accuracy_nonterminal": neural_nonterminal_metrics["sign_accuracy"],
        "handwritten_eval_sign_accuracy_nonterminal": baseline_accuracy,
        "neural_minus_handwritten_sign_accuracy_nonterminal": comparison_delta,
        # Backward-compatible key, now corrected to the shared nonterminal population.
        "neural_minus_handwritten_sign_accuracy": comparison_delta,
        "metric_comparison_population": "held_out_nonterminal",
        "checkpoint": str(output),
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Train the V1 neural value model on schema-v1 self-play JSONL.")
    parser.add_argument("--data", required=True, help="Path to JSONL emitted by PureStateTrainingData")
    parser.add_argument("--output", default="artifacts/value_model.pt")
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--validation-fraction", type=float, default=0.2)
    parser.add_argument(
        "--split-key",
        default="game_id",
        help="Dotted example key used to keep related examples together (for example source.base_scenario_id)",
    )
    parser.add_argument("--hidden-channels", type=int, default=32)
    parser.add_argument("--residual-blocks", type=int, default=2)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="cpu")
    return parser


def main() -> None:
    train(build_parser().parse_args())


if __name__ == "__main__":
    main()
