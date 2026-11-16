extends SceneTree

const EnemyVisuals := preload("res://scripts/presentation/art24/art24_enemy_visual_catalog.gd")
const Actor := preload("res://scripts/gameplay/runtime/g41_runtime_actor_view.gd")
const Balance := preload("res://scripts/core/run/run_balance_catalog.gd")
const Bus := preload("res://scripts/core/command/command_bus.gd")

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_check(Balance.DEFAULT_MAX_HP == 100, "initial_hp_100")
	_check(Balance.DEFAULT_POWER == 20, "initial_power_20")
	_check(Balance.DEFAULT_BACKPACK_CAPACITY == 100, "initial_backpack_capacity_100")
	var context := RunContext.new()
	context.start_run({"id": "scene-default", "width": 5, "height": 5, "seed": 401})
	_check(context.power == 20, "new_run_actual_power_20")
	_test_public_event_intel()
	_test_tutorial_and_trophy()
	_test_item_art()
	for event_number in range(1, 26):
		var event_icon = ContentDBAccess.get_asset_ref(StringName("z1.event.e%02d" % event_number))
		_check(event_icon is Texture2D, "event_public_icon_%02d" % event_number)
	var bus = Bus.new()
	for method: Dictionary in bus.get_method_list():
		if method["name"] == "select_event_option":
			_check(method["args"].size() == 2, "event_option_payload_reaches_domain")
	for number in range(1, 15):
		var subject := StringName("z1_monster_m%02d" % number)
		_check(EnemyVisuals.supports(subject), "monster_supported_%02d" % number)
		if not EnemyVisuals.supports(subject):
			continue
		for state: StringName in [&"idle", &"warning", &"active", &"hurt", &"dead"]:
			for index in range(EnemyVisuals.frame_count(subject, state)):
				var texture: Texture2D = EnemyVisuals.texture_for(subject, state, index)
				_check(texture != null, "frame_%02d_%s_%d" % [number, state, index])
				if texture != null:
					_check(texture.get_size() == Vector2(128, 128), "consistent_frame_size")
		var actor = Actor.new()
		root.add_child(actor)
		actor.configure(subject, {"enemy_id": str(subject), "state": &"idle", "hp": 90, "max_hp": 90, "pos": Vector2(0.5, 0.5)})
		var sprite := actor.get_node_or_null("VisualRoot/ArtVisual") as Sprite2D
		_check(sprite != null and sprite.texture != null, "production_actor_%02d" % number)
		actor.free()
	if failures.is_empty():
		print("Z1_SCENE_INTEGRATION=PASS power,events,14_monsters,140_frames")
		quit(0)
	else:
		for failure in failures:
			print("Z1_SCENE_INTEGRATION_FAIL " + failure)
		quit(1)

func _check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)

func _test_public_event_intel() -> void:
	var context := RunContext.new()
	var recon_room := Vector2i(2, 2)
	var detonation_room := Vector2i(1, 4)
	var mine := Vector2i(1, 3)
	context.start_run({
		"id": "z1-intel", "seed": 3, "width": 5, "height": 5,
		"manual_map": {"spawn": Vector2i(2, 1), "events": [recon_room, detonation_room], "mines": [mine]},
	})
	context.asset_ledger.add_currency(&"black_coin", 100, "test")
	var bus := Bus.new()
	bus.bind_context(context)
	bus.dispatch(&"move_by", {"delta": Vector2i.DOWN})
	_check(EventService.get_event_type(context, context.get_current_pos()) == &"z1_event_e21", "recon_room_uses_natural_event")
	var result := bus.dispatch(&"select_event_option", {"option_id": &"recon_3"})
	_check(bool(result.get("ok", false)), "recon_executes")
	var marker := _public_map_marker(context, mine)
	_check(bool(marker.get("confirmed_mine", false)) and marker.get("room_type") == &"Mine", "recon_public_snapshot_retains_knowledge")
	_check(marker.get("asset_id") == &"icon.room.mine", "recon_mine_is_visible_on_map")
	_check(not bool(marker.get("revealed", true)) and not bool(marker.get("explored", true)), "recon_does_not_visit_mine")
	_check(not bool(marker.get("return_eligibility", {}).get("eligible", true)), "recon_does_not_allow_fast_return")
	var safe := _public_map_marker(context, Vector2i(1, 2))
	_check(safe.get("room_type") == &"Unknown" and safe.get("known_state") == &"unknown", "recon_keeps_safe_rooms_unknown")
	var can_flag := bool(marker.get("action_enabled", false)) and StringName(marker.get("action_id", &"")) == &"toggle_flag"
	_check(can_flag, "recon_allows_map_flag")
	if can_flag:
		bus.dispatch(&"toggle_flag_cell", {"pos": mine})
	marker = _public_map_marker(context, mine)
	_check(bool(marker.get("flagged", false)) and marker.get("asset_id") == &"icon.room.mine", "recon_keeps_confirmed_icon_after_flag")

	for direction: Vector2i in [Vector2i.DOWN, Vector2i.DOWN, Vector2i.LEFT]:
		bus.dispatch(&"move_by", {"delta": direction})
	_check(context.get_current_pos() == detonation_room and EventService.get_event_type(context, detonation_room) == &"z1_event_e19", "detonation_room_uses_natural_event")
	result = bus.dispatch(&"select_event_option", {"option_id": &"detonate", "target_pos": mine})
	_check(bool(result.get("ok", false)) and context.truth_map.is_triggered(mine), "recon_flag_can_be_used_for_remote_detonation")

func _public_map_marker(context: RunContext, pos: Vector2i) -> Dictionary:
	var model := MiniMapViewModel.build_from_run_map_snapshot(context.get_status_snapshot().get("run_map_snapshot", {}))
	for marker in model.room_markers:
		if marker.get("pos") == pos:
			return marker
	return {}

func _test_tutorial_and_trophy() -> void:
	var context := RunContext.new()
	context.start_run(RunConfig.tutorial_5x5())
	_check(not bool(context.z1_event_flags.get("enabled", true)), "tutorial_keeps_original_events")
	for x in range(5):
		for y in range(5):
			_check(not String(EventService.get_event_type(context, Vector2i(x, y))).begins_with("z1_event_"), "tutorial_event_pool")
	context = RunContext.new()
	context.start_run(RunConfig.m7_map({"map_config_id": "classic_7x7_simple"}))
	context.enemy_state = G41MonsterCatalog.runtime_profile(&"z1_monster_m03", 14, "")
	var trophy := RunContentCatalog.monster_trophy(Vector2i(2, 2), 1, context)
	_check(String(trophy.get("item_id", "")) == "sp_inspection_calibration_plate", "m03_runtime_trophy")

func _test_item_art() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/assets/z1_item_art_manifest.json"))
	for record: Dictionary in manifest.get("assets", []):
		var item := {"item_id": String(record["runtime_id"])}
		var expected := String(record["path"])
		var world: Dictionary = Art24ItemVisualCatalog.resolve(item)
		_check(String(world.get("resolved_path", "")) == expected, "shared_item_world_texture_" + item["item_id"])
		var icon := Art09ManifestAssetMapping.resolve_texture(Art09ManifestAssetMapping.inventory_item_icon_ref(item))
		_check(icon != null and icon.get_size() == Vector2(128, 128), "shared_item_warehouse_texture_" + item["item_id"])
