extends Node2D
## Private 3D actor and effect pass registered to the existing room projection.

const Rig := preload("res://scripts/presentation/voxel_a1/voxel_rig.gd")
const EnemyArt := preload("res://scripts/presentation/voxel_a1/voxel_enemy_art.gd")
const Effects := preload("res://scripts/presentation/voxel_a1/voxel_fx.gd")
const HostileEffects := preload("res://scripts/presentation/voxel_a1/voxel_hostile_fx.gd")
const Weapons := preload("res://scripts/gameplay/combat/field_weapons.gd")
const Depth := preload("res://scripts/gameplay/runtime/g41_world_object_presentation_descriptor.gd")
const Combat := preload("res://scripts/gameplay/combat/g41_combat_simulation.gd")
const Talents := preload("res://scripts/core/progression/z2_talent_runtime.gd")
const MODEL_TYPES := [&"slime", &"slimeling", &"bat", &"drone", &"ironback"]
const ELEVATION := 0.93
const SPAN := 10.0
const FLOOR := 0.065
const EFFECT_VIEW_SIZE := Vector2i(760, 756)
const MODEL_VIEW_SIZE := Vector2i(216, 200)

var actor: Rig
var fx: Effects
var hostile_fx: HostileEffects
var stage: Node3D
var combat_entities: Node3D
var camera: Camera3D
var shared_world: World3D
var player_canvas: Dictionary
var occupied_layers: Dictionary = {}
var last_local := Vector2(0.5, 0.5)
var actor_heading := Vector3.BACK
var last_event := -1
var room_key := ""
var encounter_id := ""
var clock := 0.0
var last_attack := -1.0
var enemies: Dictionary = {}
var bolts: Dictionary = {}
var beams: Dictionary = {}
var muzzle_flashes := 0
var armor_impacts := 0
var soft_impacts := 0
var equipment_label: Label


func _ready() -> void:
	z_index = 660
	var view := SubViewport.new()
	view.size = EFFECT_VIEW_SIZE
	view.transparent_bg = true
	shared_world = World3D.new()
	view.world_3d = shared_world
	view.gui_disable_input = true
	view.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	view.msaa_3d = Viewport.MSAA_2X
	add_child(view)
	var picture := Sprite2D.new()
	picture.texture = view.get_texture()
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	picture.position = G41RuntimeLayout.ROOM_RECT.get_center()
	add_child(picture)
	stage = Node3D.new()
	view.add_child(stage)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("#adb8c4")
	settings.ambient_light_energy = 0.52
	environment.environment = settings
	stage.add_child(environment)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-61, -39, 0)
	key.light_color = Color("#f4dfbc")
	key.light_energy = 0.91
	stage.add_child(key)
	camera = Camera3D.new()
	stage.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.cull_mask = 1
	camera.size = float(view.size.y) * SPAN / G41RuntimeLayout.ROOM_RECT.size.y
	camera.position = Vector3(0, sin(ELEVATION), cos(ELEVATION)) * 16.0
	camera.look_at(Vector3.ZERO)
	camera.current = true
	combat_entities = Node3D.new()
	stage.add_child(combat_entities)
	actor = Rig.new()
	stage.add_child(actor)
	actor.build(true)
	player_canvas = _add_model_view(actor)
	fx = Effects.new()
	stage.add_child(fx)
	fx.build()
	hostile_fx = HostileEffects.new()
	stage.add_child(hostile_fx)
	hostile_fx.build()
	equipment_label = Label.new()
	equipment_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	equipment_label.position = G41RuntimeLayout.ROOM_RECT.position + Vector2(14.0, 9.0)
	equipment_label.add_theme_font_size_override("font_size", 18)
	equipment_label.add_theme_constant_override("outline_size", 4)
	equipment_label.add_theme_color_override("font_color", Color("#f4d9a6"))
	equipment_label.add_theme_color_override("font_outline_color", Color("#202023"))
	add_child(equipment_label)


static func visual_type(data: Dictionary) -> StringName:
	var kind := StringName(data.get("monster_type", &""))
	return &"ironback" if data.get("behavior_id", &"") == &"directional_guard" else kind


