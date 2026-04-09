extends RefCounted
class_name LlmPostGame
## Phase 4: capture match end state, optional post-game LLM, append session Markdown to user://ai_learnings/ai_learnings.md.

const _LearningsIngest = preload("res://src/llm_ai/llm_learnings_ingest.gd")
const _PostGamePrompts = preload("res://src/llm_ai/llm_post_game_prompts.gd")
## Oldest sessions dropped after this many blocks (newline --- newline separated).
const MAX_CANONICAL_SESSION_BLOCKS := 40

## Pending handoff from battle → scenario picker (cleared after consume).
static var _pending: Dictionary = {}

## Cap entire user JSON (match summary + full turn history + prior context) for provider limits.
const MAX_POST_GAME_USER_PAYLOAD_CHARS := 900_000


static func has_pending() -> bool:
	return not _pending.is_empty()


static func capture_from_battle(units: UnitsContainer) -> void:
	if units == null:
		_pending = {}
		return
	var gs: Dictionary = units._build_game_state_from_scene()
	_pending = {
		"match_had_llm_validated_plan": units.match_had_llm_validated_plan,
		"scenario_id": Scenarios.selected_scenario_id,
		"turn_number": units.turn_number,
		"game_state": gs,
		"ai_group_names": units.ai_group_names.duplicate(),
		"match_turn_history": units.match_full_turn_history.duplicate(true),
	}


static func take_pending() -> Dictionary:
	var d: Dictionary = _pending.duplicate(true)
	_pending.clear()
	return d


static func ai_outcome_from_game_state(game_state: Dictionary, ai_names: Array[String]) -> String:
	var human_alive := false
	var ai_alive := false
	for raw in game_state.get("groups", []):
		if not (raw is Dictionary):
			continue
		var g: Dictionary = raw
		var gname: String = str(g.get("name", ""))
		var is_ai: bool = gname in ai_names
		var any_alive := false
		for u in g.get("units", []):
			if u is Dictionary and int(u.get("health", 0)) > 0:
				any_alive = true
				break
		if any_alive:
			if is_ai:
				ai_alive = true
			else:
				human_alive = true
	if human_alive and ai_alive:
		return "incomplete"
	if ai_alive and not human_alive:
		return "win"
	if human_alive and not ai_alive:
		return "loss"
	return "draw"


static func build_match_summary(session: Dictionary) -> Dictionary:
	var gs: Dictionary = session.get("game_state", {}) as Dictionary
	var ai_names: Array[String] = []
	for x in session.get("ai_group_names", []):
		ai_names.append(str(x))
	var outcome: String = ai_outcome_from_game_state(gs, ai_names)
	var hist: Array = session.get("match_turn_history", []) as Array
	return {
		"scenario_id": str(session.get("scenario_id", "")),
		"rules_digest": "v1",
		"turn_number_at_end": int(session.get("turn_number", 1)),
		"had_llm_plans": bool(session.get("match_had_llm_validated_plan", false)),
		"ai_outcome": outcome,
		"ai_group_names": ai_names,
		"recorded_turns_in_history": hist.size(),
	}


## Recursively convert Vector2/Vector2i and non-JSON-friendly values for JSON.stringify.
static func sanitize_for_json(v: Variant) -> Variant:
	var t: int = typeof(v)
	if t == TYPE_DICTIONARY:
		var d: Dictionary = v
		var out: Dictionary = {}
		for k in d:
			out[str(k)] = sanitize_for_json(d[k])
		return out
	if t == TYPE_ARRAY:
		var arr: Array = v
		var out_a: Array = []
		for x in arr:
			out_a.append(sanitize_for_json(x))
		return out_a
	if t == TYPE_VECTOR2:
		var vv: Vector2 = v
		return [int(vv.x), int(vv.y)]
	if t == TYPE_VECTOR2I:
		var vi: Vector2i = v
		return [vi.x, vi.y]
	if t == TYPE_VECTOR3:
		var v3: Vector3 = v
		return [int(v3.x), int(v3.y), int(v3.z)]
	if t == TYPE_VECTOR3I:
		var v3i: Vector3i = v
		return [v3i.x, v3i.y, v3i.z]
	if t == TYPE_COLOR:
		return str(v)
	if t == TYPE_OBJECT:
		return str(v)
	return v


