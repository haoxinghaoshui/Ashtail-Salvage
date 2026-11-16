extends SceneTree

const Start = preload("res://scripts/core/run/run_start_config.gd")
const Handler = preload("res://scripts/core/command/item_command_handler.gd")
const AssetEffects = preload("res://scripts/core/run/run_asset_effect_handler.gd")
const Catalog = preload("res://scripts/core/content/m7_content_catalog.gd")
const Usability = preload("res://scripts/core/content/m3r_item_usability_model.gd")
const StateSnapshot = preload("res://scripts/core/run/run_state_snapshot.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_departure_selection()
	_test_authoritative_capacity()
	_test_shared_capacity()
	_test_capacity_changes()
	_test_cross_container_replacement()
	_test_equipment_hp()
	_test_departure_shield()
	_test_instance_identity()
	_test_event_transfers()
	_test_reward_origin()
	_test_distinct_action_provenance()
	_test_blank_slot_guard()
	_test_authorized_start_hp()
	_test_max_hp_floor_roundtrip()
	_test_additional_capacity_boundaries()
	for failure in failures:
		print("Z2_CAPACITY_CASE_FAIL " + failure)
	print("Z2_CAPACITY=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_departure_selection() -> void:
	var equipment := [_gear("start_a", 20, "armor"), _gear("start_b", 20, "rig"), _gear("start_c", 20, "head")]
	var consumables := [_consumable("start_d", 10), _consumable("start_e", 10), _consumable("start_f", 10), _consumable("start_g", 10)]
	var config := Start.default_config()
	config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "selected_equipment_items": equipment, "selected_consumable_items": consumables}, true)
	var meta := {"warehouse_items": equipment + consumables, "unlocked_map_ids": ["classic_7x7_simple"], "run_count": 0}
	config["selected_objective_id"] = Catalog.commission_offer_candidates("classic_7x7_simple", 0)[0]["id"]
	_check(bool(Start.validate(config).get("ok", false)), "three_gear_four_consumables_at_100_validate")
	var normalized_start := Start.normalize(config)
	_check(int(normalized_start.get("bag_used", -1)) == 0 and int(normalized_start.get("equipment_used", -1)) == 100, "normalized_start_projects_both_containers")
	var admitted := Start.authorize_with_meta(config, meta)
	_check(bool(admitted.get("ok", false)), "three_gear_four_consumables_at_100_authorized")
	if bool(admitted.get("ok", false)):
		var context := _context(admitted["config"])
		_check(context.asset_ledger.get_equipment_used() == 100 and context.asset_ledger.get_backpack_used() == 0, "authorized_departure_uses_shared_100_backpack_0")
		_check(context.asset_ledger.item_instances.size() == 7, "authorized_departure_loses_no_instances")
	var over := config.duplicate(true)
	over["selected_consumable_items"][3]["weight"] = 11
	_check(not bool(Start.validate(over).get("ok", true)), "shared_101_rejected_by_validation")
	var overweight_meta := meta.duplicate(true)
	overweight_meta["warehouse_items"][6]["weight"] = 11
	over["equipment_capacity"] = 999
	_check(not bool(Start.authorize_with_meta(over, overweight_meta).get("ok", true)), "forged_capacity_cannot_authorize_shared_101")
	var conflict := config.duplicate(true)
	conflict["selected_equipment_items"][2]["equipment_slot"] = "armor"
	_check(not bool(Start.validate(conflict).get("ok", true)), "slot_uniqueness_retained")
	var duplicate := config.duplicate(true)
	duplicate["selected_consumable_items"].append(duplicate["selected_consumable_items"][0].duplicate(true))
	_check(not bool(Start.validate(duplicate).get("ok", true)), "duplicate_instance_rejected")
	var missing_identity := config.duplicate(true)
	missing_identity["selected_equipment_items"][0].erase("instance_id")
	_check(not bool(Start.validate(missing_identity).get("ok", true)), "normalization_cannot_invent_selected_instance_identity")
	var old_item := {"item_id": "eq_recovery_bag", "instance_id": "legacy", "weight": 3, "counters": {"left": 1}, "origin_run_id": "original"}
	var normalized := Usability.normalize_item(old_item)
	_check(normalized["weight"] == 15 and normalized["counters"] == {"left": 1} and normalized["origin_run_id"] == "original", "unit_normalization_preserves_identity_state")


