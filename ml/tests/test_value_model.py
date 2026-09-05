from __future__ import annotations

import argparse
import json
import tempfile
import unittest
from pathlib import Path

import torch
from torch import nn

from ml.value_model.data import (
    BOARD_CHANNELS,
    BOARD_SIZE,
    ENEMY_TYPE_OFFSET,
    GLOBAL_FEATURES,
    OWN_TYPE_OFFSET,
    UNIT_TYPE_INDEX,
    VALID_MASK_CHANNEL,
    HexStateEncoder,
    ValueExampleDataset,
    load_jsonl_examples,
    split_examples_by_game,
    split_examples_by_group,
)
from ml.value_model.evaluate_counterfactual import evaluate_counterfactual_rows
from ml.value_model.metrics import (
    candidate_ranking_metrics,
    handwritten_evaluator_score,
    sign_accuracy,
    top_plan_regret_metrics,
    uncertainty_aware_candidate_ranking_metrics,
)
from ml.value_model.model import HexValueNet
from ml.value_model.train import train


def _unit(unit_id: int, kind: str, cell: list[int], health: int = 2, energy: int = 0) -> dict:
    return {
        "unit_id": unit_id,
        "def_path": f"res://src/unit/definitions/{kind}.tres",
        "cell": cell,
        "health": health,
        "max_health": max(health, 2),
        "energy": energy,
        "max_energy": max(energy, 0),
    }


def _example(
    perspective: str = "zerg",
    outcome: float = 1.0,
    game_id: str = "g1",
    scenario_family: str = "synthetic",
) -> dict:
    return {
        "schema_version": 1,
        "game_id": game_id,
        "turn_index": 2,
        "perspective_group": perspective,
        "opponent_group": "terran" if perspective == "zerg" else "zerg",
        "outcome": outcome,
        "terminal": False,
        "winner": "zerg",
        "source": {"base_scenario_id": scenario_family},
        "state": {
            "scenario_id": "synthetic",
            "hex_radius": 1,
            "groups": [
                {"name": "zerg", "resources": {"crystal": 3}, "units": [_unit(1, "zergling", [0, 0], 2)]},
                {"name": "terran", "resources": {"people": 1}, "units": [_unit(2, "marine", [1, 0], 3)]},
            ],
            "tile_resources": {},
        },
    }


