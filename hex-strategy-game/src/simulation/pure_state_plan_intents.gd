extends RefCounted
class_name PureStatePlanIntents
## Shared tactical intent vocabulary for proposal diversity.
##
## The four buckets are deliberately broad and stable:
##   commit      - attack now or move closer to pressure the enemy
##   hold        - stay roughly in place and prepare/support/economize
##   reposition  - move without materially closing or opening distance
##   disengage   - increase distance from the nearest enemy
##
## Opponent selection uses stronger diversity quotas because its job is recall:
## do not miss a qualitatively different counter. Own-plan selection remains
## score-first but preserves a diversity floor so search still sees creative
## alternatives. Command-objective recall is orthogonal to these four buckets:
## when at least two slots exist, final selection also retains one objective-
## advancing plan without adding a fifth tactical intent.

const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

const COMMIT := "commit"
const HOLD := "hold"
const REPOSITION := "reposition"
const DISENGAGE := "disengage"
const BUCKET_ORDER := [COMMIT, HOLD, REPOSITION, DISENGAGE]


static func classify_action(
	game_state: Dictionary,
	group_name: String,
	unit: Dictionary,
	action: Dictionary
) -> String:
	var action_key := str(action.get("action_key", ""))
	var config: Dictionary = Actions.get_action_config(action_key)
	if int(config.get("damage", 0)) > 0 or int(config.get("self_damage", 0)) > 0:
		return COMMIT

	var action_type := str(config.get("type", ""))
	if action_type not in TurnExecutionCore.MOVE_TYPES:
		return HOLD

	var from_cell := _cell_from_variant(unit.get("cell", [0, 0]), Vector2i.ZERO)
	var to_cell := _cell_from_variant(action.get("end_point", [from_cell.x, from_cell.y]), from_cell)
	var before := _nearest_enemy_distance(game_state, group_name, from_cell)
	var after := _nearest_enemy_distance(game_state, group_name, to_cell)
	if before < 0 or after < 0:
		return REPOSITION
	if after < before:
		return COMMIT
	if after > before:
		return DISENGAGE
	return REPOSITION


static func classify_plan(game_state: Dictionary, group_name: String, actions: Array) -> String:
	var has_movement := false
	var distance_delta := 0
	for action_variant in actions:
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		var config: Dictionary = Actions.get_action_config(str(action.get("action_key", "")))
		if int(config.get("damage", 0)) > 0 or int(config.get("self_damage", 0)) > 0:
			return COMMIT

		var action_type := str(config.get("type", ""))
		if action_type not in TurnExecutionCore.MOVE_TYPES:
			continue
		var found := TurnExecutionCore.find_unit_by_id(game_state, int(action.get("unit_id", -1)))
		if found.is_empty():
			continue
		var unit: Dictionary = found.get("unit", {})
		var from_cell := _cell_from_variant(unit.get("cell", [0, 0]), Vector2i.ZERO)
		var to_cell := _cell_from_variant(action.get("end_point", [from_cell.x, from_cell.y]), from_cell)
		var before := _nearest_enemy_distance(game_state, group_name, from_cell)
		var after := _nearest_enemy_distance(game_state, group_name, to_cell)
		has_movement = true
		if before >= 0 and after >= 0:
			# Positive means the plan opens distance; negative means it closes.
			distance_delta += after - before

	if not has_movement:
		return HOLD
	if distance_delta > 0:
		return DISENGAGE
	if distance_delta < 0:
		return COMMIT
	return REPOSITION


## Preserve at least one action from each available intent when the per-unit
## action budget is large enough to represent all four. Tiny budgets remain
## score-first because four-way coverage is impossible.
static func select_ranked_actions(
	game_state: Dictionary,
	group_name: String,
	unit: Dictionary,
	ranked: Array,
	max_actions: int
) -> Array:
	if max_actions <= 0:
		return []
	if ranked.size() <= max_actions:
		return ranked.duplicate(true)
	if max_actions < BUCKET_ORDER.size():
		return ranked.slice(0, max_actions)

	var annotated: Array = []
	for entry_variant in ranked:
		if not (entry_variant is Dictionary):
			continue
		var entry: Dictionary = entry_variant.duplicate(true)
		entry["intent"] = classify_action(game_state, group_name, unit, entry.get("action", {}))
		annotated.append(entry)
	return _select_with_quotas(annotated, max_actions, _one_each_quotas())


