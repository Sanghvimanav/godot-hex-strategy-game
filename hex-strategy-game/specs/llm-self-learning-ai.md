# Spec: Self-Learning LLM Opponent

## 1. Purpose

Define a **self-learning AI opponent** for the hex strategy game that:

- Chooses **one planned action per active unit** each planning phase using an **LLM** (plus structured game state).
- **Persists distilled learnings** after each completed match so future sessions can improve behavior.
- Balances **winning** with **player enjoyment**, and supports **dialing strength down** when the AI becomes too strong.

This document is product and architecture guidance for implementation; it does not prescribe a specific vendor, model, or hosting.

---

## 2. Scope

### 2.1 Decisions (recorded)

| Decision | Answer | Notes |
|----------|--------|--------|
| **V1: where LLM AI runs** | **Single-player only** | Human vs AI opponent in local/single-player battles. No LLM-driven seat in hosted or join multiplayer for v1. Keeps fairness, latency, and “who runs the model” simple. The same action contract and validator design still apply if multiplayer AI is added later. |
| **V1: learnings scope** | **Global (one pool)** | One shared Markdown store for the install / OS user (e.g. `user://ai_learnings/`). All local play sessions contribute to the same journal. **Per-profile** split is deferred; if added later, migrate to `user://profiles/<id>/ai_learnings/` without changing the learning file format. |
| **V1: learnings storage** | **Local files only** | Markdown (and optional small index files) on disk under `user://`. **No cloud sync, upload, or account** in v1. If optional sync is added later, prefer **opt-in**, preserve the same on-disk format as source of truth, and define conflict/merge then. |
| **V1: who writes learnings** | **LLM (second call post-match), when applicable** | After matches where the AI used the **planning LLM at least once** (at least one planning phase produced **any** validated LLM-chosen action, even if other units fell back that turn), run the **post-game** LLM to distill Markdown (or JSON → Markdown). If the post-game call **fails**, **code** still appends a **stub** (`learning_summary: unavailable`). See next row for **classic-only** matches. |
| **V1: post-game when no LLM play** | **Skip post-game LLM** | If **no** planning phase in the match used a successful LLM-backed action (entire match was classic AI — no key, offline, or every phase whole-side fallback), **do not** call the post-game LLM (saves cost; nothing LLM-specific to learn). **Code** still writes a **stub session entry** noting outcome, scenario, timestamp, and e.g. `learning_summary: skipped_no_llm_plays` so the journal records the game. |
| **V1: learnings size & evolution** | **Brief + contradiction-aware** | Entries stay **short** by spec (hard caps on bullets and length; see §7) so files **do not grow without bound**. The post-game LLM must compare new takeaways to **prior learnings** and record **contradictions** plus **experiments** (what to try next, what observation would settle the conflict). **Planning prompts** include a bounded **open contradictions / active experiments** block so future games **probe** those tensions instead of blindly trusting old bullets. |
| **V1: credentials (experimentation)** | **Bring your own key (BYOK)** | For early experimentation, the developer (or advanced tester) supplies an API key in **local settings** — e.g. **OpenAI / ChatGPT API** (HTTPS to the vendor). **Never commit keys** to the repo. Store only under `user://` (or OS secret store if you add it later). **Inference location** for this path: see §2.2 — the **model runs on the API provider’s servers**, not inside Godot. |
| **V1: fallback UX** | **In-game messages (no silent classic AI)** | Whenever the opponent uses **`planning_ai.gd`** (or equivalent) because the LLM path is unavailable, the player must see a **short, clear UI message** explaining why — e.g. missing API key, no network, request **timeout**, auth error, or post-game learning call skipped. Do **not** fall back silently. Optional persistent label during the match (e.g. “Classic AI”) is acceptable if paired with an initial explanation. See §12. |
| **V1: planning API granularity** | **One LLM call per planning phase (all AI units)** | Each time the AI side needs plans for the turn, make **one** HTTPS request whose response JSON includes **`actions[]` for every AI unit** that must act (see §6). Enables joint tactics and lowers latency/cost vs N calls. If the call fails entirely, fall back the **whole side** to classic AI (with message). If the response is **partially invalid**, validate **per unit** and fall back with `planning_ai.gd` only for failed/missing units; message should indicate **partial** fallback if any unit used classic AI. |
| **V1: how planner reads learnings** | **Parse Markdown by fixed headings** | The game **does not** use JSON sidecars or YAML frontmatter as the source of truth for injection. **Godot code** scans session `.md` files under `user://ai_learnings/`, extracts sections under **canonical `##` headings** (§7.7), and builds the bounded text block for the planning prompt. **Tradeoff:** sensitive to LLM/player edits that break headings — mitigate with **strict post-game prompt**, **tests**, and **graceful empty fallback** if a section is missing. |
| **V1: when planning LLM runs** | **Start of planning, right after prior turn executes** | When the battle returns to **planning** for the new turn (execution finished, prior plans cleared — see `units.gd` flow), **kick off the planning LLM asynchronously** so the **human can think in parallel** while the request runs. Still **one** successful planning LLM outcome per turn for the AI side unless you add explicit re-prompting later. |
| **V1: snapshot must not leak human next moves** | **Strip opponent in-progress plans** | The serialized prompt for the AI must **never** include the human/player group’s **current-turn** planned actions (in-progress or committed locally before execute). Include only **post-resolution** state: units, map, resources, effects, and **legal moves for AI units**. |
| **V1: fog of war for LLM** | **Same as AI player** | The planning snapshot must respect **fog of war from the AI side’s perspective** — hidden enemy units, tiles, or intel are **omitted or obscured** the same way the live AI opponent would experience them. **No omniscient board** for the model in v1. Optional **debug / cheat** omniscience is out of v1 unless explicitly added as a dev-only toggle. |
| **V1: AI planning progress UI** | **Visible status** | Show **in-game** indicators while the planning LLM runs: e.g. *idle / requesting / waiting on model / parsing / validating / ready* and **classic fallback** if used. Players should always know whether the opponent plan is still computing. |
| **V1: execute before LLM returns** | **Do not block the human** | If the player **ends planning or executes** while the LLM is still in flight or before validation finishes, **abort or ignore** that LLM result for **that** turn and fill the AI with **`planning_ai.gd`**, with the usual **in-game message** (no deadlock on slow APIs). |

