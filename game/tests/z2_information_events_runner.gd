extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
const Hooks = preload("res://scripts/core/run/z2_run_hooks.gd")
var information
var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := "res://scripts/core/run/z2_information_events.gd"
	if not ResourceLoader.exists(path):
		_check(false, "T11 implementation is missing; information services cannot execute")
	else:
		information = load(path)
		_test_information()
		_test_paid_information()
		_test_recon()
		_test_demine()
		_test_shortcut()
		_test_atomic_replay()
		_test_review_boundaries()
		_test_shortcut_risk_atomicity()
	for failure in failures:
		print("Z2_INFORMATION_CASE_FAIL " + failure)
	print("Z2_INFORMATION_EVENTS=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)


func _runtime(pos: Vector2i = Vector2i(3, 3), width: int = 7, height: int = 7):
	var r = Runtime.new()
	r.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	r.command_bus.dispatch(&"start_demo_run", {})
	var c: RunContext = r.context
	c.run_start_config["profile_fields"] = {"ruleset_id": "z2", "z2_progression_version": 1,
		"content_eligibility": Eligibility.freeze_profile({"profile_level": 50})}
	c.profile_fields = c.run_start_config.profile_fields.duplicate(true)
	c.run_start_config["map_config_id"] = "classic_13x13_normal"
	c.run_start_config["difficulty"] = "standard"
	c.width = width
	c.height = height
	c.truth_map.setup_manual_map({"width": width, "height": height, "manual_map": {
		"spawn": pos, "mines": [Vector2i(2, 2), Vector2i(4, 3), Vector2i(0, 0), Vector2i(6, 6)].filter(func(p): return p.x < width and p.y < height),
		"chests": [Vector2i(1, 1), Vector2i(5, 4)].filter(func(p): return p.x < width and p.y < height),
		"exits": [{"pos": Vector2i(width - 1, 0), "exit_id": &"test_exit", "random_exit": true}],
	}})
	c.intel_map.setup(width, height)
	c.visited_cells.clear()
	c.explored_cells.clear()
	c.entered_cells.clear()
	c.interacted_cells.clear()
	c.z1_event_rooms.clear()
	c.z1_event_flags.clear()
	c.z1_event_intel.clear()
	c.asset_ledger.setup({"run_id": str(c.run_id), "backpack_capacity": 100, "equipment_capacity": 100})
	c.asset_ledger.add_currency(&"black_coin", 100, "test_setup")
	c.asset_ledger.sync_compat_fields(c)
	c.pressure = 0
	c.protocol_level = 0
	c.hp = 100
	c.max_hp = 100
	c.shield = 0
	c.mine_immunity = 0
	c.mine_dmg_reduce = 0
	c.protocol_pressure_reduce = 0
	c.vitals_modifiers.clear()
	c.vitals_counters.clear()
	c.run_stats.clear()
	_room(r, pos)
	return r


func _room(r, pos: Vector2i) -> void:
	r.context.player_pos = pos
	r.context.current_pos = pos
	r.context.visited_cells[r.context.cell_key(pos)] = true
	r.context.explored_cells[r.context.cell_key(pos)] = true
	r.context.truth_map.mark_explored(pos)
	r.context.intel_map.reveal_cell(pos, r.context.truth_map)


func _dispose(r) -> void:
	r.checkpoint_writer = Callable()
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)


func _state(r, event: String) -> Dictionary:
	return information.public_state(r.context, r.context.get_current_pos(), event)


func _call(r, event: String, option: String, payload: Dictionary = {}, enter: Callable = Callable(), id: String = "") -> Dictionary:
	var pos: Vector2i = r.context.get_current_pos()
	return r.execute_atomic_operation(&"z2_information", {"event": event, "option": option, "pos": pos, "payload": payload},
		func() -> Dictionary: return information.execute(r.context, pos, event, option, payload, enter), id)


