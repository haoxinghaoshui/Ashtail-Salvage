extends SceneTree

# Read-only production audit: fixtures arrange ownership/rooms, then the actual
# Runtime, CommandBus, RoomResolver, Z2RunHooks and official Loot do all work.
# No custom on_stage/consume_stage, supply calls, replacement pools or RNG stubs.
const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Progress = preload("res://scripts/core/progression/m7_progression_service.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Loot = preload("res://scripts/core/content/z2_loot_catalog.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
const Service = preload("res://scripts/core/run/event_service.gd")
const Content = preload("res://scripts/core/content/run_rule_content.gd")
const SLEEVE := "eq_etched_sleeve"
const BADGE := "eq_old_work_badge"
const PENDANT := "eq_seam_finder_pendant"
var checks := 0
var failures: Array[String] = []
var serial := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var home := OS.get_environment("Z2_SUPPLY_EVENT_QA_HOME").simplify_path().replace("\\", "/").trim_suffix("/")
	var user_data := OS.get_user_data_dir().simplify_path().replace("\\", "/")
	if not home.is_absolute_path() or not user_data.to_lower().begins_with(home.to_lower() + "/"):
		printerr("Z2_SUPPLY_EVENT_JOURNEY=FAIL absolute isolated Z2_SUPPLY_EVENT_QA_HOME containing user:// required")
		quit(1)
		return
	_test_stage_journey()
	_test_badge_journey()
	_test_badge_qualification_and_overflow()
	_test_compression_and_coil()
	_test_search_journey()
	for failure in failures:
		print("Z2_SUPPLY_EVENT_JOURNEY_FAIL " + failure)
	print("Z2_SUPPLY_EVENT_JOURNEY=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _runtime(gear: Array) -> RunRuntimeController:
	var meta := Meta.new()
	meta.set_active_profile_path("user://supply_event_journey_%d/meta.json" % Time.get_ticks_usec(), "supply_event_journey")
	meta.initialize_z2_profile(Rules.CONTENT_VERSION)
	meta.data.tutorial_completed = true
	meta.data.profile_level = 50
	meta.data.profile_exp = Rules.exp_for_level(50)
	meta.data.talent_flags = ["z2_talent_01"]
	meta.data.talent_spent = 100
	meta.data.talent_points = 0
	var equipped: Array = []
	for id: String in gear:
		equipped.append(Progress.add_item_instance(meta.data, id, "journey_fixture").instance_id)
	_check(meta.save(), "isolated profile fixture saved")
	var r := Runtime.new()
	r.bind_meta_progress_adapter(meta)
	var commission: Dictionary = M7ContentCatalog.commission_offer_candidates("classic_13x13_normal", 0, 3)[0]
	var started: Dictionary = r.command_bus.dispatch(&"start_standard_run", {"run_start_config": {
		"map_config_id": "classic_13x13_normal", "difficulty": "normal", "seed_value": 3141,
		"selected_equipment_ids": equipped, "selected_objective_id": commission.id}})
	_check(started.get("ok", false), "actual standard departure with " + str(gear) + ": " + str(started.get("reason", "")))
	# High HP/capacity are boundary-fixture resources, not substitute event rules.
	r.context.max_hp = 1000
	r.context.hp = 1000
	r.context.pressure = 0
	r.context.power = 100
	r.context.asset_ledger.backpack_capacity = 2000
	r.context.asset_ledger.add_currency(&"black_coin", 300, "journey_fixture")
	r.context.asset_ledger.sync_compat_fields(r.context)
	return r


func _enter(r: RunRuntimeController, pos: Vector2i, event: String = "", room_type: StringName = &"Event") -> bool:
	if not event.is_empty():
		if not r.context.z1_event_rooms.has(r.context.cell_key(pos)):
			r.context.z1_event_rooms[r.context.cell_key(pos)] = {"event_type": StringName(event)}
	r.context.truth_map.set_room_type(pos, room_type)
	var result := r.execute_atomic_operation(&"room_entry", {}, func() -> Dictionary:
		r.context.player_pos = pos
		r.context.current_pos = pos
		return r.command_bus.room_resolver.enter_room(r.context), _id("entry"))
	return _check(result.get("ok", false), "real entry %s %s: %s" % [pos, event, result.get("reason", "")])


func _state(r: RunRuntimeController) -> Dictionary:
	return Service.get_event_state(r.context, r.context.get_current_pos())


func _request(r: RunRuntimeController, action: String, extra: Dictionary = {}) -> Dictionary:
	var request := {"option_id": action, "action_id": _id(action)}
	for row: Dictionary in _state(r).get("options", []):
		if str(row.id) == action:
			request.merge(row.get("payload", {}).duplicate(true), true)
			break
	request.merge(extra, true)
	return request


func _choose(r: RunRuntimeController, action: String, extra: Dictionary = {}) -> Dictionary:
	return _dispatch(r, _request(r, action, extra))


func _dispatch(r: RunRuntimeController, request: Dictionary) -> Dictionary:
	var envelope: Dictionary = r.command_bus.dispatch(&"select_event_option", request)
	return envelope.get("action_result", envelope)


func _instance(r: RunRuntimeController, item_id: String) -> String:
	for item: Dictionary in r.context.asset_ledger.item_instances.values():
		if str(item.item_id) == item_id and not bool(item.get("supply_extra", false)):
			return str(item.instance_id)
	return ""


func _remaining(r: RunRuntimeController, item_id: String) -> int:
	return int(r.context.vitals_counters.get("z2_supply:" + _instance(r, item_id), -1))


func _effects(r: RunRuntimeController) -> Dictionary:
	return {"shield": r.context.shield, "hp": r.context.hp, "counters": r.context.vitals_counters.duplicate(true),
		"supply": r.context.z1_event_flags.get("z2_supply_runtime", {}).duplicate(true),
		"items": r.context.asset_ledger.item_instances.duplicate(true),
		"black": r.context.asset_ledger.get_currency(&"black_coin")}


func _extras(r: RunRuntimeController) -> Array:
	return r.context.asset_ledger.item_instances.values().filter(func(item: Dictionary) -> bool: return item.get("supply_extra", false))


func _roundtrip_equipment(r: RunRuntimeController, item_id: String) -> void:
	var id := _instance(r, item_id)
	var charges := _remaining(r, item_id)
	var seen: Dictionary = r.context.z1_event_flags.get("z2_supply_runtime", {}).get("seen", {}).duplicate(true)
	for command in [&"unequip_item", &"drop_inventory_item", &"pickup_ground_item", &"equip_item"]:
		var result: Dictionary = r.command_bus.dispatch(command, {"instance_id": id, "action_id": _id(str(command))})
		_check(result.get("ok", false), "same instance " + str(command) + ": " + str(result.get("reason", "")))
	_check(_instance(r, item_id) == id and _remaining(r, item_id) == charges, "drop/pickup/re-equip preserves instance and charges: " + item_id)
	_check(r.context.z1_event_flags.z2_supply_runtime.seen == seen, "drop/pickup/re-equip preserves seen rooms/stages: " + item_id)


func _restart(r: RunRuntimeController) -> RunRuntimeController:
	var before := _effects(r)
	var path := "user://supply_event_restart_%d.json" % Time.get_ticks_usec()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(r.encode_checkpoint_state(r.capture_authoritative_state())))
	file.close()
	var next := Runtime.new()
	var restored := next.restore_checkpoint_state(JSON.parse_string(FileAccess.get_file_as_string(path)))
	_check(restored.get("ok", false), "production checkpoint codec restores new actual Runtime: " + str(restored.get("reason", "")))
	_check(_effects(next) == before, "restart retains equipment counters, seen identities and rewards")
	_release(r)
	return next


func _test_stage_journey() -> void:
	var r := _runtime([SLEEVE])
	var altar := Vector2i(2, 2)
	if not _enter(r, altar, "altar"):
		_release(r)
		return
	_check(_remaining(r, SLEEVE) == 10 and r.context.shield == 0, "prepare does not consume finite stage benefit")
	var before := _effects(r)
	_check(not _choose(r, "assist", {"instance_id": "not-owned"}).get("ok", true), "invalid material rejected through actual command")
	_check(_effects(r) == before, "rejected action grants no shield and spends no count")
	var hp: int = r.context.hp
	r.context.hp = int(_state(r).hp_cost)
	before = _effects(r)
	_check(not _choose(r, "offer").get("ok", true), "insufficient surviving HP rejects altar payment")
	_check(_effects(r) == before, "failed payment leaves reward/counter unchanged")
	r.context.hp = hp
	var first_request := _request(r, "offer")
	for tier in range(1, 6):
		if tier > 1:
			_check(_choose(r, "prepare").get("ok", false), "same altar prepares next stage")
		var result := _dispatch(r, first_request) if tier == 1 else _choose(r, "offer")
		_check(result.get("ok", false) and result.get("stage_completed", false), "actual altar stage %d committed" % tier)
		_check(r.context.shield == tier * 5 and _remaining(r, SLEEVE) == 10 - tier, "same altar distinct stage grants exactly one shield benefit %d" % tier)
		if tier == 1:
			before = _effects(r)
			_dispatch(r, first_request)
			_check(_effects(r) == before, "duplicate committed request cannot consume again")
			var stale := first_request.duplicate(true)
			stale.action_id = _id("stale")
			_check(not _dispatch(r, stale).get("ok", true), "stale quote rejected")
			_check(_effects(r) == before, "stale quote cannot consume benefit")
		if tier == 2:
			r = _restart(r)
	var shield_before: int = r.context.shield
	_roundtrip_equipment(r, SLEEVE)
	_enter(r, altar, "altar")
	_check(r.context.shield == shield_before and _remaining(r, SLEEVE) == 5, "altar revisit and re-pickup do not reset or reaward")
	for index in range(6):
		if not _enter(r, Vector2i(3 + index, 2), "altar"):
			continue
		var result := _choose(r, "offer")
		_check(result.get("ok", false) and result.get("stage_completed", false), "different altar tier5 is a valid room stage")
		_check(r.context.shield == mini(10, 6 + index) * 5 and _remaining(r, SLEEVE) == maxi(0, 4 - index), "global ten stage uses, including different altars, then exhausted")
		var stages: Array = result.get("stage_facts", [])
		_check(stages.size() == 1 and int(stages[0].base_talent) == 0, "new altar equipment stage independent of global tier talent dedup")
	_release(r)


func _test_badge_journey() -> void:
	var r := _runtime([BADGE])
	_check(int(Items.definition(BADGE).effect_params.max_uses) == 3 and int(Items.definition(BADGE).effect_params.per_room_limit) == 1, "authoritative badge is global3 / per-room1")
	var origin := Vector2i(2, 3)
	if not _enter(r, origin, "altar"):
		_release(r)
		return
	for tier in range(1, 4):
		if tier > 1:
			_check(_choose(r, "prepare").get("ok", false), "badge altar next offer")
		var result := _choose(r, "offer")
		_check(result.get("ok", false), "badge actual altar offer")
		# Official D02 allows recovery bag only in camp_shop. Altar stage1's
		# current qualified pool is material-only: no badge draw and no use.
		_check(_extras(r).size() == (0 if tier == 1 else 1) and _remaining(r, BADGE) == (3 if tier == 1 else 2), "same altar: empty ordinary stage1 pool spends nothing; stage2/3 share one badge use")
		if tier == 2:
			_check_extras(r, "altar", tier)
	_roundtrip_equipment(r, BADGE)
	r = _restart(r)
	_enter(r, origin, "altar")
	_check(_extras(r).size() == 1 and _remaining(r, BADGE) == 2, "restart/revisit/re-pickup preserves badge room/global limits")
	for index in range(3):
		if not _enter(r, Vector2i(3 + index, 3), "altar"):
			continue
		var stage := int(_state(r).tier)
		var previous: Array = _extras(r).map(func(item: Dictionary) -> String: return str(item.instance_id))
		_check(_choose(r, "offer").get("ok", false), "different altar actual random output")
		_check(_extras(r).size() == mini(3, index + 2) and _remaining(r, BADGE) == maxi(0, 1 - index), "global badge limit is three different eligible rooms")
		_check_extras(r, "altar", stage, previous)
	_check(_extras(r).size() == 3, "exactly three real extra ledger instances, no recursive extras")
	_release(r)


func _check_extras(r: RunRuntimeController, channel: String, stage: int, previous: Array = []) -> void:
	var frozen: Dictionary = r.context.run_start_config.profile_fields.content_eligibility
	var map_id := str(r.context.run_start_config.map_config_id)
	var pool := Loot.candidates(channel, frozen, map_id, stage)
	for item: Dictionary in _extras(r):
		if previous.has(str(item.instance_id)):
			continue
		_check(str(item.item_type) in ["collectible", "equipment", "consumable"] and not item.get("is_unique", false), "badge extra is ordinary actual item")
		_check(Eligibility.is_eligible(str(item.item_id), channel, frozen, map_id) and pool.any(func(row: Dictionary) -> bool: return str(row.item_id) == str(item.item_id)), "badge extra belongs to qualified source event/stage pool")
		_check(str(item.location_state) in ["inventory", "room_floor"], "badge reward delivered to a real location")


func _test_badge_qualification_and_overflow() -> void:
	var r := _runtime([BADGE, SLEEVE])
	if _enter(r, Vector2i(2, 4), "first_aid"):
		_check(_choose(r, "buy").get("ok", false), "fixed first aid delivery succeeds")
		_check(_remaining(r, BADGE) == 3 and _extras(r).is_empty(), "fixed delivery is not a badge event")
	if _enter(r, Vector2i(3, 4), "trap"):
		r.context.power = 0
		var sleeve_uses := _remaining(r, SLEEVE)
		var hp_before: int = r.context.hp
		var shield_before: int = r.context.shield
		var result := _choose(r, "attempt")
		_check(result.get("ok", false) and not result.get("facts", {}).get("success", true), "mechanical loss is successfully settled, not failed transaction")
		_check(_remaining(r, SLEEVE) == sleeve_uses - 1, "settled challenge counts as effective stage per completion rule")
		_check(r.context.hp == hp_before and r.context.shield == shield_before - 1 + 5, "earned shield really absorbs mechanical damage before next stage adds five")
		_check(_remaining(r, BADGE) == 3 and _extras(r).is_empty(), "no actual random item means no badge use")
	r.context.power = 100
	var full_room := Vector2i(4, 4)
	if _enter(r, full_room, "trap"):
		r.context.asset_ledger.backpack_capacity = r.context.asset_ledger.get_backpack_used()
		var result := _choose(r, "attempt")
		_check(result.get("ok", false), "real random reward event succeeds with full inventory")
		_check(_extras(r).size() == 1 and _remaining(r, BADGE) == 2, "actual overflow delivery consumes exactly one badge use")
		for item: Dictionary in _extras(r):
			_check(str(item.location_state) == "room_floor" and item.get("room_pos") == full_room, "full-pack badge extra lies on this room floor")
		_check_extras(r, "mechanism_success", 1)
		var before := _effects(r)
		_choose(r, "attempt")
		_check(_effects(r) == before, "repeating full-pack completed event cannot lose/regrant items")
	_release(r)


func _test_compression_and_coil() -> void:
	var r := _runtime([BADGE, SLEEVE])
	var inputs: Array = []
	for item_id in ["col_01", "col_02"]:
		var item: Dictionary = r.context.asset_ledger.create_item_instance(Items.definition(item_id), &"inventory")
		inputs.append(str(item.instance_id))
	if _enter(r, Vector2i(2, 5), "compress"):
		var before := _effects(r)
		_check(not _choose(r, "compress", {"instance_ids": [inputs[0], "foreign-instance"]}).get("ok", true), "compression ownership failure rejects before stage/badge")
		_check(_effects(r) == before, "invalid compression does not consume inputs or equipment uses")
		var result := _choose(r, "compress", {"instance_ids": inputs})
		_check(result.get("ok", false), "compression actual original two inputs produce qualified output")
		_check(_remaining(r, BADGE) == 2 and _extras(r).size() == 1, "compression delivery reaches real badge callback")
		_check_extras(r, "compression", 1)
	var coil_room := Vector2i(3, 5)
	if _enter(r, coil_room, "coil"):
		var sleeve_uses := _remaining(r, SLEEVE)
		var badge_uses := _remaining(r, BADGE)
		var extra_ids: Array = _extras(r).map(func(item: Dictionary) -> String: return str(item.instance_id))
		_check(_choose(r, "calibrate").get("ok", false), "coil calibration is a real paid pending action")
		_check(_remaining(r, SLEEVE) == sleeve_uses and _remaining(r, BADGE) == badge_uses, "calibration is not actual completed random delivery")
		var search_pos := _find_search(r, &"Normal", true)
		if _check(search_pos != Vector2i(-1, -1), "coil has a real official normal search destination") and _enter(r, search_pos, "", &"Normal"):
			r.command_bus.dispatch(&"search_current_room", {"action_id": _id("coil-search")})
			for tick in range(119):
				r.advance_idle_frame(1.0 / 60.0)
			_check(_remaining(r, SLEEVE) == sleeve_uses and _remaining(r, BADGE) == badge_uses, "partial search cannot complete coil or consume equipment")
			r.advance_idle_frame(1.0 / 60.0)
			var state := Service.get_event_state(r.context, coil_room)
			_check(state.get("completed", false) and not r.context.z1_event_flags.get("z2_process", {}).has("coil_pending"), "actual extra item delivery completes origin coil")
			_check(_remaining(r, SLEEVE) == sleeve_uses - 1, "coil source stage triggers real finite sleeve callback exactly once")
			var stages: Array = r.context.run_event_log.snapshot().filter(func(e: Dictionary) -> bool: return str(e.event_type) == "event_stage_completed" and str(e.payload.get("event_type", "")) == "coil")
			_check(stages.size() == 1 and stages[0].payload.get("position") == coil_room, "coil stage keeps source event position instead of search room")
			if not stages.is_empty():
				var delivered: Array = stages[0].payload.get("facts", {}).get("items", [])
				_check(delivered.size() == 1 and r.context.asset_ledger.item_instances.has(str(delivered[0].instance_id)), "coil stage contains real produced instance")
			# S4 E19/F19 + common C19: a noncombat event delivering an ordinary
			# random item uses its origin pool, including deferred coil delivery.
			_check(_remaining(r, BADGE) == badge_uses - 1 and _extras(r).size() == extra_ids.size() + 1, "AUDIT_COIL_BADGE actual deferred random event must reach badge through origin search pool")
			_check_extras(r, "search", 1, extra_ids)
	_release(r)


func _test_search_journey() -> void:
	# Badge and pendant share a device slot. Separate actual runs prevent an
	# impossible loadout and distinguish event extras from ordinary search rebates.
	for gear in [BADGE, PENDANT]:
		var r := _runtime([gear])
		var positive_rebates := 0
		for kind: StringName in [&"Normal", &"Chest"]:
			var pos := _find_search(r, kind, gear == PENDANT)
			if not _check(pos != Vector2i(-1, -1), "official seeded pool supplies search fixture " + str(kind)):
				continue
			_enter(r, pos, "", kind)
			var duration := 3.0 if kind == &"Chest" else 2.0
			var before := _effects(r)
			var request := {"action_id": _id("search")}
			_check(r.command_bus.dispatch(&"search_current_room", request).get("ok", false), "real search command starts timer " + str(kind))
			var key: String = r.context.cell_key(pos)
			_check(is_equal_approx(float(r.context.z1_event_flags.z2_search.rooms[key].duration_seconds), duration), "confirmed unmodified search duration " + str(duration))
			for tick in range(int(duration * 60.0) - 1):
				r.advance_idle_frame(1.0 / 60.0)
			_check(not r.context.searched_cells.has(key) and _effects(r) == before, "no physical reward or charge before final search tick")
			r.advance_idle_frame(1.0 / 60.0)
			_check(r.context.searched_cells.has(key), "search completes on 2/3-second boundary")
			var reward: Dictionary = r.context.last_reward
			var produced: Array = []
			for item: Dictionary in r.context.asset_ledger.item_instances.values():
				if not before.items.has(str(item.instance_id)):
					produced.append(item)
			_check(not produced.is_empty(), "timed search creates actual ledger reward")
			var total_value := 0
			var channel := "chest" if kind == &"Chest" else "search"
			for item: Dictionary in produced:
				total_value += maxi(0, int(item.base_value))
				_check(Eligibility.is_eligible(str(item.item_id), channel, r.context.run_start_config.profile_fields.content_eligibility, str(r.context.run_start_config.map_config_id)), "search reward belongs to actual frozen channel")
			var rebate := floori(total_value * 0.1) if gear == PENDANT else 0
			var actual_black: int = r.context.asset_ledger.get_currency(&"black_coin") - int(before.black)
			_check(actual_black == int(reward.get("gold", -999)) + rebate, "real black income equals base search plus nonrecursive actual-value rebate")
			if rebate > 0:
				positive_rebates += 1
			_check(_remaining(r, gear) == (10 - positive_rebates if gear == PENDANT else 3), "search consumes only positive pendant benefit; never badge use")
			_check(_extras(r).is_empty(), "ordinary search/chest does not invoke event badge")
			var completed := _effects(r)
			_enter(r, pos, "", kind)
			r.command_bus.dispatch(&"search_current_room", {"action_id": _id("revisit-search")})
			r.advance_idle_frame(0.25)
			_check(_effects(r) == completed, "revisit and completed search do not repeat reward/rebate")
			if gear == PENDANT:
				_roundtrip_equipment(r, gear)
				r = _restart(r)
		_release(r)
	_test_zero_value_search()


func _find_search(r: RunRuntimeController, kind: StringName, positive_value: bool, zero_value: bool = false) -> Vector2i:
	for y in range(1, 12):
		for x in range(1, 12):
			var pos := Vector2i(x, y)
			if pos == r.context.truth_map.spawn_pos or r.context.visited_cells.has(r.context.cell_key(pos)):
				continue
			var adjacent: int = r.context.minefield_service.count_adjacent_mines(r.context.truth_map, pos)
			var gold := Content.default_search_black_coin(r.context, pos, adjacent, kind == &"Chest")
			var definitions := Content.default_search_items(pos, adjacent, kind == &"Chest", gold, r.context)
			var value := 0
			for item: Dictionary in definitions:
				value += maxi(0, int(item.get("base_value", 0)))
			if (zero_value and value < 10) or (not zero_value and not definitions.is_empty() and (not positive_value or value >= 10)):
				return pos
	return Vector2i(-1, -1)


func _test_zero_value_search() -> void:
	var r := _runtime([PENDANT])
	var pos := _find_search(r, &"Normal", false, true)
	if _check(pos != Vector2i(-1, -1), "official search includes zero-rebate output") and _enter(r, pos, "", &"Normal"):
		r.command_bus.dispatch(&"search_current_room", {"action_id": _id("zero-search")})
		for tick in range(120):
			r.advance_idle_frame(1.0 / 60.0)
		_check(r.context.searched_cells.has(r.context.cell_key(pos)), "zero-rebate search still completes normally")
		_check(_remaining(r, PENDANT) == 10, "no real rebate never consumes pendant charge")
	_release(r)


func _id(prefix: String) -> String:
	serial += 1
	return "supply-event:%s:%d" % [prefix, serial]


func _release(r: RunRuntimeController) -> void:
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)


func _check(value: bool, label: String) -> bool:
	checks += 1
	if not value:
		failures.append(label)
	return value
