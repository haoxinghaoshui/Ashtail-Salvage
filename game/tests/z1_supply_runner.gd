extends SceneTree

const Catalog = preload("res://scripts/core/content/m7_content_catalog.gd")
const Items = preload("res://scripts/core/content/m3_item_catalog.gd")
const Usability = preload("res://scripts/core/content/m3r_item_usability_model.gd")
const Rules = preload("res://scripts/core/run/run_rule_service.gd")
const Loot = preload("res://scripts/core/content/z1_loot_catalog.gd")
const MetaAdapter = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Monsters = preload("res://scripts/gameplay/combat/g41_monster_catalog.gd")
const SUPPLY_IDS := [
	"con_salvage_seal", "eq_buffer_buckle", "col_clockwork_copper_dial",
	"sp_inspection_calibration_plate", "eq_pressure_relief_wrench", "eq_debris_brow_guard",
	"eq_etched_sleeve", "eq_strapped_backplate", "eq_seam_finder_pendant",
	"con_ledger_seal_paper", "con_cooling_patch", "con_hemostatic_clasp",
	"con_range_powder", "con_hard_shell_patch", "col_missing_tooth_counter",
	"col_missing_shift_roster", "sp_reset_spring", "sp_transit_lead_seal",
	"col_folded_price_board", "sp_depressurized_valve_core",
]
const WEIGHTS := [11, 13, 15, 11, 13, 12, 11, 15, 11, 9, 12, 15, 11, 13, 17, 10, 11, 15, 17, 15]
var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_catalog()
	_test_legacy_weights()
	_test_legacy_talent_capacity()
	if not Catalog.item_definition("con_salvage_seal").is_empty():
		_test_consumables()
		_test_drops()
		_test_materials()
		_test_equipment()
		_test_capacity_and_salvage()
		_test_save_roundtrip()
		_test_cross_run_recovery()
		_test_tutorial_pickups_and_isolation()
	if failures.is_empty():
		print("Z1_SUPPLIES=PASS checks=%d" % checks)
		quit(0)
	else:
		for failure in failures:
			print("Z1_SUPPLY_CASE_FAIL " + failure)
		print("Z1_SUPPLIES=FAIL failures=%d checks=%d" % [failures.size(), checks])
		quit(1)


func _test_catalog() -> void:
	var codex := Catalog.all_codex_entry_ids()
	for index in range(SUPPLY_IDS.size()):
		var item: Dictionary = Catalog.item_definition(SUPPLY_IDS[index])
		_check(not item.is_empty(), "catalog_%s" % SUPPLY_IDS[index])
		_check(int(item.get("weight", -1)) == WEIGHTS[index], "weight_%s" % SUPPLY_IDS[index])
		_check(codex.has("item:" + SUPPLY_IDS[index]), "codex_%s" % SUPPLY_IDS[index])
	_check(Items.all_items().size() == 63, "43_existing_plus_20_supplies")


func _test_legacy_weights() -> void:
	var legacy := {"item_id": "eq_recovery_bag", "instance_id": "old_bag", "weight": 3, "effect_amount": 2, "custom_note": "retained"}
	var normalized := Usability.normalize_item(legacy)
	_check(int(normalized.get("weight", -1)) == 15, "legacy_weight_normalized")
	_check(int(normalized.get("effect_amount", -1)) == 20, "legacy_capacity_bonus_normalized")
	_check(str(normalized.get("instance_id", "")) == "old_bag" and normalized.get("custom_note") == "retained", "legacy_identity_and_extra_retained")
	_check(Usability.normalize_item(normalized) == normalized, "legacy_normalization_idempotent")
	var unknown := Usability.normalize_item({"item_id": "legacy_custom_item", "instance_id": "custom_1", "weight": 7})
	_check(int(unknown.get("weight", -1)) == 7, "unknown_legacy_weight_retained")
	var profile := Usability.build_profile_interfaces({})
	_check(int(profile.get("backpack_capacity", 0)) == 100, "base_backpack_100")
	_check(int(profile.get("failure_salvage_capacity", 0)) == 40, "base_salvage_40")


