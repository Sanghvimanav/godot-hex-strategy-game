import unittest
from ml.value_model.phase_one_gate import score_group, promotion_report


def manifest(wins=15, losses=5, draws=0, unresolved=0, unfamiliar=False):
    outcomes = ["challenger"] * wins + ["champion"] * losses + ["draw"] * draws + ["unresolved"] * unresolved
    return {
        "preset": "phase1_unfamiliar" if unfamiliar else "phase1_familiar",
        "map_profile": "phase1_unfamiliar_v1" if unfamiliar else "compact_v1",
        "rules_version": "frozen-commit", "decision_time_budget_ms": 30000,
        "runner_type": "ubuntu-latest", "checkpoint_sha256": "checkpoint-hash",
        "champion_evaluator": "handwritten", "challenger_evaluator": "neural",
        "games": [{"game_id": f"game-{i}", "pair_id": f"pair-{i//2}",
            "challenger_group": "terran" if i % 2 == 0 else "zerg", "valid": True,
            "winner_agent": outcome, "champion_search": {"max_elapsed_ms": 1500},
            "challenger_search": {"max_elapsed_ms": 2500}} for i, outcome in enumerate(outcomes)],
    }


class PhaseOneGateTests(unittest.TestCase):
    def test_draws_cannot_inflate_win_rate(self):
        result = score_group(manifest(8, 2, 2, 8), "phase1_familiar")
        self.assertEqual(result["resolved"], 12)
        self.assertFalse(result["passed"])

    def test_minimum_resolution_requires_eight_wins(self):
        self.assertTrue(score_group(manifest(8, 2, 0, 10), "phase1_familiar")["passed"])
        self.assertFalse(score_group(manifest(7, 2, 0, 11), "phase1_familiar")["passed"])

    def test_strong_familiar_cannot_hide_weak_unfamiliar(self):
        training = {"runner_type": "ubuntu-latest", "workers": 10,
            "rules_version": "frozen-commit",
            "checkpoint_sha256": "checkpoint-hash", "pipeline_elapsed_seconds": 100,
            "evaluation_excluded_from_training": True}
        self.assertTrue(promotion_report(manifest(), manifest(unfamiliar=True), training)["passed"])
        self.assertFalse(promotion_report(manifest(20, 0), manifest(10, 10, unfamiliar=True), training)["passed"])
        training["pipeline_elapsed_seconds"] = 14400
        self.assertFalse(promotion_report(manifest(), manifest(unfamiliar=True), training)["passed"])
        training["pipeline_elapsed_seconds"] = 100
        training["rules_version"] = "different-rules"
        self.assertFalse(promotion_report(manifest(), manifest(unfamiliar=True), training)["passed"])

    def test_duplicate_games_and_runtime_overrun_fail(self):
        data = manifest()
        data["games"][1]["game_id"] = data["games"][0]["game_id"]
        self.assertFalse(score_group(data, "phase1_familiar")["passed"])
        data = manifest()
        data["games"][0]["challenger_search"]["max_elapsed_ms"] = 30001
        self.assertFalse(score_group(data, "phase1_familiar")["passed"])
        data["games"][0]["challenger_search"]["max_elapsed_ms"] = float("nan")
        self.assertFalse(score_group(data, "phase1_familiar")["passed"])


if __name__ == "__main__":
    unittest.main()
