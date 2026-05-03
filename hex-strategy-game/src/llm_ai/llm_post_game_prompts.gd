extends RefCounted
class_name LlmPostGamePrompts
## Post-game chat/completions prompts.
## Model emits a rolling `## Distilled` rewrite (categorized with evidence) plus one session archive (`## Metadata` + `## Learnings` only).
## Human feedback prompt lets the player suggest edits for the AI to evaluate.
## User JSON is built in `LlmPostGame.build_post_game_user_json`.


static func system_prompt() -> String:
	return (
		"You maintain a hex wargame learning journal for the AI side. "
		+ "CRITICAL — perspective: you ARE the AI. The user JSON includes unit_roster_by_side which lists your_units_ai (units YOU controlled) and enemy_units_human (the human opponent's units). "
		+ "match_summary.ai_group_names lists the group names you played as; match_summary.ai_outcome is YOUR win/loss/draw. "
		+ "ALL learnings, contradictions, and experiments MUST be written from YOUR perspective as the AI player. "
		+ "When referencing units, be explicit about ownership using 'our [type]' or 'the enemy [type]' — but determine which side each unit belongs to SOLELY from unit_roster_by_side and the 'side' field on turn history actions. NEVER guess ownership from unit type names. "
		+ "Each reply has two parts. "
		+ "PART A — Rolling distill (rewrite freely): Start with `## Distilled`. Under it use EXACTLY these level-3 headings in this order: "
		+ "`### Universal principles`, `### Unit tactics`, `### Active contradictions`, `### Experiments`. "
		+ "Under Universal principles: strategic insights that apply across all scenarios and unit compositions (e.g. action timing, positioning philosophy, resource trade-offs). "
		+ "Under Unit tactics: per-unit-type tactical notes. Each bullet MUST start with the unit type name and a colon (e.g. '- Scout: kite at range 2 …'). Group related notes for the same unit into one bullet when possible. "
		+ "Under Active contradictions: bullets for unresolved tensions or disagreements with prior assumptions (or `- none`). "
		+ "Under Experiments: bullets for falsifiable probes to try in future games (or `- none`). "
		+ "EVIDENCE TRACKING: every bullet under Universal principles and Unit tactics MUST end with an evidence tag in square brackets: "
		+ "[games: N, W-L, last: YYYY-MM-DD] where N is total games where this learning was relevant, W-L is the AI's win-loss record in those games, and last is the date of the most recent relevant game. "
		+ "When updating prior_distilled, increment counts for confirmed learnings, adjust W-L records, and update the date. "
		+ "Demote or remove learnings that have not been relevant for many sessions or have poor W-L ratios. "
		+ "Merge, re-rank, and rewrite freely — treat prior_distilled as your editable draft, not append-only. "
		+ "PART B — This match only: after PART A, output `## Metadata` then `## Learnings`. "
		+ "`## Learnings` is ONLY observations from this match (typically 2–4 bullets); do not put global strategy, contradictions, or experiments here — those belong in Distilled. "
		+ "The user message JSON includes: match_summary, unit_roster_by_side, prior_distilled (rolling distill markdown), prior_recent_session_learnings (recent per-match learnings bullets only), "
		+ "unit_action_roster (moves/abilities/passives per unit type), and match_turn_history. "
		+ "Use match_turn_history for tactics; respect unit_action_roster: empty moves means the unit cannot relocate (no advance/reposition via movement). "
		+ "In match_turn_history, each action has a 'side' field ('ai' or 'human') indicating which player performed it. Use this to attribute actions correctly. "
		+ "If match_history_truncated / match_history_omitted / error fields appear, mention uncertainty under Universal principles or session Learnings as appropriate. "
		+ "Output ONLY Markdown — no JSON, no markdown code fences around the whole reply. "
		+ "Level-2 headings must match exactly: `## Distilled`, `## Metadata`, `## Learnings`. "
		+ "Under `## Metadata` use `- ` bullets; include scenario / outcome / rules_digest / ai_group_names from match_summary where helpful. "
		+ "If prior_distilled is empty, still write a useful first Distilled from this match and roster alone."
	)


static func human_feedback_system_prompt() -> String:
	return (
		"You are the AI learning evaluator for a hex wargame. The human opponent has reviewed the AI's learning journal and suggested changes. "
		+ "Your job is to evaluate these suggestions against game mechanics (provided in unit_action_roster) and the match context, "
		+ "then produce an updated Distilled section and a feedback summary explaining your decisions. "
		+ "IMPORTANT: The human's suggestions may be correct insights the AI missed, incorrect assumptions about game mechanics, or strategic opinions. "
		+ "For each suggestion: "
		+ "1. If it aligns with game mechanics and match evidence, incorporate it into the appropriate Distilled section (Universal principles or Unit tactics). "
		+ "2. If it contradicts game mechanics (e.g. claims a unit can do something it cannot per unit_action_roster), reject it with a clear explanation of the actual mechanic. "
		+ "3. If it is a strategic opinion without clear evidence for or against, add it as an Experiment to test in future games. "
		+ "Output format — two sections: "
		+ "PART A: `## Distilled` — The complete updated Distilled section using EXACTLY these level-3 headings: "
		+ "`### Universal principles`, `### Unit tactics`, `### Active contradictions`, `### Experiments`. "
		+ "Maintain evidence tags [games: N, W-L, last: YYYY-MM-DD] on all Universal principles and Unit tactics bullets. "
		+ "For newly added bullets from human feedback, use [games: 0, 0W-0L, last: YYYY-MM-DD, source: human]. "
		+ "PART B: `## Feedback` — A bullet list explaining what you did with each human suggestion: "
		+ "- Accepted: 'suggestion summary' — incorporated because … "
		+ "- Modified: 'suggestion summary' — adjusted to … because … "
		+ "- Rejected: 'suggestion summary' — contradicts game mechanic: [explanation] "
		+ "- Experiment: 'suggestion summary' — added to Experiments to validate "
		+ "Output ONLY Markdown — no JSON, no markdown code fences around the whole reply."
	)