func _test_legacy_talent_capacity() -> void:
	var adapter = MetaAdapter.new()
	adapter.set_active_profile_path("user://tests/z1_legacy_capacity_talents.json", "z1_legacy_capacity_talents")
	var legacy: Dictionary = adapter.save_adapter.default_meta_progress()
	legacy["career_progression_version"] = 0
	legacy["profile_exp"] = Catalog.profile_exp_for_level(9)
	legacy["profile_level"] = 9
	legacy["tutorial_completed"] = true
	legacy["unlocked_map_ids"] = ["tutorial_5x5", "classic_7x7_simple"]
	legacy["talent_flags"] = ["talent_carry_rigging", "talent_salvage_clause"]
	legacy["talent_points"] = 2
	legacy["talent_budget_granted"] = 4
	legacy["warehouse_items"] = [
		{"item_id": "eq_recovery_bag", "instance_id": "legacy_talent_bag", "weight": 3, "effect_amount": 2},
		{"item_id": "eq_signal_pin", "instance_id": "legacy_talent_pin", "weight": 1, "effect_amount": 1},
	]
	_check(adapter.save_adapter.save_json(legacy, adapter.active_meta_progress_path, false), "legacy_talent_fixture_saved")
	for reload_index in range(2):
		adapter.load_or_create_default()
		var summary: Dictionary = adapter.get_summary()
		var profile := Usability.build_profile_interfaces(summary)
		_check(int(profile.get("backpack_capacity", -1)) == 110, "legacy_talent_backpack_110_%d" % reload_index)
		_check(int(profile.get("failure_salvage_capacity", -1)) == 50, "legacy_talent_salvage_50_%d" % reload_index)
		_check(summary.get("talent_flags") == legacy["talent_flags"] and int(summary.get("talent_points", -1)) == 2 and int(adapter.data.get("talent_budget_granted", -1)) == 4, "legacy_talent_points_stable_%d" % reload_index)
		_check(adapter.save(), "legacy_talent_normalized_save_%d" % reload_index)
	var config := RunStartConfig.default_config()
	config["map_config_id"] = "classic_7x7_simple"
	config["difficulty"] = &"simple"
	config["selected_equipment_ids"] = ["legacy_talent_bag", "legacy_talent_pin"]
	var admitted := RunStartConfig.authorize_with_meta(config, adapter.get_summary())
	_check(bool(admitted.get("ok", false)), "legacy_talent_equipment_admitted")
	var context := RunContext.new()
	context.start_run(RunConfig.m7_map(admitted.get("config", {})))
	_check(context.asset_ledger.backpack_capacity == 130, "legacy_talent_and_bag_stack_to_130")
	_check(context.asset_ledger.failure_salvage_capacity == 60, "legacy_talent_and_pin_stack_to_60")


