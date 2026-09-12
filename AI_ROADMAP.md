# AI Roadmap

## Goal

The immediate user objective is Phase 1 in `docs/AI_PHASE1.md`: at least 75% neural
wins among resolved games and at least 50% resolution independently on twenty
familiar-map and twenty unfamiliar-map games, with equal decision-time budgets,
a thirty-second turn limit, and a four-hour elapsed training pipeline. Learned
proposal and evaluation heads are both allowed. The new `Phase One Candidate`
workflow adds fresh adversarial sibling supervision and explicit promotion reports.
Keep the handwritten champion until this contract passes; older same-width or
decisive-only reports are diagnostics rather than Phase 1 success.

A fair AI that coordinates simultaneous actions, avoids obvious blunders, discovers useful strategies, offers distinct play styles, and responds within the player's turn-time budget.

The roadmap should improve two things together:

1. **AI decision quality** — generate strong candidate plans, evaluate them correctly, model opponent responses well, and spend search compute efficiently.
2. **Game-backend support for strategy** — keep simulation deterministic and fast while making it easy to add objectives, information, economy, positioning, and other mechanics that create interesting decisions.

Do not treat a stronger value network as the default answer to every AI weakness. Before changing the model, determine whether the failure came from candidate generation, candidate ranking, opponent-response modeling, state representation, or backend/game-rule limitations.

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
- the Candidate Oracle Recall diagnostic now compares the production candidate set against an intentionally wider offline teacher, evaluates the union under one shared counterfactual answer key, reports value-based recall/gap/severe misses/conditional selection accuracy and compute ratios, and can run on frozen suite states or exported self-play search decisions;
- the curated counterfactual suite is intentionally a small set of stable tactical regression checks rather than an exhaustive strategy answer key;
- the neural evaluator remains evidence rather than a gameplay upgrade, so the handwritten evaluator is still the champion/fallback.

The next phase should answer three separate questions instead of collapsing them into one generic "AI strength" metric:

1. **Candidate oracle recall:** did production search generate a near-best plan at all?
2. **Oracle value gap:** when it missed, how strategically costly was the miss?
3. **Selection accuracy conditional on recall:** when a near-best plan was present, did the evaluator/search ranking actually choose it?

This decomposition should drive the order of future work.

## Revised sequencing

The preferred sequence is:

**candidate-recall oracle -> batched neural evaluation -> candidate-generation/refinement experiments -> stronger sibling-ranking data -> risk-aware response scoring -> selective deeper search -> opponent league -> learned policy prior -> personality/fun tuning.**

Game-backend work should proceed in parallel where it unlocks faster search, richer objectives, deterministic replay, or better strategic mechanics.

## AI improvements

### 1. Candidate Oracle Recall benchmark — implemented

The first Candidate Oracle Recall diagnostic is now implemented. It deliberately leaves gameplay search unchanged: production search and a wider offline teacher only source candidate plans, then their deduplicated union is evaluated under the same coverage-aware counterfactual answer key. Recall is therefore based on shared oracle-controlled value rather than exact action-array equality.

The benchmark supports both selected frozen counterfactual states and real exported self-play `search_decisions.jsonl` states. It emits `decisions.jsonl`, `severe_misses.jsonl`, and a manifest with aggregate and per-family summaries. Defaults use a `0.10` near-best value tolerance and a `0.50` severe-miss threshold; both are configurable. It also reports production-vs-oracle simulations and wall-clock time so future generators can be compared per unit of compute.

The implementation covers the roadmap contract:

- run an intentionally expensive offline search with larger own/opponent candidate budgets;
- preserve production and wider-search candidates in one evaluation pool so a production-only plan can still be the oracle winner;
- count recall when any production candidate is within the configured value tolerance of the best union candidate;
- report near-oracle candidate recall, best-production-vs-best-oracle value gap, severe-miss rate, and selection accuracy conditional on recall;
- aggregate by scenario/behavior family when source metadata provides a family;
- record production/oracle search diagnostics and exact-oracle-winner recovery probes under progressively wider final-plan, per-unit-action, and opponent-conditioning budgets to help localize candidate loss;
- retain severe misses as a dedicated mining artifact for candidate-generator and training-data follow-up;
- keep the oracle offline-only; no gameplay policy or default search budget changes are made by this benchmark.

