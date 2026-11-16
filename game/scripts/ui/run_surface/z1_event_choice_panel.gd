extends VBoxContainer

signal option_selected(option: Dictionary)
signal close_requested

const UISkin := preload("res://scripts/presentation/art10_ui_skin_kit.gd")
const Assets := preload("res://scripts/presentation/art09_manifest_asset_mapping.gd")
const ItemArt := preload("res://scripts/presentation/art24/art24_item_visual_catalog.gd")
const SurfaceModel := preload("res://scripts/ui/run_surface/run_surface_model.gd")
const EventRooms := preload("res://scripts/ui/run_surface/z1_event_room_presentation.gd")

const LEGACY_EVENT_ICONS := {
	&"trader": &"ui.art25.long_term.event.trader",
	&"dice": &"ui.art25.long_term.event.dice",
	&"altar": &"ui.art25.long_term.event.altar",
	&"trap": &"ui.art25.long_term.event.trap",
}
const DIRECTION_LABELS := {
	Vector2i(-1, -1): "西北", Vector2i.UP: "北", Vector2i(1, -1): "东北",
	Vector2i.LEFT: "西", Vector2i.RIGHT: "东",
	Vector2i(-1, 1): "西南", Vector2i.DOWN: "南", Vector2i(1, 1): "东南",
}
const RECON_SIZES := {&"recon_3": 3, &"recon_5": 5, &"recon_7": 7}
const GROUP_NAMES := {
	&"materials": "EventMaterialChoices", &"services": "EventServiceChoices",
	&"recon": "EventReconRanges", &"hands": "EventHands", &"stock": "EventShopSlots",
}
const DETAIL_COLOR := Color(0.70, 0.80, 0.76, 1.0)
const SUCCESS_COLOR := Color(0.55, 0.92, 0.72, 1.0)
const FAILURE_COLOR := Color(1.0, 0.59, 0.41, 1.0)
const GOLD_COLOR := Color(0.94, 0.78, 0.35, 1.0)

var _title: Label
var _icon: TextureRect
var _body: Label
var _readout: Label
var _feedback: Label
var _content: VBoxContainer
var _options: VBoxContainer
var _scroll: ScrollContainer
var _close: Button
var _confirmation: VBoxContainer
var _confirm_text: Label
var _confirm_button: Button
var _confirm_origin: Button
var _pending_option: Dictionary = {}
var _event_type: StringName
var _ui_scale_factor := -1.0


func _ready() -> void:
	name = "EventOptionContent"
	add_theme_constant_override("separation", 8)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	add_child(header)
	_icon = TextureRect.new()
	_icon.name = "EventOptionIcon"
	_icon.custom_minimum_size = Vector2(32, 32)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.texture_filter = TEXTURE_FILTER_NEAREST
	_icon.mouse_filter = MOUSE_FILTER_IGNORE
	_icon.hide()
	header.add_child(_icon)
	_title = _add_label(header, "EventOptionTitle")
	_title.size_flags_horizontal = SIZE_EXPAND_FILL

	_scroll = ScrollContainer.new()
	_scroll.name = "EventOptionScroll"
	_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	add_child(_scroll)
	var scrollbar := _scroll.get_v_scroll_bar()
	scrollbar.custom_minimum_size.x = 6.0
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.16, 0.10, 0.055, 0.72)
	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(0.62, 0.43, 0.20, 0.92)
	scrollbar.add_theme_stylebox_override("scroll", track)
	for style in [&"grabber", &"grabber_highlight", &"grabber_pressed"]:
		scrollbar.add_theme_stylebox_override(style, grabber)

	var scroll_content := MarginContainer.new()
	scroll_content.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll_content.add_theme_constant_override("margin_right", 12)
	_scroll.add_child(scroll_content)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	scroll_content.add_child(_content)
	_body = _add_label(_content, "EventOptionSummary")
	_readout = _add_label(_content, "EventRoomReadout")
	_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_options = VBoxContainer.new()
	_options.name = "EventOptionButtons"
	_options.add_theme_constant_override("separation", 6)
	_content.add_child(_options)
	_feedback = _add_label(_content, "EventRoomFeedback")

	_confirmation = VBoxContainer.new()
	_confirmation.add_theme_constant_override("separation", 8)
	_content.add_child(_confirmation)
	_confirm_text = _add_label(_confirmation, "EventConfirmationText")
	_confirm_button = _add_button(_confirmation, "ConfirmEventOption", "", &"danger")
	_confirm_button.pressed.connect(_submit_confirmation)
	_confirmation.hide()

	_close = _add_button(self, "CloseEventOptions", "关闭", &"secondary")
	_close.pressed.connect(_on_close_pressed)
	_confirm_button.focus_next = _confirm_button.get_path_to(_close)
	_confirm_button.focus_previous = _confirm_button.focus_next
	set_ui_scale_factor(UISkin.runtime_ui_scale_factor() if _ui_scale_factor <= 0.0 else _ui_scale_factor)


