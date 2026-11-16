extends Control
class_name Z2EventInteractionModel
## Adapter only: core owns options/state; the delivered dialogue owns text, focus and pending requests.

signal choice_requested(request: Dictionary, option: Dictionary)
signal dismissed

const DialogueScene = preload("res://scenes/components/z2_overlays/z2_event_dialogue.tscn")
var dialogue: Control
var last_action_id := ""
var _state: Dictionary = {}
var _presentation: Dictionary = {}
var _options: Array = []
var _fields: VBoxContainer
var _amount: SpinBox
var _selected_items: Array[String] = []
var _confirmed := false
var _scope := ""
var _fingerprint := ""
var _revision := 0
var _scroll_scope := ""
var _ui_scale_factor := 1.0
var _pending_scroll := -1
var _pending_scroll_revision := 0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dialogue = DialogueScene.instantiate()
	add_child(dialogue)
	dialogue.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	resized.connect(_fit_dialogue)
	_fit_dialogue()
	dialogue.choice_requested.connect(_request)
	dialogue.dismissed.connect(func(_context: Dictionary) -> void: dismissed.emit())
	dialogue.get_node("%ChoicesFrame").visibility_changed.connect(func() -> void: call_deferred("_restore_scroll"))
	hide()

func apply_event(state: Dictionary, presentation: Dictionary = {}) -> bool:
	var previous_scroll: int = dialogue.get_node("%OptionsScroll").scroll_vertical
	var previous_scope := _scroll_scope
	var view := _project(state, presentation)
	show()
	var accepted: bool = dialogue.present_view(view)
	_build_fields()
	_queue_scroll(previous_scroll if previous_scope == _scroll_scope else 0)
	return accepted

func set_ui_scale_factor(value: float) -> void:
	_ui_scale_factor = clampf(value, 1.0, 1.5)
	_fit_dialogue()

func _fit_dialogue() -> void:
	if not is_instance_valid(dialogue):
		return
	dialogue.scale = Vector2.ONE * _ui_scale_factor
	dialogue.size = size / _ui_scale_factor
	dialogue.position = Vector2.ZERO

func _queue_scroll(value: int) -> void:
	_pending_scroll = value
	_pending_scroll_revision = _revision
	call_deferred("_restore_scroll")

func _restore_scroll() -> void:
	if _pending_scroll < 0 or not dialogue.get_node("%ChoicesFrame").is_visible_in_tree():
		return
	var revision := _pending_scroll_revision
	# Native follow_focus runs when choices appear, after the reply is advanced.
	# Restore after that layout so the first enabled option cannot hide the quote's first row.
	await get_tree().process_frame
	if revision == _revision and revision == _pending_scroll_revision and _pending_scroll >= 0:
		(dialogue.get_node("%OptionsScroll") as ScrollContainer).scroll_vertical = _pending_scroll
		_pending_scroll = -1

func _project(state: Dictionary, presentation: Dictionary) -> Dictionary:
	var scope := "%s:%s:%s" % [str(presentation.get("run_id", "")), str(state.get("room_key", "")), str(state.get("event_type", ""))]
	if scope != _scope:
		_selected_items.clear()
		_confirmed = false
	_scope = scope
	_scroll_scope = JSON.stringify([scope, state.get("quote_id", ""), state.get("revision", 0), state.get("phase", "")])
	_state = state.duplicate(true)
	_presentation = presentation.duplicate(true)
	_options = state.get("options", []).duplicate(true)
	# The core quote/revision and options identify progress; viewport/focus never do.
	var fingerprint := JSON.stringify(state).sha256_text()
	if fingerprint != _fingerprint:
		_revision += 1
		_fingerprint = fingerprint
	var options: Array[Dictionary] = []
	for index in _options.size():
		var raw: Dictionary = _options[index]
		options.append({"option_id": str(index), "action_id": _action_id(raw.get("payload", {}), index),
			"label": str(raw.get("player_title", raw.get("label", ""))),
			"cost": str(raw.get("player_cost", {}).get("display_text", "")),
			"effect": str(raw.get("player_effect", "")),
			"enabled": bool(raw.get("enabled", false)),
			"disabled_reason": str(raw.get("player_disabled_reason", raw.get("disabled_reason", raw.get("reason", ""))))})
	return {"room_id": scope, "phase_id": str(state.get("event_type", "")), "revision": _revision,
		"speaker": str(state.get("speaker", state.get("player_title", ""))),
		"lines": _lines(state), "options": options}

