extends RefCounted
class_name LlmLearningsIngest
## Reads Markdown under user://ai_learnings/; builds bounded text for planning JSON `prior_learnings`.
## Primary: canonical `ai_learnings.md` contains ONLY the rolling `## Distilled` block.
## Session archives live as individual files under user://ai_learnings/sessions/ (newest-first by filename).

const USER_LEARNINGS_ROOT := "user://ai_learnings"
const CANONICAL_LEARNINGS_FILENAME := "ai_learnings.md"
const SESSIONS_SUBFOLDER := "sessions"
## Max session archive files kept on disk; oldest pruned when exceeded.
const MAX_SESSION_FILES := 40
## Recent session files read for post-game context.
const MAX_SESSION_SNIPPETS_FOR_POST_GAME := 8
## Char budget for rolling distilled block in planner prompt.
const MAX_DISTILLED_INJECT_CHARS := 8000
## Rough total char budget for the injected prior_learnings block.
const MAX_INJECT_CHARS := 10000
## Cap when passing distilled into post-game JSON.
const MAX_POSTGAME_DISTILLED_EXCERPT_CHARS := 12000
## Cap for recent session learnings excerpt in post-game JSON.
const MAX_POSTGAME_RECENT_SESSION_CHARS := 4000

const _SECTION_NAMES: Array[String] = [
	"Metadata",
	"Result",
	"Learnings",
	"Contradictions",
	"Experiments",
]


static func canonical_learnings_path() -> String:
	return USER_LEARNINGS_ROOT.path_join(CANONICAL_LEARNINGS_FILENAME)


static func sessions_dir_path() -> String:
	return USER_LEARNINGS_ROOT.path_join(SESSIONS_SUBFOLDER)


## Split canonical file text into session chunks (newest-first file order preserved).
## Kept for backwards compat with old format files that have embedded sessions.
static func split_canonical_markdown_into_sessions(md: String) -> PackedStringArray:
	var raw: PackedStringArray = md.split("\n---\n")
	var out: PackedStringArray = PackedStringArray()
	for part in raw:
		var t: String = str(part).strip_edges()
		if not t.is_empty():
			out.append(t)
	return out


## Parse canonical file. New format: distilled-only. Old format: distilled + --- + sessions.
## Returns { distilled: String, sessions: PackedStringArray }.
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


static func ensure_sessions_directory() -> void:
	ensure_directory()
	var d := DirAccess.open(USER_LEARNINGS_ROOT)
	if d == null:
		push_warning("LlmLearningsIngest: cannot open %s" % USER_LEARNINGS_ROOT)
		return
	if not d.dir_exists(SESSIONS_SUBFOLDER):
		var err := d.make_dir(SESSIONS_SUBFOLDER)
		if err != OK:
			push_warning("LlmLearningsIngest: could not create sessions dir (err %d)" % err)


## Deletes all learnings: canonical file + all session archives.
static func clear_saved_learnings_from_disk() -> Dictionary:
	ensure_directory()
	var deleted := 0
	var failed := 0
	var dir := DirAccess.open(USER_LEARNINGS_ROOT)
	if dir == null:
		return { "ok": false, "deleted_count": 0, "failed": 0 }
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and not fn.begins_with(".") and fn.ends_with(".md"):
			var err := dir.remove(fn)
			if err == OK:
				deleted += 1
			else:
				failed += 1
		fn = dir.get_next()
	dir.list_dir_end()
	var sess_dir := DirAccess.open(sessions_dir_path())
	if sess_dir != null:
		sess_dir.list_dir_begin()
		fn = sess_dir.get_next()
		while fn != "":
			if not sess_dir.current_is_dir() and fn.ends_with(".md"):
				var err := sess_dir.remove(fn)
				if err == OK:
					deleted += 1
				else:
					failed += 1
			fn = sess_dir.get_next()
		sess_dir.list_dir_end()
	return { "ok": true, "deleted_count": deleted, "failed": failed }


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


## List session archive files in sessions/ dir, sorted newest-first (by filename which is timestamp-prefixed).
static func list_session_files_newest_first() -> PackedStringArray:
	ensure_sessions_directory()
	var dir := DirAccess.open(sessions_dir_path())
	if dir == null:
		return PackedStringArray()
	var files: Array = []
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.ends_with(".md"):
			files.append(fn)
		fn = dir.get_next()
	dir.list_dir_end()
	files.sort()
	files.reverse()
	var out: PackedStringArray = PackedStringArray()
	for f in files:
		out.append(str(f))
	return out


