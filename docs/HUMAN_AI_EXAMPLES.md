# Useful human examples for AI training

Prefer specific mistakes and counterexamples to a large collection of routine wins.
Play training/custom maps, not the reserved Phase 1 evaluation games or layouts.
Try both factions. A small initial batch of 10–20 short games is useful, especially
when it exposes the same weakness in several slightly different starting positions.

Priority situations:

- Coordinate attacks to cover different possible enemy destinations.
- Retreat a wounded unit while another unit covers it.
- Sacrifice a Baneling only when the opponent cannot safely escape.
- Race a command objective versus defending or eliminating the opponent.
- Exploit a stunned enemy or wait for an imminent heal/reinforcement.
- Break passive play with an attack that remains good against counterplay.

For each useful turn, retain the exact pre-turn dictionary state, your faction,
the commands you chose (unit ID, action key, path and target), and eventual game
outcome. Add a short explanation of what the AI missed and which opponent response
could defeat your preferred plan. Avoid revealing the opponent's submitted commands
as part of the policy's pre-turn input. Both submitted plans can be retained later
for replay/analysis, but not exposed to the choosing agent.

Screenshots plus preferred commands and an explanation are helpful for diagnosing
and authoring a replayable example, but are not direct numerical training records.
Raw states and commands are substantially better. The current proposal trainer
consumes validated search-decision JSONL; human records must be checked against
the canonical legal-action enumerator and converted into that representation.
Human preference is not a fabricated terminal win label. Compare proposed human
and AI plans using real continuations, leaving unresolved outcomes unlabeled.

Do not spend time playing the fixed benchmark repeatedly to supply training data.
Examples from those games cannot be used to improve the model being evaluated on them.
