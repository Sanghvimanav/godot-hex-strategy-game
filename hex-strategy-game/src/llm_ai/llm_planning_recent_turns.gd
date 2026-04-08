extends RefCounted
class_name LlmPlanningRecentTurns
## Builds JSON-safe `recent_turns` for the planning snapshot from UnitsContainer.replay_turn_history.

const MAX_TURNS := 5
const MAX_ACTIONS_PER_TURN := 32


static func build_for_llm(units: Node) -> Array:
	if units == null:
		return []
	var h: Variant = units.get("replay_turn_history")
	if h == null or not (h is Array):
		return []
	return build_from_history(h as Array)


## Exposed for tests; `history` is `[{ "turn": int, "recording": Dictionary }, ...]`.
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
		out.append(_compact_turn(turn_n, rec))
	return out


static func _compact_turn(turn_n: int, rec: Dictionary) -> Dictionary:
	var died_raw: Variant = rec.get("died_ids", [])
	var died: Array = []
	if died_raw is Array:
		for x in died_raw as Array:
			died.append(int(x))
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
		var one: Dictionary = {
			"unit_id": uid,
			"unit_name": str(d.get("unit_name", "Unit")),
			"type": str(d.get("type", "")),
		}
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
		"died_unit_ids": died,
		"actions": compact_actions,
	}
