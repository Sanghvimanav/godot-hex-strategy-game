from __future__ import annotations

import argparse
import copy
import json
import random
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F

from .train_joint_plan_policy import _score_example
from .train_outcome_actor_critic import _load_policy_head, _load_value_model, _row_example
from .strategic_state import make_encoder


EVALUATION_ONLY_BENCHMARKS = {"human_playtest_v1"}


def discover_demo_files(inputs: list[Path]) -> list[Path]:
    files: list[Path] = []
    for path in inputs:
        if path.is_dir():
            files.extend(sorted(path.rglob("human_policy_steps.jsonl")))
        elif path.is_file():
            files.append(path)
        else:
            raise FileNotFoundError(path)
    unique: list[Path] = []
    seen: set[Path] = set()
    for path in files:
        resolved = path.resolve()
        if resolved not in seen:
            seen.add(resolved)
            unique.append(path)
    if not unique:
        raise ValueError("no human_policy_steps.jsonl files found")
    return unique


def _evaluation_only(row: dict[str, Any]) -> bool:
    source = row.get("source", {})
    if not isinstance(source, dict):
        source = {}
    benchmark_id = str(row.get("benchmark_id", source.get("benchmark_id", "")))
    split = str(row.get("split", source.get("split", "")))
    training_allowed = row.get("training_allowed", source.get("training_allowed", None))
    return (
        benchmark_id in EVALUATION_ONLY_BENCHMARKS
        or split == "evaluation_holdout"
        or training_allowed is False
    )


