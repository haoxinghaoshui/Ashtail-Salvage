extends SceneTree

const Player := preload("res://scripts/gameplay/player/player_controller.gd")
const Talents := preload("res://scripts/core/progression/z2_talent_runtime.gd")
const Catalog := preload("res://scripts/core/progression/z2_talent_catalog.gd")
const Runtime := preload("res://scripts/core/run/run_runtime_controller.gd")
const Combat := preload("res://scripts/core/run/combat_state.gd")
const Items := preload("res://scripts/core/content/m3_item_catalog.gd")

const ROOM := Vector2i(2, 2)
const TRANSIT := Vector2i(1, 2)
const Z2_PROFILE := {"ruleset_id": "z2", "z2_progression_version": 1}

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_room_movement()
	print("Z2_ORDINARY_MOVEMENT=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	_test_flee_and_reentry(true)
	_test_flee_and_reentry(false)
	for failure in failures:
		print("ASSERT_FAIL: " + failure)
	print("Z2_MOVEMENT_RETREAT=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _profile(numbers: Array, fields: Dictionary = Z2_PROFILE, tutorial: bool = false) -> Dictionary:
	var effects: Array = []
	for number in numbers:
		effects.append(Catalog.definition("z2_talent_%02d" % int(number)))
	return Talents.run_profile(fields, effects, tutorial)


func _move(player, profile: Dictionary, frames: int = 30) -> Dictionary:
	if player.has_method("set_talent_runtime_profile"):
		player.call("set_talent_runtime_profile", profile)
	player.place_on_clear_floor(Vector2(0.2, 0.5))
	for frame in range(frames):
		player.move_local(Vector2.RIGHT, 0.5 / float(frames))
	return {"distance": player.get_local_position().x - 0.2, "speed": player.local_velocity.length()}


func _test_room_movement() -> void:
	var player := Player.new()
	_check(player.has_method("set_talent_runtime_profile"), "movement exposes the scene's talent profile setter")
	var baseline := _move(player, {})
	_check(is_equal_approx(baseline.speed, 0.74), "unconfigured ordinary room retains baseline speed")
	for fixture in [[[11], 1.02], [[21], 1.03], [[11, 21], 1.05]]:
		var profile := _profile(fixture[0])
		var before := profile.duplicate(true)
		var moved := _move(player, profile)
		var speed := 0.74 * float(fixture[1])
		var distance := speed * 0.5 - speed * speed / (2.0 * 8.0)
		_check(is_equal_approx(moved.speed, speed), "ordinary room consumes movement multiplier " + str(fixture[1]))
		_check(absf(moved.distance - distance) < 0.00001 and moved.distance > baseline.distance, "talent changes actual ordinary-room displacement " + str(fixture[1]))
		_check(profile == before, "movement does not mutate frozen effects")
	var both := _profile([11, 21])
	var at_30 := _move(player, both, 15)
	var at_144 := _move(player, both, 72)
	_check(absf(at_30.distance - at_144.distance) < 0.00001, "talented movement retains frame-rate-independent integration")
	for profile in [{}, _profile([]), _profile([11, 21], {}), _profile([11, 21], {"ruleset_id": "z2", "z2_progression_version": 2}), _profile([11, 21], Z2_PROFILE, true)]:
		_move(player, both)
		var reset := _move(player, profile)
		_check(is_equal_approx(reset.speed, baseline.speed) and absf(reset.distance - baseline.distance) < 0.00001, "empty/old/unsupported/tutorial profile resets previous run's multiplier")
	_move(player, both)
	player.set_input_enabled(false)
	var stopped: Vector2 = player.get_local_position()
	player.move_local(Vector2.RIGHT, 0.5)
	_check(player.get_local_position() == stopped, "talented movement still respects disabled input")
	player.free()


func _controller(z2: bool):
	var runtime = Runtime.new()
	if z2:
		var manager := SaveManager.new()
		_check(manager.switch_profile("movement_retreat_%d" % Time.get_ticks_usec()).get("ok", false), "Z2: fresh retreat profile selected")
		runtime.bind_meta_progress_adapter(MetaProgressAdapter.new())
		_check(runtime.initialize_z2_session(manager).get("ok", false), "Z2: real Meta and checkpoint session initialized")
		_check(preload("res://tests/z2_legacy_main_fixture.gd").start(runtime, 348).get("ok", false), "Z2: qualified standard run admitted")
		# Retain the original deterministic combat fixture after lawful admission.
		runtime.context.max_hp = 100
		runtime.context.hp = 100
		runtime.context.power = 1
		runtime.context.truth_map.set_room_type(ROOM, &"Monster")
		runtime.context.truth_map.set_room_type(TRANSIT, &"Normal")
	else:
		runtime.context.start_run({
			"id": "z2_movement_retreat", "seed": 348, "width": 5, "height": 5,
			"max_hp": 100, "power": 1,
			"manual_map": {"spawn": Vector2i.ZERO, "monsters": [ROOM], "exits": [{"pos": Vector2i(4, 4), "exit_id": "test_exit"}]},
		})
		runtime.context.run_id = &"z2_movement_retreat_fixture"
		runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": true}
	_enter(runtime, ROOM)
	return runtime


func _enter(runtime, pos: Vector2i) -> void:
	runtime.context.player_pos = pos
	runtime.context.current_pos = pos
	var entered: Dictionary = runtime.command_bus.room_resolver.enter_room(runtime.context)
	_check(entered.get("ok", false), "retreat fixture room entry accepted: " + str(entered.get("reason", entered.get("status", ""))))
	runtime.in_run_runtime.sync_room(Vector2(0.5, 0.5))


func _test_flee_and_reentry(z2: bool) -> void:
	var label := "Z2" if z2 else "legacy"
	var runtime = _controller(z2)
	var context = runtime.context
	var bridge = runtime.in_run_runtime
	var first = bridge.simulation
	_check(first != null and bridge.has_active_combat(), label + ": fixture starts real monster encounter")
	if first == null:
		_release(runtime)
		return
	var original: Dictionary = first.enemies[0].duplicate(true)
	var original_reward := Combat.preview_reward_gold(context, ROOM)
	first.set_arena_obstacles([])
	first.place_player_from_room_entry(Vector2(0.5, 0.5), Vector2.RIGHT)
	first.enemies[0]["pos"] = Vector2(0.66, 0.5)
	first.enemies[0]["entry_grace_remaining"] = 20.0
	bridge.request_attack(Vector2.RIGHT)
	for tick in range(20):
		bridge.advance_frame(1.0 / 60.0, Vector2.ZERO, Vector2.RIGHT)
	_check(int(first.enemies[0].hp) < int(original.max_hp) and int(first.enemies[0].hp) > 0, label + ": actual direct attack wounds surviving enemy")
	first.call("_spawn_projectile", String(original.enemy_id), first.player.pos, Vector2.LEFT, 7, {"velocity": Vector2.ZERO})
	bridge.advance_frame(1.0 / 60.0, Vector2.ZERO, Vector2.RIGHT)
	_check(context.hp == 93 and first.player.hp == 93, label + ": actual projectile hit persists player HP before retreat")
	context.asset_ledger.add_currency(&"black_coin", 100 - context.asset_ledger.get_currency(&"black_coin"), "retreat_fixture")
	context.asset_ledger.spend_currency(&"black_coin", 7, "already_consumed")
	context.asset_ledger.backpack_capacity = 2000
	var item: Dictionary = Items.collectible_items()[0]
	for index in range(16):
		var carried := item.duplicate(true)
		carried["instance_id"] = "retreat_common_%d" % index
		carried["reward_location"] = RunAssetLedger.LOCATION_INVENTORY
		context.asset_ledger.add_reward_items([carried], RunAssetLedger.LOCATION_INVENTORY, ROOM, "retreat_fixture")
	context.asset_ledger.add_reward_items([item], RunAssetLedger.LOCATION_ROOM_FLOOR, ROOM, "unclaimed_reward")
	var inventory_before: Array = context.asset_ledger.get_items_by_location(RunAssetLedger.LOCATION_INVENTORY).duplicate(true)
	var floor_before: Array = context.asset_ledger.get_room_floor_items(ROOM).duplicate(true)
	var balance_before: int = context.asset_ledger.get_currency(&"black_coin")
	_check(inventory_before.size() == 16 and floor_before.size() == 1, label + ": real ledger has carried items and an unclaimed reward before retreat")
	var result: Dictionary = bridge.request_flee()
	var action: Dictionary = result.get("action_result", result)
	print("RETREAT_CASE scope=%s hp=%d inventory_before=%d inventory_after=%d floor_before=%d floor_after=%d coins_before=%d coins_after=%d" % [label, context.hp, inventory_before.size(), context.asset_ledger.get_items_by_location(RunAssetLedger.LOCATION_INVENTORY).size(), floor_before.size(), context.asset_ledger.get_room_floor_items(ROOM).size(), balance_before, context.asset_ledger.get_currency(&"black_coin")])
	_check(result.get("ok") == true and bridge.flee_authorized and not bridge.has_active_combat(), label + ": real command authorizes retreat and ends encounter")
	_check(context.hp == 93 and not context.truth_map.is_cleared(ROOM), label + ": retreat neither heals nor clears room")
	if z2:
		_check(balance_before == 93 and context.asset_ledger.get_currency(&"black_coin") == balance_before, "Z2: ordinary retreat adds no currency penalty or refund of earlier consumption")
		_check(context.asset_ledger.get_items_by_location(RunAssetLedger.LOCATION_INVENTORY) == inventory_before, "Z2: ordinary retreat adds no item penalty")
		_check(context.asset_ledger.get_room_floor_items(ROOM) == floor_before, "Z2: existing unclaimed rewards stay unchanged")
		_check(int(action.get("black_coin_loss", -1)) == 0 and action.get("dropped_instance_ids", ["missing"]).is_empty(), "Z2: retreat result reports zero extra losses")
	else:
		_check(context.asset_ledger.get_currency(&"black_coin") == balance_before - 9, "legacy: unversioned path retains original ten-percent fee")
		_check(not action.get("dropped_instance_ids", []).is_empty(), "legacy: fixture exercises original item-drop penalty")
	var floor_after_flee: Array = context.asset_ledger.get_room_floor_items(ROOM).duplicate(true)
	var inventory_after_flee: Array = context.asset_ledger.get_items_by_location(RunAssetLedger.LOCATION_INVENTORY).duplicate(true)
	var balance_after_flee: int = context.asset_ledger.get_currency(&"black_coin")
	bridge.sync_room(Vector2(0.5, 0.5))
	var duplicate: Dictionary = runtime.command_bus.dispatch(&"flee_runtime_combat", {"source": "g41_in_run_runtime"})
	_check(duplicate.get("ok") == true and not bridge.has_active_combat() and context.asset_ledger.get_currency(&"black_coin") == balance_after_flee, label + ": repeated retreat cannot restart encounter or repeat fee")
	_enter(runtime, TRANSIT)
	_check(not bridge.flee_authorized and not bridge.has_active_combat(), label + ": crossing clears room-specific retreat permission")
	_enter(runtime, ROOM)
	var second = bridge.simulation
	_check(second != null and second != first and bridge.has_active_combat(), label + ": reentry starts a fresh active encounter")
	if second != null:
		var enemy: Dictionary = second.enemies[0]
		for field in ["enemy_id", "monster_type", "enemy_name", "max_hp", "enemy_power", "damage"]:
			_check(enemy.get(field) == original.get(field), label + ": same-room reentry keeps enemy " + field)
		_check(enemy.hp == enemy.max_hp, label + ": reentered enemy restores full HP")
		_check(context.hp == 93 and second.player.hp == 93, label + ": reentry preserves damage already taken")
		_check(Combat.preview_reward_gold(context, ROOM) == original_reward, label + ": reentry keeps the same reward")
		_check(context.asset_ledger.get_room_floor_items(ROOM) == floor_after_flee and context.asset_ledger.get_items_by_location(RunAssetLedger.LOCATION_INVENTORY) == inventory_after_flee and context.asset_ledger.get_currency(&"black_coin") == balance_after_flee, label + ": reentry preserves exact pending rewards and remaining assets")
		_test_clear_and_unclaimed_reward(runtime, label)
	_release(runtime)


func _test_clear_and_unclaimed_reward(runtime, label: String) -> void:
	var context = runtime.context
	var bridge = runtime.in_run_runtime
	context.power = 500
	bridge.simulation.set_arena_obstacles([])
	for tick in range(900):
		if not bridge.has_active_combat():
			break
		var target := {}
		for enemy in bridge.simulation.enemies:
			if int(enemy.hp) > 0:
				target = enemy
				break
		if target.is_empty():
			break
		var offset: Vector2 = Vector2(target.pos) - Vector2(bridge.simulation.player.pos)
		var aim := offset.normalized()
		bridge.request_attack(aim)
		bridge.advance_frame(1.0 / 60.0, aim if offset.length() > 0.15 else Vector2.ZERO, aim)
	_check(context.truth_map.is_cleared(ROOM), label + ": real attacks clear room through ordinary reward consumer")
	var floor_items: Array = context.asset_ledger.get_room_floor_items(ROOM).duplicate(true)
	var coins: int = context.asset_ledger.get_currency(&"black_coin")
	var defeated: int = int(context.run_stats.get("monsters_defeated", 0))
	_check(not floor_items.is_empty(), label + ": unclaimed reward fixture remains on room floor after combat")
	_enter(runtime, TRANSIT)
	_enter(runtime, ROOM)
	_check(not bridge.has_active_combat(), label + ": cleared room does not respawn combat")
	_check(context.asset_ledger.get_room_floor_items(ROOM) == floor_items and context.asset_ledger.get_currency(&"black_coin") == coins and int(context.run_stats.get("monsters_defeated", 0)) == defeated, label + ": cleared-room reentry preserves rewards without duplicating grant")


func _release(runtime) -> void:
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.item_command_handler.combat_active_query = Callable()
	runtime.command_bus.bind_runtime_controller(null)
	runtime.command_bus.room_resolver.runtime_controller = null


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
