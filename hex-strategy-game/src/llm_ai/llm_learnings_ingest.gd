extends RefCounted
class_name LlmLearningsIngest
## Reads Markdown under user://ai_learnings/; builds bounded text for planning JSON `prior_learnings`.
## Primary: canonical `ai_learnings.md`: optional leading `## Distilled` block, then sessions separated by a line containing only --- (newest session first).
## Fallback: any other top-level `*.md` by modified time, newest first.

## No trailing slash — use path_join for files (DirAccess.open is picky on some platforms).
const USER_LEARNINGS_ROOT := "user://ai_learnings"
const CANONICAL_LEARNINGS_FILENAME := "ai_learnings.md"
## Last K session archives (after Distilled) injected into the planner as learnings-only snippets.
const MAX_SESSION_SNIPPETS := 3
## Legacy: max whole session files when reading non-canonical markdown.
const MAX_SESSION_FILES := 8
## Char budget for rolling distilled block in planner prompt.
const MAX_DISTILLED_INJECT_CHARS := 2400
## Rough total char budget for the injected prior_learnings block (distilled + recent session learnings + legacy).
const MAX_INJECT_CHARS := 4200
## Cap when passing distilled into post-game JSON.
const MAX_POSTGAME_DISTILLED_EXCERPT_CHARS := 8000
## Cap for recent session learnings excerpt in post-game JSON.
const MAX_POSTGAME_RECENT_SESSION_CHARS := 2500

const _SECTION_NAMES: Array[String] = [
	"Metadata",
	"Result",
	"Learnings",
	"Contradictions",
	"Experiments",
]


static func canonical_learnings_path() -> String:
	return USER_LEARNINGS_ROOT.path_join(CANONICAL_LEARNINGS_FILENAME)


## Split canonical file text into session chunks (newest-first file order preserved).
static func split_canonical_markdown_into_sessions(md: String) -> PackedStringArray:
	var raw: PackedStringArray = md.split("\n---\n")
	var out: PackedStringArray = PackedStringArray()
	for part in raw:
		var t: String = str(part).strip_edges()
		if not t.is_empty():
			out.append(t)
	return out


## If the first segment is `## Distilled`, it is the rolling summary; remaining segments are per-match archives (newest first).
static func parse_canonical_file(md: String) -> Dictionary:
	var distilled := ""
	var sessions: PackedStringArray = PackedStringArray()
	var chunks := split_canonical_markdown_into_sessions(md)
	if chunks.size() == 0:
		return { "distilled": distilled, "sessions": sessions }
	var first: String = str(chunks[0]).strip_edges()
	if first.begins_with("## Distilled"):
		distilled = first
		for i in range(1, chunks.size()):
			sessions.append(str(chunks[i]).strip_edges())
	else:
		for i in range(chunks.size()):
			sessions.append(str(chunks[i]).strip_edges())
	return { "distilled": distilled, "sessions": sessions }


static func ensure_directory() -> void:
	var d := DirAccess.open("user://")
	if d == null:
		push_warning("LlmLearningsIngest: cannot open user://")
		return
	if not d.dir_exists("ai_learnings"):
		var err := d.make_dir_recursive("ai_learnings")
		if err != OK:
			push_warning("LlmLearningsIngest: could not create ai_learnings (err %d)" % err)


## Parse one Markdown string: section name -> array of bullet lines (leading "- " stripped).
static func parse_markdown_sections(md: String) -> Dictionary:
	var out: Dictionary = {}
	for n in _SECTION_NAMES:
		out[n] = []
	if md.is_empty():
		return out
	var current := ""
	var lines: PackedStringArray = md.split("\n")
	for line in lines:
		var raw: String = line
		if raw.begins_with("## "):
			current = raw.substr(3).strip_edges()
			continue
		if current.is_empty() or not (current in _SECTION_NAMES):
			continue
		if raw.strip_edges().begins_with("- "):
			var bullet: String = raw.strip_edges().substr(2).strip_edges()
			if not bullet.is_empty():
				(out[current] as Array).append(bullet)
	return out


