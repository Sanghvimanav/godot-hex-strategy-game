import unittest

from ml.value_model.reweight_tactical_pairs import reweight_pairs


class TacticalPairReweightTests(unittest.TestCase):
    def test_focus_family_faction_and_passivity_multipliers_are_capped(self):
        pairs = [
            {
                "game_id": "mixed_force-s1-challenger-terran",
                "turn_index": 2,
                "perspective_group": "terran",
                "weight": 1.0,
                "priority_reasons": ["arena_divergence"],
                "source": {
                    "base_scenario_id": "mixed_force",
                    "arena_game_id": "mixed_force-s1-challenger-terran",
                    "data_origin": "arena_divergence_hard_negative",
                },
            }
        ]
        divergences = [
            {
                "game_id": "mixed_force-s1-challenger-terran",
                "turn_index": 2,
                "neural_actions": [
                    {"action_key": "rest"},
                    {"action_key": "move"},
                ],
                "handwritten_actions": [
                    {"action_key": "attack"},
                    {"action_key": "move"},
                ],
            }
        ]

        output, manifest = reweight_pairs(
            pairs,
            divergences,
            focus_families={"mixed_force", "scout_kite", "fester_siege"},
            focus_faction="terran",
            family_multiplier=2.0,
            faction_multiplier=1.5,
            passivity_multiplier=1.5,
            max_multiplier=4.0,
        )

        self.assertEqual(output[0]["weight"], 4.0)
        self.assertEqual(manifest["pairs_reweighted"], 1)
        self.assertEqual(manifest["passivity_gap_pairs"], 1)
        self.assertIn("focus_family", output[0]["priority_reasons"])
        self.assertIn("focus_faction", output[0]["priority_reasons"])
        self.assertIn("passivity_gap", output[0]["priority_reasons"])
        metadata = output[0]["source"]["tactical_focus_reweight"]
        self.assertEqual(metadata["original_weight"], 1.0)
        self.assertEqual(metadata["multiplier"], 4.0)

    def test_non_focus_pair_remains_unchanged(self):
        pairs = [
            {
                "game_id": "attrition-s1-challenger-zerg",
                "turn_index": 0,
                "perspective_group": "zerg",
                "weight": 0.75,
                "source": {
                    "base_scenario_id": "attrition",
                    "arena_game_id": "attrition-s1-challenger-zerg",
                },
            }
        ]

        output, manifest = reweight_pairs(
            pairs,
            [],
            focus_families={"mixed_force"},
            focus_faction="terran",
            family_multiplier=2.0,
            faction_multiplier=1.5,
            passivity_multiplier=1.5,
            max_multiplier=4.0,
        )

        self.assertEqual(output[0]["weight"], 0.75)
        self.assertNotIn("tactical_focus_reweight", output[0]["source"])
        self.assertEqual(manifest["pairs_reweighted"], 0)

    def test_focus_family_on_other_faction_gets_family_multiplier_only(self):
        pairs = [
            {
                "game_id": "fester_siege-s1-challenger-zerg",
                "turn_index": 1,
                "perspective_group": "zerg",
                "weight": 1.0,
                "source": {
                    "base_scenario_id": "fester_siege",
                    "arena_game_id": "fester_siege-s1-challenger-zerg",
                },
            }
        ]

        output, manifest = reweight_pairs(
            pairs,
            [],
            focus_families={"fester_siege"},
            focus_faction="terran",
            family_multiplier=2.0,
            faction_multiplier=1.5,
            passivity_multiplier=1.5,
            max_multiplier=4.0,
        )

        self.assertEqual(output[0]["weight"], 2.0)
        self.assertEqual(manifest["focus_family_pairs"], 1)
        self.assertEqual(manifest["focus_faction_pairs"], 0)


if __name__ == "__main__":
    unittest.main()