func _lines(source: Dictionary) -> Array:
	var result: Array = []
	for raw: Variant in source.get("dialogue", source.get("response_lines", [])):
		if raw is Dictionary and raw.get("text") is String and not str(raw.text).is_empty():
			result.append(raw.duplicate(true))
	var copy := str(source.get("player_summary", source.get("description", "")))
	if result.is_empty() and not copy.is_empty():
		result.append({"text": copy})
	return result

func _action_id(payload: Dictionary, index: int) -> String:
	var identity := payload.duplicate(true)
	identity.erase("expected_conditions")
	identity.erase("expected_revision")
	return "z2_ui:" + JSON.stringify([_scope, _fingerprint, index, identity]).sha256_text()

func _request(request: Dictionary) -> void:
	var index := str(request.get("option_id", "")).to_int()
	if index < 0 or index >= _options.size():
		return
	var option: Dictionary = _options[index].duplicate(true)
	var payload: Dictionary = option.get("payload", {}).duplicate(true)
	option["input_guard_payload"] = payload.duplicate(true)
	var id := str(option.get("id", ""))
	var error := ""
	if id == "prepare" and _amount != null:
		_amount.apply()
		if int(_amount.value) <= 0:
			error = "请输入大于零的金额。"
		else:
			payload["amount"] = int(_amount.value)
	if id == "compress":
		if _selected_items.size() != 2:
			error = "请选择两件不同的物品。"
		else:
			payload["instance_ids"] = _selected_items.duplicate()
	if bool(option.get("requires_confirmation", false)):
		if not _confirmed:
			error = "请先确认所选目标。"
		else:
			payload.merge(option.get("confirmation_payload", {}), true)
	if not error.is_empty():
		dialogue.apply_result({"request": request, "ok": false, "committed": false, "message": error})
		return
	last_action_id = _action_id(payload, index)
	payload["action_id"] = last_action_id
	option["payload"] = payload
	_set_fields_enabled(false)
	choice_requested.emit(request.duplicate(true), option)

func apply_committed_result(request: Dictionary, result: Dictionary, state: Dictionary, presentation: Dictionary) -> bool:
	var previous_scroll: int = dialogue.get_node("%OptionsScroll").scroll_vertical
	var previous_scope := _scroll_scope
	var ok := bool(result.get("ok", false)) and bool(result.get("committed", false))
	var receipt := {"request": request, "ok": ok, "committed": ok}
	if not state.is_empty():
		receipt["view"] = _project(state, presentation)
	if ok:
		receipt["response_lines"] = _lines(result)
		# System result copy is not attributed to an invented NPC.
		if receipt.response_lines.is_empty() and not str(result.get("message", "")).is_empty():
			receipt.response_lines = [{"speaker": "", "text": str(result.message)}]
	else:
		receipt["message"] = "保存未完成，请重试保存后再次选择。" if str(result.get("status", "")) == "save_failed" else str(result.get("message", "操作未完成，请刷新后重试。"))
	var applied: bool = dialogue.apply_result(receipt)
	_set_fields_enabled(true)
	if applied:
		_build_fields()
		_queue_scroll(previous_scroll if previous_scope == _scroll_scope else 0)
	return applied

