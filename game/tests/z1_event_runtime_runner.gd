extends SceneTree

const EventServiceScript := preload("res://scripts/core/run/event_service.gd")
const ContextScript := preload("res://scripts/core/run/run_context.gd")
const RoomResolverScript := preload("res://scripts/core/run/room_resolver.gd")
const ItemCatalog := preload("res://scripts/core/content/m3_item_catalog.gd")
const RuntimePath := "res://scripts/core/run/z1_event_runtime.gd"

class RefusingEventPipeline extends RunRulePipeline:
	func apply_modifiers(rule_context: Dictionary, default_rule_result: Dictionary) -> Dictionary:
		var result := super.apply_modifiers(rule_context, default_rule_result)
		result["ok"] = false
		result["reason"] = "test_rule_refused"
		return result

var failures: Array[String] = []
var runtime_script


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_natural_registration()
	if ResourceLoader.exists(RuntimePath):
		runtime_script = load(RuntimePath)
		_test_options_for_all_events()
		_test_costs_repeat_and_chains()
		_test_rps_and_shop()
		_test_work_order_and_coil()
		_test_items_and_terminal()
		_test_map_actions_and_cage()
		_test_boundaries_and_legacy()
		_test_event_materials()
		_test_dynamic_trap_thresholds()
		_test_instance_choices_require_ids()
	else:
		_check(false, "z1_event_runtime_missing")
	if failures.is_empty():
		print("Z1_EVENT_RUNTIME=PASS events=25 registration,options,chains,rps,shop,work_order,items,terminal,map,cage,material_delivery")
		quit(0)
	else:
		for failure in failures:
			print("Z1_EVENT_RUNTIME_CASE_FAIL " + failure)
		print("Z1_EVENT_RUNTIME=FAIL failures=%d" % failures.size())
		quit(1)


func _test_natural_registration() -> void:
	var seen := {}
	var context: RunContext = _context()
	for seed_value in range(1, 4000):
		context.seed_value = seed_value
		seen[String(EventServiceScript.get_event_type(context, Vector2i(2, 2)))] = true
	for index in range(1, 26):
		_check(seen.has("z1_event_e%02d" % index), "natural_event_%02d" % index)


func _test_options_for_all_events() -> void:
	for index in range(1, 26):
		var context: RunContext = _event(index)
		var state: Dictionary = EventServiceScript.get_event_state(context, context.get_current_pos())
		_check(String(state.get("event_type", "")) == "z1_event_e%02d" % index, "type_%02d" % index)
		_check(not state.get("options", []).is_empty(), "options_%02d" % index)
		_check(String(state.get("player_title", "")) != "", "title_%02d" % index)


func _test_costs_repeat_and_chains() -> void:
	var context: RunContext = _event(3)
	var result := _execute(context, &"convert")
	_check(bool(result.get("ok", false)) and _coin(context) == 90 and context.safe_gold == 6, "cashout_10_for_6")
	_execute(context, &"convert")
	_check(_coin(context) == 90 and context.safe_gold == 6, "cashout_repeat_no_reward")
	_set_event(context, 5, Vector2i(3, 2))
	var options: Array = EventServiceScript.get_event_state(context, context.get_current_pos()).get("options", [])
	_check(int(options[0].get("player_cost", {}).get("amount", -1)) == 6, "cashout_seal_discount")
	context = _event(9, 0)
	context.pressure = 20
	result = _execute(context, &"quiet")
	_check(not bool(result.get("ok", true)) and context.pressure == 20, "no_coin_no_pressure_effect")
	context = _event(23)
	context.pressure = 45
	_execute(context, &"massage")
	_check(context.pressure == 32 and _coin(context) == 70, "massage_floor")
	context = _event(23)
	context.pressure = 2
	_execute(context, &"footbath")
	_check(context.pressure == 2 and _coin(context) == 100, "zero_reduction_free")
	context = _event(10)
	context.pressure = 40
	_execute(context, &"buy_patch")
	_check(context.pressure == 45 and _coin(context) == 96, "emergency_patch_threshold")
	context = _event(12)
	var original_capacity: int = context.asset_ledger.backpack_capacity
	_execute(context, &"expand")
	_set_event(context, 12, Vector2i(3, 2))
	_execute(context, &"expand")
	_check(context.asset_ledger.backpack_capacity == original_capacity + 20 and _coin(context) == 92, "capacity_once_per_run")


