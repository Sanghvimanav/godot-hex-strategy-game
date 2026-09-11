from __future__ import annotations

import torch
from torch import nn

from .data import BOARD_CHANNELS, GLOBAL_FEATURES, VALID_MASK_CHANNEL


class ResidualBlock(nn.Module):
    def __init__(self, channels: int):
        super().__init__()
        self.block = nn.Sequential(
            nn.Conv2d(channels, channels, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(channels),
            nn.ReLU(inplace=True),
            nn.Conv2d(channels, channels, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(channels),
        )
        self.activation = nn.ReLU(inplace=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.activation(x + self.block(x))


class HexValueNet(nn.Module):
    """Residual hex-state encoder with value and optional search-ranking heads."""

    def __init__(
        self,
        board_channels: int = BOARD_CHANNELS,
        global_features: int = GLOBAL_FEATURES,
        hidden_channels: int = 32,
        residual_blocks: int = 2,
        policy_head: bool = False,
    ):
        super().__init__()
        self.stem = nn.Sequential(
            nn.Conv2d(board_channels, hidden_channels, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(hidden_channels),
            nn.ReLU(inplace=True),
        )
        self.body = nn.Sequential(*(ResidualBlock(hidden_channels) for _ in range(residual_blocks)))
        feature_size = hidden_channels + global_features
        self.head = nn.Sequential(
            nn.Linear(feature_size, 64),
            nn.ReLU(inplace=True),
            nn.Linear(64, 1),
            nn.Tanh(),
        )
        self.policy_head = (
            nn.Sequential(
                nn.Linear(feature_size, 64),
                nn.ReLU(inplace=True),
                nn.Linear(64, 1),
                nn.Tanh(),
            )
            if policy_head
            else None
        )

    def _features(
        self, board: torch.Tensor, global_features: torch.Tensor
    ) -> torch.Tensor:
        if board.ndim != 4:
            raise ValueError("board must have shape [batch, channels, height, width]")
        if global_features.ndim != 2:
            raise ValueError("global_features must have shape [batch, features]")
        valid_mask = board[:, VALID_MASK_CHANNEL : VALID_MASK_CHANNEL + 1]
        x = self.body(self.stem(board))
        masked_sum = (x * valid_mask).sum(dim=(2, 3))
        valid_cells = valid_mask.sum(dim=(2, 3)).clamp_min(1.0)
        pooled = masked_sum / valid_cells
        return torch.cat([pooled, global_features], dim=1)

    def forward(self, board: torch.Tensor, global_features: torch.Tensor) -> torch.Tensor:
        """Predict perspective-relative terminal value in [-1, 1]."""
        return self.head(self._features(board, global_features)).squeeze(1)

    def policy_score(
        self, board: torch.Tensor, global_features: torch.Tensor
    ) -> torch.Tensor:
        """Score sibling candidate outcomes for search ordering/action preference."""
        if self.policy_head is None:
            raise RuntimeError("policy head is not enabled")
        return self.policy_head(self._features(board, global_features)).squeeze(1)
