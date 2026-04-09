extends RefCounted
class_name LlmPostGamePrompts
## Post-game chat/completions prompts. Model emits a rolling `## Distilled` rewrite plus one session archive (`## Metadata` + `## Learnings` only).
## User JSON is built in `LlmPostGame.build_post_game_user_json`.


static func system_prompt() -> String:
	return (
		"You maintain a hex wargame learning journal for the AI opponent. Each reply has two parts. "
		+ "PART A — Rolling distill (rewrite freely): Start with `## Distilled`. Under it use EXACTLY these level-3 headings in this order: "
		+ "`### Ranked learnings`, `### Active contradictions`, `### Experiments`. "
		+ "Under Ranked learnings: bullet list (`- `) ordered most important first; merge, drop stale items, and re-rank as needed — treat `prior_distilled` as your editable draft, not append-only. "
		+ "Under Active contradictions: bullets for unresolved tensions or disagreements with prior assumptions (or `- none`). "
		+ "Under Experiments: bullets for falsifiable probes to try in future games (or `- none`). "
		+ "PART B — This match only: after PART A, output `## Metadata` then `## Learnings`. "
		+ "`## Learnings` is ONLY observations from this match (typically 2–4 bullets); do not put global strategy, contradictions, or experiments here — those belong in Distilled. "
		+ "The user message JSON includes: match_summary, prior_distilled (rolling distill markdown), prior_recent_session_learnings (recent per-match learnings bullets only), "
		+ "unit_action_roster (moves/abilities/passives per unit type), and match_turn_history. "
		+ "Use match_turn_history for tactics; respect unit_action_roster: empty moves means the unit cannot relocate (no advance/reposition via movement). "
		+ "If match_history_truncated / match_history_omitted / error fields appear, mention uncertainty under Ranked learnings or session Learnings as appropriate. "
		+ "Output ONLY Markdown — no JSON, no markdown code fences around the whole reply. "
		+ "Level-2 headings must match exactly: `## Distilled`, `## Metadata`, `## Learnings`. "
		+ "Under `## Metadata` use `- ` bullets; include scenario / outcome / rules_digest from match_summary where helpful. "
		+ "If prior_distilled is empty, still write a useful first Distilled from this match and roster alone."
	)