func _prepare(r, event: String) -> bool:
	var result := _call(r, event, "prepare")
	_check(result.get("ok", false), event + ": prepare succeeds: " + str(result.get("reason", "")))
	_check(not result.get("stage_completed", false), event + ": prepare is not a stage")
	return bool(result.get("ok", false))


func _act(r, event: String, option: String, payload: Dictionary = {}, enter: Callable = Callable(), id: String = "") -> Dictionary:
	var request := payload.duplicate(true)
	request["quote_id"] = _state(r, event).get("quote_id", "missing")
	return _call(r, event, option, request, enter, id)


func _black(r) -> int:
	return r.context.asset_ledger.get_currency(&"black_coin")


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _reject(r, event: String, option: String, payload: Dictionary = {}, reason: String = "", enter: Callable = Callable()) -> Dictionary:
	var before: Dictionary = r.capture_authoritative_state()
	var result := _act(r, event, option, payload, enter)
	_check(not result.get("ok", true), event + ": rejection for " + option)
	_check(r.capture_authoritative_state() == before, event + ": rejection restores all state")
	_check(not result.get("stage_completed", false) and result.get("stage_fact", {}).is_empty(), event + ": rejected action has no stage")
	if not reason.is_empty():
		_check(result.get("reason", "") == reason, event + ": rejection reason " + reason + " got " + str(result.get("reason", "")))
	return result


func _intel_only(r, before: Dictionary, target: Vector2i) -> void:
	_check(r.context.visited_cells == before.visited and r.context.explored_cells == before.explored, "intel: no actual visits or exploration")
	_check(r.context.intel_map.mark_map == before.marks, "intel: no manual flags")
	_check(not r.context.intel_map.is_revealed(target), "intel: target is not directly revealed")
	_check(not r.context.truth_map.get_return_eligibility(target, r.context.intel_map).eligible, "intel: target is not a teleport destination")


func _map_before(r) -> Dictionary:
	return {"visited": r.context.visited_cells.duplicate(true), "explored": r.context.explored_cells.duplicate(true), "marks": r.context.intel_map.mark_map.duplicate(true)}


func _test_information() -> void:
	var r = _runtime()
	var before: Dictionary = r.capture_authoritative_state()
	var state := _state(r, "information")
	var choices: Array = information.options(r.context, Vector2i(3, 3), "information")
	_check(state.get("requires_prepare", false) and choices.is_empty(), "information: unprepared projection cannot execute")
	_check(r.capture_authoritative_state() == before, "information: state/options are read-only")
	if not _prepare(r, "z1_event_e01"):
		_dispose(r)
		return
	state = _state(r, "z1_event_e04")
	_check(state == _state(r, "z1_event_e17"), "information: three legacy variants share one state")
	_check(state.get("quote", {}).get("paid_fee_black", -1) == 5, "information: first quote costs 5")
	before = r.capture_authoritative_state()
	_call(r, "information", "prepare")
	_check(_state(r, "information") == state, "information: repeat prepare does not reroll")
	var map_before := _map_before(r)
	var result := _act(r, "information", "mine_count")
	_check(result.get("ok", false) and result.get("facts", {}).get("mine_count", -1) == 2, "information: free 5x5 count is true")
	_check(_black(r) == 100 and result.get("base_xp", 0) == 5 and result.get("base_talent", 0) == 2, "information: free service completes once")
	_check(result.get("facts", {}).get("intel_revealed_count", -1) == 0, "information: aggregate count creates no cell discoveries")
	_intel_only(r, map_before, Vector2i(2, 2))
	_reject(r, "z1_event_e04", "mine_locations", {}, "already_completed")
	_room(r, Vector2i(0, 1))
	_prepare(r, "information")
	_check(_state(r, "information").get("quote", {}).get("paid_fee_black", -1) == 3, "information: completed information discounts later room to 3")
	result = _act(r, "information", "mine_locations")
	_check(result.get("ok", false) and _black(r) == 97, "information: discounted service charges exactly 3")
	_dispose(r)