func advance(delta: float, position_local: Vector2, facing: Vector2, snapshot: Dictionary) -> void:
	if actor == null or not is_visible_in_tree():
		return
	var next_room := String(snapshot.get("room_key", ""))
	var changed := next_room != room_key
	if changed:
		room_key = next_room
		encounter_id = ""
		last_event = -1
		last_attack = -1.0
		fx.clear()
		hostile_fx.clear()
	var encounter := String(snapshot.get("encounter_id", ""))
	if not encounter.is_empty() and encounter != encounter_id:
		encounter_id = encounter
		last_event = -1
	clock += delta
	var speed := 0.0 if changed or delta <= 0.0 else last_local.distance_to(position_local) * SPAN / delta
	last_local = position_local
	var heading := _direction(facing)
	if heading.length_squared() > 0.001:
		actor_heading = heading
	actor.rotation.y = atan2(actor_heading.x, actor_heading.z)
	var combat_player: Dictionary = snapshot.get("player", {})
	var loadout: Dictionary = snapshot.get("field_weapons", {})
	actor.position = _world(position_local, FLOOR + float(combat_player.get("visual_lift", 0.0)) * SPAN)
	var attack: Dictionary = snapshot.get("player_attack_geometry", {})
	var strike := _attack_phase(combat_player)
	var selected := StringName(loadout.get("selected", Weapons.AXE))
	var weapon := StringName(attack.get("weapon", selected))
	if selected == Weapons.AXE:
		equipment_label.text = "战斧  ·  1 战斧  2 卡宾  3 霰弹"
	else:
		var profile: Dictionary = Weapons.PROFILES[selected]
		equipment_label.text = "%s %d/%d  备用 %d  ·  R 装填" % [profile["name"],
			loadout.get("magazines", {}).get(String(selected), 0), profile["magazine"], loadout.get("reserve", 0)]
	var variant := int(String(attack.get("attack_id", "0")).get_slice("_", 2)) % 3
	var had_firearm := actor.firearm != null
	actor.animate(delta, minf(speed, 6.0), smoothstep(3.2, 5.2, speed), strike, weapon,
		float(loadout.get("reload", 0.0)), 0.0, variant, StringName(combat_player.get("state", &"idle")))
	if not had_firearm and actor.firearm != null:
		_assign_render_layer(actor, int(player_canvas["layer"]))
	_position_model_view(player_canvas, actor.position, position_local.y)
	if weapon == &"axe" and strike >= 0.30 and strike <= 0.77 and not is_equal_approx(strike, last_attack):
		var origin := Vector2(attack.get("origin", position_local))
		fx.trace(_clip_blade(actor.blade_points(), origin, snapshot.get("arena_obstacles", [])), variant)
	last_attack = strike
	var seen := _sync_actors(snapshot.get("enemies", []))
	_events(snapshot.get("recent_events", []))
	_sync_projectiles(snapshot)
	_retire_actors(seen)
	fx.step(delta)
	hostile_fx.step(delta, camera)


func _attack_phase(player: Dictionary) -> float:
	var speed := Talents.speed_multiplier(player.get("z2_talents", {}), "attack_speed_percent")
	var timer := float(player.get("state_timer", 0.0)) * speed
	match player.get("state", &""):
		&"attack_windup":
			return lerpf(0.0, 0.40, 1.0 - clampf(timer / Combat.PLAYER_ATTACK_WINDUP, 0.0, 1.0))
		&"attack_active":
			return lerpf(0.40, 0.77, 1.0 - clampf(timer / Combat.PLAYER_ATTACK_ACTIVE, 0.0, 1.0))
		&"attack_recovery":
			return lerpf(0.77, 1.0, 1.0 - clampf(timer / Combat.PLAYER_ATTACK_RECOVERY, 0.0, 1.0))
	return -1.0


func _add_model_view(model: Node3D) -> Dictionary:
	var layer_index := 1
	while occupied_layers.has(layer_index):
		layer_index += 1
	if layer_index >= 20:
		return {}
	occupied_layers[layer_index] = true
	var mask := 1 << layer_index
	_assign_render_layer(model, mask)
	var sprite := Sprite2D.new()
	sprite.z_as_relative = false
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(sprite)
	var view := SubViewport.new()
	view.size = MODEL_VIEW_SIZE
	view.world_3d = shared_world
	view.transparent_bg = true
	view.gui_disable_input = true
	view.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	view.msaa_3d = Viewport.MSAA_2X
	sprite.add_child(view)
	var model_camera := Camera3D.new()
	view.add_child(model_camera)
	model_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	model_camera.size = float(view.size.y) * SPAN / G41RuntimeLayout.ROOM_RECT.size.y
	model_camera.cull_mask = mask
	model_camera.current = true
	sprite.texture = view.get_texture()
	return {"sprite": sprite, "camera": model_camera, "index": layer_index, "layer": mask}


