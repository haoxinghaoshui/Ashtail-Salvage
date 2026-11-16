extends SceneTree

const Goals := preload("res://scripts/core/progression/z2_goals/goal_progression.gd")
const GOAL_ID := "A08"
const EARNED_PROGRESS := 100


class ClaimWriteFailure extends SaveAdapter:
	var target_path := ""
	var failed_replaces := 0
	var staged_profile: Dictionary = {}

	func _rename_file(source: String, target: String) -> bool:
		if target == target_path and source == target_path + ATOMIC_TEMP_SUFFIX:
			staged_profile = JSON.parse_string(FileAccess.get_file_as_string(source)) as Dictionary
			target_path = ""
			failed_replaces += 1
			return false
		return super._rename_file(source, target)


var checks := 0
var failures: Array[String] = []
var main: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if _check(_isolated_save_directory(), "use fresh user data under Z2_FORMAL_QA_HOME") and _check(
			DirAccess.make_dir_recursive_absolute(SaveAdapter.SAVE_PROFILES_DIR) == OK, "create isolated profiles directory"):
		root.size = Vector2i(1280, 720)
		print("Z2_FORMAL_CLAIM_RETRY_USER_DATA ", OS.get_user_data_dir())
		var packed := load("res://scenes/main/main.tscn") as PackedScene
		if _check(packed != null and packed.can_instantiate(), "production main scene loads"):
			await _test_claim_retry(packed)
			await _release_main()
	for failure in failures:
		printerr("Z2_FORMAL_CLAIM_RETRY=FAIL: " + failure)
	print("Z2_FORMAL_CLAIM_RETRY=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _isolated_save_directory() -> bool:
	var qa_home := OS.get_environment("Z2_FORMAL_QA_HOME").replace("\\", "/").simplify_path().trim_suffix("/")
	var data_dir := OS.get_user_data_dir().replace("\\", "/").simplify_path()
	if not qa_home.is_absolute_path() or not data_dir.to_lower().begins_with(qa_home.to_lower() + "/"):
		return false
	var saves := DirAccess.open(SaveAdapter.SAVE_ROOT_DIR)
	var profiles := DirAccess.open(SaveAdapter.SAVE_PROFILES_DIR)
	return (saves == null or saves.get_files().is_empty()) \
		and (profiles == null or (profiles.get_directories().is_empty() and profiles.get_files().is_empty())) \
		and not FileAccess.file_exists(SaveAdapter.M1_META_PROGRESS_PATH)


func _test_claim_retry(packed: PackedScene) -> void:
	var scene = await _open_main(packed)
	var meta: MetaProgressAdapter = scene.meta_progress_adapter
	if not _check(meta.data.get("ruleset_id", "") == "z2" and not scene.run_context.run_active
			and scene.runtime_controller.persistence_error.is_empty(), "production scene opens a fresh Z2 profile in the lobby"):
		return
	# Stage only the prerequisites: a post-tutorial profile and two earned A08 tiers.
	meta.data["tutorial_completed"] = true
	meta.data["profile_level"] = 1
	meta.data["tutorial_completion_receipt"] = {"result_id": "claim-fixture-tutorial"}
	meta.data["talent_flags"] = ["z2_talent_01"]
	meta.data["talent_spent"] = 100
	meta.data["talent_points"] = 0
	meta.data = Goals.initial_state(meta.data)
	meta.data[Goals.STATE_KEY]["states"][GOAL_ID]["progress"] = EARNED_PROGRESS
	if not _check(meta.save(), "persist earned A08 fixture: " + meta.last_error):
		return
	meta.load_or_create_default()
	var path := meta.active_meta_progress_path
	var page = _open_achievements(scene)
	var before := meta.data.duplicate(true)
	var gold_before := int(before.get("gold", -1))
	var exp_before := int(before.get("profile_exp", -1))
	var baseline := FileAccess.get_sha256(path)
	if not _check(not baseline.is_empty() and _goal_record(before).get("unlocked", false)
			and int(_goal_record(_read_profile(path)).get("progress", 0)) == EARNED_PROGRESS,
			"missing T13 integration: earned z2_goals state must survive real save/load"):
		return
	_check_profile(before, [], gold_before, exp_before, "seeded profile")

	var cut := ClaimWriteFailure.new()
	cut.target_path = path
	meta.save_adapter = cut
	var first := _press_claim(page, 1)
	if first.is_empty():
		return
	var request: Dictionary = first.request
	var request_id := str(request.request_id)
	var rejected: Dictionary = first.envelope
	var detail: Dictionary = rejected.get("result", {})
	var reached_save := _check(cut.failed_replaces == 1 and detail.get("error", "") == "atomic_replace_failed",
		"tier 1 reaches the real atomic replace and reports its failure (%s)" % rejected.get("status", "no result"))
	_check_profile(cut.staged_profile, [1], gold_before + 20, exp_before, "failed write's staged candidate")
	_check(not bool(rejected.get("ok", true)) and not bool(detail.get("ok", true)) and str(rejected.get("status", "")) == "save_failed"
		and bool(detail.get("rolled_back", false)) and not bool(rejected.get("duplicate", false))
		and not bool(rejected.get("committed", false)) and not bool(detail.get("committed", false)),
		"page receives a rollback instead of a confirmed claim")
	for notice: Dictionary in detail.get("completions", []):
		_check(not bool(notice.get("committed", false)), "failed claim publishes no committed completion")
	_check(meta.data == before and FileAccess.get_sha256(path) == baseline,
		"failure preserves the earned tiers, unclaimed state and wallet in memory and on disk")
	_check(not _receipts(meta.data).has(request_id) and not _receipts(_read_profile(path)).has(request_id),
		"failed request leaves no committed receipt")
	if not reached_save or not _check_claim(_resend_claim(page, request), 20, false, "identical tier 1 retry"):
		return
	_check_profile(meta.data, [1], gold_before + 20, exp_before, "tier 1 in memory")
	_check_profile(_read_profile(path), [1], gold_before + 20, exp_before, "tier 1 on disk")
	_check(_receipts(_read_profile(path)).has(request_id), "tier 1 reward and request receipt are durable")

	var after_first := meta.data.duplicate(true)
	var after_first_hash := FileAccess.get_sha256(path)
	_check_claim(_resend_claim(page, request), 20, true, "identical successful tier 1 replay")
	var conflict := request.duplicate(true)
	conflict["tier"] = 2
	_check_conflict(_resend_claim(page, conflict), "same request ID with tier 2")
	_check(meta.data == after_first and FileAccess.get_sha256(path) == after_first_hash,
		"replay and tier conflict leave wallet, tiers and durable profile unchanged")
	var stale_tier := request.duplicate(true)
	stale_tier["request_id"] = request_id + "-stale-tier"
	var stale_result := _resend_claim(page, stale_tier)
	if not _check(int(stale_result.get("result", {}).get("reward", {}).get("gold", 0)) == 0
			and int(meta.data.get("gold", -1)) == gold_before + 20 and _goal_record(meta.data) == _goal_record(after_first),
			"a fresh request for claimed tier 1 must not pay earned tier 2"):
		return

	var second := _press_claim(page, 2)
	if second.is_empty() or not _check_claim(second.envelope, 40, false, "tier 2 with a new request ID"):
		return
	var request_two: Dictionary = second.request
	var second_id := str(request_two.request_id)
	_check(second_id != request_id, "the page issued a different request ID for tier 2")
	var final_hash := FileAccess.get_sha256(path)
	var written := _read_profile(path)
	_check_profile(written, [1, 2], gold_before + 60, exp_before, "both tiers on disk")
	_check(_receipts(written).has(request_id) and _receipts(written).has(second_id), "both request IDs have durable receipts")

	await _release_main()
	var reopened = await _open_main(packed)
	var reloaded: MetaProgressAdapter = reopened.meta_progress_adapter
	_check(reopened.runtime_controller.persistence_error.is_empty() and reloaded.active_meta_progress_path == path,
		"fresh main scene loads the same profile from disk")
	_check_profile(reloaded.data, [1, 2], gold_before + 60, exp_before, "reloaded profile")
	var reopened_page = _open_achievements(reopened)
	var loaded := reloaded.data.duplicate(true)
	_check_conflict(_resend_claim(reopened_page, conflict), "same request ID with tier 2 after reload")
	_check_claim(_resend_claim(reopened_page, request), 20, true, "tier 1 receipt replay after reload")
	_check_claim(_resend_claim(reopened_page, request_two), 40, true, "tier 2 receipt replay after reload")
	_check(reloaded.data == loaded and FileAccess.get_sha256(path) == final_hash,
		"post-reload replay and conflict leave the durable profile unchanged")


func _open_main(packed: PackedScene) -> Node:
	main = packed.instantiate()
	root.add_child(main)
	var scene := main.get_node("RunScene")
	scene.set_process(false)
	await process_frame
	return scene


func _release_main() -> void:
	if main == null:
		return
	var scene = main.get_node("RunScene")
	var runtime = scene.runtime_controller
	main.queue_free()
	main = null
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.bind_runtime_controller(null)
	await process_frame


func _open_achievements(scene) -> Control:
	scene._show_long_term_shell(&"task_archive")
	var page = scene.ui_shell.get_long_term_page()
	page.show_secondary(&"achievement")
	return page


func _press_claim(page, tier: int) -> Dictionary:
	for index in range(page.current_content_cards.size()):
		var card: Dictionary = page.current_content_cards[index]
		if str(card.get("id", "")) != GOAL_ID:
			continue
		page.long_term_card_buttons[index].pressed.emit()
		var button := page.find_child("ClaimGoalTier%d" % tier, true, false) as Button
		if not _check(button != null and button.is_visible_in_tree() and not button.disabled,
				"A08 tier %d is claimable from its own achievement page button" % tier):
			return {}
		var requests: Array[Dictionary] = []
		var capture := func(request: Dictionary) -> void: requests.append(request.duplicate(true))
		page.meta_action_requested.connect(capture)
		button.pressed.emit()
		page.meta_action_requested.disconnect(capture)
		if not _check(requests.size() == 1, "claim button emits one request"):
			return {}
		var request := requests[0]
		if not _check(str(request.get("source_page", "")) == "long_term" and str(request.get("action", "")) == "claim_goal"
				and str(request.get("goal_kind", "")) == "achievement" and str(request.get("goal_id", "")) == GOAL_ID
				and int(request.get("tier", 0)) == tier and not str(request.get("request_id", "")).is_empty(),
				"page request preserves A08 tier %d and request identity" % tier):
			return {}
		return {"request": request, "envelope": _page_result(page, request)}
	_check(false, "Long Term does not show the A08 achievement card")
	return {}


func _resend_claim(page, request: Dictionary) -> Dictionary:
	# A second click creates a new ID. Replay the captured request through the same
	# page signal and AppShell/RunScene route into RunController.execute_meta_action.
	page.pending_meta_action = page._meta_request_identity(request)
	page.meta_action_requested.emit(request.duplicate(true))
	return _page_result(page, request)


func _page_result(page, request: Dictionary) -> Dictionary:
	var transaction: Dictionary = page.get_meta_transaction_snapshot()
	var envelope: Dictionary = transaction.get("last_result", {})
	if _check(not transaction.get("pending", true) and envelope.get("request_id", "") == request.request_id,
			"RunController result returned to the requesting page"):
		return envelope
	return {}


func _check_claim(envelope: Dictionary, gold: int, duplicate: bool, label: String) -> bool:
	return _check(bool(envelope.get("ok", false)) and str(envelope.get("status", "")) == "claimed"
		and bool(envelope.get("duplicate", false)) == duplicate
		and int(envelope.get("result", {}).get("reward", {}).get("gold", -1)) == gold,
		"%s returns the expected claim result (%s, duplicate=%s)" % [label, envelope.get("status", "no result"), envelope.get("duplicate", false)])


func _check_conflict(envelope: Dictionary, label: String) -> void:
	_check(not bool(envelope.get("ok", true)) and str(envelope.get("status", "")) == "request_id_conflict",
		"%s is rejected as request_id_conflict (%s)" % [label, envelope.get("status", "no result")])


func _check_profile(profile: Dictionary, claimed: Array, gold: int, experience: int, label: String) -> void:
	var goal := _goal_record(profile)
	var actual_tiers: Array[int] = []
	for value in goal.get("claimed_tiers", []):
		actual_tiers.append(int(value))
	_check(bool(goal.get("unlocked", false)) and int(goal.get("progress", 0)) == EARNED_PROGRESS and actual_tiers == claimed,
		"%s keeps both earned tiers with claimed tiers %s" % [label, claimed])
	_check(int(profile.get("gold", -1)) == gold and int(profile.get("profile_exp", -1)) == experience,
		"%s has wallet gold %d and unchanged XP" % [label, gold])


func _goal_record(profile: Dictionary) -> Dictionary:
	return profile.get(Goals.STATE_KEY, {}).get("states", {}).get(GOAL_ID, {})


func _receipts(profile: Dictionary) -> Dictionary:
	return profile.get(MetaProgressAdapter.META_ACTION_RECEIPTS_KEY, {})


func _read_profile(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition
