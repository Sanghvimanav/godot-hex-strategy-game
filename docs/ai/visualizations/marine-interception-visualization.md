# Marine interception visualization

This diagram documents the formation used by the `marine_spread` self-play
scenario as of self-play suite version 4.

## Formation and intended coverage

- Zergling: `(0, 0)`
- Marine 1 and Scout 1: `(1, 0)`
- Marine 2 and Scout 2: `(1, -1)`
- Marine combined fire coverage: `(0, -1)`, `(0, 0)`, `(0, 1)`
- Scout targets: `(-1, 0)`, `(-1, 1)`

The units at `(1, 0)` and `(1, -1)` are intentionally stacked. The diagram
shows desired coordinated coverage, not actions observed in a rollout trace.
The `r3` job rotates this complete layout by 180 degrees.

## Recreating or changing the diagram

The editable source is `marine-interception-coverage.fragment.html`. It is an
in-conversation visualization fragment; render it with the visualization helper
or place it in a page that supplies the standard theme variables. Its editable
data is near the top of the script:

- `stacks` controls unit type, label, and axial coordinate.
- `marineTargets` controls solid Marine coverage hexes.
- `scoutTargets` controls dashed Scout coverage hexes.
- `size` and `origin` control board scale and placement.

Axial `(q, r)` coordinates are converted to pointy-top SVG centers with:

```text
x = origin.x + size * sqrt(3) * (q + r / 2)
y = origin.y + size * 1.5 * r
```

The board currently renders every radius-two cell satisfying:

```text
max(abs(q), abs(r), abs(-q-r)) <= 2
```

When the actual self-play scenario changes, update these data sets in the same
commit so the diagram remains an accurate statement of the intended tactic.