func _test_consumables() -> void:
	var context := _context()
	var seal := _add(context, "con_salvage_seal")
	_check(bool(Rules.use_consumable(context, seal).get("ok", false)), "seal_used")
	_check(context.asset_ledger.failure_salvage_capacity == 50, "seal_adds_10")
	_check(not bool(Rules.use_consumable(context, seal).get("ok", true)), "seal_cannot_repeat")
	var paper := _add(context, "con_ledger_seal_paper")
	Rules.use_consumable(context, paper)
	_check(context.asset_ledger.get_currency(RunAssetLedger.CURRENCY_GOLD) == 3, "paper_adds_3_safe_yield")
	context.hp = 60
	context.pressure = 20
	Rules.use_consumable(context, _add(context, "con_cooling_patch"))
	_check(context.hp == 64 and context.pressure == 10, "cooling_heals_and_reduces_pressure")
	var clasp := _add(context, "con_hemostatic_clasp")
	context.hp = 50
	_check(not bool(Rules.use_consumable(context, clasp).get("ok", true)), "clasp_blocked_at_half")
	_check(context.asset_ledger.item_instances[clasp]["location_state"] == &"inventory", "blocked_clasp_retains_instance")
	context.hp = 49
	_check(bool(Rules.use_consumable(context, clasp).get("ok", false)) and context.hp == 81, "clasp_below_half_heals_32")
	context.pressure = 0
	Rules.use_consumable(context, _add(context, "con_hard_shell_patch"))
	_check(context.mine_immunity == 1 and context.pressure == 3, "hard_shell_immunity_and_pressure")
	context.asset_ledger.pickup_ground_item(_ground(context, "con_range_powder"), context.get_current_pos())
	var powder := str(context.asset_ledger.get_items_by_location(&"inventory").back()["instance_id"])
	var position_before := context.get_current_pos()
	var entered_before := context.entered_cells.duplicate(true)
	var explored_before := context.explored_cells.duplicate(true)
	var result := Rules.use_consumable(context, powder)
	var target := Vector2i(3, 1)
	_check(bool(result.get("ok", false)), "powder_used")
	var info := context.intel_map.get_cell_info(target)
	var report: Dictionary = result.get("effect_result", {})
	_check(report.get("target") == target and target == position_before + Vector2i.UP * 2, "powder_targets_two_away_up_first")
	_check(context.intel_map.is_revealed(target), "powder_reveals_target")
	var room_type := context.truth_map.get_room_type(target)
	_check(info.get("room_type", &"Unknown") == room_type and report.get("room_type", &"Unknown") == room_type, "powder_reveals_room_type")
	_check(int(info.get("adjacent_mines", -1)) == 1 and int(report.get("adjacent_mines", -1)) == 1, "powder_reveals_adjacent_mines")
	_check(not bool(context.truth_map.get_cell(target).get("explored", false)) and context.explored_cells == explored_before, "powder_does_not_explore")
	_check(context.get_current_pos() == position_before and context.entered_cells == entered_before, "powder_does_not_enter_or_move")
	for direction in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
		_check(not context.intel_map.is_revealed(position_before + direction * 2), "powder_does_not_reveal_other_direction_%s" % direction)
	var empty_powder := _add(context, "con_range_powder")
	for delta in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
		context.intel_map.reveal_cell(context.get_current_pos() + delta * 2, context.truth_map)
	_check(not bool(Rules.use_consumable(context, empty_powder).get("ok", true)), "powder_no_target_blocked")
	_check(context.asset_ledger.item_instances[empty_powder]["location_state"] == &"inventory", "powder_no_target_retained")


