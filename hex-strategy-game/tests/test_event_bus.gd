extends RefCounted
## Tests for EventBus: signals exist and can be connected/emitted (avoids UNUSED_SIGNAL regression).

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_show_units_panel_signal_exists(tests) and ok
	ok = _test_show_units_panel_connect_and_emit(tests) and ok
	ok = _test_tile_resource_deplete_requested_signal_exists(tests) and ok
	return ok

static func _test_show_units_panel_signal_exists(tests: Node) -> bool:
	tests._log("test_event_bus: show_units_panel signal exists")
	var list: Array = EventBus.get_signal_list()
	var found := false
	for sig in list:
		if sig["name"] == "show_units_panel":
			found = true
			break
	if not found:
		tests._fail("EventBus should have signal show_units_panel")
		return false
	tests._pass("show_units_panel signal exists")
	return true

static func _test_show_units_panel_connect_and_emit(tests: Node) -> bool:
	tests._log("test_event_bus: show_units_panel can connect and emit")
	var received: Array = []
	var cb := func(units: Array) -> void: received.append(units)
	var err: int = EventBus.show_units_panel.connect(cb)
	if err != OK:
		tests._fail("connect show_units_panel failed: %d" % err)
		return false
	EventBus.show_units_panel.emit([])
	EventBus.show_units_panel.disconnect(cb)
	if received.size() != 1 or received[0].size() != 0:
		tests._fail("emit should have been received once with [], got %s" % received)
		return false
	tests._pass("show_units_panel connect and emit")
	return true

static func _test_tile_resource_deplete_requested_signal_exists(tests: Node) -> bool:
	tests._log("test_event_bus: tile_resource_deplete_requested signal exists")
	var list: Array = EventBus.get_signal_list()
	var found := false
	for sig in list:
		if sig["name"] == "tile_resource_deplete_requested":
			found = true
			break
	if not found:
		tests._fail("EventBus should have signal tile_resource_deplete_requested")
		return false
	tests._pass("tile_resource_deplete_requested signal exists")
	return true