func _test_paid_information() -> void:
	for action in ["mine_locations", "chest_locations", "exit_direction"]:
		var r = _runtime()
		if _prepare(r, "information"):
			var map_before := _map_before(r)
			var result := _act(r, "information", action)
			_check(result.get("ok", false) and _black(r) == 95, action + ": charges 5 on actual service")
			if action == "mine_locations":
				_check(result.get("facts", {}).get("intel_revealed_count", -1) == 2, "information: only two 3x3 mine locations learned")
				_check(r.context.intel_map.get_cell_info(Vector2i(2, 2)).get("confirmed_mine", false), "information: mine evidence is public")
				_check(not r.context.intel_map.is_flagged(Vector2i(2, 2)), "information: confirmed mine is not a manual flag")
			elif action == "chest_locations":
				_check(result.get("facts", {}).get("intel_revealed_count", -1) == 2, "information: 5x5 chest locations learned")
				_check(r.context.z1_event_intel.get("1,1", {}).get("known_chest", false), "information: chest intel stored without direct exploration")
			else:
				_check(result.get("facts", {}).get("exit_direction", "") == "NE", "information: nearest exit direction")
				_check(not result.get("facts", {}).has("target_pos") and r.context.z1_event_intel.is_empty(), "information: direction does not leak precise exit or mark it visited")
			_intel_only(r, map_before, Vector2i(2, 2))
		_dispose(r)
	var r = _runtime()
	_prepare(r, "information")
	r.context.asset_ledger.spend_currency(&"black_coin", 96)
	# This direct fixture debit must complete the same accounting sync as a real
	# committed action before comparing the next action's complete context.
	var synced := Hooks.consume_new_incomes(r.context)
	_check(synced.get("ok", false) and r.context.pending_gold == 4 and r.context.z1_event_flags.get("z2_income_cursor", -1) == r.context.asset_ledger.settlement_log.size(), "information: fixture debit is fully settled before leave")
	_reject(r, "information", "mine_locations", {}, "insufficient_black")
	var before: Dictionary = r.capture_authoritative_state()
	var left := _call(r, "information", "leave")
	_check(left.get("ok", false) and not left.get("stage_completed", false) and r.capture_authoritative_state().context == before.context, "information: leaving has no gameplay effect")
	_dispose(r)


func _test_recon() -> void:
	for row in [[3, 10, 2], [5, 30, 2], [7, 70, 4]]:
		var r = _runtime()
		if _prepare(r, "recon"):
			var map_before := _map_before(r)
			var result := _act(r, "recon", "recon_%d" % row[0])
			_check(result.get("ok", false) and _black(r) == 100 - row[1], "recon: exact price for size %d" % row[0])
			_check(result.get("facts", {}).get("intel_revealed_count", -1) == row[2], "recon: actual discovery count for size %d" % row[0])
			_intel_only(r, map_before, Vector2i(2, 2))
			_reject(r, "recon", "recon_3", {}, "already_completed")
		_dispose(r)
	var r = _runtime(Vector2i(0, 1))
	_prepare(r, "recon")
	var result := _act(r, "recon", "recon_3")
	_check(result.get("ok", false) and result.get("facts", {}).get("intel_revealed_count", -1) == 1, "recon: map corner clips to six cells, learns one mine")
	_check(r.context.intel_map.known_rooms.size() == 49 and r.context.z1_event_intel.size() == 1, "recon: no out-of-bounds cells")
	_room(r, Vector2i(1, 0))
	_prepare(r, "recon")
	_reject(r, "recon", "recon_3", {}, "no_new_intel")
	_dispose(r)
	r = _runtime(Vector2i(3, 0))
	_prepare(r, "recon")
	_reject(r, "recon", "recon_3", {}, "no_new_intel")
	_reject(r, "recon", "recon_9", {}, "invalid_option")
	_dispose(r)
	for row in [["information", "mine_locations", 4], ["demine", "detonate", 6], ["recon", "recon_3", 9], ["recon", "recon_5", 29], ["recon", "recon_7", 69]]:
		r = _runtime()
		r.context.intel_map.toggle_flag(Vector2i(4, 3))
		_prepare(r, row[0])
		r.context.asset_ledger.spend_currency(&"black_coin", 100 - row[2])
		_reject(r, row[0], row[1], {"target_pos": Vector2i(4, 3)}, "insufficient_black")
		_dispose(r)


