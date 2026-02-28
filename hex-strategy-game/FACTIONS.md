# Factions

Units belong to a **faction** (see `UnitDefinition.Faction`). Faction is used for identity and future rules (e.g. same-faction buffs, faction-specific tech). Combat and fog still use **group** membership (which group node the unit is under); faction can mirror or extend that.

---

## Zerg

**Units:** Zergling, Baneling  
**Faction value:** `UnitDefinition.Faction.Zerg` (1)

### Style of play

- **Speed and first strike:** Zerglings use **Fast Move** and **Fast Attack** (passive). They act early in the turn order (fast move → fast attack before normal move/attack), so they can close in and hit before slower units.
- **No energy, no range:** No energy bar. Zergling has no targeted ability—only move, rest, and a **self-target passive attack** that hits adjacent enemies. Relies on positioning and numbers.
- **Swarm and surround:** Many cheap units (Zerglings) that move and attack first, then a **Baneling** that can **Explode** (area-adjacent, slow attack phase). Baneling is a one-shot: move in, then explode for 2 damage in an area and die (self_damage). Encourages packing enemies for multi-hit or using the baneling to clear/clutch.
- **Summary:** Fast, aggressive, positional. Use fast phase to engage; use baneling for burst and area denial. No sustain or long-range; win by getting on top of the enemy and trading efficiently.

---

## Terran

**Units:** Marine, Scout  
**Faction value:** `UnitDefinition.Faction.Terran` (2)

### Style of play

- **Range and sight:** Marine has **Attack** (1 range, AoE in one direction) and **Rest** to regen **energy**; **sight_range 2** for fog. Scout has **Shoot** (ray 2–3 range), **Recruit**, **Rest**, and **sight_range 3**. Terran can see and shoot from a distance.
- **Resource management:** Both use **energy** for main attacks (marine 1 per Attack, scout 2 per Shoot). **Rest** (reload) gives energy back. Decisions are move vs shoot vs rest to keep pressure or save for key shots.
- **Phased pressure:** Marine’s passive is **normal attack phase** (attack_passive_normal), so it shoots in the main attack phase after moves. Scout has no passive—only planned actions. Terran controls when to commit attacks and when to reposition or rest.
- **Summary:** Ranged, vision-based, energy-limited. Hold sight lines, manage energy with Rest, and use range to punish Zerg that overextends. Marine for front-line AoE and vision; Scout for long-range picks plus village recruitment.

---

## Recommended new units (design)

**Design goal:** Zerg defends until large enough, then attacks; Terran pokes and prevents Zerg from snowballing. Zerg can have *more* units than Terran, but the game must stay fast (no planning 15 units every turn).

### Zerg (defend → swell → push)

| Unit | Role | Why it fits |
|------|------|-------------|
| **Overlord** | No combat, provides **supply** (increases Zerg’s unit cap). Optional: gives sight in a small area. | Gives Terran a poke target: kill Overlords to cap Zerg’s army size. Zerg must defend Overlords while building up. Naturally limits total Zerg count via supply. |
| **Roach** or **Hydralisk** | **Roach:** Tanky, 1-range, slow move. **Hydra:** Squishy, 2-range, normal move. | Something that can hold a line and hit back at poking Marines without dying in one shot. Roach = “defend until we push”; Hydra = “punish Terran that steps into range.” |
| **Queen** or **Spine Crawler** | **Queen:** Low mobility, heals/boosts nearby Zerg or “spawns” (grants a new unit slot after N turns). **Spine:** Static, 1–2 range, high HP. | Defensive anchor so Zerg has a reason to stay in place and grow instead of running out. Queen = growth; Spine = safe zone. |

**Suggested first add:** **Overlord** (supply + anti-snowball) and **Roach** (defensive backbone).

### Terran (poke, deny snowball)

| Unit | Role | Why it fits |
|------|------|-------------|
| **Medic** or **SCV** | Heals adjacent friendly units (energy or cooldown). | Keeps Marines/Scouts alive during pokes so Terran doesn’t lose the attrition war. Enables “poke, take a hit, back off, heal.” |
| **Siege Tank** or **Widow Mine** | Long range and/or area damage; punishes clumped Zerg. | “Don’t ball up or you get sieged.” Makes Zerg spread or commit, and gives Terran a way to threaten the backline (Overlords, Queen) without walking into the swarm. |
| **Reaper** or **Hellion** | Fast move, good vs light (Zerglings). Can poke and retreat. | Harass: kill Overlords or stray Zerglings to delay Zerg’s swell. Fits “poke and prevent snowball” directly. |

**Suggested first add:** **Medic** (sustain for poking) and **Siege Tank** or **Reaper** (deny clumping / harass).

---

## Anti-snowball: keeping Zerg “many units” without slowing the game

So Zerg can have more units than Terran, but planning doesn’t scale with 15 clicks per turn.

### 1. Supply cap (recommended)

- Each faction has a **supply limit** (e.g. 12 or 16).
- Every unit costs supply (Zergling 1, Baneling 1, Roach 2, Overlord 0 or 1, Marine 1, Scout 2, etc.).
- **Overlords** increase Zerg’s *max* supply (e.g. +4 per Overlord). No Overlord = low cap = can’t snowball.
- Terran’s cap can be lower or same; they have fewer, heavier units.
- **Effect:** Zerg’s *total* unit count is capped by supply; killing Overlords keeps that cap low so “large enough to attack” is a real threshold Terran can delay.

### 2. Squads / batch planning (optional)

- Allow “plan for all units of type X” (e.g. “all Zerglings move here” or “all Zerglings attack”).
- Or: only the first N units (e.g. 4) per side get a *chosen* plan; the rest run a **default** (e.g. “hold,” “attack nearest,” “follow leader”).
- **Effect:** Player makes a few key decisions; the rest of the swarm behaves in a predictable way so turn length doesn’t grow with Zerg count.

### 3. Default orders for “extra” units

- When Zerg has more units than a **planning cap** (e.g. 5), only 5 get manual plans; the rest use a **default order** (e.g. “hold position,” “attack move toward enemy,” or “follow unit X”).
- **Effect:** You still *have* more Zerg units (and they move/attack), but you don’t plan every one. Combines well with supply cap so the “overflow” isn’t huge.

### 4. Wave-based or spawn-limited Zerg (optional)

- Zerg units enter the map over time (e.g. from a building or timer), not all at once.
- **Effect:** Max Zerg on the field at once is limited (e.g. 6–8), so turn length is bounded even if “total Zerg produced” is high.

**Practical combo:** **Supply cap + Overlord** for Zerg (hard limit + Terran can poke Overlords), and either **planning cap + default orders** or **squads** so planning stays fast when Zerg has 6–8 units.