func _assign_render_layer(model: Node3D, layer: int) -> void:
	for child in model.find_children("*", "MeshInstance3D", true, false):
		(child as MeshInstance3D).layers = layer


func _position_model_view(row: Dictionary, position: Vector3, depth: float) -> void:
	var target := position + Vector3.UP * 0.95
	var sprite := row["sprite"] as Sprite2D
	var model_camera := row["camera"] as Camera3D
	sprite.position = G41RuntimeLayout.ROOM_RECT.get_center() + camera.unproject_position(target) - Vector2(EFFECT_VIEW_SIZE) * 0.5
	sprite.z_index = Depth.ground_depth(depth)
	model_camera.position = camera.position + target
	model_camera.basis = camera.basis


func _clip_blade(points: PackedVector3Array, center: Vector2, obstacles: Array) -> PackedVector3Array:
	for i in points.size():
		var p := points[i]
		var at := Vector2(p.x, p.z * sin(ELEVATION)) / SPAN + Vector2(0.5, 0.5)
		var first := at
		var distance := at.distance_squared_to(center)
		for bounds in obstacles:
			var rect := Rect2(bounds)
			var corners := [rect.position, rect.position + Vector2(rect.size.x, 0), rect.end, rect.position + Vector2(0, rect.size.y)]
			for side in 4:
				var contact = Geometry2D.segment_intersects_segment(center, at, corners[side], corners[(side + 1) % 4])
				if contact is Vector2 and center.distance_squared_to(contact) < distance:
					first = contact
					distance = center.distance_squared_to(contact)
		points[i] = _world(first, p.y)
	return points


func _sync_actors(snapshots: Array) -> Dictionary:
	var seen := {}
	for data: Dictionary in snapshots:
		var kind := visual_type(data)
		if kind not in MODEL_TYPES:
			continue
		var id := String(data["enemy_id"])
		seen[id] = true
		if not enemies.has(id):
			var instance := _create_actor(kind)
			var canvas := _add_model_view(instance["node"])
			if canvas.is_empty():
				(instance["node"] as Node3D).queue_free()
				continue
			instance["canvas"] = canvas
			enemies[id] = instance
		var row: Dictionary = enemies[id]
		var model := row["node"] as Node3D
		model.visible = int(data.get("hp", 1)) > 0
		var local := Vector2(data["pos"])
		var airborne := kind in [&"bat", &"drone"]
		var altitude := 0.34 + sin(clock * 8.8) * 0.073 if airborne else 0.0
		model.position = _world(local, FLOOR + altitude + float(data.get("visual_lift", 0.0)) * SPAN)
		var heading := _direction(Vector2(data.get("facing", local.direction_to(last_local))))
		model.rotation.y = atan2(heading.x, heading.z)
		var state := StringName(data.get("state", &"idle"))
		var body := row["body"] as Node3D
		var recoil := clampf(float(row.get("hit_until", 0.0)) - clock, 0.0, 0.16)
		body.rotation.x = -recoil * 1.4
		if kind in [&"slime", &"slimeling"]:
			var stretch := 0.77 if state == &"warning" else (1.24 if state == &"active" else 1.0)
			body.scale = Vector3(1.06 if stretch < 1.0 else 1.0, stretch, 1.06 if stretch < 1.0 else 1.0)
		if row.has("wings"):
			var beat := sin(clock * (27.0 if state == &"fire" else 17.0))
			row["wings"][0].rotation.z = beat * 0.69
			row["wings"][1].rotation.z = -beat * 0.69
		if row.has("rotor"):
			row["rotor"].rotation.y = clock * (12.6 if state == &"fire" else 4.1)
		if row.has("lens"):
			var lens := row["lens"] as MeshInstance3D
			(lens.material_override as StandardMaterial3D).albedo_color = EnemyArt.BLUE.lightened(0.39 if state == &"fire" else 0.0)
		_position_model_view(row["canvas"], model.position, local.y)
		if row.has("boss_fists"):
			var striking := state in [&"active", &"charge", &"fire"]
			var arm_tilt := 1.15 if state in [&"warning", &"aim"] else (-0.56 if striking else 0.12)
			for fist: Node3D in row["boss_fists"]:
				fist.rotation.x = arm_tilt
	return seen