**In scope**

- How the AI receives game and unit knowledge.
- The **action submission contract** the LLM must produce (compatible with existing turn execution).
- Post-game **learning artifacts** (Markdown) and **player review**.
- **Bootstrap heuristics** and **enjoyment / difficulty** controls.
- **Single-player** matches where the AI controls the opposing side (and any AI-only groups in those modes).

**Out of scope (for v1 / this spec)**

- Exact prompt wording and token budgets (keys: policy in §2.1 / §2.2 — **no secrets in repo**).
- Training or fine-tuning a custom model (optional future work).
- **Multiplayer LLM opponent** — hosting, joining, or AI filling a human slot; deferred past v1. Revisit fairness, sync, and where inference runs before shipping.
- **Cloud sync / upload of learnings** — v1 is device-local only; see §2.1.

### 2.2 Where inference runs (plain language)

**“Inference”** means *where the neural network actually evaluates your prompt and produces tokens* — not where your game code runs.

| Approach | What happens | Typical v1 fit |
|----------|----------------|----------------|
| **Remote API (BYOK)** | The game sends HTTPS requests **from the player’s machine** to a provider (e.g. OpenAI). The **provider’s servers** run the model; the key bills that account. | **Yes — experimentation default** (§2.1). Game stays thin; needs network; prompts leave the device to the vendor under their policy. |
| **Local model** | A model binary runs **on the same PC** (e.g. Ollama, llama.cpp). No OpenAI key; data stays local; heavier install/GPU. | Optional later; not required for first experiments. |
| **Your own backend** | Game calls **your** server; **your** server holds the key and calls OpenAI (or runs a model). | Future if you want to hide keys from clients or centralize billing — **not** required for dev experimentation. |

