extends RefCounted
class_name PureStateSimultaneousPUCT
## Simultaneous-action PUCT/MCTS.
##
## puct_max_depth=1 preserves the MCTS-1 root-only experiment. Depth > 1 enables
## MCTS-2: after a simultaneous plan pair resolves, the resulting public state is
## expanded as another node, both factions receive fresh policy proposals from
## that same state, and the terminal/value estimate is backed through the path.
## Neither side ever observes the other side's current-turn selected plan before
## choosing its own plan.

const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStatePlanIntents = preload("res://src/simulation/pure_state_plan_intents.gd")
const PureStateNeuralPlans = preload("res://src/simulation/pure_state_neural_plans.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")

const EVALUATOR_HANDWRITTEN := "handwritten"
const EVALUATOR_NEURAL := "neural"
const POLICY_SOURCE_AUTO := "auto"
const POLICY_SOURCE_NEURAL := "neural"
const POLICY_SOURCE_HEURISTIC := "heuristic"
const DEFAULT_SIMULATIONS := 32
const DEFAULT_C_PUCT := 1.5
const DEFAULT_VALUE_SCALE := 1000.0
const DEFAULT_MAX_DEPTH := 1
const SOURCE_POOL_MULTIPLIER := 4


static func search(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	own_max_actions_per_unit: int,
	own_max_plans: int,
	opponent_max_actions_per_unit: int,
	opponent_max_plans: int,
	fixed_other_group_actions: Dictionary = {},
	evaluator_mode: String = EVALUATOR_NEURAL,
	settings: Dictionary = {}
) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var invalid := _empty_result(group_name, opponent_group_name, evaluator_mode)
	if group_name.is_empty() or opponent_group_name.is_empty() or group_name == opponent_group_name:
		invalid["error"] = "invalid_groups"
		return invalid
	if evaluator_mode not in [EVALUATOR_HANDWRITTEN, EVALUATOR_NEURAL]:
		invalid["error"] = "unsupported_evaluator"
		return invalid
	if own_max_actions_per_unit <= 0 or own_max_plans <= 0 or opponent_max_actions_per_unit <= 0 or opponent_max_plans <= 0:
		invalid["error"] = "invalid_search_budget"
		return invalid
	if not _has_group(game_state, group_name) or not _has_group(game_state, opponent_group_name):
		invalid["error"] = "missing_group"
		return invalid

	var source := str(settings.get("puct_policy_source", POLICY_SOURCE_AUTO))
	if source == POLICY_SOURCE_AUTO:
		source = POLICY_SOURCE_NEURAL if evaluator_mode == EVALUATOR_NEURAL else POLICY_SOURCE_HEURISTIC
	if source not in [POLICY_SOURCE_NEURAL, POLICY_SOURCE_HEURISTIC]:
		invalid["error"] = "unsupported_puct_policy_source"
		return invalid
	if source == POLICY_SOURCE_NEURAL and evaluator_mode != EVALUATOR_NEURAL:
		invalid["error"] = "neural_policy_requires_neural_mode"
		return invalid

	var simulations_target := maxi(1, int(settings.get("puct_simulations", DEFAULT_SIMULATIONS)))
	var c_puct := maxf(0.0, float(settings.get("puct_c", DEFAULT_C_PUCT)))
	var value_scale := maxf(1.0, float(settings.get("puct_value_scale", DEFAULT_VALUE_SCALE)))
	var max_depth := maxi(1, int(settings.get("puct_max_depth", DEFAULT_MAX_DEPTH)))
	var decision_time_budget_ms := maxf(0.0, float(settings.get("decision_time_budget_ms", 0.0)))

	# Critical simultaneous-information invariant: the root is copied once and each
	# node creates both factions' candidate sets before any plan pair is resolved.
	var root_state := game_state.duplicate(true)
	var tree: Dictionary = {}
	var counters := {
		"evaluation_failures": 0,
		"terminal_leaves": 0,
		"value_leaves": 0,
		"candidate_frontier_leaves": 0,
		"transitions": 0,
		"max_depth_reached": 0,
	}
	var root_key := _ensure_node(
		tree, root_state, group_name, opponent_group_name,
		own_max_actions_per_unit, own_max_plans,
		opponent_max_actions_per_unit, opponent_max_plans,
		source, settings
	)
	if root_key.is_empty():
		invalid["error"] = "candidate_generation_failed"
		invalid["policy_source"] = source
		return invalid

	var simulations_run := 0
	var time_budget_exhausted := false
	for _simulation_index in range(simulations_target):
		if decision_time_budget_ms > 0.0:
			var elapsed_before := float(Time.get_ticks_usec() - started_usec) / 1000.0
			if simulations_run > 0 and elapsed_before >= decision_time_budget_ms:
				time_budget_exhausted = true
				break
		var result := _simulate_path(
			tree, root_key, 0, max_depth,
			group_name, opponent_group_name,
			own_max_actions_per_unit, own_max_plans,
			opponent_max_actions_per_unit, opponent_max_plans,
			fixed_other_group_actions, evaluator_mode, source,
			c_puct, value_scale, settings, counters
		)
		if not bool(result.get("valid", false)):
			invalid["error"] = str(result.get("error", "simulation_failed"))
			invalid["evaluation_error"] = str(result.get("evaluation_error", ""))
			invalid["simulations_run"] = simulations_run
			invalid["evaluation_failures"] = int(counters.get("evaluation_failures", 0))
			return invalid
		simulations_run += 1

	if simulations_run <= 0:
		invalid["error"] = "no_simulations_completed"
		return invalid

	var root: Dictionary = tree.get(root_key, {})
	var own_edges: Array = root.get("own_edges", []) as Array
	var opponent_edges: Array = root.get("opponent_edges", []) as Array
	var ranked_results := _ranked_results(own_edges, value_scale)
	if ranked_results.is_empty():
		invalid["error"] = "no_ranked_results"
		return invalid
	var best: Dictionary = ranked_results[0]
	var opponent_ranked := _ranked_results(opponent_edges, value_scale)
	var top_opponent_actions: Array = []
	if not opponent_ranked.is_empty():
		top_opponent_actions = (opponent_ranked[0].get("actions", []) as Array).duplicate(true)

	var stage := "MCTS-1" if max_depth == 1 else "MCTS-2"
	var search_type := "simultaneous_puct_root" if max_depth == 1 else "simultaneous_puct_tree"
	return {
		"valid": true,
		"error": "",
		"search_type": search_type,
		"mcts_stage": stage,
		"evaluator": evaluator_mode,
		"policy_source": source,
		"group_name": group_name,
		"opponent_group_name": opponent_group_name,
		"simultaneous_pre_turn": true,
		"root_turn_index": int(root_state.get("turn_index", 0)),
		"own_candidates_considered": own_edges.size(),
		"opponent_candidates_considered": opponent_edges.size(),
		"simulations_target": simulations_target,
		"simulations_run": simulations_run,
		"evaluation_failures": int(counters.get("evaluation_failures", 0)),
		"puct_c": c_puct,
		"puct_value_scale": value_scale,
		"puct_max_depth": max_depth,
		"nodes_expanded": tree.size(),
		"tree_transitions": int(counters.get("transitions", 0)),
		"max_depth_reached": int(counters.get("max_depth_reached", 0)),
		"terminal_leaves": int(counters.get("terminal_leaves", 0)),
		"value_leaves": int(counters.get("value_leaves", 0)),
		"candidate_frontier_leaves": int(counters.get("candidate_frontier_leaves", 0)),
		"decision_time_budget_ms": decision_time_budget_ms,
		"time_budget_exhausted": time_budget_exhausted,
		"elapsed_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
		"best_actions": (best.get("actions", []) as Array).duplicate(true),
		"best_intent": str(best.get("intent", "")),
		"best_proposal_score": float(best.get("proposal_score", 0.0)),
		"best_worst_case_score": float(best.get("worst_case_score", 0.0)),
		"best_average_score": float(best.get("average_score", 0.0)),
		"best_worst_response_actions": top_opponent_actions,
		"ranked_results": ranked_results,
		"root_visit_distribution": _visit_distribution(own_edges),
		"own_edge_stats": _edge_diagnostics(own_edges),
		"opponent_edge_stats": _edge_diagnostics(opponent_edges),
		"pair_stats": _pair_diagnostics(root.get("pair_stats", {}) as Dictionary),
	}