func _test_demine() -> void:
	var r = _runtime()
	_prepare(r, "demine")
	_reject(r, "demine", "detonate", {"target_pos": Vector2i(4, 3)}, "manual_flag_required")
	r.context.intel_map.learn_event_intel(Vector2i(4, 3), {"known_mine": true})
	_reject(r, "demine", "detonate", {"target_pos": Vector2i(4, 3)}, "manual_flag_required")
	r.context.intel_map.toggle_flag(Vector2i(2, 2))
	_reject(r, "demine", "detonate", {"target_pos": Vector2i(2, 2)}, "invalid_target")
	r.context.intel_map.toggle_flag(Vector2i(4, 3))
	var truth_before: Dictionary = r.context.truth_map.rooms.duplicate(true)
	var map_before := _map_before(r)
	var result := _act(r, "demine", "detonate", {"target_pos": Vector2i(4, 3)})
	_check(result.get("ok", false) and result.get("facts", {}).get("hit", false) and _black(r) == 93, "demine: hit charges 7")
	_check(r.context.pressure == 10 and result.get("facts", {}).get("pressure_delta", -1) == 10, "demine: hit applies 10 base pressure")
	_check(result.get("facts", {}).get("mines_disarmed", -1) == 1 and r.context.z1_event_flags.get("remote_mines", {}).get("4,3", false), "demine: real disarm fact and resolver compatibility")
	for key in truth_before:
		_check(r.context.truth_map.rooms[key].adjacent_mines == truth_before[key].adjacent_mines and r.context.truth_map.rooms[key].mine == truth_before[key].mine, "demine: original mine field and adjacency preserved " + key)
	_intel_only(r, map_before, Vector2i(4, 3))
	_reject(r, "demine", "detonate", {"target_pos": Vector2i(4, 3)}, "already_completed")
	_dispose(r)
	r = _runtime()
	r.context.intel_map.toggle_flag(Vector2i(3, 2))
	_prepare(r, "demine")
	result = _act(r, "demine", "detonate", {"target_pos": Vector2i(3, 2)})
	_check(result.get("ok", false) and result.get("stage_completed", false) and _black(r) == 93, "demine: wrong guess still pays and completes")
	_check(r.context.pressure == 0 and not result.get("facts", {}).get("hit", true) and result.get("facts", {}).get("mines_disarmed", -1) == 0, "demine: miss does not invent pressure or benefit")
	_dispose(r)
	r = _runtime()
	r.context.intel_map.toggle_flag(Vector2i(4, 3))
	r.context.protocol_pressure_reduce = 3
	# Z2 ignores the legacy scalar; its real pressure composer consumes these modifiers.
	r.context.vitals_modifiers["pressure"] = {"flat_reductions": [{"amount": 3}]}
	_prepare(r, "demine")
	result = _act(r, "demine", "detonate", {"target_pos": Vector2i(4, 3)})
	_check(result.get("ok", false) and r.context.pressure == 7 and result.get("facts", {}).get("pressure_delta", -1) == 7, "demine: unified pressure reductions and actual effect facts")
	_dispose(r)
	r = _runtime()
	r.context.intel_map.toggle_flag(Vector2i(4, 3))
	r.context.protocol_pressure_reduce = 3
	_prepare(r, "demine")
	result = _act(r, "demine", "detonate", {"target_pos": Vector2i(4, 3)})
	_check(result.get("ok", false) and r.context.pressure == 10 and result.get("facts", {}).get("pressure_delta", -1) == 10 and _black(r) == 93, "demine: legacy scalar alone cannot reduce Z2 pressure")
	_dispose(r)
	r = _runtime()
	r.context.intel_map.toggle_flag(Vector2i(4, 3))
	r.context.vitals_modifiers["pressure"] = {"flat_reductions": "invalid"}
	_prepare(r, "demine")
	_reject(r, "demine", "detonate", {"target_pos": Vector2i(4, 3)})
	_dispose(r)


func _test_shortcut() -> void:
	var r = _runtime(Vector2i.ZERO, 2, 2)
	if not _prepare(r, "shortcut"):
		_dispose(r)
		return
	var state := _state(r, "shortcut")
	_check(state.get("targets", []) == [Vector2i(1, 1)], "shortcut: only in-bounds diagonal at corner")
	_reject(r, "shortcut", "travel", {"target_pos": Vector2i(1, 1)}, "preview_required")
	var result := _act(r, "shortcut", "preview_target", {"target_pos": Vector2i(1, 1)})
	_check(result.get("ok", false) and not result.get("stage_completed", false) and _black(r) == 100, "shortcut: target preview never pays/completes")
	var preview: Dictionary = result.get("preview", {})
	_check(preview.get("known", {}).get("room_type", "") == &"Unknown" and not preview.get("known", {}).has("truth"), "shortcut: hidden target remains unknown")
	r.context.intel_map.toggle_flag(Vector2i(1, 1))
	_reject(r, "shortcut", "travel", {"target_pos": Vector2i(1, 1), "preview_id": preview.get("preview_id", "")}, "stale_preview")
	result = _act(r, "shortcut", "preview_target", {"target_pos": Vector2i(1, 1)})
	preview = result.get("preview", {})
	var payload := {"target_pos": Vector2i(1, 1), "preview_id": preview.get("preview_id", "")}
	_reject(r, "shortcut", "travel", payload, "flag_confirmation_required")
	payload["confirmed_flag"] = true
	_reject(r, "shortcut", "travel", payload, "room_entry_handler_required")
	var rejecting := func(_request: Dictionary) -> Dictionary:
		r.context.player_pos = Vector2i(1, 1)
		r.context.hp -= 9
		return {"ok": false, "reason": "injected_entry_failure"}
	_reject(r, "shortcut", "travel", payload, "injected_entry_failure", rejecting)
	var no_entry := func(_request: Dictionary) -> Dictionary: return {"ok": true}
	_reject(r, "shortcut", "travel", payload, "entry_not_completed", no_entry)
	r.context.asset_ledger.spend_currency(&"black_coin", 95)
	_reject(r, "shortcut", "travel", payload, "insufficient_black")
	r.context.asset_ledger.add_currency(&"black_coin", 95)
	# Real RoomResolver, with only the parent-owned transition wiring supplied here.
	var enter := func(request: Dictionary) -> Dictionary:
		_check(_black(r) == 100, "shortcut: fee is not paid before actual room entry")
		r.context.player_pos = request.target_pos
		r.context.current_pos = request.target_pos
		RunInventory.record_move(r.context)
		return r.command_bus.room_resolver.enter_room(r.context)
	result = _act(r, "shortcut", "travel", payload, enter)
	_check(result.get("ok", false) and result.get("stage_completed", false) and _black(r) == 94, "shortcut: actual entered room and one 6-coin payment")
	_check(r.context.get_current_pos() == Vector2i(1, 1) and r.context.visited_cells.has("1,1"), "shortcut: resolver records actual visit")
	_check(r.context.intel_map.is_flagged(Vector2i(1, 1)), "shortcut: confirmation preserves manual flag")
	_room(r, Vector2i.ZERO)
	_reject(r, "shortcut", "travel", payload, "already_completed", enter)
	_dispose(r)
	# Center rooms have one or two unique fixed openings; preview never rerolls.
	r = _runtime()
	_prepare(r, "shortcut")
	state = _state(r, "shortcut")
	var targets: Array = state.get("targets", [])
	_check(targets.size() in [1, 2], "shortcut: source-defined 1-2 openings")
	for target in targets:
		_check(absi(target.x - 3) == 1 and absi(target.y - 3) == 1, "shortcut: all openings are diagonal")
	_call(r, "shortcut", "prepare")
	_check(_state(r, "shortcut") == state, "shortcut: openings are persistent")
	_dispose(r)


func _test_atomic_replay() -> void:
	var r = _runtime()
	_prepare(r, "recon")
	var request := {"quote_id": _state(r, "recon").get("quote_id", "")}
	var before: Dictionary = r.capture_authoritative_state()
	r.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": false, "reason": "injected_disk_failure"}
	var result := _call(r, "recon", "recon_7", request, Callable(), "scan-action")
	_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "atomic: persistence failure rolls back fee/intel/stage")
	r.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	r.retry_persistence()
	result = _call(r, "recon", "recon_7", request, Callable(), "scan-action")
	_check(result.get("ok", false) and _black(r) == 30, "atomic: failed persistence can retry exactly once")
	var state := _state(r, "recon")
	var encoded: Dictionary = r.encode_checkpoint_state(r.capture_authoritative_state())
	result = r.restore_checkpoint_state(encoded)
	_check(result.get("ok", false) and _state(r, "recon") == state, "checkpoint: quote/result/remaining use preserved")
	before = r.capture_authoritative_state()
	result = _call(r, "recon", "recon_7", request, Callable(), "scan-action")
	_check(result.get("duplicate", false) and r.capture_authoritative_state() == before, "checkpoint: action receipt prevents repayment/reward")
	_reject(r, "recon", "recon_7", {}, "already_completed")
	_dispose(r)
	r = _runtime()
	_prepare(r, "shortcut")
	state = _state(r, "shortcut")
	encoded = r.encode_checkpoint_state(r.capture_authoritative_state())
	result = r.restore_checkpoint_state(encoded)
	_check(result.get("ok", false) and _state(r, "shortcut") == state, "checkpoint: unchosen shortcut openings/quote survive")
	_dispose(r)


func _test_review_boundaries() -> void:
	# These regressions catch stale completed projections and counting already
	# public chest scans as new information.
	var r = _runtime()
	_prepare(r, "information")
	_act(r, "information", "mine_count")
	_check(not _state(r, "information").get("requires_prepare", true), "completed service never requests a new quote")
	_dispose(r)
	r = _runtime()
	r.context.intel_map.scan_cell(Vector2i(1, 1), r.context.truth_map, &"room_type", 1.0)
	r.context.intel_map.scan_cell(Vector2i(5, 4), r.context.truth_map, &"room_type", 1.0)
	_prepare(r, "information")
	_reject(r, "information", "chest_locations", {}, "no_new_intel")
	_dispose(r)
	r = _runtime(Vector2i.ZERO, 2, 2)
	_prepare(r, "shortcut")
	var result := _act(r, "shortcut", "preview_target", {"target_pos": Vector2i(1, 1)})
	var payload := {"target_pos": Vector2i(1, 1), "preview_id": result.get("preview", {}).get("preview_id", "")}
	var malformed := func(_request: Dictionary) -> Dictionary:
		r.context.hp -= 9
		return {"ok": true, "room_entry_result": "invalid"}
	_reject(r, "shortcut", "travel", payload, "invalid_entry_result", malformed)
	_dispose(r)
	# Every room service must retain its paid result and spent use after restoring.
	for row in [["information", "mine_count"], ["information", "mine_locations"], ["demine", "detonate"]]:
		r = _runtime()
		r.context.intel_map.toggle_flag(Vector2i(4, 3))
		_prepare(r, row[0])
		result = _act(r, row[0], row[1], {"target_pos": Vector2i(4, 3)})
		_check(result.get("ok", false), "checkpoint fixture completes " + row[1])
		var state := _state(r, row[0])
		var encoded: Dictionary = r.encode_checkpoint_state(r.capture_authoritative_state())
		result = r.restore_checkpoint_state(encoded)
		_check(result.get("ok", false) and _state(r, row[0]) == state, "checkpoint preserves complete service " + row[1])
		_reject(r, row[0], row[1], {"target_pos": Vector2i(4, 3)}, "already_completed")
		_dispose(r)
	# Exhausted/invalid target guards are distinct from wrong guesses.
	r = _runtime()
	r.context.intel_map.toggle_flag(Vector2i(4, 3))
	r.context.z1_event_flags["remote_mines"] = {"4,3": true}
	_prepare(r, "demine")
	_reject(r, "demine", "detonate", {"target_pos": Vector2i(4, 3)}, "mine_already_inactive")
	_reject(r, "demine", "detonate", {"target_pos": "4,3"}, "invalid_target")
	_dispose(r)
	r = _runtime(Vector2i.ZERO, 1, 1)
	var before: Dictionary = r.capture_authoritative_state()
	result = _call(r, "shortcut", "prepare")
	_check(not result.get("ok", true) and result.get("reason", "") == "no_shortcut_target" and r.capture_authoritative_state() == before, "shortcut: empty diagonal set rejects without state")
	_dispose(r)


func _test_shortcut_risk_atomicity() -> void:
	for lethal in [false, true]:
		var r = _runtime(Vector2i.ZERO, 2, 2)
		r.context.truth_map.set_room_type(Vector2i(1, 1), &"Mine")
		r.context.hp = 10 if lethal else 100
		r.context.pressure = 80
		r.context.protocol_level = 1
		_prepare(r, "shortcut")
		var result := _act(r, "shortcut", "preview_target", {"target_pos": Vector2i(1, 1)})
		var request := {"target_pos": Vector2i(1, 1), "preview_id": result.get("preview", {}).get("preview_id", ""), "quote_id": _state(r, "shortcut").get("quote_id", "")}
		_check(result.get("preview", {}).get("known", {}).get("room_type") == &"Unknown", "shortcut: preview never exposes hidden mine")
		var enter := func(entry: Dictionary) -> Dictionary:
			r.context.player_pos = entry.target_pos
			r.context.current_pos = entry.target_pos
			RunInventory.record_move(r.context)
			return r.command_bus.room_resolver.enter_room(r.context)
		var before: Dictionary = r.capture_authoritative_state()
		r.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": false, "reason": "injected_disk_failure"}
		result = _call(r, "shortcut", "travel", request, enter, "mine-travel")
		_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "shortcut: disk failure rolls back movement/mine/protocol/fee/terminal")
		r.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
		r.retry_persistence()
		result = _call(r, "shortcut", "travel", request, enter, "mine-travel")
		_check(result.get("ok", false) and result.get("stage_completed", false) and _black(r) == 94, "shortcut: risk and 6-coin payment commit together")
		_check(r.context.hp == (0 if lethal else 68), "shortcut: entry resolves 2 protocol HP plus 30 mine damage")
		_check(r.context.pressure == 92 and r.context.truth_map.is_triggered(Vector2i(1, 1)), "shortcut: +2 exploration and +10 mine pressure applied once")
		_check(r.context.failed == lethal, "shortcut: lethal entry remains a successful paid transition")
		var encoded: Dictionary = r.encode_checkpoint_state(r.capture_authoritative_state())
		result = r.restore_checkpoint_state(encoded)
		_check(result.get("ok", false), "shortcut: completed risky entry restores checkpoint")
		# Replay uses the original action identity (origin position), as real UI retry does.
		before = r.capture_authoritative_state()
		result = r.execute_atomic_operation(&"z2_information", {"event": "shortcut", "option": "travel", "pos": Vector2i.ZERO, "payload": request},
			func() -> Dictionary: return information.execute(r.context, Vector2i.ZERO, "shortcut", "travel", request, enter), "mine-travel")
		_check(result.get("duplicate", false) and r.capture_authoritative_state() == before, "shortcut: checkpoint replay cannot reenter/charge/reward")
		_dispose(r)