func _test_rps_and_shop() -> void:
	var context: RunContext = _event(22)
	var pos := context.get_current_pos()
	_execute(context, &"rock")
	var state_before: Dictionary = context.get("z1_event_rooms")[context.cell_key(pos)].duplicate(true)
	_set_event(context, 3, Vector2i(3, 2))
	_set_event(context, 22, pos)
	_check(context.get("z1_event_rooms")[context.cell_key(pos)] == state_before, "rps_revisit_keeps_results")
	for index in range(30):
		if bool(EventServiceScript.get_event_state(context, pos).get("completed", false)):
			break
		_execute(context, [&"rock", &"paper", &"scissors"][index % 3])
	_check(bool(EventServiceScript.get_event_state(context, pos).get("completed", false)), "rps_best_of_three_finishes")
	var final_coin := _coin(context)
	_execute(context, &"rock")
	_check(_coin(context) == final_coin and final_coin >= 100 and final_coin <= 140, "rps_reward_once")
	context = _event(25, 500)
	var shop_state: Dictionary = EventServiceScript.get_event_state(context, context.get_current_pos())
	_check(shop_state.get("stock", []).size() == 3, "shop_three_slots")
	var stock: Array = shop_state.get("stock", []).duplicate(true)
	_execute(context, &"buy_0")
	_check(context.asset_ledger.get_items_by_location(&"inventory").size() == 1, "shop_prefers_inventory")
	var paid_coin := _coin(context)
	_execute(context, &"buy_0")
	_check(_coin(context) == paid_coin, "shop_slot_once")
	_check(int(context.run_stats.get("events_completed", 0)) == 1, "shop_first_purchase_progress")
	_execute(context, &"refresh")
	_check(_coin(context) == paid_coin - 5, "shop_refresh_cost")
	shop_state = EventServiceScript.get_event_state(context, context.get_current_pos())
	_check(shop_state.get("stock", []).size() == 3 and not bool(shop_state.get("completed", true)), "shop_trade_after_progress")
	_check(not stock.is_empty(), "shop_seeded_stock")
	var stock_ids := {}
	for slot in shop_state.get("stock", []):
		stock_ids[slot.get("item_id", "")] = true
	_check(stock_ids.size() == 3, "shop_slots_are_distinct")
	var filtered: Array = runtime_script.new().call("_stock_from_offers", context, context.get_current_pos(), 0, [
		{"item_id": "con_ration", "price": 6}, {"item_id": "con_med_patch", "price": 12},
		{"item_id": "con_scan_pin"}, {"item_id": "con_tape_roll", "price": 0},
		{"item_id": "con_ration", "price": 6},
	])
	_check(filtered.size() == 2, "shop_skips_missing_zero_price_and_duplicates")
	for slot in filtered:
		_check(int(slot.get("price", 0)) == (8 if slot.get("item_id") == "con_ration" else 16), "shop_ceil_price_" + String(slot.get("item_id", "")))


func _test_work_order_and_coil() -> void:
	var context: RunContext = _event(20)
	var origin := context.get_current_pos()
	_execute(context, &"start_work")
	var resolver = RoomResolverScript.new()
	for pos in [Vector2i(1, 2), Vector2i(1, 3), Vector2i(2, 3)]:
		context.player_pos = pos
		context.current_pos = pos
		resolver.enter_room(context)
	context.player_pos = origin
	context.current_pos = origin
	resolver.enter_room(context)
	_execute(context, &"claim_work")
	_check(_coin(context) == 108, "work_order_three_new_rooms")
	_execute(context, &"claim_work")
	_check(_coin(context) == 108, "work_order_once")
	context = _event(18)
	_execute(context, &"calibrate")
	var normal := Vector2i(1, 2)
	context.player_pos = normal
	context.current_pos = normal
	resolver.enter_room(context)
	var before: int = context.asset_ledger.item_instances.size()
	resolver.search_current_room(context)
	_check(context.asset_ledger.item_instances.size() == before + 2, "coil_adds_one_normal_item")
	_check(not bool(context.get("z1_event_flags").get("coil_pending", true)), "coil_consumed_once")