static func _simulate_path(
	tree: Dictionary,
	node_key: String,
	depth: int,
	max_depth: int,
	group_name: String,
	opponent_group_name: String,
	own_max_actions_per_unit: int,
	own_max_plans: int,
	opponent_max_actions_per_unit: int,
	opponent_max_plans: int,
	fixed_other_group_actions: Dictionary,
	evaluator_mode: String,
	source: String,
	c_puct: float,
	value_scale: float,
	settings: Dictionary,
	counters: Dictionary
) -> Dictionary:
	var node_variant = tree.get(node_key, {})
	if not (node_variant is Dictionary) or (node_variant as Dictionary).is_empty():
		return {"valid": false, "error": "missing_tree_node"}
	var node: Dictionary = node_variant
	var own_edges: Array = node.get("own_edges", []) as Array
	var opponent_edges: Array = node.get("opponent_edges", []) as Array
	var node_visits := int(node.get("visits", 0))
	var own_index := _select_edge_index(own_edges, node_visits, c_puct)
	var opponent_index := _select_edge_index(opponent_edges, node_visits, c_puct)
	if own_index < 0 or opponent_index < 0:
		return {"valid": false, "error": "candidate_selection_failed"}

	var state: Dictionary = (node.get("state", {}) as Dictionary).duplicate(true)
	var own_edge: Dictionary = own_edges[own_index]
	var opponent_edge: Dictionary = opponent_edges[opponent_index]
	var submitted := _build_player_actions(
		state, group_name, (own_edge.get("actions", []) as Array),
		opponent_group_name, (opponent_edge.get("actions", []) as Array),
		fixed_other_group_actions
	)
	var simulation := PureStateSimulator.simulate_turn(state, submitted)
	var next_state_variant = simulation.get("next_state", {})
	if not (next_state_variant is Dictionary) or (next_state_variant as Dictionary).is_empty():
		return {"valid": false, "error": "simulation_failed"}
	var next_state: Dictionary = (next_state_variant as Dictionary).duplicate(true)
	next_state["turn_index"] = int(state.get("turn_index", 0)) + 1
	if state.get("command_hexes", {}) is Dictionary:
		next_state["command_hexes"] = (state.get("command_hexes", {}) as Dictionary).duplicate(true)

	counters["transitions"] = int(counters.get("transitions", 0)) + 1
	counters["max_depth_reached"] = maxi(int(counters.get("max_depth_reached", 0)), depth + 1)

	var value_result: Dictionary
	var terminal := _terminal_breakdown(state, next_state, group_name, opponent_group_name, settings)
	if not terminal.is_empty():
		counters["terminal_leaves"] = int(counters.get("terminal_leaves", 0)) + 1
		value_result = _backed_result(terminal, value_scale)
	elif depth + 1 >= max_depth:
		var breakdown := _evaluate_leaf(next_state, group_name, opponent_group_name, evaluator_mode, settings)
		if not bool(breakdown.get("valid", false)):
			counters["evaluation_failures"] = int(counters.get("evaluation_failures", 0)) + 1
			return {"valid": false, "error": "evaluation_failed", "evaluation_error": str(breakdown.get("error", ""))}
		counters["value_leaves"] = int(counters.get("value_leaves", 0)) + 1
		value_result = _backed_result(breakdown, value_scale)
	else:
		var child_key := _ensure_node(
			tree, next_state, group_name, opponent_group_name,
			own_max_actions_per_unit, own_max_plans,
			opponent_max_actions_per_unit, opponent_max_plans,
			source, settings
		)
		if child_key.is_empty():
			# If a nonterminal frontier cannot produce legal policy candidates, fail
			# soft to the value model rather than throwing away the whole root search.
			var frontier := _evaluate_leaf(next_state, group_name, opponent_group_name, evaluator_mode, settings)
			if not bool(frontier.get("valid", false)):
				counters["evaluation_failures"] = int(counters.get("evaluation_failures", 0)) + 1
				return {"valid": false, "error": "evaluation_failed", "evaluation_error": str(frontier.get("error", ""))}
			counters["candidate_frontier_leaves"] = int(counters.get("candidate_frontier_leaves", 0)) + 1
			value_result = _backed_result(frontier, value_scale)
		else:
			value_result = _simulate_path(
				tree, child_key, depth + 1, max_depth,
				group_name, opponent_group_name,
				own_max_actions_per_unit, own_max_plans,
				opponent_max_actions_per_unit, opponent_max_plans,
				fixed_other_group_actions, evaluator_mode, source,
				c_puct, value_scale, settings, counters
			)
			if not bool(value_result.get("valid", false)):
				return value_result

	var backed_value := float(value_result.get("value", 0.0))
	var raw_value := float(value_result.get("raw_value", 0.0))
	_update_edge(own_edges, own_index, backed_value, raw_value)
	_update_edge(opponent_edges, opponent_index, -backed_value, -raw_value)
	var pair_stats: Dictionary = node.get("pair_stats", {}) as Dictionary
	_update_pair_stats(pair_stats, own_index, opponent_index, backed_value, raw_value)
	node["own_edges"] = own_edges
	node["opponent_edges"] = opponent_edges
	node["pair_stats"] = pair_stats
	node["visits"] = node_visits + 1
	tree[node_key] = node
	return value_result


