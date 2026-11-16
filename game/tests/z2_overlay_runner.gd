extends SceneTree

const DIALOGUE := "res://scenes/components/z2_overlays/z2_event_dialogue.tscn"
const NOTIFICATIONS := "res://scenes/components/z2_overlays/z2_notification_queue.tscn"


class GameplayProbe extends Node:
	var ticks := 0
	var overlay_key_presses := 0

	func _process(_delta: float) -> void:
		ticks += 1

	func _unhandled_key_input(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed and event.keycode in [KEY_SPACE, KEY_ESCAPE]:
			overlay_key_presses += 1

var _failures: Array[String] = []
var _checks := 0
var _first_dwell_ms := 0
var _underlay_presses := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(28.0).timeout.connect(func() -> void:
		print("Z2_OVERLAYS=TIMEOUT checks=", _checks)
		quit(1)
	)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 720)
	var dialogue := _mount(DIALOGUE)
	if dialogue != null:
		var probe := GameplayProbe.new()
		root.add_child(probe)
		await _test_dialogue(dialogue, probe)
		await _test_pending_dismissal(dialogue)
		await _test_narrow_dialogue(dialogue)
		_expect(probe.overlay_key_presses == 0, "dialogue input does not reach gameplay's unhandled Space or Escape")
		probe.free()
		dialogue.free()
	var underlay := Button.new()
	underlay.position = Vector2(420, 12)
	underlay.size = Vector2(440, 96)
	underlay.pressed.connect(func() -> void: _underlay_presses += 1)
	root.add_child(underlay)
	var notifications := _mount(NOTIFICATIONS)
	if notifications != null:
		await _test_notifications(notifications)
		notifications.free()
	underlay.free()
	for failure in _failures:
		print("Z2_OVERLAY_FAIL ", failure)
	print("Z2_OVERLAYS=%s checks=%d failures=%d first_dwell_ms=%d" % [
		"PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size(), _first_dwell_ms,
	])
	quit(0 if _failures.is_empty() else 1)