func _test_authoritative_capacity() -> void:
	var gear := _gear("capacity_rig", 10, "rig", "equipment_capacity", 20)
	var supply := _consumable("capacity_supply", 110)
	var meta := {"warehouse_items": [gear, supply], "unlocked_map_ids": ["classic_7x7_simple"], "run_count": 0}
	var config := Start.default_config()
	config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "selected_equipment_items": [gear], "selected_consumable_items": [supply]}, true)
	config["selected_objective_id"] = Catalog.commission_offer_candidates("classic_7x7_simple", 0)[0]["id"]
	var admitted := Start.authorize_with_meta(config, meta)
	_check(bool(admitted.get("ok", false)), "authoritative_capacity_bonus_overrides_stale_preview_limit")
	if bool(admitted.get("ok", false)):
		_check(bool(Start.validate(admitted["config"]).get("ok", false)) and admitted["config"]["equipment_capacity"] == 120, "authorized_capacity_validates_consistently")
	config["selected_equipment_items"] = []
	config["selected_consumable_items"] = []
	config["selected_consumable_ids"] = ["heavy_a", "heavy_b", "heavy_c"]
	meta["warehouse_items"] = [_consumable("heavy_a", 40), _consumable("heavy_b", 40), _consumable("heavy_c", 40)]
	var rejected := Start.authorize_with_meta(config, meta)
	_check(not bool(rejected.get("ok", true)) and (rejected.get("issues", []) as Array).has("shared_weight_exceeds_authoritative_capacity"), "ids_only_shared_120_rejected_by_authority")


func _test_shared_capacity() -> void:
	var ledger := _ledger()
	ledger.create_item_instance(_gear("worn", 60, "armor"), RunAssetLedger.LOCATION_EQUIPPED)
	ledger.create_item_instance(_loot("loot", 100), RunAssetLedger.LOCATION_INVENTORY)
	var reward := ledger.add_reward_items([_consumable("fits", 40)], RunAssetLedger.LOCATION_INVENTORY, Vector2i.ZERO)
	_check((reward.get("inventory_items", []) as Array).size() == 1, "consumable_fits_shared_even_when_backpack_full")
	_check(ledger.get_backpack_used() == 100 and ledger.get_equipment_used() == 100, "both_containers_independent_at_100")
	var floor_item := ledger.create_item_instance(_consumable("over", 1), RunAssetLedger.LOCATION_ROOM_FLOOR, Vector2i.ZERO)
	var before := _snapshot(ledger)
	_check(not bool(ledger.pickup_ground_item(floor_item["instance_id"], Vector2i.ZERO).get("ok", true)), "shared_101_pickup_rejected")
	_check(_snapshot(ledger) == before, "failed_pickup_is_atomic")
	_check(bool(ledger.drop_inventory_item("fits", Vector2i.ZERO).get("ok", false)), "consumable_drop")
	_check(ledger.get_equipment_used() == 60 and ledger.get_backpack_used() == 100, "consumable_drop_releases_shared_only")
	_check(bool(ledger.pickup_ground_item("fits", Vector2i.ZERO).get("ok", false)), "consumable_repick")
	_check(bool(ledger.consume_inventory_item("fits").get("ok", false)) and ledger.get_equipment_used() == 60, "consumption_releases_shared")
	var spare := _ledger()
	spare.create_item_instance(_gear("spare", 100, "head"), RunAssetLedger.LOCATION_INVENTORY)
	_check(spare.get_backpack_used() == 100 and spare.get_equipment_used() == 0, "unequipped_gear_uses_backpack")
	_check(bool(spare.equip_inventory_item("spare").get("ok", false)), "equip_at_shared_100")
	_check(spare.get_backpack_used() == 0 and spare.get_equipment_used() == 100, "equip_transfers_weight_once")


