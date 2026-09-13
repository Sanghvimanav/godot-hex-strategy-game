# Radius-one tactical curriculum (experimental, not Phase 1 promotion)

This is an intentionally small drill before returning to the full-game Phase 1
contract in `AI_PHASE1.md`. One hex of radius contains seven cells, but allied
units can share a cell. Marines begin stacked at one edge, Zerglings at the
opposite edge; both stacks rotate together through the six directions. Health,
actions and simultaneous-turn resolution use the real simulator.

| Drill | Units | Turn horizon | Success / adjudication |
| --- | --- | --- | --- |
| 1 | 1 Marine, 2 Zerglings | 3 | Zerg eliminate Marine; Marine wins if alive after turn 3. No command capture. |
| 2 | 3 Marines, 2 Zerglings | 8 (diagnostic) | Marines win by elimination or the existing one-turn-hold command capture. If Zerg remain without capture, Marines fail at the horizon. |
| 3 | 2 Marines, 4 Zerglings | 4 | Zerg eliminate Marines; Marines win if any survive through turn 4. No command capture. |

Drill 2 has no user-specified horizon; eight turns is a provisional diagnostic
limit, not a new game-wide rule. With elimination alone, a surviving Zergling
can evade three center-stacked Marines through eight turns. The existing command
hex rule makes it contestable: in a local handwritten baseline, Terran captured
the command hex on turn 3. Keep this explicit in all comparisons.

Training uses rotations 0, 2, and 4 (`basic_training`); evaluation uses 1, 3,
and 5 (`basic_s1` for the 1v2 holdout, `basic` for all 2–4 Marines versus 2–4
Zergling count combinations, 27 mirrored pairs / 54 games). The two agents
swap factions on the **same** state in each pair. Evaluation rotations must
never enter training or mistake mining; these are rotation holdouts, not
unfamiliar maps or a substitute for the two-group Phase 1 acceptance suite.

Every decisive training position gets a relative return of
`+/-0.95 ** (turns_to_terminal)`; draws remain zero. Thus a quicker win is worth more, a
later loss hurts less, and winning is still preferable to losing. Scenario and
remaining-turn context use the opt-in version-3 state encoder. Earlier
checkpoints continue using their own encoder versions unchanged.

The initial nine games are **handwritten versus handwritten self-play**: both
factions search with the same handwritten evaluator. The neural model learns
from *terminal results*, not the evaluator's score, but it does not generate
these initial actions. On the final local fixture version, the outcomes were
three Terran wins in drill 2 and six Zerg wins in drills 1 and 3. This has no
successful Marine-survival trajectories in drills 1 or 3; it is not enough to
teach competent defense. Use this only for a small value-model pilot and
independent evaluation. If the pilot is viable, generate subsequent *training-
only* neural-versus-neural and neural-versus-handwritten rollouts, including
defensive successes, and retain the original rotation holdouts untouched.

Before fitting a candidate, audit wins and losses in each training scenario,
the input-conflict count, and failures. A nine-game single-policy baseline can
show the rules work, but is not enough evidence that either faction has learned
to pursue its objective. Arena runs
must use equal decision-time budgets on the same hardware, record turn times,
and report wins, losses, draws, and unresolved games per matchup. Never promote
the checkpoint automatically or claim the broader Phase 1 gate was met.