The loss-stage recovery probes are diagnostic rather than a causal proof: exact-plan recovery is useful for locating likely pruning pressure, while the headline recall metric remains value-based so strategically equivalent plans are not mislabeled as misses.

The diagnostic question remains:

> Did the AI fail because it could not generate the idea, or because it generated the idea and valued it incorrectly?

Use the answer to decide whether the next experiment belongs in candidate generation/refinement or evaluator/ranking work.

### 2. Batch neural leaf evaluation before making the model larger

The current neural runtime is persistent, but leaf states are still evaluated one request/forward pass at a time. Remove that avoidable overhead before scaling search or model size.

- Add an `evaluate_many` path that accepts multiple simulated leaf states and returns aligned values in one request.
- Stack encoded states and perform one/few PyTorch forward passes per batch rather than one forward pass per leaf.
- Start with a low-risk integration such as batching all opponent-response leaves for one own candidate, preserving most current minimax/pruning behavior.
- Measure separately:
  - Godot simulation time;
  - state serialization/IPC time;
  - Python state encoding time;
  - neural inference time;
  - total search time.
- Add deterministic state hashes and cache duplicate neural evaluations where identical states recur.
- Only consider a larger network after input quality, candidate coverage, batching, and training supervision are no longer the dominant bottlenecks.

The goal is not merely faster inference. The goal is to convert saved evaluator overhead into more useful candidate diversity, opponent responses, or selective continuation depth.

### 3. Improve candidate generation with portfolio seeds and local refinement

Do not rely only on widening the current per-unit/joint-plan beam. Wider search has already shown rapidly increasing cost and inconsistent strength gains.

- Keep the existing bounded beam as the baseline/fallback.
- Add a feature-flagged **portfolio/refinement generator** that starts from several strategically different complete-team plans, then locally improves them.
- Portfolio seeds should remain generic and explainable, for example:
  - focus/commit;
  - hold/defend;
  - reposition/flank;
  - disengage/preserve;
  - objective pressure;
  - screening/interception;
  - production/resource tempo when applicable.
- Evaluate complete plans with the real simulator/search rather than allowing the template heuristic to determine the final answer.
- Refine a seed by changing one unit action at a time, retaining improvements and repeating for a bounded number of iterations.
- Preserve multiple diverse seeds because local refinement can get trapped in local optima.
- Compare beam, wider beam, portfolio/refinement, and hybrid generators using:
  - candidate oracle recall;
  - oracle value gap;
  - simulations;
  - wall-clock decision time;
  - same-budget arena strength.
- Prefer smarter recall per unit of compute over brute-force width.

### 4. Train the value model on stronger sibling supervision

Keep terminal game outcome as the broad value target, but make sibling-ranking data increasingly reflect difficult tactical distinctions rather than only the current production candidate set.

- Keep pairwise ranking over sibling leaves from the same decision.
- Hold the modeled opponent response fixed across compared own-plan siblings whenever possible so the label isolates the effect of the own plan.
- Continue to ground ranking labels in real simulator continuations rather than handwritten evaluator imitation.
- Primary ordering remains `win > draw > loss` with full confidence where resolved.
- Faster wins may break ties between two wins at lower weight.
- Do **not** prefer slower losses over faster losses merely because they survived longer.
- Leave genuinely unresolved comparisons unlabeled rather than fabricating certainty.

Improve the sibling pool in four ways:

1. **Oracle/refined siblings** — include strong plans discovered by the expensive candidate oracle or portfolio/refinement search, not only production-beam siblings.
2. **Hard siblings** — oversample neural-vs-handwritten disagreements, close neural scores, meaningful continuation-value gaps, and tactically different but superficially similar states.
3. **Local perturbations** — around a strong plan, change one unit action at a time to teach the evaluator why a particular coordinated execution is better.
4. **Mistake mining** — after arena/self-play failures, rerun important decision states with the oracle and turn discovered better alternatives into new training comparisons.