## Source-pool selection used inside beam generation. When capacity allows it,
## keep up to two representatives of every intent before filling by score.
static func select_pool_candidates(
	game_state: Dictionary,
	group_name: String,
	candidates: Array,
	max_plans: int
) -> Array:
	if max_plans <= 0:
		return []
	var annotated := _annotate_candidates(game_state, group_name, candidates)
	if annotated.size() <= max_plans:
		return annotated
	if max_plans < BUCKET_ORDER.size():
		return annotated.slice(0, max_plans)
	var quotas := _one_each_quotas()
	if max_plans >= 8:
		for bucket in BUCKET_ORDER:
			quotas[bucket] = 2
	return _select_with_quotas(annotated, max_plans, quotas)


## Own-plan policy: start score-first, then replace the lowest redundant picks
## until every available intent has one representative. This keeps most of the
## strongest raw proposals while preventing total tunnel vision. Objective recall
## is applied afterward as an orthogonal floor, preferentially replacing another
## plan from the same tactical bucket so four-way intent coverage stays intact.
static func select_own_candidates(
	game_state: Dictionary,
	group_name: String,
	candidates: Array,
	max_plans: int
) -> Array:
	if max_plans <= 0:
		return []
	var annotated := _annotate_candidates(game_state, group_name, candidates)
	if annotated.size() <= max_plans:
		return annotated
	if max_plans < BUCKET_ORDER.size():
		return _preserve_objective_candidate(annotated, annotated.slice(0, max_plans), max_plans)

	var selected: Array = annotated.slice(0, max_plans)
	for bucket in BUCKET_ORDER:
		if _count_intent(selected, bucket) > 0:
			continue
		var replacement := _first_with_intent(annotated, bucket, selected)
		if replacement.is_empty():
			continue
		var replace_index := _lowest_redundant_index(selected)
		if replace_index < 0:
			break
		selected[replace_index] = replacement
	selected.sort_custom(_candidate_before)
	return _preserve_objective_candidate(annotated, selected, max_plans)


## Opponent policy: coverage-heavy. With eight slots this yields the intended
## 2 commit / 1 hold / 2 reposition / 2 disengage floor, then one wildcard slot
## filled by the strongest remaining proposal. Objective recall is still kept as
## an independent floor so a small opponent set cannot omit the alternate win.
static func select_opponent_candidates(
	game_state: Dictionary,
	group_name: String,
	candidates: Array,
	max_plans: int
) -> Array:
	if max_plans <= 0:
		return []
	var annotated := _annotate_candidates(game_state, group_name, candidates)
	if annotated.size() <= max_plans:
		return annotated
	if max_plans < BUCKET_ORDER.size():
		return _preserve_objective_candidate(annotated, annotated.slice(0, max_plans), max_plans)

	var quotas := _one_each_quotas()
	if max_plans >= 5:
		quotas[COMMIT] = 2
	if max_plans >= 6:
		quotas[REPOSITION] = 2
	if max_plans >= 7:
		quotas[DISENGAGE] = 2
	var selected := _select_with_quotas(annotated, max_plans, quotas)
	return _preserve_objective_candidate(annotated, selected, max_plans)


static func count_intents(candidates: Array) -> Dictionary:
	var counts := {
		COMMIT: 0,
		HOLD: 0,
		REPOSITION: 0,
		DISENGAGE: 0,
	}
	for candidate_variant in candidates:
		if not (candidate_variant is Dictionary):
			continue
		var intent := str((candidate_variant as Dictionary).get("intent", ""))
		if counts.has(intent):
			counts[intent] = int(counts[intent]) + 1
	return counts


static func _annotate_candidates(game_state: Dictionary, group_name: String, candidates: Array) -> Array:
	var annotated: Array = []
	for candidate_variant in candidates:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant.duplicate(true)
		candidate["intent"] = classify_plan(game_state, group_name, candidate.get("actions", []))
		annotated.append(candidate)
	annotated.sort_custom(_candidate_before)
	return annotated


static func _select_with_quotas(annotated: Array, max_items: int, quotas: Dictionary) -> Array:
	var selected: Array = []
	for bucket in BUCKET_ORDER:
		var needed := int(quotas.get(bucket, 0))
		if needed <= 0:
			continue
		for candidate_variant in annotated:
			if selected.size() >= max_items or needed <= 0:
				break
			if not (candidate_variant is Dictionary):
				continue
			var candidate: Dictionary = candidate_variant
			if str(candidate.get("intent", "")) != bucket or _contains_candidate(selected, candidate):
				continue
			selected.append(candidate.duplicate(true))
			needed -= 1

	for candidate_variant in annotated:
		if selected.size() >= max_items:
			break
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		if not _contains_candidate(selected, candidate):
			selected.append(candidate.duplicate(true))
	selected.sort_custom(_candidate_before)
	return selected


