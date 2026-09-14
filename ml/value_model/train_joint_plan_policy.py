from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F

from .data import HexStateEncoder, SCHEMA_VERSION
from .joint_plan_policy import (
    ActionFeaturizer,
    PolicyExample,
    SpatialEntityJointPlanPolicyHead,
    UnitEntityFeaturizer,
    build_policy_examples,
    build_vocab,
)
from .model import HexValueNet
from .strategic_state import make_encoder
from .prepare_phase_one_training import audit


def split_decisions(decisions, fraction, seed):
    if not 0 < fraction < 1:
        raise ValueError("validation fraction must be between zero and one")
    groups = {}
    for row in decisions:
        key = row.get("game_id")
        if not key:
            raise ValueError("every decision requires a game_id for leakage-safe splitting")
        groups.setdefault(str(key), []).append(row)
    keys = sorted(groups)
    if len(keys) < 2:
        raise ValueError("need at least two independent games")
    random.Random(seed).shuffle(keys)
    count = min(len(keys) - 1, max(1, round(len(keys) * fraction)))
    heldout = set(keys[:count])
    return ([r for k, rows in groups.items() if k not in heldout for r in rows],
            [r for k, rows in groups.items() if k in heldout for r in rows])


def _load_jsonl(paths: list[Path]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in paths:
        for raw in path.read_text().splitlines():
            if not raw.strip():
                continue
            row = json.loads(raw)
            if isinstance(row, dict) and bool(row.get("valid", True)):
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
    expected_missing = {key for key in model.state_dict() if key.startswith("policy_head.")}
    if set(incompatible.missing_keys) != expected_missing or incompatible.unexpected_keys:
        raise ValueError("base checkpoint state is incompatible")
    if model.policy_head is not None:
        policy_state = checkpoint.get("policy_head_state_dict")
        if not isinstance(policy_state, dict):
            raise ValueError("checkpoint has policy_head=True but no policy_head_state_dict")
        model.policy_head.load_state_dict(policy_state)
    model.eval()
    for parameter in model.parameters():
        parameter.requires_grad_(False)
    return model


def _request_example(example: PolicyExample) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "perspective_group": example.perspective_group,
        "opponent_group": example.opponent_group,
        "turn_index": int(example.state.get("turn_index", 0)),
        "terminal": False,
        "outcome": 0.0,
        "state": example.state,
    }


