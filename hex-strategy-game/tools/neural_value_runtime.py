#!/usr/bin/env python3
"""Persistent stdin/stdout server for neural value and joint-plan policy inference."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

import torch

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from ml.value_model.data import SCHEMA_VERSION, HexStateEncoder
from ml.value_model.joint_plan_policy import (
    ActionFeaturizer,
    JointPlanPolicyHead,
    SpatialEntityJointPlanPolicyHead,
    UnitEntityFeaturizer,
)
from ml.value_model.model import HexValueNet
from ml.value_model.strategic_state import make_encoder


JointPolicy = JointPlanPolicyHead | SpatialEntityJointPlanPolicyHead


def load_model(
    checkpoint_path: str | Path, device: torch.device
) -> tuple[HexValueNet, HexStateEncoder, str]:
    checkpoint = torch.load(checkpoint_path, map_location=device, weights_only=True)
    config = checkpoint.get("model_config", {})
    encoder = make_encoder(config.get("encoder_version", 1))
    expected = {
        "board_channels": encoder.board_channels,
        "global_features": encoder.global_features,
        "board_size": encoder.board_size,
        "max_radius": encoder.max_radius,
        "unit_types": list(encoder.unit_types),
    }
    for key, value in expected.items():
        if config.get(key) != value:
            raise ValueError(f"checkpoint {key} does not match encoder: {config.get(key)!r} != {value!r}")

    has_policy_head = bool(config.get("policy_head", False))
    search_head = str(config.get("search_head", "value"))
    if search_head not in {"value", "policy"}:
        raise ValueError(f"unsupported search_head: {search_head!r}")
    if search_head == "policy" and not has_policy_head:
        raise ValueError("search_head='policy' requires policy_head=True")

    model = HexValueNet(
        board_channels=int(config["board_channels"]),
        global_features=int(config["global_features"]),
        hidden_channels=int(config["hidden_channels"]),
        residual_blocks=int(config["residual_blocks"]),
        policy_head=has_policy_head,
    ).to(device)
    if has_policy_head:
        incompatible = model.load_state_dict(checkpoint["model_state_dict"], strict=False)
        expected_missing = {key for key in model.state_dict() if key.startswith("policy_head.")}
        if set(incompatible.missing_keys) != expected_missing or incompatible.unexpected_keys:
            raise ValueError(
                f"base checkpoint state mismatch: missing={sorted(incompatible.missing_keys)}, "
                f"unexpected={sorted(incompatible.unexpected_keys)}"
            )
        policy_state = checkpoint.get("policy_head_state_dict")
        if not isinstance(policy_state, dict):
            raise ValueError("policy-head checkpoint is missing policy_head_state_dict")
        assert model.policy_head is not None
        model.policy_head.load_state_dict(policy_state)
    else:
        model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()
    return model, encoder, search_head


def load_joint_policy(
    checkpoint_path: str | Path,
    encoder: HexStateEncoder,
    device: torch.device,
) -> tuple[JointPolicy | None, ActionFeaturizer | None, UnitEntityFeaturizer | None]:
    checkpoint = torch.load(checkpoint_path, map_location=device, weights_only=True)
    config = checkpoint.get("joint_plan_policy_config")
    state = checkpoint.get("joint_plan_policy_state_dict")
    if not isinstance(config, dict) or not isinstance(state, dict):
        return None, None, None
    version = int(config.get("version", 0))
    if version not in {1, 2, 3}:
        raise ValueError("unsupported joint-plan policy version")
    action_vocab = [str(item) for item in config.get("action_vocab", [])]
    unit_vocab = [str(item) for item in config.get("unit_vocab", [])]
    if not action_vocab or not unit_vocab:
        raise ValueError("joint-plan policy vocab is empty")

    max_radius = int(config.get("max_radius", encoder.max_radius))
    if version in {1, 2}:
        # V2 changed supervision metadata only; architecture is identical to V1.
        head: JointPolicy = JointPlanPolicyHead(
            state_feature_size=int(config["state_feature_size"]),
            action_vocab_size=len(action_vocab),
            unit_vocab_size=len(unit_vocab),
            token_dim=int(config.get("token_dim", 16)),
            action_hidden=int(config.get("action_hidden", 32)),
            prefix_hidden=int(config.get("prefix_hidden", 32)),
        ).to(device)
        entity_featurizer = None
    else:
        if str(config.get("architecture", "")) != "spatial_entity_attention_v1":
            raise ValueError("unsupported V3 joint-plan policy architecture")
        head = SpatialEntityJointPlanPolicyHead(
            state_feature_size=int(config["state_feature_size"]),
            spatial_feature_size=int(config["spatial_feature_size"]),
            action_vocab_size=len(action_vocab),
            unit_vocab_size=len(unit_vocab),
            max_radius=max_radius,
            token_dim=int(config.get("token_dim", 16)),
            action_hidden=int(config.get("action_hidden", 32)),
            prefix_hidden=int(config.get("prefix_hidden", 32)),
            entity_dim=int(config.get("entity_dim", 32)),
            relation_dim=int(config.get("relation_dim", 8)),
            spatial_hidden=int(config.get("spatial_hidden", 32)),
            attention_dim=int(config.get("attention_dim", 32)),
            spatial_context_dim=int(config.get("spatial_context_dim", 32)),
        ).to(device)
        entity_featurizer = UnitEntityFeaturizer(unit_vocab, max_radius=max_radius)
    head.load_state_dict(state)
    head.eval()
    action_featurizer = ActionFeaturizer(action_vocab, unit_vocab, max_radius)
    return head, action_featurizer, entity_featurizer


def request_example(request: dict[str, Any]) -> dict[str, Any]:
    state = request.get("state")
    if not isinstance(state, dict):
        raise ValueError("state must be an object")
    perspective = str(request.get("perspective_group", ""))
    opponent = str(request.get("opponent_group", ""))
    if not perspective or not opponent or perspective == opponent:
        raise ValueError("distinct perspective_group and opponent_group are required")
    return {
        "schema_version": SCHEMA_VERSION,
        "perspective_group": perspective,
        "opponent_group": opponent,
        "turn_index": int(request.get("turn_index", state.get("turn_index", 0))),
        "terminal": bool(request.get("terminal", False)),
        "outcome": 0.0,
        "state": state,
    }


def score_requests(
    model: HexValueNet,
    encoder: HexStateEncoder,
    requests: list[dict[str, Any]],
    device: torch.device,
    search_head: str = "value",
) -> tuple[list[float], dict[str, float]]:
    started = time.perf_counter()
    encoded = [encoder.encode(request_example(request)) for request in requests]
    encoded_done = time.perf_counter()
    if not encoded:
        return [], {"encode_ms": 0.0, "inference_ms": 0.0, "total_ms": 0.0}
    boards = torch.stack([item.board for item in encoded], dim=0).to(device)
    globals_ = torch.stack([item.global_features for item in encoded], dim=0).to(device)
    with torch.no_grad():
        values = (
            model.policy_score(boards, globals_).reshape(-1)
            if search_head == "policy"
            else model(boards, globals_).reshape(-1)
        )
    inference_done = time.perf_counter()
    return [float(value.item()) for value in values], {
        "encode_ms": (encoded_done - started) * 1000.0,
        "inference_ms": (inference_done - encoded_done) * 1000.0,
        "total_ms": (inference_done - started) * 1000.0,
    }


def _action_tensors(
    featurizer: ActionFeaturizer,
    state: dict[str, Any],
    actions: list[dict[str, Any]],
    device: torch.device,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    rows = [featurizer.encode(state, action) for action in actions]
    if not rows:
        return (
            torch.empty((0,), dtype=torch.long, device=device),
            torch.empty((0,), dtype=torch.long, device=device),
            torch.empty((0, ActionFeaturizer.NUMERIC_FEATURES), dtype=torch.float32, device=device),
        )
    return (
        torch.tensor([row[0] for row in rows], dtype=torch.long, device=device),
        torch.tensor([row[1] for row in rows], dtype=torch.long, device=device),
        torch.tensor([row[2] for row in rows], dtype=torch.float32, device=device),
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
    actions: list[dict[str, Any]], unit_to_index: dict[int, int], device: torch.device
) -> torch.Tensor:
    return torch.tensor(
        [unit_to_index.get(int(action.get("unit_id", -1)), -1) for action in actions],
        dtype=torch.long,
        device=device,
    )


def score_joint_actions(
    value_model: HexValueNet,
    joint_policy: JointPolicy,
    action_featurizer: ActionFeaturizer,
    entity_featurizer: UnitEntityFeaturizer | None,
    encoder: HexStateEncoder,
    request: dict[str, Any],
    device: torch.device,
) -> list[float]:
    state = request.get("state")
    prefix = request.get("prefix_actions", [])
    candidates = request.get("candidate_actions", [])
    if not isinstance(state, dict) or not isinstance(prefix, list) or not isinstance(candidates, list):
        raise ValueError("joint policy requires state, prefix_actions, and candidate_actions")
    if not candidates or not all(isinstance(action, dict) for action in candidates):
        raise ValueError("candidate_actions must be a non-empty array of objects")
    if not all(isinstance(action, dict) for action in prefix):
        raise ValueError("prefix_actions must contain objects")

    request_row = request_example(request)
    encoded = encoder.encode(request_row)
    board = encoded.board.unsqueeze(0).to(device)
    globals_ = encoded.global_features.unsqueeze(0).to(device)
    with torch.no_grad():
        prefix_tensors = _action_tensors(action_featurizer, state, prefix, device)
        candidate_tensors = _action_tensors(action_featurizer, state, candidates, device)
        if isinstance(joint_policy, SpatialEntityJointPlanPolicyHead):
            if entity_featurizer is None:
                raise ValueError("spatial/entity policy is missing entity featurizer")
            spatial, valid_mask, state_features = value_model.encode_spatial(board, globals_)
            entity_type_ids, entity_relation_ids, entity_numeric, entity_rows, entity_cols, unit_to_index = _entity_tensors(
                entity_featurizer, state, str(request_row["perspective_group"]), device
            )
            candidate_entities = _candidate_entity_indices(candidates, unit_to_index, device)
            logits = joint_policy(
                state_features,
                spatial,
                valid_mask,
                entity_type_ids,
                entity_relation_ids,
                entity_numeric,
                entity_rows,
                entity_cols,
                *prefix_tensors,
                *candidate_tensors,
                candidate_entities,
            )
        else:
            state_features = value_model._features(board, globals_)
            logits = joint_policy(state_features, *prefix_tensors, *candidate_tensors)
    return [float(value.item()) for value in logits]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    args = parser.parse_args()
    torch.set_num_threads(1)
    device = torch.device("cpu")
    try:
        model, encoder, search_head = load_model(args.checkpoint, device)
        joint_policy, joint_action_featurizer, joint_entity_featurizer = load_joint_policy(
            args.checkpoint, encoder, device
        )
    except Exception as exc:
        print(json.dumps({"ready": False, "error": f"{type(exc).__name__}: {exc}"}), flush=True)
        return 2

    print(json.dumps({
        "ready": True,
        "board_channels": encoder.board_channels,
        "global_features": encoder.global_features,
        "batch_protocol": 1,
        "search_head": search_head,
        "policy_head": model.policy_head is not None,
        "joint_plan_policy": joint_policy is not None,
        "joint_plan_policy_spatial_entities": isinstance(joint_policy, SpatialEntityJointPlanPolicyHead),
    }), flush=True)

    for raw_line in sys.stdin:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            request = json.loads(raw_line)
            if not isinstance(request, dict):
                raise ValueError("request must be an object")
            if str(request.get("op", "")) == "score_joint_actions":
                if joint_policy is None or joint_action_featurizer is None:
                    response = {"ok": False, "unsupported": True, "error": "joint_plan_policy_unavailable"}
                else:
                    started = time.perf_counter()
                    scores = score_joint_actions(
                        model,
                        joint_policy,
                        joint_action_featurizer,
                        joint_entity_featurizer,
                        encoder,
                        request,
                        device,
                    )
                    response = {
                        "ok": True,
                        "scores": scores,
                        "candidate_count": len(scores),
                        "timing_ms": {"total_ms": (time.perf_counter() - started) * 1000.0},
                    }
            else:
                batch = request.get("requests")
                if batch is not None:
                    if not isinstance(batch, list) or not all(isinstance(item, dict) for item in batch):
                        raise ValueError("requests must be an array of objects")
                    values, timing = score_requests(model, encoder, batch, device, search_head)
                    response = {"ok": True, "values": values, "batch_size": len(values), "timing_ms": timing}
                else:
                    values, timing = score_requests(model, encoder, [request], device, search_head)
                    response = {"ok": True, "value": values[0], "batch_size": 1, "timing_ms": timing}
        except Exception as exc:
            response = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
        print(json.dumps(response, separators=(",", ":")), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
