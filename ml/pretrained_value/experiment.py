from __future__ import annotations

import argparse
import json
import random
import time
from pathlib import Path
from typing import Any, Sequence

import torch
from torch import nn
from torch.utils.data import DataLoader

from ml.pretrained_value.data import (
    nested_group_subsample,
    ranking_pair_texts,
    rows_with_group_values,
    serialize_value_example,
)
from ml.value_model.data import HexStateEncoder, ValueExampleDataset, load_jsonl_examples
from ml.value_model.metrics import sign_accuracy
from ml.value_model.model import HexValueNet
from ml.value_model.ranking import (
    RankingPairDataset,
    load_ranking_pairs,
    pairwise_ranking_loss,
    ranking_accuracy,
)


def _seed_everything(seed: int) -> None:
    random.seed(seed)
    torch.manual_seed(seed)


def _split_by_validation_groups(
    examples: Sequence[dict[str, Any]],
    pairs: Sequence[dict[str, Any]],
    split_key: str,
    validation_groups: set[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    train_examples = rows_with_group_values(examples, split_key, validation_groups, include=False)
    validation_examples = rows_with_group_values(examples, split_key, validation_groups, include=True)
    train_pairs = rows_with_group_values(pairs, split_key, validation_groups, include=False)
    validation_pairs = rows_with_group_values(pairs, split_key, validation_groups, include=True)
    if not train_examples or not validation_examples:
        raise ValueError("frozen validation groups must leave non-empty train and validation examples")
    if not train_pairs or not validation_pairs:
        raise ValueError("frozen validation groups must leave non-empty train and validation ranking pairs")
    return train_examples, validation_examples, train_pairs, validation_pairs


def _evaluate_cnn_values(
    model: HexValueNet,
    examples: Sequence[dict[str, Any]],
    batch_size: int,
    device: torch.device,
) -> dict[str, float]:
    dataset = ValueExampleDataset(examples)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False)
    predictions: list[torch.Tensor] = []
    targets: list[torch.Tensor] = []
    model.eval()
    with torch.no_grad():
        for board, globals_, target in loader:
            predictions.append(model(board.to(device), globals_.to(device)).cpu())
            targets.append(target.cpu())
    prediction = torch.cat(predictions)
    target = torch.cat(targets)
    return {
        "mse": float(nn.functional.mse_loss(prediction, target).item()),
        "sign_accuracy": sign_accuracy(prediction.tolist(), target.tolist()),
    }


def _evaluate_cnn_ranking(
    model: HexValueNet,
    pairs: Sequence[dict[str, Any]],
    batch_size: int,
    device: torch.device,
) -> dict[str, float]:
    dataset = RankingPairDataset(pairs)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False)
    better_all: list[torch.Tensor] = []
    worse_all: list[torch.Tensor] = []
    losses: list[float] = []
    model.eval()
    with torch.no_grad():
        for better_board, better_globals, worse_board, worse_globals, weights in loader:
            better = model(better_board.to(device), better_globals.to(device))
            worse = model(worse_board.to(device), worse_globals.to(device))
            losses.append(float(pairwise_ranking_loss(better, worse, weights.to(device)).item()))
            better_all.append(better.cpu())
            worse_all.append(worse.cpu())
    return {
        "loss": sum(losses) / len(losses),
        "accuracy": ranking_accuracy(torch.cat(better_all), torch.cat(worse_all)),
    }