func _test_dialogue(dialogue: Control, probe: GameplayProbe) -> void:
	var requests: Array[Dictionary] = []
	dialogue.connect("choice_requested", func(request: Dictionary) -> void: requests.append(request))
	var view := _view()
	var original := view.duplicate(true)
	_expect(bool(dialogue.call("present_view", view)), "opens a caller view")
	await _settle()
	var body := _node(dialogue, "DialogueText") as RichTextLabel
	var speaker := _node(dialogue, "SpeakerName") as Label
	_expect(speaker.text == "线报员" and body.text == view.lines[0].text, "shows opening speaker and line")
	_expect(_nameplate_fits(speaker), "nameplate allocates enough width to show the speaker's name")
	await create_timer(0.08).timeout
	_expect(body.visible_characters > 0 and body.visible_characters < body.text.length(), "reveals opening line gradually")
	await _click(body)
	_expect(body.visible_characters == -1 and body.text == view.lines[0].text, "click completes current line")
	await _click(body)
	_expect(speaker.text == "玩家" and body.text == view.lines[1].text and body.visible_characters >= 0, "next click advances to the next speaker")
	_key(KEY_SPACE)
	_expect(body.visible_characters == -1 and not _node(dialogue, "ChoicesFrame").visible, "Space completes the active line before choices")
	_key(KEY_SPACE)
	await _settle()

	var first := _node(dialogue, "Option_0") as Button
	var disabled := _node(dialogue, "Option_1") as Button
	var last := _node(dialogue, "Option_2") as Button
	_expect(first.has_focus() and disabled.disabled, "first enabled option receives focus")
	_expect(_label(first, "OptionCost") == "6 黑币" and _label(first, "OptionEffect") == "标出附近 6 处雷房", "renders caller cost and effect")
	_expect(_label(disabled, "OptionReason") == "线报还没送到。", "renders caller disabled reason")
	_key(KEY_DOWN)
	_expect(last.has_focus(), "Down skips ineligible options")
	_key(KEY_UP)
	_expect(first.has_focus(), "Up returns to the previous enabled option")
	_move(last.get_global_rect().get_center())
	await _settle()
	_expect(last.has_focus(), "mouse hover focuses an enabled option")
	await _click(disabled)
	_expect(requests.is_empty() and last.has_focus(), "disabled option neither dispatches nor steals focus")

	_key(KEY_ENTER)
	_key(KEY_SPACE)
	var gameplay_ticks := probe.ticks
	await _click(first)
	_expect(requests.size() == 1 and first.disabled and last.disabled, "pending locks both input methods")
	_expect(probe.ticks > gameplay_ticks and not paused, "an ordinary gameplay process still ticks while the choice is pending")
	if requests.is_empty():
		return
	var request := requests[0]
	_expect(request == {
		"room_id": "room-21", "phase_id": "offer", "option_id": "old_quote",
		"revision": 7, "action_id": "room-21:quote", "attempt_id": 1,
	}, "request echoes stable caller scope, option and action")
	var result := _success(request)
	for field in request:
		var mismatch := result.duplicate(true)
		mismatch.request[field] = -1 if request[field] is int else "other"
		_expect(not bool(dialogue.call("apply_result", mismatch)), "rejects mismatched " + field)
	var invalid_view := result.duplicate(true)
	invalid_view["view"] = _view("other-room", 8)
	_expect(not bool(dialogue.call("apply_result", invalid_view)), "rejects a reply carrying another room's snapshot")
	invalid_view["view"] = _view("room-21", 6)
	_expect(not bool(dialogue.call("apply_result", invalid_view)), "rejects a reply carrying a backwards revision")
	var uncommitted := result.duplicate(true)
	uncommitted["committed"] = false
	_expect(not bool(dialogue.call("apply_result", uncommitted)) and body.text == view.lines[1].text and last.disabled, "uncommitted response leaves the current choice pending")

	var failure := result.duplicate(true)
	failure.merge({"ok": false, "committed": false, "message": "情报同步失败，请稍后重试。"}, true)
	_expect(bool(dialogue.call("apply_result", failure)), "accepts a matched failure")
	var feedback := _node(dialogue, "DialogueStatus") as RichTextLabel
	_expect(feedback.text == failure.message and body.text == view.lines[1].text and not last.disabled, "failure text replaces pending feedback without playing NPC response")
	await _click(last)
	_expect(requests.size() == 2 and requests[1].action_id == request.action_id and requests[1].attempt_id != request.attempt_id, "mouse retry keeps caller action identity with a new attempt")
	if requests.size() < 2:
		return
	_expect(not bool(dialogue.call("apply_result", result)) and last.disabled, "ignores delayed success from the previous attempt")

	var refresh := _view("room-21", 8)
	refresh.lines = []
	refresh.options[0]["cost"] = "9 黑币"
	refresh.options[0]["action_id"] = "room-21:revision-8:survey"
	refresh.options[2].merge({"enabled": false, "disabled_reason": "旧报价已撤回。"}, true)
	failure.merge({"request": requests[1], "view": refresh, "message": "报价刚刚更新。"}, true)
	_expect(bool(dialogue.call("apply_result", failure)), "applies failure with a newer authoritative view")
	await _settle()
	first = _node(dialogue, "Option_0") as Button
	_expect(_label(first, "OptionCost") == "9 黑币" and _label(_node(dialogue, "Option_2"), "OptionReason") == "旧报价已撤回。" and feedback.text == failure.message, "refreshes prices, availability and failure copy together")
	_expect(speaker.text == "线报员" and _nameplate_fits(speaker), "failure refresh keeps the supplied nameplate without new dialogue lines")
	_key(KEY_ENTER)
	_expect(requests.size() == 3 and requests[2].revision == 8 and requests[2].action_id == "room-21:revision-8:survey", "next choice uses refreshed revision and action identity")
	if requests.size() < 3:
		return

	var revisit := _view("room-21", 9)
	revisit.phase_id = "visited"
	revisit.lines = [{"speaker": "线报员", "text": "标记还在，照着图走。"}]
	revisit.options = []
	result = _success(requests[2])
	result["view"] = revisit
	_expect(bool(dialogue.call("apply_result", result)), "accepts the matched committed result")
	_expect(body.text == result.response_lines[0].text and not feedback.visible, "plays committed NPC line with failure feedback cleared")
	_expect(not bool(dialogue.call("apply_result", result)), "rejects a replayed result")
	_expect(not bool(dialogue.call("present_view", refresh)), "rejects a superseded in-place view")
	_key(KEY_ESCAPE)
	_expect(not dialogue.visible and not paused, "Escape dismisses without pausing")
	_expect(bool(dialogue.call("present_view", revisit)), "reopens supplied authoritative state")
	_expect(body.text == revisit.lines[0].text and not _node(dialogue, "ChoicesFrame").visible and not feedback.visible, "revisit renders supplied copy without old choices or feedback")
	_expect(view == original, "presentation leaves caller dictionaries untouched")
	dialogue.call("dismiss")