## Write a session archive to sessions/ dir. Returns the full path written. Prunes oldest files beyond MAX_SESSION_FILES.
static func write_session_archive(content: String, scenario_id: String) -> String:
	ensure_sessions_directory()
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var ts := "%04d%02d%02d_%02d%02d%02d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
	]
	var safe_id := scenario_id.replace("/", "_").replace(" ", "_")
	var filename := "session_%s_%s.md" % [ts, safe_id]
	var path := sessions_dir_path().path_join(filename)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("LlmLearningsIngest: could not write session %s" % path)
		return ""
	f.store_string(content.strip_edges())
	f.close()
	_prune_old_sessions()
	return path


static func _prune_old_sessions() -> void:
	var files := list_session_files_newest_first()
	if files.size() <= MAX_SESSION_FILES:
		return
	var dir := DirAccess.open(sessions_dir_path())
	if dir == null:
		return
	for i in range(MAX_SESSION_FILES, files.size()):
		dir.remove(str(files[i]))


## Read the distilled-only canonical file.
static func read_distilled_from_disk() -> String:
	var path := canonical_learnings_path()
	if not FileAccess.file_exists(path):
		return ""
	var raw := FileAccess.get_file_as_string(path)
	var parsed := parse_canonical_file(raw)
	return str(parsed.get("distilled", "")).strip_edges()


## Write distilled-only to the canonical file (no sessions embedded).
static func write_distilled_to_disk(distilled_md: String) -> String:
	ensure_directory()
	var path := canonical_learnings_path()
	var d := distilled_md.strip_edges()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("LlmLearningsIngest: could not write %s" % path)
		return ""
	f.store_string(d)
	f.close()
	return path


## Plain-text excerpt of ## Learnings bullets from session archive content strings.
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


## Read recent session files and build learnings text for post-game context.
static func read_recent_sessions_for_post_game() -> String:
	var files := list_session_files_newest_first()
	var sessions: PackedStringArray = PackedStringArray()
	var base := sessions_dir_path()
	for i in range(mini(files.size(), MAX_SESSION_SNIPPETS_FOR_POST_GAME)):
		var path := base.path_join(str(files[i]))
		if FileAccess.file_exists(path):
			sessions.append(FileAccess.get_file_as_string(path).strip_edges())
	return build_recent_session_learnings_text(
		sessions,
		MAX_SESSION_SNIPPETS_FOR_POST_GAME,
		MAX_POSTGAME_RECENT_SESSION_CHARS,
	)


## Text for post-game JSON: capped rolling distill + capped recent session learnings.
static func extract_prior_context_for_post_game() -> Dictionary:
	var d := read_distilled_from_disk()
	if d.length() > MAX_POSTGAME_DISTILLED_EXCERPT_CHARS:
		d = d.substr(0, MAX_POSTGAME_DISTILLED_EXCERPT_CHARS) + "\n…"
	var r := read_recent_sessions_for_post_game()
	return { "distilled": d, "recent_session_learnings": r }


## Build prior_learnings block for the planning prompt. Distilled-only (no session snippets).
static func build_prompt_block_for_planner(map_bounds: Dictionary = {}) -> String:
	ensure_directory()
	var bounds_block := map_bounds_learnings_block(map_bounds)

	var distilled := read_distilled_from_disk()
	if distilled.is_empty() and bounds_block.is_empty():
		return "(no prior learnings yet)"

	var header := (
		"Prior learnings from the AI's rolling distilled journal (categorized: Universal principles, Unit tactics, Active contradictions, Experiments). "
		+ "Each learning has an evidence tag [games: N, W-L, last: date]. Higher-evidence learnings are more reliable. "
		+ "Honor when consistent with legal_options and rules_digest; ignore otherwise.\n"
	)
	var parts: PackedStringArray = PackedStringArray()
	if not bounds_block.is_empty():
		parts.append(bounds_block)
	if not distilled.is_empty():
		if parts.size() > 0:
			parts.append("")
		var hdr := "--- rolling distilled summary (universal principles, unit tactics, contradictions, experiments) ---\n"
		var capped := distilled
		if capped.length() > MAX_DISTILLED_INJECT_CHARS:
			capped = capped.substr(0, MAX_DISTILLED_INJECT_CHARS) + "\n…"
		parts.append(hdr + capped)

	return header + "\n".join(parts)
