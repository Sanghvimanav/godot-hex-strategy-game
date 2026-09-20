from __future__ import annotations

import argparse
import copy
import json
import math
import random
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from .data import ValueExampleDataset, load_jsonl_examples
from .joint_plan_policy import (
    ActionFeaturizer,
    PolicyExample,
    SpatialEntityJointPlanPolicyHead,
    UnitEntityFeaturizer,
    unit_type,
)
from .model import HexValueNet
from .strategic_state import make_encoder
from .train_joint_plan_policy import _score_example


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for raw in path.read_text().splitlines():
        if not raw.strip():
            continue
        value = json.loads(raw)
        if isinstance(value, dict):
            rows.append(value)
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
    expected_missing = {key for key in model.state_dict() if key.startswith("policy_head.")}
    if set(incompatible.missing_keys) != expected_missing or incompatible.unexpected_keys:
        raise ValueError(
            f"incompatible value checkpoint: missing={incompatible.missing_keys} "
            f"unexpected={incompatible.unexpected_keys}"
        )
    if model.policy_head is not None and isinstance(checkpoint.get("policy_head_state_dict"), dict):
        model.policy_head.load_state_dict(checkpoint["policy_head_state_dict"])
    return model


def _load_policy_head(
    checkpoint: dict[str, Any],
    device: torch.device,
    rows: list[dict[str, Any]],
) -> tuple[
    SpatialEntityJointPlanPolicyHead,
    dict[str, Any],
    ActionFeaturizer,
    UnitEntityFeaturizer,
]:
    config = dict(checkpoint.get("joint_plan_policy_config", {}))
    if config.get("version") != 3 or config.get("architecture") != "spatial_entity_attention_v1":
        raise ValueError("direct outcome training requires Spatial Policy V1")
    if bool(config.get("explicit_action_mechanics", False)):
        raise ValueError("explicit action mechanics are not permitted")

    old_action_vocab = list(config["action_vocab"])
    old_unit_vocab = list(config["unit_vocab"])
    action_vocab = list(old_action_vocab)
    unit_vocab = list(old_unit_vocab)
    seen_actions = set(action_vocab)
    seen_units = set(unit_vocab)
    discovered_actions: set[str] = set()
    discovered_units: set[str] = set()
    for row in rows:
        for key in ("prefix_actions", "candidate_actions"):
            for action in row.get(key, []):
                if isinstance(action, dict):
                    token = str(action.get("action_key", "<unk>"))
                    if token not in seen_actions:
                        discovered_actions.add(token)
        state = row.get("state", {})
        if isinstance(state, dict):
            for group in state.get("groups", []):
                if not isinstance(group, dict):
                    continue
                for unit in group.get("units", []):
                    if isinstance(unit, dict):
                        token = unit_type(unit)
                        if token not in seen_units:
                            discovered_units.add(token)
    action_vocab.extend(sorted(discovered_actions))
    unit_vocab.extend(sorted(discovered_units))
    config["action_vocab"] = action_vocab
    config["unit_vocab"] = unit_vocab

    head = SpatialEntityJointPlanPolicyHead(
        state_feature_size=int(config["state_feature_size"]),
        spatial_feature_size=int(config["spatial_feature_size"]),
        action_vocab_size=len(action_vocab),
        unit_vocab_size=len(unit_vocab),
        max_radius=int(config["max_radius"]),
        token_dim=int(config["token_dim"]),
        action_hidden=int(config["action_hidden"]),
        prefix_hidden=int(config["prefix_hidden"]),
        entity_dim=int(config["entity_dim"]),
        relation_dim=int(config["relation_dim"]),
        spatial_hidden=int(config["spatial_hidden"]),
        attention_dim=int(config["attention_dim"]),
        spatial_context_dim=int(config["spatial_context_dim"]),
    ).to(device)
    old_state = checkpoint.get("joint_plan_policy_state_dict")
    if not isinstance(old_state, dict):
        raise ValueError("checkpoint is missing direct policy weights")

    new_state = head.state_dict()
    embedding_old_sizes = {
        "action_embedding.weight": len(old_action_vocab),
        "action_unit_embedding.weight": len(old_unit_vocab),
        "entity_unit_embedding.weight": len(old_unit_vocab),
    }
    for key, old_value in old_state.items():
        if key not in new_state:
            raise ValueError(f"unexpected policy parameter {key}")
        if new_state[key].shape == old_value.shape:
            new_state[key] = old_value
            continue
        if key not in embedding_old_sizes or new_state[key].ndim != 2:
            raise ValueError(
                f"cannot expand policy parameter {key}: {tuple(old_value.shape)} -> "
                f"{tuple(new_state[key].shape)}"
            )
        old_size = embedding_old_sizes[key]
        if old_value.shape[0] != old_size or new_state[key].shape[0] < old_size:
            raise ValueError(f"invalid embedding expansion for {key}")
        expanded = new_state[key].clone()
        expanded[:old_size] = old_value
        vocab = old_action_vocab if key == "action_embedding.weight" else old_unit_vocab
        unknown_index = vocab.index("<unk>") if "<unk>" in vocab else 0
        if expanded.shape[0] > old_size:
            expanded[old_size:] = old_value[unknown_index].unsqueeze(0)
        new_state[key] = expanded
    head.load_state_dict(new_state)
    config["vocab_expansion"] = {
        "new_action_tokens": sorted(discovered_actions),
        "new_unit_tokens": sorted(discovered_units),
        "old_action_vocab_size": len(old_action_vocab),
        "new_action_vocab_size": len(action_vocab),
        "old_unit_vocab_size": len(old_unit_vocab),
        "new_unit_vocab_size": len(unit_vocab),
        "new_tokens_initialized_from_unknown": True,
    }
    return (
        head,
        config,
        ActionFeaturizer(action_vocab, unit_vocab, max_radius=int(config["max_radius"])),
        UnitEntityFeaturizer(unit_vocab, max_radius=int(config["max_radius"])),
    )


