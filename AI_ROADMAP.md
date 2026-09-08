# AI Roadmap

## Goal

Build a fair AI that coordinates simultaneous actions, avoids obvious blunders, discovers useful strategies, offers distinct play styles, and responds within the player's turn-time budget.

The roadmap improves two things together:

1. **AI decision quality** — generate strong candidate plans, rank them correctly, model opponent responses well, and spend search compute efficiently.
2. **Game-backend support for strategy** — keep simulation deterministic and fast while making objectives, economy, positioning, replay/debugging, and future information mechanics easy to extend.

Do not assume a larger neural network is the answer to every AI weakness. First classify the failure as candidate generation, ranking/evaluation, opponent-response modeling, state representation, continuation/search cost, or game-rule/backend limitations.

## Current position — September 8, 2026

The main architecture foundation is in place:

- one canonical pure-state simulator delegates to the same turn-resolution rules used by gameplay;
- legal actions, bounded joint planning, opponent-response search, tactical intents, whole-game rollout, and command-hex victory exist;
- seeded mirrored AI-vs-AI Arena, self-play export, controlled policy exploration, counterfactual answer keys, candidate-level leaf matrices, and selective rejected-candidate continuation exist;
- the first neural value model exists, but the handwritten evaluator remains the gameplay champion/fallback;
- the curated counterfactual suite remains a small tactical regression suite rather than the definition of general strategy.

### Recently completed foundations

- **Candidate Oracle Recall benchmark — merged.** Production candidates are compared with a wider offline teacher under one shared counterfactual answer key, with recall, oracle value gap, severe misses, conditional selection accuracy, compute diagnostics, and loss-stage probes.
- **Broad Candidate Oracle baseline — merged via PR #70.** The run completed partially because expensive continuation states still hit workflow time limits, but it produced enough paired evidence to guide the next work.
- **Batched neural leaf evaluation — merged via PR #72.** Neural opponent-response leaves can be deduplicated/cached and evaluated in batches through the persistent Python/PyTorch runtime while the handwritten path remains unchanged.
- **Canonical state hash + ReplayV1 foundation — merged via PR #76.** ReplayV1 records initial state, submitted simultaneous actions, before/after deterministic hashes, configuration/result metadata, supports deterministic replay verification, and reports the first divergent turn. Initial reason-coded resolution events are included.

### Current evidence

The broad Candidate Oracle baseline requested 40 real self-play decisions at both 2x2 and 4x4. Expensive counterfactual continuation prevented every job from finishing, so treat completion rate as part of the result rather than ignoring hard states.

Successful artifacts:

- **2x2:** 28/40 completed.
- **4x4:** 27/40 completed.
- **Total:** 55/80 completed.

On completed jobs:

- 2x2 candidate recall: **78.6%**;
- 4x4 candidate recall: **88.9%**;
- generation misses: **6 -> 3**;
- severe misses: **3 -> 0**;
- mean oracle-value gap: **0.120 -> 0.041**;
- ranking failures: **3 -> 5**;
- conditional ranking accuracy: **86.4% -> 79.2%**.

The cleaner paired comparison uses the 26 decisions where both 2x2 and 4x4 completed:

- recall improves **76.9% -> 88.5%**;
- generation misses fall **6 -> 3**;
- severe misses fall **3 -> 0**;
- mean oracle gap falls **0.127 -> 0.042**.

4x4 recovered five 2x2 generation misses and regressed on two states. This is enough evidence to conclude that wider candidate coverage can materially improve plan generation, but simply widening the current beam is too expensive to be the final answer.

The same experiment exposed the next quality bottleneck: **ranking becomes more important once better candidates are available.** Candidate generation improved at 4x4, while conditional ranking accuracy fell.

The remaining engineering bottleneck is **counterfactual continuation cost**. Several Hydra crossfire, Scout kite, Worker screen, Attrition, and Fester siege states still approach or exceed the workflow's 40-minute shell timeout. Do not rerun the full 80-job baseline by default; after continuation-cost improvements, rerun only missing cells and targeted residual generation misses.

Other useful evidence remains:

- the September 2026 frozen fast-arena 4x4 diagnostic showed candidate recall was a major confound in earlier 2x2 evaluator comparisons; handwritten won all 12 decisive games and neural won 0;
- 4x4 is materially more expensive than 2x2 and remains a diagnostic/search-quality budget rather than an automatic gameplay default;
- Value Model Experiment #73 produced roughly **75.4% held-out nonterminal winner-prediction accuracy** versus roughly **71.2%** for the handwritten evaluator, but counterfactual tactical ranking still exposed neural weaknesses;
- the neural evaluator therefore remains experimental evidence, not the gameplay champion.

## Current sequencing

Completed foundation:

**candidate-recall oracle -> batched neural evaluation -> canonical hash / ReplayV1**

Preferred next sequence:

**candidate-generation/refinement experiments -> stronger sibling-ranking data -> continuation-cost reduction -> risk-aware response scoring -> selective deeper search -> opponent league -> learned policy prior -> personality/fun tuning.**

Backend work should continue in parallel where it improves simulation speed, richer objectives, replay/debugging, or strategic mechanics.

## AI improvements

### 1. Candidate Oracle Recall benchmark — implemented and baselined

The benchmark is now a standing diagnostic/teacher rather than the next implementation task.

Use it to answer three separate questions:

1. **Candidate oracle recall:** did production search generate a near-best plan at all?
2. **Oracle value gap:** when it missed, how strategically costly was the miss?
3. **Selection accuracy conditional on recall:** when a near-best plan was present, did the evaluator/search ranking actually choose it?

Keep the oracle offline-only. Use severe misses and residual generation misses for candidate-generator experiments, mistake mining, and future sibling supervision.

Do not spend compute rerunning the entire broad baseline unless a major search architecture change makes a new baseline necessary. Prefer targeted reruns of previously missing cells and residual misses after the continuation path is cheaper.

### 2. Batched neural leaf evaluation — implemented

PR #72 added:

- batched neural requests and one/few PyTorch forwards for multiple leaf states;
- deterministic state deduplication/cache support;
- batching of opponent-response leaves per own plan when the neural evaluator is enabled;
- timing and batch diagnostics;
- fail-closed neural behavior;
- correct accounting for all simulations already executed by a batch.

The handwritten evaluator path remains unchanged. Batching reduces inference/IPC overhead; it does **not** reduce game-simulation or long counterfactual-continuation cost by itself.

Future performance work should measure simulation, serialization/IPC, encoding, inference, and continuation time separately before making the network larger.

### 3. Improve candidate generation with portfolio seeds and local refinement — next primary AI experiment

The oracle baseline supports investing here, but not through brute-force width alone.

- Keep the existing bounded beam as baseline/fallback.
- Add a feature-flagged **portfolio/refinement generator** that begins from strategically distinct complete-team plans and locally improves them.
- Generic portfolio seeds should include where applicable:
  - focus/commit;
  - hold/defend;
  - reposition/flank;
  - disengage/preserve;
  - objective pressure;
  - screening/interception;
  - production/resource tempo.
- Evaluate complete plans through the real simulator/search; templates only propose ideas.
- Refine by changing one unit action at a time for a bounded number of iterations.
- Preserve several strategically diverse local optima instead of collapsing immediately to one seed.
- Compare beam, wider beam, portfolio/refinement, and hybrid approaches using:
  - candidate oracle recall;
  - oracle value gap;
  - severe misses;
  - simulations;
  - wall-clock time;
  - same-budget Arena strength.

**Promotion target:** beat 4x4's candidate-quality gains at lower or comparable compute rather than simply making the beam wider.

### 4. Strengthen sibling-ranking supervision — next quality task after/alongside refinement

The broad baseline shows ranking is increasingly important once good candidates are present.

Keep terminal game outcome as the broad value target, but make pairwise sibling data concentrate on decisions that distinguish good strategic ranking.

- Hold the modeled opponent response fixed across own-plan siblings when possible.
- Ground labels in real simulator continuations rather than handwritten evaluator imitation.
- Primary ordering remains `win > draw > loss`.
- Faster wins may break ties at lower weight.
- Do not reward slower losses merely for surviving longer.
- Leave unresolved comparisons unlabeled.

Expand the sibling pool with:

1. **Oracle/refined siblings** from strong offline/refinement candidates.
2. **Hard siblings** from neural-vs-handwritten disagreements, close scores, and meaningful oracle-value gaps.
3. **Local perturbations** around strong plans by changing one unit action at a time.
4. **Mistake mining** from Arena/self-play/oracle failures.

Track overall and family-specific sibling-ranking accuracy. Candidate recall and ranking accuracy should be reported separately so one does not hide the other.

### 5. Reduce continuation cost before expanding offline diagnostics

The broad baseline showed the expensive part is often deep counterfactual continuation, not the initial candidate search.

Investigate in this order:

- canonical-state caching/transposition reuse across repeated continuation states;
- deduplication of equivalent candidate/response continuation branches;
- profiling of simulator state-copy and repeated rule-query hotspots;
- earlier safe termination when winner/value bounds are already decisive;
- adaptive continuation budgets based on uncertainty/importance;
- parallelism across independent continuations where deterministic reproducibility is preserved.

The goal is to make the answer key and teacher cheap enough to finish targeted hard states without weakening its meaning.

### 6. Improve neural state representation before increasing network size

- Keep explicit own/enemy command-hex channels.
- Add command occupancy/capture progress and strategically important status effects where report cards show missing information.
- Add terrain/resource/objective features as those systems become meaningful.
- Add observation/fog features only after the backend exposes a canonical player-observation state.
- Keep the current small residual CNN until input quality, candidate coverage, supervision, and runtime are no longer larger constraints.

### 7. Improve opponent-response scoring after candidate/ranking quality is stronger

The current worst-response-first/maximin approach is a strong safety baseline but can be overly conservative when one modeled response is implausible.

- Preserve forced-loss detection and adversarial stress cases.
- Experiment with risk-aware scores combining likely-response expected value with downside protection.
- Keep adversarial/best-response value visible separately.
- Consider restricted zero-sum matrix-game solves over the existing candidate x response payoff matrix for hard-AI experiments.
- Promote only after same-budget Arena evidence shows stronger play without reckless tactical failures.

### 8. Add selective multi-turn search, not uniform deeper search

Keep one simultaneous turn plus strong leaf evaluation as the normal default.

Use deeper continuation only on unstable/important decisions such as:

- near-terminal positions;
- objective capture races;
- high evaluator disagreement;
- close top candidate scores;
- sacrifice/tempo decisions with deliberately delayed value;
- large oracle/production uncertainty.

Compare selective depth against equivalent compute spent on candidate diversity/refinement.

### 9. Build an opponent league before relying on learned-policy self-play

Once candidate generation and value ranking are stronger:

- preserve historical champions/checkpoints;
- add simple strategic archetypes such as objective pressure, preservation, production/economy, and tactical commit;
- evaluate exploit gaps against the league rather than only the newest self-play policy;
- use league games to produce varied hard decisions for training.

### 10. Add a learned policy/prior only after search-generated targets are strong

Do not teach a policy merely to imitate current production-search blind spots.

- Distill priors from oracle/refined search and strong trajectories.
- Prefer factorized per-unit or joint-plan-component priors before a flat combinatorial joint distribution.
- Use learned priors to allocate search budget first, while retaining simulator/search safety.
- Preserve tactical-intent diversity, objective recall, and a small exploration floor.
- Judge the prior by candidate recall and full-game strength **per unit of compute**.

### 11. Tune difficulty and personality after strength is measurable

Use search/refinement/continuation budgets, risk tolerance, evaluator strength, and strategic priors rather than hidden stat cheats. Easier AI should make controlled, legible mistakes rather than random actions. Validate raw strength and player preference separately.

## Game backend improvements that unlock better AI and a better game

Keep one canonical simulation authority. Do not create an AI-only rules engine.

### 1. Canonical state/hash layer — hash implemented; indexing/performance work remains

PR #76 added deterministic canonical state hashing and connected it to ReplayV1 verification. Continue with:

- thin canonical indexes such as `unit_by_id`, occupancy-by-cell, and group lookup where profiling shows repeated scans;
- separation of static scenario/unit-definition data from frequently copied dynamic state where useful;
- profiling before introducing more complex delta/scratch-state simulation;
- reuse of the canonical hash for safe caches/transposition-style continuation reuse where semantics allow it.