static func _ensure_node(
	tree: Dictionary,
	state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	own_max_actions_per_unit: int,
	own_max_plans: int,
	opponent_max_actions_per_unit: int,
	opponent_max_plans: int,
	source: String,
	settings: Dictionary
) -> String:
	var key := _state_key(state)
	if tree.has(key):
		return key
	# Both candidate sets are generated from the identical state before a plan pair
	# is selected, preserving sealed simultaneous-turn information semantics.
	var own_candidates := _candidate_plans(
		state, group_name, opponent_group_name,
		own_max_actions_per_unit, own_max_plans, source, settings
	)
	var opponent_candidates := _candidate_plans(
		state, opponent_group_name, group_name,
		opponent_max_actions_per_unit, opponent_max_plans, source, settings
	)
	if own_candidates.is_empty() or opponent_candidates.is_empty():
		return ""
	tree[key] = {
		"state": state.duplicate(true),
		"visits": 0,
		"own_edges": _build_edges(own_candidates, source),
		"opponent_edges": _build_edges(opponent_candidates, source),
		"pair_stats": {},
	}
	return key


static func _candidate_plans(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	max_actions_per_unit: int,
	max_plans: int,
	source: String,
	settings: Dictionary
) -> Array:
	if source == POLICY_SOURCE_NEURAL:
		return PureStateNeuralPlans.get_candidate_plans(
			game_state, group_name, opponent_group_name,
			max_actions_per_unit, max_plans, settings
		)
	var source_limit := maxi(max_plans, max_plans * SOURCE_POOL_MULTIPLIER)
	var pool := PureStatePlans.get_candidate_plans(
		game_state, group_name, max_actions_per_unit, source_limit, true
	)
	return PureStatePlanIntents.select_own_candidates(game_state, group_name, pool, max_plans)