func _test_capacity_changes() -> void:
	var bag := _gear("bag", 15, "rig", "backpack_capacity", 20)
	var ledger := _ledger({"backpack_capacity": 120, "selected_equipment_items": [bag]})
	ledger.create_item_instance(_loot("heavy", 90), RunAssetLedger.LOCATION_INVENTORY)
	var before := _snapshot(ledger)
	_check(not bool(ledger.unequip_item("bag").get("ok", true)), "removing_capacity_gear_checks_reduced_capacity")
	_check(_snapshot(ledger) == before, "failed_bag_removal_preserves_every_ledger_field")
	ledger.drop_inventory_item("heavy", Vector2i.ZERO)
	ledger.create_item_instance(_loot("lighter", 85), RunAssetLedger.LOCATION_INVENTORY)
	_check(bool(ledger.unequip_item("bag").get("ok", false)), "unequip_at_final_backpack_100")
	_check(ledger.backpack_capacity == 100 and ledger.get_backpack_used() == 100, "unequip_retracts_bonus_once")
	_check(bool(ledger.equip_inventory_item("bag").get("ok", false)), "re_equip_restores_capacity")
	_check(ledger.backpack_capacity == 120 and ledger.get_backpack_used() == 85, "re_equip_no_capacity_drift")
	var swap := _ledger({"backpack_capacity": 120, "selected_equipment_items": [bag]})
	swap.create_item_instance(_gear("bigger", 20, "rig", "backpack_capacity", 30), RunAssetLedger.LOCATION_INVENTORY)
	swap.create_item_instance(_loot("full", 100), RunAssetLedger.LOCATION_INVENTORY)
	_check(bool(swap.equip_inventory_item("bigger").get("ok", false)), "swap_checks_final_state_without_intermediate_overflow")
	_check(swap.get_items_by_location(RunAssetLedger.LOCATION_EQUIPPED).size() == 1 and swap.item_instances["bag"]["location_state"] == RunAssetLedger.LOCATION_INVENTORY, "swap_retains_one_item_per_slot")
	_check(swap.backpack_capacity == 130 and swap.get_backpack_used() == 115 and swap.get_equipment_used() == 20, "swap_aggregates_weight_and_capacity_deltas")
	var blocked := _ledger({"selected_equipment_items": [_gear("old", 15, "armor")]})
	blocked.create_item_instance(_consumable("shared", 85), RunAssetLedger.LOCATION_INVENTORY)
	blocked.create_item_instance(_gear("new", 20, "armor"), RunAssetLedger.LOCATION_INVENTORY)
	before = _snapshot(blocked)
	_check(not bool(blocked.equip_inventory_item("new").get("ok", true)), "swap_shared_overflow_rejected")
	_check(_snapshot(blocked) == before, "failed_swap_does_not_unwear_previous_item")
	var shared_boost := _ledger({"equipment_capacity": 120, "selected_equipment_items": [_gear("shared_bag", 10, "rig", "equipment_capacity", 20)]})
	shared_boost.create_item_instance(_consumable("supplies", 105), RunAssetLedger.LOCATION_INVENTORY)
	before = _snapshot(shared_boost)
	_check(not bool(shared_boost.unequip_item("shared_bag").get("ok", true)) and _snapshot(shared_boost) == before, "removing_shared_bonus_checks_remaining_consumables")


func _test_cross_container_replacement() -> void:
	var ledger := _ledger()
	ledger.create_item_instance(_consumable("carried", 100), RunAssetLedger.LOCATION_INVENTORY)
	ledger.create_item_instance(_loot("loot", 100), RunAssetLedger.LOCATION_INVENTORY)
	ledger.create_item_instance(_consumable("ground", 90), RunAssetLedger.LOCATION_ROOM_FLOOR, Vector2i.ZERO)
	var before := _snapshot(ledger)
	_check(not bool(ledger.replace_ground_item_with_inventory_item("ground", "loot", Vector2i.ZERO).get("ok", true)), "dropping_loot_cannot_make_shared_space")
	_check(_snapshot(ledger) == before, "cross_container_replacement_failure_atomic")
	_check(bool(ledger.replace_ground_item_with_inventory_item("ground", "carried", Vector2i.ZERO).get("ok", false)), "same_container_replacement_succeeds")
	_check(ledger.get_equipment_used() == 90 and ledger.get_backpack_used() == 100 and ledger.get_room_floor_items(Vector2i.ZERO).size() == 1, "replacement_conserves_both_buckets_and_floor")
	ledger.create_item_instance(_loot("floor_loot", 95), RunAssetLedger.LOCATION_ROOM_FLOOR, Vector2i.ZERO)
	var replaced := ledger.replace_ground_item_with_inventory_item("floor_loot", "", Vector2i.ZERO)
	_check(bool(replaced.get("ok", false)) and str(replaced.get("dropped_item", {}).get("instance_id", "")) == "loot", "auto_replacement_chooses_feasible_container")
	_check(ledger.item_instances.size() == 4, "replacement_never_duplicates_or_loses_instances")