func _test_drops() -> void:
	var seen := {}
	for source in [&"search", &"chest", &"monster", &"event", &"altar"]:
		for stage in range(1, 6):
			var rows: Array = Loot.distribution(source, &"normal", stage, 0)
			var probability := 0.0
			for row in rows:
				seen[str(row["item_id"])] = true
				probability += float(row["probability"])
			_check(is_equal_approx(probability, 1.0), "drop_probability_%s_%d" % [source, stage])
	for item_id in SUPPLY_IDS:
		if item_id == "sp_inspection_calibration_plate":
			continue
		_check(seen.has(item_id), "obtainable_%s" % item_id)
	_check(Loot.roll(&"chest", Vector2i.ONE, 8, &"normal", 2) == Loot.roll(&"chest", Vector2i.ONE, 8, &"normal", 2), "drop_deterministic")
	var content = load("res://scripts/core/run/run_content_catalog.gd")
	var context := _context()
	for seed_value in range(100):
		context.seed_value = seed_value
		for item in content.search_items(Vector2i.ONE, 2, false, 1, context):
			_check(str(item["item_id"]) != "eq_debris_brow_guard", "brow_guard_only_low_adjacency")
	context.enemy_state = {"monster_id": "z1_monster_m03"}
	_check(str(content.monster_trophy(Vector2i.ONE, 2, context).get("item_id", "")) == "sp_inspection_calibration_plate", "paired_monster_drops_inspection_plate")
	context.enemy_state = Monsters.runtime_profile(&"z1_monster_m03", 20, "卡轨巡检机")
	var paired_reward := Rules.apply_combat_reward(context, context.get_current_pos(), 2)
	var paired_items: Array = paired_reward.get("ground_items", [])
	_check(paired_items.size() == 1 and str(paired_items[0].get("item_id", "")) == "sp_inspection_calibration_plate", "paired_monster_profile_drops_inspection_plate")
	context.enemy_state = Monsters.runtime_profile(&"drone", 20, "巡检无人机")
	_check(str(content.monster_trophy(Vector2i.ONE, 2, context).get("item_id", "")) != "sp_inspection_calibration_plate", "other_monster_profile_keeps_weighted_loot")
	for stage in [1, 2]:
		for row in Loot.distribution(&"altar", &"normal", stage):
			_check(str(row["item_id"]) != "col_folded_price_board", "price_board_requires_third_stage")
	for stage in [3, 4]:
		var board_probability := 0.0
		var tier_five_probability := 0.0
		for row in Loot.distribution(&"altar", &"normal", stage):
			if row["item_id"] == "col_folded_price_board":
				board_probability = float(row["probability"])
			if int(Catalog.item_definition(str(row["item_id"])).get("collectible_level", 0)) == 5:
				tier_five_probability += float(row["probability"])
		_check(board_probability > 0.0, "price_board_reachable_stage_%d" % stage)
		_check(is_equal_approx(board_probability, tier_five_probability / 5.0), "price_board_one_of_five_tier_members_stage_%d" % stage)
	var fifth_tier_six_probability := 0.0
	var fifth_probabilities := {}
	for row in Loot.distribution(&"altar", &"normal", 5):
		var item_id := str(row["item_id"])
		var probability := float(row["probability"])
		fifth_probabilities[item_id] = probability
		if int(Catalog.item_definition(item_id).get("collectible_level", 0)) == 6:
			fifth_tier_six_probability += probability
	_check(is_equal_approx(fifth_tier_six_probability, 0.85), "altar_fifth_tier_six_85_percent")
	_check(is_equal_approx(float(fifth_probabilities.get("sp_altar_residue", 0.0)), 0.10), "altar_fifth_residue_10_percent")
	_check(is_equal_approx(float(fifth_probabilities.get("eq_recovery_bag", 0.0)), 0.05), "altar_fifth_bag_5_percent")
	_check(not fifth_probabilities.has("col_folded_price_board"), "price_board_excluded_from_fifth_stage")


func _test_materials() -> void:
	var service = load("res://scripts/core/run/z1_supply_rule_service.gd")
	var context := _context()
	var inspection := _add(context, "sp_inspection_calibration_plate")
	_check(not bool(service.exchange_material(context, inspection, &"transit").get("ok", true)), "wrong_material_rejected")
	_check(bool(service.exchange_material(context, inspection, &"inspection").get("ok", false)), "inspection_exchange")
	_check(context.asset_ledger.get_currency(&"gold_coin") == 5, "inspection_safe_yield")
	_check(context.transaction_log.size() == 2, "delivery_and_currency_transactions_recorded")
	_check(not bool(service.exchange_material(context, inspection, &"inspection").get("ok", true)), "exchange_cannot_repeat")
	_check(context.transaction_log.size() == 2, "repeat_exchange_no_duplicate_transaction")
	var spring := _add(context, "sp_reset_spring")
	context.power = 5
	_check(not bool(service.use_reset_spring(context, spring, 10).get("ok", true)), "spring_insufficient_power_preserves")
	context.power = 7
	var spring_result: Dictionary = service.use_reset_spring(context, spring, 10)
	_check(bool(spring_result.get("ok", false)) and int(spring_result.get("threshold", -1)) == 7, "spring_reduces_threshold_3")
	var valve := _add(context, "sp_depressurized_valve_core")
	var valve_result: Dictionary = service.use_valve_core(context, valve, 15)
	_check(bool(valve_result.get("ok", false)) and int(valve_result.get("hp_cost", -1)) == 10, "valve_reduces_cost_5")
	_check(not bool(service.use_valve_core(context, valve, 15).get("ok", true)), "valve_cannot_repeat")
	var transit := _add(context, "sp_transit_lead_seal")
	service.exchange_material(context, transit, &"transit")
	_check(context.asset_ledger.get_currency(&"gold_coin") == 15, "transit_safe_yield")
	var on_floor := _ground(context, "sp_reset_spring")
	_check(not bool(service.use_reset_spring(context, on_floor, 8).get("ok", true)), "floor_material_not_consumed")
	var terminal_item := _add(context, "sp_transit_lead_seal")
	context.run_active = false
	_check(not bool(service.exchange_material(context, terminal_item, &"transit").get("ok", true)), "terminal_delivery_blocked")
	_check(not bool(Rules.use_consumable(context, _add(context, "con_cooling_patch")).get("ok", true)), "terminal_consumable_blocked")


