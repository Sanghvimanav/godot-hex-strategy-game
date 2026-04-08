# LLM opponent — implementation tasks

Parent spec: [`llm-self-learning-ai.md`](./llm-self-learning-ai.md).

This file is phased so each phase is shippable as a small PR or milestone. **Phase 1** is foundation only: settings, HTTP client, timeouts, and a manual smoke path. It does **not** wire the battle loop yet.

---

## Phase 1 — Foundation (BYOK + API client + timeouts)

**Goal:** Persist provider settings under `user://`, call **OpenAI `POST /v1/chat/completions` only** for v1 (custom base URL still OK; path stays `.../chat/completions`), apply **§2.3** timeouts, support **aborting** an in-flight request, and prove connectivity from the **scenario picker** panel—without changing AI planning in battle.

### 1.1 Settings model and persistence

- [x] Add a small module (e.g. `res://src/llm_ai/llm_settings.gd` as `RefCounted` or autoload) that holds:
  - **API base URL** (default `https://api.openai.com/v1` or empty = default)
  - **Model id** (string, e.g. `gpt-4o-mini`)
  - **API key** (string; never log in full—see spec §12)
- [x] Persist to `user://` (e.g. `ConfigFile` → `user://llm_ai_settings.cfg`, or a dedicated `.save` resource). Load on startup, save on change. Ship an **example** template at `res://src/llm_ai/llm_ai_settings.example.cfg` (no secrets; see repo file) for documentation or manual copy if needed.
- [x] Expose **has_configured_key(): bool** (or similar) for later gating of LLM vs classic AI.

### 1.2 Minimal settings UI (**scenario picker panel**)

- [x] Add a **collapsible or secondary panel** on **`res://src/battle/scenario_picker.tscn`** (and wire in `scenario_picker.gd`) with: base URL line edit, model line edit, API key line edit (secret), **Save**, and **Test API** (for §1.5). Keep layout consistent with existing `panel/margin/vbox` hierarchy (`scenario_picker.gd` uses `@onready` paths under `$panel/...`).
- [x] Show a short hint: keys stay **local** under `user://`, not cloud-synced (per spec §2.1).

### 1.3 HTTP client wrapper (OpenAI-compatible)

- [x] Implement a dedicated class (e.g. `LlmHttpClient` extends `RefCounted`) that:
  - Builds `POST` to `{base}/chat/completions` with `Authorization: Bearer <key>` and `Content-Type: application/json`.
  - Accepts **system + user** strings (or messages array) and returns **raw body string** + status code for the caller to parse.
  - Applies **§2.3** defaults: **connect timeout 15 s**, **read timeout 60 s** for the **planning** profile; expose a second profile or parameter for **post-game** (15 s / 45 s) even if Phase 1 only uses one path in tests.
- [x] Use Godot’s **`HTTPRequest`** (or `HTTPClient` on a worker thread if you hit blocking issues). Document chosen approach in a one-line class doc comment.
- [x] On failure (timeout, non-2xx, parse error), return a structured error **without** embedding the raw API key in error strings.

### 1.4 Request cancellation (for later battle integration)

- [x] Ensure the wrapper can **cancel** the active request (e.g. `HTTPRequest.cancel_request()` or equivalent) so Phase 2 can abort when the player executes before the LLM returns (spec §2.1).
- [x] Add a **request generation id** or `cancelled` flag so a late callback does not mutate state after cancel.

### 1.5 Smoke / sanity check

- [x] Add a **“Test API”** button (or headless test scene) that sends a minimal chat completion (e.g. user message `"ping"`), expects HTTP 200, and shows success/failure in UI or `print`—enough to validate BYOK before battle work.
- [ ] Optional: add a **godot headless** test that mocks HTTP if you already have patterns for that; otherwise skip until Phase 2.

### 1.6 Done criteria for Phase 1

- [x] With a valid key, smoke test returns 200 and assistant content.
- [x] With no key or wrong key, user sees a clear error path (no crash, no key in logs).
- [x] Timeouts match **§2.3** (or are centralized constants named in code).
- [x] Cancel path exists and is callable without battle wiring.

---

## Phase 2 — Battle planning integration (LLM + validator + fallback + UX)

**Goal:** In **single-player** battles, when BYOK is configured (`LlmAiSettings.has_configured_key()`), **kick off one async planning LLM call per planning phase** at `_begin_planning` (after prior execution), build a **snapshot + enumerated legal options** for **AI units only** (no human `planned_action`, **AI fog** per spec §5.4), parse **`actions[]` JSON** from the model, **validate** against legal sets, write **`planned_action`** on AI units (or fall back to `planning_ai.gd`), surface **progress + in-game messages**, and **abort** in-flight LLM if the player **executes first**. **Out of scope for Phase 2:** `user://ai_learnings/` + Markdown ingest (Phase 3), post-game LLM (Phase 4), rules digest / full unit cheat sheet automation (stub text is OK).

**Depends on:** Phase 1 (`LlmAiSettings`, `LlmOpenAiClient`, `HTTPRequest` pattern).

