# AI Roadmap

## Goal

Build a fair, challenging strategy-game AI that coordinates simultaneous actions, discovers useful tactics instead of only imitating handwritten heuristics, scales to materially larger armies, and stays inside the player's turn-time budget.

The immediate Phase 1 promotion contract remains the contract in `docs/AI_PHASE1.md`: the neural challenger must achieve at least 75% neural wins among resolved games and at least 50% resolution independently on twenty familiar-map and twenty unfamiliar-map games, under equal decision-time budgets and the existing training-time/provenance gates. Until that contract passes, the handwritten champion remains the gameplay baseline/fallback.

The roadmap should improve four things together:

1. **Plan generation** — propose coordinated multi-unit plans without enumerating the full combinatorial action space.
2. **Search** — spend simulation compute on uncertain or promising plans, including lower-prior plans that may prove better after simulation.
3. **Value learning** — correctly distinguish winning, drawing, losing, and non-converting states over multiple turns.
4. **Game/backend support** — keep simultaneous resolution deterministic, fast, replayable, and eventually compatible with fog of war and larger armies.

Do not treat a larger value network or a wider beam as the default answer to every weakness. Diagnose whether a failure came from plan generation, search/exploration, value/ranking, opponent modeling, representation/generalization, or game-rule limitations.

## Current architecture

The project already has most of the pieces needed for an AlphaZero/AlphaStar-inspired architecture:

- a deterministic pure-state simulator with canonical simultaneous-turn resolution;
- whole-game rollout and terminal outcome generation;
- bounded own-plan and opponent-response search;
- handwritten tactical-intent candidate generation;
- a neural value evaluator;
- an autoregressive learned joint-plan policy that emits legal per-unit actions one unit/action at a time;
- robust opponent-response evaluation;
- self-play, counterfactual decision capture, held-out arenas, and reproducible scenario rotations;
- policy proposals that supplement rather than replace normal search;
- a candidate-oracle diagnostic and wider-search teacher infrastructure.

The current live robust search is **not MCTS**. It generates a bounded set of own plans and opponent plans, simulates their one-turn interactions, evaluates leaves, and ranks own plans primarily by worst-case response value. In the current basic random configuration, the plan budget is usually four own plans and four opponent plans. Learned proposals currently occupy only part of that own-plan budget.

The learned policy is already autoregressive: it constructs complete team plans by scoring legal next actions conditioned on the state and the friendly actions already chosen in the plan prefix. This is the right basic representation for a combinatorial action space, but a fixed top-k beam alone is not enough to provide strong exploration or multi-turn credit assignment.

## September 13, 2026 findings that change the roadmap

### Value + policy self-play is promising but not yet stronger than the handwritten champion

The corrected value+policy experiment improved the fixed tactical benchmark substantially while remaining mixed on the broader held-out randomized arena:

- final held-out randomized arena: neural 27, handwritten 29, unresolved 16; neural won 48.2% of decisive games;
- prior value-only comparison was 43.3% neural among decisive games, so adding the policy was a modest overall improvement;
- fixed counterfactual suite: neural 12, handwritten 6, unresolved 0, versus 6-12 for the prior value-only model;
- Scenario 3 improved materially, including neural Zerg winning all three held-out mirrored games it controlled.

This is evidence that learned proposals can help, but not evidence that the current proposal/search loop is sufficient.

### 2 Marines vs 1 Zergling exposes a multi-turn conversion/generalization problem

In `m2_z1`, when neural controls Terran/Marines, the neural side does not lose but often fails to convert an overwhelming position:

- neural Terran: 2 wins, 0 losses, 7 unresolved at the eight-turn cap;
- handwritten Terran: 9 wins in 9 games, usually in three turns;
- held-out rotation 1 succeeds, while rotations 3 and 5 contain most of the unresolved behavior;
- unresolved games repeatedly attack while the Zergling fast-moves around the board, and the neural value remains extremely positive despite the failure to convert.

This points to at least three separate issues:

