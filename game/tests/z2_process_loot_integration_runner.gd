extends SceneTree

const Runtime := preload("res://scripts/core/run/run_runtime_controller.gd")
const Process := preload("res://scripts/core/run/z2_process_events.gd")
const Loot := preload("res://scripts/core/content/z2_loot_catalog.gd")
const Eligibility := preload("res://scripts/core/content/z2_content_eligibility.gd")
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_mechanisms()
	_recycle()
	_coil()
	_altar()
	_empty_and_research()
	_weights_definitions_and_freeze()
	for failure in failures:
		print("Z2_PROCESS_LOOT_CASE_FAIL " + failure)
	print("Z2_PROCESS_LOOT_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _runtime(level: int = 50):
	var runtime = Runtime.new()
	runtime.command_bus.dispatch(&"start_demo_run", {})
	var context: RunContext = runtime.context
	context.run_id = &"t07-process-loot"
	context.seed_value = 428
	context.profile_fields = {"ruleset_id": "z2", "z2_progression_version": 1,
		"content_eligibility": Eligibility.freeze_profile({"profile_level": level,
			"research_completed_ids": ["research_hard_shell_patch", "research_red_battery", "research_black_box_bell"]})}
	context.run_start_config.profile_fields = context.profile_fields.duplicate(true)
	context.run_start_config.map_config_id = "classic_13x13_hard"
	context.asset_ledger.setup({"run_id": str(context.run_id), "backpack_capacity": 1000, "equipment_capacity": 100})
	context.asset_ledger.add_currency(&"black_coin", 300)
	context.hp = 500
	context.max_hp = 500
	context.power = 200
	context.current_adjacent_mines = 2
	context.pressure = 0
	context.z1_event_rooms.clear()
	context.z1_event_flags.clear()
	_room(runtime, Vector2i(2, 2))
	return runtime


func _dispose(runtime) -> void:
	runtime.checkpoint_writer = Callable()
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)


func _room(runtime, pos: Vector2i) -> void:
	runtime.context.current_pos = pos
	runtime.context.player_pos = pos
	runtime.context.visited_cells[runtime.context.cell_key(pos)] = true


func _rules(runtime, tier: int = 1) -> Dictionary:
	var rules := Loot.process_rules(runtime.context, tier)
	# Trusted damage inputs for this integration test; no invented official damage policy.
	rules.merge({"difficulty": "hard", "electric_damage_type": "physical", "mechanism_failure_damage_type": "physical"})
	return rules


func _call(runtime, event: String, action: String, rules: Dictionary, payload: Dictionary = {}, action_id: String = "") -> Dictionary:
	var pos: Vector2i = runtime.context.get_current_pos()
	var request := payload.duplicate(true)
	request.revision = Process.public_state(runtime.context, pos, event).get("revision", 0)
	return runtime.execute_atomic_operation(&"t07_process_loot", {"event": event, "action": action, "payload": request},
		func() -> Dictionary: return Process.choose(runtime.context, pos, event, action, request, rules), action_id)


func _prepare(runtime, event: String, rules: Dictionary) -> bool:
	var result := _call(runtime, event, "prepare", rules)
	_check(bool(result.ok), event + " real Loot.process_rules prepares: " + str(result.get("reason", "")))
	return bool(result.ok)


func _black(runtime) -> int:
	return runtime.context.asset_ledger.get_currency(&"black_coin")


func _assert_items(result: Dictionary, count: int, channel: String, runtime) -> void:
	var items: Array = result.get("facts", {}).get("items", [])
	_check(items.size() == count, "actual granted count " + channel)
	for item: Dictionary in items:
		var original := Loot.definition(str(item.item_id))
		_check(not original.is_empty() and item.weight == original.weight and item.base_value == original.base_value, "grant keeps source units " + str(item.item_id))
		_check(Eligibility.is_eligible(str(item.item_id), channel, runtime.context.run_start_config.profile_fields.content_eligibility, "classic_13x13_hard"), "actual grant passes explicit channel")
		_check(not item.has("_roll_weight") and str(item.get("required_research_id", "")).is_empty(), "no roll metadata or research products in ledger")


func _mechanisms() -> void:
	for variant in ["mechanical", "electric"]:
		var runtime = _runtime()
		var rules := _rules(runtime)
		rules.mechanism_variant = variant
		if _prepare(runtime, "mechanism", rules):
			var state := Process.public_state(runtime.context, Vector2i(2, 2), "mechanism")
			var reward := _call(runtime, "mechanism", "attempt", rules)
			_check(bool(reward.ok) and bool(reward.valid_stage), "real mechanism resolves " + variant)
			_check(_black(runtime) == (325 if variant == "mechanical" else 306), "mechanism original income " + variant)
			_check(runtime.context.hp == (500 if variant == "mechanical" else 490), "mechanism HP unchanged policy " + variant)
			_assert_items(reward, 2 if variant == "mechanical" else 1, "mechanism_success", runtime)
			_check(state.rewards.size() == reward.facts.items.size(), "prepared output count retained")
		_dispose(runtime)


