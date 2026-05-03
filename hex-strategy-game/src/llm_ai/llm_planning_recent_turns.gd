extends RefCounted
class_name LlmPlanningRecentTurns
## Builds JSON-safe `recent_turns` for the planning snapshot from UnitsContainer.replay_turn_history.
## Filters enemy actions by AI's field of vision: only shows actions where source or dest cell was visible.

const MAX_TURNS := 2
const MAX_ACTIONS_PER_TURN := 32
const MAX_APPLIED_EFFECTS := 32


static func build_for_llm(units: Node) -> Array:
	if units == null:
		return []
	var h: Variant = units.get("replay_turn_history")
	if h == null or not (h is Array):
		return []
	return build_from_history(h as Array)


## Exposed for tests; `history` is `[{ "turn": int, "recording": Dictionary, "ai_fov": Dictionary, "ai_unit_ids": Array }, ...]`.
## Each compact turn adds `fov_cells` (axial [q,r] visible that turn), `damage_by_id` (unit_id -> HP lost this turn), and
## `applied_effects` (stun etc.), all filtered like actions: own units always; enemies only if observable rules match died/actions.
static func build_from_history(history: Array) -> Array:
	if history.is_empty():
		return []
	var start: int = maxi(0, history.size() - MAX_TURNS)
	var out: Array = []
	for i in range(start, history.size()):
		var entry: Variant = history[i]
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var turn_n: int = int(e.get("turn", 0))
		var rec: Dictionary = e.get("recording", {}) as Dictionary
		var ai_fov: Dictionary = e.get("ai_fov", {}) as Dictionary
		var ai_unit_ids: Array = e.get("ai_unit_ids", []) as Array
		out.append(_compact_turn(turn_n, rec, ai_fov, ai_unit_ids))
	return out


static func _compact_turn(turn_n: int, rec: Dictionary, ai_fov: Dictionary, ai_unit_ids: Array) -> Dictionary:
	var died_raw: Variant = rec.get("died_ids", [])
	var died: Array = []
	if died_raw is Array:
		for x in died_raw as Array:
			var uid := int(x)
			if _unit_visible_in_history(uid, ai_unit_ids, ai_fov, rec):
				died.append(uid)
	var raw_actions: Array = rec.get("actions", []) as Array
	var compact_actions: Array = []
	var n := 0
	for a in raw_actions:
		if n >= MAX_ACTIONS_PER_TURN:
			break
		if not (a is Dictionary):
			continue
		var d: Dictionary = a
		var uid := int(d.get("unit_id", 0))
		if uid <= 0:
			continue
		if not _action_visible(d, uid, ai_fov, ai_unit_ids):
			continue
		var one: Dictionary = {
			"unit_id": uid,
			"unit_name": str(d.get("unit_name", "Unit")),
			"type": str(d.get("type", "")),
		}
		var src: Variant = _get_action_source_cell(d)
		if src != null:
			if src is Vector2:
				one["from"] = [int((src as Vector2).x), int((src as Vector2).y)]
			elif src is Vector2i:
				one["from"] = [int((src as Vector2i).x), int((src as Vector2i).y)]
			elif src is Array:
				one["from"] = src
		var ak: String = str(d.get("action_key", ""))
		if not ak.is_empty():
			one["action_key"] = ak
		var ep: Variant = d.get("end_point", null)
		if ep != null:
			one["end"] = ep
		elif d.has("path"):
			var pth: Variant = d.get("path", [])
			if pth is Array and (pth as Array).size() > 0:
				var pa: Array = pth as Array
				one["end"] = pa[pa.size() - 1]
		compact_actions.append(one)
		n += 1
	return {
		"turn": turn_n,
		"fov_cells": _fov_cells_sorted(ai_fov),
		"died_unit_ids": died,
		"damage_by_id": _compact_damage_by_id(rec, ai_fov, ai_unit_ids),
		"applied_effects": _compact_applied_effects(rec, ai_fov, ai_unit_ids),
		"actions": compact_actions,
	}


static func _fov_cells_sorted(ai_fov: Dictionary) -> Array:
	var cells: Array = []
	for key in ai_fov:
		if not bool(ai_fov[key]):
			continue
		var parts: PackedStringArray = str(key).split(",")
		if parts.size() < 2:
			continue
		var q := int(parts[0].strip_edges())
		var r := int(parts[1].strip_edges())
		cells.append([q, r])
	cells.sort_custom(func(a: Variant, b: Variant) -> bool:
		var aa: Array = a as Array
		var bb: Array = b as Array
		var aq := int(aa[0])
		var bq := int(bb[0])
		if aq != bq:
			return aq < bq
		return int(aa[1]) < int(bb[1])
	)
	return cells