static func _build_edges(candidates: Array, source: String) -> Array:
	var edges: Array = []
	var scores: Array = []
	for candidate_variant in candidates:
		if candidate_variant is Dictionary:
			scores.append(float((candidate_variant as Dictionary).get("proposal_score", 0.0)))
	if scores.is_empty():
		return edges

	var priors: Array = []
	if source == POLICY_SOURCE_NEURAL:
		var maximum := -INF
		for score in scores:
			maximum = maxf(maximum, float(score))
		var total := 0.0
		for score in scores:
			var weight := exp(float(score) - maximum)
			priors.append(weight)
			total += weight
		if total <= 0.0:
			total = float(priors.size())
			for index in range(priors.size()):
				priors[index] = 1.0
		for index in range(priors.size()):
			priors[index] = float(priors[index]) / total
	else:
		var uniform := 1.0 / float(scores.size())
		for _score in scores:
			priors.append(uniform)

	var candidate_index := 0
	for candidate_variant in candidates:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		edges.append({
			"actions": (candidate.get("actions", []) as Array).duplicate(true),
			"intent": str(candidate.get("intent", "")),
			"proposal_score": float(candidate.get("proposal_score", 0.0)),
			"prior": float(priors[candidate_index]),
			"visits": 0,
			"value_sum": 0.0,
			"raw_value_sum": 0.0,
			"q": 0.0,
			"raw_q": 0.0,
		})
		candidate_index += 1
	return edges


