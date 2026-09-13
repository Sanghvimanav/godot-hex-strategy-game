# Phase 1: neural AI promotion contract

Build a fun, challenging AI while learning about neural networks and LLMs. Use
AlphaZero as inspiration; both learned plan proposals and learned evaluation are
allowed. Keep the canonical simulator and game rules shared with gameplay.

## Acceptance

Evaluate 20 games on familiar maps and 20 on unfamiliar maps, with ten mirrored
pairs in each group. Freeze the seeds and map generators before training. Neither
group, including unfamiliar deployments, may enter training or mistake mining.

Each group independently requires at least 50% resolution and at least 75% neural
wins among resolved games. Terminal draws count as resolved but not as wins.
Thus exactly ten resolved games require eight neural wins. Failed games block
promotion rather than disappearing from denominators. These small suites establish
the initial benchmark milestone, not a precise population win-rate estimate.

Compare against the handwritten heuristic with equal wall-clock decision-time
budgets on the same hardware for each game. Both agents receive the same pre-turn
state and no knowledge of the other's submitted actions. Record simulations,
actual decision time, budget exhaustion, outcomes, and termination reasons. The
maximum turn time is 30 seconds for up to six units. The budgeted search stops
between complete candidate evaluations; a blocking simulation/inference can
overrun, so measured overruns fail promotion.

Each candidate's self-play generation, continuation labeling, and all training
cycles must take under four hours elapsed, using parallel GitHub Actions workers
within available concurrency limits. Record worker count and runner type. Separate
experiments have separate budgets; final evaluation and total experimentation
time are reported separately. Example counts are diagnostics, not hard limits.
Reused parent checkpoints and datasets must have explicit provenance.

Default to automated training, asking for targeted human examples when a specific
weakness warrants it. Keep game rules frozen within experiments; after changing
rules between experiments, reevaluate both agents under the same new rules.
Monitor unresolved rates and behavior to improve aggression and fun over time.
Human-discovered exploits after a pass become subsequent training priorities.

An optional `evaluator_settings.selective_continuation` prototype compares the
two closest one-turn plans by searching one more simultaneous turn from each
plan's modeled worst response. It reserves 30% of an explicit decision-time
budget for this comparison and falls back to the original one-turn result when
the second-turn comparison cannot finish. The default remains one-turn search;
this is a worst-response probe, not exhaustive depth-two minimax, and must not
be used as promotion evidence without equal-budget tests and terminal-objective
handling for second-turn leaves.

## Initial experiment

`Phase One Candidate` starts from Iteration 2 (run `34240515308`), generates 64
training-only games against the handwritten opponent with both neural factions,
captures bounded alternative plans including unresolved-game decisions, and labels
fresh siblings using real continuations under the same opponent response. It
warm-starts the separate value/search-ranking heads, then evaluates the two frozen
groups. It never automatically replaces the champion.

The unfamiliar generator creates new opposing-wedge deployments and derives new
command positions; it does not merely relabel one-cell variations of fixtures.

Artifacts include the fresh dataset, training provenance/checkpoint, full traces,
and a fail-closed `phase_one_report.json`. A failed promotion report is evidence
for the next experiment, not a reason to weaken thresholds or alter the holdout.

## Experiment 1 result and follow-up

Run `34703812988` produced 898 fresh value examples and 123 fresh ranking pairs.
The training pipeline took 3,945 seconds on eight workers. Familiar evaluation
resolved 19/20 games with 5 neural wins (26.3%); unfamiliar evaluation resolved
18/20 with 2 neural wins (11.1%). Maximum decision times were 31.67 and 30.11
seconds respectively. Neither group passes promotion. The report job also failed
because module invocation imported PyTorch from the package initializer; the
stdlib-only gate must be invoked directly in the report job.

Experiment 2 retains the same parent checkpoint and frozen evaluation generators,
uses fresh training seed base 5100001, labels up to sixteen decisions per worker
instead of eight, increases ranking loss weight from one to three, and uses ten
epochs instead of twenty to limit value overfitting. Both agents receive equal
25-second search budgets, with the absolute 30-second promotion cap unchanged.
This is a bundled candidate improvement, not an isolated causal comparison of
each adjustment. Data jobs allow up to three hours; the full elapsed training
pipeline must still pass the four-hour gate. No champion is automatically replaced.

## Learned proposal integration

The opt-in V2 state encoder adds spatial active/pending stun duration, heal duration
and amount, pending effects, and finite tile-resource amounts. V1 remains the
default for existing checkpoints; V2 requires explicitly matching training and
runtime checkpoint metadata. Current reinforcement timing is carried by effects,
and command capture uses before/after occupant identity rather than a separate
persistent timer. This is not a claim that every future game field is encoded.

An autoregressive action head conditions on the state and earlier friendly actions.
Godot supplies all currently legal actions from the canonical server validator;
the policy can select those actions or an internal hold token that becomes no
submitted command. A bounded beam assembles plans, then robust search evaluates
them. Neural proposal mode reserves up to half of the existing own-plan budget
for learned proposals; handwritten plans fill the remaining slots without increasing
the total search width. Missing proposal checkpoints fall back to handwritten
proposals, not invented actions. The handwritten champion remains unchanged.