def _train_cnn(
    train_examples: Sequence[dict[str, Any]],
    validation_examples: Sequence[dict[str, Any]],
    train_pairs: Sequence[dict[str, Any]],
    validation_pairs: Sequence[dict[str, Any]],
    args: argparse.Namespace,
    output: Path,
) -> dict[str, Any]:
    _seed_everything(args.seed)
    device = torch.device(args.cnn_device)
    encoder = HexStateEncoder()
    model = HexValueNet(
        hidden_channels=args.cnn_hidden_channels,
        residual_blocks=args.cnn_residual_blocks,
    ).to(device)
    optimizer = torch.optim.AdamW(
        model.parameters(), lr=args.cnn_learning_rate, weight_decay=args.cnn_weight_decay
    )
    value_loss_fn = nn.MSELoss()
    train_loader = DataLoader(
        ValueExampleDataset(train_examples, encoder),
        batch_size=args.cnn_batch_size,
        shuffle=True,
    )
    ranking_loader = DataLoader(
        RankingPairDataset(train_pairs, encoder),
        batch_size=min(args.cnn_ranking_batch_size, len(train_pairs)),
        shuffle=True,
    )

    started = time.perf_counter()
    for _ in range(args.cnn_epochs):
        model.train()
        ranking_iterator = iter(ranking_loader)
        for board, globals_, target in train_loader:
            try:
                ranking_batch = next(ranking_iterator)
            except StopIteration:
                ranking_iterator = iter(ranking_loader)
                ranking_batch = next(ranking_iterator)
            better_board, better_globals, worse_board, worse_globals, weights = ranking_batch
            optimizer.zero_grad(set_to_none=True)
            prediction = model(board.to(device), globals_.to(device))
            value_loss = value_loss_fn(prediction, target.to(device))
            better = model(better_board.to(device), better_globals.to(device))
            worse = model(worse_board.to(device), worse_globals.to(device))
            rank_loss = pairwise_ranking_loss(better, worse, weights.to(device))
            (value_loss + args.ranking_weight * rank_loss).backward()
            optimizer.step()
    train_seconds = time.perf_counter() - started

    output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "model_state_dict": model.state_dict(),
            "model_config": {
                "hidden_channels": args.cnn_hidden_channels,
                "residual_blocks": args.cnn_residual_blocks,
                "board_channels": encoder.board_channels,
                "global_features": encoder.global_features,
                "board_size": encoder.board_size,
                "max_radius": encoder.max_radius,
                "unit_types": list(encoder.unit_types),
            },
            "training_config": {
                "experiment": "pretrained_value_transfer_v1",
                "training_fraction": args.training_fraction,
                "validation_groups": sorted(args.validation_groups),
                "ranking_weight": args.ranking_weight,
                "epochs": args.cnn_epochs,
                "seed": args.seed,
            },
        },
        output,
    )
    return {
        "parameter_count": sum(parameter.numel() for parameter in model.parameters()),
        "train_seconds": train_seconds,
        "validation_value": _evaluate_cnn_values(model, validation_examples, args.cnn_batch_size, device),
        "validation_ranking": _evaluate_cnn_ranking(
            model, validation_pairs, args.cnn_ranking_batch_size, device
        ),
        "checkpoint": str(output),
    }


def _tokenize(tokenizer, texts: Sequence[str], max_length: int, device: torch.device):
    encoded = tokenizer(
        list(texts),
        padding=True,
        truncation=True,
        max_length=max_length,
        return_tensors="pt",
    )
    return {key: value.to(device) for key, value in encoded.items()}


def _transformer_scores(model, tokenizer, texts: Sequence[str], max_length: int, device: torch.device) -> torch.Tensor:
    encoded = _tokenize(tokenizer, texts, max_length, device)
    logits = model(**encoded).logits.squeeze(-1)
    return torch.tanh(logits)


def _batched_transformer_scores(
    model,
    tokenizer,
    texts: Sequence[str],
    batch_size: int,
    max_length: int,
    device: torch.device,
) -> torch.Tensor:
    outputs: list[torch.Tensor] = []
    model.eval()
    with torch.no_grad():
        for start in range(0, len(texts), batch_size):
            outputs.append(
                _transformer_scores(
                    model, tokenizer, texts[start : start + batch_size], max_length, device
                ).cpu()
            )
    return torch.cat(outputs) if outputs else torch.empty(0)


def _evaluate_transformer_values(
    model,
    tokenizer,
    examples: Sequence[dict[str, Any]],
    batch_size: int,
    max_length: int,
    device: torch.device,
) -> dict[str, float]:
    texts = [serialize_value_example(example) for example in examples]
    targets = torch.tensor([float(example.get("outcome", 0.0)) for example in examples])
    predictions = _batched_transformer_scores(model, tokenizer, texts, batch_size, max_length, device)
    return {
        "mse": float(nn.functional.mse_loss(predictions, targets).item()),
        "sign_accuracy": sign_accuracy(predictions.tolist(), targets.tolist()),
    }


def _evaluate_transformer_ranking(
    model,
    tokenizer,
    pairs: Sequence[dict[str, Any]],
    batch_size: int,
    max_length: int,
    device: torch.device,
) -> dict[str, float]:
    better_texts: list[str] = []
    worse_texts: list[str] = []
    weights: list[float] = []
    for pair in pairs:
        better, worse = ranking_pair_texts(pair)
        better_texts.append(better)
        worse_texts.append(worse)
        weights.append(float(pair.get("weight", 1.0)))
    better_scores = _batched_transformer_scores(
        model, tokenizer, better_texts, batch_size, max_length, device
    )
    worse_scores = _batched_transformer_scores(
        model, tokenizer, worse_texts, batch_size, max_length, device
    )
    weight_tensor = torch.tensor(weights, dtype=torch.float32)
    return {
        "loss": float(pairwise_ranking_loss(better_scores, worse_scores, weight_tensor).item()),
        "accuracy": ranking_accuracy(better_scores, worse_scores),
    }


