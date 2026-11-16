extends Node2D

const ItemVisuals := preload("res://scripts/presentation/art24/art24_item_visual_catalog.gd")
const GOLD := Color("e1b567")
const TEAL := Color("7fbeb0")
const RED := Color("bf6244")
const DARK := Color("32251e")
const BEZEL := Color("1a1815")

var _room_id := ""
var _state_id: StringName = &"ready"
var _markers: Dictionary = {}
var _rect := Rect2()
var _stock: Array = []
var _slot_icons: Array[Texture2D] = []


func configure(projection: Dictionary) -> void:
	var payload: Dictionary = projection.get("payload", {})
	_room_id = String(payload.get("event_room_id", ""))
	_state_id = StringName(payload.get("station_state", &"ready"))
	_markers = payload.get("station_markers", {})
	var visible_rect := Rect2(projection["visual_rect_local"])
	var interaction_pos := Vector2(projection["local_pos"])
	_rect = Rect2(
		G41RuntimeLayout.local_size_to_world(visible_rect.position - interaction_pos),
		G41RuntimeLayout.local_size_to_world(visible_rect.size)
	)
	var stock: Array = payload.get("station_stock", [])
	if stock != _stock:
		_stock = stock.duplicate(true)
		_slot_icons.clear()
		for slot: Dictionary in _stock:
			_slot_icons.append(null if bool(slot.get("sold", false)) else ItemVisuals.texture_for(slot))
	set_meta("station_state", _state_id)
	set_meta("stock", _stock.duplicate(true))
	queue_redraw()


func _draw() -> void:
	if not _rect.has_area():
		return
	match _room_id:
		"e20":
			var visited := int(_markers.get("work_visited", 0))
			var claimed := bool(_markers.get("work_claimed", false))
			_lamps(Vector2(0.308, 0.640), 0.192, int(_markers.get("work_required", 3)), visited, TEAL if claimed else GOLD)
			if _state_id != &"ready":
				_lamp(_point(Vector2(0.50, 0.82)), TEAL if claimed else GOLD)
		"e21":
			_draw_scan(int(_markers.get("recon_size", 0)))
		"e22":
			_draw_hand(_point(Vector2(0.29, 0.70)), StringName(_markers.get("player_hand", &"")))
			_draw_hand(_point(Vector2(0.72, 0.70)), StringName(_markers.get("opponent_hand", &"")))
			_lamps(Vector2(0.451, 0.647), 0.057, 2, int(_markers.get("wins", 0)), TEAL)
			_lamps(Vector2(0.451, 0.780), 0.057, 2, int(_markers.get("losses", 0)), RED)
		"e23":
			_draw_relief()
		"e24":
			var locked := bool(_markers.get("cage_locked", false))
			_lamp(_point(Vector2(0.84, 0.72)), RED if locked else TEAL)
		"e25":
			_draw_stock()
		"e16", "e19":
			_draw_direction()
		"altar":
			_lamps(Vector2(0.16, 0.74), 0.17, int(_markers.get("altar_stage_total", 5)), int(_markers.get("altar_stages_completed", 0)), GOLD)
		"dice":
			if _markers.has("dice_roll"):
				_number(_point(Vector2(0.50, 0.50)), int(_markers["dice_roll"]), GOLD)
		"trap":
			if _markers.has("trap_threshold"):
				var color := GOLD
				if _markers.has("trap_triggered"):
					color = RED if bool(_markers["trap_triggered"]) else TEAL
				_number(_point(Vector2(0.735, 0.38)), int(_markers["trap_threshold"]), color)
		_:
			if _state_id == &"complete":
				_lamp(_point(Vector2(0.79, 0.82)), TEAL)


func _draw_scan(size: int) -> void:
	if size not in [3, 5, 7]:
		return
	var center := _point(Vector2(0.51, 0.57))
	var length := minf(_rect.size.x, _rect.size.y) * 0.225
	var origin := center - Vector2.ONE * length * 0.5
	draw_rect(Rect2(origin, Vector2.ONE * length), Color(0.06, 0.16, 0.16, 0.92))
	for index in range(size + 1):
		var offset := float(index) * length / float(size)
		draw_line(origin + Vector2(offset, 0), origin + Vector2(offset, length), TEAL, 1.0)
		draw_line(origin + Vector2(0, offset), origin + Vector2(length, offset), TEAL, 1.0)


