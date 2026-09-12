from __future__ import annotations

"""Warm-start wrapper for iterative ranked value-model training.

The existing train_ranked entry point intentionally creates a fresh model.  Iterative
self-play needs the learner at cycle N+1 to continue from cycle N while still using
exactly the same loss, split, optimizer, checkpoint format, and metrics code.
"""

import argparse
from pathlib import Path

import torch

from . import train_ranked
from .model import HexValueNet


class WarmStartHexValueNet(HexValueNet):
    """HexValueNet that restores the parent value/search heads at construction."""

    init_checkpoint: str | None = None

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        path = self.init_checkpoint
        if not path:
            return

        checkpoint_path = Path(path)
        if not checkpoint_path.is_file():
            raise FileNotFoundError(f"warm-start checkpoint not found: {checkpoint_path}")

        checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
        base_state = checkpoint.get("model_state_dict")
        if not isinstance(base_state, dict):
            raise ValueError("warm-start checkpoint is missing model_state_dict")

        incompatible = self.load_state_dict(base_state, strict=False)
        unexpected = list(incompatible.unexpected_keys)
        missing = [key for key in incompatible.missing_keys if not key.startswith("policy_head.")]
        if unexpected or missing:
            raise ValueError(
                "warm-start checkpoint is incompatible with the current model: "
                f"missing={missing}, unexpected={unexpected}"
            )

        policy_state = checkpoint.get("policy_head_state_dict")
        if self.policy_head is not None and isinstance(policy_state, dict):
            self.policy_head.load_state_dict(policy_state, strict=True)


def build_parser() -> argparse.ArgumentParser:
    parser = train_ranked.build_parser()
    parser.description = (
        "Continue ranked value/search-head training from a parent checkpoint for "
        "iterative self-play experiments."
    )
    parser.add_argument(
        "--init-checkpoint",
        required=True,
        help="Parent ranked_value_model.pt used to initialize value and policy heads.",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()
    WarmStartHexValueNet.init_checkpoint = args.init_checkpoint
    # train_ranked resolves HexValueNet from its module global when train() runs,
    # so swapping only that constructor keeps all training/evaluation logic shared.
    train_ranked.HexValueNet = WarmStartHexValueNet
    train_ranked.train(args)


if __name__ == "__main__":
    main()