func _build_fields() -> void:
	var amount_value := _amount.value if is_instance_valid(_amount) else 0.0
	if is_instance_valid(_fields):
		_fields.get_parent().remove_child(_fields)
		_fields.queue_free()
	_amount = null
	_fields = VBoxContainer.new()
	_fields.name = "EventInputs"
	var options_box: VBoxContainer = dialogue.get_node("%Options")
	options_box.add_child(_fields)
	options_box.move_child(_fields, 0)
	var progress := _progress_text()
	if not progress.is_empty():
		var label := Label.new()
		label.name = "EventProgress"
		label.text = progress
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_fields.add_child(label)
	var inputs: Array = _state.get("input_fields", [])
	if inputs.has("amount") and bool(_state.get("requires_prepare", false)):
		var caption := Label.new()
		caption.text = "存入金额"
		_fields.add_child(caption)
		_amount = SpinBox.new()
		_amount.name = "EventAmount"
		_amount.min_value = 0
		_amount.max_value = maxi(0, int(_presentation.get("black_coin", 0)))
		_amount.step = 1
		_amount.value = amount_value
		_fields.add_child(_amount)
		_native_input(_amount.get_line_edit())
	if inputs.has("instance_ids") and not bool(_state.get("completed", false)):
		var caption := Label.new()
		caption.text = "选择两件一档普通收藏品"
		_fields.add_child(caption)
		for item: Dictionary in _presentation.get("inventory_items", []):
			if str(item.get("item_type", "")) != "collectible" or int(item.get("collectible_level", item.get("tier", 0))) != 1 or bool(item.get("is_unique", false)):
				continue
			var id := str(item.get("instance_id", ""))
			var button := CheckBox.new()
			button.name = "Material_" + str(_fields.get_child_count())
			button.text = str(item.get("display_name", item.get("item_id", "")))
			button.set_meta("instance_id", id)
			button.button_pressed = _selected_items.has(id)
			button.toggled.connect(func(pressed: bool) -> void:
				if pressed and not _selected_items.has(id):
					_selected_items.append(id)
				elif not pressed:
					_selected_items.erase(id)
			)
			_fields.add_child(button)
			_native_input(button)
	for option: Dictionary in _options:
		if bool(option.get("requires_confirmation", false)):
			var confirm := CheckBox.new()
			confirm.name = "EventTargetConfirmation"
			confirm.text = "确认所选目标"
			confirm.button_pressed = _confirmed
			confirm.toggled.connect(func(value: bool) -> void: _confirmed = value)
			_fields.add_child(confirm)
			_native_input(confirm)
			break
	dialogue.set_process_input(true)

func _native_input(control: Control) -> void:
	# Let native amount/checkbox widgets consume keys instead of the dialogue shortcut.
	control.focus_entered.connect(func() -> void: dialogue.set_process_input(false))
	control.focus_exited.connect(func() -> void: dialogue.set_process_input(true))

func _set_fields_enabled(enabled: bool) -> void:
	if not is_instance_valid(_fields):
		return
	for child in _fields.get_children():
		if child is BaseButton:
			child.disabled = not enabled
		elif child is SpinBox:
			child.editable = enabled

func _progress_text() -> String:
	var parts: PackedStringArray = []
	if bool(_state.get("completed", false)):
		parts.append("已完成")
	for pair in [["threshold", "当前门槛"], ["wins", "胜局"], ["losses", "负局"], ["tier", "当前档位"], ["global_tier", "累计档位"]]:
		if _state.has(pair[0]):
			parts.append("%s：%s" % [pair[1], str(_state[pair[0]])])
	if _state.get("rounds") is Array:
		parts.append("已完成 %d 局" % _state.rounds.size())
	var work: Dictionary = _state.get("contract", {})
	if work.has("new_rooms"):
		parts.append("已探索新房间：%d" % work.new_rooms.size())
	if not _state.get("pending", {}).is_empty():
		parts.append("等待下一次完整普通房搜索")
	return " · ".join(parts)

func dismiss() -> void:
	dialogue.dismiss()
	hide()