### 2.1 Gating and battle entry

- [x] **Single-player only:** Do not enable LLM planning in multiplayer / host / join paths (spec §2.1). Gate on `MultiplayerState` or equivalent “local SP battle” detection used elsewhere.
- [x] **LLM enabled when:** `LlmAiSettings.has_configured_key()` and (optional) a **per-run toggle** or scenario flag if you want “classic AI only” without clearing the key — if omitted, default to **use LLM whenever key exists** for SP.
- [x] **Classic path:** If no key or LLM disabled, keep current `planning_ai.gd` behavior unchanged for AI turns.

### 2.2 Snapshot + legal options (authoritative)

- [x] Add a module (e.g. `res://src/llm_ai/llm_planning_snapshot.gd`) that, given `UnitsContainer` / battle context at planning start, produces a **Dictionary** (JSON-serializable) containing:
  - Turn number, scenario id if available, **rules_digest** string (stub `v1` until Phase 5).
  - **Per AI unit** (active units in AI groups): `unit_id`, type/def id, cell, health, energy, relevant status — **no** opponent `planned_action` fields anywhere (spec §5.4).
- [x] **Fog:** Serialize **AI-visible** units/tiles only; reuse existing fog / visibility helpers (`hex_map.refresh_fog`, visibility queries) so the model is not omniscient (spec §2.1, §5.4).
- [x] For each AI unit, call the same **legal-options** path as `planning_ai.gd` (`_collect_all_options` / `ActionCollection.get_options_for_action_key`) and attach a **numbered list** of options: each option includes `action_key`, serialized `path` / `end_point` in `[x,y]` form, and a **stable option index** for the model to pick (recommended) or require exact coordinates that the validator can match back to a legal `ActionInstance`.

### 2.3 Prompt assembly (minimal v1)

- [x] **System message:** Role, “respond with **only** a JSON object” matching spec §6 (`reasoning_summary`, `actions`, optional `meta`), and constraints: one entry per required `unit_id`, pick **only** from provided legal option lists (or indices).
- [x] **User message:** Stringify the snapshot + legal options (compact JSON text). **Stub** `rules_digest` paragraph and **stub** unit-type cheat sheet (Phase 5 can replace with generated content).
- [x] **Learnings:** Phase 3 injects `prior_learnings` via `llm_learnings_ingest.gd` (placeholder when unknown / empty).

### 2.4 Model call + JSON parse

- [x] Extend or wrap `LlmOpenAiClient` so planning can send **`messages`** = `[{role: system, ...}, {role: user, ...}]` and receive assistant **text** parsed as JSON (use `JSON.parse_string` on trimmed content; strip markdown fences if the model wraps JSON).
- [x] On **HTTP / parse / schema** failure, treat as **whole-call failure** (spec §4).

### 2.5 Validator + application to units

- [x] Map each JSON `actions[]` entry to engine types: resolve chosen legal option to **`ActionInstance`** + `is_move` matching what `units.gd` expects when storing `planned_action`.
- [x] **Validate:** every field matches one enumerated option for that `unit_id`; `path`/`end_point` consistent with `ActionInstance` construction.
- [x] **Partial success:** valid units get LLM actions; invalid/missing units get `PlanningAI.pick_action` (spec §2.1). Record that partial fallback occurred for messaging.
- [x] **Whole failure:** all AI units get `PlanningAI.pick_action`.

### 2.6 Wiring into planning flow (`units.gd` / battle)

- [x] On **`_begin_planning`** (or equivalent single entry when phase becomes PLANNING), after clearing prior plans: if SP + LLM enabled, **start async** planning routine (don’t block `_ready` of planning UI).
- [x] Ensure **`HTTPRequest`** exists for battle (child of battle scene or autoload singleton dedicated to LLM). Reuse one node; no parallel overlapping planning calls (queue or ignore if re-entrant).
- [x] When LLM completes successfully, assign **`planned_action`** on each AI unit **before** execute, matching how human planning works.
- [x] **Match flag:** Set a **boolean or counter** on the battle / `UnitsContainer` when **≥1** AI action this turn came from validated LLM output (for Phase 4 post-game LLM gate).

### 2.7 Execute-before-LLM-returns + cancel

- [x] When the player triggers **execute turn** (or submits actions) while planning LLM is in flight: call **`LlmOpenAiClient.cancel_inflight(http)`**, discard LLM result for that turn, fill AI with **`planning_ai.gd`**, show **in-game message** (spec §2.1).

### 2.8 Player-visible fallback + progress (§8.1)

- [x] **Progress states** on battle UI: queued → requesting → waiting on model → parsing/validating → ready (or classic). Reuse patterns from scenario picker status text or a small label near the turn button.
- [x] **Messages:** distinct copy for no key, timeout, HTTP error, parse error, **partial** fallback, **whole-side** classic fallback — **never silent** (spec §2.1).

### 2.9 Tests and verification

