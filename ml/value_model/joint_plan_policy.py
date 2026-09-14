from __future__ import annotations

import math
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


def _complete_plan_actions(
    state: dict[str, Any], perspective: str, actions: Iterable[dict[str, Any]]
) -> list[dict[str, Any]]:
    completed = sorted_plan_actions(actions)
    selected = {int(a.get("unit_id", -1)) for a in completed}
    for group in _groups(state):
        if group.get("name") != perspective:
            continue
        for unit in group.get("units", []):
            if not isinstance(unit, dict):
                continue
            uid = int(unit.get("unit_id", -1))
            if unit.get("health", 0) <= 0 or uid in selected:
                continue
            if any(
                e.get("kind") == "Stun"
                and e.get("duration", 0) > 0
                and not e.get("pending_first_tick", False)
                for e in unit.get("effects", [])
                if isinstance(e, dict)
            ):
                continue
            completed.append(
                {
                    "unit_id": uid,
                    "action_key": "<hold>",
                    "end_point": unit.get("cell", [0, 0]),
                    "path": [],
                }
            )
    return sorted_plan_actions(completed)


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
        plan_rows = []
        plan_rows.extend(decision.get("candidates", []))
        plan_rows.extend(decision.get("mcts_visit_distribution", []))
        for candidate in plan_rows:
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
    target_probabilities: tuple[float, ...] | None = None

    @property
    def target_index(self) -> int:
        if self.target_probabilities is not None:
            return max(range(len(self.target_probabilities)), key=self.target_probabilities.__getitem__)
        return max(range(len(self.continuation_scores)), key=self.continuation_scores.__getitem__)

    @property
    def target_distribution(self) -> tuple[float, ...]:
        if self.target_probabilities is not None:
            total = sum(max(0.0, float(v)) for v in self.target_probabilities)
            if total <= 0:
                raise ValueError("policy target distribution has no positive mass")
            return tuple(max(0.0, float(v)) / total for v in self.target_probabilities)
        target = self.target_index
        return tuple(1.0 if i == target else 0.0 for i in range(len(self.candidate_actions)))


def build_search_distillation_examples(decision: dict[str, Any]) -> list[PolicyExample]:
    """Convert complete robust-search candidates into autoregressive prefix targets."""
    state = decision.get("starting_state", {})
    perspective = str(decision.get("perspective_group", ""))
    opponent = str(decision.get("opponent_group", ""))
    if not isinstance(state, dict) or not state or not perspective or not opponent:
        return []

    plans: list[tuple[list[dict[str, Any]], float]] = []
    for candidate in decision.get("candidates", []):
        if not isinstance(candidate, dict):
            continue
        actions = _complete_plan_actions(state, perspective, candidate.get("actions", []))
        if not actions:
            continue
        plans.append((actions, float(candidate.get("handwritten_worst_case_score", 0.0))))
    if not plans:
        return []

    examples: list[PolicyExample] = []
    max_depth = max(len(actions) for actions, _ in plans)
    for depth in range(max_depth):
        groups: dict[tuple[str, ...], list[tuple[list[dict[str, Any]], float]]] = {}
        for actions, score in plans:
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