static func _format_sections_for_file(filename: String, sections: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append("--- file: %s ---" % filename)
	for key in ["Learnings", "Contradictions", "Experiments", "Result", "Metadata"]:
		var arr: Array = sections.get(key, []) as Array
		if arr.is_empty():
			continue
		parts.append("## %s" % key)
		for b in arr:
			parts.append("- %s" % str(b))
	return "\n".join(parts)


## Short Markdown block for `prior_learnings` with board size (optional) alongside file learnings.
static func map_bounds_learnings_block(map_bounds: Dictionary) -> String:
	if map_bounds.is_empty():
		return ""
	var qr: Variant = map_bounds.get("q_range", [])
	var rr: Variant = map_bounds.get("r_range", [])
	var hr: int = int(map_bounds.get("hex_radius", 0))
	var qlo = "?"
	var qhi = "?"
	var rlo = "?"
	var rhi = "?"
	if qr is Array and (qr as Array).size() >= 2:
		var qa: Array = qr as Array
		qlo = str(qa[0])
		qhi = str(qa[1])
	if rr is Array and (rr as Array).size() >= 2:
		var ra: Array = rr as Array
		rlo = str(ra[0])
		rhi = str(ra[1])
	var bullet := (
		"Board radius hex_radius=%s; approximate q span [%s,%s], r span [%s,%s] (orientation only). "
		% [str(hr), qlo, qhi, rlo, rhi]
		+ "Choose only legal_options[].i; use dist_from_map_edge when exploring toward unseen tiles."
	)
	return "## Map boundaries (automatic)\n\n- %s" % bullet


## Plain-text excerpt of ## Learnings bullets from the first `max_sessions` session archives (canonical file order).
static func build_recent_session_learnings_text(
	sessions: PackedStringArray,
	max_sessions: int,
	max_chars: int,
) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var count := 0
	for block in sessions:
		if count >= max_sessions:
			break
		var sections := parse_markdown_sections(block)
		var arr: Array = sections.get("Learnings", []) as Array
		if arr.is_empty():
			continue
		parts.append("--- prior session learnings #%d ---" % count)
		parts.append("## Learnings")
		for b in arr:
			parts.append("- %s" % str(b))
		count += 1
	var s: String = "\n".join(parts)
	if max_chars > 0 and s.length() > max_chars:
		return s.substr(0, max_chars) + "\n…"
	return s


## Text for post-game JSON: capped rolling distill + capped recent session learnings only.
static func extract_prior_context_for_post_game() -> Dictionary:
	ensure_directory()
	var path := canonical_learnings_path()
	if not FileAccess.file_exists(path):
		return { "distilled": "", "recent_session_learnings": "" }
	var parsed: Dictionary = parse_canonical_file(FileAccess.get_file_as_string(path))
	var d: String = str(parsed.get("distilled", "")).strip_edges()
	if d.length() > MAX_POSTGAME_DISTILLED_EXCERPT_CHARS:
		d = d.substr(0, MAX_POSTGAME_DISTILLED_EXCERPT_CHARS) + "\n…"
	var sessions: PackedStringArray = parsed.get("sessions", PackedStringArray()) as PackedStringArray
	var r: String = build_recent_session_learnings_text(
		sessions,
		12,
		MAX_POSTGAME_RECENT_SESSION_CHARS,
	)
	return { "distilled": d, "recent_session_learnings": r }


static func _list_md_newest_first() -> PackedStringArray:
	var entries: Array = []
	var dir := DirAccess.open(USER_LEARNINGS_ROOT)
	if dir == null:
		return PackedStringArray()
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if (
			not dir.current_is_dir()
			and not fn.begins_with(".")
			and fn.ends_with(".md")
			and fn != CANONICAL_LEARNINGS_FILENAME
		):
			var path: String = USER_LEARNINGS_ROOT.path_join(fn)
			var mt: int = 0
			if FileAccess.file_exists(path):
				mt = FileAccess.get_modified_time(path)
			entries.append({ "path": path, "name": fn, "mtime": mt })
		fn = dir.get_next()
	dir.list_dir_end()

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["mtime"]) > int(b["mtime"]))
	var out: PackedStringArray = PackedStringArray()
	for e in entries:
		out.append(str(e["path"]))
	return out


