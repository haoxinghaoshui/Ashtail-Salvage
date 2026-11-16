extends SceneTree

const Maps := preload("res://scripts/core/content/m7_content_catalog.gd")
const MAP_ID := "classic_7x7_simple"
const SEED := 1101
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
const LOOT_PATH := "res://scripts/core/content/z2_loot_catalog.gd"
const GOALS_PATH := "res://scripts/core/progression/z2_goals/goal_progression.gd"
const GROWTH_PATH := "res://scripts/core/progression/z2_progression_rules.gd"
const LOWER_TIERS := ["col_05", "col_09", "col_14", "col_12", "col_19"]
const FREIGHT := "col_absent_person_frame"
const CARRIED := "col_23"

var checks := 0
var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _check(_isolated(), "use fresh Z2_FORMAL_QA_HOME user data and D: APPDATA/LOCALAPPDATA/TEMP/TMP"):
		_finish()
		return
	for path in [LOOT_PATH, GOALS_PATH, GROWTH_PATH]:
		if not _check(ResourceLoader.exists(path), "production module available: " + path):
			_finish()
			return
	var loot := load(LOOT_PATH) as GDScript
	var goals := load(GOALS_PATH) as GDScript
	var growth := load(GROWTH_PATH) as GDScript
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	if not _check(loot != null and goals != null and growth != null and packed != null, "load production Main and Z2 modules"):
		_finish()
		return
	root.size = Vector2i(1280, 720)
	var main := packed.instantiate()
	root.add_child(main)
	var scene = main.get_node_or_null("RunScene")
	if not _check(scene != null, "Main mounts RunScene"):
		_finish()
		return
	scene.set_process(false)
	await process_frame
	if _check(_stage_profile(scene, goals, growth), "staged profile is ready"):
		# The first run makes freight necessary for A22. The second challenges M15
		# with two arrivals, and the follow-up brings both back in the backpack.
		var cases := [
			["A22 depends on freight", LOWER_TIERS + [FREIGHT], true, "active"],
			["M15 excludes freight", LOWER_TIERS + [FREIGHT, CARRIED], true, "active"],
			["M15 counts two carried", [FREIGHT, CARRIED], false, "claimable"],
		]
		for test: Array in cases:
			print("Z2_FORMAL_FREIGHT_GOALS_CASE ", test[0])
			if not _check(_exercise(scene, loot, test[1], test[2], test[3]), "case reached durable extraction"):
				break
	for child in scene.player_feedback_service.get_children():
		if child is AudioStreamPlayer:
			child.stop()
			child.stream = null
	scene.in_run_runtime.bind(null)
	scene.command_bus.bind_runtime_controller(null)
	main.queue_free()
	for _frame in range(4):
		await process_frame
	_finish()


func _isolated() -> bool:
	var home := _path(OS.get_environment("Z2_FORMAL_QA_HOME"))
	if not home.begins_with("d:/") or not _path(OS.get_user_data_dir()).begins_with(home + "/"):
		return false
	for key in ["APPDATA", "LOCALAPPDATA", "TEMP", "TMP"]:
		if not _path(OS.get_environment(key)).begins_with("d:/"):
			return false
	var data := DirAccess.open("user://")
	if data == null or data.dir_exists("saves"):
		return false
	for suffix in ["", SaveAdapter.LAST_VALID_BACKUP_SUFFIX, SaveAdapter.ATOMIC_TEMP_SUFFIX, SaveAdapter.CORRUPT_RECOVERY_SUFFIX]:
		if FileAccess.file_exists(SaveAdapter.M1_META_PROGRESS_PATH + suffix):
			return false
	return true


func _path(value: String) -> String:
	return value.replace("\\", "/").simplify_path().trim_suffix("/").to_lower()


func _stage_profile(scene, goals: GDScript, growth: GDScript) -> bool:
	var adapter: MetaProgressAdapter = scene.meta_progress_adapter
	if not _check(adapter.data.get("z2_progression_version") == 1 and scene.runtime_controller.persistence_error.is_empty(), "Main opened a current Z2 profile"):
		return false
	var meta: Dictionary = goals.initial_state(adapter.data)
	meta.merge({
		"tutorial_completed": true, "profile_level": 20, "profile_exp": growth.exp_for_level(20),
		"talent_flags": ["z2_talent_01"], "talent_earned": 100, "talent_spent": 100, "talent_points": 0,
		"unlocked_map_ids": ["tutorial_5x5", MAP_ID],
	}, true)
	for number in range(1, 15):
		var id := "M%02d" % number
		meta.z2_goals.states[id].unlocked = true
		meta.z2_goals.states[id].progress = goals.goal_state(meta, id).target
	adapter.data = goals.initial_state(meta)
	if not _check(adapter.save(), "save predecessor and level-20 eligibility fixture: " + adapter.last_error):
		return false
	var statuses := _statuses(adapter)
	return _check(statuses == ["active", "active"], "M15 and A22 start active: %s" % [statuses])