Initial proposal training distills bounded robust handwritten search scores from
training-only decisions. It is bootstrap supervision, not an AlphaZero visit-count
target or proof of optimal play. All prefixes from one game stay in one split;
action/unit vocabularies are built from training games only. Subsequent outcome-
labeled learned-plan continuations must drive improvement beyond that bootstrap.
See `docs/HUMAN_AI_EXAMPLES.md` for useful human examples and recording requirements.

### Experiment 3: strategic encoder and learned proposals

Experiment 2 (`34708894811`) did not pass: familiar games resolved 18/20 with
6 neural wins (33.3% of resolved); unfamiliar resolved 17/20 with 3 neural wins
(17.6%). Its measured turn times passed the absolute cap and its training pipeline
took 5,012 seconds. These are diagnostics, never new training examples.

Experiment 3 reuses experiment 2's audited training dataset and its eight
training-only search-capture shards. No evaluation traces enter either trainer.
The V2 value model trains from scratch for 10 epochs (ranking weight 3), because
its added input planes are incompatible with a V1 warm start. A new proposal head
then trains for 10 epochs with that value backbone frozen. Its game-level split
is aligned with the value model's split. Proposal accuracy is a conditional
preference diagnostic, not evidence of arena strength.

Frozen evaluation remains two separate mirrored 20-game groups, broad 8×8 search,
equal 25-second decision ceilings, and the absolute 30-second measured cap.
Learned proposals occupy at most four of the eight own-plan slots; handwritten
plans fill the remaining slots. All new work, including both training stages and
setup/worker waiting, counts toward the four-hour pipeline gate. Reused data and
parent run are recorded explicitly. This experiment does not promote a checkpoint.

### Experiment 3 result and controlled proposal ablation

Run `34715462406` completed on September 12, 2026. Both familiar and unfamiliar
groups resolved 16/20 games, with zero neural wins and four unresolved games each.
There were no failed games. Maximum decision times were 27.97 and 28.35 seconds;
the reused-data training pipeline took 136.20 seconds. All contract gates except
win rate passed, but this is a clear regression from experiment 2, not promotion.
Proposal validation top-1 accuracy was 38.3% across 60 held-out prefix examples;
value/ranking training also showed a generalization gap. Neither establishes the
cause of the arena regression. Do not mine these evaluation traces for training.

Experiment 4 is a controlled ablation: reuse the exact experiment 3 checkpoint
(`ef59bc0dd5862c90ca2cf82cb1369c10d9e7a4b3e4c0ff39e212889817aad5cd`)
and turn learned proposals off. The richer encoder and value/ranking weights remain
identical. All eight own-plan slots use handwritten proposals again. Frozen rules
remain commit `9509cec4d018ad97fc05cb959647303bb1f4add7`; only experiment orchestration,
provenance tooling, tests, and documentation change. Both twenty-game evaluations,
mirroring, hardware, and decision-time ceilings are unchanged. No new examples or
training epochs are produced. Preserve source training provenance and count ablation
setup time alongside the original training elapsed time rather than pretending
the reused checkpoint required zero training. Do not merge or promote automatically.

This comparison isolates proposal mode at fixed weights, including its effect on
candidate coverage and decision-time allocation. It does not isolate the V2 encoder
from the from-scratch training change, nor prove any particular tactical cause.

### Experiment 4 result and fresh-data candidate

Run `34717471103` completed September 12, 2026. With the identical experiment 3
checkpoint and handwritten-only proposals, familiar games resolved 18/20 with
5 neural wins (27.8%); unfamiliar resolved 18/20 with 3 neural wins (16.7%).
Each group had two unresolved games and no draws or failures. Maximum decision
times were 27.08 and 26.37 seconds. All gates except win rate passed. Restoring
handwritten proposals recovered wins, implicating learned proposal admission and
its compute allocation in the earlier regression; it does not prove a particular
tactical explanation. Do not mine either frozen evaluation for training.

Experiment 5 keeps handwritten-only proposals while generating 96 new training-
only games from seed base 6100001, with balanced faction assignments and eight
parallel workers. Capture up to four decisions per game and label up to 24
family-diverse decisions per worker using real neural-vs-handwritten continuations
under a shared opponent response. Combine fresh supervision with the audited
parent training dataset, requiring fresh ranking pairs rather than silent reuse.

Warm-start the V2 value/ranking model from experiment 4's unchanged checkpoint;
train five epochs at learning rate 0.0001 and ranking weight 3. Retain all parent
validation game IDs outside training and split only newly encountered games.
This limits additional fitting while expanding state/continuation coverage, but
does not guarantee stronger play. The new checkpoint contains the value/ranking
heads; proposal-head training is deferred until stronger targets/admission are
validated. Frozen evaluation, separate twenty-game gates, equal 25-second ceilings,
absolute 30-second cap, and four-hour elapsed pipeline gate remain unchanged.
