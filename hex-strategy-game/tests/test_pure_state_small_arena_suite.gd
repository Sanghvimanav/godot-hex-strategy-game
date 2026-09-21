extends RefCounted

const PureStateSmallArenaSuite = preload("res://src/simulation/pure_state_small_arena_suite.gd")


static func run_all(tests: Node) -> bool:
    var ok := true
    ok = _test_contract_and_distribution(tests) and ok
    ok = _test_seeded_layouts_are_reproducible_and_varied(tests) and ok
    return ok


static func _test_contract_and_distribution(tests: Node) -> bool:
    tests._log("test_pure_state_small_arena_suite: radius-one Marine/Zergling contract")
    var matchup_counts := {"3v3": 0, "2v2": 0, "3v2": 0, "2v3": 0}
    for seed in range(1000, 1200):
        var state := PureStateSmallArenaSuite.build_state(seed)
        if int(state.get("hex_radius", 0)) != 1:
            tests._fail("small arena must always use radius one")
            return false
        if bool(state.get("command_hexes_enabled", false)):
            tests._fail("small arena must not enable command objectives")
            return false
        var meta: Dictionary = state.get("small_arena", {})
        var matchup := str(meta.get("matchup", ""))
        if not matchup_counts.has(matchup):
            tests._fail("unexpected matchup %s" % matchup)
            return false
        matchup_counts[matchup] = int(matchup_counts[matchup]) + 1

        var occupied := {}
        for group_variant in state.get("groups", []):
            if not (group_variant is Dictionary):
                return false
            var group: Dictionary = group_variant
            var expected_path := PureStateSmallArenaSuite.MARINE_PATH if str(group.get("name", "")) == "terran" else PureStateSmallArenaSuite.ZERGLING_PATH
            for unit_variant in group.get("units", []):
                if not (unit_variant is Dictionary):
                    return false
                var unit: Dictionary = unit_variant
                if str(unit.get("def_path", "")) != expected_path:
                    tests._fail("small arena introduced a non-Marine/Zergling unit")
                    return false
                var cell: Array = unit.get("cell", [])
                if cell.size() < 2:
                    tests._fail("small arena unit is missing a mapped hex")
                    return false
                var q := int(cell[0])
                var r := int(cell[1])
                var s := -q - r
                if maxi(abs(q), maxi(abs(r), abs(s))) > 1:
                    tests._fail("small arena unit escaped radius one: %s" % str(cell))
                    return false
                var key := "%d,%d" % [q, r]
                if occupied.has(key):
                    tests._fail("small arena starts should not overlap units: %s" % key)
                    return false
                occupied[key] = true

    if int(matchup_counts["3v3"]) != 160:
        tests._fail("expected exactly 80%% 3v3 over a complete 200-seed window, got %s" % str(matchup_counts))
        return false
    tests._pass("small arena is radius one, Marine/Zergling only, and 80% 3v3")
    return true


static func _test_seeded_layouts_are_reproducible_and_varied(tests: Node) -> bool:
    tests._log("test_pure_state_small_arena_suite: seeded formation jitter")
    var first := PureStateSmallArenaSuite.build_state(424242)
    var again := PureStateSmallArenaSuite.build_state(424242)
    if first != again:
        tests._fail("same small-arena seed must reproduce exactly")
        return false

    var signatures := {}
    for seed in range(2000, 2200):
        var state := PureStateSmallArenaSuite.build_state(seed)
        signatures[PureStateSmallArenaSuite.layout_signature(state)] = true
    if signatures.size() < 60:
        tests._fail("small-arena starts are not varied enough: only %d layouts" % signatures.size())
        return false
    tests._pass("small arena produces many nearby deterministic starting formations")
    return true