func _test_equipment_hp() -> void:
	var context := _context()
	var handler := Handler.new()
	context.asset_ledger.create_item_instance(_gear("health", 10, "armor", "max_hp", 50), RunAssetLedger.LOCATION_INVENTORY)
	context.hp = 70
	var result: Dictionary = handler.execute(context, &"equip_item", {"instance_id": "health"})["action_result"]
	_check(bool(result.get("ok", false)) and context.max_hp == 150 and context.hp == 70, "equipping_max_hp_does_not_heal")
	context.hp = 130
	result = handler.execute(context, &"unequip_item", {"instance_id": "health"})["action_result"]
	_check(bool(result.get("ok", false)) and context.max_hp == 100 and context.hp == 100, "unequipping_clamps_absolute_hp")
	handler.execute(context, &"equip_item", {"instance_id": "health"})
	_check(context.max_hp == 150 and context.hp == 100, "repeated_equip_does_not_refill")
	context.asset_ledger.create_item_instance(_loot("full", 100), RunAssetLedger.LOCATION_INVENTORY)
	var before := _snapshot(context.asset_ledger)
	result = handler.execute(context, &"unequip_item", {"instance_id": "health"})["action_result"]
	_check(not bool(result.get("ok", true)) and context.max_hp == 150 and context.hp == 100 and _snapshot(context.asset_ledger) == before, "blocked_unequip_preserves_hp_and_ledger")
	var swap_context := _context()
	swap_context.asset_ledger.create_item_instance(_gear("hp_old", 10, "armor", "max_hp", 50), RunAssetLedger.LOCATION_INVENTORY)
	swap_context.asset_ledger.create_item_instance(_gear("hp_new", 10, "armor", "max_hp", 80), RunAssetLedger.LOCATION_INVENTORY)
	handler.execute(swap_context, &"equip_item", {"instance_id": "hp_old"})
	swap_context.hp = 140
	handler.execute(swap_context, &"equip_item", {"instance_id": "hp_new"})
	_check(swap_context.max_hp == 180 and swap_context.hp == 140, "same_slot_hp_swap_clamps_only_final_maximum")
	var stat_context := _context({"mine_dmg_reduce": 6})
	stat_context.asset_ledger.create_item_instance(_gear("reducer", 10, "armor", "mine_damage_reduce", 5), RunAssetLedger.LOCATION_INVENTORY)
	handler.execute(stat_context, &"equip_item", {"instance_id": "reducer"})
	_check(stat_context.mine_dmg_reduce == 11, "equip_updates_existing_passive_stat")
	handler.execute(stat_context, &"unequip_item", {"instance_id": "reducer"})
	_check(stat_context.mine_dmg_reduce == 6, "unequip_preserves_other_stat_sources")
	# Bind the real runtime query without changing the overridable handler API.
	if handler.get_property_list().filter(func(property): return property["name"] == "combat_active_query").is_empty():
		_check(false, "combat_authority_input_available")
		return
	var combat := G41InRunRuntime.new()
	combat.simulation = G41CombatSimulation.new()
	combat.simulation.start()
	handler.set("combat_active_query", Callable(combat, "has_active_combat"))
	result = handler.execute(context, &"unequip_item", {"instance_id": "health"})["action_result"]
	_check(not bool(result.get("ok", true)) and str(result.get("reason", "")) == "equipment_locked_in_combat", "combat_locks_equipment")
	combat.simulation = null
	context.asset_ledger.drop_inventory_item("full", context.get_current_pos())
	result = handler.execute(context, &"unequip_item", {"instance_id": "health"})["action_result"]
	_check(bool(result.get("ok", false)), "equipment_unlocks_when_real_combat_ends")


func _test_departure_shield() -> void:
	var inventory = load("res://scripts/core/run/run_inventory.gd")
	if not inventory.has_method("claim_departure_shield"):
		_check(false, "departure_shield_claim_available")
		return
	var ledger := _ledger({"selected_equipment_items": [_gear("shield_a", 10, "armor", "departure_shield", 25), _gear("shield_b", 10, "head", "departure_shield", 30)]})
	_check(int(inventory.claim_departure_shield(ledger, "shield_run")) == 55, "departure_shield_has_no_40_cap")
	ledger.unequip_item("shield_a")
	ledger.equip_inventory_item("shield_a")
	_check(int(inventory.claim_departure_shield(ledger, "shield_run")) == 0, "reequip_never_reissues_departure_shield")
	ledger.create_item_instance(_gear("late_shield", 10, "armor", "departure_shield", 50), RunAssetLedger.LOCATION_INVENTORY)
	ledger.equip_inventory_item("late_shield")
	_check(int(inventory.claim_departure_shield(ledger, "shield_run")) == 0, "in_run_equipment_never_receives_departure_shield")
	_check(ledger.item_instances["shield_a"].get("counters", {}).get("departure_shield_run_id", "") == "shield_run", "shield_grant_bound_to_original_instance_and_run")


