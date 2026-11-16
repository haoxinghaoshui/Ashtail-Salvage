extends SceneTree

const RuntimeController := preload("res://scripts/core/run/run_runtime_controller.gd")
const EventServiceScript := preload("res://scripts/core/run/event_service.gd")
const ItemModel := preload("res://scripts/core/content/m3r_item_usability_model.gd")
const MetaAdapter := preload("res://scripts/core/save/meta_progress_adapter.gd")
const ResultModel := preload("res://scripts/ui/result/result_presentation_model.gd")
const ResultPanelScene := preload("res://scenes/ui/result/result_panel.tscn")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_cage_victory_and_locks()
	_test_cage_defeat()
	_test_cage_navigation_locked()
	_test_damage_pressure_bridge()
	_test_lethal_pressure_snapshot()
	_test_abandon_consignment_persistence()
	_test_terminal_event_items_and_projection()
	if failures.is_empty():
		print("Z1_RUNTIME_BRIDGE=PASS cage=live,locked,unique_reward,defeat pressure=authoritative consignment=persistent,idempotent settlement=event_items_visible_once")
		quit(0)
	else:
		for failure in failures:
			print("Z1_RUNTIME_BRIDGE_CASE_FAIL " + failure)
		print("Z1_RUNTIME_BRIDGE=FAIL failures=%d" % failures.size())
		quit(1)


func _test_cage_victory_and_locks() -> void:
	var controller = _cage_controller()
	var context: RunContext = controller.context
	var runtime = controller.in_run_runtime
	var cage := EventServiceScript.cage_state(context, context.get_current_pos())
	runtime.sync_room(Vector2(0.5, 0.36))
	_check(runtime.has_active_combat(), "cage_creates_live_simulation")
	_check(runtime.simulation.arena_obstacles == G41WorldObjectProjection.room_solid_rects(&"Event", &"z1_event_e24"), "cage_uses_visible_event_obstacles")
	_check(runtime.get_player_local_position(Vector2.ZERO).distance_to(Vector2(0.5, 0.36)) < 0.001, "cage_preserves_valid_entry_position")
	_check(runtime.is_door_locked(), "cage_locks_door")
	if not runtime.has_active_combat():
		_release(controller)
		return
	var before_power: int = context.power
	var before_coin: int = context.asset_ledger.get_currency(&"black_coin")
	var snapshot: Dictionary = runtime.build_read_only_snapshot()
	var enemies: Array = snapshot.get("enemies", [])
	_check(not enemies.is_empty() and enemies[0].get("monster_type") == cage.get("monster_type"), "cage_saved_monster_type")
	_check(int(snapshot.get("encounter_profile", {}).get("enemy_power", -1)) == int(cage.get("base_power", -2)), "cage_saved_base_power")
	var flee: Dictionary = runtime.request_flee()
	_check(not bool(flee.get("ok", true)) and String(flee.get("reason", "")) == "cage_locked", "cage_refuses_flee")
	var direct_flee: Dictionary = controller.command_bus.dispatch(&"flee_runtime_combat", {"source": "g41_in_run_runtime"})
	_check(not bool(direct_flee.get("ok", true)) and context.asset_ledger.get_currency(&"black_coin") == before_coin, "cage_refuses_direct_flee_without_losses")
	var completed_simulation = runtime.simulation
	for step in range(3600):
		if not runtime.has_active_combat():
			break
		var combat: Dictionary = runtime.build_read_only_snapshot()
		var player: Dictionary = combat.get("player", {})
		var player_pos: Vector2 = player.get("pos", Vector2(0.5, 0.5))
		var target := _alive_enemy(combat)
		var move := Vector2.ZERO
		var aim := Vector2.RIGHT
		if not target.is_empty():
			var offset: Vector2 = Vector2(target.get("pos", player_pos)) - player_pos
			aim = offset.normalized() if offset.length_squared() > 0.000001 else Vector2.RIGHT
			move = aim if offset.length() > 0.16 else Vector2.ZERO
			if offset.length() <= 0.21:
				runtime.request_attack(aim)
		runtime.advance_frame(1.0 / 60.0, move, aim)
	_check(not runtime.has_active_combat() and context.run_active, "cage_real_combat_victory")
	_check(context.current_room_type == &"Event", "cage_retains_event_room")
	_check(context.truth_map.is_cleared(context.get_current_pos()), "cage_victory_clears_room")
	_check(context.power == before_power + int(cage.get("base_power", 0)) * 2, "cage_only_its_power_reward")
	_check(int(context.run_stats.get("events_completed", 0)) == 1 and int(context.run_stats.get("monsters_defeated", 0)) == 0, "cage_counts_one_event")
	_check(context.asset_ledger.get_currency(&"black_coin") == before_coin and context.asset_ledger.get_room_floor_items(context.get_current_pos()).is_empty(), "cage_does_not_grant_normal_combat_loot")
	_check(completed_simulation.reward_emitted, "cage_marks_emitting_simulation_committed")
	var repeat: Dictionary = controller.command_bus.dispatch(&"resolve_runtime_combat", {"source": "g41_combat_simulation", "combat_snapshot": completed_simulation.build_snapshot()})
	_check(bool(repeat.get("ok", false)) and context.power == before_power + int(cage.get("base_power", 0)) * 2, "cage_repeated_resolution_no_reward")
	runtime.sync_room(Vector2(0.5, 0.5))
	_check(not runtime.has_active_combat() and not runtime.is_door_locked(), "cage_remains_cleared_on_sync")
	_release(controller)