static func build_post_game_user_json(
	session: Dictionary,
	match_summary: Dictionary,
	prior_distilled: String,
	prior_recent_session_learnings: String,
) -> String:
	var raw_hist: Array = session.get("match_turn_history", []) as Array
	var sanitized_hist: Variant = sanitize_for_json(raw_hist)
	if not (sanitized_hist is Array):
		sanitized_hist = []
	var payload: Dictionary = {
		"match_summary": match_summary,
		"prior_distilled": prior_distilled,
		"prior_recent_session_learnings": prior_recent_session_learnings,
		"unit_action_roster": LlmUnitCapabilities.build_unit_action_roster(),
		"match_turn_history": sanitized_hist,
	}
	var truncated := false
	var note := ""
	while true:
		var s: String = JSON.stringify(payload)
		if s.is_empty():
			return "{\"error\":\"json_encode_failed\"}"
		if s.length() <= MAX_POST_GAME_USER_PAYLOAD_CHARS:
			if truncated:
				payload["match_history_truncated"] = true
				payload["match_history_truncated_note"] = note
			return JSON.stringify(payload)
		var turns: Array = payload.get("match_turn_history", []) as Array
		if turns.size() > 1:
			truncated = true
			note = "Oldest turns removed to fit size cap (~%d chars); newest retained." % MAX_POST_GAME_USER_PAYLOAD_CHARS
			turns.remove_at(0)
			payload["match_turn_history"] = turns
			continue
		payload["match_turn_history"] = []
		payload["match_history_omitted"] = true
		payload["match_history_omitted_note"] = "Turn recordings omitted: payload still exceeded cap with a single turn."
		s = JSON.stringify(payload)
		if s.length() <= MAX_POST_GAME_USER_PAYLOAD_CHARS:
			return s
		payload["prior_recent_session_learnings"] = "(omitted — payload too large)"
		s = JSON.stringify(payload)
		if s.length() <= MAX_POST_GAME_USER_PAYLOAD_CHARS:
			return s
		payload["prior_distilled"] = "(omitted — payload too large)"
		s = JSON.stringify(payload)
		if s.length() <= MAX_POST_GAME_USER_PAYLOAD_CHARS:
			return s
		return JSON.stringify({
			"match_summary": match_summary,
			"match_turn_history": [],
			"prior_distilled": "(omitted)",
			"prior_recent_session_learnings": "(omitted)",
			"error": "post_game_user_payload_still_too_large",
		})
	# `while true` above always returns; analyzer cannot prove exit, so this path is unreachable.
	push_error("LlmPostGame.build_post_game_user_json: loop fell through (bug)")
	return "{\"error\":\"post_game_user_json_internal\"}"


static func _strip_outer_fence(s: String) -> String:
	var t := s.strip_edges()
	if t.begins_with("```"):
		var first_nl := t.find("\n")
		if first_nl >= 0:
			t = t.substr(first_nl + 1)
		var close := t.rfind("```")
		if close >= 0:
			t = t.substr(0, close)
	return t.strip_edges()


## Split post-game model output into rolling distill (rewrite) vs one session archive (Metadata + Learnings only).
static func parse_post_game_llm_markdown(md: String) -> Dictionary:
	var t: String = _strip_outer_fence(md).strip_edges()
	if not t.begins_with("## Distilled"):
		return { "ok": false, "error": "missing_distilled_heading" }
	var needle := "\n## Metadata\n"
	var meta_idx: int = t.find(needle)
	if meta_idx < 0:
		needle = "\r\n## Metadata\r\n"
		meta_idx = t.find(needle)
	if meta_idx < 0:
		return { "ok": false, "error": "missing_metadata_separator" }
	var distilled: String = t.substr(0, meta_idx).strip_edges()
	var session: String = t.substr(meta_idx + 1).strip_edges()
	if not session.begins_with("## Metadata"):
		return { "ok": false, "error": "metadata_after_separator" }
	if not session.contains("## Learnings"):
		return { "ok": false, "error": "missing_session_learnings" }
	return { "ok": true, "distilled": distilled, "session": session }


static func _read_canonical_file_raw() -> String:
	var path: String = LlmLearningsIngest.canonical_learnings_path()
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


static func _existing_distilled_from_disk() -> String:
	var raw: String = _read_canonical_file_raw()
	var p: Dictionary = LlmLearningsIngest.parse_canonical_file(raw)
	return str(p.get("distilled", "")).strip_edges()


static func write_canonical_learnings(distilled_md: String, new_session_md: String) -> String:
	_LearningsIngest.ensure_directory()
	var path: String = LlmLearningsIngest.canonical_learnings_path()
	var old_raw: String = _read_canonical_file_raw()
	var parsed: Dictionary = LlmLearningsIngest.parse_canonical_file(old_raw)
	var old_sessions: PackedStringArray = parsed.get("sessions", PackedStringArray()) as PackedStringArray
	var blocks: PackedStringArray = PackedStringArray()
	var ns: String = new_session_md.strip_edges()
	if not ns.is_empty():
		blocks.append(ns)
	for i in range(old_sessions.size()):
		if blocks.size() >= MAX_CANONICAL_SESSION_BLOCKS:
			break
		blocks.append(str(old_sessions[i]).strip_edges())
	var d: String = distilled_md.strip_edges()
	var combined: String
	if d.is_empty():
		combined = "\n---\n".join(blocks)
	else:
		combined = "%s\n---\n%s" % [d, "\n---\n".join(blocks)]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("LlmPostGame: could not write %s" % path)
		return ""
	f.store_string(combined)
	f.close()
	return path