def load_demo_rows(paths: list[Path]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    rejected_evaluation_only = 0
    for path in paths:
        for raw in path.read_text().splitlines():
            if not raw.strip():
                continue
            row = json.loads(raw)
            if not isinstance(row, dict):
                continue
            if _evaluation_only(row):
                rejected_evaluation_only += 1
                continue
            candidates = row.get("candidate_actions")
            selected = int(row.get("selected_index", -1))
            if (
                row.get("example_type") == "human_policy_step"
                and isinstance(candidates, list)
                and len(candidates) >= 2
                and 0 <= selected < len(candidates)
            ):
                rows.append(row)
    if rejected_evaluation_only:
        print(
            json.dumps(
                {
                    "warning": "evaluation-only human rows were excluded from training",
                    "rejected_rows": rejected_evaluation_only,
                }
            )
        )
    if not rows:
        raise ValueError("no usable human policy steps")
    return rows


def split_rows(
    rows: list[dict[str, Any]], validation_fraction: float, seed: int
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not 0.0 <= validation_fraction < 1.0:
        raise ValueError("validation_fraction must be in [0, 1)")
    game_ids = sorted({str(row.get("game_id", "")) for row in rows if row.get("game_id")})
    if validation_fraction == 0.0 or len(game_ids) < 2:
        return list(rows), []
    shuffled = list(game_ids)
    random.Random(seed).shuffle(shuffled)
    heldout_count = min(
        len(shuffled) - 1,
        max(1, round(len(shuffled) * validation_fraction)),
    )
    heldout = set(shuffled[:heldout_count])
    train_rows = [row for row in rows if str(row.get("game_id", "")) not in heldout]
    eval_rows = [row for row in rows if str(row.get("game_id", "")) in heldout]
    return train_rows, eval_rows


def _metrics(
    rows,
    head,
    value_model,
    encoder,
    action_featurizer,
    entity_featurizer,
    device,
) -> dict[str, float | int]:
    if not rows:
        return {
            "rows": 0,
            "top1_accuracy": 0.0,
            "mean_selected_probability": 0.0,
            "mean_cross_entropy": 0.0,
        }
    correct = 0
    selected_probabilities: list[float] = []
    losses: list[float] = []
    head.eval()
    value_model.eval()
    with torch.no_grad():
        for row in rows:
            example = _row_example(row)
            logits = _score_example(
                head,
                value_model,
                encoder,
                action_featurizer,
                entity_featurizer,
                example,
                device,
            )
            log_probs = F.log_softmax(logits, dim=0)
            selected = int(row["selected_index"])
            correct += int(int(logits.argmax().item()) == selected)
            selected_probabilities.append(float(log_probs[selected].exp().item()))
            losses.append(float(-log_probs[selected].item()))
    return {
        "rows": len(rows),
        "top1_accuracy": correct / len(rows),
        "mean_selected_probability": sum(selected_probabilities) / len(selected_probabilities),
        "mean_cross_entropy": sum(losses) / len(losses),
    }


def train(args: argparse.Namespace) -> dict[str, Any]:
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device(args.device)

    files = discover_demo_files(args.human_policy_steps)
    rows = load_demo_rows(files)
    if args.max_rows > 0:
        rows = rows[: args.max_rows]
    train_rows, eval_rows = split_rows(rows, args.validation_fraction, args.seed)
    if not train_rows:
        raise ValueError("no human policy steps selected for training")

    checkpoint = torch.load(args.base_checkpoint, map_location=device, weights_only=False)
    encoder = make_encoder(int(checkpoint["model_config"].get("encoder_version", 1)))
    value_model = _load_value_model(checkpoint, device)
    for parameter in value_model.parameters():
        parameter.requires_grad_(False)
    value_model.eval()

    policy_head, policy_config, action_featurizer, entity_featurizer = _load_policy_head(
        checkpoint, device, rows
    )

    before_train = _metrics(
        train_rows,
        policy_head,
        value_model,
        encoder,
        action_featurizer,
        entity_featurizer,
        device,
    )
    before_eval = _metrics(
        eval_rows,
        policy_head,
        value_model,
        encoder,
        action_featurizer,
        entity_featurizer,
        device,
    )

    optimizer = torch.optim.AdamW(
        policy_head.parameters(),
        lr=args.learning_rate,
        weight_decay=args.weight_decay,
    )
    order = list(range(len(train_rows)))
    epoch_losses: list[float] = []
    for _epoch in range(args.epochs):
        random.shuffle(order)
        policy_head.train()
        optimizer.zero_grad(set_to_none=True)
        pending = 0
        losses: list[float] = []
        for index in order:
            row = train_rows[index]
            example = _row_example(row)
            logits = _score_example(
                policy_head,
                value_model,
                encoder,
                action_featurizer,
                entity_featurizer,
                example,
                device,
            )
            selected = int(row["selected_index"])
            loss = -F.log_softmax(logits, dim=0)[selected]
            (loss / float(args.accumulate_groups)).backward()
            losses.append(float(loss.detach().item()))
            pending += 1
            if pending == args.accumulate_groups:
                torch.nn.utils.clip_grad_norm_(policy_head.parameters(), args.max_grad_norm)
                optimizer.step()
                optimizer.zero_grad(set_to_none=True)
                pending = 0
        if pending:
            torch.nn.utils.clip_grad_norm_(policy_head.parameters(), args.max_grad_norm)
            optimizer.step()
            optimizer.zero_grad(set_to_none=True)
        epoch_losses.append(sum(losses) / len(losses))

    after_train = _metrics(
        train_rows,
        policy_head,
        value_model,
        encoder,
        action_featurizer,
        entity_featurizer,
        device,
    )
    after_eval = _metrics(
        eval_rows,
        policy_head,
        value_model,
        encoder,
        action_featurizer,
        entity_featurizer,
        device,
    )

    train_game_ids = sorted({str(row.get("game_id", "")) for row in train_rows})
    eval_game_ids = sorted({str(row.get("game_id", "")) for row in eval_rows})
    metrics: dict[str, Any] = {
        "supervision": "human_behavior_cloning",
        "human_policy_steps": len(rows),
        "train_steps": len(train_rows),
        "eval_steps": len(eval_rows),
        "train_game_ids": train_game_ids,
        "eval_game_ids": eval_game_ids,
        "epochs": args.epochs,
        "learning_rate": args.learning_rate,
        "weight_decay": args.weight_decay,
        "before_train": before_train,
        "after_train": after_train,
        "before_eval": before_eval,
        "after_eval": after_eval,
        "epoch_mean_cross_entropy": epoch_losses,
        "backbone_frozen": True,
        "value_head_updated": False,
        "evaluation_only_benchmarks_excluded": sorted(EVALUATION_ONLY_BENCHMARKS),
        "vocab_expansion": policy_config.get("vocab_expansion", {}),
        "input_files": [str(path) for path in files],
    }

    output = copy.deepcopy(checkpoint)
    output["joint_plan_policy_state_dict"] = policy_head.state_dict()
    updated_config = dict(policy_config)
    updated_config["human_behavior_cloning_warmstart"] = True
    updated_config["explicit_action_mechanics"] = False
    output["joint_plan_policy_config"] = updated_config

    history = list(output.get("human_policy_warmstart_history", []))
    history.append(metrics)
    output["human_policy_warmstart_history"] = history
    output["human_policy_warmstart_config"] = {
        "epochs": args.epochs,
        "learning_rate": args.learning_rate,
        "weight_decay": args.weight_decay,
        "validation_fraction": args.validation_fraction,
        "seed": args.seed,
        "backbone_frozen": True,
        "value_head_updated": False,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(output, args.output)
    print(json.dumps(metrics, indent=2, sort_keys=True))
    return metrics


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Warm-start the direct spatial policy from human Arena demonstrations"
    )
    parser.add_argument("--base-checkpoint", type=Path, required=True)
    parser.add_argument(
        "--human-policy-steps",
        type=Path,
        action="append",
        required=True,
        help="A human_policy_steps.jsonl file or a directory containing Arena sessions",
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=5)
    parser.add_argument("--validation-fraction", type=float, default=0.2)
    parser.add_argument("--learning-rate", type=float, default=1e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--accumulate-groups", type=int, default=16)
    parser.add_argument("--max-grad-norm", type=float, default=1.0)
    parser.add_argument("--max-rows", type=int, default=0)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="cpu")
    return parser


def main() -> None:
    train(build_parser().parse_args())


if __name__ == "__main__":
    main()