func _draw_hand(center: Vector2, hand: StringName) -> void:
	match hand:
		&"rock":
			draw_colored_polygon(PackedVector2Array([
				center + Vector2(-7, 3), center + Vector2(-6, -4), center + Vector2(0, -7),
				center + Vector2(6, -4), center + Vector2(7, 4), center + Vector2(2, 6),
			]), GOLD)
		&"paper":
			draw_rect(Rect2(center - Vector2(6, 7), Vector2(12, 14)), Color("d8c8a4"))
			draw_line(center + Vector2(-3, -2), center + Vector2(3, -2), DARK, 1.0)
			draw_line(center + Vector2(-3, 2), center + Vector2(3, 2), DARK, 1.0)
		&"scissors":
			draw_line(center + Vector2(-4, 4), center + Vector2(5, -6), GOLD, 2.0)
			draw_line(center + Vector2(4, 4), center + Vector2(-5, -6), GOLD, 2.0)
			draw_arc(center + Vector2(-4, 5), 3.0, 0.0, TAU, 12, GOLD, 1.0)
			draw_arc(center + Vector2(4, 5), 3.0, 0.0, TAU, 12, GOLD, 1.0)


func _draw_relief() -> void:
	var service := StringName(_markers.get("service", &""))
	if service == &"":
		return
	var center := _point(Vector2(0.31, 0.67) if service == &"footbath" else Vector2(0.79, 0.63))
	_number(center, int(_markers.get("pressure_delta", 0)), TEAL)


func _draw_stock() -> void:
	var size := minf(_rect.size.x * 0.225, _rect.size.y * 0.48)
	for index in range(mini(_slot_icons.size(), 3)):
		var center := _point(Vector2(0.165 + 0.335 * index, 0.64))
		var icon := _slot_icons[index]
		if icon != null:
			draw_texture_rect(icon, Rect2(center - Vector2.ONE * size * 0.5, Vector2.ONE * size), false)
		elif bool(_stock[index].get("sold", false)):
			draw_line(center - Vector2(size * 0.34, 0), center + Vector2(size * 0.34, 0), Color("7c5140"), 3.0)


func _draw_direction() -> void:
	if not _markers.has("target_offset"):
		return
	var direction := Vector2(_markers["target_offset"]).normalized()
	var center := _point(Vector2(0.50, 0.68))
	var tangent := direction.orthogonal()
	var color := GOLD
	if _markers.has("detonated"):
		color = TEAL if bool(_markers["detonated"]) else RED
	draw_colored_polygon(PackedVector2Array([
		center + direction * 8.0,
		center - direction * 4.0 + tangent * 5.0,
		center - direction * 4.0 - tangent * 5.0,
	]), color)


func _lamps(first: Vector2, spacing: float, count: int, lit: int, color: Color) -> void:
	for index in range(count):
		_lamp(_point(first + Vector2(spacing * index, 0.0)), color if index < lit else DARK)


func _lamp(center: Vector2, color: Color) -> void:
	draw_rect(Rect2(center - Vector2(4, 3), Vector2(8, 6)), BEZEL)
	draw_rect(Rect2(center - Vector2(3, 2), Vector2(6, 4)), color)


func _number(center: Vector2, value: int, color: Color) -> void:
	var font := ThemeDB.fallback_font
	var copy := str(value)
	var width := font.get_string_size(copy, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	draw_rect(Rect2(center - Vector2(width * 0.5 + 3.0, 8.0), Vector2(width + 6.0, 16.0)), BEZEL)
	draw_string(font, center + Vector2(-width * 0.5, 5.0), copy, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)


func _point(uv: Vector2) -> Vector2:
	return _rect.position + _rect.size * uv