static func _select_edge_index(edges: Array, total_visits: int, c_puct: float) -> int:
	var best_unvisited := -1
	var best_unvisited_prior := -INF
	for index in range(edges.size()):
		var edge: Dictionary = edges[index]
		if int(edge.get("visits", 0)) == 0:
			var prior := float(edge.get("prior", 0.0))
			if best_unvisited < 0 or prior > best_unvisited_prior:
				best_unvisited = index
				best_unvisited_prior = prior
	if best_unvisited >= 0:
		return best_unvisited

	var parent_scale := sqrt(float(maxi(1, total_visits)))
	var best_index := -1
	var best_score := -INF
	for index in range(edges.size()):
		var edge: Dictionary = edges[index]
		var visits := int(edge.get("visits", 0))
		var q := float(edge.get("q", 0.0))
		var prior := float(edge.get("prior", 0.0))
		var exploration := c_puct * prior * parent_scale / float(1 + visits)
		var score := q + exploration
		if best_index < 0 or score > best_score or (is_equal_approx(score, best_score) and prior > float((edges[best_index] as Dictionary).get("prior", 0.0))):
			best_index = index
			best_score = score
	return best_index


static func _update_edge(edges: Array, index: int, value: float, raw_value: float) -> void:
	var edge: Dictionary = edges[index]
	var visits := int(edge.get("visits", 0)) + 1
	edge["visits"] = visits
	edge["value_sum"] = float(edge.get("value_sum", 0.0)) + value
	edge["raw_value_sum"] = float(edge.get("raw_value_sum", 0.0)) + raw_value
	edge["q"] = float(edge["value_sum"]) / float(visits)
	edge["raw_q"] = float(edge["raw_value_sum"]) / float(visits)
	edges[index] = edge


static func _update_pair_stats(pair_stats: Dictionary, own_index: int, opponent_index: int, value: float, raw_value: float) -> void:
	var key := "%d:%d" % [own_index, opponent_index]
	var row: Dictionary = pair_stats.get(key, {
		"own_index": own_index,
		"opponent_index": opponent_index,
		"visits": 0,
		"value_sum": 0.0,
		"raw_value_sum": 0.0,
	})
	var visits := int(row.get("visits", 0)) + 1
	row["visits"] = visits
	row["value_sum"] = float(row.get("value_sum", 0.0)) + value
	row["raw_value_sum"] = float(row.get("raw_value_sum", 0.0)) + raw_value
	row["q"] = float(row["value_sum"]) / float(visits)
	row["raw_q"] = float(row["raw_value_sum"]) / float(visits)
	pair_stats[key] = row


static func _ranked_results(edges: Array, value_scale: float) -> Array:
	var ranked: Array = []
	for edge_variant in edges:
		if not (edge_variant is Dictionary):
			continue
		var edge: Dictionary = edge_variant
		var q := float(edge.get("q", 0.0))
		var raw_q := float(edge.get("raw_q", q * value_scale))
		ranked.append({
			"actions": (edge.get("actions", []) as Array).duplicate(true),
			"intent": str(edge.get("intent", "")),
			"proposal_score": float(edge.get("proposal_score", 0.0)),
			"puct_prior": float(edge.get("prior", 0.0)),
			"puct_visits": int(edge.get("visits", 0)),
			"puct_q": q,
			"puct_raw_q": raw_q,
			"worst_case_score": raw_q,
			"average_score": raw_q,
			"average_complete": true,
			"pruned": false,
		})
	ranked.sort_custom(_result_before)
	return ranked