1. **value calibration / temporal credit** — the value network can call a non-converting chase overwhelmingly favorable;
2. **rotation generalization** — the current action/state representation still has meaningful rotation-specific weakness;
3. **search depth / coordinated response selection** — one-turn leaf scoring does not necessarily reveal which coverage pattern forces a later kill.

### Draws at the basic-random self-play horizon now have an explicit zero target

For `basic_random_self_play`, unresolved turn-cap rollouts now opt into a value target of exactly `0.0`. They are not falsely marked terminal. Resolved wins/losses retain the existing faster-win discount, so the intended ordering is effectively:

`fast win > slow win > draw/unresolved horizon (0) > loss`

This change is scoped to basic random self-play (and explicit opt-in datasets); do not assume all unresolved branches everywhere are automatically labeled draws.

### Split-fire diagnostic: the concept is already present in the live policy/search

The focused `2M1Z Split-Fire Diagnostic` completed successfully using the existing final value+policy checkpoint.

Across held-out rotations 1, 3, and 5 and inspected turns 2-4:

- the **live neural proposal budget of 2 contained a split-fire plan on every inspected decision**;
- that split-fire plan was consistently rank 2 under the learned policy;
- the **live four-plan search also contained a split-fire candidate on every inspected decision**;
- the expanded 32-plan neural beam contained **27 split-fire variants** at every inspected turn;
- expanded heuristic/search candidates contained roughly 10-14 split-fire plans depending on the state;
- rotation 1 converted to a Terran win in four turns;
- rotations 3 and 5 still reached the turn limit despite split-fire plans being available, and the selected plan was sometimes itself split fire.

Therefore the main current failure is **not simply that autoregressive generation cannot imagine split fire**. Widening the beam can improve tactical diversity, but it will not by itself solve the observed pathology. The next search architecture must answer a harder question:

> Which coordinated plan remains good across likely/adversarial simultaneous responses and actually converts over multiple turns?

That is the main reason to move MCTS/PUCT earlier in the roadmap.

## Architecture decision: implement simultaneous-action MCTS/PUCT next

The preferred architecture is now a hybrid of AlphaStar-style structured policy generation and AlphaZero-style search/value learning:

**full visible state -> shared encoder -> autoregressive plan policy for both sides -> simultaneous-action PUCT/MCTS -> pure simulator -> value network -> visit-count targets + terminal value targets**

Do **not** implement ordinary alternating-move chess/Go MCTS. The game is simultaneous: both players choose from the same pre-turn information state and neither may condition the current-turn choice on the opponent's secretly selected current-turn plan.

The existing bounded robust search should remain available as:

- a fallback while MCTS is brought up;
- a benchmark/champion comparison;
- an offline diagnostic/teacher;
- a way to verify that MCTS is not accidentally changing simultaneous-information semantics.

### Why MCTS now

The current system is accumulating separate mechanisms for candidate width, opponent matrices, selective continuation, exploration profiles, and policy distillation. MCTS can unify much of this around a single repeated search loop:

1. use the policy prior to propose plausible plans;
2. use visit counts and PUCT to decide which plans deserve more simulation;
3. resolve both players' selected plans simultaneously;
4. continue for multiple turns where useful;
5. evaluate the frontier with the value network or a terminal game result;
6. backpropagate the result into `N` and `Q` statistics;
7. train the policy from MCTS visit counts rather than only imitating a single bounded-search winner.

The policy supplies useful prior knowledge; MCTS supplies correction and exploration when that prior is wrong.

## Autoregressive plan generation: keep it, but do not make it a hard top-k gate

### Why it is needed

A team plan is combinatorial. If five units each have eight plausible actions, there are already `8^5 = 32,768` possible complete friendly plans. At fifteen units the flat joint-plan space becomes astronomically larger.

The policy should therefore **construct** plausible plans rather than enumerate all joint actions. Conceptually:

`unit 1 action -> unit 2 action conditioned on unit 1 -> ... -> end of plan`

This is analogous to the structured/autoregressive action decomposition used by AlphaStar: learn how to compose a valid structured action instead of representing every full action combination as a separate output class.

### Main risk: good joint plans can be pruned by an early low-probability prefix

