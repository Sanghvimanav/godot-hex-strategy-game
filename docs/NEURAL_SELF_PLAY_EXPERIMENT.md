# Randomized Neural Self-Play Experiment

This experiment moves the radius-one curriculum away from training directly on the three fixed drills.

## Training

- Radius: 1.
- Marines begin stacked on one edge cell; Zerglings begin stacked on the opposite edge cell.
- Unit counts are sampled from 1-4 per side.
- 80% of starts are biased toward equal or +/-1 unit-count matchups; the remainder sample the full 1-4 range.
- Training rotations are only 0, 2, and 4.
- Command hexes/objectives are disabled.
- Faster wins are preferred with terminal-return discount `0.95 ** turns_remaining`.
- Each starting state is rolled out along greedy, light-exploration, and explore paths. Alternative paths export examples only after they first diverge from the greedy trajectory.

The workflow first trains a seed value model from randomized handwritten-vs-handwritten trajectories. It then runs neural-vs-neural self-play from the same training distribution and trains a second model from the combined seed + neural-self-play dataset.

## Evaluation

The primary arena uses a separate seed range and only rotations 1, 3, and 5. These held-out rotations are never used for training or alternative-path mining.

- 36 randomized starting pairs by default.
- Every state is played as a mirrored pair: neural as Terran and neural as Zerg against the handwritten evaluator.
- Both agents use the same search width and a 5-second decision budget.
- The report compares the seed model with the post-self-play model, including wins, mirrored-pair results, unresolved games, and passivity.

The original three fixed drills are retained as a separate counterfactual arena. They are diagnostic only and are not included in the randomized training dataset.
