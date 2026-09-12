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
