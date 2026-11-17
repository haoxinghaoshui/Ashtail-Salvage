extends Node2D
## Actual GLB-backed presentation, sharing A2's normalized movement coordinates.
## The renderer consumes public snapshots only and never settles event rewards.
const Layout = preload("res://scripts/gameplay/runtime/g41_runtime_layout.gd")
const X_SPAN := 19.3
const Y_SPAN := 14.77
const ELEVATION := 55.0
const FRAME := Rect2(-0.08, -0.28, 1.16, 1.40)
var entry: Dictionary = {}
var viewport: SubViewport
var front_viewport: SubViewport
var room_world: Node3D
var camera: Camera3D
var front_camera: Camera3D
var back_sprite: Sprite2D
var front_sprite: Sprite2D
var model: Node3D
var gates: Dictionary = {}
var gate_targets: Dictionary = {}
var candle_lights: Array[OmniLight3D] = []
var assemblies: Dictionary = {}
var status_lamp: MeshInstance3D
var elapsed := 0.0
var _ready_model := false
var _last_depth := -1

func configure(next_entry: Dictionary) -> void:
	if entry.get("model_path", "") == next_entry.get("model_path", "") and _ready_model:
		show()
		set_process(true)
		return
	_clear()
	entry = next_entry.duplicate(true)
	if entry.is_empty():
		hide()
		return
	_build()

func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	assemblies.clear()
	gates.clear()
	gate_targets.clear()
	candle_lights.clear()
	_ready_model = false
	_last_depth = -1
	set_process(false)

func deactivate() -> void:
	_clear()
	entry.clear()
	hide()

func _build() -> void:
	viewport = SubViewport.new()
	viewport.name = "ModelViewport"
	viewport.transparent_bg = true
	viewport.own_world_3d = true
	viewport.size = Vector2i(1080, 820)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(viewport)
	room_world = Node3D.new()
	viewport.add_child(room_world)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_CLEAR_COLOR
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color(0.31, 0.46, 0.47)
	settings.ambient_light_energy = 0.20
	settings.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = settings
	room_world.add_child(environment)
	if not String(entry.get("shell_path", "")).is_empty():
		var shell := (load(String(entry.shell_path)) as PackedScene).instantiate() as Node3D
		room_world.add_child(shell)
	model = (load(String(entry.model_path)) as PackedScene).instantiate() as Node3D
	room_world.add_child(model)
	_ready_model = model != null
	_index_meshes(room_world)
	camera = _camera(viewport, 1)
	front_viewport = SubViewport.new()
	front_viewport.name = "ForegroundViewport"
	front_viewport.size = viewport.size
	front_viewport.transparent_bg = true
	front_viewport.world_3d = viewport.world_3d
	front_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(front_viewport)
	front_camera = _camera(front_viewport, 2)
	back_sprite = _sprite(viewport, -100)
	front_sprite = _sprite(front_viewport, 650)
	_build_lights()
	_build_gates()
	status_lamp = _box(room_world, Vector3.ZERO, Vector3(0.12, 0.12, 0.12), Color("86b7a2"))
	var anchor: Vector2 = entry.interaction_pos
	status_lamp.position = local_to_model(anchor) + Vector3(0.0, 0.30, 0.0)
	status_lamp.visible = false
	set_meta("B_code", entry.code)
	set_meta("B_model_path", entry.model_path)
	set_process(true)
	show()

func _camera(parent: SubViewport, mask: int) -> Camera3D:
	var c := Camera3D.new()
	c.projection = Camera3D.PROJECTION_ORTHOGONAL
	c.keep_aspect = Camera3D.KEEP_HEIGHT
	var height := Y_SPAN * sin(deg_to_rad(ELEVATION)) * FRAME.size.y
	c.size = height
	# Match projection width to the source room coordinate span before the 2D
	# viewport is fitted to the same room rectangle as actors and hit tests.
	parent.size = Vector2i(roundi(820 * X_SPAN * FRAME.size.x / height), 820)
	var center := local_to_model(FRAME.get_center())
	c.position = center + Vector3(0, sin(deg_to_rad(ELEVATION)), cos(deg_to_rad(ELEVATION))) * 30.0
	parent.add_child(c)
	c.look_at(center, Vector3.UP)
	c.cull_mask = mask
	c.current = true
	return c

func _sprite(source: SubViewport, depth: int) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = source.get_texture()
	sprite.centered = false
	sprite.position = Layout.local_to_world(FRAME.position)
	sprite.scale = Layout.local_size_to_world(FRAME.size) / Vector2(source.size)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sprite.z_index = depth
	add_child(sprite)
	return sprite