def build_mcts_visit_examples(decision: dict[str, Any]) -> list[PolicyExample]:
    """Decompose an MCTS root plan-visit distribution into prefix-level soft targets."""
    state = decision.get("starting_state", {})
    perspective = str(decision.get("perspective_group", ""))
    opponent = str(decision.get("opponent_group", ""))
    if not isinstance(state, dict) or not state or not perspective or not opponent:
        return []

    plans: list[tuple[list[dict[str, Any]], float]] = []
    for row in decision.get("mcts_visit_distribution", []):
        if not isinstance(row, dict):
            continue
        mass = float(row.get("visits", 0.0))
        if mass <= 0:
            mass = float(row.get("probability", 0.0))
        if mass <= 0:
            continue
        actions = _complete_plan_actions(state, perspective, row.get("actions", []))
        if actions:
            plans.append((actions, mass))
    if not plans:
        return []

    examples: list[PolicyExample] = []
    max_depth = max(len(actions) for actions, _ in plans)
    for depth in range(max_depth):
        groups: dict[tuple[str, ...], list[tuple[list[dict[str, Any]], float]]] = {}
        for actions, mass in plans:
            if len(actions) <= depth:
                continue
            prefix_key = tuple(action_signature(action) for action in actions[:depth])
            groups.setdefault(prefix_key, []).append((actions, mass))

        for rows in groups.values():
            by_action: dict[str, tuple[dict[str, Any], float]] = {}
            for actions, mass in rows:
                action = actions[depth]
                signature = action_signature(action)
                if signature not in by_action:
                    by_action[signature] = (dict(action), 0.0)
                existing_action, existing_mass = by_action[signature]
                by_action[signature] = (existing_action, existing_mass + mass)
            if len(by_action) < 2:
                continue
            ordered = sorted(by_action.values(), key=lambda item: action_signature(item[0]))
            masses = tuple(float(mass) for _, mass in ordered)
            total = sum(masses)
            if total <= 0:
                continue
            prefix = tuple(dict(action) for action in rows[0][0][:depth])
            examples.append(
                PolicyExample(
                    state=state,
                    perspective_group=perspective,
                    opponent_group=opponent,
                    prefix_actions=prefix,
                    candidate_actions=tuple(dict(action) for action, _ in ordered),
                    continuation_scores=masses,
                    target_probabilities=tuple(mass / total for mass in masses),
                )
            )
    return examples


def build_policy_examples(decision: dict[str, Any]) -> list[PolicyExample]:
    if decision.get("mcts_visit_distribution"):
        return build_mcts_visit_examples(decision)
    return build_search_distillation_examples(decision)


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


class UnitEntityFeaturizer:
    """Keep living units as distinct entities before scattering them onto hexes."""

    NUMERIC_FEATURES = 4
    RELATION_COUNT = 2

    def __init__(self, unit_vocab: list[str], max_radius: int = 5):
        self.unit_vocab = list(unit_vocab)
        self.unit_to_id = {token: i for i, token in enumerate(self.unit_vocab)}
        self.max_radius = max(1, int(max_radius))

    def encode(
        self, state: dict[str, Any], perspective_group: str
    ) -> list[tuple[int, int, int, list[float], tuple[int, int]]]:
        rows: list[tuple[int, int, int, list[float], tuple[int, int]]] = []
        scale = float(self.max_radius)
        for group in _groups(state):
            relation_id = 0 if str(group.get("name", "")) == perspective_group else 1
            for unit in group.get("units", []):
                if not isinstance(unit, dict):
                    continue
                health = float(unit.get("health", 0.0))
                if health <= 0:
                    continue
                unit_id = int(unit.get("unit_id", -1))
                q, r = _cell(unit.get("cell", [0, 0]))
                max_health = max(1.0, float(unit.get("max_health", health)))
                energy = max(0.0, float(unit.get("energy", 0.0)))
                max_energy = max(0.0, float(unit.get("max_energy", 0.0)))
                energy_fraction = 0.0 if max_energy <= 0 else min(1.0, energy / max_energy)
                kind = unit_type(unit)
                rows.append((
                    unit_id,
                    self.unit_to_id.get(kind, self.unit_to_id.get(UNKNOWN_TOKEN, 0)),
                    relation_id,
                    [min(1.0, health / max_health), energy_fraction, q / scale, r / scale],
                    (q, r),
                ))
        rows.sort(key=lambda row: row[0])
        return rows


class JointPlanPolicyHead(nn.Module):
    """Legacy V1/V2 autoregressive scorer using only globally pooled state."""

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


