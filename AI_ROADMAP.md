# AI Roadmap

## Goal

A fair AI that coordinates simultaneous actions, avoids obvious blunders, offers distinct play styles, and responds within the player's turn-time budget.

## Current position

The pure simulator, legal actions, bounded joint planning, opponent-response search, tactical intents, whole-game rollout, richer self-play export, and first value model exist. The neural evaluator is still directional evidence rather than a gameplay upgrade, so retain the handwritten evaluator as the baseline. PR #44 adds policy-conditional counterfactual targets, candidate-ranking metrics, top-plan regret, and reviewed tactical cases.

## Plan

1. **Complete the benchmark:** merge PR #44, split it into fast per-PR checks and full scheduled/manual runs, then add seeded full-game arenas measuring win rate, blunders, behavioral diversity, and turn time.
2. **Strengthen the understandable baseline:** bound material, health, production, resource, and objective values so long-term Civilization-like state is represented without any one feature dominating.
3. **Improve self-play:** vary legal maps, units, resources, objectives, and policies; replay comparable positions with multiple exploration seeds to estimate policy-conditional win probability rather than treating one deterministic outcome as truth.
4. **Build a measured hybrid AI:** keep bounded search and the handwritten fallback, add learned value behind a flag, and add shallow multi-turn lookahead only where tactical and full-game benchmarks show an improvement within the time budget.
5. **Tune for fun:** set difficulty with search budget and controlled mistakes; set personalities with tactical-intent preferences; validate strength and interestingness separately through blind human playtests.

## Ship gate

Promote a new AI only when it beats the current AI on held-out seeded full games, reduces serious tactical regret, stays inside the turn-time budget, respects fog of war and scenario objectives, and players prefer playing against it.

**Immediate next step: finish PR #44, then add fast/full benchmark tiers and the seeded head-to-head arena before changing gameplay evaluation.**