func set_ui_scale_factor(value: float) -> void:
	_ui_scale_factor = UISkin.normalize_runtime_ui_scale_factor(value)
	if _close == null:
		return
	UISkin.apply_composition_label(_title, &"status", UISkin.scaled_font_size(18, _ui_scale_factor), GOLD_COLOR)
	UISkin.apply_composition_label(_body, &"body", UISkin.scaled_font_size(13, _ui_scale_factor))
	UISkin.apply_composition_label(_readout, &"status", UISkin.scaled_font_size(16, _ui_scale_factor), SUCCESS_COLOR)
	UISkin.apply_composition_label(_feedback, &"body", UISkin.scaled_font_size(12, _ui_scale_factor))
	UISkin.apply_composition_label(_confirm_text, &"body", UISkin.scaled_font_size(13, _ui_scale_factor))
	_scale_button(_close)
	_scale_button(_confirm_button)
	for control in _options.find_children("EventOption_*", "Button", true, false):
		_scale_button(control as Button, bool(control.get_meta("compact", false)))
	for control in _options.find_children("EventOptionDetail_*", "Label", true, false):
		_style_detail(control as Label)
	for control in _options.find_children("EventShopSlotStatus_*", "Label", true, false):
		var status := control as Label
		_style_detail(status, Color(-1, -1, -1, -1))
		status.autowrap_mode = TextServer.AUTOWRAP_OFF


func apply_event(event_state: Dictionary, presentation: Dictionary = {}) -> void:
	_event_type = StringName(event_state.get("event_type", &""))
	var title := String(event_state.get("player_title", "")).strip_edges()
	if title.is_empty():
		title = String(presentation.get("display_title", event_state.get("display_title", ""))).strip_edges()
	var body := String(event_state.get("player_summary", "")).strip_edges()
	if body.is_empty():
		body = String(event_state.get("description", "")).strip_edges()
	if body.is_empty() and not LEGACY_EVENT_ICONS.has(_event_type):
		body = String(presentation.get("summary", "")).strip_edges()
	_title.text = title if not title.is_empty() else SurfaceModel._event_type_label(_event_type)
	_body.text = body if not body.is_empty() else SurfaceModel.event_modal_text(event_state)
	if bool(event_state.get("completed", false)):
		_body.text = ""

	_icon.texture = event_icon_texture(_event_type, presentation)
	_icon.visible = _icon.texture != null
	_reset_confirmation()
	# The modal stack can assign focus before the containers finish sorting.
	_scroll.follow_focus = false
	_scroll.scroll_vertical = 0
	for child in _options.get_children():
		_options.remove_child(child)
		child.queue_free()

	var choices: Array[Dictionary] = []
	for option in event_state.get("options", []):
		if option is Dictionary and not String(option.get("id", "")).is_empty():
			choices.append(option)
	var layout := EventRooms.choice_layout(_event_type)
	_add_choices(choices, layout, event_state, presentation)
	_apply_feedback(event_state, choices, layout, presentation.get("attempt_result", {}))
	_body.visible = not _body.text.is_empty()
	_resume_scroll_focus.call_deferred()


