extends SceneTree

const Config = preload("res://scripts/ui/deploy_prep/deploy_config.gd")
const Model = preload("res://scripts/ui/deploy_prep/deploy_prep_model.gd")
const Shell = preload("res://scripts/ui/deploy_prep/deploy_prep_shell.gd")
const Start = preload("res://scripts/core/run/run_start_config.gd")
const Inventory = preload("res://scripts/ui/inventory/inventory_panel.gd")
const GroundLoot = preload("res://scripts/ui/ground_loot/ground_loot_panel.gd")
const HUDModel = preload("res://scripts/ui/hud/hud_view_model.gd")
const SurfaceModel = preload("res://scripts/ui/run_surface/run_surface_model.gd")
const Surface = preload("res://scripts/ui/run_surface/run_surface.gd")
const Layout = preload("res://scripts/ui/shell/ui_layout_profile.gd")

var failures: Array[String] = []
var checks := 0
var start_intents: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_selection_and_capacity()
	_test_capacity_effects_and_claim()
	_test_readonly_stack_identity()
	await _test_player_controls()
	await _test_in_run_displays()
	await _test_passive_feedback()
	for failure in failures:
		print("Z2_CAPACITY_UI_CASE_FAIL " + failure)
	print("Z2_CAPACITY_UI=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_selection_and_capacity() -> void:
	var meta := _meta()
	var config := Config.default_config(1, meta)
	for id in ["gear_a", "gear_b", "gear_c", "supply_a", "supply_b", "supply_c", "supply_d"]:
		var result := _toggle(config, id)
		_check(bool(result.get("changed", false)), "select_exact_" + id)
		config = result.get("config", config)
	_check(config.get("selected_equipment_ids", []) == ["gear_a", "gear_b", "gear_c"], "all_three_gear_retained")
	_check(config.get("selected_consumable_ids", []) == ["supply_a", "supply_b", "supply_c", "supply_d"], "all_four_supplies_retained")
	_check(config.get("equipment_used", -1) == 100 and config.get("equipment_capacity", -1) == 100, "shared_weight_at_100")
	_check(config.get("bag_used", -1) == 0 and config.get("bag_limit", -1) == 100, "departure_loot_bucket_empty")
	_check(bool(Config.config_validity(config).get("can_start", false)), "at_100_can_start")
	var over := _toggle(config, "over")
	_check(not bool(over.get("changed", true)) and over.get("config", {}) == config, "shared_101_rejects_without_mutation")
	_check(str(over.get("message", "")).contains("共享负重"), "overweight_explains_shared_bucket")
	var conflict := _toggle(config, "replacement")
	_check(not bool(conflict.get("changed", true)) and conflict.get("config", {}) == config, "occupied_slot_still_rejected")
	var unknown := _toggle(config, "missing")
	_check(not bool(unknown.get("changed", true)) and unknown.get("config", {}) == config, "unknown_identity_rejected")
	var start := Config.build_run_start_config(config)
	_check(start.get("equipment_used", -1) == 100 and start.get("equipment_capacity", -1) == 100, "handoff_preserves_shared_fields")
	var authorized := Start.authorize_with_meta(start, meta)
	_check(bool(authorized.get("ok", false)), "ui_selection_authorizes_with_real_warehouse")
	_check((authorized.get("config", {}) as Dictionary).get("selected_consumable_ids", []) == config.get("selected_consumable_ids", []), "authority_preserves_all_selected_identities")
	var refreshed := Config.refresh_from_meta(config, meta)
	_check(refreshed.get("selected_equipment_ids", []) == config.get("selected_equipment_ids", []) and refreshed.get("selected_consumable_ids", []) == config.get("selected_consumable_ids", []), "meta_refresh_does_not_truncate_selection")
	var model := Model.model_with_config(Model.build({"meta_progress_summary": meta}), config, &"")
	model = Model.model_with_tab(model, &"loadout")
	var rows: Array = model.get("selection_rows", [])
	var item_count := 0
	for row in rows:
		if str(row.get("detail_kind", "")) == "loadout_item":
			item_count += 1
	_check(item_count == 7, "loadout_lists_every_selected_instance")
	var capacity := _row(model, "loadout_capacity")
	_check(str(capacity.get("summary", "")).contains("100 / 100"), "capacity_card_shows_shared_weight")
	_check(str(capacity.get("facts", [])).contains("战利品") and str(capacity.get("facts", [])).contains("0 / 100"), "capacity_detail_shows_independent_loot")
	var invalid := config.duplicate(true)
	invalid["equipment_used"] = 101
	_check(not bool(Config.config_validity(invalid).get("can_start", true)), "primary_validity_blocks_shared_overweight")
	var canonical := start.duplicate(true)
	canonical["equipment_capacity"] = 140
	canonical["equipment_used"] = 110
	var resumed := Config.with_active_run_config(Config.default_config(), canonical)
	_check(resumed.get("equipment_capacity", -1) == 140 and resumed.get("equipment_used", -1) == 110, "continue_projection_uses_canonical_shared_fields")
	var tutorial := config.duplicate(true)
	tutorial["map_config_id"] = "tutorial_5x5"
	_check(Config.build_run_start_config(tutorial).get("equipment_used", -1) == 0, "tutorial_clears_formal_loadout_weight")
	var removed := _toggle(config, "gear_c")
	var replaced := _toggle(removed.get("config", {}), "replacement")
	_check(bool(replaced.get("changed", false)) and (replaced.get("config", {}) as Dictionary).get("equipment_used", -1) == 90, "explicit_remove_then_replace_keeps_slot_and_weight_rules")
	var minus := Config.adjust_warehouse_stack_quantity(config, ["supply_d", "supply_b", "supply_a", "supply_c"], -1)
	_check((minus.get("config", {}) as Dictionary).get("selected_consumable_ids", []) == ["supply_a", "supply_b", "supply_c"], "minus_removes_one_exact_instance")
	var plus := Config.adjust_warehouse_stack_quantity(minus.get("config", {}), ["supply_d", "supply_b", "supply_a", "supply_c"], 1)
	_check((plus.get("config", {}) as Dictionary).get("selected_consumable_ids", []) == config.get("selected_consumable_ids", []), "plus_restores_fourth_instance")
	_check((plus.get("config", {}) as Dictionary).get("selected_consumable_items", []) == config.get("selected_consumable_items", []), "quantity_round_trip_preserves_instance_counters")


func _test_capacity_effects_and_claim() -> void:
	var meta := _meta()
	meta["warehouse_items"] = [_gear("slotless", 10, "")]
	var config := Config.default_config(2, meta)
	var slotless := _toggle(config, "slotless")
	_check(not bool(slotless.get("changed", true)) and slotless.get("config", {}) == config, "ui_rejects_missing_equipment_slot")
	meta["warehouse_items"] = [_gear("bag", 20, "rig", "backpack_capacity", 40), _supply("heavy", 81)]
	config = Config.default_config(2, meta)
	config = _toggle(config, "bag").get("config", {})
	_check(config.get("bag_limit", -1) == 140 and config.get("equipment_capacity", -1) == 100, "loot_bonus_does_not_expand_shared_capacity")
	var over := _toggle(config, "heavy")
	_check(not bool(over.get("changed", true)) and over.get("config", {}) == config, "loot_bonus_cannot_admit_shared_101")
	meta["warehouse_items"] = [_gear("rig", 10, "rig", "equipment_capacity", 20), _supply("heavy", 110)]
	config = Config.default_config(3, meta)
	config = _toggle(config, "rig").get("config", {})
	var added := _toggle(config, "heavy")
	config = added.get("config", {})
	_check(bool(added.get("changed", false)) and config.get("equipment_used", -1) == 120 and config.get("equipment_capacity", -1) == 120, "shared_bonus_admits_exact_final_weight")
	var removed := _toggle(config, "rig")
	_check(not bool(removed.get("changed", true)) and removed.get("config", {}) == config, "capacity_source_removal_is_atomic")
	config = Config.default_config(4, _meta())
	for id in ["supply_a", "supply_b", "supply_c", "supply_d"]:
		config = _toggle(config, id).get("config", {})
	var model := Model.model_with_config(Model.build({"meta_progress_summary": _meta()}), config, &"")
	model = Model.model_with_tab(model, &"claim")
	var claim := _row(model, "claim_emergency_ration")
	var actions: Array = claim.get("actions", [])
	_check(not actions.is_empty() and bool(actions[0].get("enabled", false)), "claim_button_not_blocked_by_four_supplies")
	var claimed := Config.apply_card_action(config, &"claim", &"claim_emergency_ration")
	_check(bool(claimed.get("changed", false)) and (claimed.get("config", {}) as Dictionary).get("selected_consumable_items", []).size() == 5, "fifth_emergency_supply_is_selectable")
	var unclaimed := Config.apply_card_action(claimed.get("config", {}), &"claim", &"claim_emergency_ration")
	_check((unclaimed.get("config", {}) as Dictionary).get("selected_consumable_ids", []) == config.get("selected_consumable_ids", []), "claim_removal_preserves_owned_instances")
	var full := config.duplicate(true)
	full["equipment_used"] = 100
	model = Model.model_with_config(model, full, &"")
	claim = _row(model, "claim_emergency_ration")
	actions = claim.get("actions", [])
	_check(not actions.is_empty() and not bool(actions[0].get("enabled", true)) and str(actions[0].get("reason_code", "")) == "equipment_overweight", "claim_projection_uses_remaining_shared_weight")


func _test_player_controls() -> void:
	root.size = Vector2i(1280, 720)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var shell := Shell.new()
	root.add_child(shell)
	shell.size = Vector2(1280, 720)
	var snapshot := {"run_active": false, "meta_progress_summary": _meta()}
	shell.build({}, snapshot)
	shell.set_reduced_motion_enabled(true)
	shell.deploy_start_intent_requested.connect(func(intent: Dictionary) -> void: start_intents.append(intent))
	shell.apply_snapshot(snapshot)
	shell.show_tab(&"warehouse")
	await _frames()
	for id in ["gear_a", "gear_b", "gear_c", "supply_a", "supply_a", "supply_a", "supply_a"]:
		var card := _card(shell, id)
		var plus := card.get("quantity_plus_button") as Button if card != null else null
		_check(plus != null and plus.visible and not plus.disabled, "player_plus_available_" + id)
		if plus != null and not plus.disabled:
			plus.pressed.emit()
		await _frames()
	var selected := shell.get_selected_instance_ids()
	_check(selected.get("selected_equipment_ids", []) == ["gear_a", "gear_b", "gear_c"], "player_selected_third_gear")
	_check(selected.get("selected_consumable_ids", []) == ["supply_a", "supply_b", "supply_c", "supply_d"], "player_selected_fourth_supply")
	var supply_card := _card(shell, "supply_a")
	var quantity := supply_card.get("quantity_value_label") as Label if supply_card != null else null
	_check(quantity != null and quantity.text == "4/4", "player_card_shows_four_of_four")
	var visible_summary := ""
	for label in shell.summary_row_labels:
		if label.visible:
			visible_summary += label.text + "\n"
	_check(visible_summary.contains("共享负重 100 / 100") and visible_summary.contains("战利品：0 / 100"), "player_summary_distinguishes_both_buckets")
	var over_card := _card(shell, "over")
	if over_card != null:
		(over_card.get("quantity_plus_button") as Button).pressed.emit()
	await _frames()
	_check(shell.get_selected_instance_ids() == selected, "player_overweight_plus_keeps_exact_selection")
	_check(str(shell.current_model.get("action_message", "")).contains("共享负重"), "player_overweight_feedback_names_shared_bucket")
	await _capture("deploy-capacity-100", shell)
	shell.primary_action_button.pressed.emit()
	_check(start_intents.size() == 1, "player_can_submit_full_loadout")
	var start: Dictionary = shell.current_model.get("run_start_config", {})
	_check(start.get("selected_equipment_ids", []).size() == 3 and start.get("selected_consumable_ids", []).size() == 4, "player_handoff_not_truncated")
	_check(bool(Start.authorize_with_meta(start, _meta()).get("ok", false)), "player_handoff_authorizes")
	shell.queue_free()
	await _frames()


func _test_readonly_stack_identity() -> void:
	var ledger := RunAssetLedger.new()
	ledger.setup({})
	for id in ["first", "second"]:
		ledger.create_item_instance({"instance_id": id, "item_id": "ui_loot", "item_type": &"collectible", "weight": 15, "origin_run_id": "run_" + id, "origin_action_id": "action_" + id, "counters": {"remaining": 2}}, RunAssetLedger.LOCATION_INVENTORY)
	var before := ledger.item_instances.duplicate(true)
	var items := ledger.get_items_by_location(RunAssetLedger.LOCATION_INVENTORY)
	var model := SurfaceModel.build({"inventory_items": items}, null, {}, {})
	var stacks: Array = model.get("backpack_items", [])
	_check(stacks.size() == 1 and stacks[0].get("instance_ids", []) == ["first", "second"], "provenance_does_not_split_compatible_display_stack")
	_check(ledger.item_instances == before and before["first"]["acquired_sequence"] != before["second"]["acquired_sequence"], "display_aggregation_preserves_exact_ledger_provenance")
	items[1]["counters"]["remaining"] = 1
	model = SurfaceModel.build({"inventory_items": items}, null, {}, {})
	_check((model.get("backpack_items", []) as Array).size() == 2, "different_instance_counters_stay_visibly_distinct")


func _test_in_run_displays() -> void:
	var snapshot := {"equipment_used": 80, "equipment_capacity": 100, "backpack_used": 30, "backpack_capacity": 120, "backpack_remaining": 90, "inventory_items": [], "equipped_items": [], "room_floor_items": []}
	var profile := Layout.profile_for_size(Vector2(1280, 720))
	var inventory := Inventory.new()
	root.add_child(inventory)
	inventory.apply_layout_profile(profile)
	inventory.apply_snapshot(snapshot)
	_check(_has_both_capacities(inventory.summary_label.text), "inventory_displays_both_snapshot_buckets")
	inventory.show_panel()
	await _frames()
	await _capture("inventory-capacity", inventory)
	inventory.hide_panel()
	var loot := GroundLoot.new()
	root.add_child(loot)
	loot.apply_layout_profile(profile)
	loot.apply_snapshot(snapshot)
	_check(_has_both_capacities(loot.summary_label.text), "ground_loot_displays_both_snapshot_buckets")
	loot.show_panel()
	await _frames()
	await _capture("ground-loot-capacity", loot)
	loot.hide_panel()
	_check(_has_both_capacities(HUDModel.build_from_snapshot(snapshot).status_text), "hud_displays_both_snapshot_buckets")
	var model := SurfaceModel.build(snapshot, null, profile, {})
	_check(model.get("equipment_used", -1) == 80 and model.get("equipment_capacity", -1) == 100, "surface_projects_shared_fields")
	var surface := Surface.new()
	root.add_child(surface)
	surface.apply_layout_profile(profile)
	surface.apply_surface_model(model)
	_check(_has_both_capacities(surface.backpack_capacity_label.text), "surface_displays_both_snapshot_buckets")
	await _frames()
	await _capture("run-surface-capacity", surface)
	inventory.queue_free()
	loot.queue_free()
	surface.queue_free()
	await _frames()


func _has_both_capacities(value: String) -> bool:
	var compact := value.replace(" ", "")
	return compact.contains("80/100") and compact.contains("30/120") and compact.contains("共享") and compact.contains("战利品")


func _meta() -> Dictionary:
	return {"gold": 100, "profile_level": 9, "permit_level": 9, "protocol_difficulty": 5, "unlocked_map_ids": ["classic_7x7_simple"], "warehouse_items": [
		_gear("gear_a", 20, "armor"), _gear("gear_b", 20, "rig"), _gear("gear_c", 20, "head"),
		_supply("supply_d", 10), _supply("supply_b", 10), _supply("supply_a", 10), _supply("supply_c", 10),
		_supply("over", 1), _gear("replacement", 10, "head"),
	]}


func _gear(id: String, weight: int, slot: String, effect: String = "", amount: int = 0) -> Dictionary:
	return {"instance_id": id, "item_id": "ui_" + id, "display_name": "装备 " + id, "item_type": &"equipment", "weight": weight, "can_equip": true, "equipment_slot": slot, "effect_kind": effect, "effect_amount": amount}


func _supply(id: String, weight: int) -> Dictionary:
	return {"instance_id": id, "item_id": "ui_supply", "display_name": "共享补给", "item_type": &"consumable", "weight": weight, "can_consume": true, "effect_kind": "heal", "effect_amount": 10, "counters": {"uses": 1}, "origin_run_id": "warehouse_source"}


func _toggle(config: Dictionary, id: String) -> Dictionary:
	return Config.apply_card_action(config, &"warehouse", StringName("m3r_" + id))


func _row(model: Dictionary, id: String) -> Dictionary:
	for row in model.get("selection_rows", []):
		if str(row.get("id", "")) == id:
			return row
	return {}


func _card(shell: Control, id: String) -> Control:
	for view in shell.get("card_views"):
		if (view.get("card_data") as Dictionary).get("instance_ids", []).has(id):
			return view
	return null


func _frames() -> void:
	for _index in range(8):
		await process_frame


func _capture(name: String, control: Control) -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir=") and DisplayServer.get_name() != "headless":
			var directory := arg.trim_prefix("--capture-dir=")
			DirAccess.make_dir_recursive_absolute(directory)
			var deadline := Time.get_ticks_msec() + 3000
			while control.modulate.a < 0.999 and Time.get_ticks_msec() < deadline:
				await process_frame
			_check(control.modulate.a >= 0.999, "capture_open_animation_finished_" + name)
			await RenderingServer.frame_post_draw
			_check(root.get_texture().get_image().save_png(directory.path_join(name + ".png")) == OK, "capture_" + name)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func _test_passive_feedback() -> void:
	root.size = Vector2i(1280, 720)
	var shell := Shell.new()
	root.add_child(shell)
	shell.size = Vector2(1280, 720)
	var snapshot := {"run_active": true, "meta_progress_summary": _meta()}
	shell.build({}, snapshot)
	shell.set_reduced_motion_enabled(true)
	shell.show_action_message("请在放弃确认窗口中再次确认")
	await _frames()
	shell.apply_snapshot(snapshot)
	await _frames()
	_check(shell.current_model.action_message == "请在放弃确认窗口中再次确认", "periodic_refresh_retains_rejection_message")
	shell.show_tab(&"warehouse")
	_check(shell.current_model.action_message == "", "new_user_navigation_clears_old_feedback")
	shell.queue_free()
	await _frames()