func _test_equipment() -> void:
	var effects := {
		"eq_buffer_buckle": ["mine_dmg_reduce", 5],
		"eq_debris_brow_guard": ["mine_dmg_reduce", 4],
		"eq_etched_sleeve": ["scan_hint_bonus", 1],
		"eq_strapped_backplate": ["backpack_capacity", 110],
		"eq_seam_finder_pendant": ["search_reward_bonus", 1],
	}
	for item_id in effects:
		var result := _authorize_equipment(item_id)
		_check(bool(result.get("ok", false)), "equip_authorized_%s" % item_id)
		var config: Dictionary = result.get("config", {})
		_check(int(config.get(effects[item_id][0], -1)) == int(effects[item_id][1]), "equip_effect_%s" % item_id)
	var wrench_config: Dictionary = _authorize_equipment("eq_pressure_relief_wrench").get("config", {})
	var context := RunContext.new()
	context.start_run(wrench_config)
	var applier = load("res://scripts/core/run/run_effect_applier.gd")
	applier.apply_effects(context, [applier.effect_protocol_pressure_delta(5, "combat")])
	_check(context.pressure == 4, "wrench_exact_combat_pressure")
	applier.apply_effects(context, [applier.effect_protocol_pressure_delta(5, "combat_hit")])
	_check(context.pressure == 8, "wrench_combat_pressure")
	applier.apply_effects(context, [applier.effect_protocol_pressure_delta(5, "event_trap")])
	_check(context.pressure == 12, "wrench_mechanism_pressure")
	applier.apply_effects(context, [applier.effect_protocol_pressure_delta(5, "room_explore")])
	_check(context.pressure == 17, "wrench_preserves_explore_pressure")
	_check(context.asset_ledger.get_backpack_used() == 0 and context.asset_ledger.get_equipment_used() == 13, "equipment_uses_independent_capacity")
	var prices = load("res://scripts/core/content/z1_supply_catalog.gd")
	_check(prices.out_of_run_price("con_ration") == 6 and prices.out_of_run_price("con_med_patch") == 12, "shop_prices_follow_workbook")
	_check(prices.out_of_run_price("sp_reset_spring") == -1, "non_shop_item_has_no_shop_price")


func _authorize_equipment(item_id: String) -> Dictionary:
	var definition: Dictionary = Catalog.item_definition(item_id)
	definition["instance_id"] = "equip:" + item_id
	var meta := {"warehouse_items": [definition], "unlocked_map_ids": ["classic_7x7_simple"]}
	var config := RunStartConfig.default_config()
	config["map_config_id"] = "classic_7x7_simple"
	config["difficulty"] = &"simple"
	config["selected_equipment_ids"] = [definition["instance_id"]]
	return RunStartConfig.authorize_with_meta(config, meta)