func _apply_feedback(
	event_state: Dictionary, choices: Array[Dictionary], layout: StringName, attempt_result: Dictionary
) -> void:
	var result: Dictionary = attempt_result if not attempt_result.is_empty() else event_state.get("last_result", {})
	var completed := bool(event_state.get("completed", false))
	var copy := public_result_text(_event_type, result)
	_readout.name = "EventRoomScore" if layout == &"hands" else "EventRoomReadout"
	_readout.text = EventRooms.readout_text(_event_type, event_state)
	if layout == &"hands":
		var rounds: Array = event_state.get("rounds", [])
		if not completed and bool(result.get("ok", false)) and not rounds.is_empty():
			var round_copy := EventRooms.round_text(rounds.back())
			if not round_copy.is_empty():
				copy = round_copy
	_readout.visible = not _readout.text.is_empty()

	var has_action := choices.any(func(option: Dictionary) -> bool: return StringName(option.get("id")) != &"leave")
	if copy.is_empty():
		if completed:
			copy = "已经处理。"
		elif not has_action:
			copy = EventRooms.empty_action_text(_event_type)
	_feedback.text = copy
	_feedback.visible = not copy.is_empty()
	var color := DETAIL_COLOR if result.is_empty() else (SUCCESS_COLOR if bool(result.get("ok", false)) else FAILURE_COLOR)
	_feedback.add_theme_color_override("font_color", color)
	var order: Array[Control] = [_body, _readout, _feedback, _options, _confirmation]
	if not completed and layout == &"stock":
		order = [_feedback, _options, _body, _readout, _confirmation]
	elif not completed and layout == &"hands":
		order = [_readout, _options, _feedback, _body, _confirmation]
	for index in range(order.size()):
		_content.move_child(order[index], index)


func _add_choices(choices: Array[Dictionary], layout: StringName, state: Dictionary, presentation: Dictionary) -> void:
	var targets := _relative_targets(choices, presentation.get("room_pos")) if layout == &"targets" else {}
	if layout == &"targets" and not targets.is_empty():
		_add_targets(choices, targets)
		for index in range(choices.size()):
			if StringName(choices[index].get("id")) == &"leave":
				_add_choice(_options, choices[index], index, &"list")
		return

	var group: Container = _options
	if GROUP_NAMES.has(layout):
		group = HBoxContainer.new() if layout in [&"services", &"recon", &"hands"] else VBoxContainer.new()
		group.name = GROUP_NAMES[layout]
		group.add_theme_constant_override("separation", 4)
		_options.add_child(group)
	var stock: Array = state.get("stock", [])
	var items: Array = state.get("item_choices", presentation.get("inventory_items", []))
	for index in range(choices.size()):
		var option := choices[index]
		var id := StringName(option.get("id"))
		if id == &"leave" or (layout == &"stock" and not String(id).begins_with("buy_")):
			_add_choice(_options, option, index, &"list")
		elif layout == &"stock":
			var slot_index := int(String(id).trim_prefix("buy_"))
			var slot: Dictionary = stock[slot_index] if slot_index >= 0 and slot_index < stock.size() else {}
			var sold := bool(slot.get("sold", false))
			var status := "售罄" if sold else _cost_text(option)
			_add_choice(group, option, index, &"stock", ItemArt.texture_for(slot.get("item", {})), "", status, sold)
		elif layout == &"recon" and RECON_SIZES.has(id):
			var side := int(RECON_SIZES[id])
			_add_choice(group, option, index, layout, _range_texture(side), "%d×%d" % [side, side])
		else:
			var texture := _material_texture(option, items) if layout == &"materials" else null
			var short_title := ""
			if id == &"claim_work" and state.has("work_order"):
				short_title = String(option.get("player_title", "")).get_slice("（", 0)
			elif id == &"disarm" and state.has("trap_threshold"):
				short_title = "尝试解除机关"
			_add_choice(group, option, index, layout if layout != &"targets" else &"list", texture, short_title)
	if layout == &"stock" and group.get_child_count() == 0 and not bool(state.get("completed", false)):
		_style_detail(_add_label(group, "EventOptionDetail_EmptyStock", "货槽暂时没有商品。"))