func _test_instance_identity() -> void:
	var ledger := _ledger()
	var definition := _gear("first", 10, "armor")
	definition.merge({"item_id": "same_name", "counters": {"charges": 1, "nested": {"used": 2}}, "origin_run_id": "prior_run", "origin_action_id": "prior_action", "acquired_sequence": 7, "custom_note": "retained"}, true)
	var first := ledger.create_item_instance(definition, RunAssetLedger.LOCATION_INVENTORY)
	definition["instance_id"] = "second"
	var second := ledger.create_item_instance(definition, RunAssetLedger.LOCATION_INVENTORY)
	_check(first.get("counters", {}) == {"charges": 1, "nested": {"used": 2}} and first.get("custom_note", "") == "retained", "instance_creation_preserves_counters_and_metadata")
	if ledger.item_instances["first"].has("counters"):
		ledger.item_instances["first"]["counters"]["charges"] = 0
		_check(ledger.item_instances["second"]["counters"]["charges"] == 1 and definition["counters"]["charges"] == 1, "same_name_instances_have_independent_counters")
	ledger.equip_inventory_item("first")
	ledger.unequip_item("first")
	ledger.drop_inventory_item("first", Vector2i.ZERO)
	ledger.pickup_ground_item("first", Vector2i.ZERO)
	var current: Dictionary = ledger.item_instances["first"]
	_check(current.get("origin_run_id", "") == "prior_run" and current.get("origin_action_id", "") == "prior_action" and current.get("acquired_sequence", -1) == 7, "equip_drop_repick_preserves_origin")
	_check(current.get("counters", {}).get("charges", -1) == 0, "equip_drop_repick_does_not_reset_charges")
	var before := _snapshot(ledger)
	var duplicate := ledger.create_item_instance(second, RunAssetLedger.LOCATION_ROOM_FLOOR, Vector2i.ONE)
	_check(duplicate.is_empty() and _snapshot(ledger) == before, "duplicate_explicit_id_cannot_overwrite_existing_instance")


	var acquired := _ledger()
	var fresh := _gear("fresh", 10, "head")
	fresh["registered_for_run"] = false
	fresh["equip_allowed_now"] = false
	acquired.add_reward_items([fresh], RunAssetLedger.LOCATION_INVENTORY, Vector2i.ZERO)
	before = _snapshot(acquired)
	_check(not bool(acquired.equip_inventory_item("fresh").get("ok", true)) and _snapshot(acquired) == before, "new_drop_requires_existing_registration_contract")


func _test_event_transfers() -> void:
	var ledger := _ledger()
	ledger.create_item_instance(_loot("ship", 30), RunAssetLedger.LOCATION_INVENTORY)
	ledger.create_item_instance(_loot("pledge", 40), RunAssetLedger.LOCATION_INVENTORY)
	var before := _snapshot(ledger)
	_check(not bool(ledger.transfer_event_items(["ship", "missing"], RunAssetLedger.LOCATION_CONSIGNED).get("ok", true)) and _snapshot(ledger) == before, "event_transfer_batch_rejects_without_partial_move")
	_check(bool(ledger.transfer_event_items(["ship"], RunAssetLedger.LOCATION_CONSIGNED).get("ok", false)), "consignment_moves_existing_instance")
	_check(bool(ledger.transfer_event_items(["pledge"], RunAssetLedger.LOCATION_PLEDGED).get("ok", false)), "pledge_moves_existing_instance")
	_check(ledger.get_backpack_used() == 0 and ledger.item_instances.size() == 2 and ledger.get_inventory_and_equipped_items().is_empty(), "event_held_items_occupy_one_location_only")
	before = _snapshot(ledger)
	_check(not bool(ledger.transfer_event_items(["ship"], RunAssetLedger.LOCATION_PLEDGED).get("ok", true)) and _snapshot(ledger) == before, "held_instance_cannot_be_transferred_twice")
	var settled := ledger.settle_abandon()
	_check((settled.get("event_delivered_items", []) as Array).size() == 1 or ledger.item_instances["ship"]["location_state"] == RunAssetLedger.LOCATION_WAREHOUSE, "existing_consignment_settlement_preserved")
	_check(ledger.item_instances["pledge"]["location_state"] == RunAssetLedger.LOCATION_LOST, "existing_pledge_failure_behavior_preserved")