**Cursor vs ChatGPT API:** **ChatGPT / OpenAI API** is a documented HTTP API intended for app integrations. **Cursor** is primarily an **IDE**; it is not the standard way to power a shipped Godot client. Use **OpenAI-compatible HTTPS** as the reference integration for experimentation. If you later have a **separate**, documented HTTP API that is explicitly allowed for this use case, treat it as another pluggable **base URL + key** — do not assume a Cursor editor key works as a game backend without checking vendor terms and technical docs.

### 2.3 Default HTTP timeouts (v1)

Use these as **shipping defaults** (constants or config); expose **advanced overrides** in settings later if needed.

| Call | Connect timeout | Read / overall request timeout | Notes |
|------|-----------------|---------------------------------|--------|
| **Planning LLM** (per phase) | **15 s** | **60 s** | Abort → classic AI + message (§2.1). Player may execute first anyway. |
| **Post-game LLM** (per match, when gated on) | **15 s** | **45 s** | Shorter call, smaller payload; failure → stub only. |

**Rationale:** **15 s** connect catches dead networks without waiting forever. **60 s** read covers slow models / large legal-option lists; tune down for snappier fallback if playtests show it’s always fast. **45 s** post-game avoids hanging the end-of-match flow while still allowing a short distill pass.

---

## 3. Relationship to Current Code

Today, rule-based planning lives in `src/battle/ai/planning_ai.gd`. Turn execution expects per-group submitted actions shaped like:

- `unit_id` — stable id for the unit in the current battle state.
- `action_key` — string key for the chosen move or ability (must match game definitions).
- `path` — list of hex cells as `[x, y]` pairs; for move types, conventions match server/core expectations (path plus end cell where required).
- `end_point` — `[x, y]` target cell for the action.

The LLM-backed planner should **emit the same structure** (or a thin translation layer turns LLM output into this structure) so `TurnExecutionCore` / multiplayer submission paths stay unchanged.

---

## 4. High-Level Architecture

1. **State builder** — Serialize the current battle into a **model-safe snapshot**: units (id, type, cell, health, energy, group, key status flags), map/terrain if relevant, turn number, win/loss if terminal, and **legal action summaries** for **AI units only** (see §6). **Omit** the human/opponent group’s **planned_action** / in-progress plans entirely (§2.1). Apply **AI fog-of-war** to hidden intel (§2.1, §5.4).
2. **LLM planner** — **Once per planning phase**, triggered **as planning begins** after the previous turn’s execution (§2.1), **asynchronously**. Sends system + user messages: rules summary, unit cheat sheet, **Markdown-parser** block (§7.7), difficulty/enjoyment knobs, and the snapshot. Receives **one** **structured JSON** response whose `actions[]` lists **one chosen action per AI unit** (§2.1, §6). **Progress** is surfaced in UI (§2.1, §8.1).
3. **Validator** — Validates each submitted action against legal options. **Whole-call failure** (timeout, parse error, empty response): fall back **entire AI side** to `planning_ai.gd` + message. **Partial failure** (some `unit_id`s wrong or illegal): use LLM output for valid units; for each bad/missing unit, fall back to `planning_ai.gd` + **partial** fallback message if any fallback occurred.
4. **Match summarizer (code)** — Builds a **small, structured recap** for the post-game LLM: outcome, scenario/map id, rule digest version, difficulty preset, coarse stats you can compute (e.g. turn count, units lost), optional **tiny** turn highlights from existing recordings — not full raw logs by default.
5. **Learning writer (LLM + code)** — After match end, **code** always records a session row; runs the **post-game LLM** only when the match had **≥1** successful LLM-planned action (§7.1 / §7.5). Otherwise **stub only** (`skipped_no_llm_plays`). On post-game API failure, **stub** + `learning_summary: unavailable`.
6. **Player review** — UI or documented file location so players can read what was recorded (see §8.2).

---

## 5. Knowledge the AI Must Have

### 5.1 Game basics (static, versioned)

Ship a **short rules appendix** (in repo or bundled resource) that the system prompt always includes, with at least:

- Turn flow: planning → execution, simultaneous resolution where applicable.
- Victory / defeat conditions for the modes you support.
- Hex adjacency / range concepts at the level the engine uses.
- Energy, cooldowns, stun, and any effect that blocks actions — summarized so the model does not invent mechanics.

