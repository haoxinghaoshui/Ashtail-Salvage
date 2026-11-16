extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for fixture in [[&"Normal", 2.0, 0], [&"Chest", 3.0, 0], [&"Normal", 2.0 / 1.3, 30]]:
		var r := _runtime()
		var c: RunContext = r.context
		c.truth_map.set_room_type(Vector2i(1, 1), fixture[0])
		c.current_room_type = fixture[0]
		if int(fixture[2]) > 0:
			c.active_talent_effects = [{"talent_id": "z2_talent_12", "effect_kind": "search_speed_percent", "effect_amount": 10, "effect_params": {}}, {"talent_id": "z2_talent_16", "effect_kind": "search_speed_percent", "effect_amount": 20, "effect_params": {}}]
		var started: Dictionary = r.command_bus.dispatch(&"search_current_room", {"action_id": "search-start"})
		_check(started.get("ok", false), "search begins through player command")
		_check(not c.searched_cells.has("1,1") and c.asset_ledger.item_instances.is_empty(), "no reward before full search")
		if not c.z1_event_flags.has("z2_search"):
			_check(false, "missing durable search state")
			_release(r)
			continue
		var state: Dictionary = c.z1_event_flags.z2_search.rooms["1,1"]
		_check(is_equal_approx(float(state.duration_seconds), float(fixture[1])), "confirmed base time and additive talent speed")
		for tick in range(3):
			r.advance_idle_frame(0.25)
		var elapsed := float(c.z1_event_flags.z2_search.rooms["1,1"].elapsed_seconds)
		r.command_bus.dispatch(&"search_current_room", {"action_id": "repeat-search"})
		_check(c.z1_event_flags.z2_search.rooms["1,1"].elapsed_seconds == elapsed, "repeat interaction keeps progress")
		var saved := r.capture_authoritative_state()
		var resumed := Runtime.new()
		_check(resumed.install_authoritative_state(saved).get("ok", false), "saved progress restores")
		resumed.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
		_check(resumed.context.z1_event_flags.z2_search.rooms["1,1"].elapsed_seconds == elapsed, "restart applies no offline time")
		var steps := ceili((float(fixture[1]) - elapsed) * 60.0)
		for tick in range(maxi(0, steps - 1)):
			resumed.advance_idle_frame(1.0 / 60.0)
		_check(not resumed.context.searched_cells.has("1,1"), "last unfinished tick grants nothing")
		var published: Array[Dictionary] = []
		resumed.command_bus.state_changed.connect(func(snapshot: Dictionary) -> void: published.append(snapshot.duplicate(true)))
		var before_final: Dictionary = resumed.capture_authoritative_state()
		resumed.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": false, "reason": "search_save_cut"}
		var failed: Dictionary = resumed.advance_idle_frame(1.0 / 60.0)
		_check(not failed.get("ok", false) and published.is_empty(), "failed completion publishes no world reward")
		_check(resumed.capture_authoritative_state() == before_final, "failed completion restores full search, items and random state")
		resumed.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
		_check(resumed.retry_persistence().get("ok", false), "save retry restores permission to finish searching")
		resumed.advance_idle_frame(1.0 / 60.0)
		_check(resumed.context.searched_cells.has("1,1"), "completion and actual reward commit together")
		_check(published.size() == 1 and published[0].get("_change_scope") == &"all", "completed search publishes one full world update")
		if published.size() == 1:
			_check(published[0].get("search_state_data", {}).get("searched", false), "published state exposes completed search")
			_check(published[0].get("room_floor_items", []) == resumed.context.get_status_snapshot().room_floor_items, "published world contents match committed ledger")
		var amount: int = resumed.context.asset_ledger.get_currency(&"black_coin")
		var items: Dictionary = resumed.context.asset_ledger.item_instances.duplicate(true)
		resumed.command_bus.dispatch(&"search_current_room", {})
		resumed.advance_idle_frame(0.25)
		_check(resumed.context.asset_ledger.get_currency(&"black_coin") == amount and resumed.context.asset_ledger.item_instances == items, "completed room cannot grant twice")
		_release(resumed)
		_release(r)
	_test_pending_chest_view()
	for failure in failures:
		print("Z2_SEARCH_INTEGRATION_FAIL " + failure)
	print("Z2_SEARCH_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_pending_chest_view() -> void:
	var r := _runtime()
	var c: RunContext = r.context
	c.truth_map.set_room_type(Vector2i(1, 1), &"Chest")
	c.current_room_type = &"Chest"
	var view := preload("res://scripts/gameplay/runtime/g41_room_runtime_view.gd").new()
	root.add_child(view)
	view.apply_chest_search_result({"ok": true, "phase": "searching"}, c.get_status_snapshot())
	_check(view.chest != null and not view.chest.is_opened(), "accepting timed search never opens the chest early")
	c.searched_cells["1,1"] = true
	view.apply_chest_search_result({"ok": true}, c.get_status_snapshot())
	_check(view.chest.is_opened(), "committed completion opens the chest presentation")
	view.free()
	_release(r)

func _runtime() -> RunRuntimeController:
	var r := Runtime.new()
	r.command_bus.dispatch(&"start_demo_run", {})
	var c: RunContext = r.context
	c.run_start_config["profile_fields"] = {"ruleset_id": "z2", "z2_progression_version": 1, "content_eligibility": Eligibility.freeze_profile({"profile_level": 30})}
	c.profile_fields = c.run_start_config.profile_fields.duplicate(true)
	c.run_start_config["map_config_id"] = "classic_13x13_normal"
	c.asset_ledger.setup({"run_id": str(c.run_id), "profile_fields": c.profile_fields})
	c.player_pos = Vector2i(1, 1)
	c.current_pos = c.player_pos
	c.intel_map.reveal_cell(c.player_pos, c.truth_map)
	c.visited_cells["1,1"] = true
	c.explored_cells["1,1"] = true
	c.current_adjacent_mines = 0
	r.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	return r

func _release(r) -> void:
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
