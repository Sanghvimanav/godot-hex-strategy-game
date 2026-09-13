from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable

import torch
from torch import nn


UNKNOWN_TOKEN = "<unk>"


def unit_type(unit):
    path = str(unit.get("def_path", ""))
    return path.rsplit("/", 1)[-1].split(".")[0] if path else str(unit.get("unit_type", unit.get("type", UNKNOWN_TOKEN)))


def _cell(value: Any) -> tuple[int, int]:
    if isinstance(value, (list, tuple)) and len(value) >= 2:
        return int(value[0]), int(value[1])
    return 0, 0


def _groups(state: dict[str, Any]) -> Iterable[dict[str, Any]]:
    for group in state.get("groups", []):
        if isinstance(group, dict):
            yield group


def find_unit(state: dict[str, Any], unit_id: int) -> dict[str, Any]:
    for group in _groups(state):
        for unit in group.get("units", []):
            if isinstance(unit, dict) and int(unit.get("unit_id", -1)) == unit_id:
                return unit
    return {}


def action_signature(action: dict[str, Any]) -> str:
    unit_id = int(action.get("unit_id", -1))
    key = str(action.get("action_key", ""))
    end = _cell(action.get("end_point", [0, 0]))
    path = action.get("path", [])
    path_cells = []
    if isinstance(path, list):
        path_cells = [f"{x},{y}" for x, y in (_cell(item) for item in path)]
    return f"{unit_id}|{key}|{end[0]},{end[1]}|{'>'.join(path_cells)}"


def sorted_plan_actions(actions: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        (dict(action) for action in actions if isinstance(action, dict)),
        key=lambda action: (
            int(action.get("unit_id", -1)),
            str(action.get("action_key", "")),
            action_signature(action),
        ),
    )


def build_vocab(search_decisions: Iterable[dict[str, Any]]) -> tuple[list[str], list[str]]:
    action_keys = {UNKNOWN_TOKEN, "<hold>"}
    unit_types = {UNKNOWN_TOKEN}
    for decision in search_decisions:
        state = decision.get("starting_state", {})
        if isinstance(state, dict):
            for group in _groups(state):
                for unit in group.get("units", []):
                    if isinstance(unit, dict):
                        unit_types.add(unit_type(unit))
        for candidate in decision.get("candidates", []):
            if not isinstance(candidate, dict):
                continue
            for action in candidate.get("actions", []):
                if isinstance(action, dict):
                    action_keys.add(str(action.get("action_key", UNKNOWN_TOKEN)))
    return sorted(action_keys), sorted(unit_types)


@dataclass(frozen=True)
class PolicyExample:
    state: dict[str, Any]
    perspective_group: str
    opponent_group: str
    prefix_actions: tuple[dict[str, Any], ...]
    candidate_actions: tuple[dict[str, Any], ...]
    continuation_scores: tuple[float, ...]

    @property
    def target_index(self) -> int:
        return max(range(len(self.continuation_scores)), key=self.continuation_scores.__getitem__)


def build_search_distillation_examples(decision: dict[str, Any]) -> list[PolicyExample]:
    """Convert complete robust-search candidates into autoregressive prefix targets.

    For a given prefix, each next action receives the best worst-case score of any
    searched complete plan that starts with prefix + action.  The policy therefore
    learns which action opens the strongest searched continuation rather than
    imitating the old proposal heuristic or merely copying the played action.
    """
    state = decision.get("starting_state", {})
    perspective = str(decision.get("perspective_group", ""))
    opponent = str(decision.get("opponent_group", ""))
    if not isinstance(state, dict) or not state or not perspective or not opponent:
        return []

    plans: list[tuple[list[dict[str, Any]], float]] = []
    for candidate in decision.get("candidates", []):
        if not isinstance(candidate, dict):
            continue
        actions = sorted_plan_actions(candidate.get("actions", []))
        selected = {int(a.get("unit_id", -1)) for a in actions}
        for group in _groups(state):
            if group.get("name") != perspective:
                continue
            for unit in group.get("units", []):
                uid = int(unit.get("unit_id", -1))
                if unit.get("health", 0) <= 0 or uid in selected:
                    continue
                if any(e.get("kind") == "Stun" and e.get("duration", 0) > 0 and not e.get("pending_first_tick", False)
                       for e in unit.get("effects", [])):
                    continue
                actions.append({"unit_id": uid, "action_key": "<hold>", "end_point": unit.get("cell", [0, 0]), "path": []})
        actions = sorted_plan_actions(actions)
        if not actions:
            continue
        plans.append((actions, float(candidate.get("handwritten_worst_case_score", 0.0))))
    if not plans:
        return []

    examples: list[PolicyExample] = []
    max_depth = max(len(actions) for actions, _ in plans)
    active: list[tuple[list[dict[str, Any]], float]] = plans
    for depth in range(max_depth):
        groups: dict[tuple[str, ...], list[tuple[list[dict[str, Any]], float]]] = {}
        for actions, score in active:
            if len(actions) <= depth:
                continue
            prefix_key = tuple(action_signature(action) for action in actions[:depth])
            groups.setdefault(prefix_key, []).append((actions, score))

        for rows in groups.values():
            by_action: dict[str, tuple[dict[str, Any], float]] = {}
            for actions, score in rows:
                action = actions[depth]
                signature = action_signature(action)
                previous = by_action.get(signature)
                if previous is None or score > previous[1]:
                    by_action[signature] = (action, score)
            if len(by_action) < 2:
                continue
            ordered = sorted(by_action.values(), key=lambda item: action_signature(item[0]))
            prefix = tuple(dict(action) for action in rows[0][0][:depth])
            examples.append(
                PolicyExample(
                    state=state,
                    perspective_group=perspective,
                    opponent_group=opponent,
                    prefix_actions=prefix,
                    candidate_actions=tuple(dict(action) for action, _ in ordered),
                    continuation_scores=tuple(score for _, score in ordered),
                )
            )
    return examples