func _test_cage_defeat() -> void:
	var controller = _cage_controller()
	controller.in_run_runtime.sync_room(Vector2(0.5, 0.5))
	if not controller.in_run_runtime.has_active_combat():
		_check(false, "cage_defeat_has_simulation")
		_release(controller)
		return
	controller.in_run_runtime.simulation.call("_damage_player", 2000, "test_lethal", &"combat")
	controller.in_run_runtime.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(controller.context.failed and not controller.context.run_active, "cage_defeat_uses_normal_failure")
	_check(not controller.in_run_runtime.has_active_combat(), "cage_defeat_clears_runtime")
	_check(String(controller.context.result_snapshot.get("outcome", "")) == "Failed", "cage_defeat_has_result")
	_release(controller)


func _test_damage_pressure_bridge() -> void:
	var controller = _controller()
	var context: RunContext = controller.context
	context.player_pos = Vector2i(2, 2)
	context.current_pos = context.player_pos
	controller.command_bus.room_resolver.enter_room(context)
	controller.in_run_runtime.sync_room(Vector2(0.5, 0.5))
	if not controller.in_run_runtime.has_active_combat():
		_check(false, "pressure_test_has_simulation")
		_release(controller)
		return
	var before_pressure: int = context.pressure
	var before_hp: int = context.hp
	controller.in_run_runtime.simulation.call("_damage_player", 3, "m09_broadcast", &"m09_pulse", 4)
	controller.in_run_runtime.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(context.hp == before_hp - 3 and context.pressure == before_pressure + 4, "m09_pressure_reaches_authoritative_context")
	controller.in_run_runtime.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(context.pressure == before_pressure + 4, "drained_pressure_event_is_not_reapplied")
	context.protocol_pressure_reduce = 1
	controller.in_run_runtime.simulation.player["invulnerability"] = 0.0
	controller.in_run_runtime.simulation.call("_damage_player", 3, "m09_broadcast", &"m09_pulse", 4)
	controller.in_run_runtime.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(context.pressure == before_pressure + 7, "pressure_uses_existing_reduction_authority")
	_release(controller)


func _test_cage_navigation_locked() -> void:
	for command in [&"move_by", &"teleport_to_explored"]:
		var controller = _cage_controller()
		var original: Vector2i = controller.context.get_current_pos()
		var before_moves: int = controller.context.run_stats.get("moves", 0)
		var payload := {"source": "z1_bridge_test", "delta": Vector2i.RIGHT, "pos": Vector2i.ZERO}
		var result: Dictionary = controller.command_bus.dispatch(command, payload)
		_check(not bool(result.get("ok", true)) and controller.context.get_current_pos() == original, "cage_blocks_" + String(command))
		_check(int(controller.context.run_stats.get("moves", 0)) == before_moves, "cage_block_does_not_spend_move_" + String(command))
		_release(controller)


func _test_lethal_pressure_snapshot() -> void:
	var controller = _controller()
	var context: RunContext = controller.context
	context.player_pos = Vector2i(2, 2)
	context.current_pos = context.player_pos
	controller.command_bus.room_resolver.enter_room(context)
	context.hp = 1
	controller.in_run_runtime.sync_room(Vector2(0.5, 0.5))
	var before: int = context.pressure
	controller.in_run_runtime.simulation.call("_damage_player", 3, "m09_broadcast", &"m09_pulse", 4)
	controller.in_run_runtime.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(context.failed and int(context.result_snapshot.get("pressure", -1)) == before + 4, "lethal_hit_records_pressure_before_terminal_snapshot")
	_release(controller)


