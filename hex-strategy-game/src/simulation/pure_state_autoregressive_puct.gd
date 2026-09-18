extends RefCounted
class_name PureStateAutoregressivePUCT
## Training-only autoregressive PUCT over raw legal per-unit actions.
##
## Unlike PureStateSimultaneousPUCT, this search never asks a bounded joint-plan
## proposal generator which actions MCTS is allowed to see. At each autoregressive
## prefix it enumerates every engine-legal action for the next unit, adds the
## explicit hold choice used by the learned joint policy, forces one rollout through
## every choice, then spends any remaining simulations with PUCT.
##
## Rollout completion also scores the full legal action set unit-by-unit. No AOE,
## damage, range, hit-footprint, or other handwritten mechanics are supplied to the
## neural policy; consequences are learned only through simulation and value/outcome.

const PureStateLegalActions = preload("res://src/simulation/pure_state_legal_actions.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")

const DEFAULT_SIMULATIONS := 24
const DEFAULT_C_PUCT := 1.5
const DEFAULT_ROLLOUT_DEPTH := 3
const MIN_POST_COVERAGE_SIMULATIONS := 8


static func choose_plan(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	checkpoint_path: String,
	settings: Dictionary = {}
) -> Dictionary:
	if checkpoint_path.is_empty() or group_name.is_empty() or opponent_group_name.is_empty():
		return {"valid": false, "error": "invalid_prefix_puct_request"}
	var requested_simulations := maxi(1, int(settings.get("puct_simulations", DEFAULT_SIMULATIONS)))
	var c_puct := maxf(0.0, float(settings.get("puct_c", DEFAULT_C_PUCT)))
	var rollout_depth := maxi(1, int(settings.get("rollout_depth", DEFAULT_ROLLOUT_DEPTH)))
	var seed := int(settings.get("seed", 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	var prefix: Array = []
	var prefix_targets: Array = []
	var min_exposure_coverage := 1.0
	var min_visit_coverage := 1.0
	var zero_visit_count := 0
	var units := _decision_units(game_state, group_name)
	for unit_variant in units:
		var unit: Dictionary = unit_variant
		var unit_id := int(unit.get("unit_id", -1))
		var engine_legal := PureStateLegalActions.get_legal_actions(game_state, unit_id)
		var candidates := _planning_actions(unit, engine_legal)
		if candidates.is_empty():
			continue

		var scored := PureStateJointPolicy.score_actions(
			game_state,
			group_name,
			opponent_group_name,
			prefix,
			candidates,
			{"checkpoint_path": checkpoint_path}
		)
		if not bool(scored.get("ok", false)):
			return {"valid": false, "error": "policy_scoring_failed", "detail": scored}
		var scores: Array = scored.get("scores", [])
		if scores.size() != candidates.size():
			return {"valid": false, "error": "policy_score_count_mismatch"}
		var priors := _softmax(scores)
		var edges: Array = []
		for index in range(candidates.size()):
			edges.append({
				"action": (candidates[index] as Dictionary).duplicate(true),
				"prior": float(priors[index]),
				"visits": 0,
				"value_sum": 0.0,
				"q": 0.0,
			})

		# Coverage phase: every legal planning action gets a real simulated visit
		# before prior-guided PUCT may revisit anything.
		for edge_index in range(edges.size()):
			var rollout := _rollout_value(
				game_state,
				group_name,
				opponent_group_name,
				prefix,
				(edges[edge_index] as Dictionary).get("action", {}),
				checkpoint_path,
				rollout_depth,
				rng
			)
			if not bool(rollout.get("valid", false)):
				return {"valid": false, "error": "coverage_rollout_failed", "detail": rollout}
			_update_edge(edges, edge_index, float(rollout.get("value", 0.0)))

		var simulations_run := edges.size()
		# Coverage visits are deliberately not allowed to consume the entire search.
		# Every prefix receives a real prior-guided PUCT phase after all legal actions
		# have been seen once, so the visit distribution can express a preference.
		var simulations_target := maxi(
			requested_simulations,
			edges.size() + MIN_POST_COVERAGE_SIMULATIONS
		)
		while simulations_run < simulations_target:
			var selected_index := _select_puct(edges, simulations_run, c_puct)
			if selected_index < 0:
				return {"valid": false, "error": "puct_selection_failed"}
			var rollout := _rollout_value(
				game_state,
				group_name,
				opponent_group_name,
				prefix,
				(edges[selected_index] as Dictionary).get("action", {}),
				checkpoint_path,
				rollout_depth,
				rng
			)
			if not bool(rollout.get("valid", false)):
				return {"valid": false, "error": "puct_rollout_failed", "detail": rollout}
			_update_edge(edges, selected_index, float(rollout.get("value", 0.0)))
			simulations_run += 1

		var exposed_count := edges.size()
		var visited_count := 0
		var visit_total := 0
		var zero_visit_actions: Array = []
		for edge_variant in edges:
			var edge: Dictionary = edge_variant
			var visits := int(edge.get("visits", 0))
			visit_total += visits
			if visits > 0:
				visited_count += 1
			else:
				zero_visit_actions.append((edge.get("action", {}) as Dictionary).duplicate(true))
		var legal_count := candidates.size()
		var exposure_coverage := float(exposed_count) / float(maxi(1, legal_count))
		var visit_coverage := float(visited_count) / float(maxi(1, legal_count))
		var post_coverage_puct_visits := simulations_run - legal_count
		min_exposure_coverage = minf(min_exposure_coverage, exposure_coverage)
		min_visit_coverage = minf(min_visit_coverage, visit_coverage)
		zero_visit_count += zero_visit_actions.size()
		if exposed_count != legal_count or visited_count != legal_count or not zero_visit_actions.is_empty():
			return {
				"valid": false,
				"error": "incomplete_legal_action_coverage",
				"unit_id": unit_id,
				"legal": legal_count,
				"exposed": exposed_count,
				"visited": visited_count,
				"zero_visit_actions": zero_visit_actions,
			}
		if post_coverage_puct_visits < MIN_POST_COVERAGE_SIMULATIONS:
			return {
				"valid": false,
				"error": "insufficient_post_coverage_puct",
				"unit_id": unit_id,
				"legal": legal_count,
				"simulations_run": simulations_run,
				"post_coverage_puct_visits": post_coverage_puct_visits,
			}

		var selected_action := _best_edge_action(edges)
		var visit_distribution: Array = []
		var prior_distribution: Array = []
		var visit_probabilities: Array = []
		var prior_probabilities: Array = []
		for edge_variant in edges:
			var edge: Dictionary = edge_variant
			var visits := int(edge.get("visits", 0))
			var visit_probability := float(visits) / float(maxi(1, visit_total))
			var prior := float(edge.get("prior", 0.0))
			visit_distribution.append({
				"action": (edge.get("action", {}) as Dictionary).duplicate(true),
				"visits": visits,
				"probability": visit_probability,
				"prior": prior,
				"q": float(edge.get("q", 0.0)),
			})
			prior_distribution.append({
				"action": (edge.get("action", {}) as Dictionary).duplicate(true),
				"probability": prior,
			})
			visit_probabilities.append(visit_probability)
			prior_probabilities.append(prior)
		prefix_targets.append({
			"schema_version": 1,
			"target_type": "autoregressive_mcts_visit_distribution_v1",
			"perspective_group": group_name,
			"opponent_group": opponent_group_name,
			"starting_state": game_state.duplicate(true),
			"unit_id": unit_id,
			"prefix_actions": prefix.duplicate(true),
			"selected_action": selected_action.duplicate(true),
			"candidate_actions": candidates.duplicate(true),
			"visit_distribution": visit_distribution,
			"prior_distribution": prior_distribution,
			"engine_legal_action_count": engine_legal.size(),
			"legal_action_count": legal_count,
			"exposed_action_count": exposed_count,
			"visited_action_count": visited_count,
			"exposure_coverage": exposure_coverage,
			"visit_coverage": visit_coverage,
			"zero_visit_actions": zero_visit_actions,
			"puct_simulations_requested": requested_simulations,
			"puct_simulations_run": simulations_run,
			"forced_coverage_visits": legal_count,
			"post_coverage_puct_visits": post_coverage_puct_visits,
			"minimum_post_coverage_puct_visits": MIN_POST_COVERAGE_SIMULATIONS,
			"puct_c": c_puct,
			"rollout_depth": rollout_depth,
			"prior_entropy": _entropy(prior_probabilities),
			"visit_entropy": _entropy(visit_probabilities),
			"mcts_vs_prior_kl": _kl_divergence(visit_probabilities, prior_probabilities),
			"all_legal_actions_exposed": true,
			"all_legal_actions_visited": true,
			"explicit_action_mechanics": false,
		})
		prefix.append(selected_action.duplicate(true))

	return {
		"valid": true,
		"actions": prefix,
		"prefix_targets": prefix_targets,
		"prefix_count": prefix_targets.size(),
		"min_exposure_coverage": min_exposure_coverage,
		"min_visit_coverage": min_visit_coverage,
		"zero_visit_action_count": zero_visit_count,
		"search_type": "autoregressive_prefix_puct",
		"explicit_action_mechanics": false,
	}


static func _rollout_value(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	prefix: Array,
	candidate: Dictionary,
	checkpoint_path: String,
	rollout_depth: int,
	rng: RandomNumberGenerator
) -> Dictionary:
	var own_seed := prefix.duplicate(true)
	own_seed.append(candidate.duplicate(true))
	var own_plan_result := _complete_plan(
		game_state, group_name, opponent_group_name, own_seed, checkpoint_path, rng
	)
	if not bool(own_plan_result.get("valid", false)):
		return own_plan_result
	var opponent_plan_result := _complete_plan(
		game_state, opponent_group_name, group_name, [], checkpoint_path, rng
	)
	if not bool(opponent_plan_result.get("valid", false)):
		return opponent_plan_result
	var state := game_state.duplicate(true)
	var own_plan: Array = own_plan_result.get("actions", [])
	var opponent_plan: Array = opponent_plan_result.get("actions", [])

	for depth_index in range(rollout_depth):
		var submitted := {
			group_name: own_plan.duplicate(true),
			opponent_group_name: opponent_plan.duplicate(true),
		}
		var simulation := PureStateSimulator.simulate_turn(state, submitted)
		var next_variant = simulation.get("next_state", {})
		if not (next_variant is Dictionary) or (next_variant as Dictionary).is_empty():
			return {"valid": false, "error": "rollout_simulation_failed"}
		var next_state: Dictionary = (next_variant as Dictionary).duplicate(true)
		next_state["turn_index"] = int(state.get("turn_index", 0)) + 1
		var terminal := _terminal_value(next_state, group_name, opponent_group_name)
		if bool(terminal.get("terminal", false)):
			return {"valid": true, "value": float(terminal.get("value", 0.0)), "terminal": true}
		state = next_state
		if depth_index + 1 >= rollout_depth:
			break
		own_plan_result = _complete_plan(state, group_name, opponent_group_name, [], checkpoint_path, rng)
		opponent_plan_result = _complete_plan(state, opponent_group_name, group_name, [], checkpoint_path, rng)
		if not bool(own_plan_result.get("valid", false)) or not bool(opponent_plan_result.get("valid", false)):
			return {"valid": false, "error": "rollout_policy_completion_failed"}
		own_plan = own_plan_result.get("actions", [])
		opponent_plan = opponent_plan_result.get("actions", [])

	var evaluation := PureStateNeuralEvaluator.evaluate_breakdown(
		state,
		group_name,
		opponent_group_name,
		{"checkpoint_path": checkpoint_path}
	)
	if not bool(evaluation.get("valid", false)):
		return {"valid": false, "error": "rollout_value_failed", "detail": evaluation}
	return {
		"valid": true,
		"value": clampf(float(evaluation.get("model_value", 0.0)), -1.0, 1.0),
		"terminal": false,
	}


static func _complete_plan(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	seed_prefix: Array,
	checkpoint_path: String,
	rng: RandomNumberGenerator
) -> Dictionary:
	var prefix := seed_prefix.duplicate(true)
	var selected_units: Dictionary = {}
	for action_variant in prefix:
		if action_variant is Dictionary:
			selected_units[int((action_variant as Dictionary).get("unit_id", -1))] = true
	var units := _decision_units(game_state, group_name)
	for unit_variant in units:
		var unit: Dictionary = unit_variant
		var unit_id := int(unit.get("unit_id", -1))
		if selected_units.has(unit_id):
			continue
		var engine_legal := PureStateLegalActions.get_legal_actions(game_state, unit_id)
		var candidates := _planning_actions(unit, engine_legal)
		if candidates.is_empty():
			continue
		var scored := PureStateJointPolicy.score_actions(
			game_state,
			group_name,
			opponent_group_name,
			prefix,
			candidates,
			{"checkpoint_path": checkpoint_path}
		)
		if not bool(scored.get("ok", false)):
			return {"valid": false, "error": "rollout_policy_scoring_failed", "detail": scored}
		var scores: Array = scored.get("scores", [])
		if scores.size() != candidates.size():
			return {"valid": false, "error": "rollout_policy_score_count_mismatch"}
		var probabilities := _softmax(scores)
		var picked := _sample_index(probabilities, rng)
		if picked < 0:
			return {"valid": false, "error": "rollout_policy_sample_failed"}
		prefix.append((candidates[picked] as Dictionary).duplicate(true))
	return {"valid": true, "actions": prefix}


static func _decision_units(game_state: Dictionary, group_name: String) -> Array:
	var result: Array = []
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			if int(unit.get("health", 0)) <= 0:
				continue
			var legal := PureStateLegalActions.get_legal_actions(game_state, int(unit.get("unit_id", -1)))
			if legal.is_empty():
				continue
			result.append(unit)
	result.sort_custom(func(a, b): return int(a.get("unit_id", -1)) < int(b.get("unit_id", -1)))
	return result


static func _planning_actions(unit: Dictionary, engine_legal: Array) -> Array:
	var by_signature: Dictionary = {}
	for action_variant in engine_legal:
		if action_variant is Dictionary:
			var action: Dictionary = (action_variant as Dictionary).duplicate(true)
			by_signature[_action_signature(action)] = action
	var cell: Array = unit.get("cell", [0, 0])
	var hold := {
		"unit_id": int(unit.get("unit_id", -1)),
		"action_key": "<hold>",
		"path": [],
		"end_point": cell.duplicate(),
	}
	by_signature[_action_signature(hold)] = hold
	var result: Array = []
	var keys := by_signature.keys()
	keys.sort()
	for key_variant in keys:
		result.append((by_signature[key_variant] as Dictionary).duplicate(true))
	return result


static func _softmax(scores: Array) -> Array:
	if scores.is_empty():
		return []
	var maximum := -INF
	for score_variant in scores:
		maximum = maxf(maximum, float(score_variant))
	var result: Array = []
	var total := 0.0
	for score_variant in scores:
		var weight := exp(float(score_variant) - maximum)
		result.append(weight)
		total += weight
	if total <= 0.0:
		var uniform := 1.0 / float(scores.size())
		return Array(scores.map(func(_unused): return uniform))
	for index in range(result.size()):
		result[index] = float(result[index]) / total
	return result


static func _select_puct(edges: Array, total_visits: int, c_puct: float) -> int:
	var parent_scale := sqrt(float(maxi(1, total_visits)))
	var best_index := -1
	var best_score := -INF
	for index in range(edges.size()):
		var edge: Dictionary = edges[index]
		var visits := int(edge.get("visits", 0))
		var q := float(edge.get("q", 0.0))
		var prior := float(edge.get("prior", 0.0))
		var score := q + c_puct * prior * parent_scale / float(1 + visits)
		if best_index < 0 or score > best_score:
			best_index = index
			best_score = score
		elif is_equal_approx(score, best_score):
			var best: Dictionary = edges[best_index]
			if prior > float(best.get("prior", 0.0)):
				best_index = index
	return best_index


static func _update_edge(edges: Array, index: int, value: float) -> void:
	var edge: Dictionary = edges[index]
	var visits := int(edge.get("visits", 0)) + 1
	edge["visits"] = visits
	edge["value_sum"] = float(edge.get("value_sum", 0.0)) + value
	edge["q"] = float(edge["value_sum"]) / float(visits)
	edges[index] = edge


static func _best_edge_action(edges: Array) -> Dictionary:
	var best_index := 0
	for index in range(1, edges.size()):
		var candidate: Dictionary = edges[index]
		var best: Dictionary = edges[best_index]
		var candidate_visits := int(candidate.get("visits", 0))
		var best_visits := int(best.get("visits", 0))
		if candidate_visits > best_visits:
			best_index = index
			continue
		if candidate_visits < best_visits:
			continue
		var candidate_q := float(candidate.get("q", 0.0))
		var best_q := float(best.get("q", 0.0))
		if candidate_q > best_q and not is_equal_approx(candidate_q, best_q):
			best_index = index
			continue
		if not is_equal_approx(candidate_q, best_q):
			continue
		var candidate_prior := float(candidate.get("prior", 0.0))
		var best_prior := float(best.get("prior", 0.0))
		if candidate_prior > best_prior and not is_equal_approx(candidate_prior, best_prior):
			best_index = index
			continue
		if is_equal_approx(candidate_prior, best_prior):
			if _action_signature(candidate.get("action", {})) < _action_signature(best.get("action", {})):
				best_index = index
	return ((edges[best_index] as Dictionary).get("action", {}) as Dictionary).duplicate(true)


static func _sample_index(probabilities: Array, rng: RandomNumberGenerator) -> int:
	if probabilities.is_empty():
		return -1
	var needle := rng.randf()
	var cumulative := 0.0
	for index in range(probabilities.size()):
		cumulative += maxf(0.0, float(probabilities[index]))
		if needle <= cumulative:
			return index
	return probabilities.size() - 1


static func _terminal_value(state: Dictionary, group_name: String, opponent_group_name: String) -> Dictionary:
	var own_alive := _alive_count(state, group_name)
	var opponent_alive := _alive_count(state, opponent_group_name)
	if own_alive > 0 and opponent_alive > 0:
		return {"terminal": false, "value": 0.0}
	if own_alive <= 0 and opponent_alive <= 0:
		return {"terminal": true, "value": 0.0}
	return {"terminal": true, "value": 1.0 if own_alive > 0 else -1.0}


static func _alive_count(state: Dictionary, group_name: String) -> int:
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		var count := 0
		for unit_variant in group.get("units", []):
			if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
				count += 1
		return count
	return 0


static func _entropy(probabilities: Array) -> float:
	var result := 0.0
	for value_variant in probabilities:
		var value := maxf(0.0, float(value_variant))
		if value > 0.0:
			result -= value * log(value)
	return result


static func _kl_divergence(target: Array, prior: Array) -> float:
	if target.size() != prior.size():
		return INF
	var result := 0.0
	for index in range(target.size()):
		var p := maxf(0.0, float(target[index]))
		if p <= 0.0:
			continue
		var q := maxf(1e-12, float(prior[index]))
		result += p * log(p / q)
	return result


static func _action_signature(action_variant: Variant) -> String:
	if not (action_variant is Dictionary):
		return ""
	var action: Dictionary = action_variant
	var end_point: Array = action.get("end_point", [0, 0])
	var path_parts: Array[String] = []
	for cell_variant in action.get("path", []):
		if cell_variant is Array and (cell_variant as Array).size() >= 2:
			path_parts.append("%d,%d" % [int(cell_variant[0]), int(cell_variant[1])])
	return "%d|%s|%d,%d|%s" % [
		int(action.get("unit_id", -1)),
		str(action.get("action_key", "")),
		int(end_point[0]) if end_point.size() > 0 else 0,
		int(end_point[1]) if end_point.size() > 1 else 0,
		">".join(path_parts),
	]
