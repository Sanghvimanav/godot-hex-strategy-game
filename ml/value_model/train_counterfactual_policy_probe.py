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
    target_probabilities = tuple(mass if i in targets else 0.0 for i in range(len(candidates)))
    return PolicyExample(
        state=dict(row["state"]),
        perspective_group=str(row["perspective_group"]),
        opponent_group=str(row["opponent_group"]),
        prefix_actions=tuple(dict(a) for a in row.get("prefix_actions", [])),
        candidate_actions=candidates,
        continuation_scores=target_probabilities,
        target_probabilities=target_probabilities,
    )


def _unique_layout_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_layout: dict[str, dict[str, Any]] = {}
    for row in rows:
        by_layout.setdefault(str(row.get("layout_id", row.get("game_id", ""))), row)
    return [by_layout[key] for key in sorted(by_layout)]


def _metrics(
    rows: list[dict[str, Any]],
    head,
    value_model,
    encoder,
    action_featurizer,
    entity_featurizer,
    device: torch.device,
) -> dict[str, Any]:
    sampled = _unique_layout_rows(rows)
    correct = 0
    kill_probs: list[float] = []
    entropies: list[float] = []
    margins: list[float] = []
    per_layout: dict[str, Any] = {}

    head.eval()
    value_model.eval()
    with torch.no_grad():
        for row in sampled:
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
            targets = [int(i) for i in row["target_indices"]]
            target_set = set(targets)
            top = int(logits.argmax().item())
            is_correct = top in target_set
            correct += int(is_correct)
            kill_prob = float(sum(float(probs[i].item()) for i in targets))
            kill_probs.append(kill_prob)
            entropy = float((-(probs * probs.clamp_min(1e-12).log()).sum()).item())
            entropies.append(entropy)

            kill_best = max(float(logits[i].item()) for i in targets)
            non_targets = [i for i in range(len(row["candidate_actions"])) if i not in target_set]
            nonkill_best = max(float(logits[i].item()) for i in non_targets) if non_targets else kill_best
            margin = kill_best - nonkill_best
            margins.append(margin)

            candidates = row["candidate_actions"]
            per_layout[str(row.get("layout_id", ""))] = {
                "correct": is_correct,
                "kill_probability": kill_prob,
                "kill_margin": margin,
                "top_action": candidates[top],
                "kill_actions": [candidates[i] for i in targets],
                "candidate_count": len(candidates),
            }

    def mean(values: list[float]) -> float:
        return sum(values) / len(values) if values else 0.0

    return {
        "layouts": len(sampled),
        "top1_kill_accuracy": correct / len(sampled) if sampled else 0.0,
        "mean_kill_probability": mean(kill_probs),
        "mean_entropy": mean(entropies),
        "mean_kill_logit_margin": mean(margins),
        "per_layout": per_layout,
    }


def train(args: argparse.Namespace) -> dict[str, Any]:
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device(args.device)

    train_rows = _load_rows(args.train_rows)
    eval_rows = _load_rows(args.eval_rows)

    train_layouts = {str(row.get("layout_id", "")) for row in train_rows}
    eval_layouts = {str(row.get("layout_id", "")) for row in eval_rows}
    if train_layouts & eval_layouts:
        raise ValueError("train/eval layout overlap")
    if len(train_layouts) != 18 or len(eval_layouts) != 6:
        raise ValueError(f"expected 18/6 layout split, got {len(train_layouts)}/{len(eval_layouts)}")

    checkpoint = torch.load(args.base_checkpoint, map_location=device, weights_only=False)
    encoder = make_encoder(int(checkpoint["model_config"].get("encoder_version", 1)))
    value_model = _load_value_model(checkpoint, device)
    for parameter in value_model.parameters():
        parameter.requires_grad_(False)
    value_model.eval()

    policy_head, policy_config, action_featurizer, entity_featurizer = _load_policy_head(
        checkpoint, device, train_rows + eval_rows
    )

    before_train = _metrics(
        train_rows, policy_head, value_model, encoder, action_featurizer, entity_featurizer, device
    )
    before_eval = _metrics(
        eval_rows, policy_head, value_model, encoder, action_featurizer, entity_featurizer, device
    )

    optimizer = torch.optim.AdamW(
        policy_head.parameters(),
        lr=args.learning_rate,
        weight_decay=args.weight_decay,
    )
    order = list(range(len(train_rows)))
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

    after_train = _metrics(
        train_rows, policy_head, value_model, encoder, action_featurizer, entity_featurizer, device
    )
    after_eval = _metrics(
        eval_rows, policy_head, value_model, encoder, action_featurizer, entity_featurizer, device
    )

    metrics: dict[str, Any] = {
        "experiment": "one_hp_adjacent_zergling_counterfactual_probe",
        "training_passes": 1,
        "epochs": 0,
        "train_examples": len(train_rows),
        "eval_examples": len(eval_rows),
        "train_layouts": len(train_layouts),
        "heldout_layouts": len(eval_layouts),
        "learning_rate": args.learning_rate,
        "weight_decay": args.weight_decay,
        "mean_supervised_loss": sum(losses) / len(losses),
        "shared_spatial_encoder_frozen": True,
        "base_policy_loaded": True,
        "explicit_action_mechanics_features": False,
        "supervision": "simulator_counterfactual_immediate_marine_kill",
        "vocab_expansion": policy_config.get("vocab_expansion", {}),
        "before_train": before_train,
        "before_eval": before_eval,
        "after_train": after_train,
        "after_eval": after_eval,
    }

    output = copy.deepcopy(checkpoint)
    output["joint_plan_policy_state_dict"] = policy_head.state_dict()
    updated_config = dict(policy_config)
    updated_config["target"] = "counterfactual_immediate_kill_probe"
    output["joint_plan_policy_config"] = updated_config
    output["counterfactual_probe_metrics"] = metrics

    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(output, args.output)
    args.metrics.parent.mkdir(parents=True, exist_ok=True)
    args.metrics.write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n")
    print(json.dumps(metrics, indent=2, sort_keys=True))
    return metrics


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="One-pass supervised capacity probe for killing an adjacent 1-HP Marine"
    )
    parser.add_argument("--base-checkpoint", type=Path, required=True)
    parser.add_argument("--train-rows", type=Path, required=True)
    parser.add_argument("--eval-rows", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metrics", type=Path, required=True)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--accumulate-groups", type=int, default=16)
    parser.add_argument("--max-grad-norm", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--device", default="cpu")
    return parser


def main() -> None:
    train(build_parser().parse_args())


if __name__ == "__main__":
    main()