Autoregressive generation can miss good plans. A complete team tactic may require an early unit action that looks mediocre in isolation. If beam pruning removes that prefix, the full tactic is never constructed, and MCTS cannot discover its value.

Protections:

- never rely on greedy decoding alone;
- preserve multiple prefixes with beam search and/or stochastic sampling;
- preserve **diversity**, not merely the 32 highest-scoring near-duplicates;
- include an exploration floor so lower-prior but legal plans can enter search;
- during training, allow a broader plan set than runtime inference;
- measure **candidate oracle recall**, not only policy top-1 accuracy;
- train the policy from MCTS visit distributions so successful lower-prior discoveries become higher-prior future proposals.

The split-fire diagnostic is a useful caution: top-2 already contains one split plan, while a 32-plan beam contains many more. The problem can be **which split/coverage plan** matters, not merely whether the generic tactical family is present.

## Scaling plan generation to 15+ units

Autoregression remains viable, but the search/generation mechanism should evolve with army size.

### Roughly 1-5 units

Use complete-team autoregressive plans with a modest diverse beam. MCTS can search complete plans directly.

### Roughly 5-10 units

Use wider/diverse beam generation and progressive widening in MCTS. Avoid spending the entire candidate budget on near-identical variants. Consider stochastic lower-ranked proposals during self-play.

### Roughly 10-15+ units

Move toward **hierarchical/grouped planning** rather than one flat 15-unit sentence. A likely structure is:

1. strategic intent or objective;
2. dynamically selected unit groups/roles;
3. group-level commands such as contain, flank, focus, screen, retreat, capture, or advance;
4. lower-level autoregressive actions inside each group.

The groups should eventually be learned/dynamic rather than hard-coded squads. Attention/entity representations and pointer-style unit selection are natural tools for this stage.

Also test plan-order robustness. If unit 1 is always decoded before unit 2, the network may learn arbitrary ordering artifacts. Prefer canonical tactical ordering, permutation augmentation, or architectures that reduce sensitivity to unit enumeration order.

## Opponent plans: combine AlphaStar-style learning with explicit simultaneous search

AlphaStar largely learns opponent behavior statistically through self-play/league training rather than explicitly enumerating a full opponent plan tree at every decision. Our game has a different structure: each turn is a sealed simultaneous plan, so explicit reasoning over plausible opponent plans is especially valuable.

For the current no-fog game, use the same full visible state for both sides and the same/shared policy machinery to propose plans from each perspective:

- `P(our plan | full state, our faction)`
- `P(opponent plan | full state, opponent faction)`

Neither side receives the other side's currently selected plan.

MCTS should then spend simulations across simultaneous plan pairs without giving either player illegal sequential information. Candidate/opponent selection can begin from independent policy priors, with robust/risk-aware backup rules and matrix-game diagnostics available for hard cases.

Important: an opponent-policy probability is **not truth**. Retain downside protection and occasional lower-probability opponent exploration so the AI does not become exploitable by a surprising but legal response.

## Simultaneous MCTS design

### Node semantics

A node represents a complete public game state at a turn boundary. With no fog of war, that state is fully observable.

For each side, track plan-edge statistics such as:

- policy prior `P(s,a)`;
- visit count `N(s,a)`;
- mean backed-up value `Q(s,a)`;
- optional response-pair statistics when needed for simultaneous-game solving/debugging.

### PUCT exploration

Use a PUCT-style selection term conceptually like:

`Q(s,a) + c_puct * P(s,a) * sqrt(N(s)) / (1 + N(s,a))`

The exact simultaneous-game adaptation and constants should be treated as experimental. The important behavior is:

- high-prior/high-value plans get early attention;
- under-visited plans retain an exploration bonus;
- repeated poor simulations reduce a plan's attractiveness;
- a low-prior tactic can become dominant if search repeatedly discovers that it wins.

### Simultaneous turn selection

Do not model a turn as “Terran chooses, then Zerg observes Terran and chooses.” Both plans must be selected from the same parent information state before resolution.

Initial implementation options, in increasing sophistication:

