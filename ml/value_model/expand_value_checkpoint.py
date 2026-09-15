from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from torch import nn

from .model import HexValueNet


def expand_checkpoint(input_path: Path, output_path: Path, residual_blocks: int) -> dict:
    checkpoint = torch.load(input_path, map_location="cpu", weights_only=False)
    config = dict(checkpoint["model_config"])
    old_blocks = int(config["residual_blocks"])
    if residual_blocks <= old_blocks:
        raise ValueError(f"target residual blocks must exceed current {old_blocks}")

    model = HexValueNet(
        board_channels=int(config["board_channels"]),
        global_features=int(config["global_features"]),
        hidden_channels=int(config["hidden_channels"]),
        residual_blocks=residual_blocks,
        policy_head=bool(config.get("policy_head", False)),
    )

    # Make every newly added residual block an exact identity at initialization.
    # The input to these blocks is already post-ReLU/non-negative, so zeroing the
    # final BN scale and bias makes ReLU(x + 0) preserve the champion features.
    for block_index in range(old_blocks, residual_blocks):
        block = model.body[block_index]
        final_bn = block.block[4]
        if not isinstance(final_bn, nn.BatchNorm2d):
            raise TypeError("unexpected residual block layout")
        nn.init.zeros_(final_bn.weight)
        nn.init.zeros_(final_bn.bias)

    incompatible = model.load_state_dict(checkpoint["model_state_dict"], strict=False)
    unexpected = list(incompatible.unexpected_keys)
    allowed_prefixes = tuple(f"body.{index}." for index in range(old_blocks, residual_blocks))
    illegal_missing = [key for key in incompatible.missing_keys if not key.startswith(allowed_prefixes)]
    if unexpected or illegal_missing:
        raise ValueError(
            f"expanded checkpoint incompatible: missing={illegal_missing}, unexpected={unexpected}"
        )

    # Verify the only missing tensors belong to the newly added residual blocks.
    if not incompatible.missing_keys:
        raise ValueError("expansion unexpectedly loaded without new parameters")

    output = dict(checkpoint)
    config["residual_blocks"] = residual_blocks
    output["model_config"] = config
    output["model_state_dict"] = model.state_dict()
    output["capacity_ablation"] = {
        "type": "value_residual_depth",
        "source_residual_blocks": old_blocks,
        "target_residual_blocks": residual_blocks,
        "hidden_channels_unchanged": int(config["hidden_channels"]),
        "new_blocks_identity_initialized": True,
        "policy_architecture_unchanged": True,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    torch.save(output, output_path)
    metadata = dict(output["capacity_ablation"])
    metadata["output"] = str(output_path)
    metadata["parameter_count"] = sum(parameter.numel() for parameter in model.parameters())
    print(json.dumps(metadata, sort_keys=True))
    return metadata


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Identity-expand a value checkpoint for a capacity ablation")
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--residual-blocks", type=int, required=True)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    expand_checkpoint(args.input, args.output, args.residual_blocks)


if __name__ == "__main__":
    main()