def _row_example(row: dict[str, Any]) -> PolicyExample:
    candidates = row.get("candidate_actions", [])
    prefix = row.get("prefix_actions", [])
    selected = int(row.get("selected_index", -1))
    if not isinstance(candidates, list) or len(candidates) < 2:
        raise ValueError("policy row needs at least two candidates")
    if selected < 0 or selected >= len(candidates):
        raise ValueError("selected_index is outside candidate range")
    continuation = tuple(1.0 if i == selected else 0.0 for i in range(len(candidates)))
    return PolicyExample(
        state=dict(row["state"]),
        perspective_group=str(row["perspective_group"]),
        opponent_group=str(row["opponent_group"]),
        prefix_actions=tuple(dict(a) for a in prefix),
        candidate_actions=tuple(dict(a) for a in candidates),
        continuation_scores=continuation,
    )


def _value_request_from_policy_row(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "game_id": str(row.get("game_id", "")),
        "scenario_id": str(row.get("scenario_id", "")),
        "turn_index": int(row.get("turn_index", 0)),
        "perspective_group": str(row["perspective_group"]),
        "opponent_group": str(row["opponent_group"]),
        "outcome": 0.0,
        "terminal": False,
        "winner": "",
        "source": {
            "generation": int(row.get("generation", 0)),
            "rotation_steps": int(row.get("rotation_steps", 0)),
        },
        "state": dict(row["state"]),
    }


def _baseline_key(row: dict[str, Any]) -> tuple[str, int, str, str]:
    # Include the actual state so an accidental duplicate game_id can never make
    # one sampled trajectory borrow another trajectory's baseline.
    state_fingerprint = json.dumps(
        row.get("state", {}), sort_keys=True, separators=(",", ":")
    )
    return (
        str(row.get("game_id", "")),
        int(row.get("turn_index", 0)),
        str(row.get("perspective_group", "")),
        state_fingerprint,
    )