class ValueModelTests(unittest.TestCase):
    def test_hex_mask_and_perspective_channels(self) -> None:
        encoder = HexStateEncoder()
        zerg = encoder.encode(_example("zerg", 1.0))
        terran = encoder.encode(_example("terran", -1.0))
        self.assertEqual(tuple(zerg.board.shape), (BOARD_CHANNELS, BOARD_SIZE, BOARD_SIZE))
        self.assertEqual(int(zerg.board[VALID_MASK_CHANNEL].sum().item()), 7)
        center = (5, 5)
        east = (5, 6)
        zergling = UNIT_TYPE_INDEX["zergling"]
        marine = UNIT_TYPE_INDEX["marine"]
        self.assertEqual(float(zerg.board[OWN_TYPE_OFFSET + zergling, *center]), 1.0)
        self.assertEqual(float(zerg.board[ENEMY_TYPE_OFFSET + marine, *east]), 1.0)
        self.assertEqual(float(terran.board[ENEMY_TYPE_OFFSET + zergling, *center]), 1.0)
        self.assertEqual(float(terran.board[OWN_TYPE_OFFSET + marine, *east]), 1.0)
        self.assertEqual(tuple(zerg.global_features.shape), (GLOBAL_FEATURES,))

    def test_model_output_is_bounded_scalar_per_example(self) -> None:
        model = HexValueNet(hidden_channels=8, residual_blocks=1)
        board = torch.zeros((3, BOARD_CHANNELS, BOARD_SIZE, BOARD_SIZE))
        board[:, VALID_MASK_CHANNEL] = 1.0
        globals_ = torch.zeros((3, GLOBAL_FEATURES))
        result = model(board, globals_)
        self.assertEqual(tuple(result.shape), (3,))
        self.assertTrue(torch.all(result <= 1.0))
        self.assertTrue(torch.all(result >= -1.0))

    def test_split_by_game_never_leaks_perspective_pairs(self) -> None:
        examples = []
        for game in range(5):
            examples.append(_example("zerg", 1.0, f"g{game}"))
            examples.append(_example("terran", -1.0, f"g{game}"))
        train_examples, validation = split_examples_by_game(examples, validation_fraction=0.4, seed=7)
        train_ids = {item["game_id"] for item in train_examples}
        validation_ids = {item["game_id"] for item in validation}
        self.assertTrue(train_ids)
        self.assertTrue(validation_ids)
        self.assertTrue(train_ids.isdisjoint(validation_ids))

    def test_split_by_scenario_family_keeps_rotations_together(self) -> None:
        examples = []
        for family in ("collapse", "baneling", "mixed", "spread"):
            for rotation in range(2):
                game_id = f"{family}-r{rotation}"
                examples.append(_example("zerg", 1.0, game_id, family))
                examples.append(_example("terran", -1.0, game_id, family))
        train_examples, validation = split_examples_by_group(
            examples,
            validation_fraction=0.25,
            seed=0,
            group_key="source.base_scenario_id",
        )
        train_families = {item["source"]["base_scenario_id"] for item in train_examples}
        validation_families = {item["source"]["base_scenario_id"] for item in validation}
        self.assertEqual(len(validation_families), 1)
        self.assertTrue(train_families.isdisjoint(validation_families))
        held_out = next(iter(validation_families))
        self.assertTrue(all(item["source"]["base_scenario_id"] == held_out for item in validation))

    def test_jsonl_loader(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "examples.jsonl"
            path.write_text(json.dumps(_example()) + "\n\n", encoding="utf-8")
            loaded = load_jsonl_examples(path)
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0]["game_id"], "g1")

    def test_handwritten_evaluator_parity_shape(self) -> None:
        example = _example("zerg", 1.0)
        # Terran has one extra HP, while Zerg has two extra total resources.
        self.assertEqual(handwritten_evaluator_score(example), -6.0)
        mirrored = _example("terran", -1.0)
        self.assertEqual(handwritten_evaluator_score(mirrored), 6.0)
        self.assertEqual(sign_accuracy([-6.0, 6.0], [1.0, -1.0]), 0.0)

    def test_candidate_ranking_and_top_plan_regret(self) -> None:
        predictions = [0.1, 0.9, -0.3, 0.5, 0.5]
        targets = [0.8, 0.2, -0.6, -0.2, 0.7]
        decision_ids = ["turn-a", "turn-a", "turn-a", "turn-b", "turn-b"]

        ranking = candidate_ranking_metrics(predictions, targets, decision_ids)
        self.assertEqual(ranking["candidate_ranking_pairs"], 4)
        self.assertEqual(ranking["candidate_ranking_decisions"], 2)
        self.assertAlmostEqual(float(ranking["candidate_ranking_accuracy"]), 0.625)

        regret = top_plan_regret_metrics(predictions, targets, decision_ids)
        self.assertEqual(regret["top_plan_decisions"], 2)
        self.assertAlmostEqual(float(regret["top_plan_mean_regret"]), 0.75)
        self.assertAlmostEqual(float(regret["top_plan_max_regret"]), 0.9)
        self.assertEqual(float(regret["top_plan_optimal_rate"]), 0.0)

    def test_uncertainty_aware_ranking_skips_unseparated_pairs(self) -> None:
        predictions = [0.8, 0.9, -0.5]
        targets = [0.6, 0.5, -1.0]
        standard_errors = [0.5, 0.5, 0.1]
        decision_ids = ["turn-a", "turn-a", "turn-a"]
        raw = candidate_ranking_metrics(predictions, targets, decision_ids)
        aware = uncertainty_aware_candidate_ranking_metrics(
            predictions,
            targets,
            standard_errors,
            decision_ids,
            separation_z=1.96,
        )
        self.assertEqual(raw["candidate_ranking_pairs"], 3)
        # 0.6 vs 0.5 is well inside the policy-sample uncertainty band, while
        # both candidates remain clearly separated from -1.0.
        self.assertEqual(aware["uncertainty_aware_candidate_ranking_pairs"], 2)
        self.assertEqual(aware["uncertainty_aware_candidate_ranking_decisions"], 1)
        self.assertAlmostEqual(float(aware["uncertainty_aware_candidate_ranking_accuracy"]), 1.0)

    def test_candidate_metrics_validate_parallel_inputs(self) -> None:
        with self.assertRaises(ValueError):
            candidate_ranking_metrics([0.1], [1.0, -1.0], ["turn-a"])
        with self.assertRaises(ValueError):
            top_plan_regret_metrics([0.1], [1.0], [])
        with self.assertRaises(ValueError):
            uncertainty_aware_candidate_ranking_metrics([0.1], [1.0], [], ["turn-a"])

    def test_counterfactual_evaluation_scores_real_candidate_rows(self) -> None:
        weak_state = _example()["state"]
        strong_state = json.loads(json.dumps(weak_state))
        strong_state["groups"][0]["units"].append(_unit(3, "zergling", [0, 1], 2))

        def candidate(candidate_id: str, target: float, proposal: float, state: dict) -> dict:
            return {
                "decision_id": "decision-a",
                "candidate_id": candidate_id,
                "candidate_label": candidate_id.title(),
                "candidate_description": f"Synthetic {candidate_id} candidate",
                "perspective_group": "zerg",
                "opponent_group": "terran",
                "proposal_score": proposal,
                "assumptions": {"separation_z": 1.96},
                "target_estimate": {
                    "return_count": 1,
                    "mean_return": target,
                    "estimated_standard_error": 0.0,
                    "labeled_weight_fraction": 1.0,
                },
                "samples": [
                    {
                        "valid": True,
                        "labeled": True,
                        "weight": 1.0,
                        "state_after_first_turn": state,
                    }
                ],
            }

        encoder = HexStateEncoder()
        model = HexValueNet(hidden_channels=4, residual_blocks=0)
        for parameter in model.parameters():
            parameter.data.zero_()

        with tempfile.TemporaryDirectory() as directory:
            checkpoint_path = Path(directory) / "model.pt"
            torch.save(
                {
                    "model_state_dict": model.state_dict(),
                    "model_config": {
                        "hidden_channels": 4,
                        "residual_blocks": 0,
                        "board_channels": encoder.board_channels,
                        "global_features": encoder.global_features,
                        "board_size": encoder.board_size,
                        "max_radius": encoder.max_radius,
                        "unit_types": list(encoder.unit_types),
                    },
                },
                checkpoint_path,
            )
            result = evaluate_counterfactual_rows(
                [
                    candidate("weak", -1.0, 1.0, weak_state),
                    candidate("strong", 1.0, 0.0, strong_state),
                ],
                checkpoint_path,
            )

        self.assertEqual(result["evaluated_candidates"], 2)
        self.assertEqual(result["evaluated_decisions"], 1)
        self.assertEqual(len(result["candidate_details"]), 2)
        self.assertIn("neural_score", result["candidate_details"][0])
        self.assertIn("target_standard_error", result["candidate_details"][0])
        neural = result["evaluators"]["neural_value_model"]
        handwritten = result["evaluators"]["handwritten_state_evaluator"]
        proposal = result["evaluators"]["planner_proposal_score"]
        self.assertAlmostEqual(float(neural["candidate_ranking_accuracy"]), 0.5)
        self.assertAlmostEqual(float(neural["uncertainty_aware_candidate_ranking_accuracy"]), 0.5)
        self.assertAlmostEqual(float(neural["top_plan_mean_regret"]), 2.0)
        self.assertAlmostEqual(float(handwritten["candidate_ranking_accuracy"]), 1.0)
        self.assertAlmostEqual(float(handwritten["top_plan_mean_regret"]), 0.0)
        self.assertAlmostEqual(float(proposal["candidate_ranking_accuracy"]), 0.0)
        self.assertAlmostEqual(float(proposal["top_plan_mean_regret"]), 2.0)

    def test_trainer_compares_evaluators_on_same_nonterminal_population(self) -> None:
        examples = []
        for family in ("family-a", "family-b"):
            for perspective, outcome in (("zerg", 1.0), ("terran", -1.0)):
                nonterminal = _example(perspective, outcome, f"{family}-game", family)
                terminal = _example(perspective, outcome, f"{family}-game", family)
                terminal["terminal"] = True
                examples.extend([nonterminal, terminal])

        with tempfile.TemporaryDirectory() as directory:
            data_path = Path(directory) / "examples.jsonl"
            output_path = Path(directory) / "model.pt"
            data_path.write_text(
                "".join(json.dumps(example) + "\n" for example in examples),
                encoding="utf-8",
            )
            result = train(
                argparse.Namespace(
                    data=str(data_path),
                    output=str(output_path),
                    epochs=1,
                    batch_size=4,
                    learning_rate=3e-4,
                    weight_decay=1e-4,
                    validation_fraction=0.5,
                    split_key="source.base_scenario_id",
                    hidden_channels=4,
                    residual_blocks=0,
                    seed=0,
                    device="cpu",
                )
            )

        self.assertEqual(result["validation_examples"], 4)
        self.assertEqual(result["eval_nonterminal_examples"], 2)
        self.assertEqual(result["metric_comparison_population"], "held_out_nonterminal")
        expected_delta = (
            float(result["neural_eval_sign_accuracy_nonterminal"])
            - float(result["handwritten_eval_sign_accuracy_nonterminal"])
        )
        self.assertAlmostEqual(
            float(result["neural_minus_handwritten_sign_accuracy_nonterminal"]),
            expected_delta,
        )

    def test_trainer_reports_conflicting_identical_model_inputs(self) -> None:
        positive = _example("zerg", 1.0, "g-positive", "same-family")
        negative = json.loads(json.dumps(positive))
        negative["game_id"] = "g-negative"
        negative["outcome"] = -1.0
        negative["winner"] = "terran"
        with tempfile.TemporaryDirectory() as directory:
            data_path = Path(directory) / "examples.jsonl"
            output_path = Path(directory) / "model.pt"
            data_path.write_text(
                json.dumps(positive) + "\n" + json.dumps(negative) + "\n",
                encoding="utf-8",
            )
            result = train(
                argparse.Namespace(
                    data=str(data_path),
                    output=str(output_path),
                    epochs=1,
                    batch_size=2,
                    learning_rate=3e-4,
                    weight_decay=1e-4,
                    validation_fraction=0.0,
                    split_key="source.base_scenario_id",
                    hidden_channels=4,
                    residual_blocks=0,
                    seed=0,
                    device="cpu",
                )
            )
        self.assertEqual(result["train_conflicting_input_groups"], 1)
        self.assertEqual(result["train_conflicting_input_examples"], 2)
        self.assertEqual(result["all_conflicting_input_groups"], 1)

    def test_tiny_network_can_reduce_loss(self) -> None:
        torch.manual_seed(0)
        examples = [_example("zerg", 1.0, "g1"), _example("terran", -1.0, "g1")] * 4
        dataset = ValueExampleDataset(examples)
        board = torch.stack([dataset[i][0] for i in range(len(dataset))])
        globals_ = torch.stack([dataset[i][1] for i in range(len(dataset))])
        target = torch.stack([dataset[i][2] for i in range(len(dataset))])
        model = HexValueNet(hidden_channels=8, residual_blocks=0)
        optimizer = torch.optim.Adam(model.parameters(), lr=0.02)
        loss_fn = nn.MSELoss()
        model.train()
        initial = float(loss_fn(model(board, globals_), target).item())
        for _ in range(30):
            optimizer.zero_grad(set_to_none=True)
            loss = loss_fn(model(board, globals_), target)
            loss.backward()
            optimizer.step()
        final = float(loss_fn(model(board, globals_), target).item())
        self.assertLess(final, initial * 0.5)


if __name__ == "__main__":
    unittest.main()
