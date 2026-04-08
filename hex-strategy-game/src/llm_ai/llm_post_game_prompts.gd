extends RefCounted
class_name LlmPostGamePrompts
## Post-game chat/completions prompts (spec §7.5). Model must emit Markdown with exact ## headings for §7.3 / §7.7.
## User message JSON is built in `LlmPostGame.build_post_game_user_json` (includes full `match_turn_history`).


static func system_prompt() -> String:
	return (
		"You distill one hex wargame match into a short Markdown journal for the AI opponent. "
		+ "The user message is JSON with: match_summary (scenario, outcome, etc.), prior_learnings_excerpt (text), "
		+ "and match_turn_history — the full ordered list of executed turns for this match. "
		+ "Each match_turn_history entry is { \"turn\": number, \"recording\": { ... } }. "
		+ "recording typically includes: actions (serialized moves/abilities with paths, end_point, action_key, unit_id), "
		+ "died_ids, damage_by_id, summary (phase-grouped planned actions), before_state (per-unit snapshots before resolution). "
		+ "Use match_turn_history to infer concrete tactics (e.g. stacking, trades, timing) that explain the outcome. "
		+ "If match_history_truncated / match_history_omitted / error fields appear, note uncertainty in ## Learnings. "
		+ "Output ONLY Markdown — no JSON, no markdown code fences around the whole reply. "
		+ "Use these level-2 headings EXACTLY (ASCII, case-sensitive titles): "
		+ "## Result, ## Learnings, ## Contradictions, ## Experiments. "
		+ "Under ## Result: one bullet line starting with '- ' stating win, loss, draw, or incomplete from the AI side's perspective (same as ai_outcome in match_summary). "
		+ "Under ## Learnings: 2–4 bullet lines max, one line each. "
		+ "Under ## Contradictions: 1–3 bullets comparing new conclusions to prior_learnings_excerpt when relevant, or a single '- none' if none. "
		+ "Under ## Experiments: 1–2 bullets with testable probes for future games, or '- none'. "
		+ "Be concise. If prior excerpt is empty, still fill sections honestly from match_summary and match_turn_history."
	)