def _compute_baselines(
    rows: list[dict[str, Any]],
    value_model: HexValueNet,
    encoder,
    device: torch.device,
) -> dict[tuple[str, int, str, str], float]:
    result: dict[tuple[str, int, str, str], float] = {}
    value_model.eval()
    with torch.no_grad():
        for row in rows:
            key = _baseline_key(row)
            if key in result:
                continue
            encoded = encoder.encode(_value_request_from_policy_row(row))
            prediction = value_model(
                encoded.board.unsqueeze(0).to(device),
                encoded.global_features.unsqueeze(0).to(device),
            )
            result[key] = float(prediction.item())
    return result


def _value_metrics(
    model: HexValueNet,
    dataset: ValueExampleDataset,
    batch_size: int,
    device: torch.device,
) -> dict[str, float]:
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
    mse = float(F.mse_loss(pred, truth).item())
    sign = ((pred > 0) == (truth > 0)).float()
    nonzero = truth != 0
    sign_accuracy = float(sign[nonzero].mean().item()) if bool(nonzero.any()) else 0.0
    return {"mse": mse, "sign_accuracy_nonzero": sign_accuracy}


def _policy_metrics(
    rows: list[dict[str, Any]],
    head: SpatialEntityJointPlanPolicyHead,
    value_model: HexValueNet,
    encoder,
    action_featurizer: ActionFeaturizer,
    entity_featurizer: UnitEntityFeaturizer,
    device: torch.device,
    limit: int = 2000,
) -> dict[str, float]:
    if not rows:
        return {
            "mean_selected_probability": 0.0,
            "mean_entropy": 0.0,
            "win_selected_probability": 0.0,
            "loss_selected_probability": 0.0,
        }
    sampled = rows if len(rows) <= limit else rows[:limit]
    selected_probs: list[float] = []
    entropies: list[float] = []
    win_probs: list[float] = []
    loss_probs: list[float] = []
    head.eval()
    value_model.eval()
    with torch.no_grad():
        for row in sampled:
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
            probs = F.softmax(logits, dim=0)
            selected = int(row["selected_index"])
            p = float(probs[selected].item())
            entropy = float((-(probs * probs.clamp_min(1e-12).log()).sum()).item())
            selected_probs.append(p)
            entropies.append(entropy)
            outcome = float(row.get("outcome", 0.0))
            if outcome > 0:
                win_probs.append(p)
            elif outcome < 0:
                loss_probs.append(p)

    def mean(values: list[float]) -> float:
        return sum(values) / len(values) if values else 0.0

    return {
        "mean_selected_probability": mean(selected_probs),
        "mean_entropy": mean(entropies),
        "win_selected_probability": mean(win_probs),
        "loss_selected_probability": mean(loss_probs),
        "metric_rows": len(sampled),
    }