func _retire_actors(seen: Dictionary) -> void:
	for id in enemies.keys():
		if seen.has(id):
			continue
		var row: Dictionary = enemies[id]
		var model := row["node"] as Node3D
		var canvas: Dictionary = row["canvas"]
		model.hide()
		model.queue_free()
		(canvas["sprite"] as Sprite2D).queue_free()
		occupied_layers.erase(canvas["index"])
		enemies.erase(id)


func _create_actor(kind: StringName) -> Dictionary:
	var anchor := Node3D.new()
	combat_entities.add_child(anchor)
	var body := Node3D.new()
	anchor.add_child(body)
	var row := {"node": anchor, "body": body, "type": kind}
	match kind:
		&"drone":
			var rotor := Node3D.new()
			rotor.position.y = 0.45
			body.add_child(rotor)
			row["rotor"] = rotor
			row["lens"] = EnemyArt.drone_parts(body, rotor)
		&"bat":
			EnemyArt.faceted(body, Vector3(0, 0.40, 0.0), Vector3(0.59, 0.53, 0.50), Color("#665778"))
			EnemyArt.bat_face(body)
			var wings: Array[Node3D] = []
			for sign_value in [-1.0, 1.0]:
				var wing := Node3D.new()
				wing.position = Vector3(float(sign_value) * 0.27, 0.49, 0.0)
				body.add_child(wing)
				EnemyArt.wing(wing, sign_value)
				wings.append(wing)
			row["wings"] = wings
		&"ironback":
			EnemyArt.armor(body, Vector3(0, 0.58, 0.0), Vector3(1.10, 1.06, 0.65), EnemyArt.IRON)
			EnemyArt.ironback_parts(row, body)
		_:
			var dim := Vector3(0.98, 0.66, 0.78) * (0.65 if kind == &"slimeling" else 1.0)
			var skin := EnemyArt.faceted(body, Vector3.UP * dim.y * 0.49, dim, Color("#758945"))
			(skin.material_override as StandardMaterial3D).roughness = 0.36
			(skin.material_override as StandardMaterial3D).metallic_specular = 0.62
			for side in [-1.0, 1.0]:
				EnemyArt.faceted(body, Vector3(float(side) * dim.x * 0.19, dim.y * 0.62, dim.z * 0.46), Vector3(0.101, 0.083, 0.046), Color("#b3e5a5"), "gem", true)
			EnemyArt.gel_details(body, dim)
	return row


func _events(events: Array) -> void:
	for item: Dictionary in events:
		if encounter_id.is_empty() or item.get("encounter_id", "") != encounter_id:
			continue
		var index := int(item.get("event_index", -1))
		if index <= last_event:
			continue
		last_event = index
		match item.get("event_type", &""):
			&"player_attack_resolved":
				_player_hit(item)
			&"projectile_hit", &"projectile_blocked":
				var id := String(item.get("projectile_id", ""))
				var owner: Dictionary = enemies.get(String(item.get("owner_id", "")), {})
				if bolts.has(id) or owner.get("type") == &"bat":
					hostile_fx.bolt_contact(_world(Vector2(item["position"]), 0.60),
						_direction(Vector2(item.get("direction", Vector2.RIGHT))))
			&"ranged_fired":
				var owner: Dictionary = enemies.get(String(item.get("enemy_id", "")), {})
				if owner.get("type") == &"bat":
					var source := owner["node"] as Node3D
					hostile_fx.release(&"spread", source.position + Vector3.UP * 0.28, source.position,
						source.basis.z, 0.0, PackedVector3Array())
			&"player_damaged":
				fx.impact(actor.position + Vector3.UP * 0.71, -actor_heading, Color("#e0785b"))