func _test_items_and_terminal() -> void:
	var context: RunContext = _event(6)
	var tape := context.asset_ledger.create_item_instance(_item("con_tape_roll"), &"inventory")
	_execute(context, &"safe_open", {"instance_id": tape.get("instance_id", "")})
	_check(context.hp == 100 and _coin(context) == 106, "power_cut_tape_safe")
	_check(context.mine_immunity == 0, "handoff_does_not_use_tape_effect")
	context = _event(13)
	var first := context.asset_ledger.create_item_instance(_item("col_01"), &"inventory")
	var second := context.asset_ledger.create_item_instance(_item("col_02"), &"inventory")
	var first_id := String(first.get("instance_id", ""))
	var second_id := String(second.get("instance_id", ""))
	var result := _execute(context, &"compress", {"instance_ids": [first_id, first_id]})
	_check(not bool(result.get("ok", true)) and context.asset_ledger.get_items_by_location(&"inventory").size() == 2, "compression_duplicate_rejected_atomically")
	result = _execute(context, &"compress", {"instance_ids": [first_id, second_id]})
	_check(bool(result.get("ok", false)) and context.asset_ledger.get_items_by_location(&"inventory").is_empty(), "compression_consumes_two")
	context = _event(13)
	first = context.asset_ledger.create_item_instance(_item("col_01"), &"inventory")
	second = context.asset_ledger.create_item_instance(_item("col_02"), &"inventory")
	var third := context.asset_ledger.create_item_instance(_item("col_03"), &"inventory")
	_execute(context, &"select_first", {"instance_id": third.get("instance_id", "")})
	var selected_options: Array = EventServiceScript.get_event_state(context, context.get_current_pos()).get("options", [])
	var selectable_pair := false
	for option in selected_options:
		if option.get("id") == &"compress" and option.get("payload", {}).get("instance_ids", []).has(third.get("instance_id")):
			selectable_pair = true
	_check(selectable_pair, "compression_allows_selecting_inputs")
	_execute(context, &"compress", {"instance_ids": [third.get("instance_id"), second.get("instance_id")]})
	_check(context.asset_ledger.get_items_by_location(&"inventory").size() == 1 and context.asset_ledger.get_items_by_location(&"inventory")[0].get("item_id") == "col_01", "compression_respects_selected_pair")
	for outcome in ["success", "failure", "abandon"]:
		context = _event(11)
		var item := context.asset_ledger.create_item_instance(_item("col_01"), &"inventory")
		_execute(context, &"consign", {"instance_id": item.get("instance_id", "")})
		var settlement: Dictionary = context.asset_ledger.call("settle_" + outcome)
		_check(context.asset_ledger.get_items_by_location(&"warehouse").size() == 1, "consignment_" + outcome)
		_check(settlement.get("event_item_delivery", {}).get("delivered", []).size() == 1, "consignment_exposed_" + outcome)
		if outcome == "abandon":
			_check(not settlement.has("warehouse_items") and not settlement.has("extracted_items"), "consignment_abandon_uses_event_delivery_contract")
	context = _event(15, 4)
	var collateral_def := _item("col_13")
	collateral_def["base_value"] = 21
	var collateral := context.asset_ledger.create_item_instance(collateral_def, &"inventory")
	_execute(context, &"pawn", {"instance_id": collateral.get("instance_id", "")})
	_check(_coin(context) == 16, "advance_pays_12")
	context.asset_ledger.settle_success()
	_check(context.asset_ledger.get_items_by_location(&"warehouse").size() == 1, "advance_redeems_at_16")