1. independently select one plan for each side with PUCT and resolve the pair;
2. maintain pairwise payoff/visit statistics for important plan combinations;
3. use a restricted simultaneous zero-sum matrix-game solve at heavily visited nodes where mixed strategies matter.

Start simple, retain diagnostics, and only promote complexity if same-budget results justify it.

### Leaf evaluation and depth

Continue until:

- terminal outcome;
- simulation/depth budget;
- time budget;
- or a frontier state where the value network is used.

Unlike the current one-turn search, MCTS should be able to discover plans whose value appears only after several simultaneous turns, such as coverage that forces an escape path and kills on the following turn.

### Training targets

For self-play:

- policy target = normalized MCTS visit distribution over plans (or compatible autoregressive decomposition of that distribution);
- value target = terminal game result from the acting player's perspective, with faster-win discount where intentionally retained;
- basic-random horizon draw target = 0 under the current opt-in rule.

Do not train the policy merely to copy the raw neural prior or the current bounded search's top plan. Search should improve the target.

## MCTS implementation sequence

### MCTS-0 — preserve baselines and semantics

Before replacing gameplay search:

- keep current robust search unchanged behind its existing/default mode;
- add deterministic state/plan signatures suitable for tree statistics and transpositions;
- add tests proving both players' current-turn choices are based on the same pre-turn state;
- keep the existing 2M1Z split diagnostic as a regression fixture.

### MCTS-1 — one-node PUCT over current generated plans

Use the existing autoregressive/handwritten candidate machinery to produce a fixed initial plan set. Replace fixed ranking/allocation with repeated PUCT simulations at the root while still evaluating one simultaneous turn.

Goal: validate visit-count accounting and show that search can re-rank a lower-prior plan from simulated evidence.

### MCTS-2 — multi-turn tree

After each simultaneous resolution, create/reuse a child state and repeat policy proposal + PUCT selection. Backpropagate terminal/value estimates through the visited path.

Goal: solve conversion problems that one-turn leaf scoring cannot distinguish.

### MCTS-3 — progressive widening and proposal diversity

Do not materialize every possible plan immediately. Add plans as node visits grow:

- start with a small high-prior set;
- progressively request more autoregressive proposals;
- include stochastic/diverse lower-prior plans during training;
- deduplicate exact plans but preserve tactically distinct alternatives.

Goal: scale search without making the current policy top-k an irreversible pruning gate.

### MCTS-4 — batched neural inference and transpositions

MCTS will only be practical if inference/simulation throughput improves:

- batch policy/value evaluation for multiple frontier nodes;
- cache identical state evaluations;
- use deterministic state hashes for transposition reuse;
- measure simulator, serialization/IPC, encoding, and PyTorch inference time separately;
- convert saved overhead into more useful simulations rather than immediately increasing network size.

### MCTS-5 — self-play visit targets

Once search is trustworthy, train the policy from visit counts and the value network from final outcomes. Compare against the current search-distillation approach.

Track whether search-discovered tactics move upward in policy probability over successive generations.

## Rotation and symmetry generalization

The `m2_z1` rotation split is strong enough that rotation handling is now a first-class roadmap item.

Current action features include absolute coordinates/deltas and do not provide full rotational equivariance. Add one or more of:

- rotational data augmentation across all six hex rotations;
- canonical player-relative orientation before neural encoding;
- rotation-equivariant spatial features where practical;
- regression tests requiring equivalent policy/value behavior on rotated copies of the same tactical state.

Do this alongside MCTS rather than assuming search will hide representation failures. Search cannot efficiently compensate for a systematically wrong value/policy prior in one orientation forever.

## Exploration policy

Separate **training exploration** from **gameplay strength**.

Training may use:

- wider/progressively widened candidate sets;
- root prior noise or another controlled exploration perturbation;
- stochastic sampling from MCTS visit counts;
- deliberate lower-ranked/diverse plan injection;
- larger simulation budgets where affordable.

Gameplay may use:

- smaller deterministic/low-temperature visit selection;
- fewer initial plans with progressive widening only when the position remains uncertain;
- strict turn-time limits.

