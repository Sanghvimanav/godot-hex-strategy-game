extends RefCounted
class_name GameplayAI
## Canonical pure-state action-selection entry point.
##
## Gameplay, self-play, and future arenas should call choose_actions instead of
## depending directly on a concrete search or evaluator. Tactical tests may still
## call lower-level search classes when they intentionally inspect candidate sets.

const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStatePolicyExploration = preload("res://src/simulation/pure_state_policy_exploration.gd")

const POLICY_OPPONENT_RESPONSE := "opponent_response"
const EVALUATOR_HANDWRITTEN := "handwritten"

const DEFAULT_SETTINGS := {
	"policy": POLICY_OPPONENT_RESPONSE,
	"evaluator": EVALUATOR_HANDWRITTEN,
	"own_max_actions_per_unit": PureStateOpponentResponseSearch.DEFAULT_OWN_MAX_ACTIONS_PER_UNIT,
	"own_max_plans": PureStateOpponentResponseSearch.DEFAULT_OWN_MAX_PLANS,
	"opponent_max_actions_per_unit": PureStateOpponentResponseSearch.DEFAULT_OPPONENT_MAX_ACTIONS_PER_UNIT,
	"opponent_max_plans": PureStateOpponentResponseSearch.DEFAULT_OPPONENT_MAX_PLANS,
	"fixed_other_group_actions": {},
	"exploration_profile": PureStatePolicyExploration.PROFILE_GREEDY,
	"exploration_seed": 0,
}


static func choose_actions(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	settings: Dictionary = {}
) -> Dictionary:
	var resolved := resolve_settings(settings)
	var policy := str(resolved.get("policy", ""))
	var evaluator := str(resolved.get("evaluator", ""))
	var exploration_profile := str(resolved.get("exploration_profile", PureStatePolicyExploration.PROFILE_GREEDY))
	var exploration_seed := int(resolved.get("exploration_seed", 0))

	if policy != POLICY_OPPONENT_RESPONSE:
		return _invalid_result("unsupported_policy", resolved)
	if evaluator != EVALUATOR_HANDWRITTEN:
		return _invalid_result("unsupported_evaluator", resolved)
	if not PureStatePolicyExploration.is_supported_profile(exploration_profile):
		return _invalid_result("unsupported_exploration_profile", resolved)

	var fixed_actions_variant = resolved.get("fixed_other_group_actions", {})
	if not (fixed_actions_variant is Dictionary):
		return _invalid_result("invalid_fixed_other_group_actions", resolved)
	var fixed_actions: Dictionary = fixed_actions_variant

	var search := PureStateOpponentResponseSearch.search(
		game_state,
		group_name,
		opponent_group_name,
		int(resolved.get("own_max_actions_per_unit", 0)),
		int(resolved.get("own_max_plans", 0)),
		int(resolved.get("opponent_max_actions_per_unit", 0)),
		int(resolved.get("opponent_max_plans", 0)),
		fixed_actions
	)
	if not bool(search.get("valid", false)):
		return _invalid_result("decision_failed", resolved, search)

	var selection := PureStatePolicyExploration.select_result(
		search,
		game_state,
		group_name,
		exploration_profile,
		exploration_seed
	)
	if selection.is_empty():
		return _invalid_result("exploration_selection_failed", resolved, search)
	var actions: Array = (selection.get("actions", []) as Array).duplicate(true)
	var diagnostics := search.duplicate(true)
	diagnostics["selected_actions"] = actions.duplicate(true)
	diagnostics["exploration"] = selection.duplicate(true)

	return {
		"valid": true,
		"error": "",
		"actions": actions,
		"policy": policy,
		"evaluator": evaluator,
		"settings": resolved.duplicate(true),
		"diagnostics": diagnostics,
	}


static func resolve_settings(overrides: Dictionary = {}) -> Dictionary:
	var resolved := DEFAULT_SETTINGS.duplicate(true)
	for key_variant in overrides.keys():
		resolved[key_variant] = overrides[key_variant]
	return resolved


static func handwritten_settings(
	own_max_actions_per_unit: int,
	own_max_plans: int,
	opponent_max_actions_per_unit: int,
	opponent_max_plans: int
) -> Dictionary:
	return resolve_settings({
		"own_max_actions_per_unit": own_max_actions_per_unit,
		"own_max_plans": own_max_plans,
		"opponent_max_actions_per_unit": opponent_max_actions_per_unit,
		"opponent_max_plans": opponent_max_plans,
	})


static func _invalid_result(
	error: String,
	settings: Dictionary,
	diagnostics: Dictionary = {}
) -> Dictionary:
	return {
		"valid": false,
		"error": error,
		"actions": [],
		"policy": str(settings.get("policy", "")),
		"evaluator": str(settings.get("evaluator", "")),
		"settings": settings.duplicate(true),
		"diagnostics": diagnostics.duplicate(true),
	}