func _test_abandon_consignment_persistence() -> void:
	var controller = _controller()
	var context: RunContext = controller.context
	context.player_pos = Vector2i(1, 1)
	context.current_pos = context.player_pos
	context.z1_event_rooms[context.cell_key(context.player_pos)] = {"event_type": &"z1_event_e11"}
	controller.command_bus.room_resolver.enter_room(context)
	var item := context.asset_ledger.create_item_instance(ItemModel.item_definition("col_01"), &"inventory")
	context.asset_ledger.create_item_instance(ItemModel.item_definition("col_02"), &"inventory")
	controller.command_bus.room_resolver.select_event_option(context, &"consign", {"instance_id": item.get("instance_id", "")})
	context.abandon_run()
	var adapter := MetaAdapter.new()
	var path := "user://z2_validation/bridge-meta-%d.json" % Time.get_ticks_usec()
	adapter.set_active_profile_path(path, "z1_bridge_consignment")
	var initial_count: int = adapter.get_summary().get("warehouse_items", []).size()
	var result := adapter.apply_settlement(context.result_snapshot)
	_check(bool(result.get("ok", false)), "consignment_abandon_commits")
	var items: Array = adapter.get_summary().get("warehouse_items", [])
	_check(items.size() == initial_count + 1 and _count_instance(items, String(item.get("instance_id", ""))) == 1, "consignment_only_safe_item_persisted")
	adapter.apply_settlement(context.result_snapshot)
	adapter.load_or_create_default()
	items = adapter.get_summary().get("warehouse_items", [])
	_check(items.size() == initial_count + 1 and _count_instance(items, String(item.get("instance_id", ""))) == 1, "consignment_retry_reload_preserves_one_instance")
	_release(controller)


func _test_terminal_event_items_and_projection() -> void:
	for outcome in [&"success", &"failure", &"abandon"]:
		var ledger := RunAssetLedger.new()
		ledger.setup({"failure_salvage_capacity": 100})
		var consigned_id := _settlement_item(ledger, "col_01", &"inventory", 3)
		var pledged_id := _settlement_item(ledger, "col_13", &"inventory", 21)
		var ordinary_id := _settlement_item(ledger, "col_02", &"inventory", 4)
		var floor_id := _settlement_item(ledger, "col_03", &"room_floor", 5)
		var consumable_id := _settlement_item(ledger, "con_ration", &"inventory", 6)
		ledger.transfer_event_items([consigned_id], &"consigned")
		ledger.transfer_event_items([pledged_id], &"pledged")
		var settlement: Dictionary
		match outcome:
			&"success":
				settlement = ledger.settle_success()
			&"failure":
				var preview := ledger.build_failure_preview()
				_check(int(preview.get("lost_item_count", 0)) == 2 and int(preview.get("lost_item_value", 0)) == 25, "failure_preview_includes_pledge")
				_check(ledger.get_items_by_location(&"pledged").size() == 1 and ledger.get_items_by_location(&"consigned").size() == 1, "failure_preview_does_not_settle_event_items")
				settlement = ledger.settle_failure([ordinary_id])
			_:
				settlement = ledger.settle_abandon()
		var label := String(outcome)
		_check(bool(settlement.get("ok", false)), label + "_settles")
		var event_delivery: Dictionary = settlement.get("event_item_delivery", {})
		var delivered: Array = event_delivery.get("delivered", [])
		var forfeited: Array = event_delivery.get("forfeited", [])
		_check(delivered.size() == 1 and _count_instance(delivered, consigned_id) == 1, label + "_event_delivery_contains_only_event_item")
		_check(forfeited.size() == 1 and _count_instance(forfeited, pledged_id) == 1, label + "_forfeiture_identity")
		_check(_count_instance(settlement.get("lost_items", []), pledged_id) == 1, label + "_lost_items_include_pledge")
		var extra_lost := int(outcome == &"abandon")
		_check(int(settlement.get("lost_item_count", -1)) == 3 + extra_lost, label + "_loss_count_includes_pledge_once")
		_check(int(settlement.get("lost_item_value", -1)) == 32 + extra_lost * 4, label + "_loss_value_includes_pledge_once")
		var model := ResultModel.build({"settlement": settlement})
		var sections: Array = model.get("item_sections", [])
		_check(_count_result_rows(sections, pledged_id) == 1 and _count_result_rows(sections, pledged_id, &"event_forfeited_items") == 1, label + "_forfeiture_visible_once")
		_check(_count_result_rows(sections, consigned_id) == 1, label + "_consignment_visible_once")
		_check(_count_result_rows(sections, ordinary_id) == 1 and _count_result_rows(sections, floor_id) == 1 and _count_result_rows(sections, consumable_id) == 1, label + "_ordinary_items_still_visible")
		var consequence := String(model.get("consequence_text", ""))
		if outcome == &"success":
			_check(consequence.contains("抵押抵账 1 件"), "success_mentions_forfeiture")
		else:
			_check(_count_result_rows(sections, consigned_id, &"event_consigned_items") == 1, label + "_consignment_has_own_section")
			var retained := 1 if outcome == &"abandon" else 2
			_check(consequence.contains("保全 %d 件" % retained), label + "_retained_summary_counts_consignment")
			_check(consequence.contains("未能带回 %d 件" % (1 + extra_lost)), label + "_lost_summary_counts_forfeiture_once")
		_check_result_panel_event_rows(settlement, outcome)