func _test_map_actions_and_cage() -> void:
	var context: RunContext = _event(21)
	_execute(context, &"recon_3")
	_check(context.visited_cells.size() == 1, "recon_not_visits")
	_check(not context.intel_map.is_revealed(Vector2i(2, 1)), "recon_preserves_unknown_room")
	context = _event(19)
	context.intel_map.flag_cell(Vector2i(2, 1))
	_execute(context, &"detonate", {"target_pos": Vector2i(2, 1)})
	context.player_pos = Vector2i(2, 1)
	context.current_pos = context.player_pos
	var before_hp: int = context.hp
	RoomResolverScript.new().enter_room(context)
	_check(context.hp == before_hp, "remote_mine_no_repeat_damage")
	context = _event(16)
	var result := _execute(context, &"travel")
	_check(bool(result.get("ok", false)) and context.get_current_pos() != Vector2i(2, 2), "shortcut_real_room_entry")
	context = _event(16)
	RoomResolverScript.new().interact_current_room(context)
	_check(context.get_current_pos() != Vector2i(2, 2), "shortcut_default_interaction_enters_room")
	context = _event(24)
	_execute(context, &"enter_cage")
	var cage: Dictionary = EventServiceScript.new().call("cage_state", context, context.get_current_pos())
	_check(bool(cage.get("active", false)), "cage_active")
	var before_power: int = context.power
	EventServiceScript.new().call("resolve_cage", context, context.get_current_pos(), true)
	EventServiceScript.new().call("resolve_cage", context, context.get_current_pos(), true)
	_check(context.power == before_power + int(cage.get("base_power", 0)) * 2, "cage_reward_once")
	_check(context.truth_map.is_cleared(context.get_current_pos()), "cage_clears_event_room")


func _test_boundaries_and_legacy() -> void:
	var context: RunContext = _event(1)
	var result := _execute(context, &"read", {"target_pos": Vector2i(2, 1)})
	_check(bool(result.get("ok", false)) and not context.intel_map.is_revealed(Vector2i(2, 1)), "note_does_not_reveal_room_type")
	_check(context.z1_event_intel.has(context.cell_key(Vector2i(2, 1))), "note_stores_public_count")
	_set_event(context, 4, Vector2i(3, 2))
	_execute(context, &"inspect", {"target_pos": Vector2i(3, 1)})
	_check(_coin(context) == 98, "note_reduces_ledger_price")
	context = _event(2, 12)
	_execute(context, &"take_tape")
	_check(_coin(context) == 0 and context.asset_ledger.get_room_floor_items(context.get_current_pos()).size() == 1, "requisition_exact_price_and_floor")
	context = _event(6)
	context.hp = 1
	_execute(context, &"force_open")
	_check(context.hp == 1 and _coin(context) == 106, "power_cut_leaves_one_hp")
	context = _event(8)
	var sample := context.asset_ledger.create_item_instance(_item("mon_old_gear_set"), &"inventory")
	var extra := context.asset_ledger.create_item_instance(_item("col_01"), &"inventory")
	_execute(context, &"hand_in", {"instance_id": sample.get("instance_id", ""), "instance_ids": [sample.get("instance_id", ""), extra.get("instance_id", "")]})
	_check(context.safe_gold == 5 and context.asset_ledger.get_items_by_location(&"inventory").size() == 1, "handoff_ignores_extra_forged_inputs")
	context = _event(14)
	var ration := context.asset_ledger.create_item_instance(_item("con_ration"), &"inventory")
	context.hp = 20
	_execute(context, &"return_item", {"instance_id": ration.get("instance_id", "")})
	_check(_coin(context) == 103 and context.hp == 20, "return_ration_no_heal")
	context = _event(15, 3)
	var collateral_def := _item("col_13")
	collateral_def["base_value"] = 21
	var collateral := context.asset_ledger.create_item_instance(collateral_def, &"inventory")
	_execute(context, &"pawn", {"instance_id": collateral.get("instance_id", "")})
	context.asset_ledger.settle_success()
	_check(context.asset_ledger.get_items_by_location(&"warehouse").is_empty(), "pledge_forfeited_at_15")
	context = _event(19)
	context.intel_map.flag_cell(Vector2i(3, 2))
	_execute(context, &"detonate", {"target_pos": Vector2i(3, 2)})
	_check(_coin(context) == 93 and context.pressure == 0, "wrong_detonation_still_paid")
	context = _event(25, 500)
	context.asset_ledger.backpack_capacity = 0
	context.asset_ledger.equipment_capacity = 0
	_execute(context, &"buy_0")
	_check(context.asset_ledger.get_room_floor_items(context.get_current_pos()).size() == 1, "shop_full_bag_falls_to_floor")
	var shop_before: Dictionary = EventServiceScript.get_event_state(context, context.get_current_pos())
	var shop_pos := context.get_current_pos()
	_set_event(context, 3, Vector2i(3, 2))
	_set_event(context, 25, shop_pos)
	_check(EventServiceScript.get_event_state(context, shop_pos).get("stock") == shop_before.get("stock"), "shop_revisit_keeps_stock")
	context = _context()
	context.z1_event_flags["enabled"] = false
	for seed_value in range(1, 40):
		context.seed_value = seed_value
		_check(EventServiceScript.get_event_type(context, Vector2i(2, 2)) in [&"trader", &"dice", &"altar", &"trap"], "legacy_event_mode_%d" % seed_value)
	context.z1_event_flags["expanded"] = true
	context.z1_event_rooms["2,2"] = {"event_type": &"z1_event_e12", "completed": true}
	context.reset()
	context.start_run({"id": "reset", "width": 5, "height": 5, "manual_map": {"spawn": Vector2i.ZERO}})
	_check(not context.z1_event_flags.has("expanded") and context.z1_event_rooms.is_empty(), "new_run_resets_event_state")


