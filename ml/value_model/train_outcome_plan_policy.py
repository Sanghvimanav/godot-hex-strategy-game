from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F

from .joint_plan_policy import (
    ActionFeaturizer,
    PolicyExample,
    SpatialEntityJointPlanPolicyHead,
    UnitEntityFeaturizer,
    _complete_plan_actions,
    action_signature,
)
from .strategic_state import make_encoder
from .train_joint_plan_policy import _load_jsonl, _load_value_model, _score_example


def _trajectory_id(decision: dict[str, Any]) -> str:
    game_id = str(decision.get("game_id", ""))
    perspective = str(decision.get("perspective_group", ""))
    suffix = f"-{perspective}" if perspective else ""
    if suffix and game_id.endswith(suffix):
        return game_id[: -len(suffix)]
    return game_id


def _winner_by_game(paths: list[Path]) -> dict[str, str]:
    winners: dict[str, str] = {}
    for path in paths:
        for raw in path.read_text().splitlines():
            if not raw.strip():
                continue
            row = json.loads(raw)
            if not isinstance(row, dict):
                continue
            game_id = str(row.get("game_id", ""))
            if not game_id:
                continue
            winner = str(row.get("winner", ""))
            previous = winners.get(game_id)
            if previous is not None and previous != winner:
                raise ValueError(f"conflicting winners for {game_id}: {previous!r} vs {winner!r}")
            winners[game_id] = winner
    return winners


def _perspective_reward(winner: str, perspective: str, opponent: str) -> float:
    if not winner:
        return 0.0
    if winner == perspective:
        return 1.0
    if winner == opponent:
        return -1.0
    return 0.0


def _selected_candidate(decision: dict[str, Any]) -> dict[str, Any] | None:
    requested = int(decision.get("selected_candidate_index", -1))
    fallback: dict[str, Any] | None = None
    for row in decision.get("candidates", []):
        if not isinstance(row, dict):
            continue
        if bool(row.get("selected", False)):
            fallback = row
        if int(row.get("candidate_index", -1)) == requested:
            return row
    return fallback


def build_outcome_examples(decision: dict[str, Any]) -> list[PolicyExample]:
    """Build autoregressive targets for the plan actually played in self-play.

    Robust-search scores are intentionally ignored. Candidate plans are used only as
    the action choice set. The selected self-play plan supplies the action target;
    the eventual game outcome supplies the signed policy-gradient reward.
    """
    state = decision.get("starting_state", {})
    perspective = str(decision.get("perspective_group", ""))
    opponent = str(decision.get("opponent_group", ""))
    selected_row = _selected_candidate(decision)
    if not isinstance(state, dict) or not state or not perspective or not opponent or selected_row is None:
        return []

    plans: list[list[dict[str, Any]]] = []
    selected_plan: list[dict[str, Any]] | None = None
    selected_index = int(selected_row.get("candidate_index", -1))
    for row in decision.get("candidates", []):
        if not isinstance(row, dict):
            continue
        actions = _complete_plan_actions(state, perspective, row.get("actions", []))
        if not actions:
            continue
        plans.append(actions)
        if row is selected_row or int(row.get("candidate_index", -2)) == selected_index:
            selected_plan = actions
    if not plans or not selected_plan:
        return []

    examples: list[PolicyExample] = []
    for depth, selected_action in enumerate(selected_plan):
        selected_prefix = tuple(action_signature(action) for action in selected_plan[:depth])
        rows: list[list[dict[str, Any]]] = []
        for actions in plans:
            if len(actions) <= depth:
                continue
            prefix = tuple(action_signature(action) for action in actions[:depth])
            if prefix == selected_prefix:
                rows.append(actions)
        if not rows:
            continue

        by_action: dict[str, dict[str, Any]] = {}
        for actions in rows:
            action = actions[depth]
            by_action.setdefault(action_signature(action), dict(action))
        chosen_signature = action_signature(selected_action)
        if chosen_signature not in by_action or len(by_action) < 2:
            continue

        ordered = sorted(by_action.items(), key=lambda item: item[0])
        scores = tuple(1.0 if signature == chosen_signature else 0.0 for signature, _ in ordered)
        examples.append(
            PolicyExample(
                state=state,
                perspective_group=perspective,
                opponent_group=opponent,
                prefix_actions=tuple(dict(action) for action in selected_plan[:depth]),
                candidate_actions=tuple(dict(action) for _, action in ordered),
                continuation_scores=scores,
            )
        )
    return examples