Keep the dictionary-based state format unless profiling proves it is the dominant bottleneck.

### 2. Keep `TurnExecutionCore` canonical, but modularize its internals

As complexity grows, split responsibilities behind the canonical facade into pure resolver/rule modules such as movement/collision, combat/targeting, effects/status, economy/production, objectives/victory, and shared rule queries.

This is an internal modularization task, not permission to fork gameplay and AI rules.

### 3. Generalize objectives and scenarios

The command hex solves stalling pressure but should not become the only geometry the AI learns.

Introduce data-driven `ScenarioDefinition` / `ObjectiveDefinition` concepts that can express command capture, multiple control points, escort/defend, survival/escape, resource pressure, production races, and procedural geometry without bespoke engine branches.

### 4. Add a canonical player-observation API before fog/scouting mechanics

Before imperfect information exists, define exactly what each player can observe. Human clients and gameplay AI should use the same observation contract so fair-play guarantees are testable.

### 5. Prefer generic traits/effect operators over unit-specific rule branches

Compose new mechanics from reusable concepts such as damage, stun, movement modification, interception, spawning, resource transfer, capture progress, vision, and timed effects.

### 6. ReplayV1 foundation — implemented; enrich over time

PR #76 implemented the backend/debugging foundation:

- versioned ReplayV1 data;
- initial state and submitted simultaneous actions;
- configuration/rules/result metadata;
- before/after deterministic state hashes;
- deterministic replay through the canonical simulator;
- exact first-divergent-turn reporting;
- initial reason-coded events;
- round-trip and tamper regression tests.

Do **not** build a separate replay rules engine. Future work can incrementally add richer reason codes, automatic Arena/self-play replay emission, and visual playback using the existing replay data.

### 7. Add invariants and metamorphic tests for simultaneous resolution

Expand beyond authored examples with properties such as:

- deterministic replay of identical state/actions/config;
- mirrored/rotated equivalent states resolve equivalently when rules are symmetric;
- faction/name permutations do not change rule semantics;
- conservation rules hold where applicable;
- no impossible occupancy after resolution;
- objective capture occurs at the defined full-turn boundary;
- AI simulation and gameplay execution produce identical next states for identical inputs.

### 8. Prioritize mechanics that create simultaneous strategic prediction

Favor mechanics that create meaningful prediction, commitment, positioning, information, objective, and tempo tradeoffs. Strong candidates include interception/overwatch, telegraphed attacks, terrain/cover, multiple objectives, production/reinforcement pressure, and support/screening mechanics.

Do not add abilities solely for variety; add mechanics that create genuinely new decisions.

## Arena and benchmark efficiency policy

Spend compute on **more independent seeded positions before wider search** by default.

- **2x2:** cheap regression/baseline signal.
- **4x4:** preferred diagnostic when candidate recall/evaluator quality may be hidden by 2x2 width.
- **6x6/8x8/offline oracle:** teacher/diagnostic budgets, not automatic gameplay defaults.

Use mirrored pairs, stable seeds, and separated training/evaluation seeds. Record outcome, unresolved rate, termination reason, decision time, simulation count, candidate-intent coverage, candidate recall, oracle gap, and conditional selection accuracy where practical.

Do not assume a larger search budget is stronger. Compare quality **per unit of compute**.

For expensive broad diagnostics, isolate independent decisions/jobs so one pathological state does not erase useful results. Partial completion should be reported explicitly rather than silently filtering slow states.

## Counterfactual regression policy

Keep the curated suite small — roughly 4-6 stable tactical regressions. Do not use it as the definition of general strategy.

When rules change, update/remove cases whose old answer is no longer naturally correct. Add a new case only when self-play, Arena, oracle analysis, or playtesting reveals a recurring embarrassing tactical mistake worth guarding against.

Use Arena strength, candidate recall/value gap, self-play outcomes, sibling ranking, and held-out value performance as the evolving measurements.

## Self-play exploration policy

Exploration is a training-data tool, not evaluation noise. Search remains deterministic; training may choose from a bounded near-best prefix with reproducible seeds/provenance.

Export exploration supervision only after the trajectory actually diverges from its greedy reference. Do not use unconstrained random legal actions.