func _test_reward_origin() -> void:
	var context := _context()
	context.active_command = {"command_id": "reward_action", "action_id": "reward_action"}
	var effect := {"type": AssetEffects.EFFECT_ADD_REWARD_ITEMS, "command_id": "reward_action", "source": "search", "payload": {"item_defs": [_loot("origin", 10)], "preferred_location": RunAssetLedger.LOCATION_INVENTORY}}
	var result := AssetEffects.apply_effect(context, effect)
	_check(bool(result.get("ok", false)), "reward_effect_created_item")
	var item: Dictionary = context.asset_ledger.item_instances.get("origin", {})
	_check(item.get("origin_run_id", "") == str(context.run_id) and item.get("origin_action_id", "") == "reward_action" and int(item.get("acquired_sequence", 0)) > 0, "reward_provenance_uses_current_run_and_action")
	var event_count := context.run_event_log.size()
	AssetEffects.apply_effect(context, {"type": AssetEffects.EFFECT_DROP_INVENTORY_ITEM, "payload": {"instance_id": "origin"}})
	AssetEffects.apply_effect(context, {"type": AssetEffects.EFFECT_PICKUP_GROUND_ITEM, "payload": {"instance_id": "origin"}})
	_check(context.asset_ledger.item_instances["origin"].get("origin_action_id", "") == "reward_action" and context.asset_ledger.next_instance_index == 2, "repick_never_generates_new_origin_or_instance")
	_check(context.run_event_log.size() == event_count + 2, "drop_and_repick_are_movement_events_only")
	var before := _snapshot(context.asset_ledger)
	result = AssetEffects.apply_effect(context, effect)
	_check(not bool(result.get("ok", true)) and _snapshot(context.asset_ledger) == before, "duplicate_reward_id_is_atomic_failure")


	before = _snapshot(context.asset_ledger)
	result = context.asset_ledger.add_reward_items([_loot("first_new", 10), _loot("origin", 10)], RunAssetLedger.LOCATION_INVENTORY, Vector2i.ZERO)
	_check(not bool(result.get("ok", true)) and _snapshot(context.asset_ledger) == before, "duplicate_in_reward_batch_does_not_commit_prior_items")
	context.asset_ledger.create_item_instance(_consumable("shared_full", 100), RunAssetLedger.LOCATION_INVENTORY)
	context.asset_ledger.create_item_instance(_consumable("blocked_ground", 1), RunAssetLedger.LOCATION_ROOM_FLOOR, context.get_current_pos())
	result = AssetEffects.apply_effect(context, {"type": AssetEffects.EFFECT_PICKUP_GROUND_ITEM, "payload": {"instance_id": "blocked_ground"}})
	_check(not bool(result.get("ok", true)) and (result.get("transaction", {}).get("item_moves", []) as Array).is_empty(), "blocked_pickup_never_records_successful_item_movement")


func _ledger(config: Dictionary = {}) -> RunAssetLedger:
	var ledger := RunAssetLedger.new()
	ledger.setup(config)
	return ledger


func _context(extra: Dictionary = {}) -> RunContext:
	var config := {"id": "z2_capacity", "seed": 1122, "width": 5, "height": 5, "max_hp": 100, "power": 20, "backpack_capacity": 100, "equipment_capacity": 100, "manual_map": {"spawn": Vector2i(2, 2), "mines": [], "exits": [{"pos": Vector2i(4, 4), "exit_id": "exit"}]}}
	config.merge(extra, true)
	var context := RunContext.new()
	context.start_run(config)
	return context


func _gear(id: String, weight: int, slot: String, effect: String = "", amount: int = 0) -> Dictionary:
	return {"instance_id": id, "item_id": "fixture_" + id, "item_type": &"equipment", "weight": weight, "can_equip": true, "registered_for_run": true, "equip_allowed_now": true, "equipment_slot": slot, "effect_kind": effect, "effect_amount": amount}


func _consumable(id: String, weight: int) -> Dictionary:
	return {"instance_id": id, "item_id": "fixture_" + id, "item_type": &"consumable", "weight": weight, "can_consume": true}


func _loot(id: String, weight: int) -> Dictionary:
	return {"instance_id": id, "item_id": "fixture_" + id, "item_type": &"collectible", "weight": weight, "base_value": 1}


func _snapshot(ledger: RunAssetLedger) -> Dictionary:
	return {"items": ledger.item_instances.duplicate(true), "floor": ledger.room_floor_items.duplicate(true), "currencies": ledger.currency_balances.duplicate(true), "status": ledger.status_effects.duplicate(true), "log": ledger.settlement_log.duplicate(true), "warehouse": ledger.warehouse_lite.duplicate(true), "backpack_capacity": ledger.backpack_capacity, "equipment_capacity": ledger.equipment_capacity, "salvage_capacity": ledger.failure_salvage_capacity, "next_index": ledger.next_instance_index}


func _check(condition: bool, name: String) -> void:
	checks += 1
	if not condition:
		failures.append(name)


func _test_distinct_action_provenance() -> void:
	var context := _context()
	context.active_command = {"action_id": "receipt_action", "command_id": "internal_command"}
	var result := AssetEffects.apply_effect(context, {"type": AssetEffects.EFFECT_ADD_REWARD_ITEMS, "command_id": "internal_command", "source": "search", "payload": {"item_defs": [_loot("action_origin", 10)]}})
	var item: Dictionary = context.asset_ledger.item_instances["action_origin"]
	print("REVIEW_PROVENANCE ok=%s active_action=receipt_action actual_origin=%s" % [result.get("ok"), item.get("origin_action_id")])
	_check(bool(result.get("ok", false)) and item.get("origin_action_id") == "receipt_action", "active_action_identity_precedes_legacy_command_fallback")
	for case in [
		{"effect_action": "effect_receipt", "active_action": "outer_receipt", "effect_command": "effect_command", "active_command": "active_command", "expected": "effect_receipt"},
		{"effect_action": "", "active_action": "outer_receipt", "effect_command": "effect_command", "active_command": "active_command", "expected": "outer_receipt"},
		{"effect_action": "", "active_action": "", "effect_command": "effect_command", "active_command": "active_command", "expected": "effect_command"},
		{"effect_action": "", "active_action": "", "effect_command": "", "active_command": "active_command", "expected": "active_command"},
	]:
		context = _context()
		context.active_command = {"action_id": case.active_action, "command_id": case.active_command}
		AssetEffects.apply_effect(context, {"type": AssetEffects.EFFECT_ADD_REWARD_ITEMS, "action_id": case.effect_action, "command_id": case.effect_command, "payload": {"item_defs": [_loot("precedence", 1)]}})
		_check(context.asset_ledger.item_instances["precedence"]["origin_action_id"] == case.expected, "origin_precedence_" + case.expected)


