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
    """Small residual CNN producing a perspective-relative value in [-1, 1]."""

    def __init__(
        self,
        board_channels: int = BOARD_CHANNELS,
        global_features: int = GLOBAL_FEATURES,
        hidden_channels: int = 32,
        residual_blocks: int = 2,
    ):
        super().__init__()
        self.stem = nn.Sequential(
            nn.Conv2d(board_channels, hidden_channels, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(hidden_channels),
            nn.ReLU(inplace=True),
        )
        self.body = nn.Sequential(*(ResidualBlock(hidden_channels) for _ in range(residual_blocks)))
        self.head = nn.Sequential(
            nn.Linear(hidden_channels + global_features, 64),
            nn.ReLU(inplace=True),
            nn.Linear(64, 1),
            nn.Tanh(),
        )

    def forward(self, board: torch.Tensor, global_features: torch.Tensor) -> torch.Tensor:
        if board.ndim != 4:
            raise ValueError("board must have shape [batch, channels, height, width]")
        if global_features.ndim != 2:
            raise ValueError("global_features must have shape [batch, features]")
        valid_mask = board[:, VALID_MASK_CHANNEL : VALID_MASK_CHANNEL + 1]
        x = self.body(self.stem(board))
        masked_sum = (x * valid_mask).sum(dim=(2, 3))
        valid_cells = valid_mask.sum(dim=(2, 3)).clamp_min(1.0)
        pooled = masked_sum / valid_cells
        return self.head(torch.cat([pooled, global_features], dim=1)).squeeze(1)