Version this text when rules change (`rules_digest_v1`, etc.) so old learnings can be tagged with the rule version they assumed.

### 5.2 Per-unit-type cheat sheet (static, data-driven)

For each unit definition, provide a **compact capability line** the prompt can include or the model can retrieve:

- Unit name / internal id.
- Move types available (`fast move`, `move`, `slow move`, etc., as the game classifies them).
- Ability keys and **plain-language** effect: damage pattern, heal, spawn, explode conditions, etc.
- Notable constraints (e.g. “only explodes on same tile as enemy”).

Prefer generating this from existing `.tres` / `UnitDefinition` data to avoid drift.

### 5.3 Legal actions (dynamic, authoritative)

The **source of truth** for what a unit can do this turn is the engine: same path as `_collect_all_options` / ability DB. For each unit, pass **enumerated legal options** (action_key + target cells or path hints) rather than asking the model to guess legality from prose alone. The model **chooses among given options** when possible; free-form coordinates are only allowed if the pipeline can validate them.

### 5.4 Information boundary (planning snapshot)

- **No human next-turn intent** — Never serialize the player group’s **current** `planned_action` (or equivalent) into the planning prompt. The AI plans **in parallel** with the human (§2.1); leaking drafts would be unfair and unrealistic.
- **World state only** — After execution, the board reflects resolved outcomes; that (plus AI-legal moves) is the baseline for the next planning LLM call.
- **Fog / hidden units** — **v1:** The snapshot matches **AI fog-of-war** only (§2.1). Do not reveal hidden enemies or tiles to the model. Align serialization with whatever the game already uses for AI visibility (e.g. same rules as `planning_ai.gd` / fog refresh after execution).

---

## 6. LLM Output Format (recommended)

Use **strict JSON** from the model, for example:

```json
{
  "reasoning_summary": "One short paragraph for logs / optional UI.",
  "actions": [
    {
      "unit_id": 12,
      "action_key": "bite",
      "path": [[3, 4], [4, 4]],
      "end_point": [5, 4]
    }
  ],
  "meta": {
    "difficulty_preset": "standard",
    "enjoyment_bias": 0.35
  }
}
```

Rules:

- **v1:** The planner returns this object from **one** API call per **planning phase**, covering **all** AI units that must act in that phase — not one HTTP request per unit (§2.1).
- Exactly **one entry per AI unit** that must act; omit or flag units that should skip only if the rules allow.
- All coordinates must appear in the **legal option list** or pass geometric validation.
- `reasoning_summary` should stay short to control cost; deeper rationale can go to a debug log, not necessarily to the learning file.

---

## 7. Learning Loop (Markdown Persistence)

### 7.1 When to write

Trigger **once per completed game** (win, loss, draw, or forfeit), after final state is known.

- **Always:** persist something (stub or full entry) under `user://ai_learnings/` (§2.1 **V1: post-game when no LLM play**).
- **Post-game LLM:** only if the match had **≥ 1** planning phase with **≥ 1** successfully validated LLM action; otherwise **skip** that API call and write the **no-LLM stub** only.

### 7.2 Where to store

**v1:** Use a **single global** folder under the Godot user data dir, e.g. `user://ai_learnings/` — **must be easy to open in a text editor**. Avoid binary-only stores for the primary artifact. (Do not nest under per-save profiles for v1; see §2.1.)

For development-only inspection, a symlink or documented path under the project is fine; shipped builds should use `user://` so learnings persist across launches.

**v1:** No network persistence for learnings — files stay on the player’s machine unless they manually copy or use OS backup.

### 7.3 File shape

- **Session file** per match: `YYYY-MM-DD_match_<id>.md`, or append sections to a rolling `journal.md` if you prefer fewer files (session files are easier to review).
- Each **full** entry is produced primarily by the **post-game LLM** (see §7.5) and should stay **small**. **Classic-only matches** get a **code-written stub** only (§2.1). For **parser-driven injection** (§2.1, §7.7), full entries **must** use the **exact level-2 headings** below (titles **verbatim**, ASCII — the post-game system prompt enforces this):
  - **`## Metadata`** — Optional if the same fields are code-prefixed above the LLM block; otherwise YAML-like lines or bullets: `date`, `scenario`, `rules_digest`, `difficulty_preset`.
  - **`## Result`** — One line: win / loss / draw from AI perspective.
  - **`## Learnings`** — **2–4** `- ` bullets max, one line each.
  - **`## Contradictions`** — **1–3** `- ` bullets max (A vs B).
  - **`## Experiments`** — **1–2** `- ` bullets max (testable probes; status like `open` / `resolved` can be inline in the bullet).
  - Optional: **`## Validator fallbacks`** — one line or omit.

