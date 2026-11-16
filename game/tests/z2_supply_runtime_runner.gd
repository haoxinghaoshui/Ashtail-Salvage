extends SceneTree

const PATH := "res://scripts/core/run/z2_supply_runtime.gd"
const Items := preload("res://scripts/core/content/z2_item_catalog.gd")
const Context := preload("res://scripts/core/run/run_context.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const Effects := preload("res://scripts/core/run/run_effect_applier.gd")
var runtime: Script
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(FileAccess.file_exists(PATH), "30-supply runtime exists")
	if failures.is_empty():
		runtime = load(PATH)
		_check(runtime != null and runtime.can_instantiate(), "supply module compiles")
		if failures.is_empty():
			_consumable_matrix()
			_consumable_boundaries()
			_drugs_and_damage()
			_equipment_matrix()
			_equipment_limits()
			_interactions_and_rejections()
			_partial_restart_and_event_boundaries()
			_restart_and_atomicity()
	for failure in failures:
		print("Z2_SUPPLY_CASE_FAIL " + failure)
	print("Z2_SUPPLY_RUNTIME=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _context() -> RunContext:
	var run := Context.new()
	run.start_run({"id": "t08", "mode": &"standard", "seed": 13, "width": 7, "height": 7, "power": 20, "max_hp": 100,
		"profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1},
		"manual_map": {"spawn": Vector2i(3, 3), "mines": [], "monsters": [], "events": [], "chests": [], "exits": []}})
	run.hp = 20
	run.pressure = 50
	run.asset_ledger.add_currency(&"black_coin", 150)
	return run


func _item(id: String, suffix: String = "1") -> Dictionary:
	var item: Dictionary = Items.definition(id)
	item.instance_id = id + "_" + suffix
	return item


func _equip(run: RunContext, ids: Array) -> Array:
	var equipped: Array = []
	for id in ids:
		equipped.append(_item(id))
	_check(runtime.apply_equipment_change(run, [], equipped).ok, "equip " + str(ids))
	return equipped


func _event(run: RunContext, equipped: Array, kind: String, extra: Dictionary = {}) -> Dictionary:
	var event := extra.duplicate(true)
	event.kind = kind
	return runtime.on_event(run, equipped, event)


func _consumable_matrix() -> void:
	for item: Dictionary in Items.supplies():
		if not item.can_consume:
			continue
		item.instance_id = item.item_id + "_first"
		var run := _context()
		var before := Snapshot.capture_context(run)
		var preview: Dictionary = runtime.evaluate_consumable(run, item)
		_check(preview.ok and preview.has("preview"), "normal consumption preview " + item.item_id)
		_check(Snapshot.capture_context(run) == before, "preview is pure " + item.item_id)
		var used: Dictionary = runtime.apply_consumable(run, item)
		_check(used.ok and used.get("consume_instance_id") == item.instance_id, "normal actual application " + item.item_id)
		_check(Snapshot.capture_context(run) != before, "real effect changed run " + item.item_id)
		var after := Snapshot.capture_context(run)
		_check(not runtime.apply_consumable(run, item).ok and Snapshot.capture_context(run) == after, "same consumed instance cannot apply twice " + item.item_id)
		var restarted := Context.new()
		Snapshot.install_context(restarted, Snapshot.unpack_checkpoint(Snapshot.pack_checkpoint(after)).state)
		_check(runtime.snapshot(run) == runtime.snapshot(restarted), "checkpoint preserves supply state " + item.item_id)
		_check(not runtime.apply_consumable(restarted, item).ok, "consumption receipt survives restart " + item.item_id)
		var ended := _context()
		ended.run_active = false
		var stopped := Snapshot.capture_context(ended)
		_check(not runtime.apply_consumable(ended, item).ok and Snapshot.capture_context(ended) == stopped, "invalid inactive context leaves item and state " + item.item_id)


func _consumable_boundaries() -> void:
	for row in [["con_ration", 10], ["con_med_patch", 25], ["con_hemostatic_clasp", 50]]:
		var run := _context()
		_check(runtime.apply_consumable(run, _item(row[0])).ok and run.hp == 20 + row[1], "exact heal " + row[0])
		run = _context()
		run.hp = run.max_hp
		_check(not runtime.apply_consumable(run, _item(row[0])).ok, "full HP rejects " + row[0])
	var half := _context()
	half.hp = 50
	_check(not runtime.apply_consumable(half, _item("con_hemostatic_clasp")).ok, "clasp strict below half")
	half.hp = 49
	_check(runtime.apply_consumable(half, _item("con_hemostatic_clasp")).ok and half.hp == 99, "clasp half boundary -1")
	for row in [["con_hard_shell_patch", 20], ["con_cooling_patch", 30]]:
		var run := _context()
		run.shield = 100
		run.pressure = 0
		_check(runtime.apply_consumable(run, _item(row[0])).ok and run.shield == 100 + row[1], "shield unbounded and composite works at zero pressure " + row[0])
	var battery := _context()
	_check(runtime.apply_consumable(battery, _item("con_red_battery")).ok and battery.pressure == 55, "battery immediate pressure5")
	_check(not runtime.apply_consumable(battery, _item("con_red_battery", "2")).ok, "battery pending cannot stack")
	_check(runtime.apply_consumable(battery, _item("con_cooling_patch")).ok and battery.shield == 60 and battery.pressure == 35, "battery doubles both base effects of one item")
	_check(runtime.apply_consumable(battery, _item("con_hard_shell_patch")).ok and battery.shield == 80, "battery consumed only once")
	var capped := _context()
	capped.hp = 100
	runtime.apply_consumable(capped, _item("con_red_battery"))
	_check(not runtime.apply_consumable(capped, _item("con_ration")).ok, "failed heal preserves battery")
	capped.hp = 99
	_check(runtime.apply_consumable(capped, _item("con_ration")).ok and capped.hp == 100, "capped real heal still consumes item and battery")
	var calm := _context()
	runtime.apply_consumable(calm, _item("con_calm_candy"))
	_check(calm.pressure == 40 and not runtime.apply_consumable(calm, _item("con_calm_candy", "2")).ok, "candy immediate10 and duplicate rejection")
	for expected in [48, 56, 66]:
		_event(calm, [], "pressure", {"packet": {"amount": 10}})
		_check(calm.pressure == expected, "candy exactly two reductions")
	var clean := _context()
	clean.pressure = 0
	_check(not runtime.apply_consumable(clean, _item("con_stabilizer")).ok, "stabilizer zero benefit rejects")
	clean.temporary_statuses = [_negative("bleed", "bleeding"), _negative("poison", "poison")]
	_check(runtime.apply_consumable(clean, _item("con_stabilizer")).ok, "stabilizer cleanse only is benefit")
	_check(clean.temporary_statuses[1].phase == "ended" and clean.temporary_statuses[0].phase == "active", "poison before bleeding, cleanse one")
	var exchange := _context()
	runtime.apply_consumable(exchange, _item("con_ledger_seal_paper"))
	_check(exchange.asset_ledger.get_currency(&"black_coin") == 50 and exchange.asset_ledger.get_currency(&"gold_coin") == 80, "ledger cap100 at80 percent into safe gold")
	_check(not runtime.apply_consumable(exchange, _item("con_ledger_seal_paper", "2")).ok, "ledger once per run")
	exchange = _context()
	exchange.asset_ledger.currency_balances[&"black_coin"] = 1
	_check(not runtime.apply_consumable(exchange, _item("con_ledger_seal_paper")).ok, "ledger zero output rejects")
	exchange.asset_ledger.currency_balances[&"black_coin"] = 2
	_check(runtime.apply_consumable(exchange, _item("con_ledger_seal_paper")).ok and exchange.asset_ledger.get_currency(&"gold_coin") == 1, "ledger floors 2*80 percent")
	var seal := _context()
	runtime.apply_consumable(seal, _item("con_salvage_seal"))
	_check(seal.asset_ledger.failure_salvage_capacity == 60 and not runtime.apply_consumable(seal, _item("con_salvage_seal", "2")).ok, "seal plus20 once")
	var selected := [_item("col_05"), _item("col_24"), _item("con_ration")]
	var weights: Dictionary = runtime.salvage_weights(seal, selected)
	_check(weights.weights["col_24_1"] == 35 and weights.weights["col_05_1"] == 1 and weights.weights["con_ration_1"] == 4, "seal only heaviest ordinary collectible minus10")
	_check(runtime.salvage_weights(seal, [_item("col_05")]).total_weight == 1, "seal weight floor1")
	for id in ["con_range_powder", "con_scan_pin"]:
		var run := _context()
		for y in range(7):
			for x in range(7):
				run.intel_map.reveal_cell(Vector2i(x, y), run.truth_map)
		_check(not runtime.apply_consumable(run, _item(id)).ok, "fully known map no wasted scanner " + id)
	var powder := _context()
	runtime.apply_consumable(powder, _item("con_range_powder"))
	_check(powder.intel_map.is_revealed(Vector2i(3, 1)), "powder chooses up two first")
	_check(not powder.visited_cells.has(powder.cell_key(Vector2i(3, 1))), "reveal does not count as visit")


func _drugs_and_damage() -> void:
	var tape := _context()
	tape.hp = 100
	runtime.apply_consumable(tape, _item("con_tape_roll"))
	_check(not runtime.apply_consumable(tape, _item("con_tape_roll", "2")).ok, "tape nonstacking")
	_event(tape, [], "damage", {"packet": {"amount": 5, "damage_type": "physical"}})
	_check(tape.hp == 99, "tape leaves at least1 damage")
	_event(tape, [], "damage", {"packet": {"amount": 5, "damage_type": "physical"}})
	_check(tape.hp == 94, "tape ends after actual benefit")
	var waiver := _context()
	waiver.hp = 100
	runtime.apply_consumable(waiver, _item("con_waiver_medicine"))
	_check(waiver.pressure == 60, "waiver cost10")
	runtime.advance_time(waiver, 100.0)
	_event(waiver, [], "combat_started", {"actual": true})
	waiver.shield = 100
	for unused in range(4):
		_event(waiver, [], "damage", {"packet": {"amount": 20, "damage_type": "physical"}})
	_check(waiver.shield == 60, "waiver four shielded physical hits each halved")
	_event(waiver, [], "damage", {"packet": {"amount": 20, "damage_type": "physical"}})
	_check(waiver.shield == 40, "fifth hit unmodified")
	waiver = _context()
	runtime.apply_consumable(waiver, _item("con_waiver_medicine"))
	_event(waiver, [], "combat_started", {"actual": true})
	runtime.apply_consumable(waiver, _item("con_ration"))
	_check(waiver.hp == 25, "waiver halves healing after bonuses")
	runtime.advance_time(waiver, 20.0)
	runtime.apply_consumable(waiver, _item("con_ration", "2"))
	_check(waiver.hp == 35, "waiver expiry restores healing")
	for ending in ["combat_ended", "retreat"]:
		var drug := _context()
		runtime.apply_consumable(drug, _item("con_waiver_medicine"))
		_event(drug, [], "combat_started", {"actual": true})
		_event(drug, [], ending)
		runtime.apply_consumable(drug, _item("con_ration"))
		_check(drug.hp == 30, "drug ends at " + ending)
	var pill := _context()
	runtime.apply_consumable(pill, _item("con_countdown_pill"))
	_check(pill.max_hp == 85 and pill.pressure == 62, "pill exact maxHP15 and pressure12 costs")
	_event(pill, [], "combat_started", {"actual": true})
	runtime.advance_time(pill, 50.0)
	_check(runtime.attack_power(pill, 20) == 20, "pill waits for first attack, not combat entry")
	_event(pill, [], "first_attack", {"actual": true})
	_check(runtime.attack_power(pill, 20) == 25, "first actual attack already has25 percent")
	_event(pill, [], "damage", {"packet": {"amount": 200, "damage_type": "physical"}})
	_check(pill.hp == 1, "pill one direct lethal protection")
	_event(pill, [], "damage", {"packet": {"amount": 200, "damage_type": "physical"}})
	_check(pill.hp == 0, "pill cannot protect twice")
	for max_hp in [15, 16]:
		var low := _context()
		low.max_hp = max_hp
		low.hp = max_hp
		_check(runtime.apply_consumable(low, _item("con_countdown_pill")).ok == (max_hp == 16), "pill full max-HP payment boundary %d" % max_hp)
	var duration := _context()
	_event(duration, [], "combat_started", {"actual": true})
	runtime.apply_consumable(duration, _item("con_countdown_pill"))
	runtime.advance_time(duration, 11.99)
	_check(runtime.attack_power(duration, 20) == 25, "pill active before12 seconds")
	_event(duration, [], "offline", {"delta": 999.0})
	_check(runtime.attack_power(duration, 20) == 25, "offline freezes drug timer")
	runtime.advance_time(duration, 0.01)
	_check(runtime.attack_power(duration, 20) == 20 and duration.max_hp == 85, "pill expires without refunding maxHP")
	_check(not runtime.apply_consumable(duration, _item("con_countdown_pill", "2")).ok, "pill one use even after expiry")


func _equipment_matrix() -> void:
	for item: Dictionary in Items.supplies():
		if not item.can_equip:
			continue
		item.instance_id = item.item_id + "_one"
		var run := _context()
		var before := Snapshot.capture_context(run)
		var params: Dictionary = runtime.equipment_parameters([item])
		_check(params.ok and Snapshot.capture_context(run) == before, "equipment parameter query " + item.item_id)
		_check(runtime.apply_equipment_change(run, [], [item]).ok, "equipment actual apply " + item.item_id)
		_check(runtime.on_departure(run, [item]).ok, "equipment departure " + item.item_id)
		var saved: Dictionary = runtime.snapshot(run)
		var restart := Context.new()
		Snapshot.install_context(restart, Snapshot.unpack_checkpoint(Snapshot.pack_checkpoint(Snapshot.capture_context(run))).state)
		_check(runtime.snapshot(restart) == saved, "equipment restart " + item.item_id)
		_check(not runtime.apply_equipment_change(run, [item], [item, item]).ok, "duplicate instance/slot denied " + item.item_id)
		_check(runtime.apply_equipment_change(run, [item], []).ok and runtime.apply_equipment_change(run, [], [item]).ok, "equipment remove and re-equip " + item.item_id)
		_check(runtime.on_departure(run, [item]).get("shield_added", -1) == 0, "departure shield never regranted " + item.item_id)
	var vest := _context()
	vest.hp = 95
	var gear := _equip(vest, ["eq_old_vest"])
	_check(vest.max_hp == 105 and vest.hp == 95, "vest +5 max, no free heal")
	vest.hp = 104
	runtime.apply_equipment_change(vest, gear, [])
	_check(vest.hp == 100 and vest.max_hp == 100, "unequip clamps absolute HP")
	var shovel := _context()
	var tools := _equip(shovel, ["eq_folding_shovel"])
	_check(shovel.power == 50, "shovel +30 power")
	_event(shovel, tools, "ordinary_clear", {"room_id": "A", "actual": true})
	_check(shovel.pressure == 54, "shovel actual clear pressure4")
	_event(shovel, tools, "ordinary_clear", {"room_id": "B", "actual": false})
	_check(shovel.pressure == 54, "automatic clear excluded")
	var opener := _context()
	_equip(opener, ["eq_edge_opener"])
	_check(opener.power == 25, "opener +5 power")
	var bag := _context()
	_equip(bag, ["eq_recovery_bag"])
	_check(bag.asset_ledger.backpack_capacity == 110, "bag +10 loot capacity")
	var goggles := _context()
	_equip(goggles, ["eq_goggles"])
	runtime.apply_consumable(goggles, _item("con_scan_pin"))
	var diagonal_count := 0
	for delta in [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1)]:
		diagonal_count += int(goggles.intel_map.is_revealed(Vector2i(3, 3) + delta))
	_check(diagonal_count == 1, "goggles one unknown diagonal on basic scan")


func _equipment_limits() -> void:
	var guard := _context()
	guard.hp = 100
	var head := _equip(guard, ["eq_debris_brow_guard"])
	for unused in range(10):
		guard.hp = 100
		_event(guard, head, "damage", {"packet": {"amount": 10, "damage_type": "physical"}})
		_check(guard.hp == 91, "brow guard 10 percent")
	guard.hp = 100
	_event(guard, head, "damage", {"packet": {"amount": 10, "damage_type": "physical"}})
	_check(guard.hp == 90, "guard eleventh hit exhausted")
	runtime.apply_equipment_change(guard, head, [])
	runtime.apply_equipment_change(guard, [], head)
	guard.hp = 100
	_event(guard, head, "damage", {"packet": {"amount": 10, "damage_type": "physical"}})
	_check(guard.hp == 90, "reequip does not reset guard")
	for row in [["eq_pressure_relief_wrench", 10, 10, 5, "combat"], ["eq_insulated_sleeve", 5, 7, 6, "other"]]:
		var run := _context()
		var equipped := _equip(run, [row[0]])
		for unused in range(row[1]):
			run.pressure = 0
			_event(run, equipped, "pressure", {"packet": {"amount": row[2], "source_kind": row[4]}})
			_check(run.pressure == row[3], "pressure reduction and floor " + row[0])
		run.pressure = 0
		_event(run, equipped, "pressure", {"packet": {"amount": row[2], "source_kind": row[4]}})
		_check(run.pressure == row[2], "pressure use limit " + row[0])
	var buckle := _context()
	var rig := _equip(buckle, ["eq_buffer_buckle"])
	runtime.on_departure(buckle, rig)
	_check(buckle.shield == 15, "buckle departure15")
	for n in range(4):
		buckle.hp = 100
		buckle.shield = 0
		_event(buckle, rig, "damage", {"packet": {"amount": 10, "damage_type": "mine"}})
		_check(buckle.hp == (95 if n < 3 else 90), "buckle three mine reductions")
	for row in [["eq_etched_sleeve", "event_stage", 10, 5], ["eq_strapped_backplate", "ordinary_clear", 5, 6]]:
		var run := _context()
		var equipped := _equip(run, [row[0]])
		for n in range(row[2] + 1):
			_event(run, equipped, row[1], {"event_id": str(n), "room_id": str(n), "actual": true, "valid": true, "noncombat": true})
		_check(run.shield == row[2] * row[3], "shield hook finite limit " + row[0])
	var signal_run := _context()
	var device := _equip(signal_run, ["eq_signal_pin"])
	for room in ["one", "one", "two", "three"]:
		_event(signal_run, device, "ordinary_clear", {"room_id": room, "actual": true})
	_check(signal_run.asset_ledger.failure_salvage_capacity == 60, "signal base10 plus two distinct clears5")
	var pendant := _context()
	var pendant_gear := _equip(pendant, ["eq_seam_finder_pendant"])
	for n in range(11):
		_event(pendant, pendant_gear, "search_completed", {"room_id": str(n), "new_output_base_value": 123456})
	_check(pendant.asset_ledger.get_currency(&"black_coin") == 123600, "pendant 10 times, floor value10 percent and no money cap")
	var badge := _context()
	var badge_gear := _equip(badge, ["eq_old_work_badge"])
	badge.asset_ledger.backpack_capacity = 0
	for n in range(4):
		_event(badge, badge_gear, "random_reward_event", {"room_id": str(n), "ordinary_random": true, "noncombat": true, "extra_item": Items.definition("col_21")})
	_check(badge.asset_ledger.get_room_floor_items(badge.get_current_pos()).size() == 3, "badge three actual extra items, full bag drops floor")
	var bell := _context()
	var bell_gear := _equip(bell, ["eq_black_box_bell"])
	bell.hp = 40
	_event(bell, bell_gear, "damage", {"packet": {"amount": 15, "damage_type": "physical"}})
	_check(bell.hp == 40 and bell.shield == 25, "bell triggers below30 percent and resolves same hit using40 shield")
	bell.pressure = 0
	_event(bell, bell_gear, "pressure", {"packet": {"amount": 5}})
	_check(bell.pressure == 6, "bell extra1 after trigger")
	bell.shield = 0
	_event(bell, bell_gear, "damage", {"packet": {"amount": 15, "damage_type": "physical"}})
	_check(bell.hp == 25, "bell once per instance")


func _restart_and_atomicity() -> void:
	var run := _context()
	var equipped := _equip(run, ["eq_debris_brow_guard", "eq_black_box_bell"])
	_event(run, equipped, "combat_started", {"actual": true})
	runtime.apply_consumable(run, _item("con_waiver_medicine"))
	runtime.advance_time(run, 7.0)
	var restart := Context.new()
	Snapshot.install_context(restart, Snapshot.unpack_checkpoint(Snapshot.pack_checkpoint(Snapshot.capture_context(run))).state)
	for context in [run, restart]:
		_event(context, equipped, "damage", {"packet": {"amount": 20, "damage_type": "physical"}})
		runtime.advance_time(context, 13.0)
	_check(Snapshot.capture_context(run) == Snapshot.capture_context(restart), "same actions after restart preserve timers, counts and effects")
	var invalid := _context()
	invalid.vitals_modifiers["heal"] = "invalid"
	var before := Snapshot.capture_context(invalid)
	_check(not runtime.apply_consumable(invalid, _item("con_ration")).ok and Snapshot.capture_context(invalid) == before, "pipeline rejects without consumption or partial changes")
	var saved: Dictionary = runtime.snapshot(run)
	var copy := _context()
	runtime.restore(copy, saved)
	_check(runtime.snapshot(copy) == saved, "module snapshot/restore API")


func _interactions_and_rejections() -> void:
	for item: Dictionary in Items.supplies():
		if not item.can_equip:
			continue
		item.instance_id = item.item_id + "_stale"
		var run := _context()
		runtime.apply_equipment_change(run, [], [item])
		var before := Snapshot.capture_context(run)
		_check(not runtime.apply_equipment_change(run, [], [item]).ok and Snapshot.capture_context(run) == before, "reject stale equipment before-set " + item.item_id)
		_check(runtime.apply_equipment_change(run, [item], [item]).ok and Snapshot.capture_context(run) == before, "repeated identical sync is no-op " + item.item_id)
		item.instance_id = ""
		_check(not runtime.equipment_parameters([item]).ok, "equipment requires persistent instance ID " + item.item_id)
	var guarded := _context()
	var head := _equip(guarded, ["eq_debris_brow_guard"])
	var before: Dictionary = runtime.snapshot(guarded)
	_event(guarded, head, "damage", {"packet": {"amount": 1, "damage_type": "physical"}})
	_check(runtime.snapshot(guarded) == before, "guard no actual reduction preserves charge")
	var calm := _context()
	var wrench := _equip(calm, ["eq_pressure_relief_wrench"])
	calm.pressure = 100
	before = runtime.snapshot(calm)
	_event(calm, wrench, "pressure", {"packet": {"amount": 10, "source_kind": "combat"}})
	_check(runtime.snapshot(calm) == before, "pressure clamp with no actual benefit preserves charge")
	calm.pressure = 0
	_event(calm, wrench, "pressure", {"packet": {"amount": 10, "source_kind": "item_cost"}})
	_check(calm.pressure == 10 and runtime.snapshot(calm) == before, "wrench excludes noncombat nonmechanism sources")
	var insulation := _context()
	var sleeve := _equip(insulation, ["eq_insulated_sleeve"])
	insulation.pressure = 0
	_event(insulation, sleeve, "pressure", {"packet": {"amount": 100}})
	_check(insulation.pressure == 90, "insulation cap10 on large source")
	var bell := _context()
	var bell_gear := _equip(bell, ["eq_black_box_bell"])
	bell.hp = 50
	_event(bell, bell_gear, "damage", {"packet": {"amount": 20, "damage_type": "physical"}})
	_check(bell.hp == 30 and bell.shield == 0, "bell exactly30 percent does not trigger")
	bell.hp = 20
	bell.shield = 40
	_event(bell, bell_gear, "damage", {"packet": {"amount": 10, "damage_type": "physical"}})
	_check(bell.shield == 30 and runtime.snapshot(bell).counters["z2_supply:eq_black_box_bell_1"] == 1, "existing40 shield never spends bell")
	bell.shield = 0
	_event(bell, bell_gear, "damage", {"packet": {"amount": 1, "damage_type": "physical"}})
	_check(bell.shield == 39 and bell.hp == 20, "bell remaining charge works after shield falls")
	runtime.apply_equipment_change(bell, bell_gear, [])
	bell.pressure = 0
	_event(bell, [], "pressure", {"packet": {"amount": 3}})
	_check(bell.pressure == 4, "bell pressure cost persists after unequip")
	var battery := _context()
	battery.max_hp = 200
	battery.hp = 20
	battery.vitals_modifiers.z2_talents = {"enabled": true, "effects": [{"talent_id": "z2_talent_08", "effect_kind": "low_hp_healing_percent", "effect_amount": 20, "effect_params": {"hp_threshold_percent": 30}}]}
	runtime.apply_consumable(battery, _item("con_red_battery"))
	runtime.apply_consumable(battery, _item("con_hemostatic_clasp"))
	_check(battery.hp == 130, "battery and talent add on base:50*(1+1+.2)=110")
	var doubled_candy := _context()
	runtime.apply_consumable(doubled_candy, _item("con_red_battery"))
	runtime.apply_consumable(doubled_candy, _item("con_calm_candy"))
	_check(doubled_candy.pressure == 35, "battery doubles candy immediate pressure reduction")
	for expected in [41, 47, 57]:
		_event(doubled_candy, [], "pressure", {"packet": {"amount": 10}})
		_check(doubled_candy.pressure == expected, "battery doubles future reductions but not hit count")
	var combined := _context()
	_event(combined, [], "combat_started", {"actual": true})
	runtime.apply_consumable(combined, _item("con_waiver_medicine"))
	runtime.apply_consumable(combined, _item("con_red_battery"))
	runtime.apply_consumable(combined, _item("con_ration"))
	_check(combined.hp == 30, "healing reduction applies after battery")
	var cleanse := _context()
	cleanse.pressure = 0
	cleanse.temporary_statuses = [_negative("slow", "existing_negative_slow")]
	_check(runtime.apply_consumable(cleanse, _item("con_stabilizer")).ok and cleanse.temporary_statuses[0].phase == "ended", "other existing explicitly cleanseable lasting negative type")
	var no_cleanse := _context()
	no_cleanse.pressure = 0
	var permanent := _negative("cost", "paid_hp_cost")
	permanent.type = "permanent"
	no_cleanse.temporary_statuses = [permanent]
	_check(not runtime.apply_consumable(no_cleanse, _item("con_stabilizer")).ok, "cleanse cannot undo paid or permanent cost")
	var duplicate := _context()
	var pendant := _equip(duplicate, ["eq_seam_finder_pendant"])
	_event(duplicate, pendant, "search_completed", {"room_id": "same", "new_output_base_value": 0})
	_check(runtime.snapshot(duplicate).counters["z2_supply:eq_seam_finder_pendant_1"] == 10, "pendant zero reward does not use charge")
	for unused in range(2):
		_event(duplicate, pendant, "search_completed", {"room_id": "same", "new_output_base_value": 20})
	_check(duplicate.asset_ledger.get_currency(&"black_coin") == 152, "pendant duplicated completion cannot double-reward")
	var backplate := _context()
	var armor := _equip(backplate, ["eq_strapped_backplate"])
	runtime.on_departure(backplate, armor)
	_check(backplate.max_hp == 90 and backplate.shield == 30, "backplate maxHP-10 and departure30")
	var before_swap := Snapshot.capture_context(backplate)
	_event(backplate, armor, "combat_started", {"actual": true})
	_check(not runtime.apply_equipment_change(backplate, armor, []).ok, "combat locks equipment")
	Snapshot.install_context(backplate, before_swap)
	for item_id in ["con_ledger_seal_paper", "con_salvage_seal", "con_countdown_pill"]:
		var run := _context()
		runtime.apply_consumable(run, _item(item_id))
		var restart := Context.new()
		Snapshot.install_context(restart, Snapshot.unpack_checkpoint(Snapshot.pack_checkpoint(Snapshot.capture_context(run))).state)
		_check(not runtime.apply_consumable(restart, _item(item_id, "different_instance")).ok, "run limit survives restart on another instance " + item_id)


func _negative(id: String, kind: String) -> Dictionary:
	return {"id": id, "type": "temporary_debuff", "temporary_type": kind, "phase": "active", "remaining": 50.0, "dot_per_second": 1.0, "cleanseable": true}


func _partial_restart_and_event_boundaries() -> void:
	var cases := [
		["eq_debris_brow_guard", {"kind": "damage", "packet": {"amount": 10, "damage_type": "physical"}}],
		["eq_pressure_relief_wrench", {"kind": "pressure", "packet": {"amount": 10, "source_kind": "mechanism"}}],
		["eq_insulated_sleeve", {"kind": "pressure", "packet": {"amount": 20}}],
		["eq_buffer_buckle", {"kind": "damage", "packet": {"amount": 10, "damage_type": "mine"}}],
		["eq_seam_finder_pendant", {"kind": "search_completed", "room_id": "first", "new_output_base_value": 20}],
		["eq_etched_sleeve", {"kind": "event_stage", "event_id": "first", "valid": true, "noncombat": true}],
		["eq_signal_pin", {"kind": "ordinary_clear", "room_id": "first", "actual": true}],
		["eq_strapped_backplate", {"kind": "ordinary_clear", "room_id": "first", "actual": true}],
		["eq_old_work_badge", {"kind": "random_reward_event", "room_id": "first", "ordinary_random": true, "noncombat": true, "extra_item": _item("col_21", "extra_first")}],
		["eq_black_box_bell", {"kind": "damage", "packet": {"amount": 15, "damage_type": "physical"}}],
	]
	for row in cases:
		var run := _context()
		run.hp = 40
		var gear := _equip(run, [row[0]])
		runtime.on_event(run, gear, row[1])
		var key: String = "z2_supply:" + row[0] + "_1"
		_check(runtime.snapshot(run).counters[key] == int(Items.definition(row[0]).effect_params.max_uses) - 1, "first actual benefit charges instance " + row[0])
		var restarted := Context.new()
		Snapshot.install_context(restarted, Snapshot.unpack_checkpoint(Snapshot.pack_checkpoint(Snapshot.capture_context(run))).state)
		for context in [run, restarted]:
			runtime.apply_equipment_change(context, gear, [])
			runtime.apply_equipment_change(context, [], gear)
			var next_event: Dictionary = row[1].duplicate(true)
			next_event.room_id = "second"
			next_event.event_id = "second"
			if next_event.has("extra_item"):
				next_event.extra_item.instance_id = "col_21_extra_second"
			runtime.on_event(context, gear, next_event)
		_check(Snapshot.capture_context(run) == Snapshot.capture_context(restarted), "partial counters and side effects replay after restart " + row[0])
	var badge := _context()
	var badge_gear := _equip(badge, ["eq_old_work_badge"])
	for event in [
		{"kind": "random_reward_event", "room_id": "combat", "ordinary_random": true, "noncombat": false, "extra_item": _item("col_21")},
		{"kind": "random_reward_event", "room_id": "fixed", "ordinary_random": false, "noncombat": true, "extra_item": _item("col_21")},
		{"kind": "random_reward_event", "room_id": "empty", "ordinary_random": true, "noncombat": true, "extra_item": {}},
		{"kind": "random_reward_event", "room_id": "recursive", "ordinary_random": true, "noncombat": true, "supply_extra": true, "extra_item": _item("col_21")},
	]:
		var before := Snapshot.capture_context(badge)
		runtime.on_event(badge, badge_gear, event)
		_check(Snapshot.capture_context(badge) == before, "badge excludes invalid event " + str(event.room_id))
	var stage := _context()
	var sleeve := _equip(stage, ["eq_etched_sleeve"])
	_event(stage, sleeve, "event_stage", {"event_id": "combat", "valid": true, "noncombat": false})
	_event(stage, sleeve, "event_stage", {"event_id": "incomplete", "valid": false, "noncombat": true})
	_check(stage.shield == 0, "sleeve excludes combat and uncompleted stage")
	var cost := _context()
	var old_badge := _item("eq_old_work_badge")
	cost.asset_ledger.create_item_instance(Items.definition("col_13"), &"inventory")
	cost.asset_ledger.backpack_capacity = 75
	var before_capacity := Snapshot.capture_context(cost)
	_check(not runtime.apply_equipment_change(cost, [], [old_badge]).ok and Snapshot.capture_context(cost) == before_capacity, "badge -10 capacity rejected if current loot would overflow")
	var talent := _context()
	_event(talent, [], "combat_started", {"actual": true})
	talent.vitals_modifiers.z2_talents = {"enabled": true, "effects": [{"talent_id": "z2_talent_10", "effect_kind": "lethal_protection", "effect_amount": 1, "effect_params": {}}]}
	talent.vitals_counters.z2_talent_10 = 1
	runtime.apply_consumable(talent, _item("con_countdown_pill"))
	_event(talent, [], "damage", {"packet": {"amount": 200, "damage_type": "physical"}})
	_check(talent.hp == 1 and talent.vitals_counters.z2_talent_10 == 0 and runtime.snapshot(talent).counters["z2_supply:con_countdown_pill_1"] == 1, "talent protection spends before pill")
	for outcome in ["success", "failure", "abandon"]:
		var exchange := _context()
		runtime.apply_consumable(exchange, _item("con_ledger_seal_paper"))
		var result: Dictionary = {}
		match outcome:
			"success": result = exchange.asset_ledger.settle_success()
			"failure": result = exchange.asset_ledger.settle_failure([])
			"abandon": result = exchange.asset_ledger.settle_abandon()
		_check(result.get("safe_yield_retained") == 80, "safe exchange gold really retained on " + outcome)
	for invalid_amount in [0, -20]:
		var invalid_run := _context()
		var invalid_item := _item("con_hard_shell_patch")
		invalid_item.effect_amount = invalid_amount
		var before := Snapshot.capture_context(invalid_run)
		_check(not runtime.apply_consumable(invalid_run, invalid_item).ok and Snapshot.capture_context(invalid_run) == before, "invalid/nonbeneficial shield definition rejected atomically")
	var mine := _context()
	var buckle := _equip(mine, ["eq_buffer_buckle"])
	var before_mine := Snapshot.capture_context(mine)
	_check(not _event(mine, buckle, "damage", {"packet": {"amount": -3, "damage_type": "mine"}}).ok and Snapshot.capture_context(mine) == before_mine, "mine reduction cannot sanitize a negative damage packet")


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
