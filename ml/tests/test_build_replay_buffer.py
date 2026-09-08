from __future__ import annotations

import unittest

from ml.value_model.build_replay_buffer import build_replay, build_ranking_replay


def example(policy: str, scenario: str, arena_preset: str = "") -> dict:
    source = {
        "data_policy": policy,
        "base_scenario_id": scenario,
    }
    if arena_preset:
        source["arena_preset"] = arena_preset
    return {"game_id": f"{policy}-{scenario}", "source": source}


class BuildReplayBufferTests(unittest.TestCase):
    def test_prefers_new_examples_and_caps_buffer(self) -> None:
        new = [example("current_self_play", f"new-{i}") for i in range(6)]
        history = [example("handwritten", f"old-{i}") for i in range(6)]
        rows, manifest = build_replay(new, history, max_examples=5, seed=7)
        self.assertEqual(5, len(rows))
        self.assertTrue(all(row["source"]["data_policy"] == "current_self_play" for row in rows))
        self.assertEqual(5, manifest["new_examples_selected"])
        self.assertEqual(0, manifest["history_examples_selected"])

    def test_fills_from_history_after_removing_frozen_arena_rows(self) -> None:
        new = [example("current_self_play", "new")]
        history = [
            example("neural_vs_handwritten", "arena", arena_preset="fast"),
            example("handwritten", "keep-a"),
            example("handwritten", "keep-b"),
        ]
        rows, manifest = build_replay(new, history, max_examples=3, seed=0)
        self.assertEqual(3, len(rows))
        self.assertEqual(1, manifest["history_examples_excluded_frozen_arena"])
        self.assertFalse(any(row["source"].get("arena_preset") for row in rows))

    def test_ranking_replay_drops_arena_and_tactical_pairs(self) -> None:
        pairs = [
            {"pair_kind": "outcome", "source": {"data_origin": "arena_divergence_hard_negative"}},
            {"pair_kind": "outcome", "source": {"tactical_focus_reweight": {"multiplier": 4}}},
            {"pair_kind": "faster_win", "source": {"base_scenario_id": "mixed_force"}},
        ]
        rows, manifest = build_ranking_replay(pairs, max_pairs=10)
        self.assertEqual(1, len(rows))
        self.assertEqual("faster_win", rows[0]["pair_kind"])
        self.assertEqual(2, manifest["history_pairs_excluded_frozen_arena"])


if __name__ == "__main__":
    unittest.main()