## Sibling-ranking supervision policy

Ranking supervision must be grounded in real simulator continuations and split by held-out scenario families to prevent leakage.

As the oracle/refinement system improves, increasingly source sibling pairs from:

- oracle/refined candidates;
- local perturbations around strong plans;
- evaluator disagreements;
- meaningful oracle-value gaps;
- actual Arena/self-play mistakes.

Report overall and family-specific ranking accuracy. Do not let the dataset become a closed loop over only the plans the current bounded generator already knows.

## Promotion gates

### Candidate-generator promotion gate

A candidate generator must improve near-oracle recall and/or reduce oracle-value gaps/severe misses without unacceptable decision-time cost. It must preserve deterministic behavior, objective/intent coverage, and same-budget full-game strength.

### Neural evaluator promotion gate

The first neural gameplay milestone remains:

**same search budget + neural evaluator vs same search budget + handwritten evaluator on frozen mirrored Arena seeds.**

A neural candidate should improve full-game strength, counterfactual decision quality, and held-out sibling ordering before replacing handwritten evaluation.

Interpret evaluator failures only where candidate recall is adequate.

### Learned-policy promotion gate

A learned prior must improve candidate recall and/or full-game strength **per unit of search compute** before replacing handcrafted proposal/pruning as default.

## Revised milestones

### Milestone A — Search quality and speed foundation

**Completed**

- Candidate Oracle Recall benchmark and severe-miss mining.
- Broad Candidate Oracle baseline sufficient to establish candidate-generation and ranking priorities.
- Batched neural leaf evaluation with cache/dedup/timing diagnostics.
- Deterministic canonical state hash.

**Next**

- Portfolio/refinement candidate generator behind a feature flag.
- Profile and reduce expensive continuation/state-copy/repeated-evaluation hotspots.
- Add canonical indexes only where profiling justifies them.

**Gate**

- Better candidate recall/value gap at comparable compute.
- No deterministic/regression failures.
- Material improvement in hard-state diagnostic completion/runtime.

### Milestone B — Better decision policy

**Completed foundation**

- ReplayV1 deterministic replay/hash verification and initial reason-coded events.

**Next**

- Train sibling ranking from production + oracle/refined + mistake-mined siblings.
- Add family-level sibling diagnostics.
- Experiment with risk-aware opponent-response scoring after ranking data improves.
- Modularize `TurnExecutionCore` internals without creating another rules engine.
- Add generic objective/scenario definitions.

**Gate**

- Lower serious tactical regret.
- Better conditional selection accuracy when a near-oracle candidate is available.
- No increase in passive/pathological-loop behavior.
- Same-budget Arena improvement against the champion.

### Milestone C — Strategic depth

**AI**

- Selective multi-turn continuation triggers.
- Historical champion/archetype opponent league.
- Value-model training across richer scenario families.

**Backend/game**

- Data-driven scenario/objective catalog.
- Canonical player-observation API.
- A small number of strategically distinct mechanics emphasizing prediction, information, multi-objective pressure, and tempo-vs-production decisions.

**Gate**

- No single strategy dominates procedural scenario variants.
- Exploit gaps against historical/archetype opponents shrink.
- Blind playtests report multiple viable plans and readable AI behavior.

### Milestone D — Learned policy and personalities

**AI**

- Distill policy priors from stronger search/oracle targets.
- Factorized per-unit prior plus coordination/joint-plan signal.
- Difficulty and personality through budgets, risk, and strategic priors.

**Backend/game**

- Expand generic traits/effect operators.
- Expand scenario/asymmetry catalog only after objective/observation abstractions are stable.

**Ship gate**

- AI beats the previous champion at equal compute.
- Candidate recall and tactical regret improve.
- Turn-time budget is met.
- Objective/fog/loop cases pass.
- Human preference improves in blind playtests.

## Immediate next step

**Build and benchmark the feature-flagged portfolio/refinement candidate generator, using the Candidate Oracle baseline as the comparison point. In parallel, profile and reduce the expensive counterfactual-continuation path. Then rerun only the missing baseline cells and residual 4x4 generation misses, and feed oracle/refined plans plus mined mistakes into stronger sibling-ranking supervision.**