func _authorize_review_gear(equipment: Array, ids_only: bool = false) -> Dictionary:
	var config := Start.default_config()
	config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "selected_equipment_items": equipment}, true)
	config["selected_objective_id"] = Catalog.commission_offer_candidates("classic_7x7_simple", 0)[0]["id"]
	if ids_only:
		config["selected_equipment_items"] = []
		config["selected_equipment_ids"] = equipment.map(func(item: Dictionary) -> String: return str(item["instance_id"]))
	return Start.authorize_with_meta(config, {"warehouse_items": equipment, "unlocked_map_ids": ["classic_7x7_simple"], "run_count": 0})


func _test_blank_slot_guard() -> void:
	var items := [_gear("blank_a", 10, ""), _gear("blank_b", 10, ""), _gear("blank_c", 10, "")]
	var config := Start.default_config()
	config["selected_equipment_items"] = items
	_check(not bool(Start.validate(config).get("ok", true)), "empty_equipment_slot_cannot_validate")
	var admitted := _authorize_review_gear(items)
	print("REVIEW_EMPTY_SLOT admitted=%s issues=%s" % [admitted.get("ok"), admitted.get("issues")])
	_check(not bool(admitted.get("ok", true)), "empty_equipment_slot_cannot_authorize")
	_check(not bool(_authorize_review_gear(items, true).get("ok", true)), "owned_empty_slot_rejected_for_ids_only_selection")
	_check(not bool(_authorize_review_gear([_gear("space", 10, "  ")]).get("ok", true)), "whitespace_equipment_slot_rejected")
	var ledger := _ledger()
	for item in items:
		ledger.create_item_instance(item, RunAssetLedger.LOCATION_INVENTORY)
	var before := _snapshot(ledger)
	var equipped := ledger.equip_inventory_item("blank_a")
	print("REVIEW_EMPTY_SLOT ledger_equip_ok=%s" % equipped.get("ok"))
	_check(not bool(equipped.get("ok", true)) and _snapshot(ledger) == before, "empty_equipment_slot_cannot_equip")


func _test_authorized_start_hp() -> void:
	var admitted := _authorize_review_gear([_gear("start_hp", 10, "armor", "max_hp", 50)])
	_check(bool(admitted.get("ok", false)), "max_hp_fixture_is_authorized")
	var context := _context(Usability.runtime_config_patch(admitted.get("config", {})))
	print("REVIEW_START_HP max=%d hp=%d" % [context.max_hp, context.hp])
	_check(context.max_hp == 150 and context.hp == 150, "authorized_start_hp_includes_equipped_bonus")
	var normalized := Start.normalize({"run_start_config_preview": admitted.get("config", {})})
	_check(normalized.get("max_hp", -1) == 150, "authorized_max_hp_survives_route_normalization")
	var forged: Dictionary = admitted.get("config", {}).duplicate(true)
	forged["max_hp"] = 999
	var reauthorized := Start.authorize_with_meta(forged, {"warehouse_items": [_gear("start_hp", 10, "armor", "max_hp", 50)], "unlocked_map_ids": ["classic_7x7_simple"], "run_count": 0})
	_check(bool(reauthorized.get("ok", false)) and reauthorized.get("config", {}).get("max_hp", -1) == 150, "start_hp_recomputed_from_owned_gear_not_preview")
	var result: Dictionary = Handler.new().execute(context, &"unequip_item", {"instance_id": "start_hp"})["action_result"]
	print("REVIEW_START_HP removed_ok=%s max=%d hp=%d" % [result.get("ok"), context.max_hp, context.hp])
	_check(bool(result.get("ok", false)) and context.max_hp == 100 and context.hp == 100, "removing_start_hp_gear_restores_base_100")