Track sibling-ranking accuracy by decision family, not only overall accuracy. A model that is 90% accurate on routine commit-vs-commit pairs but poor on sacrifice, objective/material, crossfire, or production/tempo tradeoffs is not yet strategically reliable.

Use oracle-generated training targets as a teacher for the future learned policy as well, so the policy does not merely imitate the blind spots of the current production search.

### 5. Improve neural state representation before increasing network size

- Keep explicit own/enemy command-hex channels so the model can see the alternate victory condition.
- Add command occupancy/capture-progress state and strategically important status effects such as stun when report cards show those are still missing signals.
- Add terrain/resource/objective features as those systems become strategically meaningful.
- Add observation/fog features only after the backend exposes a canonical player-observation state.
- Keep the current small residual CNN initially; better inputs, broader training data, and better candidate coverage are higher priority than more layers while the dataset remains modest.
- Use candidate/oracle diagnostics to distinguish missing representation, missing training coverage, and missing candidate recall.

### 6. Improve opponent-response scoring after candidate coverage is measured

The current worst-response-first search is a strong safety baseline for simultaneous turns, but pure maximin can become unnecessarily conservative when one modeled response is extremely unlikely.

- Preserve hard forced-loss detection and adversarial stress cases.
- Experiment with a risk-aware score that combines likely-response expected value with explicit downside protection.
- Keep adversarial/best-response value separately visible in diagnostics.
- For hard-AI experiments, use the already available candidate x opponent-response payoff matrix to evaluate a restricted two-player zero-sum matrix-game solve when the leaf utility assumptions are appropriate.
- Do not replace current maximin until same-budget arena tests show that the alternative is stronger without creating reckless tactical failures.

### 7. Add selective multi-turn search, not uniform deeper search

Do not make every position two or more turns deep.

- Continue to treat one simultaneous turn plus strong leaf evaluation as the default.
- Trigger deeper continuation only on unstable/important decisions, such as:
  - near-terminal positions;
  - objective capture races;
  - high evaluator disagreement;
  - close top candidate scores;
  - sacrifice/tempo decisions whose value is deliberately delayed;
  - large oracle/production uncertainty.
- Compare selective continuation against equivalent compute spent on broader candidate generation.
- Promote deeper search only when it improves strength/regret inside the player's turn-time budget.

### 8. Build an opponent league before relying on learned-policy self-play

Once candidate generation and value ranking are stronger, diversify the opponents that training/evaluation must withstand.

- Preserve historical champion checkpoints/policies.
- Add simple strategic archetypes where useful, such as aggressive objective pressure, preservation/retreat bias, economy/production bias, or tactical commit bias.
- Evaluate exploit gaps against the league, not only against the newest self-play policy.
- Use the league to reduce overfitting to one current opponent style and to generate more varied hard decision states.

### 9. Add a learned policy/prior only after search-generated targets are strong

Do not train the future policy head primarily to imitate the current bounded production search.

- Distill priors from successful oracle/refined search decisions and strong self-play/search trajectories.
- Prefer factorized per-unit or joint-plan-component priors before attempting a flat distribution over the combinatorial joint-plan space.
- Use learned priors to allocate candidate/search budget, not to remove the simulator/search safety net immediately.
- Retain tactical-intent diversity, objective recall, and a small exploration floor so unusual but important plans remain discoverable.
- Measure policy quality by **candidate oracle recall per unit of compute** and same-budget full-game strength.
- Only replace handcrafted proposal scoring when the learned prior produces stronger or more complete candidate sets within the gameplay budget.

### 10. Tune difficulty and personality after strength is measurable

- Set difficulty primarily with search budget, candidate/refinement budget, continuation budget, risk tolerance, and evaluator strength.
- Set personalities through tactical/strategic priors rather than hidden stat cheats.
- Allow easier AI to make controlled, legible mistakes rather than random nonsense.
- Validate raw strength and player preference separately through blind playtests.

## Game backend improvements that unlock better AI and a better game

The AI roadmap depends on the game backend continuing to make strategic states cheap, deterministic, expressive, and understandable. Keep one canonical simulation authority rather than creating an AI-only rules engine.