func _event(number: int, coins: int = 100) -> RunContext:
	var context: RunContext = _context(coins)
	_set_event(context, number, Vector2i(2, 2))
	return context


func _test_event_materials() -> void:
	var already_strong := _legacy_event(&"trap")
	var unneeded_spring := _add_material(already_strong, "sp_reset_spring")
	already_strong.power = int(EventServiceScript.get_event_state(already_strong, already_strong.get_current_pos()).get("trap_threshold", 8))
	var declined := _command_event(already_strong, &"disarm_with_spring", unneeded_spring)
	_check(not bool(declined.get("ok", true)) and _material_in_inventory(already_strong, unneeded_spring) and _coin(already_strong) == 100, "spring_not_spent_when_base_power_already_suffices")
	var context := _legacy_event(&"trap")
	var first_spring := _add_material(context, "sp_reset_spring")
	var second_spring := _add_material(context, "sp_reset_spring")
	var trap_threshold := int(EventServiceScript.get_event_state(context, context.get_current_pos()).get("trap_threshold", 8))
	context.power = trap_threshold - 4
	var before_coin := _coin(context)
	var result := _command_event(context, &"disarm_with_spring", second_spring)
	_check(not bool(result.get("ok", true)) and _material_in_inventory(context, second_spring) and _coin(context) == before_coin, "spring_insufficient_power_keeps_instance_and_reward")
	context.power = trap_threshold - 3
	_check(_has_material_option(context, &"disarm_with_spring", first_spring) and _has_material_option(context, &"disarm_with_spring", second_spring), "trap_lists_exact_spring_instances")
	result = _command_event(context, &"disarm_with_spring", "")
	_check(not bool(result.get("ok", true)) and _material_in_inventory(context, second_spring), "spring_requires_explicit_instance")
	var hp_before: int = context.hp
	var pressure_before: int = context.pressure
	result = _command_event(context, &"disarm_with_spring", second_spring)
	_check(bool(result.get("ok", false)) and _coin(context) == before_coin + 25 and context.hp == hp_before and context.pressure == pressure_before, "spring_lowers_threshold_and_grants_safe_reward")
	_check(_material_in_inventory(context, first_spring) and not _material_in_inventory(context, second_spring) and context.power == trap_threshold - 3, "spring_consumes_only_selected_instance_without_changing_power")
	_command_event(context, &"disarm_with_spring", second_spring)
	_check(_coin(context) == before_coin + 25, "spring_trap_repeat_does_not_grant_reward")
	context = _legacy_event(&"altar")
	var first_valve := _add_material(context, "sp_depressurized_valve_core")
	var second_valve := _add_material(context, "sp_depressurized_valve_core")
	context.hp = 5
	before_coin = _coin(context)
	result = _command_event(context, &"offer_with_valve", second_valve)
	_check(not bool(result.get("ok", true)) and context.hp == 5 and _material_in_inventory(context, second_valve), "valve_insufficient_hp_keeps_instance")
	context.hp = 6
	_check(_has_material_option(context, &"offer_with_valve", second_valve), "altar_lists_exact_valve_instance")
	result = _command_event(context, &"offer_with_valve", second_valve)
	_check(bool(result.get("ok", false)) and context.hp == 1 and int(context.run_stats.get("altar_stage", 0)) == 1 and _coin(context) > before_coin, "valve_discount_preserves_one_hp_and_advances_stage")
	_check(_material_in_inventory(context, first_valve) and not _material_in_inventory(context, second_valve), "valve_consumes_only_selected_instance")
	context.hp = 100
	before_coin = _coin(context)
	result = _command_event(context, &"offer_with_valve", second_valve)
	_check(not bool(result.get("ok", true)) and _material_in_inventory(context, first_valve) and _coin(context) == before_coin, "stale_valve_does_not_consume_another_instance")
	context = _legacy_event(&"altar")
	var rollback_valve := _add_material(context, "sp_depressurized_valve_core")
	context.rule_pipeline = RefusingEventPipeline.new()
	var transactions_before: int = context.transaction_log.size()
	var settlement_before: Array = context.asset_ledger.settlement_log.duplicate(true)
	before_coin = _coin(context)
	result = _command_event(context, &"offer_with_valve", rollback_valve)
	_check(not bool(result.get("ok", true)) and String(result.get("reason", "")) == "test_rule_refused", "material_rule_rejection_is_reported")
	_check(_material_in_inventory(context, rollback_valve) and context.hp == 100 and _coin(context) == before_coin and int(context.run_stats.get("altar_stage", 0)) == 0, "material_rule_rejection_restores_inventory_hp_reward_and_stage")
	_check(context.transaction_log.size() == transactions_before and context.asset_ledger.settlement_log == settlement_before and context.asset_ledger.get_room_floor_items(context.get_current_pos()).is_empty(), "material_rule_rejection_restores_logs_and_floor")
	for entry in [["sp_transit_lead_seal", 10], ["sp_inspection_calibration_plate", 5], ["mon_old_gear_set", 5]]:
		context = _event(8)
		var instance_id := _add_material(context, entry[0])
		_check(_has_material_option(context, &"hand_in", instance_id), "signoff_option_" + entry[0])
		result = _command_event(context, &"hand_in", instance_id)
		_check(bool(result.get("ok", false)) and context.safe_gold == entry[1] and not _material_in_inventory(context, instance_id), "signoff_exact_yield_" + entry[0])
		_command_event(context, &"hand_in", instance_id)
		_check(context.safe_gold == entry[1], "signoff_reward_once_" + entry[0])


