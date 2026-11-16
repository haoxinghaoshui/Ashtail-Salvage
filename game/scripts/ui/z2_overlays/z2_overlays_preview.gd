extends Control
## Standalone preview. All prices, revisions and receipts below are local fixtures.

const Dialogue := preload("res://scripts/ui/z2_overlays/z2_event_dialogue.gd")
const Notifications := preload("res://scripts/ui/z2_overlays/z2_notification_queue.gd")
const INTEL_ICON := preload("res://assets/ui/art25/content/long_term/task/task_sample_research.png")
const SURVEY_ICON := preload("res://assets/ui/art25/content/long_term/task/task_first_survey.png")
const ROOM_ID := "preview:z1_event_e21"

@onready var _dialogue: Dialogue = $EventDialogue
@onready var _notifications: Notifications = $NotificationQueue
@onready var _talk: Button = %TalkButton
@onready var _toolbar: VBoxContainer = %PreviewControls

var _view: Dictionary = {}
var _playback := 0


func _ready() -> void:
	_view = _initial_view(1)
	_talk.pressed.connect(_talk_to_npc)
	%ReplayNotifications.pressed.connect(_play_notifications)
	%ResetFixture.pressed.connect(_reset_fixture)
	_dialogue.choice_requested.connect(_reply_to_choice)
	resized.connect(_place_controls)
	_place_controls()
	_talk.grab_focus()
	_play_notifications()


func _place_controls() -> void:
	_toolbar.position = Vector2(28, 24) if size.x >= 760.0 else Vector2(22, 122)


func _talk_to_npc() -> void:
	if not _dialogue.visible:
		_dialogue.present_view(_view)


func _reset_fixture() -> void:
	_dialogue.dismiss()
	_view = _initial_view(_view.revision + 1)
	_talk.text = "与线报员交谈"
	_talk.grab_focus()


func _reply_to_choice(request: Dictionary) -> void:
	await get_tree().create_timer(0.28).timeout
	if _view.revision != request.revision:
		return
	var result := {"request": request}
	var next_revision: int = request.revision + 1
	if request.option_id == "old_quote":
		_view = _initial_view(next_revision)
		_view.lines = []
		_view.options[0]["cost"] = "9 黑币"
		_view.options[1] = {"option_id": "old_quote", "label": "核对旧线报", "enabled": false, "disabled_reason": "原报价已作废。"}
		result.merge({
			"ok": false, "committed": false,
			"message": "旧线报已经作废。新的标记报价是 9 黑币，可以重新选择。",
		})
	else:
		_view = {
			"room_id": ROOM_ID, "phase_id": "revisit", "revision": next_revision,
			"lines": [{"speaker": "线报员", "text": "我这真没东西了，你去问问别人吧，别逮着我一个人薅了！刚才标好的雷位还留在图上。"}],
			"options": [],
		}
		_talk.text = "回访线报员"
		result.merge({
			"ok": true, "committed": true,
			"response_lines": [
				{"speaker": "线报员", "text": "感谢老板，老板大气！"},
				{"speaker": "情报", "text": "以本房为中心，5×5 范围内共有 6 处雷，已在地图标记。"},
			],
		})
	result["view"] = _view
	_dialogue.apply_result(result)


func _initial_view(revision: int) -> Dictionary:
	return {
		"room_id": ROOM_ID, "phase_id": "offer", "revision": revision, "speaker": "线报员",
		"lines": [
			{"speaker": "玩家", "text": "你是卖啥的？"},
			{"speaker": "线报员", "text": "问那么难听干嘛，这叫提供情报！近处的图刚核过，外圈还有一份旧线报。你选一张，我把上面的雷位跟你说清楚。"},
		],
		"options": [
			{
				"option_id": "recon_5", "action_id": "preview:survey:%d" % revision,
				"label": "标出附近雷位", "cost": "6 黑币",
				"effect": "标记以本房为中心 5×5 范围内的雷位。地图会保留这些标记，方便回访时核对路线。",
				"enabled": true,
			},
			{
				"option_id": "old_quote", "action_id": "preview:quote:%d" % revision,
				"label": "核对旧线报", "cost": "12 黑币", "effect": "核对外围图纸上的旧雷位标记。",
				"enabled": true,
			},
			{
				"option_id": "exit_location", "label": "打听撤离点",
				"disabled_reason": "外圈哨点还没回报，线报员手上没有可以确认的撤离路线。",
				"enabled": false,
			},
		],
	}


func _play_notifications() -> void:
	_playback += 1
	var receipt := {"ok": true, "committed": true, "receipt_id": "preview:goals:%d" % _playback}
	_notifications.enqueue_committed(receipt, {
		"goal_id": "event_visits", "tier": 1, "icon": INTEL_ICON,
		"title": "事儿真多", "body": "累计进入事件房 50 次",
	})
	_notifications.enqueue_committed(receipt, {
		"goal_id": "first_survey", "tier": 0, "icon": SURVEY_ICON,
		"title": "熟悉现场", "body": "事件房、战斗房、宝箱房各进入 3 次",
	})