func _test_pending_dismissal(dialogue: Control) -> void:
	var requests: Array[Dictionary] = []
	var dismissals: Array[Dictionary] = []
	dialogue.connect("choice_requested", func(request: Dictionary) -> void: requests.append(request))
	dialogue.connect("dismissed", func(context: Dictionary) -> void: dismissals.append(context))
	var view := _view("room-pending")
	view.lines = []
	dialogue.call("present_view", view)
	_key(KEY_ENTER)
	_key(KEY_ESCAPE)
	_expect(not dialogue.visible and requests.size() == 1 and dismissals.size() == 1, "Escape closes while a request is in flight")
	if requests.is_empty() or dismissals.is_empty():
		return
	_expect(dismissals[0].get("pending_request") == requests[0], "dismissal identifies the outstanding request")
	dialogue.call("present_view", view)
	_key(KEY_ENTER)
	_expect(requests.size() == 1, "same-revision revisit keeps the in-flight lock")
	_key(KEY_ESCAPE)
	_expect(not bool(dialogue.call("apply_result", _success(requests[0]))) and not dialogue.visible, "an offscreen result never reopens the panel")

	dialogue.call("present_view", view)
	_key(KEY_ENTER)
	var new_room := _view("room-other")
	new_room.lines = []
	dialogue.call("present_view", new_room)
	_key(KEY_ENTER)
	_expect(requests.size() == 3 and requests[2].room_id == "room-other", "another room can submit its own request")
	if requests.size() < 3:
		return
	_expect(not bool(dialogue.call("apply_result", _success(requests[1]))) and (_node(dialogue, "Option_0") as Button).disabled, "late result does not unlock or replace the current room")
	new_room.revision += 1
	dialogue.call("present_view", new_room)
	_expect(not bool(dialogue.call("apply_result", _success(requests[2]))) and not (_node(dialogue, "Option_0") as Button).disabled, "authority refresh invalidates a superseded pending request")
	_key(KEY_ENTER)
	_expect(requests.size() == 4, "new revision can make a new request")
	if requests.size() >= 4:
		dialogue.call("apply_result", _success(requests[3]))
		_key(KEY_SPACE)
		_key(KEY_SPACE)
		_expect(not _node(dialogue, "ChoicesFrame").visible and requests.size() == 4, "success without a snapshot retires the old options")
	dialogue.call("dismiss")