func _relative_targets(choices: Array[Dictionary], room_pos: Variant) -> Dictionary:
	if not room_pos is Vector2i:
		return {}
	var targets := {}
	for index in range(choices.size()):
		var option := choices[index]
		if StringName(option.get("id")) == &"leave":
			continue
		var target: Variant = option.get("payload", {}).get("target_pos")
		if not target is Vector2i:
			return {}
		var relative: Vector2i = target - room_pos
		if not DIRECTION_LABELS.has(relative) or targets.has(relative):
			return {}
		targets[relative] = index
	return targets


func _add_targets(choices: Array[Dictionary], targets: Dictionary) -> void:
	var grid := GridContainer.new()
	grid.name = "EventTargetGrid"
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	_options.add_child(grid)
	var details: Array[String] = []
	for y in range(-1, 2):
		for x in range(-1, 2):
			var relative := Vector2i(x, y)
			if targets.has(relative):
				var index := int(targets[relative])
				_add_choice(grid, choices[index], index, &"targets", null, DIRECTION_LABELS[relative])
				var detail := _option_detail(choices[index], true, true)
				if not detail.is_empty() and not details.has(detail):
					details.append(detail)
			elif relative == Vector2i.ZERO:
				var origin := _add_label(grid, "EventOptionDetail_Origin", "本房")
				origin.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				origin.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				origin.size_flags_horizontal = SIZE_EXPAND_FILL
				_style_detail(origin)
			else:
				var gap := Control.new()
				gap.mouse_filter = MOUSE_FILTER_IGNORE
				gap.size_flags_horizontal = SIZE_EXPAND_FILL
				grid.add_child(gap)
	if not details.is_empty():
		_style_detail(_add_label(_options, "EventOptionDetail_Target", "\n".join(details)))