func _test_max_hp_floor_roundtrip() -> void:
	var context := _context()
	var handler := Handler.new()
	context.asset_ledger.create_item_instance(_gear("floor_hp", 10, "armor", "max_hp", 50), RunAssetLedger.LOCATION_INVENTORY)
	handler.execute(context, &"equip_item", {"instance_id": "floor_hp"})
	# A fully payable permanent max-HP payment leaves 20 of the equipped 150.
	var vitals = load("res://scripts/core/run/run_vitals_resolver.gd")
	var payment: Dictionary = vitals.resolve_damage({"hp": context.hp, "max_hp": context.max_hp}, {"amount": 130, "damage_type": "max_hp_payment"})
	_check(bool(payment.get("ok", false)) and payment.get("state", {}).get("max_hp") == 20, "max_hp_payment_is_fully_payable_before_roundtrip")
	context.max_hp = int(payment["state"]["max_hp"])
	context.hp = int(payment["state"]["hp"])
	handler.execute(context, &"unequip_item", {"instance_id": "floor_hp"})
	_check(context.max_hp == 1 and context.max_hp_equipment_floor_debt == 31, "equipment_floor_records_unclamped_debt")
	var floor_snapshot := StateSnapshot.capture_context(context)
	var rejected := RunEffectApplier.apply_damage_packet(context, {"amount": 1, "damage_type": "max_hp_payment"})
	_check(not bool(rejected.get("ok", true)) and context.max_hp_equipment_floor_debt == 31 and context.max_hp == 1, "unpayable_max_hp_cost_does_not_clear_floor_debt")
	handler.execute(context, &"equip_item", {"instance_id": "floor_hp"})
	print("REVIEW_MAX_HP_FLOOR before=20 after=%d hp=%d" % [context.max_hp, context.hp])
	_check(context.max_hp == 20, "equipment_roundtrip_cannot_refund_permanent_max_hp_cost")
	_check(context.hp == 1 and context.max_hp_equipment_floor_debt == 0, "restored_max_hp_does_not_refill_current_hp")
	StateSnapshot.install_context(context, floor_snapshot)
	_check(context.max_hp == 1 and context.max_hp_equipment_floor_debt == 31, "snapshot_restore_preserves_floor_debt")
	for _index in range(3):
		handler.execute(context, &"equip_item", {"instance_id": "floor_hp"})
		_check(context.max_hp == 20 and context.hp == 1, "repeated_roundtrip_has_no_permanent_cost_refund")
		handler.execute(context, &"unequip_item", {"instance_id": "floor_hp"})
	context.reset()
	_check(context.max_hp == 100 and context.max_hp_equipment_floor_debt == 0, "context_reset_clears_previous_run_floor_debt")


func _test_additional_capacity_boundaries() -> void:
	var ledger := _ledger()
	ledger.create_item_instance(_loot("bagfull", 100), RunAssetLedger.LOCATION_INVENTORY)
	var result := ledger.add_reward_items([_loot("overflow_loot", 1), _consumable("shared_fit", 100), _consumable("shared_overflow", 1)], RunAssetLedger.LOCATION_INVENTORY, Vector2i.ZERO)
	_check(bool(result.get("ok", false)) and ledger.get_backpack_used() == 100 and ledger.get_equipment_used() == 100 and ledger.get_room_floor_items(Vector2i.ZERO).size() == 2, "mixed_rewards_overflow_into_correct_buckets")
	var before := _snapshot(ledger)
	result = ledger.add_reward_items([_loot("new_repeat", 1), _loot("new_repeat", 1)], RunAssetLedger.LOCATION_INVENTORY, Vector2i.ZERO)
	_check(not bool(result.get("ok", true)) and _snapshot(ledger) == before, "duplicate_new_ids_in_same_batch_atomic")
	result = ledger.add_reward_items([_loot("valid_first", 1), null], RunAssetLedger.LOCATION_INVENTORY, Vector2i.ZERO)
	_check(not bool(result.get("ok", true)) and _snapshot(ledger) == before, "malformed_reward_batch_atomic")
	ledger.consume_inventory_item("shared_fit")
	before = _snapshot(ledger)
	_check(not bool(ledger.consume_inventory_item("shared_fit").get("ok", true)) and _snapshot(ledger) == before, "repeat_consumption_atomic")
	var gear := _gear("counter_transfer", 10, "armor")
	gear["counters"] = {"nested": {"remaining": 2}}
	ledger = _ledger()
	ledger.create_item_instance(gear, RunAssetLedger.LOCATION_INVENTORY)
	ledger.create_item_instance(_loot("counter_ground", 10), RunAssetLedger.LOCATION_ROOM_FLOOR, Vector2i.ZERO)
	ledger.replace_ground_item_with_inventory_item("counter_ground", "counter_transfer", Vector2i.ZERO)
	ledger.pickup_ground_item("counter_transfer", Vector2i.ZERO)
	ledger.transfer_event_items(["counter_transfer"], RunAssetLedger.LOCATION_PLEDGED)
	_check(ledger.item_instances["counter_transfer"]["counters"] == {"nested": {"remaining": 2}}, "replacement_pickup_pledge_preserves_nested_counters")