static func _compact_damage_by_id(rec: Dictionary, ai_fov: Dictionary, ai_unit_ids: Array) -> Dictionary:
	var raw: Variant = rec.get("damage_by_id", null)
	var out: Dictionary = {}
	if raw == null or typeof(raw) != TYPE_DICTIONARY:
		return out
	var dmg: Dictionary = raw
	for k in dmg:
		var uid: int = int(k)
		if uid <= 0:
			continue
		if not _unit_visible_in_history(uid, ai_unit_ids, ai_fov, rec):
			continue
		out[uid] = int(dmg[k])
	return out


static func _compact_applied_effects(rec: Dictionary, ai_fov: Dictionary, ai_unit_ids: Array) -> Array:
	var raw: Variant = rec.get("applied_effects", [])
	var out: Array = []
	if raw == null or not (raw is Array):
		return out
	var n := 0
	for item in raw as Array:
		if n >= MAX_APPLIED_EFFECTS:
			break
		if not (item is Dictionary):
			continue
		var ed: Dictionary = item
		var uid: int = int(ed.get("unit_id", 0))
		if uid <= 0:
			continue
		if not _unit_visible_in_history(uid, ai_unit_ids, ai_fov, rec):
			continue
		var one: Dictionary = {"unit_id": uid}
		var eff: Variant = ed.get("effect", {})
		if eff is Dictionary:
			one["effect"] = (eff as Dictionary).duplicate(true)
		else:
			one["effect"] = {}
		out.append(one)
		n += 1
	return out


## Returns true if the action should be shown to AI based on FOV.
## AI's own units' actions are always visible; enemy actions visible if source or dest cell is in ai_fov.
static func _action_visible(action: Dictionary, unit_id: int, ai_fov: Dictionary, ai_unit_ids: Array) -> bool:
	if unit_id in ai_unit_ids:
		return true
	if ai_fov.is_empty():
		return true
	var source_cell: Variant = _get_action_source_cell(action)
	var dest_cell: Variant = _get_action_dest_cell(action)
	if source_cell != null and _cell_in_fov(source_cell, ai_fov):
		return true
	if dest_cell != null and _cell_in_fov(dest_cell, ai_fov):
		return true
	return false


## Extracts the source cell (where the acting unit was) from an action recording.
static func _get_action_source_cell(action: Dictionary) -> Variant:
	if action.has("from_cell"):
		return action.get("from_cell")
	if action.has("caster_cell"):
		return action.get("caster_cell")
	if action.has("cell"):
		return action.get("cell")
	var ac: Variant = action.get("ac", null)
	if ac is Dictionary:
		var acd: Dictionary = ac
		if acd.has("from_cell"):
			return acd.get("from_cell")
	return null


## Extracts the destination cell from an action recording.
static func _get_action_dest_cell(action: Dictionary) -> Variant:
	if action.has("end_point"):
		return action.get("end_point")
	if action.has("target_cell"):
		return action.get("target_cell")
	if action.has("path"):
		var path: Variant = action.get("path")
		if path is Array and (path as Array).size() > 0:
			return (path as Array)[(path as Array).size() - 1]
	var ac: Variant = action.get("ac", null)
	if ac is Dictionary:
		var acd: Dictionary = ac
		if acd.has("end_point"):
			return acd.get("end_point")
		if acd.has("path"):
			var p: Variant = acd.get("path")
			if p is Array and (p as Array).size() > 0:
				return (p as Array)[(p as Array).size() - 1]
	return null


## Checks if a cell (Array [q,r] or Vector2) is in the FOV dictionary.
static func _cell_in_fov(cell: Variant, ai_fov: Dictionary) -> bool:
	var q: int = 0
	var r: int = 0
	if cell is Array:
		var arr: Array = cell
		if arr.size() < 2:
			return false
		q = int(arr[0])
		r = int(arr[1])
	elif cell is Vector2:
		q = int((cell as Vector2).x)
		r = int((cell as Vector2).y)
	elif cell is Vector2i:
		q = (cell as Vector2i).x
		r = (cell as Vector2i).y
	else:
		return false
	var key := "%d,%d" % [q, r]
	return ai_fov.get(key, false)


## Returns true if a dead unit should be reported (was visible to AI or was AI's own unit).
static func _unit_visible_in_history(uid: int, ai_unit_ids: Array, ai_fov: Dictionary, rec: Dictionary) -> bool:
	if uid in ai_unit_ids:
		return true
	if ai_fov.is_empty():
		return true
	var actions: Array = rec.get("actions", []) as Array
	for a in actions:
		if not (a is Dictionary):
			continue
		var d: Dictionary = a
		if int(d.get("unit_id", 0)) != uid:
			continue
		var dest: Variant = _get_action_dest_cell(d)
		if dest != null and _cell_in_fov(dest, ai_fov):
			return true
		var src: Variant = _get_action_source_cell(d)
		if src != null and _cell_in_fov(src, ai_fov):
			return true
	return false