static func build_prompt_block_for_planner(map_bounds: Dictionary = {}) -> String:
	ensure_directory()
	var bounds_block := map_bounds_learnings_block(map_bounds)

	var chunks: PackedStringArray = PackedStringArray()
	var used := 0

	var canonical_path := canonical_learnings_path()
	var used_canonical := false
	if FileAccess.file_exists(canonical_path):
		var canonical_full: String = FileAccess.get_file_as_string(canonical_path)
		if not canonical_full.strip_edges().is_empty():
			used_canonical = true
			var parsed: Dictionary = parse_canonical_file(canonical_full)
			var distilled: String = str(parsed.get("distilled", "")).strip_edges()
			if not distilled.is_empty():
				var sep_cost: int = 1 if chunks.size() > 0 else 0
				var hdr: String = "--- rolling distilled summary (ranked learnings, contradictions, experiments) ---\n"
				var room: int = MAX_INJECT_CHARS - used - sep_cost - hdr.length()
				if room > 48:
					var dchunk: String = distilled
					var soft_cap: int = mini(MAX_DISTILLED_INJECT_CHARS, room)
					if dchunk.length() > soft_cap:
						dchunk = dchunk.substr(0, soft_cap) + "\n…"
					var dblock: String = hdr + dchunk
					if chunks.size() > 0:
						chunks.append("")
						used += 1
					chunks.append(dblock)
					used += dblock.length()
			var sess: PackedStringArray = parsed.get("sessions", PackedStringArray()) as PackedStringArray
			var budget: int = maxi(0, MAX_INJECT_CHARS - used - 80)
			var recent: String = build_recent_session_learnings_text(sess, MAX_SESSION_SNIPPETS, budget)
			if not recent.is_empty():
				if chunks.size() > 0:
					chunks.append("")
					used += 1
				chunks.append(recent)
				used += recent.length()

	if not used_canonical:
		var paths := _list_md_newest_first()
		var count_legacy := 0
		for path in paths:
			if count_legacy >= MAX_SESSION_FILES:
				break
			count_legacy += 1
			if not FileAccess.file_exists(path):
				push_warning("LlmLearningsIngest: missing file %s" % path)
				continue
			var md := FileAccess.get_file_as_string(path)
			var sections := parse_markdown_sections(md)
			var all_empty := true
			for k in ["Learnings", "Contradictions", "Experiments", "Result", "Metadata"]:
				if (sections.get(k, []) as Array).size() > 0:
					all_empty = false
					break
			if all_empty:
				continue
			var fname := path.get_file()
			var block := _format_sections_for_file(fname, sections)
			if block.is_empty():
				continue
			var need_sep := chunks.size() > 0
			var add_len := block.length() + (1 if need_sep else 0)
			if used + add_len > MAX_INJECT_CHARS:
				if used > 0:
					chunks.append("… (truncated; older sessions omitted)")
				break
			if need_sep:
				chunks.append("")
			chunks.append(block)
			used += add_len

	if chunks.is_empty() and bounds_block.is_empty():
		return "(no prior learnings yet)"

	var header := (
		"Prior learnings from user://ai_learnings/ai_learnings.md (rolling distilled summary plus recent per-match learnings). "
		+ "Honor when consistent with legal_options and rules_digest; ignore otherwise.\n"
	)
	var parts: PackedStringArray = PackedStringArray()
	if not bounds_block.is_empty():
		parts.append(bounds_block)
	if not chunks.is_empty():
		if parts.size() > 0:
			parts.append("")
		parts.append("\n".join(chunks))
	return header + "\n".join(parts)
