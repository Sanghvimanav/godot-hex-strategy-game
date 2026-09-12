from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import torch

from ml.value_model.data import HexStateEncoder
from ml.value_model.model import HexValueNet


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME = REPO_ROOT / "hex-strategy-game" / "tools" / "neural_value_runtime.py"


def _request() -> dict:
    return {
        "perspective_group": "zerg",
        "opponent_group": "terran",
        "turn_index": 2,
        "terminal": False,
        "state": {
            "hex_radius": 5,
            "command_hexes": {"zerg": [5, 0], "terran": [-5, 0]},
            "groups": [
                {
                    "name": "zerg",
                    "resources": {},
                    "units": [
                        {
                            "unit_id": 1,
                            "def_path": "res://src/unit/definitions/zergling.tres",
                            "cell": [1, 0],
                            "health": 3,
                            "max_health": 3,
                            "energy": 0,
                            "max_energy": 0,
                        }
                    ],
                },
                {
                    "name": "terran",
                    "resources": {},
                    "units": [
                        {
                            "unit_id": 2,
                            "def_path": "res://src/unit/definitions/marine.tres",
                            "cell": [-1, 0],
                            "health": 3,
                            "max_health": 3,
                            "energy": 1,
                            "max_energy": 1,
                        }
                    ],
                },
            ],
            "tile_resources": {},
        },
    }


class NeuralRuntimeServerTests(unittest.TestCase):
    def _launch(self, checkpoint: dict):
        temp_dir = tempfile.TemporaryDirectory()
        checkpoint_path = Path(temp_dir.name) / "runtime_test.pt"
        torch.save(checkpoint, checkpoint_path)
        process = subprocess.Popen(
            [sys.executable, "-u", str(RUNTIME), "--checkpoint", str(checkpoint_path)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(temp_dir.cleanup)
        self.addCleanup(self._stop_process, process)
        self.assertIsNotNone(process.stdin)
        self.assertIsNotNone(process.stdout)
        return process

    @staticmethod
    def _stop_process(process: subprocess.Popen) -> None:
        if process.poll() is not None:
            return
        if process.stdin is not None:
            process.stdin.close()
        process.terminate()
        process.wait(timeout=5)

    def test_current_encoder_checkpoint_scores_deterministically(self) -> None:
        encoder = HexStateEncoder()
        model = HexValueNet()
        checkpoint = {
            "model_state_dict": model.state_dict(),
            "model_config": {
                "hidden_channels": 32,
                "residual_blocks": 2,
                "board_channels": encoder.board_channels,
                "global_features": encoder.global_features,
                "board_size": encoder.board_size,
                "max_radius": encoder.max_radius,
                "unit_types": list(encoder.unit_types),
            },
        }
        process = self._launch(checkpoint)
        ready = json.loads(process.stdout.readline())
        self.assertTrue(ready["ready"], ready)
        self.assertEqual(ready["board_channels"], encoder.board_channels)
        self.assertEqual(ready["global_features"], encoder.global_features)
        self.assertEqual(ready["search_head"], "value")
        self.assertFalse(ready["policy_head"])

        scores = []
        for _ in range(2):
            process.stdin.write(json.dumps(_request()) + "\n")
            process.stdin.flush()
            response = json.loads(process.stdout.readline())
            self.assertTrue(response["ok"], response)
            scores.append(float(response["value"]))
        self.assertTrue(math.isfinite(scores[0]))
        self.assertGreaterEqual(scores[0], -1.0)
        self.assertLessEqual(scores[0], 1.0)
        self.assertAlmostEqual(scores[0], scores[1], places=7)

    def test_policy_checkpoint_uses_policy_head_for_search_scores(self) -> None:
        encoder = HexStateEncoder()
        model = HexValueNet(policy_head=True)
        assert model.policy_head is not None
        with torch.no_grad():
            for parameter in model.policy_head.parameters():
                parameter.zero_()
            model.policy_head[2].bias.fill_(0.5)
        base_state = {
            key: value
            for key, value in model.state_dict().items()
            if not key.startswith("policy_head.")
        }
        checkpoint = {
            "model_state_dict": base_state,
            "policy_head_state_dict": model.policy_head.state_dict(),
            "model_config": {
                "hidden_channels": 32,
                "residual_blocks": 2,
                "board_channels": encoder.board_channels,
                "global_features": encoder.global_features,
                "board_size": encoder.board_size,
                "max_radius": encoder.max_radius,
                "unit_types": list(encoder.unit_types),
                "policy_head": True,
                "search_head": "policy",
            },
        }
        process = self._launch(checkpoint)
        ready = json.loads(process.stdout.readline())
        self.assertTrue(ready["ready"], ready)
        self.assertEqual(ready["search_head"], "policy")
        self.assertTrue(ready["policy_head"])

        process.stdin.write(json.dumps(_request()) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        self.assertTrue(response["ok"], response)
        self.assertAlmostEqual(float(response["value"]), math.tanh(0.5), places=6)


if __name__ == "__main__":
    unittest.main()
