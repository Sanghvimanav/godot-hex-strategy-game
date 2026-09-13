# Radius-one tactical curriculum (experimental, not Phase 1 promotion)

This is an intentionally small drill before returning to the full-game Phase 1
contract in `AI_PHASE1.md`. One hex of radius contains seven cells, but allied
units can share a cell. Marines begin stacked at one edge, Zerglings at the
opposite edge; both stacks rotate together through the six directions. Health,
actions and simultaneous-turn resolution use the real simulator.

| Drill | Units | Turn horizon | Success / adjudication |
| --- | --- | --- | --- |
| 1 | 1 Marine, 2 Zerglings | 3 | Zerg eliminate Marine; Marine wins if alive after turn 3. No command capture. |
| 2 | 3 Marines, 2 Zerglings | 8 (diagnostic) | Marines win only by eliminating both Zerglings. If any Zergling remains at the horizon, Marines fail. No command capture. |
| 3 | 2 Marines, 4 Zerglings | 4 | Zerg eliminate Marines; Marines win if any survive through turn 4. No command capture. |

None of the three basic drills uses a command-hex objective. This is deliberate:
we want the smallest possible combat curriculum, so Scenario 2 must demonstrate
that the Marines can actually catch and eliminate the Zerglings rather than win
through a secondary objective. The `basic_state(...)` helper keeps command hexes
as an explicit per-game opt-in (`command_hexes_enabled=true`) for later scenarios
that need anti-kiting pressure.

Drill 2 has no user-specified horizon; eight turns remains a provisional
diagnostic limit, not a new game-wide rule. A previous fixture version let
Terran win this drill by command capture on turn 3. That result no longer counts.
If the handwritten baseline cannot eliminate both Zerglings by turn 8, the game
is a Zerg win and should be reported as evidence that the baseline does not solve
the drill.

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
these initial actions. This means a loss is not "the handwritten evaluator losing
to another evaluator"; the same handwritten policy controls both sides, and one
faction simply loses the resulting game. Scenario 2 is now particularly useful
as a diagnostic because its old command-capture shortcut is gone.

Before fitting a candidate, audit wins and losses in each training scenario,
the input-conflict count, failures, and termination reasons. A nine-game
single-policy baseline can show the rules work, but is not enough evidence that
either faction has learned to pursue its objective. Arena runs must use equal
decision-time budgets on the same hardware, record turn times, and report wins,
losses, draws, and unresolved games per matchup. Never promote the checkpoint
automatically or claim the broader Phase 1 gate was met.