func _add_choice(
	group: Container, option: Dictionary, index: int, layout: StringName,
	icon: Texture2D = null, short_title: String = "", slot_status: String = "", sold: bool = false
) -> void:
	var row := VBoxContainer.new()
	row.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 2)
	group.add_child(row)
	var button_parent: Container = row
	if layout == &"stock":
		button_parent = HBoxContainer.new()
		button_parent.add_theme_constant_override("separation", 6)
		row.add_child(button_parent)

	var id := StringName(option.get("id"))
	var enabled := bool(option.get("enabled", true))
	var title := String(option.get("player_title", "处理事件")).strip_edges()
	if title.is_empty():
		title = "处理事件"
	var tone: StringName = &"secondary" if not enabled or id == &"leave" else &"primary"
	if id in [&"enter_cage", &"force_open"]:
		tone = &"warning" if enabled else &"secondary"
	var compact := layout != &"list"
	var button := _add_button(button_parent, "EventOption_%d" % index, title if short_title.is_empty() else short_title, tone, compact, not enabled)
	button.tooltip_text = title
	var detail := _option_detail(option, true, true)
	if not detail.is_empty():
		button.tooltip_text += "\n" + detail
	button.size_flags_horizontal = SIZE_EXPAND_FILL
	button.icon = icon
	button.texture_filter = TEXTURE_FILTER_NEAREST
	if layout in [&"stock", &"materials"]:
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if enabled:
		var selected := option.duplicate(true)
		button.pressed.connect(_choose_option.bind(selected, button))

	if layout == &"stock":
		var status := _add_label(button_parent, "EventShopSlotStatus_%d" % index, slot_status)
		status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_style_detail(status, DETAIL_COLOR if sold else GOLD_COLOR)
		status.autowrap_mode = TextServer.AUTOWRAP_OFF
		detail = _option_detail(option, false, not sold)
	elif layout == &"targets":
		return
	if not detail.is_empty():
		var detail_label := _add_label(row, "EventOptionDetail_%d" % index, detail)
		_style_detail(detail_label)
		if layout in [&"recon", &"services"]:
			detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _choose_option(option: Dictionary, source: Button) -> void:
	var id := StringName(option.get("id"))
	var requires_confirmation := bool(option.get("requires_confirmation", false)) and id != &"confirm_high_value_sale"
	if not requires_confirmation and id != &"enter_cage":
		option_selected.emit(option.duplicate(true))
		return
	_pending_option = option.duplicate(true)
	_confirm_origin = source
	var lines: Array[String] = [String(option.get("player_title", ""))]
	if id == &"enter_cage":
		lines.append("入笼后房门和地图回传会锁定，击败怪物后才能继续。")
	else:
		var detail := _option_detail(option, true, false)
		if not detail.is_empty():
			lines.append(detail)
	_confirm_text.text = "\n".join(lines)
	match id:
		&"enter_cage":
			_confirm_button.text = "确认入笼"
		&"compress":
			_confirm_button.text = "确认压缩"
		_:
			_confirm_button.text = "确认操作"
	_confirm_button.disabled = false
	_options.hide()
	_body.hide()
	_feedback.hide()
	_confirmation.show()
	_close.text = "返回选项"
	_close.focus_next = _close.get_path_to(_confirm_button)
	_close.focus_previous = _close.focus_next
	_scroll.scroll_vertical = 0
	_close.grab_focus()


func _submit_confirmation() -> void:
	if _pending_option.is_empty():
		return
	var selected := _pending_option.duplicate(true)
	_pending_option.clear()
	_confirm_button.disabled = true
	option_selected.emit(selected)


func _on_close_pressed() -> void:
	if not _confirmation.visible:
		close_requested.emit()
		return
	var previous := _confirm_origin
	_reset_confirmation()
	_body.visible = not _body.text.is_empty()
	_feedback.visible = not _feedback.text.is_empty()
	if is_instance_valid(previous):
		_scroll.follow_focus = false
		previous.grab_focus()
		_resume_scroll_focus.call_deferred()


func _reset_confirmation() -> void:
	_pending_option.clear()
	_confirm_origin = null
	_confirmation.hide()
	_options.show()
	_close.text = "关闭"
	_close.focus_next = NodePath()
	_close.focus_previous = NodePath()


func _resume_scroll_focus() -> void:
	await get_tree().process_frame
	_scroll.follow_focus = true
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused == null or not is_visible_in_tree() or not _scroll.is_ancestor_of(focused):
		return
	if _event_type == &"z1_event_e25" and not _scroll.get_global_rect().has_point(focused.get_global_rect().get_center()):
		# Keep the shelf visible when only a lower action can receive focus.
		_close.focus_next = _close.get_path_to(focused)
		_close.focus_previous = _close.focus_next
		_close.grab_focus()
		_scroll.scroll_vertical = 0
		return
	_scroll.ensure_control_visible(focused)


func _add_label(parent: Control, node_name: String, copy: String = "") -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = copy
	parent.add_child(label)
	return label