func _test_narrow_dialogue(dialogue: Control) -> void:
	root.size = Vector2i(704, 540)
	await _settle()
	var view := _view("room-long")
	view.lines[0].speaker = "黄铜管道巡检组旧仓库值守员".repeat(12)
	view.lines[0].text = "仓库下层的排水井里还有一份军械清单，沿着铜色管道走，再绕开左手第二处断裂的台阶。".repeat(9)
	view.lines.resize(1)
	view.options[0]["effect"] = view.lines[0].text
	dialogue.call("present_view", view)
	_key(KEY_SPACE)
	await _settle()
	var text_box := _node(dialogue, "DialogueText") as RichTextLabel
	_expect(text_box.get_v_scroll_bar().visible and text_box.get_content_height() > text_box.size.y, "long Chinese dialogue wraps into a scrollable text area")
	_key(KEY_SPACE)
	await _settle()
	var viewport := Rect2(Vector2.ZERO, Vector2(root.size))
	var panel := _node(dialogue, "DialogueFrame")
	var choices := _node(dialogue, "ChoicesFrame")
	var scroll := _node(dialogue, "OptionsScroll") as ScrollContainer
	var button := _node(dialogue, "Option_0")
	var effect := _node(button, "OptionEffect") as Label
	_expect(viewport.encloses(panel.get_global_rect()) and viewport.encloses(choices.get_global_rect()) and not choices.get_global_rect().intersects(panel.get_global_rect()), "narrow panels fit vertically without overlap")
	_expect(button.get_global_rect().encloses(effect.get_global_rect()) and effect.get_line_count() > 3, "long option copy wraps inside its button")
	_expect(scroll.get_v_scroll_bar().visible and not scroll.get_h_scroll_bar().visible, "long options scroll vertically only")
	_key(KEY_DOWN)
	await _settle()
	_expect((_node(dialogue, "Option_2") as Button).has_focus() and scroll.scroll_vertical > 0, "keyboard focus scrolls to the next enabled option")
	dialogue.call("dismiss")
	root.size = Vector2i(1280, 720)
	await _settle()


func _test_notifications(queue: Control) -> void:
	var shown: Array[String] = []
	var finished: Array[String] = []
	var started_at: Array[int] = []
	var ended_at: Array[int] = []
	queue.connect("notification_shown", func(notice: Dictionary) -> void:
		shown.append(notice.title)
		started_at.append(Time.get_ticks_msec())
	)
	queue.connect("notification_finished", func(notice: Dictionary) -> void:
		finished.append(notice.title)
		ended_at.append(Time.get_ticks_msec())
	)
	var receipt := {"ok": true, "committed": true, "receipt_id": "fixture-50"}
	var failed := {"ok": false, "committed": true, "receipt_id": "fixture-50"}
	var uncommitted := {"ok": true, "committed": false, "receipt_id": "fixture-50"}
	var first := {"goal_id": "event_visits", "tier": 1, "title": "事儿真多", "body": "累计进入事件房 50 次"}
	var next := {"goal_id": "event_visits", "tier": 2, "title": "事儿还多", "body": "累计进入事件房 100 次"}
	var long_title := "熟悉现场后请核对仓库和东侧通风井的巡查图"
	var other := {"goal_id": "first_survey", "tier": 1, "title": long_title, "body": "三类房间各进入 3 次"}
	_expect(not bool(queue.call("enqueue_committed", failed, first)) and not bool(queue.call("enqueue_committed", uncommitted, first)), "failed and uncommitted receipts never enqueue")
	_expect(not bool(queue.call("enqueue_committed", {"ok": true, "committed": true}, first)), "receipt identity is required")
	_expect(not bool(queue.call("enqueue_committed", receipt, {"goal_id": "", "title": "无效"})), "goal and tier identity are required")
	_expect(bool(queue.call("enqueue_committed", receipt, first)), "accepts the first committed goal")
	_expect(not bool(queue.call("enqueue_committed", receipt, first)), "dedupes an active notification")
	_expect(bool(queue.call("enqueue_committed", receipt, next)), "same receipt and goal can notify a different tier")
	_expect(not bool(queue.call("enqueue_committed", receipt, next)), "dedupes an already queued tier")
	_expect(bool(queue.call("enqueue_committed", receipt, other)), "same receipt can notify another goal")
	var last_receipt := {"ok": true, "committed": true, "receipt_id": "fixture-51"}
	var last := first.duplicate()
	last.title = "另一笔结算"
	_expect(bool(queue.call("enqueue_committed", last_receipt, last)), "distinct committed receipts with the same goal and tier remain distinct")
	first.title = "外部修改"
	await _settle()
	var card := _node(queue, "NotificationCard")
	_expect(card.position.y < 14.0, "notification slides from above the viewport")
	await _until(func() -> bool: return not shown.is_empty(), 1.5)
	_expect(shown == ["事儿真多"], "first visible notification comes from the original accepted payload")
	_expect(absf(card.get_global_rect().get_center().x - root.size.x / 2.0) < 1.5 and _label(card, "NotificationBody") == first.body, "notification is centered with caller body")
	_expect((_node(card, "NotificationIcon") as TextureRect).texture != null, "visible toast has an icon")
	_expect(card.size.y >= 64.0 and card.size.y <= 96.0, "regular desktop notification uses a compact height")
	await _click(card)
	_expect(_underlay_presses == 1 and not paused, "mouse clicks pass through the toast and the tree stays active")
	await create_timer(2.95).timeout
	_expect(finished.is_empty() and is_equal_approx(card.position.y, 14.0), "card holds fully on screen for at least 2.95 seconds")
	root.size = Vector2i(410, 540)
	await _until(func() -> bool: return shown.size() >= 3, 9.0)
	var title := _node(card, "NotificationTitle") as Label
	_expect(title.text == long_title and title.get_line_count() >= 2 and title.size.y >= 38.0, "long Chinese notification title stays wrapped")
	_expect(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(card.get_global_rect()) and card.get_global_rect().encloses(title.get_global_rect()), "wrapped toast and title stay inside their bounds")
	print("Z2_OVERLAY_LONG_TITLE lines=", title.get_line_count(), " card_px=", card.size)
	await _until(func() -> bool: return finished.size() == 4, 9.0)
	var sequence := ["事儿真多", "事儿还多", long_title, "另一笔结算"]
	_expect(shown == sequence and finished == sequence, "queue shows and finishes each unique notification in FIFO order")
	if not ended_at.is_empty() and not started_at.is_empty():
		_first_dwell_ms = ended_at[0] - started_at[0]
		_expect(_first_dwell_ms >= 3450 and _first_dwell_ms <= 3900, "3.4-second hold and slide-out elapsed in real time")
	_expect(not card.visible and not bool(queue.call("enqueue_committed", receipt, {"goal_id": "event_visits", "tier": 1, "title": "重播"})), "queue hides and remembers completed notifications")