def _train_transformer(
    train_examples: Sequence[dict[str, Any]],
    validation_examples: Sequence[dict[str, Any]],
    train_pairs: Sequence[dict[str, Any]],
    validation_pairs: Sequence[dict[str, Any]],
    args: argparse.Namespace,
    output: Path,
) -> dict[str, Any]:
    try:
        from peft import LoraConfig, TaskType, get_peft_model
        from transformers import AutoModelForSequenceClassification, AutoTokenizer
    except ImportError as exc:
        raise RuntimeError(
            "pretrained experiment dependencies are missing; install ml/pretrained_value/requirements.txt"
        ) from exc

    _seed_everything(args.seed)
    device = torch.device(args.transformer_device)
    tokenizer = AutoTokenizer.from_pretrained(args.model_name, use_fast=True)
    if tokenizer.pad_token is None:
        if tokenizer.eos_token is None:
            raise ValueError("tokenizer has neither a pad token nor an eos token")
        tokenizer.pad_token = tokenizer.eos_token
    base = AutoModelForSequenceClassification.from_pretrained(
        args.model_name, num_labels=1, problem_type="regression"
    )
    base.config.pad_token_id = tokenizer.pad_token_id
    if hasattr(base.config, "use_cache"):
        base.config.use_cache = False
    modules_to_save = ["score"] if hasattr(base, "score") else None
    lora = LoraConfig(
        task_type=TaskType.SEQ_CLS,
        r=args.lora_rank,
        lora_alpha=args.lora_alpha,
        lora_dropout=args.lora_dropout,
        target_modules=[value.strip() for value in args.lora_target_modules.split(",") if value.strip()],
        modules_to_save=modules_to_save,
    )
    model = get_peft_model(base, lora).to(device)
    trainable_parameters = sum(parameter.numel() for parameter in model.parameters() if parameter.requires_grad)
    total_parameters = sum(parameter.numel() for parameter in model.parameters())
    optimizer = torch.optim.AdamW(
        [parameter for parameter in model.parameters() if parameter.requires_grad],
        lr=args.transformer_learning_rate,
        weight_decay=args.transformer_weight_decay,
    )

    value_texts = [serialize_value_example(example) for example in train_examples]
    value_targets = [float(example.get("outcome", 0.0)) for example in train_examples]
    pair_texts = [ranking_pair_texts(pair) for pair in train_pairs]
    pair_weights = [float(pair.get("weight", 1.0)) for pair in train_pairs]
    if not value_texts or not pair_texts:
        raise ValueError("transformer training requires value examples and ranking pairs")

    started = time.perf_counter()
    for epoch in range(args.transformer_epochs):
        model.train()
        value_indices = list(range(len(value_texts)))
        pair_indices = list(range(len(pair_texts)))
        random.Random(args.seed + epoch).shuffle(value_indices)
        random.Random(args.seed + 10_000 + epoch).shuffle(pair_indices)
        pair_cursor = 0
        for start in range(0, len(value_indices), args.transformer_batch_size):
            batch_indices = value_indices[start : start + args.transformer_batch_size]
            batch_texts = [value_texts[index] for index in batch_indices]
            targets = torch.tensor(
                [value_targets[index] for index in batch_indices], dtype=torch.float32, device=device
            )
            rank_indices: list[int] = []
            for _ in range(min(args.transformer_ranking_batch_size, len(pair_indices))):
                rank_indices.append(pair_indices[pair_cursor % len(pair_indices)])
                pair_cursor += 1
            better_texts = [pair_texts[index][0] for index in rank_indices]
            worse_texts = [pair_texts[index][1] for index in rank_indices]
            weights = torch.tensor(
                [pair_weights[index] for index in rank_indices], dtype=torch.float32, device=device
            )

            optimizer.zero_grad(set_to_none=True)
            prediction = _transformer_scores(model, tokenizer, batch_texts, args.max_length, device)
            value_loss = nn.functional.mse_loss(prediction, targets)
            better = _transformer_scores(model, tokenizer, better_texts, args.max_length, device)
            worse = _transformer_scores(model, tokenizer, worse_texts, args.max_length, device)
            rank_loss = pairwise_ranking_loss(better, worse, weights)
            (value_loss + args.ranking_weight * rank_loss).backward()
            if args.transformer_max_grad_norm > 0:
                torch.nn.utils.clip_grad_norm_(
                    [parameter for parameter in model.parameters() if parameter.requires_grad],
                    args.transformer_max_grad_norm,
                )
            optimizer.step()
    train_seconds = time.perf_counter() - started

    output.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(output)
    tokenizer.save_pretrained(output)
    (output / "experiment_config.json").write_text(
        json.dumps(
            {
                "base_model_name": args.model_name,
                "max_length": args.max_length,
                "training_fraction": args.training_fraction,
                "validation_groups": sorted(args.validation_groups),
                "ranking_weight": args.ranking_weight,
                "seed": args.seed,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    return {
        "base_model_name": args.model_name,
        "total_parameter_count": total_parameters,
        "trainable_parameter_count": trainable_parameters,
        "trainable_parameter_fraction": trainable_parameters / total_parameters,
        "train_seconds": train_seconds,
        "validation_value": _evaluate_transformer_values(
            model, tokenizer, validation_examples, args.transformer_eval_batch_size, args.max_length, device
        ),
        "validation_ranking": _evaluate_transformer_ranking(
            model, tokenizer, validation_pairs, args.transformer_eval_batch_size, args.max_length, device
        ),
        "checkpoint": str(output),
    }


def run_experiment(args: argparse.Namespace) -> dict[str, Any]:
    examples = load_jsonl_examples(args.data)
    pairs = load_ranking_pairs(args.ranking_data)
    validation_groups = {value.strip() for value in args.validation_groups_csv.split(",") if value.strip()}
    if not validation_groups:
        raise ValueError("at least one frozen validation group is required")
    args.validation_groups = validation_groups
    train_examples, validation_examples, train_pairs, validation_pairs = _split_by_validation_groups(
        examples, pairs, args.split_key, validation_groups
    )
    fraction_examples = nested_group_subsample(
        train_examples, args.training_fraction, group_key="game_id", seed=args.seed
    )
    fraction_pairs = nested_group_subsample(
        train_pairs, args.training_fraction, group_key="game_id", seed=args.seed
    )

    cnn_output = Path(args.output_dir) / "cnn_value_model.pt"
    transformer_output = Path(args.output_dir) / "pretrained_adapter"
    result: dict[str, Any] = {
        "experiment_version": 1,
        "training_fraction": args.training_fraction,
        "split_key": args.split_key,
        "validation_groups": sorted(validation_groups),
        "full_training_examples": len(train_examples),
        "full_training_ranking_pairs": len(train_pairs),
        "training_examples": len(fraction_examples),
        "training_ranking_pairs": len(fraction_pairs),
        "validation_examples": len(validation_examples),
        "validation_ranking_pairs": len(validation_pairs),
        "cnn": _train_cnn(
            fraction_examples, validation_examples, fraction_pairs, validation_pairs, args, cnn_output
        ),
    }
    result["pretrained"] = _train_transformer(
        fraction_examples, validation_examples, fraction_pairs, validation_pairs, args, transformer_output
    )
    output = Path(args.output_dir) / "metrics.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compare scratch HexValueNet against a LoRA-tuned pretrained transformer on one frozen split."
    )
    parser.add_argument("--data", required=True)
    parser.add_argument("--ranking-data", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--training-fraction", type=float, required=True)
    parser.add_argument("--split-key", default="source.base_scenario_id")
    parser.add_argument(
        "--validation-groups",
        dest="validation_groups_csv",
        default="baneling_finish,mixed_force,scout_kite",
        help="Comma-separated frozen held-out scenario families used for every fraction.",
    )
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--ranking-weight", type=float, default=0.5)

    parser.add_argument("--cnn-device", default="cpu")
    parser.add_argument("--cnn-epochs", type=int, default=60)
    parser.add_argument("--cnn-batch-size", type=int, default=64)
    parser.add_argument("--cnn-ranking-batch-size", type=int, default=32)
    parser.add_argument("--cnn-hidden-channels", type=int, default=32)
    parser.add_argument("--cnn-residual-blocks", type=int, default=2)
    parser.add_argument("--cnn-learning-rate", type=float, default=3e-4)
    parser.add_argument("--cnn-weight-decay", type=float, default=1e-4)

    parser.add_argument("--model-name", default="Qwen/Qwen3-0.6B")
    parser.add_argument("--transformer-device", default="cpu")
    parser.add_argument("--transformer-epochs", type=int, default=3)
    parser.add_argument("--transformer-batch-size", type=int, default=4)
    parser.add_argument("--transformer-ranking-batch-size", type=int, default=4)
    parser.add_argument("--transformer-eval-batch-size", type=int, default=8)
    parser.add_argument("--transformer-learning-rate", type=float, default=2e-4)
    parser.add_argument("--transformer-weight-decay", type=float, default=1e-4)
    parser.add_argument("--transformer-max-grad-norm", type=float, default=1.0)
    parser.add_argument("--max-length", type=int, default=384)
    parser.add_argument("--lora-rank", type=int, default=8)
    parser.add_argument("--lora-alpha", type=int, default=16)
    parser.add_argument("--lora-dropout", type=float, default=0.05)
    parser.add_argument("--lora-target-modules", default="q_proj,v_proj")
    return parser


def main() -> None:
    run_experiment(build_parser().parse_args())


if __name__ == "__main__":
    main()
