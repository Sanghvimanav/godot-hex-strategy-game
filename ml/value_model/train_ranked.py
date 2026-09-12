from __future__ import annotations

import argparse
import json
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
from .metrics import sign_accuracy
from .model import HexValueNet
from .strategic_state import make_encoder
from .ranking import (
    RankingPairDataset,
    load_ranking_pairs,
    pairwise_ranking_loss,
    ranking_accuracy,
    ranking_kind_counts,
    split_ranking_pairs_by_group_values,
)
from .train import (
    _evaluate,
    _input_conflict_metrics,
    _load_handwritten_baseline,
    _seed_everything,
    _split_groups,
    _synthetic_test_baseline,
)


def _evaluate_ranking(
    model: HexValueNet,
    dataset: RankingPairDataset,
    batch_size: int,
    device: torch.device,
) -> dict[str, float]:
    if len(dataset) == 0:
        return {"loss": float("nan"), "accuracy": float("nan")}
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False)
    losses: list[float] = []
    better_predictions: list[torch.Tensor] = []
    worse_predictions: list[torch.Tensor] = []
    model.eval()
    with torch.no_grad():
        for better_board, better_globals, worse_board, worse_globals, weights in loader:
            better = model.policy_score(
                better_board.to(device), better_globals.to(device)
            )
            worse = model.policy_score(
                worse_board.to(device), worse_globals.to(device)
            )
            loss = pairwise_ranking_loss(better, worse, weights.to(device))
            losses.append(float(loss.item()))
            better_predictions.append(better.cpu())
            worse_predictions.append(worse.cpu())
    better_all = torch.cat(better_predictions)
    worse_all = torch.cat(worse_predictions)
    return {
        "loss": sum(losses) / len(losses),
        "accuracy": ranking_accuracy(better_all, worse_all),
    }


def _next_ranking_batch(loader: DataLoader, iterator):
    try:
        return next(iterator), iterator
    except StopIteration:
        iterator = iter(loader)
        return next(iterator), iterator


def _tactical_focus_groups(pairs: list[dict]) -> set[str]:
    groups: set[str] = set()
    for pair in pairs:
        source = pair.get("source", {})
        if not isinstance(source, dict):
            continue
        metadata = source.get("tactical_focus_reweight", {})
        if not isinstance(metadata, dict):
            continue
        configured = metadata.get("configured_focus_families", [])
        if isinstance(configured, list):
            groups.update(str(value) for value in configured if str(value))
    return groups


def _split_examples_for_training(
    examples: list[dict],
    args: argparse.Namespace,
    tactical_focus_groups: set[str],
) -> tuple[int, list[dict], list[dict]]:
    explicit_split_seed = getattr(args, "split_seed", None)
    if explicit_split_seed is not None:
        split_seed = int(explicit_split_seed)
        train_examples, validation_examples = split_examples_by_group(
            examples,
            validation_fraction=args.validation_fraction,
            seed=split_seed,
            group_key=args.split_key,
        )
        return split_seed, train_examples, validation_examples

    start_seed = int(args.seed)
    candidate_seeds = [start_seed]
    if tactical_focus_groups and args.split_key == "source.base_scenario_id":
        candidate_seeds = list(range(start_seed, start_seed + 1000))

    for split_seed in candidate_seeds:
        train_examples, validation_examples = split_examples_by_group(
            examples,
            validation_fraction=args.validation_fraction,
            seed=split_seed,
            group_key=args.split_key,
        )
        validation_groups = {
            example_group_value(example, args.split_key)
            for example in validation_examples
        }
        if tactical_focus_groups.isdisjoint(validation_groups):
            return split_seed, train_examples, validation_examples

    raise ValueError(
        "unable to find a train/validation split that keeps tactical focus groups "
        "out of validation"
    )


def _base_model_state_dict(model: HexValueNet) -> dict[str, torch.Tensor]:
    return {
        key: value
        for key, value in model.state_dict().items()
        if not key.startswith("policy_head.")
    }