func _test_dynamic_trap_thresholds() -> void:
	var cases := [
		[&"easy", 0, 15, 21], [&"easy", 8, 31, 43],
		[&"standard", 0, 19, 25], [&"standard", 8, 39, 53],
		[&"hard", 0, 25, 33], [&"hard", 8, 51, 69],
		[&"hell", 0, 30, 40], [&"hell", 8, 63, 85],
	]
	for data in cases:
		var context := _legacy_event(&"trap")
		context.run_start_config["difficulty"] = data[0]
		var pos := context.get_current_pos()
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx != 0 or dy != 0:
					context.truth_map.set_room_type(pos + Vector2i(dx, dy), &"Mine" if data[1] == 8 else &"Normal")
		var key := context.cell_key(pos)
		context.current_adjacent_mines = 8 if data[1] == 0 else 0
		var bounds := RunBalanceCatalog.trap_power_range(data[1], data[0])
		_check(bounds == Vector2i(data[2], data[3]), "trap_threshold_exact_bounds_%s_%d" % [data[0], data[1]])
		var observed_min := 999
		var observed_max := -1
		for run_seed in range(24):
			context.seed_value = run_seed
			context.z1_event_rooms[key] = {"event_type": &"trap"}
			var state := EventServiceScript.get_event_state(context, pos)
			var threshold := int(state.get("trap_threshold", -1))
			observed_min = mini(observed_min, threshold)
			observed_max = maxi(observed_max, threshold)
		_check(observed_min >= bounds.x and observed_max <= bounds.y and observed_min < observed_max, "trap_threshold_draws_%s_%d_observed_%d_%d" % [data[0], data[1], observed_min, observed_max])

	var context := _legacy_event(&"trap")
	context.run_start_config["difficulty"] = &"hard"
	var pos := context.get_current_pos()
	var state := EventServiceScript.get_event_state(context, pos)
	var threshold := int(state.get("trap_threshold", -1))
	var key := context.cell_key(pos)
	_check(threshold > 0 and int(context.z1_event_rooms[key].get("trap_threshold", -1)) == threshold, "trap_threshold_stored_for_room")
	var normal_option: Dictionary = state.get("options", [])[0]
	_check(String(normal_option.get("player_title", "")).contains(str(threshold)), "trap_option_shows_actual_threshold")
	context.power += 8
	context.hp = 60
	var ration := _add_material(context, "con_ration")
	RunRuleService.use_consumable(context, ration)
	var resolver := RoomResolverScript.new()
	context.player_pos = Vector2i(1, 2)
	context.current_pos = context.player_pos
	resolver.enter_room(context)
	context.player_pos = pos
	context.current_pos = pos
	resolver.enter_room(context)
	_check(int(EventServiceScript.get_event_state(context, pos).get("trap_threshold", 0)) == threshold, "trap_stable_after_room_reentry_power_growth_and_item_use")

	var failure := _legacy_event(&"trap")
	var failure_threshold := int(EventServiceScript.get_event_state(failure, failure.get_current_pos()).get("trap_threshold", 8))
	failure.power = failure_threshold - 1
	var result := _command_event(failure, &"disarm", "")
	_check(bool(result.get("ok", false)) and failure.hp == 100 - RunBalanceCatalog.TRAP_FAILURE_DAMAGE and _coin(failure) == 100, "trap_regular_attempt_uses_threshold_failure")
	var success := _legacy_event(&"trap")
	success.power = int(EventServiceScript.get_event_state(success, success.get_current_pos()).get("trap_threshold", 8))
	result = _command_event(success, &"disarm", "")
	_check(bool(result.get("ok", false)) and success.hp == 100 and _coin(success) == 125, "trap_regular_attempt_succeeds_at_threshold")

	var retry := _legacy_event(&"trap")
	var spring := _add_material(retry, "sp_reset_spring")
	retry.power = int(EventServiceScript.get_event_state(retry, retry.get_current_pos()).get("trap_threshold", 8)) - 3
	retry.rule_pipeline = RefusingEventPipeline.new()
	result = _command_event(retry, &"disarm_with_spring", spring)
	_check(not bool(result.get("ok", true)) and _material_in_inventory(retry, spring) and _coin(retry) == 100, "trap_rejected_rule_retains_spring")
	retry.rule_pipeline = RunRulePipeline.new()
	result = _command_event(retry, &"disarm_with_spring", spring)
	_check(bool(result.get("ok", false)) and not _material_in_inventory(retry, spring) and _coin(retry) == 125, "trap_failed_rule_can_retry_same_spring_once")


