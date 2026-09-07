# AI Roadmap

## Goal

A fair AI that coordinates simultaneous actions, avoids obvious blunders, discovers useful strategies, offers distinct play styles, and responds within the player's turn-time budget.

## Current position

The pure simulator, legal actions, bounded joint planning, opponent-response search, tactical intents, whole-game rollout, command-hex victory, counterfactual decision benchmark, seeded AI-vs-AI arena, richer self-play export, controlled policy exploration, and first neural value model all exist.

The measurement and baseline foundation is now substantially complete:

- the arena has stable fast and full seed sets, reproducible procedural variants, mirrored faction swaps, deterministic sharding, and per-agent decision-time/simulation telemetry;
- generated arena games receive a small horizon allowance so active objective races are less likely to be mislabeled as unresolved;
- objective-aware proposal/final-plan recall and rotation-aware command objectives are on `main`;
- the handwritten evaluator uses bounded relative material, health, resources, energy, objective value, and generic production-capacity value;
- a prior 64-game 2x2-vs-4x4 arena found no aggregate strength benefit from wider 4x4 search despite roughly 3x the simulations;
- a prior 16-game 2x2-vs-6x6 diagnostic showed a modest 6x6 edge, but at roughly 6x the simulations and about 5-6x the decision time, so 6x6 remains diagnostic rather than the default;
- the September 2026 frozen fast-arena 4x4 diagnostic showed that candidate recall was a major confound in the earlier 2x2 evaluator comparison: handwritten won all 12 decisive games, neural won 0, five mirrored pairs were clean handwritten pair wins, and the other three pairs were unresolved rather than faction-tied;
- in particular, `baneling_flank`, `medic_hold`, and `worker_screen` changed from faction-dominated 2x2 outcomes to handwritten wins from both factions at 4x4, while `hydra_crossfire` changed from a Zerg sweep to one handwritten win plus one unresolved mirror;
- this means the current fast-arena fixtures are broadly useful evaluator tests; do not rebalance them merely because a 2x2 search omitted useful hold/reposition/disengage plans;
- 4x4 is materially more expensive: the diagnostic averaged about 5.35 s per handwritten decision and 6.14 s per neural decision, with roughly 10.8 and 12.1 simulations per decision respectively, so it should be used deliberately rather than assumed to be the cheap default;
- PR #52 landed a 42-game `diverse` self-play suite with 16 deterministic training-only procedural variants across the eight strategic families, with training seeds separated from frozen arena evaluation seeds;
- PR #53 landed controlled deterministic near-best policy exploration, expanding the diverse suite to 58 games while exporting exploration supervision only after the replay actually diverges from its greedy reference;
- Value Model Experiment #73 produced 55/58 labeled games, 652 examples, zero conflicting encoded-input groups, and roughly 75.4% held-out nonterminal winner-prediction accuracy versus 71.2% for the handwritten evaluator;
- the same experiment still exposed tactical weakness in neural counterfactual ranking, including the Baneling-sacrifice decision, so the neural evaluator is not yet ready to replace the handwritten champion;
- PR #54 strengthened the counterfactual answer key so opponent weights come from a pre-turn search-policy proxy, unresolved continuation mass is represented as value bounds, adversarial/best-response value is separate, and authored responses remain explicit stress cases;
- PR #56 records the complete bounded candidate x opponent-response leaf matrix for self-play decisions so candidate-level supervision is available without changing live search;
- PR #57 selectively continues high-value rejected candidates with the real simulator, prioritizing neural-vs-handwritten disagreement, close neural scores, and tactically large one-turn swings while leaving unresolved branches unlabeled;
- the curated counterfactual suite is intentionally a small set of stable tactical regression checks rather than an exhaustive strategy answer key;
- the neural evaluator remains evidence rather than a gameplay upgrade, so the handwritten evaluator is still the champion/fallback.

The current learning step is to make the neural value function better at the exact ranking problem search asks it to solve. Keep terminal game outcome as the broad state-value target, then add same-decision sibling ranking supervision from real continuations. Do not add a learned policy/pruning head until value ranking is measurably useful under a fixed candidate set.

