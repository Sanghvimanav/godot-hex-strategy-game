from __future__ import annotations

import argparse
import copy
import json
import random
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F

from .joint_plan_policy import PolicyExample
from .strategic_state import make_encoder
from .train_joint_plan_policy import _score_example
from .train_outcome_actor_critic import _load_policy_head, _load_value_model


def _load_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for raw in path.read_text().splitlines():
        if not raw.strip():
            continue
        row = json.loads(raw)
        if not isinstance(row, dict):
            continue
        candidates = row.get("candidate_actions", [])
        targets = row.get("target_indices", [])
        if not isinstance(candidates, list) or len(candidates) < 2:
            continue
        if not isinstance(targets, list) or not targets:
            continue
        target_indices = sorted({int(i) for i in targets})
        if any(i < 0 or i >= len(candidates) for i in target_indices):
            raise ValueError("target index outside candidate range")
        row["target_indices"] = target_indices
        rows.append(row)
    if not rows:
        raise ValueError(f"no usable rows in {path}")
    return rows


def _example(row: dict[str, Any]) -> PolicyExample:
    candidates = tuple(dict(a) for a in row["candidate_actions"])
    targets = set(int(i) for i in row["target_indices"])
    mass = 1.0 / float(len(targets))
    probs = tuple(mass if i in targets else 0.0 for i in range(len(candidates)))
    return PolicyExample(
        state=dict(row["state"]),
        perspective_group=str(row["perspective_group"]),
        opponent_group=str(row["opponent_group"]),
        prefix_actions=tuple(dict(a) for a in row.get("prefix_actions", [])),
        candidate_actions=candidates,
        continuation_scores=probs,
        target_probabilities=probs,
    )


def _row_metrics(
    rows: list[dict[str, Any]],
    head,
    value_model,
    encoder,
    action_featurizer,
    entity_featurizer,
    device: torch.device,
) -> dict[str, Any]:
    head.eval()
    value_model.eval()
    correct = 0
    opening_correct = 0
    opening_total = 0
    continuation_correct = 0
    continuation_total = 0
    target_probs: list[float] = []
    margins: list[float] = []
    decisions: dict[str, dict[str, Any]] = {}

    with torch.no_grad():
        for row in rows:
            example = _example(row)
            logits = _score_example(
                head,
                value_model,
                encoder,
                action_featurizer,
                entity_featurizer,
                example,
                device,
            )
            probs = F.softmax(logits, dim=0)
            targets = set(int(i) for i in row["target_indices"])
            top = int(logits.argmax().item())
            is_correct = top in targets
            correct += int(is_correct)
            role = str(row.get("decision_role", ""))
            if role == "opening":
                opening_total += 1
                opening_correct += int(is_correct)
            else:
                continuation_total += 1
                continuation_correct += int(is_correct)

            target_prob = sum(float(probs[i].item()) for i in targets)
            target_probs.append(target_prob)
            target_best = max(float(logits[i].item()) for i in targets)
            nontarget = [i for i in range(len(row["candidate_actions"])) if i not in targets]
            nontarget_best = max(float(logits[i].item()) for i in nontarget)
            margins.append(target_best - nontarget_best)
            decisions[str(row["decision_id"])] = {
                "correct": is_correct,
                "top_action": row["candidate_actions"][top],
                "target_probability": target_prob,
                "target_margin": target_best - nontarget_best,
                "role": role,
                "initial_layout_id": row["initial_layout_id"],
                "marine_response": row.get("marine_response"),
            }

    layouts: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        layouts.setdefault(str(row["initial_layout_id"]), []).append(row)

    robust_success = 0
    per_layout: dict[str, Any] = {}
    for layout_id, layout_rows in sorted(layouts.items()):
        results = [decisions[str(row["decision_id"])] for row in layout_rows]
        opening = [r for r in results if r["role"] == "opening"]
        continuations = [r for r in results if r["role"] == "continuation"]
        ok = len(opening) == 1 and opening[0]["correct"] and continuations and all(r["correct"] for r in continuations)
        robust_success += int(ok)
        per_layout[layout_id] = {
            "robust_two_turn_win": ok,
            "opening_correct": bool(opening and opening[0]["correct"]),
            "continuation_correct": sum(int(r["correct"]) for r in continuations),
            "continuation_total": len(continuations),
        }

    def mean(values: list[float]) -> float:
        return sum(values) / len(values) if values else 0.0

    return {
        "decision_rows": len(rows),
        "initial_layouts": len(layouts),
        "top1_target_accuracy": correct / len(rows),
        "opening_top1_accuracy": opening_correct / opening_total if opening_total else 0.0,
        "continuation_top1_accuracy": continuation_correct / continuation_total if continuation_total else 0.0,
        "robust_two_turn_win_rate": robust_success / len(layouts) if layouts else 0.0,
        "robust_two_turn_wins": robust_success,
        "mean_target_probability": mean(target_probs),
        "mean_target_logit_margin": mean(margins),
        "per_layout": per_layout,
        "decisions": decisions,
    }