func _normal_step(truth: TruthMap, origin: Vector2i) -> Vector2i:
	for step: Vector2i in DIRECTIONS:
		if truth.is_inside(origin + step) and truth.get_room_type(origin + step) == &"Normal":
			return step
	return Vector2i.ZERO


func _exercise(scene, loot: GDScript, item_ids: Array, consign: bool, m15_status: String) -> bool:
	if scene.result_panel.is_visible_in_tree():
		scene._return_from_result_to_deploy()
	var adapter: MetaProgressAdapter = scene.meta_progress_adapter
	var before_status := _statuses(adapter)
	var choices := Maps.commission_offer_candidates(MAP_ID, int(adapter.data.get("run_count", 0)), 3)
	if not _command(scene, &"start_standard_run", {"run_start_config": {
		"map_config_id": MAP_ID, "seed_value": SEED, "difficulty": "",
		"selected_objective_id": str(choices[0].id) if not choices.is_empty() else "",
	}}) or not _check(scene._show_run_screen(), "enter production gameplay"):
		return false
	var context: RunContext = scene.run_context
	var origin := context.get_current_pos()
	var exits := context.truth_map.get_exits()
	var step := _normal_step(context.truth_map, origin)
	if not _check(context.run_active and exits.size() == 1 and origin.distance_squared_to(exits[0]) == 1
		and step != Vector2i.ZERO, "seed %d has a real adjacent exit and a normal neighbor" % SEED):
		return false
	var exit_pos: Vector2i = exits[0]
	var fixture: Dictionary = scene.runtime_controller.execute_atomic_operation(&"z2_formal_freight_fixture", {}, func() -> Dictionary:
		var instances := {}
		for item_id: String in item_ids:
			var definition: Dictionary = loot.definition(item_id)
			var tier := 6 if item_id in [FREIGHT, CARRIED] else LOWER_TIERS.find(item_id) + 1
			if definition.get("tier") != tier or definition.get("item_type") != &"collectible" or definition.get("is_unique", true):
				return {"ok": false, "reason": "unexpected catalog tier or type for " + item_id}
			if not context.asset_ledger.can_fit_item(definition).get("ok", false):
				return {"ok": false, "reason": "insufficient capacity for " + item_id}
			var instance := context.asset_ledger.create_item_instance(definition, &"inventory")
			if instance.is_empty():
				return {"ok": false, "reason": "cannot create catalog instance for " + item_id}
			instances[item_id] = instance
		if consign:
			var room := origin + step
			context.truth_map.set_room_type(room, &"Event")
			context.z1_event_rooms[context.cell_key(room)] = {"event_type": &"consign"}
			context.asset_ledger.add_currency(&"black_coin", 100, "z2_formal_freight_fixture")
		return {"ok": true, "instances": instances}
	)
	if not _check(fixture.get("ok") == true, "checkpoint canonical instances at real weights: %s" % fixture.get("reason", "")):
		return false
	var instances: Dictionary = fixture.instances
	var freight_id := str(instances[FREIGHT].instance_id) if consign else ""
	if consign:
		if not _walk(scene, origin + step) or not _consign(scene, freight_id):
			return false
		_check(_statuses(adapter) == before_status and not adapter.data.get("run_receipts", {}).has(str(context.run_id)), "consign leaves goal status unchanged until settlement")
		if not _walk(scene, origin):
			return false
	if not _walk(scene, exit_pos) or not _command(scene, &"request_extract") or not _command(scene, &"confirm_extract"):
		return false
	var commit: Dictionary = scene.runtime_controller.last_meta_commit
	if not _check(context.extracted and commit.get("status") == "committed", "real extraction commits: %s" % commit.get("status", "")):
		return false
	_check_terminal(context, instances, freight_id, exit_pos)
	_check_profile(adapter, str(context.run_id), instances, m15_status)
	return true


func _consign(scene, freight_id: String) -> bool:
	var context: RunContext = scene.run_context
	var pos := context.get_current_pos()
	var state := EventService.get_event_state(context, pos)
	if not _check(state.get("ruleset_id") == "z2" and state.get("event_type") == "consign", "real room entry resolves the T10 consign service"):
		return false
	if state.get("requires_prepare", false):
		if not _command(scene, &"select_event_option", {"option_id": &"prepare"}):
			return false
		state = EventService.get_event_state(context, pos)
	for option: Dictionary in state.get("options", []):
		var payload: Dictionary = option.get("payload", {}).duplicate(true)
		if option.get("id") != &"consign" or payload.get("instance_id") != freight_id or not option.get("enabled", false):
			continue
		payload["option_id"] = option.id
		var balance := context.asset_ledger.get_currency(&"black_coin")
		var fee := int(option.player_cost.amount)
		if not _command(scene, &"select_event_option", payload):
			return false
		var action: Dictionary = scene.last_command_result.get("action_result", {})
		return _check(action.get("ruleset_id") == "z2" and action.get("facts", {}).get("instance_id") == freight_id
			and context.asset_ledger.item_instances[freight_id].location_state == &"consigned"
			and fee > 0 and context.asset_ledger.get_currency(&"black_coin") == balance - fee,
			"T10 charges the projected fee and consigns the exact tier-6 instance")
	return _check(false, "T10 exposes an enabled quote for the catalog freight instance")