### 1. Add a canonical state/index/hash layer before any wholesale state rewrite

- Keep the dictionary-based state format for now unless profiling proves it is the dominant bottleneck.
- Add thin canonical indexes such as `unit_by_id`, occupancy-by-cell, and group lookup so repeated full scans are avoidable.
- Add a deterministic canonical state hash usable for neural-evaluation caching, replay verification, transposition-style reuse, and regression debugging.
- Separate static scenario/unit-definition data from frequently copied dynamic state where practical.
- Profile before introducing more complex delta/scratch-state simulation.

### 2. Keep `TurnExecutionCore` canonical, but modularize its internals

Do not fork simulation logic between gameplay and AI. Preserve the current architecture in which pure simulation delegates to the same turn-resolution rules.

As complexity grows, split responsibilities behind the canonical facade into pure rule/resolver modules, for example:

- movement/collision;
- combat/targeting;
- effects/status;
- economy/resources/production;
- objectives/victory;
- shared rule queries.

This should improve testability and iteration speed without creating two sources of truth.

### 3. Generalize objectives and scenarios

The command hex is a useful anti-stalling pressure mechanism, but it should not become the only strategic geometry the AI learns.

- Introduce data-driven `ScenarioDefinition` / `ObjectiveDefinition` concepts.
- Support command-hex capture as a default/fallback objective while allowing scenario-specific primary objectives.
- Make it easy to express multiple control points, escort/defend, resource pressure, production races, survival/escape, and similar strategic families without bespoke engine branches.
- Use procedural variants to vary geometry and prevent overfitting to one objective layout.

### 4. Add a canonical player-observation API before fog/scouting mechanics

Before adding imperfect information, define the exact state visible to each player.

- Gameplay AI should eventually plan from `ObservationState(player)` rather than unrestricted world state when fog/stealth exists.
- Keep hidden full state available to the simulator/server, not to the planning policy.
- Use the same observation contract for human-client information and AI information so fair-play guarantees are testable.

### 5. Prefer generic traits/effect operators over unit-specific rule branches

As new mechanics are added, compose them from reusable concepts such as damage, stun, movement modification, interception, spawning, resource transfer, capture progress, vision, and timed effects.

This keeps the backend extensible and gives the AI consistent semantic features rather than a growing collection of special-case unit logic.

### 6. Add deterministic ReplayV1 and reason-coded events

- Record enough data to reproduce a match deterministically from initial state + submitted simultaneous actions + seeds/configuration.
- Include state hashes at useful boundaries so replay divergence can be located precisely.
- Emit reason-coded resolution events that can explain movement conflicts, missed attacks, blocks/intercepts, objective progress, effects, spawns, and victory triggers.
- Use the same event stream for debugging, visualization, and eventually player-facing combat explanations.

Readability matters for fun: simultaneous outcomes should feel surprising because the opponent outguessed the player, not because resolution rules are opaque.

### 7. Add invariants and metamorphic tests for simultaneous resolution

In addition to authored examples, test properties that should hold across many generated states, such as:

- deterministic replay of the same state/actions/seed;
- faction/name permutations do not change rule semantics;
- mirrored/rotated equivalent states resolve equivalently when the rules are symmetric;
- unit/resource conservation rules hold where applicable;
- no unit occupies an impossible cell after resolution;
- objective capture is checked at the defined full-turn boundary;
- AI simulation and gameplay/server execution produce identical next states for the same inputs.

### 8. Prioritize mechanics that create simultaneous strategic prediction

A smarter AI cannot create depth if the game offers only one dominant decision axis. Favor mechanics that create meaningful tradeoffs between prediction, commitment, information, positioning, objectives, and tempo.

Strong candidates include:

- interception/overwatch or other ways to punish predicted movement;
- telegraphed attacks with positional counterplay;
- cover/terrain that changes movement-vs-damage tradeoffs;
- scouting/fog/stealth once the observation API exists;
- multiple objectives that force splitting and screening;
- production/reinforcement systems that create immediate-pressure-vs-growth decisions;
- support/screening mechanics that make coordinated multi-unit plans valuable.

