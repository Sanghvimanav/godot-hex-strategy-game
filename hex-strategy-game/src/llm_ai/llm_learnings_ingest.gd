extends RefCounted
class_name LlmLearningsIngest
## Reads Markdown under user://ai_learnings/ (§7.7); builds bounded text for planning JSON `prior_learnings`.
## Session files: any top-level `*.md`, newest first (see §7.3 for heading names); subfolders are not scanned in v1.

## No trailing slash — use path_join for files (DirAccess.open is picky on some platforms).
const USER_LEARNINGS_ROOT := "user://ai_learnings"
## Last K session files by modified time (§7.4 / §7.7).
const MAX_SESSION_FILES := 8
## Rough char budget for injected block (~§7.4 “≤ ~1k tokens” for recent learnings; keep conservative).
const MAX_INJECT_CHARS := 3600

const _SECTION_NAMES: Array[String] = [
	"Metadata",
	"Result",
	"Learnings",
	"Contradictions",
	"Experiments",
]


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


static func _list_md_newest_first() -> PackedStringArray:
	var entries: Array = []
	var dir := DirAccess.open(USER_LEARNINGS_ROOT)
	if dir == null:
		return PackedStringArray()
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and not fn.begins_with(".") and fn.ends_with(".md"):
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

	var paths := _list_md_newest_first()
	var chunks: PackedStringArray = PackedStringArray()
	var used := 0
	var count := 0
	for path in paths:
		if count >= MAX_SESSION_FILES:
			break
		count += 1
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
		"Prior learnings from local Markdown (user://ai_learnings/). "
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