def _load_spatial_head(checkpoint: dict[str, Any], device: torch.device) -> SpatialEntityJointPlanPolicyHead:
    config = checkpoint.get("joint_plan_policy_config", {})
    if int(config.get("version", 0)) != 3 or config.get("architecture") != "spatial_entity_attention_v1":
        raise ValueError("outcome policy fine-tuning requires a V3 spatial_entity_attention_v1 checkpoint")
    state = checkpoint.get("joint_plan_policy_state_dict")
    if not isinstance(state, dict):
        raise ValueError("base checkpoint is missing joint_plan_policy_state_dict")
    head = SpatialEntityJointPlanPolicyHead(
        state_feature_size=int(config["state_feature_size"]),
        spatial_feature_size=int(config["spatial_feature_size"]),
        action_vocab_size=len(config["action_vocab"]),
        unit_vocab_size=len(config["unit_vocab"]),
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
    head.load_state_dict(state)
    return head


def _behavior_metrics(
    head: SpatialEntityJointPlanPolicyHead,
    value_model,
    encoder,
    action_featurizer: ActionFeaturizer,
    entity_featurizer: UnitEntityFeaturizer,
    examples: list[tuple[PolicyExample, float]],
    device: torch.device,
) -> dict[str, Any]:
    buckets: dict[str, list[tuple[float, float]]] = {"win": [], "loss": []}
    head.eval()
    with torch.no_grad():
        for example, reward in examples:
            if reward == 0:
                continue
            logits = _score_example(
                head, value_model, encoder, action_featurizer, entity_featurizer, example, device
            )
            probabilities = F.softmax(logits, dim=0)
            target = example.target_index
            bucket = "win" if reward > 0 else "loss"
            buckets[bucket].append((
                float(probabilities[target].item()),
                1.0 if int(logits.argmax().item()) == target else 0.0,
            ))

    result: dict[str, Any] = {}
    for name, rows in buckets.items():
        result[name] = {
            "prefix_examples": len(rows),
            "mean_selected_probability": (
                sum(probability for probability, _ in rows) / len(rows) if rows else 0.0
            ),
            "selected_top1_rate": (
                sum(top1 for _, top1 in rows) / len(rows) if rows else 0.0
            ),
        }
    return result


def train(args: argparse.Namespace) -> dict[str, Any]:
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device(args.device)

    checkpoint = torch.load(args.base_checkpoint, map_location=device, weights_only=False)
    config = checkpoint["joint_plan_policy_config"]
    value_model = _load_value_model(checkpoint, device)
    encoder = make_encoder(checkpoint["model_config"].get("encoder_version", 1))
    action_featurizer = ActionFeaturizer(
        list(config["action_vocab"]), list(config["unit_vocab"]), max_radius=encoder.max_radius
    )
    entity_featurizer = UnitEntityFeaturizer(list(config["unit_vocab"]), max_radius=encoder.max_radius)
    head = _load_spatial_head(checkpoint, device)

    decisions = _load_jsonl(args.search_decisions)
    if args.evaluator:
        decisions = [
            row for row in decisions
            if str(row.get("source", {}).get("evaluator", "")) == args.evaluator
        ]
    winners = _winner_by_game(args.value_examples)

    training_examples: list[tuple[PolicyExample, float]] = []
    decision_counts = {"win": 0, "loss": 0, "draw_or_unresolved": 0, "missing_outcome": 0, "no_prefix_choices": 0}
    used_game_ids: set[str] = set()
    for decision in decisions:
        trajectory = _trajectory_id(decision)
        if trajectory not in winners:
            decision_counts["missing_outcome"] += 1
            continue
        perspective = str(decision.get("perspective_group", ""))
        opponent = str(decision.get("opponent_group", ""))
        reward = _perspective_reward(winners[trajectory], perspective, opponent)
        if reward > 0:
            decision_counts["win"] += 1
        elif reward < 0:
            decision_counts["loss"] += 1
        else:
            decision_counts["draw_or_unresolved"] += 1
        prefix_examples = build_outcome_examples(decision)
        if not prefix_examples:
            decision_counts["no_prefix_choices"] += 1
            continue
        used_game_ids.add(trajectory)
        training_examples.extend((example, reward) for example in prefix_examples if reward != 0)

    if not training_examples:
        raise ValueError("no outcome-labeled policy examples were produced")
    if not any(reward > 0 for _, reward in training_examples):
        raise ValueError("outcome policy requires at least one winning example")
    if not any(reward < 0 for _, reward in training_examples):
        raise ValueError("outcome policy requires at least one losing example")

    before = _behavior_metrics(
        head, value_model, encoder, action_featurizer, entity_featurizer, training_examples, device
    )
    optimizer = torch.optim.AdamW(head.parameters(), lr=args.learning_rate, weight_decay=args.weight_decay)
    order = list(range(len(training_examples)))
    for _epoch in range(args.epochs):
        random.shuffle(order)
        head.train()
        optimizer.zero_grad(set_to_none=True)
        pending = 0
        for index in order:
            example, reward = training_examples[index]
            logits = _score_example(
                head, value_model, encoder, action_featurizer, entity_featurizer, example, device
            )
            log_probs = F.log_softmax(logits, dim=0)
            loss = -float(reward) * log_probs[example.target_index]
            if args.entropy_weight > 0:
                probabilities = log_probs.exp()
                entropy = -(probabilities * log_probs).sum()
                loss = loss - args.entropy_weight * entropy
            (loss / float(args.accumulate_groups)).backward()
            pending += 1
            if pending == args.accumulate_groups:
                torch.nn.utils.clip_grad_norm_(head.parameters(), args.max_grad_norm)
                optimizer.step()
                optimizer.zero_grad(set_to_none=True)
                pending = 0
        if pending:
            torch.nn.utils.clip_grad_norm_(head.parameters(), args.max_grad_norm)
            optimizer.step()
            optimizer.zero_grad(set_to_none=True)

    after = _behavior_metrics(
        head, value_model, encoder, action_featurizer, entity_featurizer, training_examples, device
    )
    metrics = {
        "objective": "signed_self_play_outcome_policy_gradient",
        "robust_search_scores_used_in_loss": False,
        "mcts_visit_targets_used_in_loss": False,
        "candidate_sets_reused_from_search_capture": True,
        "evaluator_filter": args.evaluator,
        "decision_rows_considered": len(decisions),
        "decision_outcomes": decision_counts,
        "training_prefix_examples": len(training_examples),
        "training_games": len(used_game_ids),
        "before": before,
        "after": after,
        "epochs": args.epochs,
        "learning_rate": args.learning_rate,
        "entropy_weight": args.entropy_weight,
        "seed": args.seed,
    }

    output = dict(checkpoint)
    output["joint_plan_policy_state_dict"] = head.state_dict()
    policy_config = dict(config)
    policy_config["target"] = "signed_self_play_outcome_policy_gradient"
    output["joint_plan_policy_config"] = policy_config
    output["outcome_policy_metrics"] = metrics
    output["outcome_policy_training_config"] = {
        "base_checkpoint": str(args.base_checkpoint),
        "search_decisions": [str(path) for path in args.search_decisions],
        "value_examples": [str(path) for path in args.value_examples],
        "evaluator_filter": args.evaluator,
        "epochs": args.epochs,
        "learning_rate": args.learning_rate,
        "weight_decay": args.weight_decay,
        "entropy_weight": args.entropy_weight,
        "max_grad_norm": args.max_grad_norm,
        "backbone_frozen": True,
        "robust_search_scores_used_in_loss": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(output, args.output)
    print(json.dumps(metrics, indent=2, sort_keys=True))
    return metrics


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fine-tune the V3 spatial policy from actual self-play outcomes rather than search scores"
    )
    parser.add_argument("--base-checkpoint", type=Path, required=True)
    parser.add_argument("--search-decisions", type=Path, action="append", required=True)
    parser.add_argument("--value-examples", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evaluator", default="neural")
    parser.add_argument("--epochs", type=int, default=10)
    parser.add_argument("--learning-rate", type=float, default=1e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--entropy-weight", type=float, default=0.01)
    parser.add_argument("--accumulate-groups", type=int, default=16)
    parser.add_argument("--max-grad-norm", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="cpu")
    return parser


def main() -> None:
    train(build_parser().parse_args())


if __name__ == "__main__":
    main()