func _view(room_id: String = "room-21", revision: int = 7) -> Dictionary:
	return {
		"room_id": room_id, "phase_id": "offer", "revision": revision, "speaker": "线报员",
		"lines": [
			{"speaker": "线报员", "text": "新画好的那张图在这儿，出了这道门记得贴着墙走。"},
			{"speaker": "玩家", "text": "告诉我这里有多少雷。"},
		],
		"options": [
			{"option_id": "recon_5", "action_id": room_id + ":survey", "label": "买近处情报", "cost": "6 黑币", "effect": "标出附近 6 处雷房", "enabled": true},
			{"option_id": "exit_location", "label": "打听撤离点", "disabled_reason": "线报还没送到。", "enabled": false},
			{"option_id": "old_quote", "action_id": room_id + ":quote", "label": "核对旧线报", "cost": "12 黑币", "effect": "核对远处雷房", "enabled": true},
		],
	}


func _success(request: Dictionary) -> Dictionary:
	return {
		"request": request, "ok": true, "committed": true,
		"response_lines": [{"speaker": "线报员", "text": "标好了，有白粉的那道门别碰。"}],
	}


func _mount(path: String) -> Control:
	var packed := load(path) as PackedScene if FileAccess.file_exists(path) else null
	_expect(packed != null, "required scene is available: " + path)
	if packed == null:
		return null
	var control := packed.instantiate() as Control
	root.add_child(control)
	return control


func _node(parent: Node, key: String) -> Control:
	return parent.find_child(key, true, false) as Control


func _label(parent: Node, key: String) -> String:
	return (_node(parent, key) as Label).text


func _nameplate_fits(speaker: Label) -> bool:
	var font := speaker.get_theme_font(&"font")
	var width := font.get_string_size(speaker.text, HORIZONTAL_ALIGNMENT_LEFT, -1, speaker.get_theme_font_size(&"font_size")).x
	return speaker.is_visible_in_tree() and speaker.size.x + 1.0 >= width


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(description)


func _key(code: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = down
		root.push_input(event, true)


func _move(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	root.push_input(event, true)


func _click(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	_move(point)
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


func _until(condition: Callable, seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame
