extends SceneTree

const CombatSimulation := preload("res://scripts/gameplay/combat/g41_combat_simulation.gd")
const MonsterCatalog := preload("res://scripts/gameplay/combat/g41_monster_catalog.gd")
const InRunRuntime := preload("res://scripts/core/run/g41_in_run_runtime.gd")
const VisualCatalog := preload("res://scripts/presentation/z1/z1_monster_visual_catalog.gd")
const SAMPLE_HP := [90, 76, 119, 105, 119, 112, 140, 110, 80, 112, 84, 126, 100, 91]
const BASE_HP := [72, 48, 112, 112, 112, 112, 112, 72, 72, 112, 48, 112, 72, 48]
const HP_MULTIPLIERS := [0.9, 1.0, 0.85, 0.75, 0.85, 0.8, 1.0, 1.1, 0.8, 0.8, 1.1, 0.9, 1.0, 1.2]

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var simulation_script: Script = CombatSimulation
	if not simulation_script.can_instantiate():
		_require(false, "production combat simulation did not compile")
		_finish()
		return
	_check_catalog_and_scaling()
	_check_production_encounter_pool()
	_check_spawn_and_legacy_types()
	_check_active_behaviors()
	_check_guard_counter_repair_and_echo()
	_check_timing_obstacles_and_control()
	_check_return_projectile_boundary()
	_check_death_pause_and_determinism()
	_check_echo_survives_the_triggering_hit()
	_check_midair_death_and_mixed_encounter()
	_check_visual_catalog()
	_finish()


func _check_catalog_and_scaling() -> void:
	for index in range(14):
		var monster_type := StringName("z1_monster_m%02d" % (index + 1))
		var definition := MonsterCatalog.definition(monster_type)
		_require(not definition.is_empty(), "%s has no production definition" % monster_type)
		if definition.is_empty():
			continue
		_require(String(definition.get("source_id", "")) == "M%02d" % (index + 1), "%s lost its source identity" % monster_type)
		_require(String(definition.get("visual_key", "")) == "z1.monster.m%02d" % (index + 1), "%s has the wrong visual key" % monster_type)
		var sample := MonsterCatalog.runtime_profile(monster_type, 14, "")
		_require(int(sample.get("max_hp", 0)) == SAMPLE_HP[index], "%s does not match the strength-14 HP sample" % monster_type)
		var lower := MonsterCatalog.runtime_profile(monster_type, 12, "")
		var expected_hp := int(round((float(BASE_HP[index]) + 24.0) * float(HP_MULTIPLIERS[index])))
		_require(int(lower.get("max_hp", 0)) == expected_hp, "%s does not scale HP from encounter strength" % monster_type)
		_require(int(lower.get("base_power", -1)) == 12, "%s did not retain its initial base power" % monster_type)
	_require(MonsterCatalog.definition(&"z1_monster_m00").is_empty(), "unknown Z1 monster was accepted")


func _check_production_encounter_pool() -> void:
	var expected_types: Array[StringName] = [&"slime", &"bat", &"drone"]
	for number in range(1, 15):
		expected_types.append(StringName("z1_monster_m%02d" % number))
	var observed_counts: Dictionary = {}
	var runtime = InRunRuntime.new()
	for seed in range(512):
		for cell: Vector2i in [Vector2i.ZERO, Vector2i(2, 3), Vector2i(6, 5)]:
			var encounter: Array = runtime.call("_encounter_types", seed, cell, seed % 9)
			_require(encounter.size() == 1, "normal room must spawn one mother enemy")
			if encounter.size() != 1:
				continue
			var monster_type := StringName(encounter[0])
			_require(monster_type in expected_types, "normal room selected an unregistered mother enemy")
			_require(encounter == runtime.call("_encounter_types", seed, cell, seed % 9), "normal room changed enemy identity for the same seed and cell")
			observed_counts[monster_type] = int(observed_counts.get(monster_type, 0)) + 1
			if int(observed_counts[monster_type]) == 1:
				var simulation = CombatSimulation.new()
				simulation.start({"seed": seed, "monster_types": encounter, "enemy_profiles": [MonsterCatalog.runtime_profile(monster_type, 14, "")]})
				_require(simulation.enemies.size() == 1 and StringName(simulation.enemies[0]["monster_type"]) == monster_type, "production encounter could not create its selected mother enemy")
	for monster_type in expected_types:
		_require(int(observed_counts.get(monster_type, 0)) > 0, "normal rooms never selected %s across seed enumeration" % monster_type)
	_require(observed_counts.size() == 17, "normal rooms did not reach all three existing and fourteen new mother enemies")
	_require(not observed_counts.has(&"slimeling"), "normal room directly generated the split-only small slime")
	print("Z1_MONSTER_POOL_COVERAGE samples=1536 counts=%s" % JSON.stringify(observed_counts))


func _check_spawn_and_legacy_types() -> void:
	for index in range(14):
		var monster_type := StringName("z1_monster_m%02d" % (index + 1))
		var simulation = CombatSimulation.new()
		var profile := MonsterCatalog.runtime_profile(monster_type, 14, "")
		profile["base_power"] = 12
		simulation.start({"seed": 41, "monster_types": [monster_type], "enemy_profiles": [profile]})
		_require(simulation.enemies.size() == 1, "%s could not spawn through production start" % monster_type)
		if simulation.enemies.is_empty():
			continue
		var enemy: Dictionary = simulation.enemies[0]
		_require(int(enemy.get("max_hp", 0)) == SAMPLE_HP[index], "%s spawn changed calculated HP" % monster_type)
		_require(int(enemy.get("base_power", -1)) == 12, "%s spawn discarded frozen base power" % monster_type)
		_require(String(enemy.get("visual_key", "")) == "z1.monster.m%02d" % (index + 1), "%s spawn discarded visual identity" % monster_type)
		simulation.advance_ticks(29)
		_require(StringName(simulation.enemies[0].get("state", &"")) != &"arrival", "%s stayed frozen after entry grace" % monster_type)
	for monster_type: StringName in [&"slime", &"slimeling", &"bat", &"drone"]:
		var simulation = CombatSimulation.new()
		simulation.start({"seed": 41, "monster_types": [monster_type]})
		_require(simulation.enemies.size() == 1, "legacy %s no longer spawns" % monster_type)
		if not simulation.enemies.is_empty():
			_require(int(simulation.enemies[0].get("max_hp", 0)) == int(MonsterCatalog.definition(monster_type).get("max_hp", 0)), "legacy %s HP changed" % monster_type)
	var template_samples := {&"slime": 100, &"bat": 76, &"drone": 140}
	for monster_type: StringName in template_samples:
		_require(int(MonsterCatalog.runtime_profile(monster_type, 14, "")["max_hp"]) == int(template_samples[monster_type]), "template %s does not match the new-unit sample" % monster_type)
	_require(int(MonsterCatalog.runtime_profile(&"slimeling", 6, "")["max_hp"]) == 30, "small slime does not match the strength-six sample")


func _check_active_behaviors() -> void:
	var expected := {
		1: &"aftershock", 2: &"return_projectile", 3: &"rail_charge",
		5: &"delayed_archive", 7: &"four_way_laser", 8: &"magnetic_pull",
		9: &"pressure_pulse", 11: &"conveyor", 12: &"live_cable", 13: &"marked_jump",
	}
	for index: int in expected:
		var distance := 0.13 if index == 1 else 0.30
		if index == 2:
			distance = 0.55
		var simulation = _fixture(index, distance)
		if simulation.enemies.is_empty():
			continue
		var events: Array[Dictionary] = []
		var saw_warning := false
		var saw_active := false
		for tick in range(480):
			simulation.advance_ticks(1)
			events.append_array(simulation.drain_events())
			for raw_hazard in simulation.build_snapshot().get("hazards", []):
				var hazard: Dictionary = raw_hazard
				_require(String(hazard.get("hazard_id", "")) != "", "M%02d hazard has no stable identity" % index)
				_require(String(hazard.get("owner_id", "")) != "", "M%02d hazard lost its owner" % index)
				saw_warning = saw_warning or StringName(hazard.get("phase", &"")) == &"warning"
				saw_active = saw_active or StringName(hazard.get("phase", &"")) == &"active"
		_require(_has_event(events, &"z1_attack_started", expected[index]), "M%02d never performed %s" % [index, expected[index]])
		if index != 2:
			_require(saw_warning and saw_active, "M%02d attack lacks a warning-to-active hazard lifecycle" % index)
		if index == 2:
			_require(_has_event(events, &"projectile_returned"), "M02 central projectile never returned")
		if index == 7:
			_require(Vector2(simulation.enemies[0]["pos"]).is_equal_approx(Vector2(0.70, 0.50)), "M07 fixed turret moved")
		if index == 9:
			var pressure_events := 0
			for event in events:
				if event.get("event_type") == &"player_damaged" and int(event.get("pressure_delta", 0)) == 4:
					pressure_events += 1
			_require(pressure_events > 0, "M09 hit did not carry its four-point pressure effect")
		if index == 13:
			_require(_has_event(events, &"jump_landed"), "M13 did not finish its marked jump")


func _check_guard_counter_repair_and_echo() -> void:
	var guard = _fixture(4, 0.13)
	if not guard.enemies.is_empty():
		guard.advance_ticks(35)
		var before := int(guard.enemies[0]["hp"])
		_strike(guard, Vector2.LEFT)
		_require(before - int(guard.enemies[0]["hp"]) == 5, "M04 front guard did not reduce a 20-power strike to five damage")
		var guard_events: Array = guard.drain_events()
		_require(_has_event(guard_events, &"guard_blocked"), "M04 did not expose the guarded hit")
	var rear = _fixture(4, 0.13)
	if not rear.enemies.is_empty():
		rear.advance_ticks(35)
		var before := int(rear.enemies[0]["hp"])
		_strike(rear, Vector2.RIGHT)
		_require(before - int(rear.enemies[0]["hp"]) == 20, "M04 rear strike was incorrectly blocked")
	var counter = _fixture(6, 0.13)
	if not counter.enemies.is_empty():
		counter.advance_ticks(35)
		_strike(counter)
		var first_events: Array = counter.drain_events()
		_require(not _has_event(first_events, &"counter_primed"), "M06 counter triggered after only one hit")
		_require(int(counter.enemies[0].get("counter_charge", 0)) == 1, "M06 first hit did not expose the lit counter mark")
		counter.advance_ticks(45)
		_strike(counter)
		var second_events: Array = counter.drain_events()
		_require(_has_event(second_events, &"counter_primed"), "M06 second hit within the lit window did not prime a counter")
		counter.advance_ticks(40)
		_require(_has_event(counter.drain_events(), &"hazard_activated", &"hit_counter"), "M06 counter never activated after its half-second warning")
		_require(int(counter.enemies[0].get("counter_charge", -1)) == 0, "M06 consumed counter mark stayed lit")
	var repair = _fixture(10, 0.13)
	if not repair.enemies.is_empty():
		repair.advance_ticks(35)
		repair.player["power"] = 60
		_strike(repair)
		repair.player["pos"] = Vector2(0.10, 0.10)
		repair.advance_ticks(600)
		var events: Array = repair.drain_events()
		_require(_has_event(events, &"repair_started"), "M10 half-health crossing did not start repair")
		_require(_has_event(events, &"monster_healed"), "M10 did not heal after reaching a free socket")
		_require(int(repair.enemies[0]["hp"]) == 80, "M10 repair did not restore exactly one quarter of maximum HP")
		_strike(repair)
		repair.player["pos"] = Vector2(0.10, 0.10)
		repair.advance_ticks(600)
		_require(not _has_event(repair.drain_events(), &"monster_healed"), "M10 repeated its one-time repair")
	var echo = _fixture(14, 0.30)
	if not echo.enemies.is_empty():
		echo.advance_ticks(35)
		echo.queue_player_attack(Vector2.UP)
		echo.advance_ticks(100)
		var events: Array = echo.drain_events()
		var copies := 0
		for event in events:
			if event.get("event_type") == &"z1_attack_started" and event.get("behavior_id") == &"attack_echo":
				copies += 1
				_require(Vector2(event.get("direction", Vector2.ZERO)).is_equal_approx(Vector2.UP), "M14 changed the copied player facing")
		_require(copies == 1, "M14 did not copy exactly one player attack")


