from __future__ import annotations

from typing import Any

from .joint_plan_policy import (
    PolicyExample,
    _complete_plan_actions,
    action_signature,
    build_mcts_visit_examples,
)


TIE_TOLERANCE = 1e-9


def build_tie_aware_search_distillation_examples(
    decision: dict[str, Any], *, tie_tolerance: float = TIE_TOLERANCE
) -> list[PolicyExample]:
    """Build robust-search policy targets without arbitrary coordinate tie-breaking.

    Rules:
    - unique best action: ordinary one-hot target;
    - multiple tied best actions with at least one worse action: uniform mass over
      the tied best actions;
    - every action tied: skip the prefix because robust search expressed no
      preference at all.

    Candidate ordering is still deterministic for reproducibility, but ordering can
    no longer manufacture a policy preference.
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
                    by_action[signature] = (dict(action), score)
            if len(by_action) < 2:
                continue

            ordered = sorted(by_action.values(), key=lambda item: action_signature(item[0]))
            scores = tuple(float(score) for _, score in ordered)
            best = max(scores)
            winners = [index for index, score in enumerate(scores) if abs(score - best) <= tie_tolerance]
            if len(winners) == len(scores):
                # Fully tied robust scores contain no preference signal.
                continue
            mass = 1.0 / float(len(winners))
            target = tuple(mass if index in winners else 0.0 for index in range(len(scores)))
            prefix = tuple(dict(action) for action in rows[0][0][:depth])
            examples.append(
                PolicyExample(
                    state=state,
                    perspective_group=perspective,
                    opponent_group=opponent,
                    prefix_actions=prefix,
                    candidate_actions=tuple(dict(action) for action, _ in ordered),
                    continuation_scores=scores,
                    target_probabilities=target,
                )
            )
    return examples


def build_policy_examples_tie_aware(decision: dict[str, Any]) -> list[PolicyExample]:
    """Canonical policy-target entry point for any future robust/MCTS mixtures."""
    if decision.get("mcts_visit_distribution"):
        return build_mcts_visit_examples(decision)
    return build_tie_aware_search_distillation_examples(decision)