func _recycle() -> void:
	for action in ["take", "deliver"]:
		var runtime = _runtime()
		var rules := _rules(runtime)
		if _prepare(runtime, "recycle", rules):
			var offered: Dictionary = Process.public_state(runtime.context, Vector2i(2, 2), "recycle").rewards[0]
			_check(offered.item_id in ["sp_inspection_calibration_plate", "sp_transit_lead_seal"], "real recycled material is outside72 catalog")
			var price := 5 if offered.item_id == "sp_inspection_calibration_plate" else 10
			var result := _call(runtime, "recycle", action, rules)
			_check(bool(result.ok) and bool(result.valid_stage), "real recycling " + action)
			if action == "take":
				_assert_items(result, 1, "recycle", runtime)
				var instance_id := str(result.facts.item_instance_id)
				# Inherited material definitions retain their explicit floor delivery.
				# Actually pick up that same instance before carrying it to another room.
				if str(runtime.context.asset_ledger.item_instances[instance_id].location_state) == "room_floor":
					var picked: Dictionary = runtime.context.asset_ledger.pickup_ground_item(instance_id, Vector2i(2, 2))
					_check(bool(picked.ok), "real material floor pickup succeeds")
				_room(runtime, Vector2i(3, 2))
				if _prepare(runtime, "recycle", _rules(runtime)):
					var handed := _call(runtime, "recycle", "deliver", _rules(runtime), {"instance_id": instance_id})
					_check(bool(handed.ok) and str(handed.facts.item_instance_id) == instance_id, "same real material delivered across rooms")
					_check(runtime.context.asset_ledger.get_currency(&"gold_coin") == price, "source recycling price kept")
			else:
				_check(runtime.context.asset_ledger.get_currency(&"gold_coin") == price, "onsite real material price")
			_check(_black(runtime) == 300, "no invented recycling fee")
		_dispose(runtime)


func _search_hook(runtime, rules: Dictionary) -> Dictionary:
	var pos: Vector2i = runtime.context.get_current_pos()
	var receipt := {"search_id": "real-origin-search", "room_id": runtime.context.cell_key(pos), "room_type": "normal", "complete": true}
	return runtime.execute_atomic_operation(&"t07_real_search", receipt,
		func() -> Dictionary: return Process.on_normal_search_completed(runtime.context, pos, receipt, rules))


func _coil() -> void:
	var runtime = _runtime()
	var rules := _rules(runtime)
	if _prepare(runtime, "coil", rules):
		var calibrated := _call(runtime, "coil", "calibrate", rules)
		_check(bool(calibrated.ok) and _black(runtime) == 295 and not bool(calibrated.valid_stage), "coil original fee and no premature stage")
		_room(runtime, Vector2i(3, 2))
		var empty_rules := _rules(runtime)
		empty_rules.pools.normal_search.items = []
		var before: Dictionary = runtime.capture_authoritative_state()
		var denied := _search_hook(runtime, empty_rules)
		_check(not bool(denied.ok) and runtime.capture_authoritative_state() == before, "empty extra pool preserves pending and assets")
		# Restart with pending coil, then real origin pool resolves identically.
		var restart = _runtime()
		var restored: Dictionary = restart.restore_checkpoint_state(runtime.encode_checkpoint_state(before))
		_check(bool(restored.ok), "pending real coil checkpoint decodes")
		var result := _search_hook(runtime, _rules(runtime))
		var resumed := _search_hook(restart, _rules(restart))
		_check(bool(result.ok) and bool(result.valid_stage) and result.room_id == "2,2", "real extra completes source coil room")
		_assert_items(result, 1, "search", runtime)
		_check(result.get("facts") == resumed.get("facts"), "weighted pending coil deterministic after restore")
		var after: Dictionary = runtime.capture_authoritative_state()
		var duplicate := _search_hook(runtime, _rules(runtime))
		_check(bool(duplicate.ok) and not bool(duplicate.get("valid_stage", false)) and runtime.capture_authoritative_state() == after, "duplicate search grants no second item")
		_dispose(restart)
	_dispose(runtime)


func _altar() -> void:
	var runtime = _runtime()
	var paid := 0
	var earned := 0
	for tier in range(1, 6):
		var rules := _rules(runtime, tier)
		if not _prepare(runtime, "altar", rules): break
		var state := Process.public_state(runtime.context, Vector2i(2, 2), "altar")
		_check(int(state.hp_cost) == [10, 15, 25, 35, 50][tier - 1] and int(state.black_reward) == [2, 5, 8, 10, 15][tier - 1], "altar exact original stage prices")
		var snapshot: Dictionary = runtime.capture_authoritative_state()
		var restart = _runtime()
		var restored: Dictionary = restart.restore_checkpoint_state(runtime.encode_checkpoint_state(snapshot))
		_check(bool(restored.ok), "prepared real altar checkpoint decodes")
		_check(Process.public_state(restart.context, Vector2i(2, 2), "altar").rewards == state.rewards, "prepared weighted reward survives restore")
		_dispose(restart)
		var result := _call(runtime, "altar", "offer", rules)
		paid += [10, 15, 25, 35, 50][tier - 1]
		earned += [2, 5, 8, 10, 15][tier - 1]
		_check(bool(result.ok) and int(result.facts.tier) == tier and bool(result.valid_stage), "real altar tier " + str(tier))
		_check(runtime.context.hp == 500 - paid and _black(runtime) == 300 + earned, "altar exact actual payment/income")
		_assert_items(result, 1, "altar", runtime)
	_dispose(runtime)


func _empty_and_research() -> void:
	for event in ["mechanism", "recycle", "coil", "altar"]:
		var runtime = _runtime(0)
		var before: Dictionary = runtime.capture_authoritative_state()
		var result := _call(runtime, event, "prepare", _rules(runtime))
		_check(not bool(result.ok) and str(result.reason) == "empty_eligible_pool", "real level0 pool refuses " + event)
		_check(runtime.capture_authoritative_state() == before, "empty pool refuses before any assets/stage change " + event)
		_dispose(runtime)
		var completed = _runtime()
		var rules := _rules(completed)
		var key: String = "normal_search" if event == "coil" else event
		rules.pools[key].items = [{"item_id": "con_hard_shell_patch", "roll_weight": 1}, {"item_id": "con_red_battery", "roll_weight": 1}, {"item_id": "eq_black_box_bell", "roll_weight": 1}]
		var prior: Dictionary = completed.capture_authoritative_state()
		var blocked := _call(completed, event, "prepare", rules)
		_check(not bool(blocked.ok) and completed.capture_authoritative_state() == prior, "completed research never becomes random product " + event)
		_dispose(completed)


func _weights_definitions_and_freeze() -> void:
	var runtime = _runtime()
	var rules := _rules(runtime)
	rules.pools.normal_search.items = [{"item_id": "col_01", "roll_weight": 1.0, "probability": 0.999}, ["col_02", 3.0]]
	var pool := Process._pool(runtime.context, "normal_search", rules)
	_check(bool(pool.ok), "compact and pair entries accepted together")
	if bool(pool.ok):
		var random := RandomNumberGenerator.new()
		random.seed = 2301
		for _index in range(32):
			var saved_state := random.state
			var ticket := random.randf()
			random.state = saved_state
			var chosen: Dictionary = Process._draw(pool.items, 1, random)[0]
			_check(chosen.item_id == ("col_01" if ticket < 0.25 else "col_02"), "literal1:3 ticket interval, not physical weight or probability hint")
			_check(not chosen.has("_roll_weight"), "internal weight stripped")
	for bad in [0, -1, INF, NAN, "2", true]:
		var invalid := _rules(runtime)
		invalid.pools.normal_search.items = [{"item_id": "col_01", "roll_weight": bad}]
		var rejected := Process._pool(runtime.context, "normal_search", invalid)
		_check(not bool(rejected.ok) and str(rejected.reason) == "invalid_pool_weight", "invalid compact weight fails closed " + str(bad))
	var ids := _rules(runtime)
	ids.pools.recycle.items = ["sp_inspection_calibration_plate", "sp_transit_lead_seal"]
	_check(bool(Process._pool(runtime.context, "recycle", ids).ok), "legacy ID entries resolve supplied materials")
	ids.definitions.clear()
	_check(not bool(Process._pool(runtime.context, "recycle", ids).ok), "missing inherited definitions no Meta fallback")
	var canonical := _rules(runtime)
	canonical.definitions.col_01 = {"item_id": "col_01", "base_value": 999999, "weight": 999999}
	canonical.pools.normal_search.items = ["col_01", "col_01"]
	var resolved := Process._pool(runtime.context, "normal_search", canonical)
	_check(bool(resolved.ok) and resolved.items.size() == 2 and resolved.items[0].base_value == 2 and resolved.items[0].weight == 2, "canonical values and duplicate ID tickets retained")
	var mismatched := _rules(runtime)
	mismatched.pools.recycle.items = ["sp_inspection_calibration_plate"]
	mismatched.definitions.sp_inspection_calibration_plate.item_id = "col_01"
	_check(not bool(Process._pool(runtime.context, "recycle", mismatched).ok), "injected definition ID mismatch denied")
	var forbidden := _rules(runtime)
	forbidden.pools.normal_search.channel = "qualification"
	_check(not bool(Process._pool(runtime.context, "normal_search", forbidden).ok), "qualification is never acquisition")
	runtime.context.profile_fields.content_eligibility = Eligibility.freeze_profile({"profile_level": 0})
	_check(bool(Process._pool(runtime.context, "normal_search", _rules(runtime)).ok), "process pools read original departure freeze")
	_dispose(runtime)


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