class ActionFeaturizer:
    NUMERIC_FEATURES = 7

    def __init__(self, action_vocab: list[str], unit_vocab: list[str], max_radius: int = 5):
        self.action_vocab = list(action_vocab)
        self.unit_vocab = list(unit_vocab)
        self.action_to_id = {token: i for i, token in enumerate(self.action_vocab)}
        self.unit_to_id = {token: i for i, token in enumerate(self.unit_vocab)}
        self.max_radius = max(1, int(max_radius))

    def encode(self, state: dict[str, Any], action: dict[str, Any]) -> tuple[int, int, list[float]]:
        unit = find_unit(state, int(action.get("unit_id", -1)))
        action_key = str(action.get("action_key", UNKNOWN_TOKEN))
        actor_type = unit_type(unit)
        from_x, from_y = _cell(unit.get("cell", [0, 0]))
        to_x, to_y = _cell(action.get("end_point", [from_x, from_y]))
        path = action.get("path", [])
        path_len = len(path) if isinstance(path, list) else 0
        scale = float(self.max_radius)
        numeric = [
            from_x / scale,
            from_y / scale,
            to_x / scale,
            to_y / scale,
            (to_x - from_x) / scale,
            (to_y - from_y) / scale,
            min(path_len, self.max_radius * 2) / float(self.max_radius * 2),
        ]
        return (
            self.action_to_id.get(action_key, self.action_to_id.get(UNKNOWN_TOKEN, 0)),
            self.unit_to_id.get(actor_type, self.unit_to_id.get(UNKNOWN_TOKEN, 0)),
            numeric,
        )


class JointPlanPolicyHead(nn.Module):
    """Autoregressive action scorer conditioned on board state and chosen prefix."""

    def __init__(
        self,
        state_feature_size: int,
        action_vocab_size: int,
        unit_vocab_size: int,
        token_dim: int = 16,
        action_hidden: int = 32,
        prefix_hidden: int = 32,
    ) -> None:
        super().__init__()
        self.action_embedding = nn.Embedding(action_vocab_size, token_dim)
        self.unit_embedding = nn.Embedding(unit_vocab_size, token_dim)
        self.numeric = nn.Sequential(
            nn.Linear(ActionFeaturizer.NUMERIC_FEATURES, token_dim),
            nn.ReLU(inplace=True),
        )
        self.action_encoder = nn.Sequential(
            nn.Linear(token_dim * 3, action_hidden),
            nn.ReLU(inplace=True),
        )
        self.prefix_gru = nn.GRU(action_hidden, prefix_hidden, batch_first=True)
        self.scorer = nn.Sequential(
            nn.Linear(state_feature_size + prefix_hidden + action_hidden, 64),
            nn.ReLU(inplace=True),
            nn.Linear(64, 1),
        )
        self.prefix_hidden = prefix_hidden

    def encode_actions(
        self,
        action_ids: torch.Tensor,
        unit_ids: torch.Tensor,
        numeric: torch.Tensor,
    ) -> torch.Tensor:
        return self.action_encoder(
            torch.cat(
                [self.action_embedding(action_ids), self.unit_embedding(unit_ids), self.numeric(numeric)],
                dim=-1,
            )
        )

    def forward(
        self,
        state_features: torch.Tensor,
        prefix_action_ids: torch.Tensor,
        prefix_unit_ids: torch.Tensor,
        prefix_numeric: torch.Tensor,
        candidate_action_ids: torch.Tensor,
        candidate_unit_ids: torch.Tensor,
        candidate_numeric: torch.Tensor,
    ) -> torch.Tensor:
        if state_features.ndim != 2 or state_features.size(0) != 1:
            raise ValueError("state_features must have shape [1, features]")
        if prefix_action_ids.numel() == 0:
            prefix_state = state_features.new_zeros((1, self.prefix_hidden))
        else:
            prefix_encoded = self.encode_actions(prefix_action_ids, prefix_unit_ids, prefix_numeric).unsqueeze(0)
            _, hidden = self.prefix_gru(prefix_encoded)
            prefix_state = hidden[-1]
        candidates = self.encode_actions(candidate_action_ids, candidate_unit_ids, candidate_numeric)
        count = candidates.size(0)
        context = torch.cat(
            [state_features.expand(count, -1), prefix_state.expand(count, -1), candidates], dim=1
        )
        return self.scorer(context).squeeze(1)