Avoid unconstrained random legal actions. Exploration should remain policy-guided and reproducible.

## Opponent league

Retain an AlphaStar-like league concept even after MCTS is added. MCTS improves local decisions; a league improves the distribution of strategies the networks learn to face.

Keep:

- historical champion checkpoints;
- current self-play opponents;
- exploiters/archetypes that pressure known weaknesses such as rushing, preservation, objective racing, economy/production, or unusual movement;
- held-out opponents for promotion tests.

The league should prevent the policy/value network from becoming excellent only against its current mirror.

## Fog of war: defer hidden-state inference, preserve the interface boundary now

Fog of war is **not implemented yet**, so the current MCTS/policy should use full public state. Do not prematurely add belief-state complexity.

Before fog/scouting is implemented, define a canonical player-observation API:

- simulator/server retains authoritative full state;
- each player/AI receives `ObservationState(player)`;
- the planning policy and MCTS tree are built from the information legally visible to that player;
- previously observed hidden information can later be handled by memory/belief models rather than leaking server state.

When fog arrives, AlphaStar-style recurrent/entity memory becomes more relevant. Until then, the uncertainty to solve is primarily **opponent intent**, not hidden world state.

## Value model priorities

MCTS does not remove the need for a good value model. It makes value errors easier to diagnose because visit statistics show which lines were actually explored.

Priorities:

- calibrate draw/non-conversion states around zero rather than assigning huge positive values to endless chases;
- retain terminal outcome as the strongest value supervision;
- use faster wins as a secondary preference, not a replacement for win/draw/loss ordering;
- mine MCTS disagreement states where prior policy/value and backed-up search value differ materially;
- preserve counterfactual/sibling ranking diagnostics as secondary supervision;
- report calibration and ranking by scenario family/rotation, not only overall accuracy.

## Candidate generation / policy promotion metrics

Top-1 policy accuracy is not enough. Track:

- oracle recall of at least one near-best plan;
- tactical-family/diversity coverage;
- first rank of oracle-quality plans;
- MCTS visit share assigned to plans that began with low prior;
- probability/visit calibration across rotations;
- plan coverage per unit of compute;
- same-budget full-game strength.

A policy is useful when it makes good search cheaper, not merely when it imitates yesterday's search winner.

## Game/backend work that unlocks better search

### Deterministic state/index/hash layer

- add canonical `unit_by_id`, occupancy, group/objective indexes;
- add deterministic state hashes for MCTS transpositions, value caching, replay verification, and debugging;
- separate static scenario/unit-definition data from frequently copied dynamic state where practical;
- profile before a wholesale state rewrite.

### Keep one canonical simultaneous rules engine

Do not fork gameplay and AI rules. Continue to resolve MCTS simulations through the same canonical pure rule/resolution path used by the game.

As complexity grows, modularize movement/collision, combat, effects, economy/production, objectives, and shared rule queries behind the canonical facade.

### Replay and diagnostics

Add deterministic replay records and reason-coded events so an MCTS line can be reconstructed and explained. Store enough provenance to answer:

- what state was searched;
- which plan priors existed;
- which plan pairs were visited;
- visit/Q statistics;
- value-network frontier estimates;
- selected plan;
- actual resolved result.

### Scenario/objective generalization

Command hexes are useful anti-stalling pressure but should not become the only strategic geometry. Keep data-driven objectives/scenarios for elimination, control, survival/escape, production races, escort/defend, and multi-objective pressure.

## Evaluation and promotion gates

### MCTS integration gate

MCTS should not become the default because it is theoretically attractive. Promote it only when it:

- preserves simultaneous-information legality;
- passes deterministic/replay tests;
- improves tactical conversion or full-game strength at a measured compute cost;
- stays inside the player turn-time budget;
- does not materially increase pathological loops or search failures.

### Policy gate

A learned autoregressive policy must improve candidate/oracle recall and/or MCTS strength per unit of compute. It must preserve an exploration path for unusual but important plans.

### Value gate

A neural value candidate should improve held-out outcome calibration/ranking and same-budget game strength. Evaluate results by rotation and strategic family as well as overall.