func _add_button(
	parent: Container, node_name: String, title: String, tone: StringName,
	compact: bool = false, disabled: bool = false
) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = title
	button.disabled = disabled
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UISkin.apply_button(button, tone, 13, &"button", &"display")
	button.set_meta("compact", compact)
	for state in [&"normal", &"hover", &"pressed", &"focus", &"disabled"]:
		if compact:
			var focused: bool = state in [&"hover", &"focus"]
			var plate := StyleBoxFlat.new()
			plate.bg_color = Color("172723") if state != &"pressed" else Color("10201d")
			plate.border_color = Color("87c8ae") if focused else Color("80633b")
			if tone == &"warning" and not focused:
				plate.border_color = Color("ba734b")
			if state == &"disabled":
				plate.bg_color = Color("161c1b")
				plate.border_color = Color("53493a")
			plate.set_border_width_all(1)
			plate.set_content_margin(SIDE_LEFT, 7.0)
			plate.set_content_margin(SIDE_RIGHT, 7.0)
			plate.set_content_margin(SIDE_TOP, 4.0)
			plate.set_content_margin(SIDE_BOTTOM, 4.0)
			button.add_theme_stylebox_override(state, plate)
		else:
			var style := button.get_theme_stylebox(state)
			style.set_content_margin(SIDE_LEFT, 40.0)
			style.set_content_margin(SIDE_RIGHT, 40.0)
	_scale_button(button, compact)
	parent.add_child(button)
	return button


func _scale_button(button: Button, compact: bool = false) -> void:
	button.add_theme_font_size_override("font_size", UISkin.scaled_font_size(13, _ui_scale_factor))
	button.custom_minimum_size = UISkin.scaled_control_minimum(Vector2(0.0, 27.0 if compact else 34.0), _ui_scale_factor)
	if compact:
		button.add_theme_constant_override("h_separation", 4)
		button.add_theme_constant_override("icon_max_width", UISkin.scaled_font_size(15, _ui_scale_factor))


func _style_detail(label: Label, color: Color = DETAIL_COLOR) -> void:
	UISkin.apply_composition_label(label, &"body", UISkin.scaled_font_size(11, _ui_scale_factor), color)


static func _cost_text(option: Dictionary) -> String:
	var cost: Dictionary = option.get("player_cost", {})
	return String(cost.get("display_text", "")).strip_edges() if StringName(cost.get("kind", &"none")) != &"none" else ""


static func _option_detail(option: Dictionary, include_cost: bool, include_disabled: bool) -> String:
	var lines: Array[String] = []
	var cost := _cost_text(option)
	if include_cost and not cost.is_empty():
		lines.append(cost)
	var effect := String(option.get("player_effect", "")).strip_edges()
	if not effect.is_empty() and effect != String(option.get("player_title", "")).strip_edges():
		lines.append(effect)
	if include_disabled and not bool(option.get("enabled", true)):
		lines.append(String(option.get("player_disabled_reason", "当前条件不足。")))
	return "\n".join(lines)


static func _material_texture(option: Dictionary, items: Array) -> Texture2D:
	var instance_id := String(option.get("payload", {}).get("instance_id", ""))
	if not instance_id.is_empty():
		for item in items:
			if item is Dictionary and String(item.get("instance_id", "")) == instance_id:
				return ItemArt.texture_for(item)
	return null


static func _range_texture(side: int) -> Texture2D:
	var span := side * 2 + 1
	var pixels := Image.create_empty(span, span, false, Image.FORMAT_RGBA8)
	pixels.fill(Color("37605a"))
	for y in range(side):
		for x in range(side):
			pixels.set_pixel(x * 2 + 1, y * 2 + 1, Color("142824"))
	pixels.set_pixel(side, side, Color("ddb460"))
	return ImageTexture.create_from_image(pixels)


static func public_result_text(event_type: StringName, result: Dictionary) -> String:
	return EventRooms.result_text(event_type, result)


static func event_icon_texture(event_type: StringName, presentation: Dictionary) -> Texture2D:
	return Assets.resolve_texture({
		"asset_id": presentation.get("event_icon_asset_id", &""),
		"fallback_asset_id": LEGACY_EVENT_ICONS.get(event_type, &""),
	})