func _test_instance_choices_require_ids() -> void:
	for fixture in [[8, &"hand_in", "sp_transit_lead_seal"], [11, &"consign", "col_01"]]:
		for requested_id in ["", "stale-instance"]:
			var context := _event(fixture[0])
			var available_id := _add_material(context, fixture[2])
			var result := _command_event(context, fixture[1], requested_id)
			_check(not bool(result.get("ok", true)) and _material_in_inventory(context, available_id), "event_%d_missing_or_stale_id_does_not_consume_%s" % [fixture[0], requested_id])
			_check(_coin(context) == 100 and context.safe_gold == 0 and not context.interacted_cells.has(context.cell_key(context.get_current_pos())), "event_%d_missing_or_stale_id_no_reward_or_completion_%s" % [fixture[0], requested_id])


func _legacy_event(event_type: StringName) -> RunContext:
	var context := _event(1)
	context.z1_event_rooms[context.cell_key(context.get_current_pos())]["event_type"] = event_type
	return context


func _add_material(context: RunContext, item_id: String) -> String:
	return String(context.asset_ledger.create_item_instance(_item(item_id), &"inventory").get("instance_id", ""))


func _material_in_inventory(context: RunContext, instance_id: String) -> bool:
	return context.asset_ledger.item_instances.get(instance_id, {}).get("location_state", &"") == &"inventory"