Do not add many abilities merely for variety. Add mechanics that create new kinds of decisions the search and value model can learn to distinguish.

## Arena efficiency policy

Spend compute on **more independent seeded positions before wider search** by default. Keep the ordinary PR arena inexpensive and use wider/full diagnostics for promotion decisions. Record win/loss/draw, unresolved rate, termination reason, non-progress streak, decision time, simulation count, candidate-intent coverage, candidate-oracle recall, oracle value gap, and conditional selection accuracy where practical.

Use mirrored pairs to cancel faction/scenario bias and stable seed sets to make before/after comparisons meaningful. New training seeds must not overlap frozen evaluation seeds.

Do not assume a larger plan-response budget is stronger. Compare strength and oracle recall per unit of compute. The current evidence supports separate uses:

- **2x2:** cheap baseline/regression signal;
- **4x4:** preferred diagnostic when evaluator quality or candidate recall is being tested and 2x2 may suppress tactical-intent diversity;
- **6x6/8x8 or offline oracle budgets:** diagnostic/teacher tools, not automatic gameplay defaults.

A faction-dominated result at 2x2 is not enough evidence to declare a fixture bad. Rerun the same frozen pair at 4x4 first. The September 2026 diagnostic showed that this distinction matters: all decisive 4x4 games favored the handwritten evaluator, eliminating the faction-tied pattern seen at 2x2.

## Counterfactual regression policy

Keep the curated counterfactual suite intentionally small and focused on obvious tactical regressions that should remain meaningful across many rule changes. Prefer roughly 4-6 stable cases over a large catalog of hand-authored strategic situations.

Do not use the curated suite as the primary definition of good strategy. When rules change, update or remove a case if its old answer is no longer naturally correct. Promote a new case only when self-play, arena games, oracle analysis, or playtesting reveals a recurring embarrassing tactical mistake worth guarding against.

Use arena strength, candidate-oracle recall/value gap, self-play outcomes, held-out sibling ranking, and held-out value-model performance as the primary evolving-game measurements.

## Self-play exploration policy

Exploration is a **training-data tool**, not a source of evaluation noise. Search still generates and ranks plans deterministically. Training may occasionally select a non-best plan only from a small near-best prefix and only within a bounded worst-case score gap. Every exploration choice must be reproducible from recorded state/profile/seed provenance.

Exploration replays export supervised examples only after their trajectory diverges from the identical greedy reference. This prevents a state-only value model from receiving opposite outcome labels for the same pre-divergence input.

Do not use unconstrained random legal actions. The purpose is to expose plausible alternate strategies and outcomes, not to teach the value model from intentionally nonsensical play.

## Sibling-ranking supervision policy

Ranking supervision must be grounded in real simulator continuations. Pair leaves by the decision that generated them and, where possible, hold the modeled opponent response fixed across the pair.

Use terminal outcome ordering as the primary signal. Faster wins may break ties between two wins at lower weight. Do not prefer slower losses over faster losses. Unresolved continuations remain unlabeled rather than receiving guessed preferences.

As the candidate oracle matures, increasingly source sibling pairs from oracle/refined candidates, local one-unit perturbations around strong plans, evaluator disagreements, and actual arena/self-play mistakes. Do not let the sibling dataset become a closed loop that only teaches the network to rank plans the current bounded generator already knows how to propose.

Split ranking pairs by the same held-out scenario-family grouping used for ordinary value examples so sibling states from a held-out family cannot leak into training.

Report both overall sibling-ranking accuracy and family-specific accuracy for strategically difficult tradeoffs.

## Promotion gates

### Candidate-generator promotion gate

A new candidate generator should improve near-oracle recall and/or reduce severe oracle value gaps without unacceptable decision-time cost. It must also preserve deterministic behavior, intent/objective coverage, and same-budget full-game strength.

### Neural evaluator promotion gate

The first neural gameplay milestone is not lower training loss. It is:

**same search budget + neural evaluator vs same search budget + handwritten evaluator on frozen mirrored arena seeds.**