def train(args: argparse.Namespace) -> dict[str, Any]:
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device(args.device)

    train_rows = _load_rows(args.train_rows)
    eval_rows = _load_rows(args.eval_rows)
    train_layouts = {str(row["initial_layout_id"]) for row in train_rows}
    eval_layouts = {str(row["initial_layout_id"]) for row in eval_rows}
    if train_layouts & eval_layouts:
        raise ValueError("train/eval initial layout overlap")
    if len(train_layouts) != 18 or len(eval_layouts) != 6:
        raise ValueError(f"expected 18/6 initial layout split, got {len(train_layouts)}/{len(eval_layouts)}")

    checkpoint = torch.load(args.base_checkpoint, map_location=device, weights_only=False)
    encoder = make_encoder(int(checkpoint["model_config"].get("encoder_version", 1)))
    value_model = _load_value_model(checkpoint, device)
    for parameter in value_model.parameters():
        parameter.requires_grad_(False)
    value_model.eval()

    policy_head, policy_config, action_featurizer, entity_featurizer = _load_policy_head(
        checkpoint, device, train_rows + eval_rows
    )

    before_train = _row_metrics(
        train_rows, policy_head, value_model, encoder, action_featurizer, entity_featurizer, device
    )
    before_eval = _row_metrics(
        eval_rows, policy_head, value_model, encoder, action_featurizer, entity_featurizer, device
    )

    optimizer = torch.optim.AdamW(
        policy_head.parameters(),
        lr=args.learning_rate,
        weight_decay=args.weight_decay,
    )
    order = [i % len(train_rows) for i in range(args.training_examples)]
    random.shuffle(order)
    policy_head.train()
    optimizer.zero_grad(set_to_none=True)
    pending = 0
    losses: list[float] = []

    for index in order:
        row = train_rows[index]
        example = _example(row)
        logits = _score_example(
            policy_head,
            value_model,
            encoder,
            action_featurizer,
            entity_featurizer,
            example,
            device,
        )
        target = torch.tensor(
            example.target_distribution,
            dtype=logits.dtype,
            device=logits.device,
        )
        loss_raw = -(target * F.log_softmax(logits, dim=0)).sum()
        (loss_raw / float(args.accumulate_groups)).backward()
        losses.append(float(loss_raw.detach().item()))
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

    after_train = _row_metrics(
        train_rows, policy_head, value_model, encoder, action_featurizer, entity_featurizer, device
    )
    after_eval = _row_metrics(
        eval_rows, policy_head, value_model, encoder, action_featurizer, entity_featurizer, device
    )

    metrics = {
        "experiment": "two_hp_two_turn_zergling_probe",
        "training_passes": 1,
        "epochs": 0,
        "source_train_decision_rows": len(train_rows),
        "source_eval_decision_rows": len(eval_rows),
        "training_examples": len(order),
        "train_initial_layouts": len(train_layouts),
        "heldout_initial_layouts": len(eval_layouts),
        "learning_rate": args.learning_rate,
        "weight_decay": args.weight_decay,
        "mean_supervised_loss": sum(losses) / len(losses),
        "shared_spatial_encoder_frozen": True,
        "base_policy_loaded": True,
        "explicit_action_mechanics_features": False,
        "marine_allowed_actions": ["<hold>", "move_short"],
        "supervision": "robust_two_turn_counterfactual_targets",
        "vocab_expansion": policy_config.get("vocab_expansion", {}),
        "before_train": before_train,
        "before_eval": before_eval,
        "after_train": after_train,
        "after_eval": after_eval,
    }

    output = copy.deepcopy(checkpoint)
    output["joint_plan_policy_state_dict"] = policy_head.state_dict()
    updated_config = dict(policy_config)
    updated_config["target"] = "counterfactual_two_turn_robust_win_probe"
    output["joint_plan_policy_config"] = updated_config
    output["two_turn_counterfactual_probe_metrics"] = metrics

    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(output, args.output)
    args.metrics.parent.mkdir(parents=True, exist_ok=True)
    args.metrics.write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n")
    print(json.dumps(metrics, indent=2, sort_keys=True))
    return metrics


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="One-pass supervised capacity probe for a two-turn Zergling kill"
    )
    parser.add_argument("--base-checkpoint", type=Path, required=True)
    parser.add_argument("--train-rows", type=Path, required=True)
    parser.add_argument("--eval-rows", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metrics", type=Path, required=True)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--training-examples", type=int, default=4860)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--accumulate-groups", type=int, default=16)
    parser.add_argument("--max-grad-norm", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=23)
    parser.add_argument("--device", default="cpu")
    return parser


def main() -> None:
    train(build_parser().parse_args())


if __name__ == "__main__":
    main()
