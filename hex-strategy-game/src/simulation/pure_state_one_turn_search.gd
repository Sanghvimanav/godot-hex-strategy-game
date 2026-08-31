extends RefCounted
class_name PureStateOneTurnSearch
## First complete tactical search loop for the pure-state AI stack.
##
## Search is one simultaneous turn deep:
##   candidate own plans -> simulate against fixed other-group actions -> evaluate
##
## This intentionally does not predict opponent actions yet. Callers may supply
## fixed actions for any other group; omitted groups are assumed to submit none.
## Opponent-response search / belief-state sampling belongs in a later layer.

const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")

const DEFAULT_MAX_ACTIONS_PER_UNIT := 8
const DEFAULT_MAX_PLANS := 50


## Returns the best one-turn plan for group_name under fixed other-group actions.
##
## other_group_actions is a mapping such as:
## {
##   "terran": [ ...actions... ],
## }
##
## Result shape:
## {
##   "valid": bool,
##   "group_name": String,
##   "candidates_considered": int,
##   "best_actions": Array[Dictionary],
##   "best_proposal_score": float,
##   "best_evaluation_score": float,
##   "best_evaluation_breakdown": Dictionary,
##   "best_next_state": Dictionary,
##   "best_recording": Dictionary,
##   "ranked_results": Array[Dictionary],
## }
##
## ranked_results intentionally excludes full next-state snapshots to keep the
## result compact as the game grows; only the winning candidate retains them.
static func search(
	game_state: Dictionary,
	group_name: String,
	other_group_actions: Dictionary = {},
	max_actions_per_unit: int = DEFAULT_MAX_ACTIONS_PER_UNIT,
	max_plans: int = DEFAULT_MAX_PLANS
) -> Dictionary:
	var invalid := _empty_result(group_name)
	if group_name.is_empty() or max_actions_per_unit <= 0 or max_plans <= 0:
		return invalid
	if not _has_group(game_state, group_name):
		return invalid

	var candidates := PureStatePlans.get_candidate_plans(
		game_state,
		group_name,
		max_actions_per_unit,
		max_plans
	)
	if candidates.is_empty():
		return invalid

	var ranked: Array = []
	var best_full: Dictionary = {}
	for candidate_variant in candidates:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var own_actions: Array = candidate.get("actions", []).duplicate(true)
		var player_actions := _build_player_actions(game_state, group_name, own_actions, other_group_actions)
		var simulation := PureStateSimulator.simulate_turn(game_state, player_actions)
		var next_state: Dictionary = simulation.get("next_state", {})
		var breakdown := PureStateEvaluator.evaluate_breakdown(next_state, group_name)
		var result := {
			"actions": own_actions,
			"proposal_score": float(candidate.get("proposal_score", 0.0)),
			"evaluation_score": float(breakdown.get("total", 0.0)),
			"evaluation_breakdown": breakdown.duplicate(true),
		}
		ranked.append(result)

		if best_full.is_empty() or _result_before(result, best_full):
			best_full = result.duplicate(true)
			best_full["next_state"] = next_state.duplicate(true)
			best_full["recording"] = (simulation.get("recording", {}) as Dictionary).duplicate(true)

	if ranked.is_empty() or best_full.is_empty():
		return invalid

	ranked.sort_custom(_result_before)
	return {
		"valid": true,
		"group_name": group_name,
		"candidates_considered": ranked.size(),
		"best_actions": (best_full.get("actions", []) as Array).duplicate(true),
		"best_proposal_score": float(best_full.get("proposal_score", 0.0)),
		"best_evaluation_score": float(best_full.get("evaluation_score", 0.0)),
		"best_evaluation_breakdown": (best_full.get("evaluation_breakdown", {}) as Dictionary).duplicate(true),
		"best_next_state": (best_full.get("next_state", {}) as Dictionary).duplicate(true),
		"best_recording": (best_full.get("recording", {}) as Dictionary).duplicate(true),
		"ranked_results": ranked,
	}


static func _build_player_actions(
	game_state: Dictionary,
	group_name: String,
	own_actions: Array,
	other_group_actions: Dictionary
) -> Dictionary:
	var submitted: Dictionary = {}
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var name := str(group_variant.get("name", ""))
		if name.is_empty():
			continue
		submitted[name] = []

	for other_name_variant in other_group_actions.keys():
		var other_name := str(other_name_variant)
		if other_name == group_name:
			continue
		var actions_variant = other_group_actions.get(other_name_variant, [])
		if actions_variant is Array:
			submitted[other_name] = actions_variant.duplicate(true)

	submitted[group_name] = own_actions.duplicate(true)
	return submitted


static func _has_group(game_state: Dictionary, group_name: String) -> bool:
	for group_variant in game_state.get("groups", []):
		if group_variant is Dictionary and str(group_variant.get("name", "")) == group_name:
			return true
	return false


static func _empty_result(group_name: String) -> Dictionary:
	return {
		"valid": false,
		"group_name": group_name,
		"candidates_considered": 0,
		"best_actions": [],
		"best_proposal_score": 0.0,
		"best_evaluation_score": 0.0,
		"best_evaluation_breakdown": {},
		"best_next_state": {},
		"best_recording": {},
		"ranked_results": [],
	}


static func _result_before(a: Dictionary, b: Dictionary) -> bool:
	var a_eval := float(a.get("evaluation_score", 0.0))
	var b_eval := float(b.get("evaluation_score", 0.0))
	if not is_equal_approx(a_eval, b_eval):
		return a_eval > b_eval
	var a_proposal := float(a.get("proposal_score", 0.0))
	var b_proposal := float(b.get("proposal_score", 0.0))
	if not is_equal_approx(a_proposal, b_proposal):
		return a_proposal > b_proposal
	return _plan_signature(a.get("actions", [])) < _plan_signature(b.get("actions", []))


static func _plan_signature(actions: Array) -> String:
	var parts: PackedStringArray = []
	for action_variant in actions:
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		parts.append("%08d|%s|%s|%s" % [
			int(action.get("unit_id", -1)),
			str(action.get("action_key", "")),
			str(action.get("end_point", [])),
			str(action.get("path", [])),
		])
	return ";".join(parts)
