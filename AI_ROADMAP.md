# AI Roadmap

## Goal

A fair AI that coordinates simultaneous actions, avoids obvious blunders, offers distinct play styles, and responds within the player's turn-time budget.

## Current position

The pure simulator, legal actions, bounded joint planning, opponent-response search, tactical intents, whole-game rollout, self-play export, and first value model already exist. PR #42 broadens the data, but its latest held-out result is **45% neural accuracy vs 100% handwritten**, with **9/24 turn limits** and **2/24 search failures**. Do not replace the handwritten evaluator yet.

## Plan

1. **Finish #42:** record the final result, merge the broader suite, and fix the failed/unfinished rollout cases.
2. **Create the real benchmark:** fast tactical checks on every PR plus seeded full-game arenas measuring win rate, blunders, behavioral diversity, and turn time.
3. **Improve self-play:** vary legal maps, units, resources, objectives, and policies; replay each position with multiple exploration seeds to learn win probability instead of one deterministic outcome.
4. **Build a hybrid AI:** keep the existing bounded search, add the learned value behind a flag, retain the handwritten fallback, and add shallow multi-turn lookahead only where the benchmark proves it helps.
5. **Tune for fun:** set difficulty with search budget and controlled mistakes; set personalities with tactical-intent preferences; validate both through blind human playtests.

## Ship gate

Promote a new AI only when it beats the current AI on held-out full games, stays inside the turn-time budget, respects fog of war, and players prefer playing against it.

**Immediate next implementation PR after #42: the benchmark and head-to-head arena.**
