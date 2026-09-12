#!/usr/bin/env python3
"""Persistent stdin/stdout server for the experimental Godot neural evaluator."""

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
from ml.value_model.model import HexValueNet


def load_model(
    checkpoint_path: str | Path, device: torch.device
) -> tuple[HexValueNet, HexStateEncoder, str]:
    checkpoint = torch.load(checkpoint_path, map_location=device, weights_only=True)
    config = checkpoint.get("model_config", {})
    encoder = HexStateEncoder()
    expected = {
        "board_channels": encoder.board_channels,
        "global_features": encoder.global_features,
        "board_size": encoder.board_size,
        "max_radius": encoder.max_radius,
        "unit_types": list(encoder.unit_types),
    }
    for key, value in expected.items():
        if config.get(key) != value:
            raise ValueError(
                f"checkpoint {key} does not match encoder: "
                f"{config.get(key)!r} != {value!r}"
            )

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
        incompatible = model.load_state_dict(
            checkpoint["model_state_dict"], strict=False
        )
        missing = set(incompatible.missing_keys)
        unexpected = set(incompatible.unexpected_keys)
        expected_missing = {
            key for key in model.state_dict() if key.startswith("policy_head.")
        }
        if missing != expected_missing or unexpected:
            raise ValueError(
                "base checkpoint state mismatch: "
                f"missing={sorted(missing)}, unexpected={sorted(unexpected)}"
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
        if search_head == "policy":
            values = model.policy_score(boards, globals_).reshape(-1)
        else:
            values = model(boards, globals_).reshape(-1)
    inference_done = time.perf_counter()
    return [float(value.item()) for value in values], {
        "encode_ms": (encoded_done - started) * 1000.0,
        "inference_ms": (inference_done - encoded_done) * 1000.0,
        "total_ms": (inference_done - started) * 1000.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    args = parser.parse_args()

    torch.set_num_threads(1)
    device = torch.device("cpu")
    try:
        model, encoder, search_head = load_model(args.checkpoint, device)
    except Exception as exc:
        print(json.dumps({"ready": False, "error": f"{type(exc).__name__}: {exc}"}), flush=True)
        return 2

    print(
        json.dumps(
            {
                "ready": True,
                "board_channels": encoder.board_channels,
                "global_features": encoder.global_features,
                "batch_protocol": 1,
                "search_head": search_head,
                "policy_head": model.policy_head is not None,
            }
        ),
        flush=True,
    )
    for raw_line in sys.stdin:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            request = json.loads(raw_line)
            if not isinstance(request, dict):
                raise ValueError("request must be an object")
            batch = request.get("requests")
            if batch is not None:
                if not isinstance(batch, list) or not all(isinstance(item, dict) for item in batch):
                    raise ValueError("requests must be an array of objects")
                values, timing = score_requests(
                    model, encoder, batch, device, search_head=search_head
                )
                response = {
                    "ok": True,
                    "values": values,
                    "batch_size": len(values),
                    "timing_ms": timing,
                }
            else:
                values, timing = score_requests(
                    model, encoder, [request], device, search_head=search_head
                )
                response = {
                    "ok": True,
                    "value": values[0],
                    "batch_size": 1,
                    "timing_ms": timing,
                }
        except Exception as exc:
            response = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
        print(json.dumps(response, separators=(",", ":")), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