func _player_hit(event: Dictionary) -> void:
	var weapon := StringName(event.get("weapon", &"axe"))
	var heading := _direction(Vector2(event.get("facing", Vector2.RIGHT)))
	if weapon != &"axe" and actor.muzzle != null:
		var ends := PackedVector3Array()
		var blocked: Array = event.get("shot_obstacle_endpoints", [])
		var muzzle := actor.muzzle.global_position
		for endpoint: Vector2 in event.get("shot_endpoints", PackedVector2Array()):
			var at := _world(endpoint, muzzle.y - (0.14 if endpoint in blocked else 0.0))
			ends.append(at)
			if endpoint in blocked:
				fx.obstruction_hit(at, -heading)
		fx.shot(muzzle, actor.shell_port.global_position, ends, heading, weapon == &"scattergun")
		muzzle_flashes += 1
	for id: String in event.get("hit_enemy_ids", []):
		if not enemies.has(id):
			continue
		var row: Dictionary = enemies[id]
		var target := row["node"] as Node3D
		var kind := StringName(row["type"])
		var shell := kind in [&"drone", &"ironback"]
		var gel := kind in [&"slime", &"slimeling"]
		var height := 0.38 if kind != &"ironback" else 0.71
		var contact := (target.position + Vector3.UP * height).move_toward(actor.position + Vector3.UP * 0.71, 0.32)
		var tint := Color("#e6a665") if weapon == &"axe" else Color("#9bd7e9")
		fx.impact(contact, heading, tint, &"armor" if shell else (&"gel" if gel else &"body"))
		row["hit_until"] = clock + 0.16
		armor_impacts += int(shell)
		soft_impacts += int(gel)


func _sync_projectiles(snapshot: Dictionary) -> void:
	var live_bolts := {}
	for shot: Dictionary in snapshot.get("projectiles", []):
		if enemies.get(String(shot.get("owner_id", "")), {}).get("type") != &"bat":
			continue
		var id := String(shot["projectile_id"])
		live_bolts[id] = true
		if not bolts.has(id):
			bolts[id] = hostile_fx.bolt_view(combat_entities)
		var bolt := bolts[id] as Node3D
		bolt.position = _world(Vector2(shot["pos"]), 0.62)
		var direction := _direction(Vector2(shot.get("velocity", Vector2.RIGHT)))
		bolt.rotation.y = atan2(direction.x, direction.z)
		(bolt.get_child(0) as Node3D).rotation.z = clock * 6.0
	_retire_missing(bolts, live_bolts)
	var live_beams := {}
	for laser: Dictionary in snapshot.get("lasers", []):
		var id := String(laser.get("owner_id", ""))
		var owner: Dictionary = enemies.get(id, {})
		if owner.get("type") != &"drone":
			continue
		var source := owner["node"] as Node3D
		var at := source.position + Vector3.UP * 0.28
		var to := _world(Vector2(laser["endpoint"]), at.y)
		var direction := at.direction_to(to)
		if at.distance_to(to) < 0.04:
			continue
		source.rotation.y = atan2(direction.x, direction.z)
		at = at.move_toward(to, minf(0.51, at.distance_to(to) * 0.35))
		live_beams[id] = true
		var first := not beams.has(id)
		if first:
			beams[id] = hostile_fx.laser_view(combat_entities)
		var beam := beams[id] as Node3D
		beam.scale = Vector3.ONE
		beam.position = at
		beam.look_at(to, Vector3.UP, true)
		var pulse := lerpf(0.27, 1.0, smoothstep(0.0, 0.14, float(laser["remaining"])))
		beam.scale = Vector3(pulse, pulse, at.distance_to(to))
		for i in range(1, beam.get_child_count()):
			var glint := beam.get_child(i) as Node3D
			var progress := fposmod(clock * 2.8 + i * 0.25, 1.0)
			glint.position.z = progress
			glint.visible = progress > 0.06 and progress < 0.95
		if bool(laser.get("occluded", false)) and (first or clock >= float(beam.get_meta("next_contact", 0.0))):
			hostile_fx.beam_contact(to - direction * 0.04, direction, first)
			beam.set_meta("next_contact", clock + 0.11)
	_retire_missing(beams, live_beams)


func _retire_missing(views: Dictionary, visible_ids: Dictionary) -> void:
	for id in views.keys():
		if not visible_ids.has(id):
			(views[id] as Node3D).queue_free()
			views.erase(id)


func _direction(value: Vector2) -> Vector3:
	return Vector3(value.x, 0, value.y / sin(ELEVATION)).normalized()


func _world(value: Vector2, height: float) -> Vector3:
	return Vector3((value.x - 0.5) * SPAN, height, (value.y - 0.5) * SPAN / sin(ELEVATION))