func _index_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh := node as MeshInstance3D
		mesh.layers = 1
		var id := String(mesh.get_meta("B_assembly", ""))
		if id.is_empty():
			for unit: Dictionary in entry.units:
				if String(mesh.name).contains("__" + String(unit.id) + "_"):
					id = String(unit.id)
					break
		if not id.is_empty():
			if not assemblies.has(id):
				assemblies[id] = []
			assemblies[id].append(mesh)
	for child in node.get_children():
		_index_meshes(child)

func _build_lights() -> void:
	for p: Vector3 in [Vector3(-2.0, 1.65, -6), Vector3(2.0, 1.65, -6), Vector3(-7.8, 1.45, -1.7), Vector3(-7.8, 1.45, 1.7), Vector3(7.8, 1.45, -1.7), Vector3(7.8, 1.45, 1.7), Vector3(-2.0, 0.8, 5.8), Vector3(2.0, 0.8, 5.8)]:
		var light := OmniLight3D.new()
		light.position = p
		light.light_color = Color(1.0, 0.56, 0.24)
		light.light_energy = 3.4
		light.omni_range = 6.0
		light.omni_attenuation = 1.4
		room_world.add_child(light)
		candle_lights.append(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-65, -25, 0)
	fill.light_color = Color(0.36, 0.57, 0.60)
	fill.light_energy = 0.12
	room_world.add_child(fill)
	var work := OmniLight3D.new()
	work.position = local_to_model(entry.interaction_pos) + Vector3(0, 4.5, -0.8)
	work.light_color = Color(1.0, 0.76, 0.44)
	work.light_energy = 2.0
	work.omni_range = 6.0
	work.shadow_enabled = true
	room_world.add_child(work)

func _box(parent: Node3D, pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var obj := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	obj.mesh = shape
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	obj.material_override = material
	obj.position = pos
	obj.layers = 1
	parent.add_child(obj)
	return obj

func _build_gates() -> void:
	for side in ["north", "east", "south", "west"]:
		var gate := Node3D.new()
		gate.name = "B_Gate_" + side
		room_world.add_child(gate)
		gate.position = {"north": Vector3(0, 0, -6.45), "south": Vector3(0, 0, 6.45), "east": Vector3(8.4, 0, 0), "west": Vector3(-8.4, 0, 0)}[side]
		if side in ["east", "west"]:
			gate.rotation.y = PI / 2
		for i in range(9):
			_box(gate, Vector3(-0.96 + i * 0.24, 0.82, 0), Vector3(0.09, 1.64, 0.11), Color("343f3b"))
		for y in [0.18, 1.5]:
			_box(gate, Vector3(0, y, 0), Vector3(2.15, 0.14, 0.15), Color("544735"))
		gate.position.y = -1.9
		gate.hide()
		gates[side] = gate
		gate_targets[side] = -1.9

func apply_snapshot(snapshot: Dictionary, doors: Array[Dictionary]) -> void:
	if not _ready_model:
		return
	var state: Dictionary = snapshot.get("event_state", {})
	status_lamp.visible = bool(state.get("completed", false))
	for d in doors:
		var side := String(d.get("orientation", ""))
		if gates.has(side):
			gate_targets[side] = -1.9 if StringName(d.get("visual_state", &"")) == &"available" else 0.0
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	front_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func update_player_depth(player: Vector2) -> void:
	if not _ready_model:
		return
	var bucket := roundi(player.y * 1000)
	if bucket == _last_depth:
		return
	_last_depth = bucket
	var changed := false
	for unit: Dictionary in entry.units:
		var mask := 3 if player.y < float(unit.ground_y) - 0.01 else 1
		for mesh: MeshInstance3D in assemblies.get(String(unit.id), []):
			changed = changed or mesh.layers != mask
			mesh.layers = mask
	if changed:
		front_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _process(delta: float) -> void:
	var previous := elapsed
	elapsed += delta
	for i in candle_lights.size():
		candle_lights[i].light_energy = 3.4 * (1.0 + 0.035 * sin(elapsed * 6.0 + i * 1.7))
	for side in gates:
		var gate: Node3D = gates[side]
		if not is_equal_approx(gate.position.y, float(gate_targets[side])):
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		gate.position.y = move_toward(gate.position.y, float(gate_targets[side]), delta * 4.0)
		gate.visible = gate.position.y > -1.64
	if int(previous * 10.0) != int(elapsed * 10.0):
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		front_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

static func local_to_model(pos: Vector2) -> Vector3:
	return Vector3((pos.x - 0.5) * X_SPAN, 0.06, (pos.y - 0.5) * Y_SPAN)

func debug_snapshot() -> Dictionary:
	return {"model_loaded": _ready_model, "code": entry.get("code", ""), "model_path": entry.get("model_path", ""), "assemblies": assemblies.keys(), "gate_targets": gate_targets.duplicate(), "lights": candle_lights.size()}