Keep entries **human-readable**. The **ingestion** layer reads these headings only (§7.7); see §7.4 for caps on how much is injected into the planner.

### 7.4 Growth and caps

- **Per-session cap** — Enforce in prompt and (if needed) post-validate: max **4** learning bullets, max **3** contradiction items, max **2** active experiment lines **per match file section** (tune numbers but keep order-of-magnitude **small**).
- **Repository cap** — Prefer **session files** over one ever-growing file, or run occasional **manual / opt-in “compact journal”** (future) that asks the LLM to merge old sessions into a shorter `distilled_learnings.md`. v1 can ship with **session files only** + **player reset** if size bothers users.
- **Max injected into planner** — Recent learnings **≤ ~1k tokens** (or last **K** sessions’ summaries only); **open contradictions + experiments ≤ ~500 tokens** so planning stays fast and cheap.
- Optionally maintain `learnings_index.md` with **one-line** summaries per session file (index entries must also stay short).

### 7.5 Post-game LLM (v1)

- **Gate:** Run only when **§7.1** says the match had LLM-backed planning at least once. Otherwise **skip** this call entirely; **code** writes the stub (`skipped_no_llm_plays` or equivalent).
- **Inputs:** Match summarizer output; a **trimmed excerpt** of prior learnings (last few sessions or rolling digest), **not** the entire corpus if it exceeds caps.
- **Task:** Append **Markdown** that follows **§7.3** heading contract **exactly** (`## Result`, `## Learnings`, `## Contradictions`, `## Experiments`, …) so the **§7.7** parser can ingest it. v1 does **not** rely on a JSON sidecar for learnings (§2.1). Optional: validate bullet counts in code after append and log a warning if over cap.
- **Failure:** On timeout or error (when the post-game call **was** attempted), **code** appends stub metadata + “`learning_summary: unavailable`” so match history is not lost.

### 7.6 Contradictions and experiments (behavior)

- **Detection** — The post-game prompt instructs the model to **explicitly compare** new conclusions to the provided prior excerpt and list **mismatches** (e.g. “earlier we favored aggression from ahead; this loss suggests turtling was better on this map”).
- **Experiments** — Each contradiction should prefer a **testable** behavioral tweak in **future** planning (not vague advice). The **planner** system prompt states: when **active experiments** apply to the current board state, **satisfy the experiment** when it is **legal and within difficulty/enjoyment constraints** — i.e. **explore** on purpose, not only exploit.
- **Resolution** — A later post-game session marks an experiment **resolved** (with outcome: “A confirmed”, “B confirmed”, “inconclusive”) and **stops** promoting it in the injected block. Unresolved items **age out** after **M** sessions (config) unless refreshed, to avoid stale probes forever.

### 7.7 Markdown ingestion for planner (v1)

- **Source:** Read the **N** most recent session files (or tail sections of `journal.md` if you use one file — then split on a delimiter or repeated session headers; prefer **separate files** for simpler parsing).
- **Headings:** Recognize only **`## `** (level 2) with titles **exactly** `Learnings`, `Contradictions`, `Experiments` (and optionally `Result`, `Metadata`) per §7.3. Matching should be **case-sensitive** on the title word to avoid accidental collisions; strip one space after `#`/`##`.
- **Extraction:** Under each section, collect lines matching `- ` bullets until the next `##` or EOF. Non-bullet prose in those sections is ignored or concatenated as a single item (prefer **bullets only** in prompts to the post-game model).
- **Robustness:** Missing section → treat as **empty** for that category (no crash). Malformed file → log warning, **skip file** or skip section. Player-edited Markdown may break ingestion; **document** that advanced users should keep headings intact.
- **Assembly:** Concatenate excerpts from the last **K** sessions within token caps (§7.4), dedupe or prioritize **open** experiments if you add inline markers later.

