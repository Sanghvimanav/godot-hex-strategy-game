extends RefCounted
## Tests for §7.7 Markdown section parsing (no user:// IO in core tests).

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_parse_all_sections(tests) and ok
	ok = _test_parse_unknown_heading_ignored(tests) and ok
	ok = _test_parse_garbage_no_crash(tests) and ok
	ok = _test_format_sections_output(tests) and ok
	ok = _test_map_bounds_learnings_block(tests) and ok
	return ok

static func _sample_md() -> String:
	return """## Metadata
- k: v

## Result
- loss

## Learnings
- First lesson
- Second lesson

## Contradictions
- A vs B

## Experiments
- Try X (open)
"""

static func _test_parse_all_sections(tests: Node) -> bool:
	tests._log("test_llm_learnings_ingest: parse_all_sections")
	var d: Dictionary = LlmLearningsIngest.parse_markdown_sections(_sample_md())
	if (d["Metadata"] as Array).size() != 1:
		tests._fail("expected 1 Metadata bullet")
		return false
	if (d["Result"] as Array).size() != 1 or str((d["Result"] as Array)[0]) != "loss":
		tests._fail("expected Result loss")
		return false
	if (d["Learnings"] as Array).size() != 2:
		tests._fail("expected 2 Learnings")
		return false
	if (d["Contradictions"] as Array).size() != 1:
		tests._fail("expected 1 Contradiction")
		return false
	if (d["Experiments"] as Array).size() != 1:
		tests._fail("expected 1 Experiment")
		return false
	tests._pass("parse_all_sections")
	return true

static func _test_parse_unknown_heading_ignored(tests: Node) -> bool:
	tests._log("test_llm_learnings_ingest: unknown_heading_ignored")
	var md := "## Learnings\n- ok\n## NotASection\n- bad\n"
	var d: Dictionary = LlmLearningsIngest.parse_markdown_sections(md)
	if (d["Learnings"] as Array).size() != 1 or str((d["Learnings"] as Array)[0]) != "ok":
		tests._fail("Learnings should parse")
		return false
	tests._pass("unknown_heading_ignored")
	return true

static func _test_parse_garbage_no_crash(tests: Node) -> bool:
	tests._log("test_llm_learnings_ingest: garbage_no_crash")
	var d1: Dictionary = LlmLearningsIngest.parse_markdown_sections("not markdown {{{")
	var d2: Dictionary = LlmLearningsIngest.parse_markdown_sections("")
	for n in ["Learnings", "Contradictions", "Experiments"]:
		if (d1.get(n, null) as Array).size() != 0:
			tests._fail("garbage should yield empty %s" % n)
			return false
	if (d2["Learnings"] as Array).size() != 0:
		tests._fail("empty string should yield empty Learnings")
		return false
	tests._pass("garbage_no_crash")
	return true

static func _test_format_sections_output(tests: Node) -> bool:
	tests._log("test_llm_learnings_ingest: format_sections_output")
	var d: Dictionary = LlmLearningsIngest.parse_markdown_sections(_sample_md())
	var fmt: String = LlmLearningsIngest._format_sections_for_file("sess.md", d)
	if not fmt.contains("First lesson") or not fmt.contains("Try X"):
		tests._fail("formatted block missing bullets: %s" % fmt)
		return false
	if not fmt.begins_with("--- file: sess.md ---"):
		tests._fail("expected file header")
		return false
	tests._pass("format_sections_output")
	return true

static func _test_map_bounds_learnings_block(tests: Node) -> bool:
	tests._log("test_llm_learnings_ingest: map_bounds_learnings_block")
	var b: String = LlmLearningsIngest.map_bounds_learnings_block({})
	if not b.is_empty():
		tests._fail("empty dict should yield empty block")
		return false
	var s: String = LlmLearningsIngest.map_bounds_learnings_block({
		"hex_radius": 5,
		"q_range": [-5, 5],
		"r_range": [-4, 4],
	})
	if not s.contains("## Map boundaries"):
		tests._fail("expected heading")
		return false
	if not s.contains("hex_radius=5"):
		tests._fail("expected hex_radius in text: %s" % s)
		return false
	if not s.contains("-5") or not s.contains("5"):
		tests._fail("expected q range in text: %s" % s)
		return false
	tests._pass("map_bounds_learnings_block")
	return true
