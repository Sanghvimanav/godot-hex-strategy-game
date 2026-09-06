from __future__ import annotations

import unittest

from ml.value_model.data import (
    ENEMY_COMMAND_HEX_CHANNEL,
    OWN_COMMAND_HEX_CHANNEL,
    HexStateEncoder,
)


def _unit(unit_id: int, kind: str, cell: list[int]) -> dict:
    return {
        "unit_id": unit_id,
        "def_path": f"res://src/unit/definitions/{kind}.tres",
        "cell": cell,
        "health": 2,
        "max_health": 2,
        "energy": 0,
        "max_energy": 0,
    }


def _example(perspective: str) -> dict:
    opponent = "terran" if perspective == "zerg" else "zerg"
    return {
        "schema_version": 1,
        "game_id": "objective-test",
        "turn_index": 0,
        "perspective_group": perspective,
        "opponent_group": opponent,
        "outcome": 1.0,
        "terminal": False,
        "winner": perspective,
        "source": {"base_scenario_id": "objective-test"},
        "state": {
            "scenario_id": "objective-test",
            "hex_radius": 1,
            "command_hexes": {
                "zerg": [-1, 0],
                "terran": [1, 0],
            },
            "groups": [
                {"name": "zerg", "resources": {}, "units": [_unit(1, "zergling", [0, 0])]},
                {"name": "terran", "resources": {}, "units": [_unit(2, "marine", [0, 1])]},
            ],
            "tile_resources": {},
        },
    }


class ObjectiveEncoderTests(unittest.TestCase):
    def test_command_hex_channels_are_perspective_relative(self) -> None:
        encoder = HexStateEncoder()
        zerg = encoder.encode(_example("zerg"))
        terran = encoder.encode(_example("terran"))

        zerg_command = (5, 4)   # [-1, 0]
        terran_command = (5, 6) # [1, 0]

        self.assertEqual(float(zerg.board[OWN_COMMAND_HEX_CHANNEL, *zerg_command]), 1.0)
        self.assertEqual(float(zerg.board[ENEMY_COMMAND_HEX_CHANNEL, *terran_command]), 1.0)
        self.assertEqual(float(terran.board[OWN_COMMAND_HEX_CHANNEL, *terran_command]), 1.0)
        self.assertEqual(float(terran.board[ENEMY_COMMAND_HEX_CHANNEL, *zerg_command]), 1.0)

        self.assertEqual(float(zerg.board[OWN_COMMAND_HEX_CHANNEL].sum()), 1.0)
        self.assertEqual(float(zerg.board[ENEMY_COMMAND_HEX_CHANNEL].sum()), 1.0)
        self.assertEqual(float(terran.board[OWN_COMMAND_HEX_CHANNEL].sum()), 1.0)
        self.assertEqual(float(terran.board[ENEMY_COMMAND_HEX_CHANNEL].sum()), 1.0)

    def test_states_without_command_hexes_remain_backward_compatible(self) -> None:
        example = _example("zerg")
        del example["state"]["command_hexes"]
        encoded = HexStateEncoder().encode(example)
        self.assertEqual(float(encoded.board[OWN_COMMAND_HEX_CHANNEL].sum()), 0.0)
        self.assertEqual(float(encoded.board[ENEMY_COMMAND_HEX_CHANNEL].sum()), 0.0)


if __name__ == "__main__":
    unittest.main()
