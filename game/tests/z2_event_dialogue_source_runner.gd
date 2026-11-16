extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Events = preload("res://scripts/core/run/z2_event_runtime.gd")
const Dialogue = preload("res://scripts/core/run/z2_event_dialogue_catalog.gd")
const Service = preload("res://scripts/core/run/event_service.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const Adapter = preload("res://scripts/ui/event/event_interaction_model.gd")
const SOURCE_SHA := "515F69FF5463A87AA427B669C5D987CF959B652A726294864E4FEC1E808035A2"
var checks := 0
var failures: Array[String] = []
var sequence := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var home := OS.get_environment("Z2_EVENT_DIALOGUE_QA_HOME").simplify_path().replace("\\", "/").trim_suffix("/")
	if not home.is_absolute_path() or not OS.get_user_data_dir().simplify_path().replace("\\", "/").to_lower().begins_with(home.to_lower() + "/"):
		printerr("Z2_EVENT_DIALOGUE_SOURCE=FAIL absolute isolated user data root required")
		quit(1)
		return
	_test_all_openings()
	_test_source_branches()
	await _test_real_dialogue_receipts()
	_test_revisit_and_preparation()
	_test_settled_loss()
	for failure in failures:
		print("Z2_EVENT_DIALOGUE_SOURCE_FAIL " + failure)
	print("Z2_EVENT_DIALOGUE_SOURCE=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _runtime() -> RunRuntimeController:
	var meta := Meta.new()
	meta.set_active_profile_path("user://dialogue_source_%d/meta.json" % Time.get_ticks_usec(), "dialogue_source")
	meta.initialize_z2_profile(Rules.CONTENT_VERSION)
	meta.data.tutorial_completed = true
	meta.data.profile_level = 50
	meta.data.profile_exp = Rules.exp_for_level(50)
	meta.data.talent_flags = ["z2_talent_01"]
	meta.data.talent_spent = 100
	meta.data.talent_points = 0
	_check(meta.save(), "isolated profile fixture saved")
	var r := Runtime.new()
	r.bind_meta_progress_adapter(meta)
	var commission: Dictionary = M7ContentCatalog.commission_offer_candidates("classic_13x13_normal", 0, 3)[0]
	var result: Dictionary = r.command_bus.dispatch(&"start_standard_run", {"run_start_config": {
		"map_config_id": "classic_13x13_normal", "difficulty": "normal", "seed_value": 3141, "selected_objective_id": commission.id}})
	_check(result.get("ok", false), "real standard departure")
	r.context.hp = 1000
	r.context.max_hp = 1000
	r.context.power = 100
	r.context.asset_ledger.backpack_capacity = 2000
	r.context.asset_ledger.add_currency(&"black_coin", 300, "dialogue_fixture")
	return r

func _enter(r: RunRuntimeController, pos: Vector2i, event: String) -> bool:
	r.context.truth_map.set_room_type(pos, &"Event")
	if not r.context.z1_event_rooms.has(r.context.cell_key(pos)):
		r.context.z1_event_rooms[r.context.cell_key(pos)] = {"event_type": StringName(event)}
	var result := r.execute_atomic_operation(&"room_entry", {}, func() -> Dictionary:
		r.context.player_pos = pos
		r.context.current_pos = pos
		return r.command_bus.room_resolver.enter_room(r.context), _id("enter"))
	return _check(result.get("ok", false), "actual room entry " + event + ": " + str(result.get("reason", "")))

func _state(r: RunRuntimeController) -> Dictionary:
	return Service.get_event_state(r.context, r.context.get_current_pos())

func _request(r: RunRuntimeController, option: String) -> Dictionary:
	var request := {"option_id": option, "action_id": _id(option)}
	for row: Dictionary in _state(r).get("options", []):
		if str(row.id) == option:
			request.merge(row.get("payload", {}), true)
			break
	return request

func _choose(r: RunRuntimeController, option: String) -> Dictionary:
	var result: Dictionary = r.command_bus.dispatch(&"select_event_option", _request(r, option))
	return result.get("action_result", result)

func _copy(state: Dictionary, field: String = "dialogue") -> String:
	var result := ""
	for line: Dictionary in state.get(field, []):
		result += str(line.get("text", "")) + "\n"
	return result

func _test_all_openings() -> void:
	var r := _runtime()
	var index := 0
	for event: String in Events.event_ids():
		var pos := Vector2i(index % 10 + 1, index / 10 + 2)
		index += 1
		if not _enter(r, pos, event):
			continue
		var before := Snapshot.capture_context(r.context)
		var view := _state(r)
		_check(not view.get("dialogue", []).is_empty(), "S3 opening reaches canonical " + event)
		_check(view.get("dialogue_source", {}).get("sha256", "") == SOURCE_SHA, "source hash reaches canonical " + event)
		_check(not _copy(view).contains("【") and not _copy(view).contains("当前报价已确认"), "no unresolved source placeholder/engineering prepare copy " + event)
		for line: Dictionary in view.get("dialogue", []):
			_check(int(line.get("source_row", 0)) > 0, "every flavor line retains S3 row " + event)
		_check(Snapshot.capture_context(r.context) == before, "dialogue projection is pure " + event)
		if event == "seal":
			_check(not _copy(view).contains("花8黑币") and not _copy(view).contains("增加10点"), "old seal numeric example excluded")
		if event == "consign":
			_check(not _copy(view).contains("一件8黑币"), "old flat freight fee excluded")
		if event == "cage":
			r.in_run_runtime.reset()
	_release(r)

func _has_row(view: Dictionary, row: int) -> bool:
	return view.get("dialogue", []).any(func(line: Dictionary) -> bool: return int(line.get("source_row", 0)) == row)

func _test_source_branches() -> void:
	# Projection fixtures exercise dialogue selection only. Official pools and
	# actual transactions are exercised separately through the Runtime above.
	var completed_rows := {"information": 22, "shop": 39, "savings": 54, "seal": 70,
		"mechanism": 89, "recycle": 105, "relief": 122, "first_aid": 138, "consign": 153,
		"expand": 168, "compress": 183, "trader": 202, "pawn": 217, "shortcut": 232,
		"coil": 248, "demine": 264, "clock_in": 281, "recon": 296, "rps": 0,
		"cage": 334, "dice": 355, "altar": 372}
	for event: String in Events.event_ids():
		var state := {"completed": true, "stage_awarded": true, "offers": [{"sold": false}],
			"contract": {"claimed": true}, "last_result": {"option_id": "deposit"}}
		var view := Dialogue.project(event, state, {"returning": true})
		_check(_has_row(view, completed_rows[event]) if completed_rows[event] > 0 else view.dialogue.is_empty(), "completed source branch or explicit absence " + event)
		_check(not _copy(view).contains("【"), "completed branch has no unbound tokens " + event)
	var cases := [
		["information", {}, {"information_discount": true}, 14, "同行都是朋友"],
		["shop", {"offers": [], "options": [{"id": "refresh", "player_cost": {"amount": 15}}]}, {"returning": true}, 39, "再添15枚"],
		["savings", {"room_key": "2,2"}, {"savings_pending": {"room_key": "1,1", "principal": 37}}, 54, "上次存了37"],
		["seal", {}, {"seal_discount": true}, 67, "老客户路线"],
		["mechanism", {"variant": "electric"}, {}, 82, "已断电"],
		["mechanism", {"variant": "mechanical", "threshold": 137}, {}, 85, "137"],
		["first_aid", {"quote": {"options": [{"id": "buy", "reward": {"base_pressure": 5}}]}}, {}, 135, "应急供应"],
		["coil", {"room_key": "2,2", "pending": {"room_id": "2,2"}}, {}, 247, "灯还亮着"],
		["clock_in", {"contract": {"new_rooms": {"2,2": true}}}, {}, 279, "还差2间"],
		["rps", {"rounds": [{}], "wins": 1, "losses": 0}, {}, 315, "1比0"],
		["dice", {"rounds": [{}]}, {}, 354, "换个盅"],
		["altar", {"offer_count": 1, "hp_cost": 17, "black_reward": 23, "rewards": [{"display_name": "实际报价物品"}]}, {}, 368, "实际报价物品"],
	]
	for test: Array in cases:
		var view := Dialogue.project(test[0], test[1], test[2])
		_check(_has_row(view, test[3]) and _copy(view).contains(test[4]), "state-based source branch " + str(test[0]))
		_check(not _copy(view).contains("【"), "bound actual placeholder " + str(test[0]))
	_check(Dialogue.project("clock_in", {"contract": {"new_rooms": {"a": true, "b": true, "c": true}}}).dialogue.is_empty(), "no invented clock ready-before-claim dialogue")
	_check(not _has_row(Dialogue.project("altar", {"requires_prepare": true, "hp_cost": 99}), 368), "stale altar quote does not render a price")
	_check(not _copy(Dialogue.project("shop", {"requires_prepare": true}, {"returning": true})).contains("【"), "unbound shop refresh price stays omitted")
	var replies := [
		["information", "mine_count", {}, 16], ["information", "exit_direction", {}, 20],
		["shop", "refresh", {}, 38], ["savings", "deposit", {}, 53], ["savings", "withdraw", {}, 54],
		["seal", "use", {}, 69], ["relief", "flat", {}, 119], ["relief", "ten_percent", {}, 120], ["relief", "thirty_percent", {}, 121],
		["first_aid", "buy", {}, 137], ["consign", "consign", {}, 152], ["expand", "expand", {}, 167],
		["compress", "compress", {"output": {"display_name": "真实压缩产物"}}, 182],
		["trader", "sell", {}, 201], ["pawn", "pawn", {}, 216], ["shortcut", "travel", {}, 0],
		["mechanism", "attempt", {"success": true, "mechanism_variant": "mechanical"}, 87],
		["mechanism", "attempt", {"success": true, "mechanism_variant": "electric"}, 84],
		["mechanism", "attempt", {"success": false}, 88],
		["recycle", "take", {"operation": "take"}, 103], ["recycle", "deliver", {"operation": "deliver", "safe_income": 13}, 104],
		["coil", "calibrate", {}, 246], ["coil", "search_completed", {}, 0],
		["demine", "demine", {"hit": true}, 262], ["demine", "demine", {"hit": false}, 263],
		["clock_in", "register", {}, 278], ["clock_in", "claim", {}, 280],
		["recon", "recon_5", {"scan_size": 5}, 295],
		["rps", "rock", {"outcome": "tie"}, 310], ["rps", "paper", {"outcome": "win"}, 311], ["rps", "scissors", {"outcome": "loss"}, 312],
		["rps", "rock", {"match_win": true, "black_income_gross": 37}, 313], ["rps", "paper", {"match_win": false}, 314],
		["cage", "combat_completed", {"win": true}, 332], ["cage", "combat_completed", {"win": false}, 333],
		["dice", "roll", {"win": false, "face": 2, "round": 1}, 349],
		["dice", "roll", {"win": true, "face": 5}, 351], ["dice", "roll", {"win": true, "face": 6}, 352],
		["altar", "offer", {}, 370], ["altar", "assist", {}, 0],
	]
	for test: Array in replies:
		var view := {"dialogue": Dialogue.response(test[0], test[1], test[2], {})}
		_check(_has_row(view, test[3]) if test[3] > 0 else view.dialogue.is_empty(), "source response or explicit absence %s/%s" % [test[0], test[1]])
		_check(not _copy(view).contains("【"), "response binds available actual facts %s/%s" % [test[0], test[1]])
	_check(_copy({"dialogue": Dialogue.response("compress", "compress", {"output": {"display_name": "真实压缩产物"}}, {})}).contains("吐出真实压缩产物"), "compression reply uses delivered item name")
	_check(_copy({"dialogue": Dialogue.response("recon", "recon_5", {"scan_size": 5}, {})}).contains("5×5"), "recon reply uses actual scan size")
	_check(_copy({"dialogue": Dialogue.response("rps", "rock", {"match_win": true, "black_income_gross": 37}, {})}).contains("37枚"), "rps reply uses actual prize")
	_check(not _has_row({"dialogue": Dialogue.response("dice", "roll", {"win": false, "face": 2, "round": 3}, {})}, 350), "final loss does not invite impossible fourth round")

func _test_real_dialogue_receipts() -> void:
	var r := _runtime()
	_enter(r, Vector2i(2, 2), "relief")
	r.context.pressure = 40
	_choose(r, "prepare")
	var view := _state(r)
	_check(str(view.get("speaker", "")) == "老板" and _copy(view).contains("坐坐坐"), "source relief identity and opening")
	var adapter := Adapter.new()
	root.add_child(adapter)
	await process_frame
	_check(adapter.apply_event(view, {"run_id": str(r.context.run_id)}), "actual adapter accepts source projection")
	_check(adapter.dialogue.get_node("%DialogueText").text == str(view.get("dialogue", [{}])[0].get("text", "")), "real component shows source body instead of summary")
	var captured: Array = []
	adapter.choice_requested.connect(func(request: Dictionary, option: Dictionary) -> void: captured.append({"request": request, "option": option}))
	for _step in range(40):
		if adapter.dialogue._choosing:
			break
		adapter.dialogue._advance()
	var index := 0
	for row: Dictionary in view.options:
		if row.id == "flat":
			break
		index += 1
	adapter.dialogue._request_option(index)
	if _check(captured.size() == 1, "actual dialogue selection produces request"):
		var payload: Dictionary = captured[0].option.payload.duplicate(true)
		payload.option_id = captured[0].option.id
		var envelope: Dictionary = r.command_bus.dispatch(&"select_event_option", payload)
		var result: Dictionary = envelope.get("action_result", envelope).duplicate(true)
		result.committed = bool(envelope.get("ok", false)) and r.action_receipts.has(str(payload.action_id))
		_check(result.get("ok", false) and result.committed and r.context.pressure == 35, "real committed relief applies actual pressure change")
		_check(str(result.get("message", "")).contains("5") and not result.get("response_lines", []).is_empty() and str(result.response_lines[0].text) == str(result.message), "actual result feedback stays first and intact")
		_check(_copy(result, "response_lines").contains("这下清静了"), "sourced relief reply appended after actual result")
		_check(adapter.apply_committed_result(captured[0].request, result, _state(r), {"run_id": str(r.context.run_id)}), "real component accepts committed receipt")
		_check(adapter.dialogue.get_node("%DialogueText").text == str(result.message), "component prioritizes actual payment/effect response")
		_check(adapter.dialogue.get_node("%SpeakerName").text == "老板", "result inherits source NPC identity")
	# Real pending component request with a stale quote in an unfinished room.
	_enter(r, Vector2i(3, 2), "relief")
	view = _state(r)
	adapter.apply_event(view, {"run_id": str(r.context.run_id)})
	for _step in range(40):
		if adapter.dialogue._choosing:
			break
		adapter.dialogue._advance()
	captured.clear()
	adapter.dialogue._request_option(0)
	if _check(captured.size() == 1, "actual component produces request to reject"):
		var stale: Dictionary = captured[0].option.payload.duplicate(true)
		stale.option_id = captured[0].option.id
		stale.quote_id = "expired"
		var before := Snapshot.capture_context(r.context)
		var failure: Dictionary = r.command_bus.dispatch(&"select_event_option", stale)
		var rejected: Dictionary = failure.get("action_result", failure)
		_check(not rejected.get("ok", true) and rejected.get("reason", "") == "stale_quote" and not str(rejected.get("message", "")).is_empty(), "actual failed action retains real stale-quote reason")
		_check(rejected.get("response_lines", []).is_empty() and rejected.get("dialogue", []).is_empty(), "failure does not borrow success flavor")
		_check(Snapshot.capture_context(r.context) == before, "rejected quote changes no authoritative event state")
		_check(adapter.apply_committed_result(captured[0].request, rejected, _state(r), {"run_id": str(r.context.run_id)}), "actual component accepts failure feedback")
		_check(adapter.dialogue.get_node("%DialogueStatus").text == str(rejected.message), "actual component shows original failure reason independently")
	adapter.queue_free()
	await process_frame
	_release(r)

func _test_revisit_and_preparation() -> void:
	var r := _runtime()
	var pos := Vector2i(2, 2)
	_enter(r, pos, "shop")
	_check(_copy(_state(r)).contains("你这是地下商铺吗"), "shop first visit uses S3 B35")
	var prepared := _choose(r, "prepare")
	_check(_copy(prepared, "response_lines").contains("包的！") and not str(prepared.get("message", "")).contains("当前报价已确认"), "prepare publishes source dialogue instead of generic confirmation")
	_enter(r, Vector2i(3, 2), "relief")
	_enter(r, pos, "shop")
	_check(_copy(_state(r)).contains("上次的货还没人买"), "unbought real room revisit uses S3 B39")
	var saved: Variant = r.encode_checkpoint_state(r.capture_authoritative_state())
	var resumed := Runtime.new()
	_check(resumed.restore_checkpoint_state(JSON.parse_string(JSON.stringify(saved))).get("ok", false), "dialogue visit state survives actual codec")
	_check(_copy(_state(resumed)) == _copy(_state(r)), "restored revisit does not return to first visit")
	_release(resumed)
	_enter(r, Vector2i(4, 2), "relief")
	r.context.pressure = 30
	_choose(r, "prepare")
	_choose(r, "flat")
	_check(_copy(_state(r)).contains("你这回都做完了"), "completed relief uses S3 B122")
	_release(r)

func _test_settled_loss() -> void:
	var r := _runtime()
	_enter(r, Vector2i(2, 2), "trap")
	r.context.power = 0
	var result := _choose(r, "attempt")
	_check(result.get("ok", false) and not result.get("facts", {}).get("success", true), "mechanical loss remains settled success")
	_check(str(result.get("message", "")).contains("未通过") and str(result.get("response_lines", [{}])[0].get("text", "")) == str(result.message), "loss result stays ahead of flavor")
	_check(_copy(result, "response_lines").contains("嘶——") and not _copy(result, "response_lines").contains("生命减少1"), "loss flavor uses S3 B88 but never replaces actual damage with example")
	_release(r)

func _id(prefix: String) -> String:
	sequence += 1
	return "source-dialogue:%s:%d" % [prefix, sequence]

func _release(r: RunRuntimeController) -> void:
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)

func _check(value: bool, label: String) -> bool:
	checks += 1
	if not value:
		failures.append(label)
	return value