func _test_capacity_and_salvage() -> void:
	var context := _context()
	for index in range(9):
		_add(context, "col_missing_shift_roster")
	var ground_id := _ground(context, "col_missing_shift_roster")
	_check(bool(context.asset_ledger.pickup_ground_item(ground_id, context.get_current_pos()).get("ok", false)), "exact_capacity_100_allowed")
	var overflow := _ground(context, "col_missing_shift_roster")
	_check(not bool(context.asset_ledger.pickup_ground_item(overflow, context.get_current_pos()).get("ok", true)), "over_capacity_stays_floor")
	_check(context.asset_ledger.item_instances[overflow]["location_state"] == &"room_floor", "overflow_item_preserved")
	var consumable := _ground(context, "con_cooling_patch")
	_check(bool(context.asset_ledger.pickup_ground_item(consumable, context.get_current_pos()).get("ok", false)), "consumable_uses_shared_container_not_full_loot_bag")
	context.asset_ledger.equipment_capacity = context.asset_ledger.get_equipment_used()
	var shared_overflow := _ground(context, "con_cooling_patch")
	_check(not bool(context.asset_ledger.pickup_ground_item(shared_overflow, context.get_current_pos()).get("ok", true)), "full_shared_container_rejects_consumable")
	var salvage := _context()
	var gear_id := _add(salvage, "eq_buffer_buckle")
	salvage.asset_ledger.item_instances[gear_id]["location_state"] = &"equipped"
	var relic_id := _add(salvage, "col_missing_tooth_counter")
	var material_id := _add(salvage, "sp_reset_spring")
	var blocked: Dictionary = salvage.asset_ledger.settle_failure([gear_id, relic_id, material_id])
	_check(not bool(blocked.get("ok", true)), "equipment_and_inventory_share_salvage_40")
	_check(salvage.asset_ledger.item_instances[relic_id]["location_state"] == &"inventory", "blocked_salvage_preserves_items")
	var accepted: Dictionary = salvage.asset_ledger.settle_failure([gear_id, relic_id])
	_check(bool(accepted.get("ok", false)), "salvage_subset_within_40")


func _test_save_roundtrip() -> void:
	var adapter = MetaAdapter.new()
	adapter.set_active_profile_path("user://tests/z1_supply_save.json", "z1_supply_save")
	adapter.clear()
	var context := _context()
	_add(context, "col_missing_shift_roster")
	_add(context, "eq_etched_sleeve")
	_add(context, "sp_reset_spring")
	var settlement := context.asset_ledger.settle_success()
	var result := {"result_id": "z1_supply_roundtrip", "outcome": "Success", "settlement": settlement, "warehouse_lite": settlement.get("warehouse_lite", [])}
	_check(bool(adapter.apply_settlement(result).get("ok", false)), "supply_save_commits")
	adapter.load_or_create_default()
	var ids := {}
	for item in adapter.get_summary().get("warehouse_items", []):
		ids[str(item.get("item_id", ""))] = true
	_check(ids.has("col_missing_shift_roster") and ids.has("eq_etched_sleeve") and ids.has("sp_reset_spring"), "supply_save_roundtrip")
	var before: Array = adapter.get_summary().get("warehouse_items", [])
	adapter.apply_settlement(result)
	_check(adapter.get_summary().get("warehouse_items", []) == before, "settlement_repeat_no_duplicate")
	var old: Dictionary = adapter.save_adapter.default_meta_progress()
	old["warehouse_items"] = [{"item_id": "eq_recovery_bag", "instance_id": "old_saved_bag", "weight": 3, "effect_amount": 2, "custom_note": "keep"}]
	old["starter_grant_version"] = 1
	adapter.save_adapter.save_json(old, adapter.active_meta_progress_path, false)
	adapter.load_or_create_default()
	var migrated: Dictionary = adapter.get_summary()["warehouse_items"][0]
	_check(int(migrated["weight"]) == 15 and int(migrated["effect_amount"]) == 20 and migrated["custom_note"] == "keep", "legacy_disk_weight_migrates")
	adapter.save()
	adapter.load_or_create_default()
	_check(adapter.get_summary()["warehouse_items"][0] == migrated, "legacy_disk_migration_idempotent")
	var sandbox = MetaAdapter.new()
	sandbox.set_active_profile_path("user://tests/z1_supply_save_failure.json", "dev_sandbox")
	sandbox.clear()
	var before_failure: Array = sandbox.get_summary().get("warehouse_items", [])
	_check(bool(sandbox.debug_inject_next_save_failure().get("ok", false)), "save_failure_armed_in_sandbox")
	var failed_save: Dictionary = sandbox.apply_settlement(result)
	_check(not bool(failed_save.get("ok", true)), "failed_save_reported")
	_check(sandbox.get_summary().get("warehouse_items", []) == before_failure, "failed_save_rolls_back_supply_items")
	_check(bool(sandbox.apply_settlement(result).get("ok", false)), "failed_save_retry_commits_once")