def _state_inputs(
    value_model: HexValueNet,
    encoder: HexStateEncoder,
    example: PolicyExample,
    device: torch.device,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    encoded = encoder.encode(_request_example(example))
    board = encoded.board.unsqueeze(0).to(device)
    globals_ = encoded.global_features.unsqueeze(0).to(device)
    with torch.no_grad():
        spatial, valid_mask, state_features = value_model.encode_spatial(board, globals_)
    return state_features.detach(), spatial.detach(), valid_mask.detach()


def _action_tensors(
    featurizer: ActionFeaturizer,
    state: dict[str, Any],
    actions: tuple[dict[str, Any], ...],
    device: torch.device,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    encoded = [featurizer.encode(state, action) for action in actions]
    if not encoded:
        return (
            torch.empty((0,), dtype=torch.long, device=device),
            torch.empty((0,), dtype=torch.long, device=device),
            torch.empty((0, ActionFeaturizer.NUMERIC_FEATURES), dtype=torch.float32, device=device),
        )
    return (
        torch.tensor([row[0] for row in encoded], dtype=torch.long, device=device),
        torch.tensor([row[1] for row in encoded], dtype=torch.long, device=device),
        torch.tensor([row[2] for row in encoded], dtype=torch.float32, device=device),
    )


def _entity_tensors(
    featurizer: UnitEntityFeaturizer,
    state: dict[str, Any],
    perspective_group: str,
    device: torch.device,
) -> tuple[
    torch.Tensor,
    torch.Tensor,
    torch.Tensor,
    torch.Tensor,
    torch.Tensor,
    dict[int, int],
]:
    rows = featurizer.encode(state, perspective_group)
    if not rows:
        return (
            torch.empty((0,), dtype=torch.long, device=device),
            torch.empty((0,), dtype=torch.long, device=device),
            torch.empty((0, UnitEntityFeaturizer.NUMERIC_FEATURES), dtype=torch.float32, device=device),
            torch.empty((0,), dtype=torch.long, device=device),
            torch.empty((0,), dtype=torch.long, device=device),
            {},
        )
    unit_to_index = {row[0]: index for index, row in enumerate(rows)}
    return (
        torch.tensor([row[1] for row in rows], dtype=torch.long, device=device),
        torch.tensor([row[2] for row in rows], dtype=torch.long, device=device),
        torch.tensor([row[3] for row in rows], dtype=torch.float32, device=device),
        torch.tensor([row[4][1] + featurizer.max_radius for row in rows], dtype=torch.long, device=device),
        torch.tensor([row[4][0] + featurizer.max_radius for row in rows], dtype=torch.long, device=device),
        unit_to_index,
    )


def _candidate_entity_indices(
    actions: tuple[dict[str, Any], ...], unit_to_index: dict[int, int], device: torch.device
) -> torch.Tensor:
    return torch.tensor(
        [unit_to_index.get(int(action.get("unit_id", -1)), -1) for action in actions],
        dtype=torch.long,
        device=device,
    )


def _score_example(
    head: SpatialEntityJointPlanPolicyHead,
    value_model: HexValueNet,
    encoder: HexStateEncoder,
    action_featurizer: ActionFeaturizer,
    entity_featurizer: UnitEntityFeaturizer,
    example: PolicyExample,
    device: torch.device,
) -> torch.Tensor:
    state_features, spatial_features, valid_mask = _state_inputs(value_model, encoder, example, device)
    prefix = _action_tensors(action_featurizer, example.state, example.prefix_actions, device)
    candidates = _action_tensors(action_featurizer, example.state, example.candidate_actions, device)
    entity_tensors = _entity_tensors(
        entity_featurizer, example.state, example.perspective_group, device
    )
    entity_type_ids, entity_relation_ids, entity_numeric, entity_rows, entity_cols, unit_to_index = entity_tensors
    candidate_entities = _candidate_entity_indices(example.candidate_actions, unit_to_index, device)
    return head(
        state_features,
        spatial_features,
        valid_mask,
        entity_type_ids,
        entity_relation_ids,
        entity_numeric,
        entity_rows,
        entity_cols,
        *prefix,
        *candidates,
        candidate_entities,
    )


def _accuracy(
    head: SpatialEntityJointPlanPolicyHead,
    value_model: HexValueNet,
    encoder: HexStateEncoder,
    action_featurizer: ActionFeaturizer,
    entity_featurizer: UnitEntityFeaturizer,
    examples: list[PolicyExample],
    device: torch.device,
) -> float:
    if not examples:
        return 0.0
    correct = 0
    head.eval()
    with torch.no_grad():
        for example in examples:
            logits = _score_example(
                head, value_model, encoder, action_featurizer, entity_featurizer, example, device
            )
            correct += int(int(logits.argmax().item()) == example.target_index)
    return correct / len(examples)


def _policy_loss(logits: torch.Tensor, example: PolicyExample) -> torch.Tensor:
    target = torch.tensor(example.target_distribution, dtype=logits.dtype, device=logits.device)
    if target.numel() != logits.numel():
        raise ValueError("policy target distribution does not match candidate count")
    return -(target * F.log_softmax(logits, dim=0)).sum()


def train(args: argparse.Namespace) -> dict[str, Any]:
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device(args.device)

    decisions = _load_jsonl(args.search_decisions)
    audit(decisions)
    checkpoint = torch.load(args.base_checkpoint, map_location=device, weights_only=False)
    base_training = checkpoint.get("training_config", {})
    heldout_ids = base_training.get("validation_game_ids")
    if heldout_ids is not None:
        heldout = set(heldout_ids)
        trained = set(base_training.get("training_game_ids", []))
        train_rows = [r for r in decisions if str(r.get("game_id")) in trained]
        eval_rows = [r for r in decisions if str(r.get("game_id")) in heldout]
        if {r["game_id"] for r in train_rows} & {r["game_id"] for r in eval_rows}:
            raise ValueError("base model contains overlapping game splits")
    else:
        train_rows, eval_rows = split_decisions(decisions, args.validation_fraction, args.seed)
    train_examples = [e for r in train_rows for e in build_policy_examples(r)]
    eval_examples = [e for r in eval_rows for e in build_policy_examples(r)]
    examples = train_examples + eval_examples
    if len(examples) < 2:
        raise ValueError("need at least two autoregressive policy examples")
    action_vocab, unit_vocab = build_vocab(train_rows)
    if not train_examples or not eval_examples:
        raise ValueError("both game-disjoint splits require preference examples")

    encoder = make_encoder(checkpoint["model_config"].get("encoder_version", 1))
    value_model = _load_value_model(checkpoint, device)
    config = checkpoint["model_config"]
    spatial_feature_size = int(config["hidden_channels"])
    state_feature_size = spatial_feature_size + encoder.global_features
    action_featurizer = ActionFeaturizer(action_vocab, unit_vocab, max_radius=encoder.max_radius)
    entity_featurizer = UnitEntityFeaturizer(unit_vocab, max_radius=encoder.max_radius)
    head = SpatialEntityJointPlanPolicyHead(
        state_feature_size=state_feature_size,
        spatial_feature_size=spatial_feature_size,
        action_vocab_size=len(action_vocab),
        unit_vocab_size=len(unit_vocab),
        max_radius=encoder.max_radius,
        token_dim=args.token_dim,
        action_hidden=args.action_hidden,
        prefix_hidden=args.prefix_hidden,
        entity_dim=args.entity_dim,
        relation_dim=args.relation_dim,
        spatial_hidden=args.spatial_hidden,
        attention_dim=args.attention_dim,
        spatial_context_dim=args.spatial_context_dim,
    ).to(device)
    optimizer = torch.optim.AdamW(head.parameters(), lr=args.learning_rate, weight_decay=args.weight_decay)

    order = list(range(len(train_examples)))
    for _epoch in range(args.epochs):
        random.shuffle(order)
        head.train()
        optimizer.zero_grad(set_to_none=True)
        pending = 0
        for index in order:
            example = train_examples[index]
            logits = _score_example(
                head, value_model, encoder, action_featurizer, entity_featurizer, example, device
            )
            loss = _policy_loss(logits, example) / float(args.accumulate_groups)
            loss.backward()
            pending += 1
            if pending == args.accumulate_groups:
                optimizer.step()
                optimizer.zero_grad(set_to_none=True)
                pending = 0
        if pending:
            optimizer.step()
            optimizer.zero_grad(set_to_none=True)

    mcts_rows = sum(1 for r in decisions if r.get("mcts_visit_distribution"))
    robust_rows = len(decisions) - mcts_rows
    soft_examples = sum(1 for e in examples if e.target_probabilities is not None)
    metrics = {
        "search_decisions": len(decisions),
        "mcts_visit_decisions": mcts_rows,
        "robust_distillation_decisions": robust_rows,
        "train_game_ids": sorted({r["game_id"] for r in train_rows}),
        "eval_game_ids": sorted({r["game_id"] for r in eval_rows}),
        "prefix_training_examples": len(examples),
        "soft_visit_prefix_examples": soft_examples,
        "train_examples": len(train_examples),
        "eval_examples": len(eval_examples),
        "train_top1_accuracy": _accuracy(
            head, value_model, encoder, action_featurizer, entity_featurizer, train_examples, device
        ),
        "eval_top1_accuracy": _accuracy(
            head, value_model, encoder, action_featurizer, entity_featurizer, eval_examples, device
        ),
        "action_vocab_size": len(action_vocab),
        "unit_vocab_size": len(unit_vocab),
        "policy_parameters": sum(parameter.numel() for parameter in head.parameters()),
        "architecture": "spatial_entity_attention_v1",
    }

    target_kind = "mcts_visit_distribution" if mcts_rows and not robust_rows else (
        "mixed_mcts_visits_and_robust_search" if mcts_rows else "best_robust_searched_continuation"
    )
    output = dict(checkpoint)
    output["joint_plan_policy_config"] = {
        "version": 3,
        "architecture": "spatial_entity_attention_v1",
        "state_feature_size": state_feature_size,
        "spatial_feature_size": spatial_feature_size,
        "action_vocab": action_vocab,
        "unit_vocab": unit_vocab,
        "max_radius": encoder.max_radius,
        "token_dim": args.token_dim,
        "action_hidden": args.action_hidden,
        "prefix_hidden": args.prefix_hidden,
        "entity_dim": args.entity_dim,
        "relation_dim": args.relation_dim,
        "spatial_hidden": args.spatial_hidden,
        "attention_dim": args.attention_dim,
        "spatial_context_dim": args.spatial_context_dim,
        "target": target_kind,
        "explicit_action_mechanics": False,
    }
    output["joint_plan_policy_state_dict"] = head.state_dict()
    output["joint_plan_policy_metrics"] = metrics
    output["joint_plan_training_config"] = {
        "epochs": args.epochs, "seed": args.seed,
        "learning_rate": args.learning_rate, "weight_decay": args.weight_decay,
        "backbone_frozen": True,
        "base_checkpoint": str(args.base_checkpoint),
        "search_decisions": [str(path) for path in args.search_decisions],
        "split_aligned_with_value_model": heldout_ids is not None,
        "supports_soft_mcts_visit_targets": True,
        "spatial_entity_policy": True,
        "explicit_action_mechanics": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(output, args.output)
    print(json.dumps(metrics, indent=2))
    return metrics


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Train spatial/entity autoregressive policy from robust search or MCTS visits")
    parser.add_argument("--base-checkpoint", type=Path, required=True)
    parser.add_argument("--search-decisions", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--validation-fraction", type=float, default=0.2)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--accumulate-groups", type=int, default=16)
    parser.add_argument("--token-dim", type=int, default=16)
    parser.add_argument("--action-hidden", type=int, default=32)
    parser.add_argument("--prefix-hidden", type=int, default=32)
    parser.add_argument("--entity-dim", type=int, default=32)
    parser.add_argument("--relation-dim", type=int, default=8)
    parser.add_argument("--spatial-hidden", type=int, default=32)
    parser.add_argument("--attention-dim", type=int, default=32)
    parser.add_argument("--spatial-context-dim", type=int, default=32)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="cpu")
    return parser


def main() -> None:
    train(build_parser().parse_args())


if __name__ == "__main__":
    main()
