# AI Roadmap

## Goal

A fair AI that coordinates simultaneous actions, avoids obvious blunders, discovers useful strategies, offers distinct play styles, and responds within the player's turn-time budget.

## Current position

The pure simulator, legal actions, bounded joint planning, opponent-response search, tactical intents, whole-game rollout, command-hex victory, counterfactual decision benchmark, seeded AI-vs-AI arena, richer self-play export, and first neural value model all exist.

The measurement foundation is now substantially complete:

- the arena has stable fast and full seed sets, reproducible procedural variants, mirrored faction swaps, deterministic sharding, and per-agent decision-time/simulation telemetry;
- generated arena games receive a small horizon allowance so active objective races are less likely to be mislabeled as unresolved;
- objective-aware proposal/final-plan recall and rotation-aware command objectives are on `main`;
- the handwritten evaluator now uses bounded relative material, health, resources, energy, objective value, and generic production-capacity value;
- a 64-game 2x2-vs-4x4 arena found no strength benefit from wider 4x4 search despite roughly 3x the simulations;
- a 16-game 2x2-vs-6x6 diagnostic showed a modest 6x6 edge, but at roughly 6x the simulations and about 5-6x the decision time, so 6x6 remains a diagnostic profile rather than the default;
- the neural evaluator is still directional evidence rather than a gameplay upgrade, so the handwritten evaluator remains the champion/fallback for now.

PR #52 expands the `diverse` self-play training suite from 26 to 42 games with 16 deterministic training-only procedural variants across the eight strategic families. Training seeds are intentionally separate from the frozen arena evaluation seeds.

## Plan

1. **Finish diverse self-play and keep evaluation data separate.**
   - Land the 42-game diverse self-play suite once its end-to-end value-model experiment is green.
   - Keep training-only procedural seeds disjoint from frozen arena/counterfactual evaluation seeds.
   - Continue tracking labeled-game rate, failures, unresolved games, scenario-family coverage, and example count so additional diversity is useful rather than merely larger.

2. **Add policy/exploration diversity to self-play.**
   - Replay comparable starting positions with multiple deterministic exploration seeds.
   - Sometimes sample among near-best legal plans instead of always taking the same deterministic top plan.
   - Preserve reproducibility and record the exploration policy/seed in training provenance.
   - Use these repeated positions to learn policy-conditional outcomes rather than treating one deterministic trajectory as ground truth.

3. **Improve the neural state representation before making the network larger.**
   - Add explicit own/enemy command-hex channels so the model can see the alternate victory condition.
   - Add command occupancy/capture-progress state and strategically important status effects such as stun.
   - Add terrain/resource/objective features as those systems become strategically meaningful.
   - Keep the current small residual CNN initially; better inputs and broader training data are higher priority than more layers while the dataset is still small.

4. **Build a measured hybrid AI.**
   - Keep bounded search and the handwritten evaluator as a fallback.
   - Put neural leaf/state evaluation behind a feature flag using the same search budget as the handwritten baseline.
   - Run neural-vs-handwritten matches on the frozen mirrored arena seeds so evaluator quality is isolated from search width.
   - Promote neural evaluation only when it improves full-game strength and tactical regret without exceeding the decision-time budget.

5. **Iterate the neural value model with real report cards.**
   - Train on terminal game outcomes, not handwritten-evaluator imitation.
   - Use held-out scenario families, counterfactual ranking/regret, and neural-vs-champion arena results together.
   - Prefer better data, representation, augmentation, targets, and training stability before increasing model size.
   - Once neural evaluation consistently beats the handwritten champion at comparable compute, allow neural-guided self-play to become a larger part of future data generation.

6. **Add shallow multi-turn lookahead only when measurement justifies it.**
   - Search width alone is not monotonic: 4x4 cost substantially more than 2x2 without improving strength, while 6x6 showed only a modest small-sample gain at much higher cost.
   - Treat 6x6/8x8 breadth as diagnostic tools, not default gameplay budgets.
   - Prefer additional seeded positions and improved state evaluation before brute-force width.
   - Add shallow multi-turn continuation only if the arena shows a meaningful strength gain inside the player's turn-time budget.

7. **Tune for fun after strength is measurable.**
   - Set difficulty with search budget, controlled mistakes, and/or evaluator strength.
   - Set personalities with tactical-intent/policy preferences rather than hidden stat cheats.
   - Validate raw strength and interestingness separately through blind human playtests.

## Arena efficiency policy

Spend compute on **more independent seeded positions before wider search**. Keep the fast arena inexpensive and use the full arena for promotion decisions. Record win/loss/draw, unresolved rate, termination reason, non-progress streak, decision time, and simulation count for every agent configuration.

Use mirrored pairs to cancel faction/scenario bias and stable seed sets to make before/after comparisons meaningful. New training seeds must not overlap frozen evaluation seeds.

Do not assume a larger plan-response budget is stronger. Compare strength per unit of compute. The current evidence makes 2x2 the practical default, 4x4 an alternate profile, 6x6 a diagnostic ceiling, and 8x8 unnecessary unless a specific experiment requires it.

## Neural promotion gate

The first neural gameplay milestone is not lower training loss. It is:

**same search budget + neural evaluator vs same search budget + handwritten evaluator on frozen mirrored arena seeds.**

A neural candidate should show improvement across both full-game strength and counterfactual decision quality before replacing the handwritten baseline.

## Ship gate

Promote a new AI only when it beats the current champion on held-out seeded full games, reduces serious tactical regret, stays inside the turn-time budget, respects fog of war and scenario objectives, avoids non-progress/pathological loops, and players prefer playing against it.

**Immediate next step: finish and land PR #52, then add deterministic policy/exploration diversity before expanding the neural state representation with explicit objective/capture information.**
