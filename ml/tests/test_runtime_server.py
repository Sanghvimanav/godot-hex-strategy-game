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


class NeuralRuntimeServerTests(unittest.TestCase):
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
        with tempfile.TemporaryDirectory() as temp_dir:
            checkpoint_path = Path(temp_dir) / "runtime_test.pt"
            torch.save(checkpoint, checkpoint_path)
            process = subprocess.Popen(
                [sys.executable, "-u", str(RUNTIME), "--checkpoint", str(checkpoint_path)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertIsNotNone(process.stdin)
            self.assertIsNotNone(process.stdout)
            try:
                ready = json.loads(process.stdout.readline())
                self.assertTrue(ready["ready"], ready)
                self.assertEqual(ready["board_channels"], encoder.board_channels)
                self.assertEqual(ready["global_features"], encoder.global_features)

                request = {
                    "perspective_group": "zerg",
                    "opponent_group": "terran",
                    "turn_index": 2,
                    "terminal": False,
                    "state": {
                        "hex_radius": 5,
                        "command_hexes": {"zerg": [5, 0], "terran": [-5, 0]},
                        "groups": [
                            {"name": "zerg", "resources": {}, "units": [{"unit_id": 1, "def_path": "res://src/unit/definitions/zergling.tres", "cell": [1, 0], "health": 3, "max_health": 3, "energy": 0, "max_energy": 0}]},
                            {"name": "terran", "resources": {}, "units": [{"unit_id": 2, "def_path": "res://src/unit/definitions/marine.tres", "cell": [-1, 0], "health": 3, "max_health": 3, "energy": 1, "max_energy": 1}]},
                        ],
                        "tile_resources": {},
                    },
                }
                scores = []
                for _ in range(2):
                    process.stdin.write(json.dumps(request) + "\n")
                    process.stdin.flush()
                    response = json.loads(process.stdout.readline())
                    self.assertTrue(response["ok"], response)
                    scores.append(float(response["value"]))
                self.assertTrue(math.isfinite(scores[0]))
                self.assertGreaterEqual(scores[0], -1.0)
                self.assertLessEqual(scores[0], 1.0)
                self.assertAlmostEqual(scores[0], scores[1], places=7)
            finally:
                if process.stdin is not None:
                    process.stdin.close()
                process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