class SpatialEntityJointPlanPolicyHead(nn.Module):
    """V3 policy: distinct unit entities plus candidate-conditioned attention over all hexes.

    No action-mechanics features (AOE, damage, legal escapes, etc.) are supplied. The
    policy must learn relevant spatial relationships from state/action supervision.
    """

    def __init__(
        self,
        state_feature_size: int,
        spatial_feature_size: int,
        action_vocab_size: int,
        unit_vocab_size: int,
        max_radius: int = 5,
        token_dim: int = 16,
        action_hidden: int = 32,
        prefix_hidden: int = 32,
        entity_dim: int = 32,
        relation_dim: int = 8,
        spatial_hidden: int = 32,
        attention_dim: int = 32,
        spatial_context_dim: int = 32,
    ) -> None:
        super().__init__()
        self.max_radius = max(1, int(max_radius))
        self.action_embedding = nn.Embedding(action_vocab_size, token_dim)
        self.action_unit_embedding = nn.Embedding(unit_vocab_size, token_dim)
        self.action_numeric = nn.Sequential(
            nn.Linear(ActionFeaturizer.NUMERIC_FEATURES, token_dim),
            nn.ReLU(inplace=True),
        )
        self.action_encoder = nn.Sequential(
            nn.Linear(token_dim * 3, action_hidden),
            nn.ReLU(inplace=True),
        )
        self.prefix_gru = nn.GRU(action_hidden, prefix_hidden, batch_first=True)

        self.entity_unit_embedding = nn.Embedding(unit_vocab_size, token_dim)
        self.entity_relation_embedding = nn.Embedding(UnitEntityFeaturizer.RELATION_COUNT, relation_dim)
        self.entity_numeric = nn.Sequential(
            nn.Linear(UnitEntityFeaturizer.NUMERIC_FEATURES, token_dim),
            nn.ReLU(inplace=True),
        )
        self.entity_encoder = nn.Sequential(
            nn.Linear(token_dim * 2 + relation_dim, entity_dim),
            nn.ReLU(inplace=True),
        )

        self.spatial_projector = nn.Sequential(
            nn.Linear(spatial_feature_size + entity_dim + 2, spatial_hidden),
            nn.ReLU(inplace=True),
        )
        query_input = action_hidden + prefix_hidden + entity_dim
        self.query = nn.Linear(query_input, attention_dim)
        self.keys = nn.Linear(spatial_hidden, attention_dim)
        self.values = nn.Linear(spatial_hidden, spatial_context_dim)
        self.scorer = nn.Sequential(
            nn.Linear(
                state_feature_size + prefix_hidden + action_hidden + entity_dim + spatial_context_dim,
                64,
            ),
            nn.ReLU(inplace=True),
            nn.Linear(64, 1),
        )
        self.prefix_hidden = prefix_hidden
        self.entity_dim = entity_dim
        self.attention_dim = attention_dim

    def encode_actions(
        self,
        action_ids: torch.Tensor,
        unit_ids: torch.Tensor,
        numeric: torch.Tensor,
    ) -> torch.Tensor:
        return self.action_encoder(torch.cat([
            self.action_embedding(action_ids),
            self.action_unit_embedding(unit_ids),
            self.action_numeric(numeric),
        ], dim=-1))

    def encode_entities(
        self,
        entity_type_ids: torch.Tensor,
        entity_relation_ids: torch.Tensor,
        entity_numeric: torch.Tensor,
    ) -> torch.Tensor:
        if entity_type_ids.numel() == 0:
            return entity_numeric.new_zeros((0, self.entity_dim))
        return self.entity_encoder(torch.cat([
            self.entity_unit_embedding(entity_type_ids),
            self.entity_relation_embedding(entity_relation_ids),
            self.entity_numeric(entity_numeric),
        ], dim=-1))

    def _prefix_state(
        self,
        state_features: torch.Tensor,
        prefix_action_ids: torch.Tensor,
        prefix_unit_ids: torch.Tensor,
        prefix_numeric: torch.Tensor,
    ) -> torch.Tensor:
        if prefix_action_ids.numel() == 0:
            return state_features.new_zeros((1, self.prefix_hidden))
        encoded = self.encode_actions(prefix_action_ids, prefix_unit_ids, prefix_numeric).unsqueeze(0)
        _, hidden = self.prefix_gru(encoded)
        return hidden[-1]

    def _spatial_tokens(
        self,
        spatial_features: torch.Tensor,
        entity_vectors: torch.Tensor,
        entity_rows: torch.Tensor,
        entity_cols: torch.Tensor,
    ) -> torch.Tensor:
        if spatial_features.ndim != 4 or spatial_features.size(0) != 1:
            raise ValueError("spatial_features must have shape [1, channels, height, width]")
        _, _, height, width = spatial_features.shape
        backbone = spatial_features[0].permute(1, 2, 0).reshape(height * width, -1)
        scattered = spatial_features.new_zeros((height * width, self.entity_dim))
        if entity_vectors.numel():
            flat_indices = entity_rows * width + entity_cols
            scattered.index_add_(0, flat_indices, entity_vectors)

        row_grid, col_grid = torch.meshgrid(
            torch.arange(height, device=spatial_features.device, dtype=spatial_features.dtype),
            torch.arange(width, device=spatial_features.device, dtype=spatial_features.dtype),
            indexing="ij",
        )
        scale = float(self.max_radius)
        coordinates = torch.stack([
            (col_grid.reshape(-1) - self.max_radius) / scale,
            (row_grid.reshape(-1) - self.max_radius) / scale,
        ], dim=1)
        return self.spatial_projector(torch.cat([backbone, scattered, coordinates], dim=1))

    def forward(
        self,
        state_features: torch.Tensor,
        spatial_features: torch.Tensor,
        valid_mask: torch.Tensor,
        entity_type_ids: torch.Tensor,
        entity_relation_ids: torch.Tensor,
        entity_numeric: torch.Tensor,
        entity_rows: torch.Tensor,
        entity_cols: torch.Tensor,
        prefix_action_ids: torch.Tensor,
        prefix_unit_ids: torch.Tensor,
        prefix_numeric: torch.Tensor,
        candidate_action_ids: torch.Tensor,
        candidate_unit_ids: torch.Tensor,
        candidate_numeric: torch.Tensor,
        candidate_entity_indices: torch.Tensor,
    ) -> torch.Tensor:
        if state_features.ndim != 2 or state_features.size(0) != 1:
            raise ValueError("state_features must have shape [1, features]")
        if valid_mask.ndim != 4 or valid_mask.size(0) != 1 or valid_mask.size(1) != 1:
            raise ValueError("valid_mask must have shape [1, 1, height, width]")

        prefix_state = self._prefix_state(state_features, prefix_action_ids, prefix_unit_ids, prefix_numeric)
        candidates = self.encode_actions(candidate_action_ids, candidate_unit_ids, candidate_numeric)
        entity_vectors = self.encode_entities(entity_type_ids, entity_relation_ids, entity_numeric)
        count = candidates.size(0)

        actor_vectors = state_features.new_zeros((count, self.entity_dim))
        if entity_vectors.size(0):
            valid_actor = (candidate_entity_indices >= 0) & (candidate_entity_indices < entity_vectors.size(0))
            safe_indices = candidate_entity_indices.clamp(0, entity_vectors.size(0) - 1)
            actor_vectors = entity_vectors[safe_indices] * valid_actor.to(entity_vectors.dtype).unsqueeze(1)

        spatial_tokens = self._spatial_tokens(
            spatial_features, entity_vectors, entity_rows, entity_cols
        )
        prefix_expanded = prefix_state.expand(count, -1)
        query_input = torch.cat([candidates, prefix_expanded, actor_vectors], dim=1)
        queries = self.query(query_input)
        keys = self.keys(spatial_tokens)
        values = self.values(spatial_tokens)
        attention_logits = queries @ keys.transpose(0, 1) / math.sqrt(float(self.attention_dim))
        valid_cells = valid_mask[0, 0].reshape(-1).bool()
        if not bool(valid_cells.any()):
            raise ValueError("spatial policy requires at least one valid hex")
        attention_logits = attention_logits.masked_fill(~valid_cells.unsqueeze(0), torch.finfo(attention_logits.dtype).min)
        attention = torch.softmax(attention_logits, dim=1)
        spatial_context = attention @ values

        context = torch.cat([
            state_features.expand(count, -1),
            prefix_expanded,
            candidates,
            actor_vectors,
            spatial_context,
        ], dim=1)
        return self.scorer(context).squeeze(1)
