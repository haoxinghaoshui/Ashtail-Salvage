extends SceneTree

const PREVIEW := "res://scenes/components/z2_overlays/z2_overlays_preview.tscn"

var _failures: Array[String] = []
var _checks := 0
var _captures := 0
var _capture_dir := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(12.0).timeout.connect(func() -> void:
		print("Z2_OVERLAY_PREVIEW=TIMEOUT checks=", _checks)
		quit(1)
	)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 720)
	var scene := load(PREVIEW) as PackedScene if FileAccess.file_exists(PREVIEW) else null
	_expect(scene != null, "standalone preview scene is available")
	if scene != null:
		var preview := scene.instantiate()
		root.add_child(preview)
		await _exercise_preview(preview)
		preview.free()
	for failure in _failures:
		print("Z2_OVERLAY_PREVIEW_FAIL ", failure)
	print("Z2_OVERLAY_PREVIEW=%s checks=%d failures=%d captures=%d" % [
		"PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size(), _captures,
	])
	quit(0 if _failures.is_empty() else 1)


func _exercise_preview(preview: Node) -> void:
	var talk := _node(preview, "TalkButton")
	var dialogue := _node(preview, "EventDialogue")
	var notifications := _node(preview, "NotificationQueue")
	var body := _node(dialogue, "DialogueText") as RichTextLabel
	var feedback := _node(dialogue, "DialogueStatus") as RichTextLabel
	var speaker := _node(dialogue, "SpeakerName") as Label
	var toast := _node(notifications, "NotificationCard")
	var requests: Array[Dictionary] = []
	var notices: Array[String] = []
	dialogue.connect("choice_requested", func(request: Dictionary) -> void: requests.append(request))
	notifications.connect("notification_shown", func(notice: Dictionary) -> void: notices.append(notice.title))
	await _settle()
	_expect(not dialogue.visible and not paused, "preview starts in the room with gameplay processing available")
	await _click(talk)
	_expect(body.text == "你是卖啥的？", "opens from the room's Talk button")
	if body.visible_characters >= 0:
		await _click(body)
	_expect(body.visible_characters == -1, "opening line is fully revealed before advancing")
	_key(KEY_SPACE)
	_key(KEY_SPACE)
	_key(KEY_SPACE)
	await _settle()
	var choice := _node(dialogue, "Option_0") as Button
	_expect(choice != null and choice.has_focus(), "click and Space reach the actual choice controls")
	if choice == null:
		return
	_expect(await _wait_for(func() -> bool: return not notices.is_empty()), "a fixture toast slides into view")
	_expect(notices == ["事儿真多"], "achievement appears first while the dialogue is interactive")
	_expect(speaker.text == "线报员" and _nameplate_fits(speaker), "desktop frame has a readable NPC nameplate")
	_expect(toast.size.y <= 96.0, "desktop renders a compact notification card")
	print("Z2_OVERLAY_PREVIEW_LAYOUT desktop_toast_px=", toast.size.y, " desktop_nameplate_px=", speaker.size.x)
	await _capture("final-preview-1280x720.png", Vector2i(1280, 720))

	_key(KEY_DOWN)
	_key(KEY_ENTER)
	_expect(requests.size() == 1 and requests[0].option_id == "old_quote", "keyboard requests the selected fixture choice")
	var failed := await _wait_for(func() -> bool: return feedback.text.contains("旧线报"))
	_expect(failed, "real fixture failure is shown")
	if not failed:
		return
	_expect((_node(dialogue, "Option_1") as Button).disabled, "stale quoted option is disabled by the refreshed view")
	root.size = Vector2i(704, 540)
	await _settle()
	var bounds := Rect2(Vector2.ZERO, Vector2(root.size))
	var panel := _node(dialogue, "DialogueFrame").get_global_rect()
	var choices := _node(dialogue, "ChoicesFrame").get_global_rect()
	var options := _node(dialogue, "OptionsScroll") as ScrollContainer
	_expect(speaker.text == "线报员" and _nameplate_fits(speaker), "narrow failure keeps a readable nameplate")
	_expect(bounds.encloses(panel) and bounds.encloses(choices) and not panel.intersects(choices), "704×540 panels stay within the viewport and stack without overlap")
	_expect(options.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO and not options.get_h_scroll_bar().visible, "narrow choices retain vertical scrolling without horizontal overflow")
	var reason := _node(_node(dialogue, "Option_2"), "OptionReason")
	_expect(options.get_global_rect().encloses(reason.get_global_rect()), "standard narrow fixture shows the complete last disabled reason")
	_expect(not toast.get_global_rect().intersects(choices), "compact active toast clears the narrow choice panel")
	print("Z2_OVERLAY_PREVIEW_LAYOUT narrow_choices=", choices, " narrow_nameplate_px=", speaker.size.x)
	await _capture("final-preview-704x540.png", Vector2i(704, 540))

	await _click(_node(dialogue, "Option_0"))
	_expect(requests.size() == 2 and requests[1].revision > requests[0].revision, "mouse submits the refreshed choice")
	_expect(await _wait_for(func() -> bool: return body.text == "感谢老板，老板大气！"), "matched committed reply plays the NPC line")
	_key(KEY_ESCAPE)
	await _settle()
	_expect(not dialogue.visible and not paused and (talk as Button).has_focus(), "Escape closes and restores the room button's keyboard focus")
	await _click(talk)
	_expect(body.text.begins_with("我这真没东西了") and not _node(dialogue, "ChoicesFrame").visible, "revisit uses the supplied committed fixture state")
	_expect(await _wait_for(func() -> bool: return notices.size() >= 2, 4.5), "second queued notice appears during normal room interaction")
	_expect(notices.slice(0, 2) == ["事儿真多", "熟悉现场"], "preview's two notices play in enqueue order")


func _capture(file_name: String, expected_size: Vector2i) -> void:
	if _capture_dir.is_empty():
		return
	_expect(DisplayServer.get_name() != "headless", "captures use a rendering display")
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	_expect(image.get_size() == expected_size, "capture has the requested canvas size")
	var output := _capture_dir.path_join(file_name)
	var saved := image.save_png(output) == OK
	_expect(saved, "PNG saved to requested scratch output")
	if saved:
		_captures += 1
		print("Z2_OVERLAY_CAPTURE ", output, " ", image.get_size())


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(description)


func _node(parent: Node, key: String) -> Control:
	return parent.find_child(key, true, false) as Control


func _nameplate_fits(speaker: Label) -> bool:
	var font := speaker.get_theme_font(&"font")
	var width := font.get_string_size(speaker.text, HORIZONTAL_ALIGNMENT_LEFT, -1, speaker.get_theme_font_size(&"font_size")).x
	return speaker.is_visible_in_tree() and speaker.size.x + 1.0 >= width


func _key(code: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = down
		root.push_input(event, true)


func _click(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)
	await _settle()


func _settle() -> void:
	await process_frame
	await process_frame


func _wait_for(condition: Callable, seconds: float = 1.5) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return condition.call()
