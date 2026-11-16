extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Opening = preload("res://scripts/core/run/z2_opening_runtime.gd")
const Offer = preload("res://scripts/core/progression/z2_opening_offer.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_tools()
	_test_room_effects()
	_test_statuses_and_end()
	_test_avoidance_and_cash()
	_test_sacrifice_combat()
	for failure in failures:
		print("Z2_OPENING_HOOKS_FAIL " + failure)
	print("Z2_OPENING_HOOKS=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _runtime(effect: String) -> RunRuntimeController:
	var r := Runtime.new()
	r.command_bus.dispatch(&"start_demo_run", {})
	var c: RunContext = r.context
	c.profile_fields = {"ruleset_id": "z2", "z2_progression_version": 1, "content_eligibility": Eligibility.freeze_profile({"profile_level": 50})}
	c.active_talent_effects = [Z2TalentCatalog.definition("z2_talent_15")]
	c.run_start_config["profile_fields"] = c.profile_fields.duplicate(true)
	c.run_start_config["map_config_id"] = "classic_13x13_normal"
	c.run_start_config["difficulty"] = "normal"
	c.vitals_modifiers["z2_talents"] = Z2TalentRuntime.from_context(c)
	c.asset_ledger.setup({"run_id": str(c.run_id), "profile_fields": c.profile_fields})
	c.z1_event_flags.clear()
	c.z1_event_rooms.clear()
	c.pressure = 20
	Z2SupplyRuntime.on_departure(c, [])
	var meta := {"ruleset_id": "z2", "z2_progression_version": 1, "profile_id": "hook-fixture", "run_count": 0, "gold": 0, "talent_flags": ["z2_talent_15"]}
	var prepared: Dictionary
	for seed in range(1, 200):
		prepared = Offer.execute(meta, "prepare", {"request_id": "prepare"}, seed)
		if prepared.offer.candidates.has(effect):
			break
	var chosen := Offer.execute(prepared.meta, "choose", {"request_id": "choose", "offer_id": prepared.offer.offer_id, "effect_id": effect})
	c.run_start_config["z2_opening_offer"] = chosen.meta.z2_opening_offer.duplicate(true)
	_check(Opening.admit_departure(c, c.run_start_config.z2_opening_offer).get("ok", false), "admit actual selected effect " + effect)
	r.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	return r

func _test_tools() -> void:
	var r := _runtime("dismantle")
	var c: RunContext = r.context
	for index in range(2):
		var item := Items.definition("col_01")
		item.instance_id = "scrap:%d" % index
		c.asset_ledger.add_reward_items([item], &"inventory", c.get_current_pos(), "fixture")
		var request := {"instance_id": item.instance_id, "tool": "scan" if index == 0 else "trap", "action_id": "dismantle:%d" % index}
		_check(r.command_bus.dispatch(&"dismantle_opening_item", request).get("ok", false), "dismantle actual inventory instance")
		r.command_bus.dispatch(&"dismantle_opening_item", request)
	_check(int(Opening.public_state(c).effect_state.uses) == 2, "dismantle replay does not spend an extra slot")
	var visits := c.visited_cells.duplicate(true)
	var truth := Snapshot.capture_data(c.truth_map)
	var pressure := c.pressure
	var scanned: Dictionary = r.command_bus.dispatch(&"use_opening_tool", {"tool": "scan", "action_id": "tool-scan"})
	_check(scanned.get("ok", false), "real scan tool changes intelligence")
	_check(c.pressure == pressure + 4 and int(Opening.public_state(c).effect_state.tools.scan) == 0, "scan charges pressure and one tool after benefit")
	_check(c.visited_cells == visits and Snapshot.capture_data(c.truth_map) == truth, "scan never changes actual visits or truth")
	var pos := Vector2i(1, 2)
	c.truth_map.set_room_type(pos, &"Event")
	# The threshold tool case targets the mechanical member; canonical mechanism
	# now legitimately chooses either the mechanical or electric variant.
	c.z1_event_rooms[c.cell_key(pos)] = {"event_type": &"trap"}
	_check(_enter(r, pos).get("ok", false), "actual mechanism entry")
	var state := EventService.get_event_state(c, pos)
	if state.has("threshold"):
		var threshold := float(state.threshold)
		c.power = ceili(threshold) - 1
		_check(r.command_bus.dispatch(&"use_opening_tool", {"tool": "trap", "action_id": "tool-trap"}).get("ok", false), "trap tool resolves newly feasible actual mechanism")
		_check(c.truth_map.is_cleared(pos) and int(Opening.public_state(c).effect_state.tools.trap) == 0, "tool outcome clears room and consumes once")
	else:
		_check(false, "mechanism missing threshold")
	_release(r)

func _test_room_effects() -> void:
	var r := _runtime("auto_clear")
	var c: RunContext = r.context
	for pos in [Vector2i(1, 2), Vector2i(2, 2)]:
		c.truth_map.set_room_type(pos, &"Monster")
		_check(_enter(r, pos).get("ok", false) and c.truth_map.is_cleared(pos), "first two ordinary rooms clear before enemy spawn")
	_check(c.asset_ledger.item_instances.is_empty() and c.asset_ledger.get_currency(&"black_coin") == 0 and int(c.run_stats.monsters_defeated) == 0, "automatic clear has no normal drops or growth")
	var chest := Vector2i(2, 3)
	c.truth_map.set_room_type(chest, &"Chest")
	_enter(r, chest)
	r.command_bus.dispatch(&"search_current_room", {})
	for tick in range(12):
		r.advance_idle_frame(0.25)
	_check(c.searched_cells.has(c.cell_key(chest)) and c.asset_ledger.item_instances.is_empty() and c.asset_ledger.get_currency(&"black_coin") == 0, "first full chest search is actually empty")
	_release(r)
	r = _runtime("mine_pressure")
	c = r.context
	c.pressure = 50
	for pos in [Vector2i(1, 2), Vector2i(2, 2), Vector2i(2, 3)]:
		c.truth_map.set_room_type(pos, &"Mine")
		_check(_enter(r, pos).get("ok", false), "actual mine entry")
	_check(int(Opening.public_state(c).effect_state.mine_uses) == 3, "only actual first three triggers consume exchange")
	_check(c.pressure < 50, "actual mine pressure decreases instead of ordinary increase")
	_release(r)

func _test_statuses_and_end() -> void:
	var r := _runtime("status_clear")
	var c: RunContext = r.context
	for id in ["con_tape_roll", "con_waiver_medicine", "con_countdown_pill"]:
		var item := Items.definition(id)
		item.instance_id = id
		c.asset_ledger.add_reward_items([item], &"inventory", c.get_current_pos(), "fixture")
		_check(r.command_bus.dispatch(&"use_consumable", {"instance_id": id}).get("ok", false), "actual temporary effect use " + id)
		var receipts: int = c.z1_event_flags.z2_opening.receipts.size()
		r.advance_idle_frame(0.02)
		_check(c.z1_event_flags.z2_opening.receipts.size() == receipts, "status time alone never creates opening receipts " + id)
	_check(c.temporary_statuses.all(func(status: Dictionary) -> bool: return str(status.get("phase", "")) == "ended") and int(Opening.public_state(c).effect_state.uses) == 1, "third distinct actual temporary effect triggers clear")
	_check(c.asset_ledger.get_items_by_location(&"consumed").size() == 3, "clear does not refund paid items")
	_release(r)
	r = _runtime("power_life")
	c = r.context
	_check(c.max_hp == 110 and c.power == 18, "frozen20 opening gives10 maxHP and costs2 power")
	c.hp = 75
	_check(r.command_bus.dispatch(&"end_opening_effect", {"action_id": "end-effect"}).get("ok", false), "actual end effect command")
	_check(c.max_hp == 100 and c.hp == 75 and c.power == 20, "end removes contributions without healing")
	r.command_bus.dispatch(&"end_opening_effect", {"action_id": "end-effect"})
	_check(c.max_hp == 100 and c.power == 20, "end replay cannot reverse twice")
	_release(r)

func _enter(r, pos: Vector2i) -> Dictionary:
	return r.execute_atomic_operation(&"fixture_room_entry", {"pos": pos}, func() -> Dictionary:
		r.context.player_pos = pos
		r.context.current_pos = pos
		return r.command_bus.room_resolver.enter_room(r.context))

func _test_avoidance_and_cash() -> void:
	var r := _runtime("avoidance")
	var c: RunContext = r.context
	for index in range(8):
		var pos := Vector2i(index % 7, index / 7)
		c.truth_map.set_room_type(pos, &"Normal")
		_check(_enter(r, pos).get("ok", false), "real new safe room increases avoidance progress")
		_enter(r, pos)
		_check(int(Opening.public_state(c).effect_state.rooms) == index + 1, "revisit does not advance avoidance")
	_check(c.power == 24 and Opening.public_state(c).attack_allowed, "eight distinct rooms grant frozen20 percent and release attacks")
	_release(r)
	r = _runtime("forced_cash")
	c = r.context
	var item := Items.definition("col_01")
	var count := floori(float(c.asset_ledger.backpack_capacity) * 0.8 / int(item.weight)) + 1
	var proceeds := count * floori(int(item.base_value) * 0.6)
	var last_request := {}
	for index in range(count):
		item.instance_id = "cash:%d" % index
		c.asset_ledger.add_reward_items([item], &"room_floor", c.get_current_pos(), "fixture")
		last_request = {"instance_id": item.instance_id, "action_id": "cash-pickup:%d" % index}
		_check(r.command_bus.dispatch(&"pickup_ground_item", last_request).get("ok", false), "actual pickup with forced-cash threshold")
		if index < count - 1:
			_check(bool(Opening.public_state(c).effect_state.active), "no sale before strictly exceeding80percent")
	_check(not Opening.public_state(c).effect_state.active and c.asset_ledger.backpack_capacity == 100, "actual pickup triggers sale and removes capacity bonus")
	_check(c.asset_ledger.get_currency(&"black_coin") == proceeds and c.asset_ledger.get_items_by_location(&"consumed").size() == count, "forced sale preserves each sold original identity and exact proceeds")
	r.command_bus.dispatch(&"pickup_ground_item", last_request)
	_check(c.asset_ledger.get_currency(&"black_coin") == proceeds, "replayed pickup cannot sell twice")
	_release(r)

func _test_sacrifice_combat() -> void:
	var r := _runtime("sacrifice")
	var c: RunContext = r.context
	var pos := Vector2i(0, 0)
	c.truth_map.set_room_type(pos, &"Monster")
	_check(_enter(r, pos).get("ok", false), "real sacrifice combat enters")
	r.in_run_runtime.sync_room(Vector2(0.5, 0.5))
	var simulation = r.in_run_runtime.simulation
	if simulation == null:
		_check(false, "ordinary room creates simulation")
		_release(r)
		return
	c.power = 500
	simulation.set_arena_obstacles([])
	for enemy in simulation.enemies:
		enemy.entry_grace_remaining = 100.0
	for tick in range(600):
		if not r.in_run_runtime.has_active_combat():
			break
		simulation = r.in_run_runtime.simulation
		var target := {}
		for enemy in simulation.enemies:
			if enemy.hp > 0:
				target = enemy
				break
		if target.is_empty():
			break
		var offset: Vector2 = Vector2(target.pos) - Vector2(simulation.player.pos)
		var aim := offset.normalized()
		r.in_run_runtime.request_attack(aim)
		r.in_run_runtime.advance_frame(1.0 / 60.0, aim if offset.length() > 0.15 else Vector2.ZERO, aim)
	_check(c.truth_map.is_cleared(pos) and c.max_hp == 95 and int(Opening.public_state(c).effect_state.uses) == 1, "real clear charges5 maximumHP exactly once")
	_check(c.power == 502 + int(c.run_stats.get("monster_power_bonus", 0)), "sacrifice adds2 separately from ordinary growth")
	_enter(r, pos)
	_check(c.max_hp == 95 and int(Opening.public_state(c).effect_state.uses) == 1, "cleared-room revisit does not sacrifice again")
	_release(r)

func _release(r) -> void:
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
