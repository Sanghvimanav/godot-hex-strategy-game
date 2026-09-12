from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import torch

from ml.value_model.model import HexValueNet
from ml.value_model.train_ranked_iterative import WarmStartHexValueNet


class WarmStartTrainingTests(unittest.TestCase):
    def tearDown(self) -> None:
        WarmStartHexValueNet.init_checkpoint = None

    def test_restores_value_and_policy_heads(self) -> None:
        source = HexValueNet(hidden_channels=8, residual_blocks=1, policy_head=True)
        with torch.no_grad():
            for index, parameter in enumerate(source.parameters()):
                parameter.fill_(0.01 * (index + 1))

        base_state = {
            key: value.clone()
            for key, value in source.state_dict().items()
            if not key.startswith("policy_head.")
        }
        assert source.policy_head is not None
        checkpoint = {
            "model_state_dict": base_state,
            "policy_head_state_dict": {
                key: value.clone() for key, value in source.policy_head.state_dict().items()
            },
        }

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "parent.pt"
            torch.save(checkpoint, path)
            WarmStartHexValueNet.init_checkpoint = str(path)
            restored = WarmStartHexValueNet(
                hidden_channels=8,
                residual_blocks=1,
                policy_head=True,
            )

        source_state = source.state_dict()
        restored_state = restored.state_dict()
        self.assertEqual(set(source_state), set(restored_state))
        for key in source_state:
            self.assertTrue(torch.equal(source_state[key], restored_state[key]), key)


if __name__ == "__main__":
    unittest.main()