static func _visit_distribution(edges: Array) -> Array:
	var total := 0
	for edge_variant in edges:
		if edge_variant is Dictionary:
			total += int((edge_variant as Dictionary).get("visits", 0))
	var result: Array = []
	for edge_variant in edges:
		if not (edge_variant is Dictionary):
			continue
		var edge: Dictionary = edge_variant
		var visits := int(edge.get("visits", 0))
		result.append({
			"actions": (edge.get("actions", []) as Array).duplicate(true),
			"visits": visits,
			"probability": float(visits) / float(total) if total > 0 else 0.0,
			"prior": float(edge.get("prior", 0.0)),
			"q": float(edge.get("q", 0.0)),
		})
	result.sort_custom(func(a, b):
		if int(a.get("visits", 0)) != int(b.get("visits", 0)):
			return int(a.get("visits", 0)) > int(b.get("visits", 0))
		return _plan_signature(a.get("actions", [])) < _plan_signature(b.get("actions", []))
	)
	return result


static func _result_before(a: Dictionary, b: Dictionary) -> bool:
	var a_visits := int(a.get("puct_visits", 0))
	var b_visits := int(b.get("puct_visits", 0))
	if a_visits != b_visits:
		return a_visits > b_visits
	var a_q := float(a.get("puct_q", 0.0))
	var b_q := float(b.get("puct_q", 0.0))
	if not is_equal_approx(a_q, b_q):
		return a_q > b_q
	var a_prior := float(a.get("puct_prior", 0.0))
	var b_prior := float(b.get("puct_prior", 0.0))
	if not is_equal_approx(a_prior, b_prior):
		return a_prior > b_prior
	return _plan_signature(a.get("actions", [])) < _plan_signature(b.get("actions", []))


static func _edge_diagnostics(edges: Array) -> Array:
	var result: Array = []
	for edge_variant in edges:
		if not (edge_variant is Dictionary):
			continue
		var edge: Dictionary = edge_variant
		result.append({
			"actions": (edge.get("actions", []) as Array).duplicate(true),
			"prior": float(edge.get("prior", 0.0)),
			"visits": int(edge.get("visits", 0)),
			"q": float(edge.get("q", 0.0)),
			"raw_q": float(edge.get("raw_q", 0.0)),
		})
	result.sort_custom(func(a, b): return _result_before({
		"actions": a.get("actions", []), "puct_visits": a.get("visits", 0),
		"puct_q": a.get("q", 0.0), "puct_prior": a.get("prior", 0.0),
	}, {
		"actions": b.get("actions", []), "puct_visits": b.get("visits", 0),
		"puct_q": b.get("q", 0.0), "puct_prior": b.get("prior", 0.0),
	}))
	return result


static func _pair_diagnostics(pair_stats: Dictionary) -> Array:
	var result: Array = []
	for key_variant in pair_stats.keys():
		var row_variant = pair_stats[key_variant]
		if row_variant is Dictionary:
			result.append((row_variant as Dictionary).duplicate(true))
	result.sort_custom(func(a, b):
		var av := int(a.get("visits", 0))
		var bv := int(b.get("visits", 0))
		if av != bv:
			return av > bv
		if int(a.get("own_index", 0)) != int(b.get("own_index", 0)):
			return int(a.get("own_index", 0)) < int(b.get("own_index", 0))
		return int(a.get("opponent_index", 0)) < int(b.get("opponent_index", 0))
	)
	return result


static func _backed_result(breakdown: Dictionary, value_scale: float) -> Dictionary:
	var raw_value := float(breakdown.get("total", 0.0))
	return {"valid": true, "raw_value": raw_value, "value": tanh(raw_value / value_scale)}


static func _terminal_breakdown(
	before: Dictionary,
	after: Dictionary,
	group_name: String,
	opponent_group_name: String,
	settings: Dictionary
) -> Dictionary:
	var own_alive := _alive_count_for_group(after, group_name)
	var opponent_alive := _alive_count_for_group(after, opponent_group_name)
	if own_alive <= 0 or opponent_alive <= 0:
		var score := 0.0
		if own_alive > 0 and opponent_alive <= 0:
			score = PureStateEvaluator.TERMINAL_WEIGHT
		elif opponent_alive > 0 and own_alive <= 0:
			score = -PureStateEvaluator.TERMINAL_WEIGHT
		return {"valid": true, "total": score, "terminal": score, "terminal_reason": "elimination"}
	return _capture_terminal_breakdown(before, after, group_name, opponent_group_name, settings)


