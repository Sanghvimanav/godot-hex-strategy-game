# AI Roadmap

## Goal

A fair AI that coordinates simultaneous actions, avoids obvious blunders, offers distinct play styles, and responds within the player's turn-time budget.

## Current position

The pure simulator, legal actions, bounded joint planning, opponent-response search, tactical intents, whole-game rollout, command-hex victory, richer self-play export, counterfactual decision benchmark, and first value model exist. Objective-aware proposal/final-plan recall and rotation-aware command objectives are on `main`. The neural evaluator is still directional evidence rather than a gameplay upgrade, so retain the handwritten evaluator as the baseline.

The next measurement layer is a seeded AI-vs-AI arena. Arena scenarios should be procedural but reproducible: select from proven tactical families, perturb geometry/HP/resources with deterministic seeds, rotate deployments, and play every generated state twice with the competing agent configurations swapped between factions. This gives robustness to small scenario changes without sacrificing debuggability.

## Plan

1. **Complete the benchmark:** split checks into a fast per-PR tier and larger manual/full tier; use the seeded full-game arena to measure wins, unresolved games, non-progress, decision time, and search simulations. Keep mirrored side swaps together so faction/scenario bias cancels within each pair.
2. **Strengthen the understandable baseline:** bound material, health, production, resource, and objective values so long-term Civilization-like state is represented without any one feature dominating.
3. **Improve self-play:** vary legal maps, units, resources, objectives, and policies; replay comparable positions with multiple exploration seeds to estimate policy-conditional win probability rather than treating one deterministic outcome as truth.
4. **Build a measured hybrid AI:** keep bounded search and the handwritten fallback, add learned value behind a flag, and add shallow multi-turn lookahead only where tactical and full-game benchmarks show an improvement within the time budget.
5. **Tune for fun:** set difficulty with search budget and controlled mistakes; set personalities with tactical-intent preferences; validate strength and interestingness separately through blind human playtests.

## Arena efficiency policy

Spend compute on **more seeded positions before wider search**. The fast arena should use tight 2x2 plan-response budgets and shard complete mirrored pairs across workers. The full arena should first increase the number/diversity of generated pairs; only widen search when the question specifically concerns search depth. Record per-agent decision time and simulation count so strength gains can be compared at equal compute.

## Ship gate

Promote a new AI only when it beats the current champion on held-out seeded full games, reduces serious tactical regret, stays inside the turn-time budget, respects fog of war and scenario objectives, and players prefer playing against it.

**Immediate next step: land the seeded arena, establish a stable fast/full seed set, then use it before changing gameplay evaluation.**