func _check_result_panel_event_rows(settlement: Dictionary, outcome: StringName) -> void:
	var panel := ResultPanelScene.instantiate() as ResultPanel
	root.add_child(panel)
	panel.show_summary({"settlement": settlement})
	var sections := panel.find_child("ResultItemSections", true, false)
	var labels: Array[String] = []
	if sections != null:
		for child in sections.find_children("*", "Label", true, false):
			labels.append((child as Label).text)
	var label := String(outcome)
	var consigned_name := String(ItemModel.item_definition("col_01").get("display_name", ""))
	var pledged_name := String(ItemModel.item_definition("col_13").get("display_name", ""))
	_check(labels.count(consigned_name) == 1 and labels.count(pledged_name) == 1, label + "_result_panel_shows_each_event_item_once")
	_check(labels.has("抵押抵账 · 1"), label + "_result_panel_has_forfeiture_heading")
	if outcome != &"success":
		_check(labels.has("已托运 · 1"), label + "_result_panel_has_consignment_heading")
	panel.free()


func _settlement_item(ledger: RunAssetLedger, item_id: String, location: StringName, value: int) -> String:
	var definition := ItemModel.item_definition(item_id)
	definition["base_value"] = value
	var item := ledger.create_item_instance(definition, location, Vector2i(1, 1))
	return String(item.get("instance_id", ""))


func _count_result_rows(sections: Array, instance_id: String, section_id: StringName = &"") -> int:
	var count := 0
	for section in sections:
		if section_id == &"" or section.get("section_id", &"") == section_id:
			count += _count_instance(section.get("items", []), instance_id)
	return count


func _cage_controller():
	var controller = _controller()
	var context: RunContext = controller.context
	context.player_pos = Vector2i(1, 1)
	context.current_pos = context.player_pos
	context.z1_event_rooms[context.cell_key(context.player_pos)] = {"event_type": &"z1_event_e24"}
	controller.command_bus.room_resolver.enter_room(context)
	controller.command_bus.room_resolver.select_event_option(context, &"enter_cage")
	return controller


func _controller():
	var controller = RuntimeController.new()
	controller.context.start_run({"id": "z1_bridge", "seed": 348, "width": 5, "height": 5, "max_hp": 1000, "power": 200,
		"manual_map": {"spawn": Vector2i.ZERO, "events": [Vector2i(1, 1)], "monsters": [Vector2i(2, 2)], "exits": [{"pos": Vector2i(4, 4), "exit_id": "test_exit"}]}})
	controller.context.asset_ledger.add_currency(&"black_coin", 100, "test")
	controller.context.asset_ledger.sync_compat_fields(controller.context)
	return controller


func _alive_enemy(snapshot: Dictionary) -> Dictionary:
	for enemy in snapshot.get("enemies", []):
		if int(enemy.get("hp", 0)) > 0:
			return enemy
	return {}


func _release(controller) -> void:
	controller.in_run_runtime.reset()
	controller.in_run_runtime.bind(null)
	controller.command_bus.bind_runtime_controller(null)


func _count_instance(items: Array, instance_id: String) -> int:
	var count := 0
	for item in items:
		count += int(String(item.get("instance_id", "")) == instance_id)
	return count


func _check(condition: bool, key: String) -> void:
	if not condition:
		failures.append(key)
