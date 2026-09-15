from __future__ import annotations

import unittest

from ml.value_model.robust_policy_targets import build_tie_aware_search_distillation_examples


def _action(q: int, r: int) -> dict:
    return {"unit_id": 1, "action_key": "attack_short", "path": [], "end_point": [q, r]}


def _decision(scores: list[float]) -> dict:
    endpoints = [[1, 0], [0, 1], [-1, 1]]
    return {
        "starting_state": {
            "groups": [
                {
                    "name": "terran",
                    "units": [
                        {
                            "unit_id": 1,
                            "health": 3,
                            "cell": [0, 0],
                            "def_path": "res://src/unit/definitions/marine.tres",
                        }
                    ],
                },
                {"name": "zerg", "units": []},
            ]
        },
        "perspective_group": "terran",
        "opponent_group": "zerg",
        "candidates": [
            {
                "actions": [_action(*endpoint)],
                "handwritten_worst_case_score": score,
            }
            for endpoint, score in zip(endpoints, scores)
        ],
    }


class RobustPolicyTieTargetsTest(unittest.TestCase):
    def test_two_tied_best_share_probability(self) -> None:
        examples = build_tie_aware_search_distillation_examples(_decision([10.0, 10.0, 0.0]))
        self.assertEqual(len(examples), 1)
        example = examples[0]
        by_endpoint = {
            tuple(action["end_point"]): probability
            for action, probability in zip(example.candidate_actions, example.target_distribution)
        }
        self.assertAlmostEqual(by_endpoint[(1, 0)], 0.5)
        self.assertAlmostEqual(by_endpoint[(0, 1)], 0.5)
        self.assertAlmostEqual(by_endpoint[(-1, 1)], 0.0)

    def test_all_tied_prefix_is_skipped(self) -> None:
        examples = build_tie_aware_search_distillation_examples(_decision([5.0, 5.0, 5.0]))
        self.assertEqual(examples, [])

    def test_unique_best_remains_one_hot(self) -> None:
        examples = build_tie_aware_search_distillation_examples(_decision([1.0, 3.0, 2.0]))
        self.assertEqual(len(examples), 1)
        example = examples[0]
        by_endpoint = {
            tuple(action["end_point"]): probability
            for action, probability in zip(example.candidate_actions, example.target_distribution)
        }
        self.assertAlmostEqual(by_endpoint[(0, 1)], 1.0)
        self.assertAlmostEqual(sum(example.target_distribution), 1.0)


if __name__ == "__main__":
    unittest.main()