func _has_material_option(context: RunContext, option_id: StringName, instance_id: String) -> bool:
	for option in EventServiceScript.get_event_state(context, context.get_current_pos()).get("options", []):
		if option.get("id", &"") == option_id and option.get("payload", {}).get("instance_id", "") == instance_id and bool(option.get("enabled", false)):
			return true
	return false


func _command_event(context: RunContext, option_id: StringName, instance_id: String) -> Dictionary:
	var command_bus := CommandBus.new()
	command_bus.context = context
	var payload := {"option_id": option_id, "source": "z1_event_test"}
	if not instance_id.is_empty():
		payload["instance_id"] = instance_id
	var result := command_bus.dispatch(&"select_event_option", payload)
	return result.get("action_result", {})


func _context(coins: int = 100) -> RunContext:
	var context: RunContext = ContextScript.new()
	context.start_run({
		"id": "z1_event_test", "seed": 301, "width": 5, "height": 5,
		"power": 20, "backpack_capacity": 100,
		"manual_map": {"spawn": Vector2i(0, 0), "events": [Vector2i(2, 2), Vector2i(3, 2)], "mines": [Vector2i(2, 1)], "exits": [{"pos": Vector2i(4, 4), "exit_id": "test_exit", "random_exit": true}]},
	})
	context.asset_ledger.add_currency(&"black_coin", coins, "test")
	context.asset_ledger.sync_compat_fields(context)
	return context


func _set_event(context, number: int, pos: Vector2i) -> void:
	var rooms: Dictionary = context.get("z1_event_rooms")
	var key: String = context.cell_key(pos)
	if not rooms.has(key):
		rooms[key] = {"event_type": StringName("z1_event_e%02d" % number)}
	context.set("z1_event_rooms", rooms)
	context.player_pos = pos
	context.current_pos = pos
	context.current_room_type = &"Event"
	context.intel_map.reveal_cell(pos, context.truth_map)


func _execute(context, option_id: StringName, payload: Dictionary = {}) -> Dictionary:
	return RoomResolverScript.new().call("select_event_option", context, option_id, payload)


func _coin(context) -> int:
	return context.asset_ledger.get_currency(&"black_coin")


func _item(item_id: String) -> Dictionary:
	for item in ItemCatalog.all_items():
		if String(item.get("item_id", "")) == item_id:
			return item.duplicate(true)
	return {}


func _check(condition: bool, key: String) -> void:
	if not condition:
		failures.append(key)
