from __future__ import annotations

import unittest
from copy import deepcopy

from ml.experiments.manifest import ManifestError, build_plan, validate_manifest
from ml.experiments.results import ResultContractError, build_scorecard, matching_shard_results


class ExperimentFrameworkTests(unittest.TestCase):
    def _manifest(self) -> dict:
        return {
            "schema_version": 1,
            "experiment_id": "test-experiment-v1",
            "search": {
                "own_candidates": 4,
                "opponent_responses": 5,
                "decision_budget_seconds": 25,
                "proposal_mode": "handwritten",
            },
            "seed_partitions": {
                "training": {"role": "training", "start": 1000, "count": 2},
                "diagnostic": {"role": "diagnostic", "start": 2000, "count": 4},
                "familiar": {"role": "frozen_eval", "start": 3000, "count": 20},
                "unfamiliar": {"role": "frozen_eval", "start": 4000, "count": 20},
            },
            "data_policy": {
                "training_roles": ["training"],
                "mineable_roles": ["training", "diagnostic"],
            },
            "gates": [
                {
                    "name": "decision_cap",
                    "path": "overall.timing.decision_max_ms",
                    "op": "<=",
                    "value": 30000,
                }
            ],
            "tiers": {
                "diagnostic": {
                    "partitions": ["diagnostic"],
                    "shards_per_partition": 2,
                    "promotion_eligible": False,
                    "gates": [
                        {
                            "name": "diagnostic_resolution",
                            "path": "overall.games.resolution_rate",
                            "op": ">=",
                            "value": 0.5,
                        }
                    ],
                },
                "promotion": {
                    "partitions": ["familiar", "unfamiliar"],
                    "shards_per_partition": 1,
                    "promotion_eligible": True,
                    "gates": [
                        {
                            "name": "familiar_resolution",
                            "path": "groups.familiar.games.resolution_rate",
                            "op": ">=",
                            "value": 0.5,
                        },
                        {
                            "name": "familiar_win_rate",
                            "path": "groups.familiar.games.resolved_win_rate",
                            "op": ">=",
                            "value": 0.75,
                        },
                        {
                            "name": "unfamiliar_resolution",
                            "path": "groups.unfamiliar.games.resolution_rate",
                            "op": ">=",
                            "value": 0.5,
                        },
                        {
                            "name": "unfamiliar_win_rate",
                            "path": "groups.unfamiliar.games.resolved_win_rate",
                            "op": ">=",
                            "value": 0.75,
                        },
                    ],
                },
            },
        }

    def _result(
        self,
        plan: dict,
        shard_id: str,
        partition: str,
        *,
        wins: int,
        losses: int,
        draws: int,
        unresolved: int,
        failures: int = 0,
        decision_ms: list[float] | None = None,
        metric_sum: float = 0.0,
        metric_count: int = 0,
    ) -> dict:
        return {
            "schema_version": 1,
            "experiment_id": plan["experiment_id"],
            "tier": plan["tier"],
            "manifest_sha256": plan["manifest_sha256"],
            "shard_id": shard_id,
            "partition": partition,
            "provenance": deepcopy(plan["provenance"]),
            "games": {
                "wins": wins,
                "losses": losses,
                "draws": draws,
                "unresolved": unresolved,
                "failures": failures,
            },
            "metrics": {
                "candidate_recall": {"sum": metric_sum, "count": metric_count},
            },
            "timing": {
                "decision_ms": list(decision_ms or []),
                "training_seconds": 0.0,
            },
        }

    def test_manifest_rejects_frozen_reuse_and_seed_overlap(self) -> None:
        manifest = self._manifest()
        validate_manifest(manifest)

        frozen_reuse = deepcopy(manifest)
        frozen_reuse["data_policy"]["training_roles"].append("frozen_eval")
        with self.assertRaisesRegex(ManifestError, "frozen_eval"):
            validate_manifest(frozen_reuse)

        overlap = deepcopy(manifest)
        overlap["seed_partitions"]["diagnostic"]["start"] = 1001
        with self.assertRaisesRegex(ManifestError, "overlaps partitions"):
            validate_manifest(overlap)

    def test_plan_has_stable_shards_and_resumes_only_pending_ids(self) -> None:
        manifest = self._manifest()
        plan = build_plan(manifest, "diagnostic", rules_sha="abcdef123456")

        self.assertEqual(
            [shard["shard_id"] for shard in plan["expected_shards"]],
            ["diagnostic-00", "diagnostic-01"],
        )
        self.assertEqual(plan["expected_shards"][0]["seeds"], [2000, 2002])
        self.assertEqual(plan["expected_shards"][1]["seeds"], [2001, 2003])

        resumed = build_plan(
            manifest,
            "diagnostic",
            rules_sha="abcdef123456",
            completed_shards={"diagnostic-00"},
        )
        self.assertEqual(resumed["completed_shard_ids"], ["diagnostic-00"])
        self.assertEqual(
            [shard["shard_id"] for shard in resumed["pending_shards"]],
            ["diagnostic-01"],
        )

    def test_scorecard_aggregates_groups_draws_metrics_and_timing(self) -> None:
        plan = build_plan(
            self._manifest(),
            "promotion",
            rules_sha="abcdef123456",
            checkpoint_sha256="checkpoint-1",
        )
        familiar = self._result(
            plan,
            "familiar-00",
            "familiar",
            wins=15,
            losses=4,
            draws=1,
            unresolved=0,
            decision_ms=[1000, 1500, 29999],
            metric_sum=18,
            metric_count=20,
        )
        unfamiliar = self._result(
            plan,
            "unfamiliar-00",
            "unfamiliar",
            wins=12,
            losses=3,
            draws=1,
            unresolved=4,
            decision_ms=[800, 1200],
            metric_sum=14,
            metric_count=20,
        )

        scorecard = build_scorecard(plan, [familiar, unfamiliar])

        self.assertTrue(scorecard["passed"], scorecard["gates"])
        self.assertEqual(scorecard["overall"]["games"]["total"], 40)
        self.assertAlmostEqual(scorecard["groups"]["familiar"]["games"]["resolved_win_rate"], 0.75)
        self.assertAlmostEqual(scorecard["groups"]["unfamiliar"]["games"]["resolved_win_rate"], 0.75)
        self.assertAlmostEqual(scorecard["overall"]["metrics"]["candidate_recall"], 0.8)
        self.assertEqual(scorecard["overall"]["timing"]["decision_max_ms"], 29999)

    def test_scorecard_and_resume_fail_closed_on_missing_or_conflicting_results(self) -> None:
        plan = build_plan(
            self._manifest(),
            "promotion",
            rules_sha="abcdef123456",
            checkpoint_sha256="checkpoint-1",
        )
        familiar = self._result(
            plan,
            "familiar-00",
            "familiar",
            wins=15,
            losses=4,
            draws=1,
            unresolved=0,
            decision_ms=[1000],
        )

        partial = build_scorecard(plan, [familiar])
        self.assertFalse(partial["passed"])
        self.assertEqual(partial["shards"]["missing_ids"], ["unfamiliar-00"])
        self.assertFalse(partial["gates"][0]["passed"])

        unrelated = deepcopy(familiar)
        unrelated["experiment_id"] = "another-experiment"
        self.assertEqual(matching_shard_results(plan, [unrelated, familiar]), [familiar])

        wrong_checkpoint = deepcopy(familiar)
        wrong_checkpoint["provenance"]["checkpoint_sha256"] = "different-checkpoint"
        with self.assertRaisesRegex(ResultContractError, "checkpoint hash"):
            build_scorecard(plan, [wrong_checkpoint])


if __name__ == "__main__":
    unittest.main()
