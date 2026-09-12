"""Opt-in V2 planes; V1 checkpoints remain readable without reinterpretation."""
import torch
from .data import HexStateEncoder, EncodedExample, BOARD_CHANNELS, BOARD_SIZE, MAX_RADIUS, _in_hex


EXTRA_PLANES = ("own_stun", "enemy_stun", "own_pending_stun", "enemy_pending_stun",
                "own_heal_duration", "enemy_heal_duration", "own_heal_amount", "enemy_heal_amount",
                "own_pending_effect", "enemy_pending_effect", "tile_resource_amount")


class StrategicStateEncoder(HexStateEncoder):
    board_channels = BOARD_CHANNELS + len(EXTRA_PLANES)

    def encode(self, example):
        base = super().encode(example)
        extra = torch.zeros((len(EXTRA_PLANES), BOARD_SIZE, BOARD_SIZE))
        state = example["state"]
        radius = int(state.get("hex_radius", MAX_RADIUS))
        own = example["perspective_group"]
        for group in state.get("groups", []):
            side = 0 if group.get("name") == own else 1
            for unit in group.get("units", []):
                if float(unit.get("health", 0)) <= 0:
                    continue
                q, r = map(int, unit.get("cell", [0, 0]))
                if not _in_hex(q, r, radius):
                    continue
                y, x = r + MAX_RADIUS, q + MAX_RADIUS
                for effect in unit.get("effects", []):
                    duration = max(0, int(effect.get("duration", 0)))
                    if not duration:
                        continue
                    pending = bool(effect.get("pending_first_tick", False))
                    if pending:
                        extra[8 + side, y, x] += min(duration / 20, 1)
                    if effect.get("kind") == "Stun":
                        extra[(2 if pending else 0) + side, y, x] += min(duration / 20, 1)
                    if effect.get("kind") == "HealOverTime":
                        extra[4 + side, y, x] += min(duration / 20, 1)
                        amount = max(0, float(effect.get("params", {}).get("heal_per_turn", 0)))
                        extra[6 + side, y, x] += min(amount / 20, 1)
        for key, value in state.get("tile_resources", {}).items():
            parts = str(key).split(",")
            if len(parts) != 2:
                continue
            q, r = map(int, parts)
            if _in_hex(q, r, radius):
                amount = value.get("amount", value.get("resource_amount", 0)) if isinstance(value, dict) else value
                extra[10, r + MAX_RADIUS, q + MAX_RADIUS] = min(max(float(amount), 0) / 50, 1)
        return EncodedExample(torch.cat((base.board, extra), dim=0), base.global_features, base.target)


def make_encoder(version=1):
    if version == 1:
        return HexStateEncoder()
    if version == 2:
        return StrategicStateEncoder()
    raise ValueError(f"unsupported encoder version: {version}")