def train(args: argparse.Namespace) -> dict[str, Any]:
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device(args.device)

    checkpoint = torch.load(args.base_checkpoint, map_location=device, weights_only=False)
    encoder = make_encoder(int(checkpoint["model_config"].get("encoder_version", 1)))
    value_model = _load_value_model(checkpoint, device)

    raw_rows = _load_jsonl(args.policy_steps)
    rows = [
        row
        for row in raw_rows
        if isinstance(row.get("candidate_actions"), list)
        and len(row["candidate_actions"]) >= 2
        and 0 <= int(row.get("selected_index", -1)) < len(row["candidate_actions"])
    ]
    if not rows:
        raise ValueError("no usable direct-policy training rows")

    policy_head, policy_config, action_featurizer, entity_featurizer = _load_policy_head(
        checkpoint, device, rows
    )

    value_examples = load_jsonl_examples(args.value_examples)
    if not value_examples:
        raise ValueError("no value examples")
    generations = {int(row.get("generation", -1)) for row in rows}
    if len(generations) != 1:
        raise ValueError(f"one update must contain exactly one fresh generation, got {generations}")
    generation = next(iter(generations))

    baselines = _compute_baselines(rows, value_model, encoder, device)
    advantages = {
        _baseline_key(row): max(
            -2.0,
            min(2.0, float(row.get("outcome", 0.0)) - baselines[_baseline_key(row)]),
        )
        for row in rows
    }

    value_dataset = ValueExampleDataset(value_examples, encoder)
    value_before = _value_metrics(value_model, value_dataset, args.batch_size, device)

    # The spatial encoder is shared by the direct policy. Keep it frozen so value
    # learning cannot move the policy representation outside PPO's trust region.
    for parameter in value_model.parameters():
        parameter.requires_grad_(False)
    value_model.eval()

    policy_before = _policy_metrics(
        rows,
        policy_head,
        value_model,
        encoder,
        action_featurizer,
        entity_featurizer,
        device,
    )

    # Exactly one shuffled PPO-style pass over fresh gameplay. The behavior
    # probability was recorded at game generation time, so the clipped ratio
    # constrains how far this one pass can move each selected action.
    order = list(range(len(rows)))
    random.shuffle(order)
    policy_optimizer = torch.optim.AdamW(
        policy_head.parameters(),
        lr=args.policy_learning_rate,
        weight_decay=args.weight_decay,
    )
    policy_head.train()
    policy_optimizer.zero_grad(set_to_none=True)
    pending = 0
    actor_losses: list[float] = []
    entropies: list[float] = []
    advantage_values: list[float] = []
    probability_ratios: list[float] = []
    clipped_rows = 0
    for index in order:
        row = rows[index]
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
        log_probs = F.log_softmax(logits, dim=0)
        probs = log_probs.exp()
        selected = int(row["selected_index"])
        advantage = float(advantages[_baseline_key(row)])
        behavior_probability = max(1e-8, float(row.get("behavior_probability", 0.0)))
        selected_probability = probs[selected].clamp_min(1e-8)
        ratio = selected_probability / behavior_probability
        clipped_ratio = ratio.clamp(1.0 - args.ppo_clip, 1.0 + args.ppo_clip)
        unclipped_objective = ratio * advantage
        clipped_objective = clipped_ratio * advantage
        actor_loss = -torch.minimum(unclipped_objective, clipped_objective)
        entropy = -(probs * log_probs).sum()
        loss = (actor_loss - args.entropy_beta * entropy) / float(args.accumulate_groups)
        loss.backward()
        actor_losses.append(float(actor_loss.detach().item()))
        entropies.append(float(entropy.detach().item()))
        advantage_values.append(advantage)
        ratio_value = float(ratio.detach().item())
        probability_ratios.append(ratio_value)
        clipped_rows += int(ratio_value < 1.0 - args.ppo_clip or ratio_value > 1.0 + args.ppo_clip)
        pending += 1
        if pending == args.accumulate_groups:
            torch.nn.utils.clip_grad_norm_(policy_head.parameters(), args.max_grad_norm)
            policy_optimizer.step()
            policy_optimizer.zero_grad(set_to_none=True)
            pending = 0
    if pending:
        torch.nn.utils.clip_grad_norm_(policy_head.parameters(), args.max_grad_norm)
        policy_optimizer.step()
        policy_optimizer.zero_grad(set_to_none=True)

    policy_after = _policy_metrics(
        rows,
        policy_head,
        value_model,
        encoder,
        action_featurizer,
        entity_featurizer,
        device,
    )

    # Update only the value head after the policy step. The shared spatial encoder
    # stays fixed across generations so this cannot implicitly change policy logits.
    for parameter in value_model.head.parameters():
        parameter.requires_grad_(True)
    value_optimizer = torch.optim.AdamW(
        value_model.head.parameters(),
        lr=args.value_learning_rate,
        weight_decay=args.weight_decay,
    )
    value_loader = DataLoader(value_dataset, batch_size=args.batch_size, shuffle=True)
    value_model.eval()
    value_model.head.train()
    for board, globals_, target in value_loader:
        value_optimizer.zero_grad(set_to_none=True)
        prediction = value_model(board.to(device), globals_.to(device))
        loss = F.mse_loss(prediction, target.to(device))
        loss.backward()
        torch.nn.utils.clip_grad_norm_(value_model.head.parameters(), args.max_grad_norm)
        value_optimizer.step()
    value_after = _value_metrics(value_model, value_dataset, args.batch_size, device)

    def mean(values: list[float]) -> float:
        return sum(values) / len(values) if values else 0.0

    outcomes = [float(row.get("outcome", 0.0)) for row in rows]
    metrics: dict[str, Any] = {
        "generation": generation,
        "training_passes": 1,
        "epochs": 0,
        "policy_steps": len(rows),
        "value_examples": len(value_examples),
        "wins_policy_steps": sum(1 for value in outcomes if value > 0),
        "loss_policy_steps": sum(1 for value in outcomes if value < 0),
        "draw_policy_steps": sum(1 for value in outcomes if value == 0),
        "mean_preupdate_baseline": mean(list(baselines.values())),
        "mean_advantage": mean(advantage_values),
        "mean_abs_advantage": mean([abs(value) for value in advantage_values]),
        "mean_actor_loss": mean(actor_losses),
        "mean_training_entropy": mean(entropies),
        "mean_probability_ratio": mean(probability_ratios),
        "ppo_clipped_fraction": clipped_rows / len(rows),
        "ppo_clip": args.ppo_clip,
        "entropy_beta": args.entropy_beta,
        "value_before": value_before,
        "value_after": value_after,
        "policy_before": policy_before,
        "policy_after": policy_after,
        "policy_supervision": "final_game_outcome_ppo_clipped",
        "value_supervision": "final_game_outcome_value_head_only",
        "shared_spatial_encoder_frozen": True,
        "training_opponent": "frozen_handwritten",
        "mcts_used": False,
        "explicit_action_mechanics": False,
        "vocab_expansion": policy_config.get("vocab_expansion", {}),
    }

    output = copy.deepcopy(checkpoint)
    output["model_state_dict"] = {
        key: value
        for key, value in value_model.state_dict().items()
        if not key.startswith("policy_head.")
    }
    if value_model.policy_head is not None:
        output["policy_head_state_dict"] = value_model.policy_head.state_dict()
    output["joint_plan_policy_state_dict"] = policy_head.state_dict()
    updated_policy_config = dict(policy_config)
    updated_policy_config["target"] = "outcome_ppo_v2"
    updated_policy_config["explicit_action_mechanics"] = False
    output["joint_plan_policy_config"] = updated_policy_config

    history = list(output.get("outcome_actor_critic_history", []))
    history.append(metrics)
    output["outcome_actor_critic_history"] = history
    output["outcome_actor_critic_config"] = {
        "training_passes_per_generation": 1,
        "epochs": 0,
        "value_learning_rate": args.value_learning_rate,
        "policy_learning_rate": args.policy_learning_rate,
        "entropy_beta": args.entropy_beta,
        "ppo_clip": args.ppo_clip,
        "shared_spatial_encoder_frozen": True,
        "weight_decay": args.weight_decay,
        "training_opponent": "frozen_handwritten",
        "direct_policy": True,
        "mcts_used": False,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(output, args.output)
    print(json.dumps(metrics, indent=2, sort_keys=True))
    return metrics


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="One-pass outcome actor-critic update from neural-vs-handwritten games"
    )
    parser.add_argument("--base-checkpoint", type=Path, required=True)
    parser.add_argument("--policy-steps", type=Path, required=True)
    parser.add_argument("--value-examples", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--value-learning-rate", type=float, default=1e-4)
    parser.add_argument("--policy-learning-rate", type=float, default=1e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--entropy-beta", type=float, default=0.01)
    parser.add_argument("--ppo-clip", type=float, default=0.2)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--accumulate-groups", type=int, default=16)
    parser.add_argument("--max-grad-norm", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="cpu")
    return parser


def main() -> None:
    train(build_parser().parse_args())


if __name__ == "__main__":
    main()
