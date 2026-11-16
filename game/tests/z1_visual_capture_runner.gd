extends "res://tests/art25_production_visual_capture_runner.gd"

var z1_capture_options: Dictionary = {}

func _capture_one(options: Dictionary) -> void:
	z1_capture_options = options.duplicate(true)
	await super._capture_one(options)

func _teleport_and_focus(run_scene, room_type: StringName, local_pos: Vector2) -> bool:
	if not await super._teleport_and_focus(run_scene, room_type, local_pos):
		return false
	if room_type == &"Event":
		var view = run_scene.get("room_runtime_view")
		var action_id := StringName(z1_capture_options.get("action", &""))
		if action_id != &"" and not _apply_event_capture_action(run_scene, action_id):
			return false
		if bool(z1_capture_options.get("room-only", false)):
			if action_id == &"enter_cage" and not await _await_condition(
				func() -> bool:
					for actor in view.enemy_views.values():
						if StringName(actor.presentation_snapshot().get("phase", &"arrival")) != &"arrival":
							return true
					return false,
				"cage entrant visible"
			):
				return false
			run_scene.set_process(false)
			run_scene.set_physics_process(false)
			view.set_context_ui_suppressed(true)
			var runtime = run_scene.get("in_run_runtime")
			if not runtime.has_active_combat():
				var player = run_scene.get("player_controller")
				player.place_on_clear_floor(Vector2(0.36, 0.74))
				view.advance(0.0, player.get_local_position(), runtime.build_read_only_snapshot())
	return await _await_layout_stable(run_scene, "Z1 room fixture")


func _apply_event_capture_action(run_scene: Node, action_id: StringName) -> bool:
	var context: RunContext = run_scene.get("run_context")
	var state: Dictionary = context.get_status_snapshot().get("event_state", {})
	for option: Dictionary in state.get("options", []):
		if StringName(option.get("id", &"")) != action_id or not bool(option.get("enabled", true)):
			continue
		var payload: Dictionary = (option.get("payload", {}) as Dictionary).duplicate(true)
		payload["option_id"] = action_id
		var result: Dictionary = run_scene.get("command_bus").dispatch(&"select_event_option", payload)
		if bool(result.get("ok", false)):
			print("Z1_ROOM_CAPTURE_ACTION=PASS %s %s" % [state.get("event_type", ""), action_id])
			return true
		break
	_fail("Event capture action was unavailable: %s" % action_id)
	return false

func _teleport_to_room(run_scene, room_type: StringName) -> bool:
	if not await super._teleport_to_room(run_scene, room_type):
		return false
	run_scene.call("_hide_runtime_popups")
	var context: RunContext = run_scene.get("run_context")
	context.tutorial_popup.clear()
	run_scene.get("tutorial_popup_panel").apply_popup({})
	if room_type == &"Event" and z1_capture_options.has("event"):
		context.z1_event_rooms[context.cell_key(context.get_current_pos())] = {"event_type": StringName(z1_capture_options["event"])}
		context.asset_ledger.add_currency(&"black_coin", 100, "visual_fixture")
		context.asset_ledger.sync_compat_fields(context)
		if z1_capture_options.has("pressure"):
			context.pressure = int(z1_capture_options["pressure"])
		run_scene.call("_refresh_view_models")
	if room_type == &"Monster" and z1_capture_options.has("monster"):
		var subject := StringName(z1_capture_options["monster"])
		var runtime = run_scene.get("in_run_runtime")
		var profile := G41MonsterCatalog.runtime_profile(subject, 14, "")
		context.enemy_state = profile.duplicate(true)
		var simulation := G41CombatSimulation.new()
		simulation.start({"seed": 311, "player_pos": Vector2(0.30, 0.72), "player_facing": Vector2.RIGHT, "player_hp": context.hp, "player_max_hp": context.max_hp, "player_power": context.power, "monster_types": [subject], "enemy_profiles": [profile], "arena_obstacles": G41CombatSimulation.production_arena_obstacles()})
		runtime.simulation = simulation
		var pose := StringName(z1_capture_options.get("pose", "idle"))
		if pose != &"idle":
			for tick in range(180):
				simulation.advance_frame(1.0 / 60.0)
				var enemies: Array = simulation.build_snapshot().get("enemies", [])
				if not enemies.is_empty() and StringName(enemies[0].get("state", &"")) == pose:
					break
		run_scene.get("player_controller").set_local_position(Vector2(0.30, 0.72))
		run_scene.call("_refresh_view_models")
		run_scene.get("room_runtime_view").apply_combat_snapshot(runtime.build_read_only_snapshot())
		run_scene.set_process(false)
		run_scene.set_physics_process(false)
	return true