static func _alive_count_for_group(state: Dictionary, group_name: String) -> int:
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


static func _evaluate_leaf(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	evaluator_mode: String,
	settings: Dictionary
) -> Dictionary:
	if evaluator_mode == EVALUATOR_NEURAL:
		return PureStateNeuralEvaluator.evaluate_breakdown(game_state, group_name, opponent_group_name, settings)
	return PureStateEvaluator.evaluate_breakdown(game_state, group_name)


static func _capture_terminal_breakdown(
	before: Dictionary,
	after: Dictionary,
	group_name: String,
	opponent_group_name: String,
	settings: Dictionary
) -> Dictionary:
	if not bool(settings.get("score_command_capture", false)):
		return {}
	var hexes_variant = before.get("command_hexes", {})
	if not (hexes_variant is Dictionary):
		return {}
	var hexes: Dictionary = hexes_variant
	if not hexes.has(group_name) or not hexes.has(opponent_group_name):
		return {}
	var previous := PureStateCommandHexRules.initial_occupants(before, group_name, opponent_group_name, hexes)
	var capture := PureStateCommandHexRules.capture_after_complete_turn(after, group_name, opponent_group_name, hexes, previous)
	var completed: Dictionary = capture.get("completed", {})
	var own := bool(completed.get(group_name, false))
	var enemy := bool(completed.get(opponent_group_name, false))
	if not own and not enemy:
		return {}
	var score := 0.0
	if own != enemy:
		score = PureStateEvaluator.TERMINAL_WEIGHT if own else -PureStateEvaluator.TERMINAL_WEIGHT
	return {
		"valid": true,
		"total": score,
		"terminal": score,
		"terminal_reason": "simultaneous_command_capture" if own and enemy else "command_capture",
	}


static func _build_player_actions(
	game_state: Dictionary,
	group_name: String,
	own_actions: Array,
	opponent_group_name: String,
	opponent_actions: Array,
	fixed_other_group_actions: Dictionary
) -> Dictionary:
	var submitted: Dictionary = {}
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var name := str((group_variant as Dictionary).get("name", ""))
		if not name.is_empty():
			submitted[name] = []
	for fixed_name_variant in fixed_other_group_actions.keys():
		var fixed_name := str(fixed_name_variant)
		if fixed_name == group_name or fixed_name == opponent_group_name:
			continue
		var fixed_actions = fixed_other_group_actions.get(fixed_name_variant, [])
		if fixed_actions is Array:
			submitted[fixed_name] = (fixed_actions as Array).duplicate(true)
	submitted[group_name] = own_actions.duplicate(true)
	submitted[opponent_group_name] = opponent_actions.duplicate(true)
	return submitted


static func _has_group(game_state: Dictionary, group_name: String) -> bool:
	for group_variant in game_state.get("groups", []):
		if group_variant is Dictionary and str((group_variant as Dictionary).get("name", "")) == group_name:
			return true
	return false


static func _state_key(state: Dictionary) -> String:
	# Exact serialized state is intentionally conservative for MCTS-2. MCTS-4 can
	# replace this with a compact canonical/transposition hash after semantics are
	# proven. Exact JSON avoids accidentally merging strategically different states.
	return JSON.stringify(state)


static func _plan_signature(actions_variant: Variant) -> String:
	if not (actions_variant is Array):
		return ""
	var parts: PackedStringArray = []
	for action_variant in actions_variant:
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


static func _empty_result(group_name: String, opponent_group_name: String, evaluator_mode: String) -> Dictionary:
	return {
		"valid": false,
		"error": "",
		"evaluation_error": "",
		"search_type": "simultaneous_puct_root",
		"mcts_stage": "MCTS-1",
		"evaluator": evaluator_mode,
		"group_name": group_name,
		"opponent_group_name": opponent_group_name,
		"simulations_run": 0,
		"elapsed_ms": 0.0,
		"best_actions": [],
		"ranked_results": [],
	}