func _context() -> RunContext:
	var context := RunContext.new()
	context.start_run({"id": "z1_supplies_test", "map_config_id": "classic_7x7_normal", "seed": 11011, "width": 7, "height": 7, "max_hp": 100, "power": 20, "backpack_capacity": 100, "failure_salvage_capacity": 40, "manual_map": {"spawn": Vector2i(3, 3), "mines": [Vector2i(2, 1)], "exits": [{"pos": Vector2i(6, 6), "exit_id": "exit"}]}})
	context.run_start_config = {"map_config_id": "classic_7x7_normal"}
	return context


func _test_cross_run_recovery() -> void:
	var adapter = MetaAdapter.new()
	adapter.set_active_profile_path("user://tests/z1_supply_two_run_recovery.json", "dev_sandbox")
	adapter.clear()
	var recovered_ids: Array[String] = []
	for run_index in range(2):
		var context := _context()
		var definitions := [Catalog.item_definition("col_missing_shift_roster"), Catalog.item_definition("sp_reset_spring")]
		var added := RunAssetEffectHandler.apply_effects(context, [{
			"type": RunAssetEffectHandler.EFFECT_ADD_REWARD_ITEMS,
			"source": "event_reward",
			"payload": {"item_defs": definitions, "preferred_location": &"room_floor", "room_pos": context.get_current_pos()},
		}])
		_check(bool(added.get("ok", false)), "recovery_normal_add_%d" % run_index)
		var floor_items := context.asset_ledger.get_room_floor_items(context.get_current_pos())
		_check(floor_items.size() == 2, "recovery_two_ground_items_%d" % run_index)
		for item in floor_items:
			var instance_id := str(item["instance_id"])
			_check(not recovered_ids.has(instance_id), "recovery_cross_run_identity_%d_%s" % [run_index, item["item_id"]])
			recovered_ids.append(instance_id)
			_check(bool(Rules.pickup_ground_item(context, instance_id).get("ok", false)), "recovery_normal_pickup_%d_%s" % [run_index, item["item_id"]])
		context.complete_extract()
		_check(context.extracted and not context.result_snapshot.is_empty(), "recovery_normal_extract_%d" % run_index)
		var snapshot := context.result_snapshot.duplicate(true)
		if run_index == 1:
			var before: Dictionary = adapter.data.duplicate(true)
			var disk_before := FileAccess.get_file_as_string(adapter.active_meta_progress_path)
			adapter.debug_inject_next_save_failure()
			var failed: Dictionary = adapter.apply_settlement(snapshot)
			_check(not bool(failed.get("ok", true)), "recovery_second_commit_failure_reported")
			_check(adapter.data == before, "recovery_failed_commit_restores_all_memory")
			_check(FileAccess.get_file_as_string(adapter.active_meta_progress_path) == disk_before, "recovery_failed_commit_preserves_disk")
		var committed: Dictionary = adapter.apply_settlement(snapshot)
		_check(bool(committed.get("ok", false)), "recovery_commit_%d" % run_index)
		var disk_after := FileAccess.get_file_as_string(adapter.active_meta_progress_path)
		var repeated: Dictionary = adapter.apply_settlement(snapshot)
		_check(bool(repeated.get("duplicate", false)), "recovery_repeat_commit_is_duplicate_%d" % run_index)
		_check(FileAccess.get_file_as_string(adapter.active_meta_progress_path) == disk_after, "recovery_repeat_commit_does_not_write_%d" % run_index)
		adapter.load_or_create_default()
		var warehouse_ids: Array[String] = []
		var counts := {"col_missing_shift_roster": 0, "sp_reset_spring": 0}
		for item in adapter.get_summary().get("warehouse_items", []):
			var item_id := str(item.get("item_id", ""))
			if counts.has(item_id):
				counts[item_id] += 1
				warehouse_ids.append(str(item["instance_id"]))
		_check(counts["col_missing_shift_roster"] == run_index + 1 and counts["sp_reset_spring"] == run_index + 1, "recovery_preserves_every_run_copy_%d" % run_index)
		_check(warehouse_ids.size() == recovered_ids.size(), "recovery_warehouse_identity_count_%d" % run_index)
	var carry_context := RunContext.new()
	var carried := Catalog.item_definition("eq_buffer_buckle")
	carried["instance_id"] = "legacy_carried_buckle"
	carried["weight"] = 2
	carry_context.start_run({"id": "carry_identity", "width": 7, "height": 7, "selected_equipment_items": [carried], "manual_map": {"spawn": Vector2i(3, 3)}})
	var equipped := carry_context.asset_ledger.get_items_by_location(&"equipped")
	_check(equipped.size() == 1 and str(equipped[0]["instance_id"]) == "legacy_carried_buckle" and int(equipped[0]["weight"]) == 13, "carry_identity_preserved_while_weight_normalizes")


