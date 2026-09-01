from __future__ import annotations

import argparse
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

    nonterminal_eval = [example for example in eval_examples if not bool(example.get("terminal", False))]
    baseline_examples = nonterminal_eval if nonterminal_eval else eval_examples
    baseline_scores = [handwritten_evaluator_score(example) for example in baseline_examples]
    baseline_targets = [float(example.get("outcome", 0.0)) for example in baseline_examples]
    baseline_accuracy = sign_accuracy(baseline_scores, baseline_targets)

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
        "train_mse": train_metrics["mse"],
        "train_sign_accuracy": train_metrics["sign_accuracy"],
        "eval_mse": eval_metrics["mse"],
        "eval_sign_accuracy": eval_metrics["sign_accuracy"],
        "handwritten_eval_sign_accuracy_nonterminal": baseline_accuracy,
        "neural_minus_handwritten_sign_accuracy": eval_metrics["sign_accuracy"] - baseline_accuracy,
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