func _fixture(number: int, distance: float = 0.30):
	var monster_type := StringName("z1_monster_m%02d" % number)
	var simulation = CombatSimulation.new()
	simulation.start({
		"seed": 41, "monster_types": [monster_type],
		"player_pos": Vector2(0.70 - distance, 0.50),
		"player_hp": 1000, "player_max_hp": 1000, "player_power": 20,
		"enemy_profiles": [MonsterCatalog.runtime_profile(monster_type, 14, "")],
	})
	if not simulation.enemies.is_empty():
		simulation.enemies[0]["pos"] = Vector2(0.70, 0.50)
	simulation.drain_events()
	return simulation


func _check_timing_obstacles_and_control() -> void:
	var aftershock = _fixture(1, 0.13)
	var ring := _await_hazard(aftershock, &"aftershock")
	_require(not ring.is_empty(), "M01 did not expose its pending outer ring")
	if not ring.is_empty():
		var created_tick := int(aftershock.tick_index)
		aftershock.player["pos"] = Vector2(ring["origin"])
		var hp_before := int(aftershock.player["hp"])
		var activated_tick := -1
		for tick in range(50):
			aftershock.advance_ticks(1)
			for event in aftershock.drain_events():
				if event.get("event_type") == &"hazard_activated" and event.get("hazard_id") == ring["hazard_id"]:
					activated_tick = int(event["tick"])
		_require(activated_tick - created_tick == 39, "M01 aftershock did not wait the full 0.65 seconds after its first strike")
		_require(int(aftershock.player["hp"]) == hp_before, "M01 outer ring damaged the safe center")
	var rail = _fixture(3, 0.45)
	rail.set_arena_obstacles([Rect2(0.50, 0.30, 0.04, 0.40)])
	rail.advance_ticks(180)
	_require(_has_event(rail.drain_events(), &"charge_blocked"), "M03 did not stop when its charge reached cover")
	_require(float(rail.enemies[0]["pos"].x) > 0.54, "M03 crossed solid cover")
	_require(int(rail.player["hp"]) == 1000, "M03 damaged the player through cover")
	var returned = _fixture(2, 0.55)
	returned.set_arena_obstacles([Rect2(0.50, 0.30, 0.04, 0.40)])
	returned.advance_ticks(180)
	var return_events: Array = returned.drain_events()
	_require(_has_event(return_events, &"projectile_blocked"), "M02 central path ignored cover")
	_require(not _has_event(return_events, &"projectile_returned"), "M02 returned a projectile already destroyed by cover")
	for number in [8, 11]:
		var moving = _fixture(number, 0.30)
		var hazard := _await_hazard(moving, &"magnetic_pull" if number == 8 else &"conveyor")
		if hazard.is_empty():
			continue
		var before := Vector2(moving.player["pos"])
		moving.advance_ticks(90)
		var after := Vector2(moving.player["pos"])
		_require(after.x > before.x + 0.05 if number == 8 else after.x < before.x - 0.05, "M%02d control did not move the player along its visible direction" % number)
	var archive = _fixture(5, 0.30)
	var rectangle := _await_hazard(archive, &"delayed_archive")
	if not rectangle.is_empty():
		var locked := Vector2(rectangle["origin"])
		archive.player["pos"] = Vector2(0.15, 0.15)
		archive.advance_ticks(45)
		_require(int(archive.player["hp"]) == 1000, "M05 followed the player after locking the prior position")
		_require(locked.distance_to(Vector2(0.40, 0.50)) < 0.01, "M05 did not target the previous player position")
	var cable = _fixture(12, 0.30)
	var line := _await_hazard(cable, &"live_cable")
	if not line.is_empty():
		cable.player["pos"] = Vector2(line["origin"]).lerp(Vector2(line["endpoint"]), 0.5)
		cable.advance_ticks(45)
		_require(int(cable.player["hp"]) < 1000, "M12 live fixed cable did not damage a player touching it")


func _check_return_projectile_boundary() -> void:
	var bat_origin := Vector2(0.75, 0.50)
	for player_start: Vector2 in [Vector2(0.92, 0.50), Vector2(0.92, 0.63)]:
		var simulation = _fixture(2)
		simulation.enemies[0]["pos"] = bat_origin
		simulation.player["pos"] = player_start
		var warning := _await_hazard(simulation, &"return_projectile")
		if warning.is_empty():
			continue
		var marked_point := Vector2(warning["origin"])
		_require(is_equal_approx(marked_point.x, CombatSimulation.ROOM_MAX), "M02 warning did not clip to the near room wall")
		var aim_direction := (player_start - bat_origin).normalized()
		_require((marked_point - bat_origin).normalized().is_equal_approx(aim_direction), "M02 clipped warning left its locked aiming ray")
		simulation.set_player_input(Vector2.UP)
		simulation.advance_ticks(75)
		var returned := 0
		for event in simulation.drain_events():
			if StringName(event.get("event_type", &"")) == &"projectile_returned":
				returned += 1
				_require(Vector2(event["position"]).is_equal_approx(marked_point), "M02 central projectile did not turn at the warned point")
		_require(returned == 1, "M02 central projectile did not return after the player sidestepped near the wall")


func _check_death_pause_and_determinism() -> void:
	for number in [1, 3, 5, 7, 8, 9, 11, 12, 13]:
		var simulation = _fixture(number, 0.13 if number == 1 else 0.30)
		var behavior := StringName(MonsterCatalog.definition(StringName("z1_monster_m%02d" % number))["behavior_id"])
		var warning := _await_hazard(simulation, behavior)
		if warning.is_empty():
			continue
		var paused_snapshot: Dictionary = simulation.build_canonical_snapshot()
		simulation.set_paused(true)
		simulation.advance_frame(0.25)
		simulation.advance_ticks(10)
		_require(simulation.build_canonical_snapshot() == paused_snapshot, "M%02d advanced while paused" % number)
		simulation.set_paused(false)
		var index := 0
		while index < simulation.enemies.size():
			simulation.call("_damage_enemy", index, 10000)
			index += 1
		simulation.advance_ticks(1)
		_require(simulation.hazards.is_empty() and simulation.cleared, "M%02d left live hazards after every enemy died" % number)
	for number in [2, 3, 5, 7, 8, 9, 11, 12, 13]:
		var first = _fixture(number, 0.30)
		var second = _fixture(number, 0.30)
		first.advance_ticks(360)
		for frame in range(180):
			second.advance_frame(1.0 / 30.0)
		_require(first.build_canonical_snapshot() == second.build_canonical_snapshot(), "M%02d simulation depends on the rendering schedule" % number)


func _check_echo_survives_the_triggering_hit() -> void:
	var echo = _fixture(14, 0.13)
	echo.advance_ticks(35)
	_strike(echo)
	echo.advance_ticks(40)
	_require(_has_event(echo.drain_events(), &"hazard_activated", &"attack_echo"), "M14 lost the promised echo when the observed player strike hit it")


func _check_visual_catalog() -> void:
	var checked_paths: Array[String] = []
	for number in range(1, 15):
		var monster_type := StringName("z1_monster_m%02d" % number)
		_require(VisualCatalog.supports(monster_type), "visual catalog does not support M%02d" % number)
		_require(VisualCatalog.frame_count(monster_type, &"idle") == 2, "M%02d idle does not use two authored frames" % number)
		_require(VisualCatalog.frame_count(monster_type, &"dead") == 5, "M%02d death does not use five authored frames" % number)
		_require(VisualCatalog.texture_path(monster_type, &"hurt") == "res://assets/z1/monsters/m%02d/hurt.png" % number, "M%02d hurt path can drift to an unrelated visual set" % number)
		for state: StringName in [&"idle", &"warning", &"active", &"hurt", &"dead"]:
			for frame_index in range(VisualCatalog.frame_count(monster_type, state)):
				var image_path := VisualCatalog.texture_path(monster_type, state, frame_index)
				checked_paths.append(image_path)
				var texture := VisualCatalog.texture_for(monster_type, state, frame_index)
				var frame: Image = texture.get_image() if texture != null else null
				_require(frame != null, "monster frame could not be loaded: %s" % image_path)
				if frame == null:
					continue
				_require(frame.get_size() == Vector2i(128, 128), "monster frame has a different size: %s" % image_path)
				_require(frame.detect_alpha() != Image.ALPHA_NONE, "monster frame lost its transparent background: %s" % image_path)
				_require(frame.get_used_rect().has_area(), "monster frame is empty: %s" % image_path)
	_require(checked_paths.size() == 140 and checked_paths == VisualCatalog.production_texture_paths(), "Z1 monster catalog does not expose all 140 checked frames")


func _check_midair_death_and_mixed_encounter() -> void:
	var jumping = _fixture(13, 0.30)
	_await_hazard(jumping, &"marked_jump")
	for tick in range(60):
		if StringName(jumping.enemies[0]["state"]) == &"active":
			break
		jumping.advance_ticks(1)
	jumping.advance_ticks(3)
	jumping.player["pos"] = Vector2(0.35, 0.50)
	jumping.player["power"] = 1000
	jumping.set_player_input(Vector2.ZERO, Vector2.RIGHT)
	_require(jumping.queue_player_attack(Vector2.RIGHT), "midair test could not queue the lethal strike")
	jumping.advance_ticks(12)
	_require(int(jumping.enemies[0]["hp"]) == 0, "midair strike missed the marked jumper")
	_require(is_zero_approx(float(jumping.enemies[0].get("visual_lift", 0.0))), "M13 death retained an airborne presentation offset")
	var types: Array[StringName] = []
	for number in range(1, 15):
		types.append(StringName("z1_monster_m%02d" % number))
	var mixed = CombatSimulation.new()
	mixed.start({"seed": 57, "monster_types": types, "player_hp": 10000, "player_max_hp": 10000})
	for tick in range(1200):
		var direction := Vector2.from_angle(float(tick / 90) * PI / 4.0)
		mixed.set_player_input(direction, -direction)
		if tick % 55 == 0:
			mixed.queue_player_attack(-direction)
		mixed.advance_ticks(1)
		var position := Vector2(mixed.player["pos"])
		var in_bounds := position.is_finite() and position == position.clamp(Vector2.ONE * CombatSimulation.ROOM_MIN, Vector2.ONE * CombatSimulation.ROOM_MAX)
		if not in_bounds:
			_require(false, "mixed encounter position at tick %d was (%.9f, %.9f)" % [tick, position.x, position.y])
			break
	_require(mixed.enemies.size() >= 14, "mixed encounter lost its registered enemy roster")


func _await_hazard(simulation, behavior: StringName) -> Dictionary:
	for tick in range(360):
		simulation.advance_ticks(1)
		for hazard in simulation.build_snapshot().get("hazards", []):
			if StringName(hazard.get("behavior_id", &"")) == behavior:
				return hazard
	_require(false, "%s did not produce a hazard before the test deadline" % behavior)
	return {}


func _strike(simulation, side: Vector2 = Vector2.LEFT) -> void:
	var target := Vector2(simulation.enemies[0]["pos"])
	simulation.player["pos"] = target + side * 0.12
	simulation.player["velocity"] = Vector2.ZERO
	simulation.set_player_input(Vector2.ZERO, -side)
	_require(simulation.queue_player_attack(-side), "attack fixture could not queue a ready player strike")
	simulation.advance_ticks(12)


func _has_event(events: Array, event_type: StringName, behavior_id: StringName = &"") -> bool:
	for raw_event in events:
		var event: Dictionary = raw_event
		if StringName(event.get("event_type", &"")) != event_type:
			continue
		if behavior_id == &"" or StringName(event.get("behavior_id", &"")) == behavior_id:
			return true
	return false


func _require(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("Z1_MONSTER_RUNTIME=PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("Z1_MONSTER_RUNTIME=FAIL count=%d" % failures.size())
	quit(1)