---

## 8. Player Review of Learnings

### 8.1 AI planning progress (v1)

During each planning phase, show **clear UI** for opponent plan computation (§2.1): e.g. states *queued → requesting → waiting on model → parsing / validating → ready*, and **classic AI** when falling back. This is separate from the **fallback reason** toasts in §12; progress is **persistent** in the HUD or turn panel until the AI plan is locked or classic path is chosen.

### 8.2 Learnings files

Requirements:

1. **Discoverability** — In-game menu item or settings panel: “View AI learnings” opens the folder or a simple in-game Markdown viewer.
2. **Transparency** — No hidden training data; players see the same Markdown the AI uses (or a sanitized copy if you ever strip PII — unlikely here).
3. **Control** — Allow **delete / reset learnings** and **export** (zip of `.md` files) so players can share or wipe behavior. For v1, reset clears the **global** pool (affects everyone using that machine’s user data for this app).
4. **Privacy** — If you ever log player chat or names, state explicitly what is excluded from learnings; default should be **game state only**. For v1, learnings are **local files** (no cloud); say so in UI if you mention “AI memory.”

---

## 9. Bootstrap Heuristics (Starting Point)

Seed the system prompt (or a `bootstrap_heuristics.md` file) with a few **simple, correct-ish** rules, for example:

- If your side has **more healthy offensive units** (or higher total effective attack threat) than the enemy and you are not critically low on health, **favor pressure and favorable trades** over passive farming.
- If you are **materially behind**, prioritize **preservation**, favorable terrain, and energy-efficient actions until an opening appears.
- Do not waste **high-cost abilities** on **low-value targets** when a cheaper action secures a similar outcome.
- Respect **unit-specific win conditions** (e.g. explode-only when sharing a tile with a high-value target).

These are **defaults**, not laws — the learning journal refines them over time.

---

## 10. Dual Objective: Win + Enjoyable Opponent

### 10.1 Enjoyment dimensions (tunable)

Define explicit knobs (even if v1 is only backend constants):

- **Pacing** — avoid stalling when ahead; avoid hopeless drag when behind (within reason).
- **Variety** — slight randomization among near-equal moves so play feels less robotic.
- **Fairness perception** — avoid exploit loops the player cannot answer; if detected, learnings should add counters.
- **Clarity** — optional post-turn one-liner (off by default) explaining intent for casual modes.

### 10.2 Scoring (conceptual)

Internally you can treat move choice as optimizing a **weighted sum**, e.g. `win_probability_estimate - enjoyment_penalty`, where enjoyment_penalty increases for “miserable” behaviors (infinite kiting, optimal but repetitive lethality). The LLM need not implement math; **prompt instructions + filtering** approximate this.

---

## 11. Difficulty and “Dial Back” When Too Strong

When the AI wins too often or feedback says it’s unfun, operators need **non-code** or **light-config** levers:

| Lever | Effect |
|--------|--------|
| **Difficulty preset** | Alters temperature, max reasoning depth, or how many legal options are shown (e.g. hide top-N best targets). |
| **Enjoyment bias** | Higher value → prompt stresses variety, suboptimal-but-interesting moves, or “give the player a visible out.” |
| **Validator strictness** | Softer validation + fallback could be replaced with “retry once with hint” before fallback — or deliberately **no retry** on lower tiers to humanize mistakes. |
| **Action subset sampling** | Randomly drop the single best legal option from the list before asking the model (strength dial). |
| **Horizon limit** | Provide less lookahead text (fewer enemy intents) on easier settings. |

Expose **one player-facing slider or preset** that maps to a bundle of these settings, and record the preset name in each session Markdown file for reproducibility.

---

## 12. Safety, Cost, and Failure Modes