## Plan

1. **Improve the neural state representation before making the network larger.**
   - Keep explicit own/enemy command-hex channels so the model can see the alternate victory condition.
   - Add command occupancy/capture-progress state and strategically important status effects such as stun when report cards show those are still missing signals.
   - Add terrain/resource/objective features as those systems become strategically meaningful.
   - Keep the current small residual CNN initially; better inputs and broader training data are higher priority than more layers while the dataset is still small.
   - Use candidate-level diagnostics to distinguish missing representation, missing training coverage, and missing candidate recall; do not assume every tactical miss is a value-model problem.

2. **Build a measured hybrid AI.**
   - Keep bounded search and the handwritten evaluator as a fallback.
   - Put neural leaf/state evaluation behind a feature flag using the same search budget as the handwritten baseline.
   - Compare neural vs handwritten on frozen mirrored arena seeds at identical search width.
   - Use 2x2 for cheap PR smoke/regression where appropriate, but use a 4x4 same-budget diagnostic for evaluator-promotion questions when 2x2 candidate recall is known to hide tactical alternatives.
   - Promote neural evaluation only when it improves full-game strength and tactical regret without exceeding the decision-time budget.

3. **Train the value model on both outcome and sibling ordering.**
   - Keep the existing terminal-outcome value loss: learn who eventually wins from each state.
   - Add pairwise ranking loss over sibling leaves from the same recorded decision, using real simulator continuations rather than handwritten leaf scores as the preference target.
   - Control the comparison by using the same modeled opponent response for both siblings whenever possible, so the label measures the own-plan difference rather than response variance.
   - Primary ordering is `win > draw > loss` with full ranking weight.
   - Among two winning continuations, use faster victory only as lower-confidence supervision.
   - Do **not** create loss-vs-loss preferences based on survival time; the model should not learn that merely delaying defeat is strategically valuable.
   - Report held-out sibling-ranking accuracy alongside winner-prediction accuracy, counterfactual candidate-ranking accuracy/regret, and direct Arena results.
   - Train on terminal game outcomes, not handwritten-evaluator imitation.
   - Once neural evaluation consistently beats the handwritten champion at comparable compute, allow neural-guided self-play to become a larger part of future data generation.

4. **Add a learned policy/prior for candidate pruning after value ranking works.**
   - Move toward an AlphaZero-like policy + value architecture rather than leaving candidate pruning permanently handcrafted.
   - Train a policy/prior from successful self-play/search decisions to score which unit actions and joint-plan components deserve search budget.
   - Use learned priors to rank/prune own plans and likely opponent responses while retaining a tactical-intent diversity floor, objective recall, and a small exploration floor so unusual but important plans are not permanently hidden.
   - For simultaneous turns, prefer factorized per-unit or joint-plan-component priors before attempting a flat probability distribution over the combinatorial joint-plan space.
   - Measure policy recall separately: how often does the eventual best sibling survive candidate pruning?
   - Only replace handcrafted proposal scoring when learned pruning improves strength or candidate recall per unit of compute.

5. **Add shallow multi-turn lookahead only when measurement justifies it.**
   - Search width alone is not monotonic: prior aggregate testing found 4x4 cost substantially more than 2x2 without improving aggregate strength, while 6x6 showed only a modest small-sample gain at much higher cost.
   - The frozen fast-arena diagnostic established a different point: 4x4 can materially improve candidate recall and make evaluator comparisons cleaner even when it is not globally stronger per unit compute.
   - Treat 4x4 as an evaluator/candidate-recall diagnostic, and 6x6/8x8 as wider diagnostic tools rather than automatic gameplay defaults.
   - Prefer additional seeded positions, better candidate priors, and improved state evaluation before brute-force width.
   - Add shallow multi-turn continuation only if the arena shows a meaningful strength gain inside the player's turn-time budget.

6. **Tune for fun after strength is measurable.**
   - Set difficulty with search budget, controlled mistakes, and/or evaluator strength.
   - Set personalities with tactical-intent/policy preferences rather than hidden stat cheats.
   - Validate raw strength and interestingness separately through blind human playtests.