func _test_tutorial_pickups_and_isolation() -> void:
	var context := RunContext.new()
	context.start_run(RunConfig.tutorial_5x5({"backpack_capacity": 1}))
	_check(context.asset_ledger.backpack_capacity == 100, "tutorial_runtime_capacity_100")
	_check(int(context.run_start_config["backpack_capacity"]) == 100, "tutorial_start_snapshot_capacity_100")
	var room := RoomResolver.new()
	var recovered_count := 0
	for room_pos in [Vector2i(1, 4), Vector2i(2, 3), Vector2i(3, 2), Vector2i(4, 1)]:
		context.player_pos = room_pos
		room.enter_room(context)
		var searched := room.search_current_room(context)
		_check(bool(searched.get("ok", false)), "tutorial_search_%s" % room_pos)
		var ground := context.asset_ledger.get_room_floor_items(room_pos)
		_check(not ground.is_empty(), "tutorial_ground_reward_%s" % room_pos)
		for item in ground:
			var pickup := Rules.pickup_ground_item(context, str(item["instance_id"]))
			_check(bool(pickup.get("ok", false)), "tutorial_pickup_%s_%s" % [room_pos, item["item_id"]])
			recovered_count += 1
	_check(context.asset_ledger.get_items_by_location(&"inventory").size() == recovered_count, "tutorial_all_box_rewards_fit")
	context.player_pos = Vector2i(4, 4)
	room.enter_room(context)
	context.complete_extract()
	_check(context.outcome == "Training Complete", "tutorial_real_extraction_completed")
	var adapter = MetaAdapter.new()
	adapter.set_active_profile_path("user://tests/z1_supply_tutorial_isolation.json", "z1_supply_tutorial_isolation")
	adapter.clear()
	adapter.load_or_create_default()
	var before: Dictionary = adapter.get_summary()
	_check(bool(adapter.apply_settlement(context.result_snapshot).get("ok", false)), "tutorial_completion_commits")
	adapter.load_or_create_default()
	var after: Dictionary = adapter.get_summary()
	_check(bool(after.get("tutorial_completed", false)), "tutorial_completion_persists")
	for key in ["gold", "profile_exp", "talent_points", "warehouse_items", "run_count", "history_records"]:
		_check(after.get(key) == before.get(key), "tutorial_isolated_%s" % key)


func _add(context: RunContext, item_id: String) -> String:
	return str(context.asset_ledger.create_item_instance(Catalog.item_definition(item_id), &"inventory", context.get_current_pos())["instance_id"])


func _ground(context: RunContext, item_id: String) -> String:
	return str(context.asset_ledger.create_item_instance(Catalog.item_definition(item_id), &"room_floor", context.get_current_pos())["instance_id"])


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition and not failures.has(message):
		failures.append(message)