def train(args: argparse.Namespace) -> dict:
    _seed_everything(args.seed)
    all_examples = load_jsonl_examples(args.data)
    if not all_examples:
        raise ValueError("dataset is empty")
    all_pairs = load_ranking_pairs(args.ranking_data)
    if not all_pairs:
        raise ValueError("ranking dataset is empty")

    tactical_focus_groups = _tactical_focus_groups(all_pairs)
    split_seed, train_examples, validation_examples = _split_examples_for_training(
        all_examples,
        args,
        tactical_focus_groups,
    )
    validation_group_values = {
        example_group_value(example, args.split_key) for example in validation_examples
    }
    if args.split_key == "game_id":
        validation_group_values.update(getattr(args, "parent_validation_game_ids", []))
    train_pairs, validation_pairs = split_ranking_pairs_by_group_values(
        all_pairs,
        args.split_key,
        validation_group_values,
    )
    if not train_pairs:
        raise ValueError("no ranking pairs remain in the training split")

    encoder = make_encoder(getattr(args, "encoder_version", 1))
    all_conflicts = _input_conflict_metrics(all_examples, encoder)
    train_conflicts = _input_conflict_metrics(train_examples, encoder)
    validation_conflicts = _input_conflict_metrics(validation_examples, encoder)

    train_dataset = ValueExampleDataset(train_examples, encoder)
    validation_dataset = ValueExampleDataset(validation_examples, encoder)
    train_ranking_dataset = RankingPairDataset(train_pairs, encoder)
    validation_ranking_dataset = RankingPairDataset(validation_pairs, encoder)
    train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True)
    ranking_loader = DataLoader(
        train_ranking_dataset,
        batch_size=min(args.ranking_batch_size, len(train_ranking_dataset)),
        shuffle=True,
    )

    device = torch.device(args.device)
    model = HexValueNet(
        board_channels=encoder.board_channels,
        global_features=encoder.global_features,
        hidden_channels=args.hidden_channels,
        residual_blocks=args.residual_blocks,
        policy_head=True,
    ).to(device)
    optimizer = torch.optim.AdamW(
        model.parameters(), lr=args.learning_rate, weight_decay=args.weight_decay
    )
    value_loss_fn = nn.MSELoss()

    for _ in range(args.epochs):
        model.train()
        ranking_iterator = iter(ranking_loader)
        for board, globals_, target in train_loader:
            ranking_batch, ranking_iterator = _next_ranking_batch(
                ranking_loader, ranking_iterator
            )
            (
                better_board,
                better_globals,
                worse_board,
                worse_globals,
                ranking_weights,
            ) = ranking_batch

            optimizer.zero_grad(set_to_none=True)
            prediction = model(board.to(device), globals_.to(device))
            value_loss = value_loss_fn(prediction, target.to(device))
            better_prediction = model.policy_score(
                better_board.to(device), better_globals.to(device)
            )
            worse_prediction = model.policy_score(
                worse_board.to(device), worse_globals.to(device)
            )
            rank_loss = pairwise_ranking_loss(
                better_prediction,
                worse_prediction,
                ranking_weights.to(device),
            )
            loss = value_loss + args.ranking_weight * rank_loss
            loss.backward()
            optimizer.step()

    train_metrics = _evaluate(model, train_dataset, args.batch_size, device)
    eval_examples = validation_examples if validation_examples else train_examples
    eval_dataset = validation_dataset if validation_examples else train_dataset
    eval_metrics = _evaluate(model, eval_dataset, args.batch_size, device)

    ranking_eval_pairs = validation_pairs if validation_pairs else train_pairs
    ranking_eval_dataset = (
        validation_ranking_dataset if validation_pairs else train_ranking_dataset
    )
    train_ranking_metrics = _evaluate_ranking(
        model, train_ranking_dataset, args.ranking_batch_size, device
    )
    eval_ranking_metrics = _evaluate_ranking(
        model, ranking_eval_dataset, args.ranking_batch_size, device
    )

    nonterminal_eval = [
        example for example in eval_examples if not bool(example.get("terminal", False))
    ]
    nonterminal_dataset = ValueExampleDataset(nonterminal_eval, encoder)
    neural_nonterminal_metrics = _evaluate(
        model, nonterminal_dataset, args.batch_size, device
    )
    baseline = _load_handwritten_baseline(
        getattr(args, "handwritten_baseline", None), len(nonterminal_eval)
    )
    if baseline is None:
        baseline = _synthetic_test_baseline(nonterminal_eval)

    training_config = vars(args).copy()
    training_config["effective_split_seed"] = split_seed
    training_config["tactical_focus_train_groups"] = sorted(tactical_focus_groups)
    training_config["validation_game_ids"] = sorted({str(e["game_id"]) for e in validation_examples}
                                                    | {str(p["game_id"]) for p in validation_pairs})
    training_config["training_game_ids"] = sorted({str(e["game_id"]) for e in train_examples}
                                                  | {str(p["game_id"]) for p in train_pairs})
    assert model.policy_head is not None
    checkpoint = {
        # Keep the legacy value-model state dict loadable by frozen/offline evaluators.
        "model_state_dict": _base_model_state_dict(model),
        # Runtime search can opt into this separate action-ranking head.
        "policy_head_state_dict": model.policy_head.state_dict(),
        "model_config": {
            "encoder_version": getattr(args, "encoder_version", 1),
            "hidden_channels": args.hidden_channels,
            "residual_blocks": args.residual_blocks,
            "board_channels": encoder.board_channels,
            "global_features": encoder.global_features,
            "board_size": encoder.board_size,
            "max_radius": encoder.max_radius,
            "unit_types": list(encoder.unit_types),
            "policy_head": True,
            "search_head": "policy",
        },
        "training_config": training_config,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(checkpoint, output)

    result: dict = {
        "examples": len(all_examples),
        "train_examples": len(train_examples),
        "validation_examples": len(validation_examples),
        "ranking_pairs": len(all_pairs),
        "train_ranking_pairs": len(train_pairs),
        "validation_ranking_pairs": len(validation_pairs),
        "ranking_comparison_population": (
            "held_out" if validation_pairs else "training_fallback"
        ),
        "ranking_head": "policy",
        "ranking_weight": args.ranking_weight,
        "ranking_pair_kind_counts": ranking_kind_counts(all_pairs),
        "train_policy_ranking_accuracy": train_ranking_metrics["accuracy"],
        "train_policy_ranking_loss": train_ranking_metrics["loss"],
        "eval_policy_ranking_accuracy": eval_ranking_metrics["accuracy"],
        "eval_policy_ranking_loss": eval_ranking_metrics["loss"],
        # Backward-compatible aliases for existing workflow summaries.
        "train_ranking_accuracy": train_ranking_metrics["accuracy"],
        "train_ranking_loss": train_ranking_metrics["loss"],
        "eval_ranking_accuracy": eval_ranking_metrics["accuracy"],
        "eval_ranking_loss": eval_ranking_metrics["loss"],
        "split_key": args.split_key,
        "split_seed": split_seed,
        "tactical_focus_train_groups": sorted(tactical_focus_groups),
        "train_split_groups": _split_groups(train_examples, args.split_key),
        "validation_split_groups": _split_groups(validation_examples, args.split_key),
        "ranking_eval_groups": sorted(
            {
                str(pair.get("source", {}).get("base_scenario_id", ""))
                for pair in ranking_eval_pairs
                if isinstance(pair.get("source"), dict)
            }
        ),
        "all_duplicate_input_groups": all_conflicts["duplicate_input_groups"],
        "all_duplicate_input_examples": all_conflicts["duplicate_input_examples"],
        "all_conflicting_input_groups": all_conflicts["conflicting_input_groups"],
        "all_conflicting_input_examples": all_conflicts["conflicting_input_examples"],
        "train_duplicate_input_groups": train_conflicts["duplicate_input_groups"],
        "train_duplicate_input_examples": train_conflicts["duplicate_input_examples"],
        "train_conflicting_input_groups": train_conflicts["conflicting_input_groups"],
        "train_conflicting_input_examples": train_conflicts["conflicting_input_examples"],
        "validation_conflicting_input_groups": validation_conflicts[
            "conflicting_input_groups"
        ],
        "validation_conflicting_input_examples": validation_conflicts[
            "conflicting_input_examples"
        ],
        "train_mse": train_metrics["mse"],
        "train_sign_accuracy": train_metrics["sign_accuracy"],
        "eval_mse": eval_metrics["mse"],
        "eval_sign_accuracy": eval_metrics["sign_accuracy"],
        "eval_nonterminal_examples": len(nonterminal_eval),
        "neural_eval_mse_nonterminal": neural_nonterminal_metrics["mse"],
        "neural_eval_sign_accuracy_nonterminal": neural_nonterminal_metrics[
            "sign_accuracy"
        ],
        "metric_comparison_population": "held_out_nonterminal",
        "checkpoint": str(output),
    }
    if baseline is not None:
        targets = [float(example.get("outcome", 0.0)) for example in nonterminal_eval]
        baseline_accuracy = sign_accuracy(baseline["scores"], targets)
        delta = neural_nonterminal_metrics["sign_accuracy"] - baseline_accuracy
        result["handwritten_eval_sign_accuracy_nonterminal"] = baseline_accuracy
        result["neural_minus_handwritten_sign_accuracy_nonterminal"] = delta
        result["neural_minus_handwritten_sign_accuracy"] = delta
        result["handwritten_evaluator_fingerprint"] = baseline[
            "evaluator_fingerprint"
        ]
    else:
        result[
            "handwritten_comparison_status"
        ] = "not_reported_without_godot_baseline"

    print(json.dumps(result, indent=2, sort_keys=True))
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Train a shared neural encoder with separate value and search-ranking heads."
        )
    )
    parser.add_argument("--data", required=True)
    parser.add_argument("--ranking-data", required=True)
    parser.add_argument("--output", default="artifacts/value_model.pt")
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--encoder-version", type=int, choices=(1, 2), default=1)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--ranking-batch-size", type=int, default=32)
    parser.add_argument("--ranking-weight", type=float, default=0.5)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--validation-fraction", type=float, default=0.2)
    parser.add_argument("--split-key", default="game_id")
    parser.add_argument(
        "--split-seed",
        type=int,
        default=None,
        help=(
            "Optional seed for train/validation grouping. When omitted, tactical "
            "focus metadata may select a different split seed while --seed still "
            "controls model initialization and minibatch randomness."
        ),
    )
    parser.add_argument("--hidden-channels", type=int, default=32)
    parser.add_argument("--residual-blocks", type=int, default=2)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--handwritten-baseline", default=None)
    return parser


def main() -> None:
    train(build_parser().parse_args())


if __name__ == "__main__":
    main()