## Arena efficiency policy

Spend compute on **more independent seeded positions before wider search** by default. Keep the ordinary PR arena inexpensive and use wider/full diagnostics for promotion decisions. Record win/loss/draw, unresolved rate, termination reason, non-progress streak, decision time, simulation count, and candidate-intent coverage where practical.

Use mirrored pairs to cancel faction/scenario bias and stable seed sets to make before/after comparisons meaningful. New training seeds must not overlap frozen evaluation seeds.

Do not assume a larger plan-response budget is stronger. Compare strength per unit of compute. The current evidence supports two separate uses:

- **2x2:** cheap baseline/regression signal;
- **4x4:** preferred diagnostic when the question is evaluator quality or candidate recall and 2x2 may suppress tactical-intent diversity.

A faction-dominated result at 2x2 is not enough evidence to declare a fixture bad. Rerun the same frozen pair at 4x4 first. The September 2026 diagnostic showed that this distinction matters: all decisive 4x4 games favored the handwritten evaluator, eliminating the faction-tied pattern seen at 2x2.

## Counterfactual regression policy

Keep the curated counterfactual suite intentionally small and focused on obvious tactical regressions that should remain meaningful across many rule changes. Prefer roughly 4-6 stable cases over a large catalog of hand-authored strategic situations.

Do not use the curated suite as the primary definition of good strategy. When rules change, update or remove a case if its old answer is no longer naturally correct. Promote a new case only when self-play, arena games, or playtesting reveals a recurring embarrassing tactical mistake worth guarding against.

Use arena strength, self-play outcomes, held-out sibling ranking, and held-out value-model performance as the primary evolving-game measurements.

## Self-play exploration policy

Exploration is a **training-data tool**, not a source of evaluation noise. Search still generates and ranks plans deterministically. Training may occasionally select a non-best plan only from a small near-best prefix and only within a bounded worst-case score gap. Every exploration choice must be reproducible from recorded state/profile/seed provenance.

Exploration replays export supervised examples only after their trajectory diverges from the identical greedy reference. This prevents a state-only value model from receiving opposite outcome labels for the same pre-divergence input.

Do not use unconstrained random legal actions. The purpose is to expose plausible alternate strategies and outcomes, not to teach the value model from intentionally nonsensical play.

## Sibling-ranking supervision policy

Ranking supervision must be grounded in real simulator continuations. Pair leaves by the decision that generated them and, where possible, hold the modeled opponent response fixed across the pair.

Use terminal outcome ordering as the primary signal. Faster wins may break ties between two wins at lower weight. Do not prefer slower losses over faster losses. Unresolved continuations remain unlabeled rather than receiving guessed preferences.

Split ranking pairs by the same held-out scenario-family grouping used for the ordinary value examples so sibling states from a held-out family cannot leak into training.

## Neural promotion gate

The first neural gameplay milestone is not lower training loss. It is:

**same search budget + neural evaluator vs same search budget + handwritten evaluator on frozen mirrored arena seeds.**

A neural candidate should show improvement across full-game strength, counterfactual decision quality, and held-out sibling ordering before replacing the handwritten baseline.

Because 2x2 can hide evaluator-sensitive plans, a promotion candidate should also be checked at 4x4 on the frozen fast arena or another candidate-recall-controlled same-budget set before interpreting faction-tied 2x2 outcomes as evaluator equivalence.

A later learned-policy milestone adds a second gate: candidate recall and strength per unit of search compute must improve before neural priors replace the handcrafted proposal/pruning baseline.

## Ship gate

Promote a new AI only when it beats the current champion on held-out seeded full games, reduces serious tactical regret, stays inside the turn-time budget, respects fog of war and scenario objectives, avoids non-progress/pathological loops, and players prefer playing against it.

**Immediate next step: land the response-controlled sibling-ranking pipeline, run the manual Value Model Experiment, let the follow-up retrain with terminal-outcome plus pairwise-ranking loss, then compare the ranked checkpoint against the value-only checkpoint on held-out sibling accuracy, counterfactual regret, and same-budget neural-vs-handwritten Arena results.**