- **Cost** — Cache static prompts; minimize snapshot size; cap learnings injected. **Planning:** **one** LLM call per **planning phase** for all AI units (§2.1), plus **one** post-game call per match. Keep post-game input/output **small** (§7.4–§7.5).
- **Latency / connectivity** — Async planning with timeout (**§2.3** defaults: 15 s connect, 60 s read for planning); on timeout or transport failure, fall back to `planning_ai.gd` and show an **in-game message** (§2.1, **V1: fallback UX**). Same for **missing or invalid API key** before or during a match. Post-game uses **§2.3** (45 s read).
- **Post-game LLM** — If **skipped** (classic-only match), no API call; stub on disk (§7.5). If **attempted and failed**, stub + `learning_summary: unavailable`; optionally toast: learning summary unavailable. If **attempted and succeeded**, full brief entry per §7.3.
- **Hallucination** — Never trust raw coordinates; always validate against engine-generated legal sets.
- **Cheating / omniscience** — The planning prompt must **not** include the human’s **unsubmitted / in-progress** moves (§2.1, §5.4). Fog and hidden intel follow §5.4. Still avoid inventing facts not in the snapshot. If multiplayer LLM ships later, re-evaluate parity rules.
- **Secrets** — Keys only via BYOK settings + `user://` (or OS keychain). Log and crash reports must **redact** API keys and Authorization headers.

---

## 13. Implementation Checklist (for future PRs)

**Implementation order (see `specs/tasks.md`):** It is valid to ship **`user://ai_learnings/` + §7.7 Markdown ingestion into the planner** before the **post-game LLM**. That way players can create or edit `.md` learnings by hand while the automatic post-match writer is still pending. The normative product behavior in §7.5 (post-game call when applicable) is unchanged; only the **delivery order** of milestones is flexible.

- [ ] Settings UI + persistence for **BYOK** (base URL if needed, model name, API key); HTTPS client for **OpenAI-compatible** chat/completions (experimentation path; see §2.2); apply **§2.3** timeouts (configurable later).
- [ ] **Player-visible fallback** — copy + UI for no key, offline/HTTP errors, planning timeout, and optional “Classic AI” state; no silent fallback (§2.1).
- [ ] Serialized battle snapshot + legal action enumeration for **AI units**; **strip** human group `planned_action`; fog/visibility per §5.4.
- [ ] **Async planning LLM** at **planning phase start** (post-execution); **abort/ignore** in-flight result if player executes first (§2.1); **progress UI** (§8.1).
- [ ] JSON (or equivalent) schema for LLM output; **single** planning-phase request returning `actions[]` for all AI units; validator with **whole-side** vs **per-unit** fallback (§2.1).
- [ ] Match summarizer (compact recap from recordings / end state).
- [ ] **`user://ai_learnings/` + Markdown ingestion** (§7.7): scan `user://ai_learnings/*.md` for `## Learnings` / `## Contradictions` / `## Experiments`; assemble bounded prompt block; **age-out** for stale experiments; tests for missing/malformed sections. **May ship before** post-game LLM so users can hand-edit learnings first.
- [ ] **Post-game LLM** → brief Markdown under `user://ai_learnings/` with **§7.3** headings; **gate** on “≥1 successful LLM-planned action in match”; **skip** post-game API + **stub** when classic-only; failure stub when call errors.
- [ ] Player-facing review / reset / export.
- [ ] Versioned rules digest + unit cheat sheet from data.
- [ ] Bootstrap heuristics file + difficulty / enjoyment preset mapping.
- [ ] Tests: validator edge cases; learning file created on mock game end; optional snapshot golden tests.

---

## 14. Open Questions

All items below were **resolved** for v1; revisit only if product scope changes.

- ~~Should LLM AI be **single-player only** at first?~~ **Resolved:** yes — v1 is single-player only (see §2.1).
- ~~Should learnings be **global** or **per player profile** on the same machine?~~ **Resolved:** **global** for v1 — one shared pool under `user://ai_learnings/` (see §2.1, §7.2). Per-profile is a future option.
- ~~**Cloud sync** of learnings?~~ **Resolved:** **local files to start** — v1 has no cloud sync or upload (see §2.1). Optional opt-in sync remains a **future** consideration and should not block v1 UX or paths.

**Future (not v1):** optional cloud backup/sync, per-profile learnings, multiplayer LLM — decide when those features are scheduled.
