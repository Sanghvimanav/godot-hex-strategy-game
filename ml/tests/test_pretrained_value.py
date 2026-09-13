from __future__ import annotations

import unittest

from ml.pretrained_value.data import nested_group_subsample, serialize_value_example


class PretrainedValueDataTest(unittest.TestCase):
    def _example(self, perspective: str = "terran") -> dict:
        opponent = "zerg" if perspective == "terran" else "terran"
        return {
            "schema_version": 1,
            "game_id": "g1",
            "perspective_group": perspective,
            "opponent_group": opponent,
            "turn_index": 5,
            "terminal": False,
            "winner": "zerg",
            "state": {
                "hex_radius": 3,
                "command_hexes": {"terran": [3, 0], "zerg": [-3, 0]},
                "groups": [
                    {"name": "terran", "resources": {"crystal": 2}, "units": [
                        {"unit_id": 99, "def_path": "res://src/unit/definitions/marine.tres", "cell": [0, 1], "health": 2, "max_health": 4, "energy": 0, "max_energy": 0, "effects": ["secret_effect"]},
                        {"unit_id": 100, "def_path": "res://src/unit/definitions/scout.tres", "cell": [1, 0], "health": 0, "max_health": 2, "energy": 0, "max_energy": 0},
                    ]},
                    {"name": "zerg", "resources": {"crystal": 1}, "units": [
                        {"unit_id": 7, "def_path": "res://src/unit/definitions/zergling.tres", "cell": [-1, 0], "health": 3, "max_health": 3, "energy": 0, "max_energy": 0}
                    ]},
                ],
            },
        }

    def test_serializer_is_perspective_relative_and_label_clean(self) -> None:
        text = serialize_value_example(self._example("terran"))
        self.assertIn("PERSPECTIVE terran", text)
        self.assertIn("own_types=marine:1", text)
        self.assertIn("enemy_types=zergling:1", text)
        self.assertNotIn("winner", text.lower())
        self.assertNotIn("secret_effect", text)
        self.assertNotIn("unit_id", text)
        self.assertNotIn("scout", text)
        swapped = serialize_value_example(self._example("zerg"))
        self.assertIn("PERSPECTIVE zerg", swapped)
        self.assertIn("own_types=zergling:1", swapped)
        self.assertIn("enemy_types=marine:1", swapped)

    def test_nested_fraction_subsets_keep_whole_games(self) -> None:
        rows = [{"game_id": f"g{game}", "row": row} for game in range(10) for row in range(2)]
        ten = nested_group_subsample(rows, 0.10, seed=4)
        twenty_five = nested_group_subsample(rows, 0.25, seed=4)
        fifty = nested_group_subsample(rows, 0.50, seed=4)
        full = nested_group_subsample(rows, 1.0, seed=4)
        def games(population):
            return {row["game_id"] for row in population}
        self.assertTrue(games(ten) <= games(twenty_five) <= games(fifty) <= games(full))
        self.assertEqual(len(ten) % 2, 0)
        self.assertEqual(len(full), len(rows))


if __name__ == "__main__":
    unittest.main()
