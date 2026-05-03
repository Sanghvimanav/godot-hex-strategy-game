---
name: self-evolve-targeted-repair
description: Runs one self-evolve iteration, diagnoses failed eval cases, patches the active prompt, and re-tests only failed cases for up to 3 repair rounds. If all repaired cases pass, starts the next self-evolve iteration. Use when the user asks to iterate on prompt failures quickly without full long runs each round.
---
# Self-Evolve Targeted Repair

## Goal
Run a tight optimization loop:
1. Run exactly one self-evolve iteration.
2. Diagnose failures from that iteration.
3. Update the prompt.
4. Re-test only failed cases.
5. Repeat prompt-repair up to 3 rounds.
6. If all failed cases are fixed, run one more self-evolve iteration.

## Inputs
- Planner thinking level (for eval calls), e.g. `medium`.
- Optimizer thinking level (for self-evolve), e.g. `high`.
- Optional model override (default from project settings).

## Workflow

Copy this checklist and keep it updated:

```text
Repair Loop Progress
- [ ] Step 1: Run one self-evolve iteration
- [ ] Step 2: Collect failed cases and reasons
- [ ] Step 3: Repair round 1 prompt update + targeted rerun
- [ ] Step 4: Repair round 2 prompt update + targeted rerun (if needed)
- [ ] Step 5: Repair round 3 prompt update + targeted rerun (if needed)
- [ ] Step 6: If all pass, run one additional self-evolve iteration
```

### Step 1: Run one iteration
Run:

```bash
python3 tools/evals/run_self_evolve.py --max-iters 1 --thinking-level <planner_thinking> --optimizer-thinking-level <optimizer_thinking>
```

Find the latest session under:
- `tools/evals/self_evolve/<session_id>/`

Find the iteration run summary:
- `tools/evals/runs/<session_id>_iter01/summary.json`

### Step 2: Diagnose failures
From `summary.json`, read:
- `failed_case_ids`
- `failed_case_reasons`

Then inspect each failed case artifact:
- `tools/evals/runs/<session_id>_iter01/cases/<case_id>.json`

For each case, record:
- expected behavior (from reason + case intent),
- chosen action(s),
- error class:
  - geometry/coverage confusion,
  - aggression vs safety policy,
  - multi-unit coordination,
  - parse/format mismatch.

### Step 3-5: Prompt repair rounds (max 3)
For each round:
1. Edit the active prompt file used by iter01 (usually in session prompts dir, e.g. `prompts/iter01_prompt.txt`, or the custom prompt path in summary `run_meta.custom_system_prompt_file`).
2. Keep edits minimal and tied to observed failure classes.
3. Re-run only failed cases using `run_planning_eval.sh`.

Single case:

```bash
./tools/run_planning_eval.sh --case=<case_id> --mode=live_llm --out=tools/evals/runs/repair_<session_id>_<round>_<case_id>.json --thinking_level=<planner_thinking> --custom_system_prompt_file=<prompt_file>
```

After reruns:
- If all failed cases now pass: stop repair loop early.
- Else: apply another prompt patch and repeat (up to 3 rounds total).

### Step 6: Continue evolution only after repair success
If all previously failed cases pass after repair rounds, run one more single self-evolve iteration with the repaired prompt as the seed/custom prompt.

Use:

```bash
python3 tools/evals/run_self_evolve.py --max-iters 1 --thinking-level <planner_thinking> --optimizer-thinking-level <optimizer_thinking>
```

## Prompt Patch Rules
- Prefer deterministic rules over prose.
- Add explicit tie-breaks for failure pattern (e.g., guaranteed kill > spacing).
- Keep schema instructions unchanged unless schema bug is confirmed.
- Do not add contradictory global heuristics.
- Keep prompt concise; avoid adding long narrative sections.

## Output Format To User
For each round, report:
- prompt changes made (1-3 bullets),
- failed cases before/after,
- cases still failing with short reasons.

Final report:
- `repaired: true|false`
- rounds used: `1-3`
- list of fixed case ids
- list of unresolved case ids
- whether follow-up self-evolve iteration was started.