static func _preserve_objective_candidate(annotated: Array, selected: Array, max_items: int) -> Array:
	if max_items < 2 or annotated.is_empty() or selected.is_empty():
		return selected
	for candidate_variant in selected:
		if candidate_variant is Dictionary and int((candidate_variant as Dictionary).get("objective_progress", 0)) > 0:
			return selected

	var best := _best_objective_candidate(annotated)
	if best.is_empty():
		return selected

	var result := selected.duplicate(true)
	if result.size() < max_items:
		result.append(best.duplicate(true))
	else:
		# Replacing a candidate from the objective plan's own intent bucket preserves
		# the existing tactical coverage whenever that bucket is already represented.
		var objective_intent := str(best.get("intent", ""))
		var replace_index := _lowest_intent_index(result, objective_intent)
		if replace_index < 0:
			replace_index = _lowest_redundant_index(result)
		if replace_index < 0:
			replace_index = result.size() - 1
		result[replace_index] = best.duplicate(true)
	result.sort_custom(_candidate_before)
	return result


static func _best_objective_candidate(annotated: Array) -> Dictionary:
	var best: Dictionary = {}
	for candidate_variant in annotated:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var progress := int(candidate.get("objective_progress", 0))
		if progress <= 0:
			continue
		if best.is_empty():
			best = candidate
			continue
		var best_progress := int(best.get("objective_progress", 0))
		var score := float(candidate.get("proposal_score", candidate.get("score", 0.0)))
		var best_score := float(best.get("proposal_score", best.get("score", 0.0)))
		if progress > best_progress or (progress == best_progress and score > best_score):
			best = candidate
	return best.duplicate(true) if not best.is_empty() else {}


static func _one_each_quotas() -> Dictionary:
	return {
		COMMIT: 1,
		HOLD: 1,
		REPOSITION: 1,
		DISENGAGE: 1,
	}


static func _count_intent(candidates: Array, intent: String) -> int:
	var count := 0
	for candidate_variant in candidates:
		if candidate_variant is Dictionary and str((candidate_variant as Dictionary).get("intent", "")) == intent:
			count += 1
	return count


static func _first_with_intent(annotated: Array, intent: String, selected: Array) -> Dictionary:
	for candidate_variant in annotated:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		if str(candidate.get("intent", "")) == intent and not _contains_candidate(selected, candidate):
			return candidate.duplicate(true)
	return {}


static func _lowest_intent_index(selected: Array, intent: String) -> int:
	if intent.is_empty():
		return -1
	for i in range(selected.size() - 1, -1, -1):
		var candidate: Dictionary = selected[i]
		if str(candidate.get("intent", "")) == intent:
			return i
	return -1


static func _lowest_redundant_index(selected: Array) -> int:
	for i in range(selected.size() - 1, -1, -1):
		var candidate: Dictionary = selected[i]
		var intent := str(candidate.get("intent", ""))
		if _count_intent(selected, intent) > 1:
			return i
	return -1


static func _contains_candidate(candidates: Array, candidate: Dictionary) -> bool:
	var signature := _candidate_signature(candidate)
	for existing_variant in candidates:
		if existing_variant is Dictionary and _candidate_signature(existing_variant as Dictionary) == signature:
			return true
	return false


static func _candidate_before(a: Dictionary, b: Dictionary) -> bool:
	var a_score := float(a.get("proposal_score", a.get("score", 0.0)))
	var b_score := float(b.get("proposal_score", b.get("score", 0.0)))
	if not is_equal_approx(a_score, b_score):
		return a_score > b_score
	return _candidate_signature(a) < _candidate_signature(b)


static func _candidate_signature(candidate: Dictionary) -> String:
	var actions = candidate.get("actions", null)
	if actions is Array:
		return _plan_signature(actions)
	var action = candidate.get("action", {})
	if action is Dictionary:
		return _plan_signature([action])
	return ""


static func _nearest_enemy_distance(game_state: Dictionary, group_name: String, from_cell: Vector2i) -> int:
	var best := -1
	for group_variant in game_state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) == group_name:
			continue
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			if int(unit.get("health", 0)) <= 0:
				continue
			var cell := _cell_from_variant(unit.get("cell", [0, 0]), Vector2i.ZERO)
			var distance := HexGrid.hex_distance(from_cell.x, from_cell.y, cell.x, cell.y)
			if best < 0 or distance < best:
				best = distance
	return best


static func _cell_from_variant(value: Variant, fallback: Vector2i) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return fallback


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