- [x] **Headless or unit tests** where feasible: JSON parser + validator with **mock** legal-option tables; no live API in CI.
- [ ] **Manual checklist:** SP battle with key → AI plans appear; disconnect network → classic + message; execute quickly → cancel path + classic.
- [x] Run full project test suite before PR; fix or file any **pre-existing** failures separately.

### 2.10 Done criteria for Phase 2

- [x] SP with valid key: AI units receive **`planned_action`** from LLM when the call succeeds within timeout.
- [x] Invalid JSON / bad actions: **no crash**; classic fallback path works.
- [x] Human’s in-progress plans are **not** in the model prompt (spot-check logging in dev build only, redact secrets).
- [x] Execute-early cancels LLM and still resolves the turn.
- [x] Match-level “LLM used this match” flag is available for Phase 4 (post-game LLM).

---

## Phase 3 — `ai_learnings` + Markdown ingestion for planner (**no** post-game LLM)

**Goal:** Persist and read learnings under **`user://ai_learnings/`** per spec §7.2–§7.3 layout; implement **§7.7** ingestion (scan Markdown, canonical `##` headings, bounded bullets); **inject** the assembled block into the **planning** prompt (replacing Phase 2’s empty stub). Users can **author or edit** `.md` files by hand before any automated writer exists.

**Rationale (order):** Shipping storage + parser + planner injection first lets players tune behavior via files immediately; the **post-game LLM** (Phase 4) only automates appending sessions later.

**Depends on:** Phase 2 (planning call + `LlmPlanningPrompts` / snapshot).

**Out of scope for Phase 3:** Post-match LLM call, automatic session append from match results, code-written stubs at match end (Phase 4).

### 3.1 Directory and file contract

- [x] Ensure **`user://ai_learnings/`** exists when needed; document in spec or a one-line README under `src/llm_ai/` if useful.
- [x] Define how session files are named (e.g. `YYYY-MM-DD_session.md` or `session_*.md`) and that **§7.3** headings are **verbatim** for the parser (see `llm-self-learning-ai.md` §7.3 / §7.7).
- [x] Optional: ship a **repo example** at `res://src/llm_ai/ai_learnings.example.md` (no secrets) for copy-paste into `user://ai_learnings/`.

### 3.2 Parser (§7.7)

- [x] Module (e.g. `llm_learnings_ingest.gd`) that scans `user://ai_learnings/**/*.md` (or agreed glob), extracts **`## Learnings`**, **`## Contradictions`**, **`## Experiments`** (and optional **`## Result`**, **`## Metadata`** if in spec), bullet lines only under each section until next `##`.
- [x] **Robustness:** Missing section → empty; malformed file → log warning, skip file or section; no crash.
- [x] **Caps:** Respect §7.4 token/line budgets for the string passed into the planner.

### 3.3 Planner wiring

- [x] Replace Phase 2 placeholder learnings text with **parser output** (or “(no prior learnings)” when nothing on disk / all empty).
- [x] Cache or reload policy: e.g. reload when entering planning phase or when settings change (keep simple for v1).

### 3.4 Age-out / recency (minimal v1)

- [x] Prefer last **K** sessions or rolling window per spec §7.7; document constants in code.

### 3.5 Tests

- [x] Headless tests: golden Markdown → expected extracted block; missing headings; garbage file.

### 3.6 Done criteria for Phase 3

- [x] With hand-authored Markdown under `user://ai_learnings/`, planning prompt includes injected learnings; with no files, behavior matches Phase 2 stub.
- [x] Post-game LLM **not** required for this milestone.

---

## Phase 4 — Post-game LLM + session stubs

**Goal:** After match end, **§7.5** flow: match summarizer input, **optional** post-game `chat/completions` when **`match_had_llm_validated_plan`** (or equivalent) is true; append **§7.3** Markdown or write **stubs** when skipped (classic-only) or on API failure. Complements Phase 3: files can be **fully manual** until Phase 4, then **partially auto**.

**Depends on:** Phase 2 (flag), Phase 3 (directory + heading contract + parser expectations aligned).

### 4.1 (outline — expand when implementing)

- [x] Gate post-game API on “≥1 validated LLM-planned action this match”; else stub only (`skipped_no_llm_plays` or per spec).
- [x] On success/failure, append or update under `user://ai_learnings/` per §7.3.
- [x] Player-visible message when post-game call skipped or fails (per §12).
- [x] **End game** (single-player): button on battle UI captures match state, returns to scenario picker, runs post-game pipeline (async on picker).

---

## Phase 5 — Player review, rules digest, polish

**Goal:** Player-facing **review / reset / export** of learnings, versioned **rules digest** + unit cheat sheet from data where applicable, presets, polish + tests per spec §13.

---

## Decisions (locked)

| Topic | Choice |
|--------|--------|
| Settings UI | **Panel on scenario picker** (`scenario_picker.tscn` / `scenario_picker.gd`) |
| v1 API | **OpenAI-compatible `POST {base}/chat/completions` only** |
| Example file in repo | **Yes** — `src/llm_ai/llm_ai_settings.example.cfg` (no real secrets) |