A neural candidate should show improvement across full-game strength, counterfactual decision quality, and held-out sibling ordering before replacing the handwritten baseline.

Interpret evaluator failures only on decisions where candidate recall is adequate. If both evaluators were denied a near-oracle plan, classify the primary failure as candidate generation rather than evaluator ranking.

Because 2x2 can hide evaluator-sensitive plans, a promotion candidate should also be checked at 4x4 on the frozen fast arena or another candidate-recall-controlled same-budget set before interpreting faction-tied 2x2 outcomes as evaluator equivalence.

### Learned-policy promotion gate

A learned prior must improve candidate oracle recall and/or full-game strength **per unit of search compute** before replacing handcrafted proposal/pruning as the default.

## Revised milestones

### Milestone A — Search quality and speed foundation

**AI**
- Candidate Oracle Recall benchmark and severe-miss mining. **Implemented; use the benchmark to identify candidate-generation misses and mine better siblings.**
- Batched neural leaf evaluation with timing breakdown.
- Portfolio/refinement candidate generator behind a feature flag.

**Backend**
- Profile simulator hotspots.
- Add canonical state indexes and deterministic state hash.
- Optimize dynamic-state copying only where profiling justifies it.
- Replace or update stale architecture/migration documentation with the current normative simulation contract.

**Gate**
- Better candidate recall/value gap at comparable compute.
- No deterministic/regression failures.
- Neural evaluation overhead materially reduced.

### Milestone B — Better decision policy

**AI**
- Train sibling ranking from production + oracle/refined + mistake-mined siblings.
- Add family-level sibling diagnostics.
- Experiment with risk-aware opponent-response scoring.
- Experiment with restricted matrix-game solving for hard AI where appropriate.

**Backend**
- Modularize `TurnExecutionCore` internals without creating a second rules engine.
- Add ReplayV1 + deterministic replay checks.
- Add generic objective/scenario definitions.

**Gate**
- Lower serious tactical regret.
- Better conditional selection accuracy when a near-oracle candidate is available.
- No increase in passive/pathological-loop behavior.
- Same-budget arena improvement against the current champion.

### Milestone C — Strategic depth

**AI**
- Selective multi-turn continuation triggers.
- Historical champion/archetype opponent league.
- Train value model across richer scenario families.

**Backend/game**
- Data-driven scenario/objective catalog.
- Canonical player-observation API.
- Add a small number of strategically distinct mechanics, prioritizing prediction, information, multi-objective pressure, and tempo-vs-production decisions.

**Gate**
- No single strategy dominates procedural scenario variants.
- Exploit gaps against historical/archetype opponents shrink.
- Blind playtests report multiple viable plans and readable AI behavior.

### Milestone D — Learned policy and personalities

**AI**
- Distill policy priors from stronger search/oracle targets.
- Factorized per-unit prior plus coordination/joint-plan component signal.
- Difficulty and personality through budgets, risk, and strategic priors.

**Backend/game**
- Expand generic traits/effect operators.
- Increase scenario/asymmetry catalog only after the objective/observation abstractions are stable.

**Ship gate**
- AI beats the previous champion at equal compute.
- Candidate recall and tactical regret improve.
- Turn-time budget is met.
- Objective/fog/loop cases pass.
- Human preference improves in blind playtests.

## Ship gate

Promote a new AI only when it beats the current champion on held-out seeded full games, reduces serious tactical regret, stays inside the turn-time budget, respects fog of war and scenario objectives, avoids non-progress/pathological loops, and players prefer playing against it.

Do not optimize solely for win rate. A shippable opponent should make strong decisions for understandable reasons, expose the player to multiple viable strategies, and remain fair under the same information and rules available to the player.

**Immediate next step: run the Candidate Oracle Recall diagnostic across the frozen benchmark and sampled self-play decisions, inspect the severe-miss artifact, and use those results to choose between candidate-generation/refinement work and evaluator/ranking work. In parallel, batch neural leaf evaluation so evaluator overhead is not unnecessarily consuming search budget. Then feed oracle/refined candidates and mined mistakes into the response-controlled sibling-ranking dataset.**
