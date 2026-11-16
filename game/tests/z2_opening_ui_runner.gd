extends SceneTree
const Model = preload("res://scripts/ui/deploy_prep/deploy_prep_model.gd")
const Shell = preload("res://scripts/ui/deploy_prep/deploy_prep_shell.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Config = preload("res://scripts/ui/deploy_prep/deploy_config.gd")
class CutSave extends SaveAdapter:
	var cut := false
	func _rename_file(source: String, target: String) -> bool:
		if cut and source.ends_with(ATOMIC_TEMP_SUFFIX):
			cut = false
			return false
		return super._rename_file(source, target)
var failures: Array[String] = []
var checks := 0
var panel: Control
var meta: MetaProgressAdapter
var runtime: RunRuntimeController
var sent: Array[Dictionary] = []
func _initialize() -> void:
	call_deferred("_run")
func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func _rows() -> Array:
	var rows: Array = []
	for row: Dictionary in panel.current_model.selection_rows:
		if str(row.id).begins_with("opening_"): rows.append(row)
	return rows
func _submit(request: Dictionary) -> void:
	sent.append(request.duplicate(true))
	var result := runtime.execute_meta_action(request)
	panel.apply_snapshot({"meta_progress_summary": result.meta_progress_summary})
	panel.apply_meta_action_result(result)
func _press(card: String, action: String) -> void:
	panel._on_card_pressed(StringName(card))
	for index in panel.detail_actions.size():
		if str(panel.detail_actions[index].id) == action:
			var button: Button = panel.detail_primary_action_button if index == 0 else panel.detail_secondary_action_button
			var before := sent.size()
			button.pressed.emit()
			button.pressed.emit()
			await process_frame
			_check(sent.size() == before + 1, "real synchronous receipt still rejects repeated " + action)
			return
	_check(false, "missing real action " + action)
func _action(action: String) -> Dictionary:
	for row: Dictionary in _rows():
		for entry: Dictionary in row.get("actions", []):
			if str(entry.id) == action: return entry
	return {}
func _boundary_checks() -> void:
	meta.data.run_count = int(meta.data.run_count) + 1
	meta.data.gold = 4
	_check(meta.save(), "next-departure low-balance fixture persists")
	panel.apply_snapshot({"meta_progress_summary": meta.get_summary()})
	_check(_rows().size() == 1 and not _action("opening_prepare").is_empty(), "stale prior departure offer is hidden")
	var config := Config.default_config(1, meta.get_summary())
	config = Config.select_map(config, "classic_7x7_simple").config
	_check(Config.config_validity(config).reason_code == &"opening_selection_required", "unfinished qualified offer blocks normal departure preview")
	await _press("opening_offer", "opening_prepare")
	_check(not _action("opening_refresh").get("enabled", false) and _action("opening_skip").get("enabled", false), "insufficient gold disables refresh and keeps free skip")
	var locked: Dictionary = meta.get_summary()
	locked.admission = {"fixture": true}
	panel.apply_snapshot({"meta_progress_summary": locked})
	_check(not _action("opening_refresh").get("enabled", false) and not _action("opening_skip").get("enabled", false) and not _action("opening_choose").get("enabled", false), "pending admission locks all opening operations")
	panel.apply_snapshot({"meta_progress_summary": meta.get_summary(), "run_active": true})
	_check(not _action("opening_choose").get("enabled", false), "active run locks choices")
	meta.data.gold = 1000
	_check(meta.save(), "refresh-boundary balance persists")
	panel.apply_snapshot({"meta_progress_summary": meta.get_summary(), "run_active": false})
	for count in range(1, 11):
		var old_gold := int(meta.data.gold)
		var old_offer := str(meta.data.z2_opening_offer.offer_id)
		_check(str(_action("opening_refresh").get("label", "")).contains(str(count * 5)), "refresh%d shows next committed cost" % count)
		await _press("opening_offer", "opening_refresh")
		_check(int(meta.data.gold) == old_gold - count * 5 and int(meta.data.z2_opening_offer.refresh_count) == count, "refresh%d charges exactly once" % count)
		_check(meta.data.z2_opening_offer.offer_id != old_offer and _rows().size() == 4, "refresh%d replaces only current three choices" % count)
	_check(not _action("opening_refresh").get("enabled", false) and _action("opening_skip").get("enabled", false), "refresh cap10 disables further charge but keeps skip")
	await _press("opening_offer", "opening_skip")
	_check(meta.data.z2_opening_offer.status == "skipped" and _rows().size() == 1 and _action("opening_choose").is_empty(), "actual skip is final and removes alternatives")
	meta.load_or_create_default()
	_check(meta.data.z2_opening_offer.status == "skipped", "skip survives actual reload")
	config = Config.default_config(1, meta.get_summary())
	config = Config.select_map(config, "classic_7x7_simple").config
	_check(Config.config_validity(config).can_start, "skipped offer releases departure preview")
func _run() -> void:
	meta = Meta.new()
	meta.set_active_profile_path("user://opening_ui_%d/meta.json" % Time.get_ticks_usec(), "opening_ui")
	_check(meta.initialize_z2_profile(Rules.CONTENT_VERSION).get("ok", false), "real profile initialized")
	meta.begin_tutorial_training()
	meta.purchase_tutorial_flag()
	meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "opening_ui_teaching")
	meta.data.gold = 1000
	meta.data.talent_flags.append("z2_talent_15")
	_check(meta.save(), "qualified fixture persists")
	runtime = RunRuntimeController.new()
	runtime.bind_meta_progress_adapter(meta)
	panel = Shell.new()
	root.add_child(panel)
	panel.build({}, {"meta_progress_summary": meta.get_summary()})
	panel.reduced_motion = true
	panel.show_tab(&"loadout")
	panel.meta_action_requested.connect(_submit)
	await process_frame
	_check(not _rows().is_empty(), "qualified profile has camp opening entry")
	if not _rows().is_empty():
		await _press("opening_offer", "opening_prepare")
		_check(meta.data.z2_opening_offer.candidates.size() == 3, "real prepare persists three options")
		_check(_rows().size() == 4, "three choices and shared refresh/skip in existing tab")
		var saved: Dictionary = meta.data.z2_opening_offer.duplicate(true)
		var writer := CutSave.new()
		meta.save_adapter = writer
		writer.cut = true
		await _press("opening_offer", "opening_refresh")
		var failed: Dictionary = sent.back().duplicate(true)
		_check(meta.data.z2_opening_offer == saved and int(meta.data.gold) == 1000, "failed refresh neither redraws nor charges")
		await _press("opening_offer", "opening_refresh")
		_check(sent.back().request_id == failed.request_id, "failed refresh retries exact request ID")
		_check(int(meta.data.gold) == 995 and int(meta.data.z2_opening_offer.refresh_count) == 1, "successful retry pays exactly5")
		meta.load_or_create_default()
		panel.apply_snapshot({"meta_progress_summary": meta.get_summary()})
		var selected: String = str(meta.data.z2_opening_offer.candidates[0])
		await _press("opening_" + selected, "opening_choose")
		_check(meta.data.z2_opening_offer.selected == selected and _rows().size() == 1, "choice persists and removes alternative actions")
		var next: Dictionary = meta.get_summary()
		next.talent_flags = ["z2_talent_29", "z2_talent_39"]
		panel.apply_snapshot({"meta_progress_summary": next})
		_check(_rows().is_empty(), "future nodes alone expose no opening choice")
		await _boundary_checks()
	panel.set_page_active(false)
	panel.free()
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)
	runtime = null
	meta = null
	await process_frame
	for failure in failures: print("Z2_OPENING_UI_FAIL " + failure)
	print("Z2_OPENING_UI=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