func _check_terminal(context: RunContext, instances: Dictionary, freight_id: String, exit_pos: Vector2i) -> void:
	var settlement := context.settlement_result
	var terminal: Dictionary = settlement.get("terminal_facts", {})
	var events: Array = terminal.get("run_events", [])
	_check(settlement.get("settlement_source") == "RunSettlementService" and settlement.get("finalized") == true
		and settlement.get("outcome") == &"success" and events.any(func(event: Dictionary) -> bool:
			return event.get("event_type") == &"extraction_success" and event.get("payload", {}).get("position") == exit_pos),
		"T14 finalizes success with the actual exit position")
	var before: Dictionary = terminal.get("items_before_settlement", {})
	var delivered := _collectibles(settlement.get("event_item_delivery", {}).get("delivered", []))
	_check(delivered.keys() == ([] if freight_id.is_empty() else [freight_id]), "T14 event delivery contains exactly the consigned instance")
	var arrivals := _collectibles(settlement.get("warehouse_items", []))
	_check(arrivals.size() == instances.size() and _contains_instances(arrivals, instances), "all and only the staged collectibles arrive in T14")
	for item: Dictionary in instances.values():
		var id := str(item.instance_id)
		var location := "consigned" if id == freight_id else "inventory"
		_check(str(before.get(id, {}).get("location_state", "")) == location,
			"T14 freezes %s as %s before delivery" % [item.item_id, location])


func _check_profile(adapter: MetaProgressAdapter, run_id: String, instances: Dictionary, m15_status: String) -> void:
	var disk := MetaProgressAdapter.new()
	disk.set_active_profile_path(adapter.active_meta_progress_path, adapter.active_profile_id)
	_check(disk.last_load_status == "loaded" and disk.data.get("run_receipts", {}).has(run_id)
		and disk.data.get("z2_goals", {}).get("run_receipts", {}).has(run_id), "profile reload has both terminal and goal receipts")
	var summary := disk.get_summary()
	_check(_contains_instances(_collectibles(summary.get("warehouse_items", [])), instances), "exact T14 collectible instances are in the reloaded warehouse")
	var actual := _statuses(disk)
	_check(actual == [m15_status, "claimable"], "reloaded [M15, A22] expected %s, observed %s" % [[m15_status, "claimable"], actual])


func _collectibles(items: Array) -> Dictionary:
	var result := {}
	for item: Dictionary in items:
		if str(item.get("item_type")) == "collectible":
			result[str(item.instance_id)] = item
	return result


func _contains_instances(actual: Dictionary, expected: Dictionary) -> bool:
	for item: Dictionary in expected.values():
		var other: Dictionary = actual.get(str(item.instance_id), {})
		if other.get("item_id") != item.item_id or int(other.get("tier", 0)) != int(item.tier) \
			or int(other.get("weight", -1)) != int(item.weight) or str(other.get("location_state")) != "warehouse":
			return false
	return true


func _statuses(adapter: MetaProgressAdapter) -> Array:
	var summary := adapter.get_summary()
	return [summary.get("task_states", {}).get("M15", {}).get("status", ""),
		summary.get("achievement_states", {}).get("A22", {}).get("status", "")]


func _walk(scene, target: Vector2i) -> bool:
	var context: RunContext = scene.run_context
	return _command(scene, &"attempt_room_transition", {"direction": target - context.get_current_pos()}) \
		and _check(context.get_current_pos() == target and context.visited_cells.has(context.cell_key(target)), "actually enter room %s" % target)


func _command(scene, action: StringName, payload: Dictionary = {}) -> bool:
	var result: Dictionary = scene._dispatch_command(action, payload, false, false)
	var detail: Dictionary = result.get("action_result", result)
	return _check(result.get("ok") == true, "%s: %s" % [action, detail.get("reason", detail.get("status", ""))])


func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		printerr("Z2_FORMAL_FREIGHT_GOALS_CASE_FAIL " + message)
	return condition


func _finish() -> void:
	print("Z2_FORMAL_FREIGHT_GOALS=%s checks=%d failures=%d" % ["PASS" if failures == 0 else "FAIL", checks, failures])
	quit(0 if failures == 0 else 1)