### Phase 1 gate

The existing Phase 1 contract remains authoritative until explicitly changed. MCTS experiments are not automatic promotions and must not mine reserved evaluation games into training.

## Revised milestones

### Milestone A — simultaneous MCTS foundation

- keep current robust search as fallback/baseline;
- add state/plan hashes and MCTS node statistics;
- implement fixed-candidate simultaneous root PUCT;
- prove no sequential current-turn information leakage;
- add instrumentation for `P`, `N`, `Q`, simulations, and elapsed time;
- retain the 2M1Z split-fire diagnostic.

**Gate:** deterministic/legal search that can re-rank plans from simulations without regressing baseline integration.

### Milestone B — multi-turn search + rotation fixes

- extend PUCT through multiple simultaneous turns;
- use neural value at frontier and terminal outcomes when reached;
- add rotational augmentation/canonicalization and rotated regression tests;
- batch frontier neural evaluation;
- add transposition/value caching.

**Gate:** materially better conversion on `m2_z1` rotations 3/5 and improved same-budget arena strength or tactical regret.

### Milestone C — AlphaZero-style self-play targets

- train autoregressive policy from MCTS visit distributions;
- train value from terminal outcomes, including scoped draw=0 horizon targets;
- use controlled root exploration during training;
- compare learned-prior + MCTS against current robust search/distillation at equal compute.

**Gate:** search discoveries become policy priors over successive generations, reducing simulations required for the same strength.

### Milestone D — opponent league and strategic depth

- preserve historical checkpoints and add exploiters/archetypes;
- broaden scenario families and production/objective mechanics;
- evaluate exploit gaps and strategy diversity;
- continue full-game, counterfactual, and oracle-recall diagnostics.

**Gate:** no single narrow strategy dominates held-out procedural variants, and exploit gaps shrink.

### Milestone E — 10-15+ unit scaling

- add progressive widening and explicit diversity controls;
- benchmark beam width/candidate count vs unit count;
- prototype dynamic grouping/hierarchical plan generation;
- add group/entity attention or pointer-style selection if flat autoregression becomes inefficient;
- verify unit-order/permutation robustness.

**Gate:** larger-army candidate recall and decision quality scale without exponential runtime growth.

### Milestone F — fog/scouting and personalities

- expose canonical player-observation states;
- add memory/belief modeling only when hidden information exists;
- maintain fair information access for AI and humans;
- tune difficulty/personality through search budget, risk, exploration temperature, and strategic priors rather than hidden stat cheats.

## Immediate next steps

1. **Implement the first simultaneous PUCT/MCTS layer using the existing policy/value/simulator rather than adding more ad hoc exploration heuristics.** Keep current robust search as the control/fallback.
2. Start with fixed candidate sets so the first experiment isolates visit-count search from candidate-generation changes.
3. Preserve both sides' same-state simultaneous planning semantics; do not implement fake alternating turns.
4. Add multi-turn expansion next, because the completed split-fire diagnostic shows that the relevant tactic is already present in live candidates while rotations 3/5 still fail to convert.
5. In parallel, add rotational augmentation/canonicalization and use the new basic-random draw=0 targets in the next training run.
6. Once MCTS is stable, train the policy from visit counts and add progressive widening/diverse proposals so the policy prior guides search without becoming a hard top-k gate.
7. Revisit hierarchical/grouped planning when controlled scaling tests show flat autoregressive complete-team plans becoming inefficient around larger armies; expect this to matter by roughly 10-15+ active units rather than redesigning prematurely for today's tiny boards.

## Ship gate

Promote a new AI only when it beats the current champion on held-out seeded full games, reduces serious tactical regret, stays inside the turn-time budget, respects simultaneous information and later fog-of-war constraints, avoids non-progress/pathological loops, and produces behavior players find challenging and legible.

Do not optimize solely for win rate. A shippable opponent should make strong decisions for understandable reasons, discover coordinated plans rather than depend on authored answers, expose the player to multiple viable strategies, and remain fair under the same information and rules available to the player.