static func _metadata_lines(session: Dictionary, match_summary: Dictionary, learning_summary: String) -> PackedStringArray:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("## Metadata")
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	lines.append(
		"- date: %04d-%02d-%02d %02d:%02d:%02d"
		% [int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)), int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0))]
	)
	lines.append("- scenario: %s" % str(match_summary.get("scenario_id", "")))
	lines.append("- rules_digest: %s" % str(match_summary.get("rules_digest", "v1")))
	lines.append("- turns_at_end: %d" % int(match_summary.get("turn_number_at_end", 0)))
	lines.append("- learning_summary: %s" % learning_summary)
	return lines


static func write_stub_session_file(
	session: Dictionary,
	match_summary: Dictionary,
	learning_summary: String,
	body_note: String,
) -> String:
	var meta := _metadata_lines(session, match_summary, learning_summary)
	var parts: PackedStringArray = PackedStringArray()
	for line in meta:
		parts.append(line)
	parts.append("")
	parts.append("## Learnings")
	parts.append("- %s" % body_note)
	return write_canonical_learnings(_existing_distilled_from_disk(), "\n".join(parts))


static func write_llm_session_file(
	session: Dictionary,
	match_summary: Dictionary,
	learning_summary: String,
	llm_markdown: String,
) -> String:
	var existing: String = _existing_distilled_from_disk()
	var parsed := parse_post_game_llm_markdown(llm_markdown)
	if not bool(parsed.get("ok", false)):
		push_warning(
			"LlmPostGame: parse_post_game_llm_markdown failed (%s); distill unchanged."
			% str(parsed.get("error", "?"))
		)
		var meta := _metadata_lines(session, match_summary, learning_summary)
		var parts: PackedStringArray = PackedStringArray()
		for line in meta:
			parts.append(line)
		parts.append("")
		parts.append("## Learnings")
		parts.append("- Post-game model returned an unexpected shape; rolling distill left unchanged.")
		return write_canonical_learnings(existing, "\n".join(parts))
	return write_canonical_learnings(
		str(parsed.get("distilled", "")).strip_edges(),
		str(parsed.get("session", "")).strip_edges(),
	)


## Runs post-game pipeline: stubs when gated off; otherwise chat/completions (POST_GAME profile).
## Instance method (not static): `await` is not allowed in static GDScript functions.
func run_session_async(
	http: HTTPRequest,
	settings: LlmAiSettings,
	client: LlmOpenAiClient,
) -> Dictionary:
	var session: Dictionary = take_pending()
	if session.is_empty():
		return { "ok": true, "message": "", "skipped": true }

	var match_summary: Dictionary = build_match_summary(session)
	var had_llm: bool = bool(match_summary.get("had_llm_plans", false))

	if not had_llm:
		write_stub_session_file(
			session,
			match_summary,
			"skipped_no_llm_plays",
			"Session recorded; post-game LLM skipped (no validated LLM plans this match).",
		)
		return {
			"ok": true,
			"message": "AI learnings: saved session stub (no LLM plans this match — post-game distill skipped).",
			"skipped": false,
		}

	if not settings.has_configured_key():
		write_stub_session_file(
			session,
			match_summary,
			"skipped_no_key",
			"Had LLM plans but API key missing at save time — stub only.",
		)
		return { "ok": false, "message": "AI learnings: key missing; saved stub only.", "skipped": false }

	var pri: Dictionary = _LearningsIngest.extract_prior_context_for_post_game()
	var user_json: String = build_post_game_user_json(
		session,
		match_summary,
		str(pri.get("distilled", "")),
		str(pri.get("recent_session_learnings", "")),
	)
	var messages: Array = [
		{"role": "system", "content": _PostGamePrompts.system_prompt()},
		{"role": "user", "content": user_json},
	]
	var result: Dictionary = await client.chat_completions(
		http,
		settings.get_effective_base_url(),
		settings.api_key,
		settings.model,
		messages,
		LlmOpenAiClient.Profile.POST_GAME,
		LlmOpenAiClient.default_max_tokens(LlmOpenAiClient.Profile.POST_GAME),
	)
	if not result.get("ok", false):
		write_stub_session_file(
			session,
			match_summary,
			"unavailable",
			"Post-game LLM failed (%s); full distill unavailable." % str(result.get("error", "?")),
		)
		return {
			"ok": false,
			"message": "AI learnings: post-game call failed — saved stub (learning_summary unavailable).",
			"skipped": false,
		}

	var content: String = str(result.get("content", "")).strip_edges()
	if content.is_empty():
		write_stub_session_file(session, match_summary, "unavailable", "Post-game LLM returned empty body.")
		return { "ok": false, "message": "AI learnings: empty response — saved stub.", "skipped": false }

	write_llm_session_file(session, match_summary, "ok", content)
	return {
		"ok": true,
		"message": "AI learnings: updated rolling distill and archived this match in user://ai_learnings/ai_learnings.md.",
		"skipped": false,
	}
