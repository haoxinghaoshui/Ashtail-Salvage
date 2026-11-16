extends SceneTree

# Run prepare/resume/verify in separate processes with the same case and token.
# This runner refuses real user data before constructing any save actor.
const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Manager = preload("res://scripts/core/save/save_manager.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Legacy = preload("res://scripts/core/content/z1_supply_catalog.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const Economy = preload("res://scripts/core/run/z2_economy_events.gd")

class CutMetaRename extends SaveAdapter:
	var cut := false
	var target := ""
	var cuts := 0
	func _rename_file(source_path: String, target_path: String) -> bool:
		if cut and source_path.ends_with(ATOMIC_TEMP_SUFFIX) and target_path == target:
			cuts += 1
			return false
		return super._rename_file(source_path, target_path)

var checks := 0
var failures: Array[String] = []
var phase := ""
var ending := ""
var token := ""
var profile := ""
var evidence_path := ""
var r
var meta
var manager

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if OS.get_cmdline_user_args().is_empty():
		_suite()
		return
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var split := arg.trim_prefix("--").split("=", true, 1)
		if split.size() == 2:
			args[split[0]] = split[1]
	phase = str(args.get("phase", ""))
	ending = str(args.get("case", ""))
	token = str(args.get("token", ""))
	var isolated := _canonical(str(args.get("isolation-root", "")))
	if not _isolated(isolated):
		_finish()
		return
	_check(phase in ["prepare", "resume", "verify"] and ending in ["success", "failure", "abandon"] and token.is_valid_identifier(), "explicit phase/case/token")
	if not failures.is_empty():
		_finish()
		return
	profile = "terminal_" + token + "_" + ending
	evidence_path = "user://terminal_durable/" + profile + ".json"
	print("DURABLE_PROCESS phase=%s case=%s pid=%d user=%s" % [phase, ending, OS.get_process_id(), OS.get_user_data_dir()])
	if phase == "prepare":
		_prepare()
	elif phase == "resume":
		_resume()
	else:
		_verify()
	_finish()

func _under(path: String, parent: String) -> bool:
	return _canonical(path).begins_with(parent + "/")

func _canonical(path: String) -> String:
	return path.replace("\\", "/").simplify_path().trim_suffix("/").to_lower()

func _isolated(isolated: String) -> bool:
	# Explicit absolute D root; a volume root or actual user home is never valid.
	_check(isolated.is_absolute_path() and isolated.begins_with("d:/") and isolated.length() > 3, "explicit absolute D isolation root")
	_check(_under(OS.get_user_data_dir(), isolated), "user data lies below explicit isolation root")
	for key in ["APPDATA", "LOCALAPPDATA", "TEMP", "TMP"]:
		_check(_under(OS.get_environment(key), isolated), "D isolation " + key)
	var home := _canonical(OS.get_environment("USERPROFILE"))
	# The formal harness also redirects USERPROFILE to a child of its fresh root.
	_check(not home.is_empty() and isolated != home and not _under(isolated, home), "isolation root is not the user profile or a child of it")
	var formal := _canonical(OS.get_environment("Z2_FORMAL_QA_HOME"))
	if not formal.is_empty():
		_check(formal == isolated, "phase root matches explicit formal QA root")
	return failures.is_empty()

func _suite() -> void:
	phase = "suite"
	ending = "all"
	var isolated := _canonical(OS.get_environment("Z2_FORMAL_QA_HOME"))
	if not _isolated(isolated):
		_finish()
		return
	# The formal harness gives this runner a fresh home. Never adopt old profiles.
	_check(not DirAccess.dir_exists_absolute("user://saves") and not DirAccess.dir_exists_absolute("user://terminal_durable"), "suite refuses any existing profile/evidence directory")
	if not failures.is_empty():
		_finish()
		return
	var log_root := isolated.path_join("terminal-durable-evidence")
	_check(DirAccess.make_dir_recursive_absolute(log_root) == OK, "suite evidence directory created")
	var suite_token := "suite_" + Crypto.new().generate_random_bytes(8).hex_encode()
	var process_count := 0
	var child_checks := 0
	for child_case in ["success", "failure", "abandon"]:
		for child_phase in ["prepare", "resume", "verify"]:
			var output: Array = []
			var child_args := PackedStringArray(["--headless", "--quit-after", "120", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/z2_terminal_durable_runner.gd", "--", "--phase=" + child_phase, "--case=" + child_case, "--token=" + suite_token, "--isolation-root=" + isolated])
			var exit_code := OS.execute(OS.get_executable_path(), child_args, output, true)
			process_count += 1
			var log := ""
			for chunk in output:
				log += str(chunk)
			var path := log_root.path_join(child_case + "-" + child_phase + ".log")
			var file := FileAccess.open(path, FileAccess.WRITE)
			_check(file != null, "child log opens " + path)
			if file != null:
				file.store_string(log)
				file.close()
			var marker := "Z2_TERMINAL_DURABLE=PASS case=%s phase=%s " % [child_case, child_phase]
			var diagnostics := false
			for text in ["SCRIPT ERROR", "Parse Error", "ERROR:", "WARNING:", "Z2_TERMINAL_DURABLE_FAIL"]:
				diagnostics = diagnostics or log.contains(text)
			_check(exit_code == 0 and log.count(marker) == 1 and not diagnostics, "child exit/PASS/diagnostics " + child_case + "/" + child_phase + " exit=" + str(exit_code))
			var count_regex := RegEx.create_from_string("checks=([0-9]+) failures=0")
			var counted := count_regex.search(log)
			if counted != null:
				child_checks += int(counted.get_string(1))
			print("DURABLE_CHILD case=%s phase=%s exit=%d log=%s" % [child_case, child_phase, exit_code, path])
	_check(process_count == 9, "all nine independent processes executed")
	print("DURABLE_SUITE children=%d child_checks=%d" % [process_count, child_checks])
	checks += child_checks
	_finish()

func _open() -> bool:
	manager = Manager.new()
	manager.load_manifest()
	_check(manager.switch_profile(profile).get("ok", false), "SaveManager selects isolated profile")
	meta = Meta.new()
	r = Runtime.new()
	r.bind_meta_progress_adapter(meta)
	var opened: Dictionary = r.initialize_z2_session(manager)
	_check(opened.get("ok", false), "real Runtime initializes/restores: " + str(opened))
	_check(r.checkpoint_service != null and not r.checkpoint_writer.is_valid(), "production checkpoint writer is active")
	return opened.get("ok", false)

func _prepare() -> void:
	if not _open():
		return
	_check(int(meta.data.get("run_count", 0)) == 0 and meta.data.get("admission", {}).is_empty(), "fresh isolated profile")
	# Qualification and owned-instance setup only. Departure and all saves are real.
	meta.data.tutorial_completed = true
	meta.data.profile_exp = 30
	meta.data.profile_level = 2
	meta.data.talent_flags = ["z2_talent_01", "z2_talent_19", "z2_talent_30"]
	meta.data.talent_earned = 220
	meta.data.talent_spent = 220
	meta.data.talent_points = 0
	meta.data.gold = 1000
	var gear := _item("eq_signal_pin", "carry-gear", {"uses": 1, "triggers": 2})
	var ration := _item("con_ration", "carry-ration")
	var stored := _item("col_01", "already-stored")
	var s03 := {}
	for row in Legacy.all_items():
		if str(row.get("source_id", "")) == "S03":
			s03 = row.duplicate(true)
			s03.instance_id = "already-stored-s03"
			s03.location_state = "warehouse"
			s03.counters = {"stored": 1}
	_check(not s03.is_empty(), "existing S03 definition found without new source values")
	# Old S03 follows its existing warehouse record contract; Z2 rows below retain
	# their full frozen version and counters. This is not a legacy migration test.
	s03 = meta._minimal_item_record(s03)
	meta.data.warehouse_items = [gear, ration, stored, s03]
	_check(meta.save(), "owned frozen instances persist before departure")
	var commission: Dictionary = M7ContentCatalog.commission_offer_candidates("classic_7x7_simple", 0, 3)[0]
	var started: Dictionary = r.command_bus.dispatch(&"start_standard_run", {"action_id": "departure", "run_start_config": {
		"map_config_id": "classic_7x7_simple", "difficulty": "simple", "seed_value": 20261116,
		"selected_objective_id": commission.id, "selected_equipment_ids": ["carry-gear"], "selected_consumable_ids": ["carry-ration"]}})
	_check(started.get("ok", false), "Meta-authorized actual departure: " + str(started.get("issues", started.get("reason", ""))))
	if not started.get("ok", false):
		print("DURABLE_START_FAILURE ", started)
		return
	_check(meta.data.get("admission", {}).get("phase") == "active", "two-stage durable admission active")
	_check(FileAccess.file_exists(r.checkpoint_service.checkpoint_path), "departure checkpoint exists")
	_check(meta.data.admission.reserved_instance_ids.has("carry-ration") and meta.data.admission.reserved_instance_ids.has("carry-gear"), "exact carried instance reservation")
	_check(r.context.asset_ledger.item_instances["carry-gear"].get("counters", {}) == gear.counters, "departure retains per-instance use counts")
	var added: Dictionary = r.execute_atomic_operation(&"durable_fixture_assets", {}, func() -> Dictionary:
		var ledger = r.context.asset_ledger
		for row in [["con_ration", "loot-ration"], ["con_tape_roll", "extra-tape"], ["con_tape_roll", "used-tape"], ["col_01", "selected-loot"], ["col_01", "freight"], ["col_07", "pawn"]]:
			var item := _item(row[0], row[1], {"uses": 1} if row[1] == "used-tape" else {})
			ledger.create_item_instance(item, &"inventory", r.context.get_current_pos())
		ledger.create_item_instance(_item("col_03", "floor-loot"), &"room_floor", r.context.get_current_pos())
		# Already delivered boundary: exact same IDs are on disk and in Warehouse Lite.
		for old in [stored, s03]:
			var retained: Dictionary = ledger.create_item_instance(old, &"warehouse")
			ledger.warehouse_lite.append(retained)
		ledger.add_currency(&"black_coin", 100, "test_asset_fixture")
		ledger.add_currency(&"gold_coin", 7, "test_safe_fixture")
		ledger.sync_compat_fields(r.context)
		return {"ok": true}, "fixture-assets")
	_check(added.get("ok", false), "asset fixture commits through real checkpoint")
	_economy("consign", Vector2i(1, 1), "consign", {"instance_id": "freight"})
	_economy("pawn", Vector2i(2, 1), "pawn", {"instance_id": "pawn"})
	_economy("savings", Vector2i(3, 1), "deposit", {"amount": 20})
	var ledger = r.context.asset_ledger
	_check(str(ledger.item_instances.freight.location_state) == "consigned", "actual consignment transfers original instance")
	_check(str(ledger.item_instances.pawn.location_state) == "pledged", "actual pawn transfers original instance")
	_check(not r.context.z1_event_flags.get("z2_economy", {}).get("savings_pending", {}).is_empty(), "actual savings guarantee pending")
	var before := _meta_state()
	var frozen := {}
	for id in ledger.item_instances:
		frozen[id] = _definition(ledger.item_instances[id])
	# Already-warehoused rows were committed before the run, not created anew.
	frozen["already-stored"] = _definition(stored)
	frozen["already-stored-s03"] = _definition(s03)
	var evidence := {"run_id": str(r.context.run_id), "profile": profile, "phase_pid": OS.get_process_id(),
		"before_meta": before, "frozen": frozen, "black": ledger.get_currency(&"black_coin"), "safe": ledger.get_currency(&"gold_coin")}
	if ending == "success":
		var exit_pos: Vector2i = r.context.truth_map.exits[0]
		_check(_enter(exit_pos, "Exit").get("ok", false), "real exit room entry")
		_check(r.command_bus.dispatch(&"request_extract", {"action_id": "extract-request"}).get("ok", false), "real extract request")
		_check(r.command_bus.dispatch(&"confirm_extract", {"action_id": "extract-confirm"}).get("ok", false), "success enters retention choice")
	elif ending == "failure":
		var failed: Dictionary = r.execute_atomic_operation(&"terminal_fixture_damage", {}, func() -> Dictionary:
			r.context.hp = 0
			return {"ok": true}, "fatal-damage")
		_check(failed.get("ok", false), "actual Runtime detects fatal health and freezes failure")
	else:
		_check(r.command_bus.dispatch(&"abandon_run", {"confirmed": true, "action_id": "abandon"}).get("ok", false), "actual abandon confirmation")
	_check_pending(evidence)
	_check(r.save_current_checkpoint().get("ok", false), "pending selection explicitly saved")
	evidence["revision"] = r.transaction_revision
	evidence["pending_hash"] = Snapshot.fingerprint(r.context.result_snapshot)
	_write_evidence(evidence)

func _resume() -> void:
	var evidence := _read_evidence()
	if evidence.is_empty() or not _open():
		return
	_check(OS.get_process_id() != int(evidence.phase_pid), "selection reopens in a new OS process")
	_check(str(r.context.run_id) == str(evidence.run_id) and r.transaction_revision == int(evidence.revision), "checkpoint restores exact run and revision")
	_check(Snapshot.fingerprint(r.context.result_snapshot) == str(evidence.pending_hash), "pending immutable result survives process restart")
	_check_pending(evidence)
	for id in evidence.frozen:
		_check(_matches_definition(r.context.asset_ledger.item_instances.get(id, {}), evidence.frozen[id]), "restart frozen definition/counters " + id)
	var selection: Array = ["selected-loot", "carry-ration"] if ending == "success" else ["carry-gear", "carry-ration", "loot-ration"]
	var state: Dictionary = r.terminal_selection_state(selection)
	_check(int(state.get("settlement_weights", {}).get("carry-ration", -1)) == 10, "retained ration costs exactly10 settlement weight")
	_check(int(r.context.asset_ledger.item_instances["carry-ration"].weight) == int(evidence.frozen["carry-ration"].weight), "retention does not replace physical weight")
	var expected_limit := 1 if ending == "success" else 2
	_check(int(state.get("retention_limit", -1)) == expected_limit, "ending-specific retained count")
	for bad in [["carry-ration", "carry-ration"], ["used-tape"], ["missing-instance"], ["carry-ration", "loot-ration", "extra-tape"]]:
		var before := Snapshot.fingerprint(r.capture_authoritative_state())
		var rejected: Dictionary = r.command_bus.dispatch(&"confirm_failure_salvage", {"selected_instance_ids": bad})
		_check(not rejected.get("ok", true), "invalid selection rejected " + str(bad))
		_check(Snapshot.fingerprint(r.capture_authoritative_state()) == before, "invalid selection does not alter durable candidate")
	var previous_bytes := FileAccess.get_file_as_string(meta.active_meta_progress_path)
	var previous_state := _meta_state()
	var cut := CutMetaRename.new()
	cut.target = meta.active_meta_progress_path
	cut.cut = true
	meta.save_adapter = cut
	var result: Dictionary = r.command_bus.dispatch(&"confirm_failure_salvage", {"selected_instance_ids": selection, "action_id": "final-choice"})
	_check(result.get("ok", false), "final choice itself commits to checkpoint")
	_check(cut.cuts == 1 and str(r.last_meta_commit.get("status", "")) == "save_failed", "only Meta final rename fails after terminal checkpoint: " + str(r.last_meta_commit))
	_check(_same(_meta_state(), previous_state), "failed Meta commit rolls back warehouse/gold/XP/receipts")
	_check(FileAccess.get_file_as_string(meta.active_meta_progress_path) == previous_bytes, "failed Meta commit leaves primary bytes unchanged")
	_check(FileAccess.file_exists(r.checkpoint_service.checkpoint_path), "failed Meta commit retains retry checkpoint")
	var disk := Meta.new()
	disk.set_active_profile_path(meta.active_meta_progress_path, profile)
	_check(not disk.data.get("run_receipts", {}).has(str(evidence.run_id)), "independent disk read has no premature terminal receipt")
	_check(int(disk.data.get("run_count", -1)) == int(previous_state.run_count), "independent disk read has no premature run count")
	var terminal: Dictionary = r.context.result_snapshot.duplicate(true)
	var terminal_hash := Snapshot.fingerprint(terminal)
	_check(terminal.get("settlement", {}).get("finalized", false), "failed-save snapshot is already finalized")
	cut.cut = false
	var retry: Dictionary = r.command_bus.dispatch(&"retry_terminal_commit", {"action_id": "retry-identical-terminal"})
	_check(retry.get("ok", false), "same terminal retries via real Runtime: " + str(retry.get("status", retry.get("reason", ""))))
	_check(Snapshot.fingerprint(r.context.result_snapshot) == terminal_hash, "retry does not rebuild or mutate terminal result")
	_assert_final(evidence, terminal)
	evidence["terminal"] = terminal
	evidence["after_meta"] = _meta_state()
	evidence["resume_pid"] = OS.get_process_id()
	evidence["terminal_hash"] = terminal_hash
	var saved_bytes := FileAccess.get_file_as_string(meta.active_meta_progress_path)
	var replay: Dictionary = r.command_bus.dispatch(&"retry_terminal_commit", {})
	_check(replay.get("ok", false) and FileAccess.get_file_as_string(meta.active_meta_progress_path) == saved_bytes, "same-process retry is disk no-op")
	_check(_same(_meta_state(), evidence.after_meta), "same-process retry cannot add warehouse/XP/gold")
	_write_evidence(evidence)

func _verify() -> void:
	var evidence := _read_evidence()
	if evidence.is_empty() or not evidence.has("after_meta") or not _open():
		_check(false, "completed resume evidence required")
		return
	_check(OS.get_process_id() != int(evidence.resume_pid), "final reread uses third OS process")
	_check(not r.context.run_started, "settled checkpoint cannot resume gameplay")
	_check(_same(_meta_state(), evidence.after_meta), "third process preserves exact warehouse/counters/XP/gold/receipts")
	_assert_final(evidence, evidence.terminal)
	var bytes := FileAccess.get_file_as_string(meta.active_meta_progress_path)
	var replay: Dictionary = r.checkpoint_service.apply_settlement(evidence.terminal)
	_check(replay.get("ok", false), "cross-process identical terminal returns durable receipt")
	_check(_same(_meta_state(), evidence.after_meta), "cross-process replay grants no duplicate items/XP/gold")
	_check(FileAccess.get_file_as_string(meta.active_meta_progress_path) == bytes, "cross-process replay performs no Meta write")
	var changed: Dictionary = evidence.terminal.duplicate(true)
	changed.settlement.long_term_gold_gained = int(changed.settlement.long_term_gold_gained) + 1
	var conflict: Dictionary = r.checkpoint_service.apply_settlement(changed)
	_check(not conflict.get("ok", true) and conflict.get("status") == "run_receipt_conflict", "same-run changed settlement rejected")
	_check(_same(_meta_state(), evidence.after_meta), "conflicting retry preserves all durable balances")

func _check_pending(evidence: Dictionary) -> void:
	_check(str(r.context.phase) == "failure_salvage" and not r.context.run_active, "terminal choice is frozen for " + ending)
	_check(str(r.context.settlement_result.get("outcome", "")) == ending, "pending choice preserves actual ending")
	_check(not r.context.settlement_result.get("finalized", true) and r.context.settlement_result.get("requires_salvage_selection", false), "choice required before finalization")
	_check(_same(_meta_state(), evidence.before_meta), "pending selection cannot award or remove Meta assets")
	_check(not meta.data.get("run_receipts", {}).has(str(evidence.run_id)), "pending choice cannot create terminal receipt")
	_check(not r.retry_terminal_commit().get("ok", true), "pending result cannot be forcibly committed")

func _assert_final(evidence: Dictionary, terminal: Dictionary) -> void:
	var settlement: Dictionary = terminal.get("settlement", {})
	_check(str(settlement.get("outcome", "")) == ending and settlement.get("finalized", false), "durable finalized ending matches")
	var expected: Array = ["already-stored", "already-stored-s03", "carry-gear", "carry-ration", "freight"]
	if ending == "success":
		expected.append_array(["selected-loot", "pawn"])
	else:
		expected.append("loot-ration")
	expected.sort()
	var actual: Array = []
	for item: Dictionary in meta.data.warehouse_items:
		actual.append(str(item.instance_id))
	actual.sort()
	_check(actual == expected, "exact warehouse instance multiset: " + str(actual))
	_check(actual.count("already-stored-s03") == 1, "already-stored S03 is never duplicated")
	for id in expected:
		var matches: Array = meta.data.warehouse_items.filter(func(item: Dictionary) -> bool: return str(item.instance_id) == id)
		_check(matches.size() == 1, "one durable copy of " + id)
		if matches.size() == 1:
			_check(_matches_definition(matches[0], evidence.frozen[id]), "terminal frozen definition/use counts " + id)
	var safe := int(evidence.safe)
	var black := int(evidence.black)
	var expected_gold := safe + black - 16 if ending == "success" else safe
	_check(int(settlement.get("long_term_gold_gained", -1)) == expected_gold, "safe survives all endings; successful pawn costs16 once")
	_check(int(meta.data.gold) == int(evidence.before_meta.gold) + expected_gold, "Meta gold credited exactly once")
	var growth: Dictionary = settlement.get("z2_growth", {})
	var delta := int(growth.get("experience", growth.get("exp", -1)))
	_check(delta > 0, "real event journal yields nonzero XP")
	_check(int(meta.data.profile_exp) == int(evidence.before_meta.profile_exp) + delta, "Meta XP credited exactly once")
	_check(int(meta.data.run_count) == int(evidence.before_meta.run_count) + 1, "one terminal increments run count once")
	_check(meta.data.get("run_receipts", {}).has(str(evidence.run_id)) and meta.data.get("admission", {}).is_empty(), "receipt atomically releases admission")
	_check(not FileAccess.file_exists(r.checkpoint_service.checkpoint_path) and not FileAccess.file_exists(r.checkpoint_service.checkpoint_path + SaveAdapter.LAST_VALID_BACKUP_SUFFIX), "settled checkpoint and backup cleaned")

func _economy(event: String, pos: Vector2i, action: String, params: Dictionary) -> void:
	_check(_enter(pos, "Event", event).get("ok", false), "real room entry " + event)
	if event == "savings":
		var prepared: Dictionary = r.command_bus.dispatch(&"select_event_option", {"option_id": "prepare", "amount": params.amount, "action_id": "prepare-savings"})
		_check(prepared.get("ok", false), "actual savings principal preparation")
	var state := Economy.public_state(r.context, pos, event)
	var payload := params.duplicate(true)
	payload.merge({"option_id": action, "quote_id": state.get("quote_id", ""), "action_id": "economy-" + event})
	var done: Dictionary = r.command_bus.dispatch(&"select_event_option", payload)
	_check(done.get("ok", false), "real economy " + event + ": " + str(done.get("reason", "")))
	var before := Snapshot.fingerprint(r.capture_authoritative_state())
	var replay: Dictionary = r.command_bus.dispatch(&"select_event_option", payload)
	_check(replay.get("ok", false) and replay.get("duplicate", false) and Snapshot.fingerprint(r.capture_authoritative_state()) == before, "economy replay preserves original transfer " + event)

func _enter(pos: Vector2i, room_type: String, event := "") -> Dictionary:
	return r.execute_atomic_operation(&"durable_fixture_room_entry", {"pos": pos}, func() -> Dictionary:
		if room_type == "Event":
			r.context.truth_map.set_room_type(pos, &"Event")
			r.context.z1_event_rooms[r.context.cell_key(pos)] = {"event_type": StringName(event)}
		r.context.player_pos = pos
		r.context.current_pos = pos
		return r.command_bus.room_resolver.enter_room(r.context), "entry-" + str(pos))

func _item(id: String, instance: String, counters: Dictionary = {}) -> Dictionary:
	var item: Dictionary = Items.definition(id)
	item.instance_id = instance
	item.location_state = "warehouse"
	item.counters = counters.duplicate(true)
	return item

func _definition(item: Dictionary) -> Dictionary:
	var result := {}
	for key in ["instance_id", "item_id", "display_name", "content_version", "item_type", "main_type", "rarity", "collectible_level", "tier", "weight", "base_value", "purchase_price", "can_equip", "can_consume", "can_sell", "can_store", "is_unique", "source_id", "source_sheet", "source_row", "source_hash", "icon_path", "short_description", "effect_kind", "effect_amount", "effect_params", "equipment_slot", "counters"]:
		if item.has(key):
			result[key] = item[key]
	return result

func _meta_state() -> Dictionary:
	var result := {}
	for key in ["warehouse_items", "gold", "profile_exp", "profile_level", "talent_points", "talent_earned", "run_count", "extract_count", "fail_count", "abandon_count", "admission", "run_receipts", "committed_result_ids", "history_records", "z2_goals", "z2_fact_sequence", "task_states", "achievement_states"]:
		result[key] = meta.data.get(key)
	return result

func _same(a: Variant, b: Variant) -> bool:
	# JSON stores ordinary integral values as floats; compare their canonical values.
	var left := SaveAdapter.json_fingerprint(meta._json_safe(a))
	var right := SaveAdapter.json_fingerprint(meta._json_safe(b))
	return not left.is_empty() and left == right

func _matches_definition(item: Dictionary, frozen: Dictionary) -> bool:
	var original_fields := {}
	for key in frozen:
		original_fields[key] = item.get(key)
	return _same(original_fields, frozen)

func _write_evidence(data: Dictionary) -> void:
	_check(SaveAdapter.new().save_json({"state": Snapshot.pack_checkpoint(data)}, evidence_path, false), "durable comparison evidence saved")

func _read_evidence() -> Dictionary:
	var loaded := SaveAdapter.new().load_json_result(evidence_path, {}, false)
	var unpacked := Snapshot.unpack_checkpoint(loaded.get("data", {}).get("state", {}))
	_check(loaded.get("ok", false) and unpacked.get("ok", false), "prior process comparison evidence exists")
	return unpacked.get("state", {})

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		print("Z2_TERMINAL_DURABLE_FAIL " + ending + "/" + phase + " " + label)

func _finish() -> void:
	if r != null:
		r.command_bus.runtime_controller = null
		r.command_bus.room_resolver.bind_runtime_controller(null)
		r.in_run_runtime.bind(null)
	print("Z2_TERMINAL_DURABLE=%s case=%s phase=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", ending, phase, checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
