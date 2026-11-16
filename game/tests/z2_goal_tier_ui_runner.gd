extends SceneTree
const Shell = preload("res://scripts/ui/long_term/long_term_shell.gd")
const Catalog = preload("res://scripts/core/content/m7_content_catalog.gd")
var failures: Array[String] = []
var checks := 0
var sent: Array[Dictionary] = []
func _initialize() -> void:
	call_deferred("_run")
func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func _run() -> void:
	var summary := {"ruleset_id": "z2", "z2_progression_version": 1, "profile_level": 1,
		"achievement_states": {"A08": {"status": "claimable", "progress": 200, "target": 200, "claimable_tiers": [1, 2, 3], "claimed_tiers": []}}}
	summary["achievement_definitions"] = Catalog.achievement_definitions(summary)
	var snapshot := {"meta_progress_summary": summary}
	var before := snapshot.duplicate(true)
	var panel := Shell.new()
	root.add_child(panel)
	panel.build({}, snapshot)
	panel.reduced_motion = true
	panel.show_secondary(&"achievement")
	for index in panel.current_content_cards.size():
		if str(panel.current_content_cards[index].get("id", "")) == "A08":
			panel.long_term_card_buttons[index].pressed.emit()
			break
	panel.meta_action_requested.connect(func(request: Dictionary) -> void: sent.append(request))
	await process_frame
	_check(snapshot == before, "goal UI projection is pure")
	_check(panel._meta_action_target_id({"action": "claim_goal", "goal_kind": "achievement", "goal_id": "A08"}) == "achievement:A08:1", "default claim tier also matches runtime suffix1")
	var selected_card: Button = panel.long_term_card_buttons[panel.selected_content_card_index]
	_check(selected_card.get_node_or_null(selected_card.focus_neighbor_right) == panel.find_child("ClaimGoalTier1", true, false), "selected goal keyboard navigation reaches first tier claim")
	for tier in [3, 1, 2]:
		var button := panel.find_child("ClaimGoalTier%d" % tier, true, false) as Button
		_check(button != null and button.is_visible_in_tree() and not button.disabled, "independent tier%d button" % tier)
		if button == null: continue
		var count := sent.size()
		button.pressed.emit()
		button.pressed.emit()
		_check(sent.size() == count + 1, "pending tier%d locks repeated input" % tier)
		if sent.size() == count: continue
		var request: Dictionary = sent.back()
		_check(request.action == &"claim_goal" and request.goal_id == "A08" and request.get("tier", 0) == tier, "actual page signal carries chosen tier%d" % tier)
		_check(panel.apply_meta_action_result({"ok": false, "status": "save_failed", "source_page": "long_term",
			"request_id": request.request_id, "action": "claim_goal", "target_id": "achievement:A08:%d" % tier, "result": {"ok": false}}), "matching failure releases tier%d" % tier)
	summary.achievement_states.A08.claimed_tiers = [2]
	summary.achievement_states.A08.claimable_tiers = [1, 3]
	panel.apply_snapshot({"meta_progress_summary": summary})
	var claimed := panel.find_child("ClaimGoalTier2", true, false) as Button
	_check(claimed != null and claimed.disabled, "new summary disables only claimed tier2")
	panel.set_page_active(false)
	panel.free()
	await process_frame
	for failure in failures: print("Z2_GOAL_TIER_UI_FAIL " + failure)
	print("Z2_GOAL_TIER_UI=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
