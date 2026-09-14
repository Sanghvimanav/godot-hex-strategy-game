from __future__ import annotations

import argparse
import json
import math
import random
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F
from torch import nn
from torch.utils.data import DataLoader

from .data import ValueExampleDataset, load_jsonl_examples
from .joint_plan_policy import (
    ActionFeaturizer,
    PolicyExample,
    SpatialEntityJointPlanPolicyHead,
    UnitEntityFeaturizer,
)
from .metrics import sign_accuracy
from .model import HexValueNet
from .strategic_state import make_encoder
from .train_joint_plan_policy import _score_example


EXPECTED_ROTATIONS = {0, 1, 2, 3, 4, 5}


def _load_jsonl(paths: list[Path]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in paths:
        for raw in path.read_text().splitlines():
            if not raw.strip():
                continue
            row = json.loads(raw)
            if isinstance(row, dict):
                rows.append(row)
    return rows


def _load_value_model(checkpoint: dict[str, Any], device: torch.device) -> HexValueNet:
    config = checkpoint["model_config"]
    model = HexValueNet(
        board_channels=int(config["board_channels"]),
        global_features=int(config["global_features"]),
        hidden_channels=int(config["hidden_channels"]),
        residual_blocks=int(config["residual_blocks"]),
        policy_head=bool(config.get("policy_head", False)),
    ).to(device)
    incompatible = model.load_state_dict(checkpoint["model_state_dict"], strict=False)
    unexpected = list(incompatible.unexpected_keys)
    missing = [key for key in incompatible.missing_keys if not key.startswith("policy_head.")]
    if unexpected or missing:
        raise ValueError(f"champion value checkpoint is incompatible: missing={missing}, unexpected={unexpected}")
    if model.policy_head is not None and isinstance(checkpoint.get("policy_head_state_dict"), dict):
        model.policy_head.load_state_dict(checkpoint["policy_head_state_dict"])
    return model


def _load_policy_head(
    checkpoint: dict[str, Any], encoder, device: torch.device
) -> tuple[SpatialEntityJointPlanPolicyHead, dict[str, Any], ActionFeaturizer, UnitEntityFeaturizer]:
    config = dict(checkpoint.get("joint_plan_policy_config", {}))
    if config.get("version") != 3 or config.get("architecture") != "spatial_entity_attention_v1":
        raise ValueError("MCTS self-play V1 requires the Spatial Policy V1 architecture")
    if bool(config.get("explicit_action_mechanics", False)):
        raise ValueError("explicit action mechanics are not permitted")
    action_vocab = list(config["action_vocab"])
    unit_vocab = list(config["unit_vocab"])
    head = SpatialEntityJointPlanPolicyHead(
        state_feature_size=int(config["state_feature_size"]),
        spatial_feature_size=int(config["spatial_feature_size"]),
        action_vocab_size=len(action_vocab),
        unit_vocab_size=len(unit_vocab),
        max_radius=int(config.get("max_radius", encoder.max_radius)),
        token_dim=int(config["token_dim"]),
        action_hidden=int(config["action_hidden"]),
        prefix_hidden=int(config["prefix_hidden"]),
        entity_dim=int(config["entity_dim"]),
        relation_dim=int(config["relation_dim"]),
        spatial_hidden=int(config["spatial_hidden"]),
        attention_dim=int(config["attention_dim"]),
        spatial_context_dim=int(config["spatial_context_dim"]),
    ).to(device)
    state = checkpoint.get("joint_plan_policy_state_dict")
    if not isinstance(state, dict):
        raise ValueError("champion checkpoint is missing spatial joint-plan policy weights")
    head.load_state_dict(state)
    return (
        head,
        config,
        ActionFeaturizer(action_vocab, unit_vocab, max_radius=int(config.get("max_radius", encoder.max_radius))),
        UnitEntityFeaturizer(unit_vocab, max_radius=int(config.get("max_radius", encoder.max_radius))),
    )


def _policy_examples(rows: list[dict[str, Any]]) -> list[PolicyExample]:
    examples: list[PolicyExample] = []
    for row in rows:
        if row.get("target_type") != "autoregressive_mcts_visit_distribution_v1":
            continue
        if not bool(row.get("all_legal_actions_exposed", False)):
            raise ValueError("policy target did not expose every legal action")
        if not bool(row.get("all_legal_actions_visited", False)):
            raise ValueError("policy target did not visit every legal action")
        if float(row.get("exposure_coverage", 0.0)) < 1.0 or float(row.get("visit_coverage", 0.0)) < 1.0:
            raise ValueError("policy target coverage is below 100%")
        candidates = row.get("candidate_actions", [])
        visits = row.get("visit_distribution", [])
        if not isinstance(candidates, list) or len(candidates) < 2:
            continue
        if not isinstance(visits, list) or len(visits) != len(candidates):
            raise ValueError("MCTS visit distribution does not match candidate actions")
        masses = tuple(float(item.get("visits", 0.0)) for item in visits)
        total = sum(masses)
        if total <= 0.0:
            raise ValueError("MCTS visit target has zero total mass")
        examples.append(
            PolicyExample(
                state=dict(row["starting_state"]),
                perspective_group=str(row["perspective_group"]),
                opponent_group=str(row["opponent_group"]),
                prefix_actions=tuple(dict(action) for action in row.get("prefix_actions", [])),
                candidate_actions=tuple(dict(action) for action in candidates),
                continuation_scores=masses,
                target_probabilities=tuple(mass / total for mass in masses),
            )
        )
    if not examples:
        raise ValueError("no usable MCTS visit policy examples")
    return examples


def _value_metrics(model: HexValueNet, dataset: ValueExampleDataset, batch_size: int, device: torch.device) -> dict[str, float]:
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False)
    predictions: list[torch.Tensor] = []
    targets: list[torch.Tensor] = []
    model.eval()
    with torch.no_grad():
        for board, globals_, target in loader:
            predictions.append(model(board.to(device), globals_.to(device)).cpu())
            targets.append(target.cpu())
    pred = torch.cat(predictions)
    truth = torch.cat(targets)
    return {
        "mse": float(F.mse_loss(pred, truth).item()),
        "sign_accuracy": float(sign_accuracy(pred, truth)),
    }


def _policy_metrics(
    head: SpatialEntityJointPlanPolicyHead,
    value_model: HexValueNet,
    encoder,
    action_featurizer: ActionFeaturizer,
    entity_featurizer: UnitEntityFeaturizer,
    examples: list[PolicyExample],
    device: torch.device,
) -> dict[str, float]:
    losses: list[float] = []
    top1 = 0
    kls: list[float] = []
    head.eval()
    with torch.no_grad():
        for example in examples:
            logits = _score_example(
                head,
                value_model,
                encoder,
                action_featurizer,
                entity_featurizer,
                example,
                device,
            )
            target = torch.tensor(example.target_distribution, dtype=logits.dtype, device=device)
            log_probs = F.log_softmax(logits, dim=0)
            losses.append(float((-(target * log_probs).sum()).item()))
            top1 += int(int(logits.argmax().item()) == example.target_index)
            probs = log_probs.exp()
            safe_target = target.clamp_min(1e-12)
            safe_probs = probs.clamp_min(1e-12)
            kls.append(float((target * (safe_target.log() - safe_probs.log())).sum().item()))
    return {
        "cross_entropy": sum(losses) / len(losses),
        "top1_accuracy": top1 / len(examples),
        "target_to_policy_kl": sum(kls) / len(kls),
    }


def train(args: argparse.Namespace) -> dict[str, Any]:
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device(args.device)

    champion = torch.load(args.base_checkpoint, map_location=device, weights_only=False)
    encoder = make_encoder(int(champion["model_config"].get("encoder_version", 1)))
    value_examples = load_jsonl_examples(args.value_examples)
    policy_rows = _load_jsonl(args.policy_targets)
    if not value_examples:
        raise ValueError("value self-play dataset is empty")
    rotations = {
        int(example.get("source", {}).get("rotation_steps"))
        for example in value_examples
        if example.get("source", {}).get("rotation_steps") is not None
    }
    policy_rotations = {
        int(row.get("rotation_steps"))
        for row in policy_rows
        if row.get("rotation_steps") is not None
    }
    if rotations != EXPECTED_ROTATIONS or policy_rotations != EXPECTED_ROTATIONS:
        raise ValueError(f"training must cover all six rotations: value={rotations}, policy={policy_rotations}")

    min_exposure = min(float(row.get("exposure_coverage", 0.0)) for row in policy_rows)
    min_visit = min(float(row.get("visit_coverage", 0.0)) for row in policy_rows)
    zero_visit = sum(len(row.get("zero_visit_actions", [])) for row in policy_rows)
    if min_exposure < 1.0 or min_visit < 1.0 or zero_visit:
        raise ValueError(
            f"legal-action coverage failed: exposure={min_exposure}, visit={min_visit}, zero_visit={zero_visit}"
        )

    value_model = _load_value_model(champion, device)
    value_dataset = ValueExampleDataset(value_examples, encoder)
    value_before = _value_metrics(value_model, value_dataset, args.batch_size, device)
    value_loader = DataLoader(value_dataset, batch_size=args.batch_size, shuffle=True)
    value_optimizer = torch.optim.AdamW(
        value_model.parameters(), lr=args.value_learning_rate, weight_decay=args.weight_decay
    )
    value_model.train()
    for _ in range(args.value_epochs):
        for board, globals_, target in value_loader:
            value_optimizer.zero_grad(set_to_none=True)
            prediction = value_model(board.to(device), globals_.to(device))
            loss = F.mse_loss(prediction, target.to(device))
            loss.backward()
            value_optimizer.step()
    value_after = _value_metrics(value_model, value_dataset, args.batch_size, device)

    head, policy_config, action_featurizer, entity_featurizer = _load_policy_head(champion, encoder, device)
    examples = _policy_examples(policy_rows)
    for parameter in value_model.parameters():
        parameter.requires_grad_(False)
    value_model.eval()
    policy_before = _policy_metrics(
        head, value_model, encoder, action_featurizer, entity_featurizer, examples, device
    )
    policy_optimizer = torch.optim.AdamW(
        head.parameters(), lr=args.policy_learning_rate, weight_decay=args.weight_decay
    )
    order = list(range(len(examples)))
    for _ in range(args.policy_epochs):
        random.shuffle(order)
        head.train()
        policy_optimizer.zero_grad(set_to_none=True)
        pending = 0
        for index in order:
            example = examples[index]
            logits = _score_example(
                head,
                value_model,
                encoder,
                action_featurizer,
                entity_featurizer,
                example,
                device,
            )
            target = torch.tensor(example.target_distribution, dtype=logits.dtype, device=device)
            loss = -(target * F.log_softmax(logits, dim=0)).sum() / float(args.accumulate_groups)
            loss.backward()
            pending += 1
            if pending == args.accumulate_groups:
                policy_optimizer.step()
                policy_optimizer.zero_grad(set_to_none=True)
                pending = 0
        if pending:
            policy_optimizer.step()
            policy_optimizer.zero_grad(set_to_none=True)
    policy_after = _policy_metrics(
        head, value_model, encoder, action_featurizer, entity_featurizer, examples, device
    )

    visit_entropies = [float(row.get("visit_entropy", 0.0)) for row in policy_rows]
    prior_entropies = [float(row.get("prior_entropy", 0.0)) for row in policy_rows]
    search_kls = [float(row.get("mcts_vs_prior_kl", 0.0)) for row in policy_rows]
    metrics: dict[str, Any] = {
        "value_examples": len(value_examples),
        "policy_prefix_examples": len(examples),
        "policy_target_source": "mcts_visit_distributions_only",
        "robust_distillation_rows_used": 0,
        "value_target_source": "final_self_play_result",
        "trained_rotations": sorted(rotations),
        "static_rotation_holdout": False,
        "minimum_legal_action_exposure_coverage": min_exposure,
        "minimum_legal_action_visit_coverage": min_visit,
        "zero_visit_action_count": zero_visit,
        "mean_prior_entropy": sum(prior_entropies) / len(prior_entropies),
        "mean_visit_entropy": sum(visit_entropies) / len(visit_entropies),
        "mean_mcts_vs_prior_kl": sum(search_kls) / len(search_kls),
        "value_before": value_before,
        "value_after": value_after,
        "policy_before": policy_before,
        "policy_after": policy_after,
        "explicit_action_mechanics": False,
    }

    output = dict(champion)
    output["model_state_dict"] = value_model.state_dict()
    updated_policy_config = dict(policy_config)
    updated_policy_config["target"] = "autoregressive_prefix_mcts_visit_distribution_v1"
    updated_policy_config["explicit_action_mechanics"] = False
    output["joint_plan_policy_config"] = updated_policy_config
    output["joint_plan_policy_state_dict"] = head.state_dict()
    output["mcts_self_play_metrics"] = metrics
    output["mcts_self_play_training_config"] = {
        "base_checkpoint": str(args.base_checkpoint),
        "value_examples": str(args.value_examples),
        "policy_targets": [str(path) for path in args.policy_targets],
        "value_epochs": args.value_epochs,
        "policy_epochs": args.policy_epochs,
        "value_learning_rate": args.value_learning_rate,
        "policy_learning_rate": args.policy_learning_rate,
        "seed": args.seed,
        "train_on_all_six_rotations": True,
        "static_holdout": False,
        "policy_target_source": "mcts_visit_distributions_only",
        "robust_distillation_rows_used": 0,
        "value_target_source": "final_self_play_result",
        "full_legal_action_exposure_required": True,
        "full_legal_action_visit_required": True,
        "explicit_action_mechanics": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(output, args.output)
    print(json.dumps(metrics, indent=2, sort_keys=True))
    return metrics


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Warm-start value and spatial policy from full-coverage tiny MCTS self-play"
    )
    parser.add_argument("--base-checkpoint", type=Path, required=True)
    parser.add_argument("--value-examples", type=Path, required=True)
    parser.add_argument("--policy-targets", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--value-epochs", type=int, default=15)
    parser.add_argument("--policy-epochs", type=int, default=15)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--value-learning-rate", type=float, default=1e-4)
    parser.add_argument("--policy-learning-rate", type=float, default=1e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--accumulate-groups", type=int, default=16)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="cpu")
    return parser


def main() -> None:
    train(build_parser().parse_args())


if __name__ == "__main__":
    main()
