extends SceneTree

const SaveScript := preload("res://scripts/core/save/save_adapter.gd")
const MetaScript := preload("res://scripts/core/save/meta_progress_adapter.gd")
const ManagerScript := preload("res://scripts/core/save/save_manager.gd")
const SERVICE_PATH := "res://scripts/core/save/run_checkpoint_service.gd"

class CutpointAdapter extends SaveAdapter:
	var fail_commit := 0
	var commit_count := 0
	var fail_cleanup := false

	func _rename_file(source_path: String, target_path: String) -> bool:
		if source_path.ends_with(ATOMIC_TEMP_SUFFIX):
			commit_count += 1
			if commit_count == fail_commit:
				return false
		return super._rename_file(source_path, target_path)

	func remove_json(path: String) -> bool:
		if fail_cleanup:
			last_error = "injected_cleanup_failure"
			return false
		return super.remove_json(path)

var failures: Array[String] = []
var checks := 0
var service_script: Script
var root_path := "user://z2_checkpoint_%s" % Time.get_ticks_usec()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var numeric := {"integer": 37, "fraction": 1.2345678901234567, "zero": 0, "nested": [1, 2]}
	var parsed: Variant = JSON.parse_string(JSON.stringify(numeric, "", true, true))
	_require(SaveScript.json_fingerprint(numeric) == SaveScript.json_fingerprint(parsed), "snapshot hash is stable across JSON numeric decoding")
	_test_prepared_reservation_disk_contract()
	var probe = MetaScript.new()
	_require(probe.has_method("initialize_z2_profile"), "Z2 profile initialization API is missing")
	_require(ResourceLoader.exists(SERVICE_PATH), "disk checkpoint/admission service is missing")
	if failures.is_empty():
		service_script = load(SERVICE_PATH)
		_test_admission_cutpoints()
		_test_complete_checkpoint_and_rollback()
		_test_reservations_and_references()
		_test_recovery_guards()
		_test_terminal_receipts()
		_test_old_and_unknown_profiles()
		_test_recovery_and_receipt_edge_cases()
	print("Z2_CHECKPOINT checks=%d failures=%d disk_root=%s" % [checks, failures.size(), ProjectSettings.globalize_path(root_path)])
	for failure in failures:
		print("Z2_RUN_CHECKPOINT_CASE_FAIL " + failure)
	print("Z2_RUN_CHECKPOINT=%s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _test_prepared_reservation_disk_contract() -> void:
	# Existing API behavioral RED: durable prepared reservation must survive load and block consumption.
	var adapter := SaveScript.new()
	var prepared: Dictionary = adapter.default_meta_progress()
	var snapshot := _snapshot("prepared-disk")
	prepared.merge({"profile_id": "prepared-disk", "ruleset_id": "z2", "content_version": "z2", "run_receipts": {}, "checkpoint_cleanup_run_id": ""}, true)
	prepared["warehouse_items"] = [{"instance_id": "reserved-material", "item_id": "mon_old_gear_set", "item_type": "collectible", "can_sell": true, "is_unique": false, "base_value": 20}]
	prepared["admission"] = {
		"schema_version": 1, "phase": "prepared", "profile_id": "prepared-disk", "run_id": "run-1", "ruleset_id": "z2", "content_version": "z2",
		"snapshot_schema_version": 1, "reserved_instance_ids": ["reserved-material"], "initial_snapshot": snapshot,
		"initial_snapshot_hash": JSON.stringify(JSON.parse_string(JSON.stringify(snapshot, "", true, true)), "", true, true).sha256_text(),
	}
	var binding: Dictionary = prepared.admission.duplicate(true)
	binding.erase("phase")
	binding.erase("initial_snapshot")
	prepared.admission["admission_hash"] = SaveScript.json_fingerprint(binding)
	var path := root_path + "/prepared-disk/meta_progress.json"
	_require(adapter.save_json(prepared, path, false), "prepare real disk reservation fixture")
	var meta = MetaScript.new()
	meta.set_active_profile_path(path, "prepared-disk")
	_require(meta.get_summary().get("reserved_instance_ids", []) == ["reserved-material"], "durable prepared reservation survives normal meta load")
	_require(meta.get_summary().get("warehouse_items", []).is_empty(), "durable reserved identity not advertised for another departure")
	_require(not bool(meta.sell_collectible("reserved-material").get("ok", true)), "durable prepared reservation blocks sale without caller guard")


func _fixture(name: String) -> Dictionary:
	var meta = MetaScript.new()
	meta.set_active_profile_path(root_path + "/" + name + "/meta_progress.json", name)
	_require(bool(meta.initialize_z2_profile().get("ok", false)), name + ": initialize new profile")
	meta.data["gold"] = 500
	meta.data["warehouse_items"].append({"instance_id": "reserved-material", "item_id": "mon_old_gear_set", "item_type": "collectible", "can_sell": true, "is_unique": false, "base_value": 20})
	_require(meta.save(), name + ": persist fixture")
	var adapter := CutpointAdapter.new()
	meta.save_adapter = adapter
	var service = service_script.new()
	service.save_adapter = adapter
	_require(bool(service.configure(meta).get("ok", false)), name + ": configure service")
	return {"meta": meta, "service": service, "adapter": adapter, "snapshot": _snapshot(name)}


func _restart(fixture: Dictionary) -> Dictionary:
	var old_meta = fixture.meta
	var meta = MetaScript.new()
	meta.set_active_profile_path(old_meta.active_meta_progress_path, old_meta.active_profile_id)
	var adapter := CutpointAdapter.new()
	meta.save_adapter = adapter
	var service = service_script.new()
	service.save_adapter = adapter
	_require(bool(service.configure(meta).get("ok", false)), old_meta.active_profile_id + ": configure after restart")
	return {"meta": meta, "service": service, "adapter": adapter, "snapshot": fixture.snapshot.duplicate(true)}


func _snapshot(profile: String) -> Dictionary:
	return {
		"schema_version": 1, "profile_id": profile, "run_id": "run-1", "ruleset_id": "z2", "content_version": "z2", "revision": 0,
		"state": {"context": {"hp": 37, "map": [[0, 1], [2, 3]], "minefield": [[false, true], [false, false]], "visited": ["0,0"], "items": [{"instance_id": "reserved-material", "location_state": "backpack"}], "charges": {"shield": 2}, "temporary_effects": [{"id": "slow", "remaining": 2.5}]},
		"combat": {"enemies": [{"id": "e1", "hp": 9, "position": [1.25, 2.75]}], "projectiles": [{"id": "p1", "position": [3.5, 4.25]}], "attack_buffer": ["strike"], "elapsed": 12.5, "pending_events": [{"damage": 3}]},
		"events": {"shared": {"dice_candidates": [2, 5, 6]}, "rooms": {"1,1": {"shop_stock": ["a", "b"], "visited": true}}},
		"rng_state": "18446744073709551601", "fact_cursor": 7, "action_receipts": {"action-1": {"revision": 0}}, "salvage_pending": false},
	}


func _test_admission_cutpoints() -> void:
	# Break caught: simulation before durable active, or lost reservations on restart.
	for cut in [1, 2, 3]:
		var f := _fixture("cut-%d" % cut)
		var before: Dictionary = f.meta.data.duplicate(true)
		f.adapter.fail_commit = cut
		var result: Dictionary = f.service.begin_admission(f.snapshot, ["reserved-material"])
		_require(not bool(result.get("ok", true)) and not bool(result.get("can_simulate", false)), "cut %d cannot start simulation" % cut)
		var disk := _read(f.meta.active_meta_progress_path)
		if cut == 1:
			_require(f.meta.data == before, "prepare failure restores entire meta memory")
			_require(disk.get("admission", {}).is_empty(), "before prepared no durable reservation")
		else:
			_require(str(disk.get("admission", {}).get("phase", "")) == "prepared", "cut %d preserves durable prepared" % cut)
			_require(f.meta.get_summary().get("reserved_instance_ids", []) == ["reserved-material"], "cut %d reserves original identity" % cut)
		_require(FileAccess.file_exists(f.service.checkpoint_path) == (cut == 3), "checkpoint existence at cut %d" % cut)
		if cut == 3:
			var prepared_load: Dictionary = f.service.load_checkpoint()
			_require(bool(prepared_load.get("ok", false)) and not bool(prepared_load.get("can_simulate", true)), "prepared checkpoint loads without simulation authority")
		var restarted := _restart(f)
		if cut == 1:
			_require(not bool(restarted.service.recover_admission().get("can_simulate", false)), "missing admission never auto-starts")
			result = restarted.service.begin_admission(f.snapshot, ["reserved-material"])
		else:
			result = restarted.service.recover_admission()
		_require(bool(result.get("ok", false)) and bool(result.get("can_simulate", false)), "resume cut %d to active: %s" % [cut, result])
		_require(int(result.get("generation", -1)) == 0, "resume cut %d only generation zero" % cut)
		var cp_bytes := FileAccess.get_file_as_string(restarted.service.checkpoint_path)
		var meta_bytes := FileAccess.get_file_as_string(restarted.meta.active_meta_progress_path)
		result = restarted.service.begin_admission(f.snapshot, ["reserved-material"])
		_require(bool(result.get("ok", false)), "same run admission idempotent")
		_require(cp_bytes == FileAccess.get_file_as_string(restarted.service.checkpoint_path) and meta_bytes == FileAccess.get_file_as_string(restarted.meta.active_meta_progress_path), "duplicate admission performs no writes")
		var other: Dictionary = f.snapshot.duplicate(true)
		other["run_id"] = "run-2"
		_require(not bool(restarted.service.begin_admission(other, []).get("ok", true)), "different active run rejected")


func _test_complete_checkpoint_and_rollback() -> void:
	# Break caught: partial snapshots, failed replace overwrites, revision conflicts, wall-clock progression on load.
	var f := _fixture("complete")
	_require(bool(f.service.begin_admission(f.snapshot, ["reserved-material"]).get("ok", false)), "admit complete fixture")
	var next: Dictionary = f.snapshot.duplicate(true)
	next["revision"] = 1
	next.state.context.hp = 12
	next.state.combat.enemies[0].hp = 4
	next.state.events.shared.dice_candidates = [6, 1, 3]
	next.state["salvage_pending"] = true
	f.adapter.fail_commit = f.adapter.commit_count + 1
	var previous_bytes := FileAccess.get_file_as_string(f.service.checkpoint_path)
	_require(not bool(f.service.save_checkpoint(next).get("ok", true)), "failed checkpoint commit reports failure")
	_require(previous_bytes == FileAccess.get_file_as_string(f.service.checkpoint_path), "failed replace preserves durable snapshot bytes")
	var restarted := _restart(f)
	_require(_same_json(restarted.service.load_checkpoint().get("snapshot", {}), f.snapshot), "restart after failed action restores full preceding snapshot")
	_require(bool(restarted.service.save_checkpoint(next).get("ok", false)), "retry next checkpoint")
	var restored := _restart(restarted)
	var result: Dictionary = restored.service.load_checkpoint()
	_require(_same_json(result.get("snapshot", {}), next), "context/combat/events/RNG/facts/receipts survive disk reload")
	_require(int(result.get("generation", -1)) == 1, "successful checkpoint increments generation")
	_require(_same_json(restored.service.load_checkpoint().get("snapshot", {}), next), "repeated load leaves offline clock frozen")
	_require(bool(restored.service.save_checkpoint(next).get("ok", false)), "same revision and payload is idempotent")
	var changed: Dictionary = next.duplicate(true)
	changed.state.context.hp = 99
	_require(not bool(restored.service.save_checkpoint(changed).get("ok", true)), "same revision different snapshot rejects")
	_require(not bool(restored.service.save_checkpoint(f.snapshot).get("ok", true)), "older revision cannot roll back")
	changed = next.duplicate(true)
	changed["revision"] = 2
	changed["bad_vector"] = Vector2(1, 2)
	_require(not bool(restored.service.save_checkpoint(changed).get("ok", true)), "non JSON-safe snapshot rejects")


func _test_reservations_and_references() -> void:
	# Break caught: reserved items available to a second deployment, sale, research or colliding purchase.
	var f := _fixture("reserved")
	_require(not bool(f.service.begin_admission(f.snapshot, ["missing"]).get("ok", true)), "cannot reserve nonexistent identity")
	_require(not bool(f.service.begin_admission(f.snapshot, ["reserved-material", "reserved-material"]).get("ok", true)), "duplicate reservation rejects")
	_require(bool(f.service.begin_admission(f.snapshot, ["reserved-material"]).get("ok", false)), "reserve actual warehouse material")
	var summary: Dictionary = f.meta.get_summary()
	_require(summary.get("reserved_instance_ids", []) == ["reserved-material"], "summary exposes reserved identities")
	for item in summary.warehouse_items:
		_require(item.instance_id != "reserved-material", "reserved identity excluded from available warehouse")
	_require(not bool(f.meta.sell_collectible("reserved-material").get("ok", true)), "single sale cannot consume reservation")
	_require(not bool(f.meta.sell_collectibles_batch(["reserved-material"]).get("ok", true)), "batch sale cannot consume reservation")
	_require(not bool(f.meta.complete_research("research_anomaly_structure").get("ok", true)), "research cannot consume reservation")
	_require(bool(f.meta.purchase_item("con_ration").get("ok", false)), "purchase independent item while reserved")
	var reloaded := _restart(f)
	_require(reloaded.meta.get_summary().get("reserved_instance_ids", []) == ["reserved-material"], "purchase/save/reload preserves admission")
	for field in ["profile_id", "run_id", "ruleset_id", "content_version", "schema_version"]:
		var changed: Dictionary = f.snapshot.duplicate(true)
		changed["revision"] = 1
		changed[field] = 999 if field == "schema_version" else "wrong"
		_require(not bool(reloaded.service.save_checkpoint(changed).get("ok", true)), "checkpoint rejects mismatched " + field)
	_require(not bool(reloaded.service.load_checkpoint("another-profile").get("ok", true)), "cross-profile load rejects")
	var g := _fixture("separate")
	_require(not bool(g.service.load_checkpoint().get("can_simulate", false)), "unrelated profile has no active run")
	var manager = ManagerScript.new()
	manager.active_profile_id = "separate"
	_require(not bool(manager.configure_checkpoint_service(g.service, f.meta).get("ok", true)), "manager refuses mismatched meta profile")


func _test_recovery_guards() -> void:
	# Break caught: active corruption resets initial state, unknown formats overwritten, prepared advances beyond generation zero.
	for kind in ["missing", "corrupt", "future", "unknown", "foreign", "checksum", "revision"]:
		var f := _fixture("guard-" + kind)
		_require(bool(f.service.begin_admission(f.snapshot, []).get("ok", false)), kind + ": admit")
		var next: Dictionary = f.snapshot.duplicate(true)
		next["revision"] = 1
		next.state.context.hp = 19
		_require(bool(f.service.save_checkpoint(next).get("ok", false)), kind + ": advance")
		_remove(f.service.checkpoint_path + ".bak")
		var envelope := _read(f.service.checkpoint_path)
		match kind:
			"missing": _remove(f.service.checkpoint_path)
			"corrupt": _write_text(f.service.checkpoint_path, "{broken")
			"future": envelope["schema_version"] = 999
			"unknown": envelope["format"] = "foreign-format"
			"foreign": envelope["profile_id"] = "foreign-profile"
			"checksum": envelope.snapshot.state.context.hp = 999
			"revision": envelope["revision"] = 73
		if kind not in ["missing", "corrupt"]:
			_write(f.service.checkpoint_path, envelope)
		var before := FileAccess.get_file_as_string(f.service.checkpoint_path) if FileAccess.file_exists(f.service.checkpoint_path) else ""
		var restarted := _restart(f)
		var result: Dictionary = restarted.service.recover_admission()
		_require(not bool(result.get("ok", true)) and not bool(result.get("can_simulate", false)), kind + ": active requires recovery error")
		_require(not bool(restarted.service.save_checkpoint(next).get("ok", true)), kind + ": refuse write over invalid active checkpoint")
		var after := FileAccess.get_file_as_string(f.service.checkpoint_path) if FileAccess.file_exists(f.service.checkpoint_path) else ""
		_require(before == after, kind + ": invalid primary unchanged")
	var f := _fixture("backup")
	_require(bool(f.service.begin_admission(f.snapshot, []).get("ok", false)), "backup: admit")
	var next: Dictionary = f.snapshot.duplicate(true)
	next["revision"] = 1
	next.state.context.hp = 18
	_require(bool(f.service.save_checkpoint(next).get("ok", false)), "backup: revision one")
	next["revision"] = 2
	next.state.context.hp = 8
	_require(bool(f.service.save_checkpoint(next).get("ok", false)), "backup: revision two")
	_write_text(f.service.checkpoint_path, "{broken")
	var result: Dictionary = _restart(f).service.recover_admission()
	_require(bool(result.get("ok", false)) and int(result.get("revision", -1)) == 1 and int(result.get("snapshot", {}).get("state", {}).get("context", {}).get("hp", -1)) == 18, "active corruption recovers validated previous checkpoint, not initial")
	var recovered := _restart(f)
	var backup_bytes := FileAccess.get_file_as_string(f.service.checkpoint_path + ".bak")
	_require(str(result.get("status", "")) == "recovered_backup" and not str(result.get("snapshot_hash", "")).is_empty(), "backup recovery exposes original hash/generation")
	var future_snapshot: Dictionary = next.duplicate(true)
	future_snapshot["revision"] = 3
	_require(not bool(recovered.service.save_checkpoint(future_snapshot).get("ok", true)), "future revision cannot silently overwrite recovered backup")
	_require(FileAccess.get_file_as_string(f.service.checkpoint_path + ".bak") == backup_bytes, "rejected future write preserves backup")
	_require(not bool(recovered.service.confirm_checkpoint_recovery(99, "wrong").get("ok", true)), "recovery confirmation binds exact generation/hash")
	_require(bool(recovered.service.confirm_checkpoint_recovery(int(result.get("generation", -1)), str(result.get("snapshot_hash", ""))).get("ok", false)), "explicit recovery repairs selected snapshot")
	_require(int(recovered.service.load_checkpoint().get("revision", -1)) == 1, "recovery repair never increments revision")
	_require(not bool(recovered.service.save_checkpoint(future_snapshot).get("ok", true)), "repaired checkpoint rejects skipped revision")
	_require(bool(recovered.service.save_checkpoint(next).get("ok", false)), "restored next revision can persist")
	var future_backup := _read(f.service.checkpoint_path)
	future_backup["schema_version"] = 999
	_write(f.service.checkpoint_path, future_backup)
	_require(not bool(_restart(f).service.recover_admission().get("ok", true)), "future primary never falls back to old backup")
	var prepared := _fixture("prepared-tamper")
	prepared.adapter.fail_commit = 3
	prepared.service.begin_admission(prepared.snapshot, [])
	var bad := _read(prepared.service.checkpoint_path)
	bad["generation"] = 1
	_write(prepared.service.checkpoint_path, bad)
	_require(not bool(_restart(prepared).service.recover_admission().get("ok", true)), "prepared with later generation never activates")
	var custom := _fixture("content-version")
	custom.meta.data["content_version"] = "z2-t00-t04-20261115"
	_require(custom.meta.save(), "custom version fixture saved")
	custom.snapshot["content_version"] = "z2-t00-t04-20261115"
	custom.snapshot["content_hash"] = "parent-owned-content-hash"
	_require(bool(custom.service.configure(custom.meta, "z2", "z2-t00-t04-20261115").get("ok", false)), "configure supplied content version")
	_require(bool(custom.service.begin_admission(custom.snapshot, []).get("ok", false)), "admission honors supplied content version")
	_require(custom.service.load_checkpoint().get("snapshot", {}).get("content_hash", "") == "parent-owned-content-hash", "opaque content hash round-trips")


func _test_terminal_receipts() -> void:
	# Break caught: duplicate rewards, lost salvage, premature cleanup, failed save mutates meta memory.
	var f := _fixture("terminal")
	_require(bool(f.service.begin_admission(f.snapshot, ["reserved-material"]).get("ok", false)), "terminal: admit")
	var pending := {"profile_id": "terminal", "run_id": "run-1", "outcome": "Failed", "settlement": {"outcome": "failure", "requires_salvage_selection": true, "finalized": false}}
	_require(str(f.service.apply_settlement(pending).get("status", "")) == "awaiting_salvage_selection", "preserve pending salvage")
	_require(bool(_restart(f).service.load_checkpoint().get("can_simulate", false)), "salvage pending preserves checkpoint and admission")
	var terminal := {"profile_id": "terminal", "run_id": "run-1", "result_id": "terminal-1", "outcome": "Extracted", "settlement": {"outcome": "success", "gold_coin_gained": 7, "warehouse_lite": []}}
	var before: Dictionary = f.meta.data.duplicate(true)
	f.adapter.fail_commit = f.adapter.commit_count + 1
	_require(not bool(f.service.apply_settlement(terminal).get("ok", true)), "failed settlement reports failure")
	_require(f.meta.data == before, "failed settlement restores complete meta and reservations")
	_require(FileAccess.file_exists(f.service.checkpoint_path), "failed settlement leaves checkpoint")
	f.adapter.fail_cleanup = true
	var committed: Dictionary = f.service.apply_settlement(terminal)
	_require(bool(committed.get("ok", false)), "terminal receipt committed despite cleanup failure")
	_require(int(f.meta.data.gold) == 507 and int(f.meta.data.run_count) == 1, "terminal awards exactly once")
	_require(FileAccess.file_exists(f.service.checkpoint_path), "cleanup failure preserves leftover checkpoint")
	var terminal_load: Dictionary = f.service.load_checkpoint()
	_require(terminal_load.get("status", "") == "settled" and not bool(terminal_load.get("can_simulate", true)), "read-only checkpoint load gives terminal receipt authority")
	var same_key_conflict: Dictionary = terminal.duplicate(true)
	same_key_conflict["outcome"] = "Failed"
	_require(not bool(f.service.apply_settlement(same_key_conflict).get("ok", true)), "same terminal result key with changed outcome rejects")
	var restarted := _restart(f)
	var recovered: Dictionary = restarted.service.recover_admission()
	_require(not bool(recovered.get("can_simulate", false)) and str(recovered.get("status", "")) == "settled", "receipt authoritative over leftover checkpoint")
	_require(not FileAccess.file_exists(restarted.service.checkpoint_path) and not FileAccess.file_exists(restarted.service.checkpoint_path + ".bak"), "recovery retries checkpoint and backup cleanup")
	var duplicate: Dictionary = restarted.service.apply_settlement(terminal)
	_require(bool(duplicate.get("ok", false)) and duplicate.get("result_id", "") == committed.get("result_id", "") and duplicate.get("outcome", "") == committed.get("outcome", ""), "identical terminal payload returns original durable result")
	var changed: Dictionary = terminal.duplicate(true)
	changed["result_id"] = "different-result"
	changed["outcome"] = "Failed"
	_require(not bool(restarted.service.apply_settlement(changed).get("ok", true)), "changed outcome rejected despite different result ID")
	_require(int(restarted.meta.data.gold) == 507 and int(restarted.meta.data.run_count) == 1, "duplicate/conflicting results never re-award")
	_require(not bool(restarted.service.begin_admission(f.snapshot, ["reserved-material"]).get("can_simulate", false)), "settled run cannot re-open")
	var next_run: Dictionary = f.snapshot.duplicate(true)
	next_run["run_id"] = "run-2"
	_require(bool(restarted.service.begin_admission(next_run, []).get("ok", false)), "new run can start after terminal cleanup")
	_require(not bool(restarted.service.apply_settlement(changed).get("ok", true)), "old conflict cannot affect new run")
	_require(bool(restarted.service.load_checkpoint().get("can_simulate", false)), "old terminal retry cannot delete new checkpoint")


func _test_old_and_unknown_profiles() -> void:
	# Break caught: implicit migration overwrites legacy progress, unknown format overwritten, fields lost in normalization.
	var adapter := SaveScript.new()
	_require(int(adapter.default_meta_progress().schema_version) == 5 and not adapter.default_meta_progress().has("ruleset_id"), "legacy default schema stays compatible")
	for kind in ["legacy", "future", "unknown-ruleset", "unknown-admission"]:
		var path: String = root_path + "/format-" + kind + "/meta_progress.json"
		var data: Dictionary = adapter.default_meta_progress()
		data["gold"] = 911
		if kind == "future": data["schema_version"] = 999
		if kind == "unknown-ruleset": data["ruleset_id"] = "future-rules"
		if kind == "unknown-admission":
			data.merge({"ruleset_id": "z2", "profile_id": "format-" + kind, "content_version": "z2", "run_receipts": {}, "admission": {"schema_version": 999, "phase": "future"}}, true)
		_write(path, data)
		var before := FileAccess.get_file_as_string(path)
		var meta = MetaScript.new()
		meta.set_active_profile_path(path, "format-" + kind)
		_require(not bool(meta.initialize_z2_profile().get("ok", true)), kind + ": refuses silent Z2 migration")
		if kind != "legacy": _require(not meta.save(), kind + ": unknown format refuses writes")
		_require(before == FileAccess.get_file_as_string(path), kind + ": bytes unchanged")


func _test_recovery_and_receipt_edge_cases() -> void:
	# Break caught: legacy result_id dedup suppresses a distinct run's reward.
	var f := _fixture("receipt-scope")
	_require(bool(f.service.begin_admission(f.snapshot, []).get("ok", false)), "receipt-scope: first run")
	var result := {"run_id": "run-1", "result_id": "same-result-id", "outcome": "Extracted", "settlement": {"outcome": "success", "gold_coin_gained": 7}}
	var first: Dictionary = f.meta.apply_settlement(result)
	_require(bool(first.get("ok", false)), "receipt-scope: first settlement")
	_require(_same_json(_restart(f).meta.apply_settlement(result), first), "direct meta retry returns exactly the original durable receipt")
	var next: Dictionary = f.snapshot.duplicate(true)
	next["run_id"] = "run-2"
	_require(bool(f.service.begin_admission(next, []).get("ok", false)), "receipt-scope: distinct run")
	result["run_id"] = "run-2"
	_require(bool(f.service.apply_settlement(result).get("ok", false)), "receipt-scope: distinct settlement")
	_require(int(f.meta.data.run_count) == 2 and int(f.meta.data.gold) == 514, "distinct run uses run identity even with reused legacy result_id")
	# Break caught: a corrupt active marker falling back to prepared recreates initial state.
	var lost := _fixture("lost-active-meta")
	_require(bool(lost.service.begin_admission(lost.snapshot, []).get("ok", false)), "lost-active-meta: admit")
	_write_text(lost.meta.active_meta_progress_path, "{broken")
	_remove(lost.service.checkpoint_path)
	var loaded := _restart(lost)
	_require(not bool(loaded.service.recover_admission().get("can_simulate", false)), "recovered prepared meta cannot prove no active actions; never reconstruct")
	_require(not FileAccess.file_exists(lost.service.checkpoint_path), "ambiguous meta recovery never recreates initial checkpoint")
	# Break caught: legacy normalization silently upgrades an unsupported Z2 schema.
	var unknown := _fixture("old-z2-schema")
	var meta_data := _read(unknown.meta.active_meta_progress_path)
	meta_data["schema_version"] = 4
	_write(unknown.meta.active_meta_progress_path, meta_data)
	var meta = MetaScript.new()
	meta.set_active_profile_path(unknown.meta.active_meta_progress_path, "old-z2-schema")
	_require(not meta.can_write_persistence(), "unsupported Z2 schema is blocked before legacy normalization")
	# Break caught: a generated purchase identity duplicates an existing reserved warehouse record.
	var collision := _fixture("purchase-collision")
	collision.meta.data.warehouse_items.append({"instance_id": "m7:m7_base_shop:000001:con_ration", "item_id": "con_ration", "item_type": "consumable"})
	_require(collision.meta.save(), "purchase-collision: fixture")
	_require(bool(collision.service.begin_admission(collision.snapshot, ["m7:m7_base_shop:000001:con_ration"]).get("ok", false)), "purchase-collision: reserve")
	var before: Dictionary = collision.meta.data.duplicate(true)
	_require(not bool(collision.meta.purchase_item("con_ration").get("ok", true)), "purchase cannot duplicate reserved identity")
	_require(collision.meta.data == before, "purchase collision rolls back all metadata")
	# Break caught: prepared plus corrupt backup is mistaken for a genuinely absent checkpoint.
	var damaged := _fixture("damaged-prepared-backup")
	damaged.adapter.fail_commit = 2
	damaged.service.begin_admission(damaged.snapshot, [])
	_write_text(damaged.service.checkpoint_path + ".bak", "{broken")
	_require(not bool(_restart(damaged).service.recover_admission().get("ok", true)), "damaged prepared backup is not missing checkpoint")
	_require(not FileAccess.file_exists(damaged.service.checkpoint_path), "damaged backup never reset to initial")
	# Break caught: changing reservation identities to other valid items breaks the admission/checkpoint binding.
	var binding := _fixture("reservation-binding")
	_require(bool(binding.service.begin_admission(binding.snapshot, ["reserved-material"]).get("ok", false)), "reservation-binding: admit")
	var altered := _read(binding.meta.active_meta_progress_path)
	altered.admission.reserved_instance_ids = ["m6_starter:eq_goggles:1"]
	_write(binding.meta.active_meta_progress_path, altered)
	_require(not bool(_restart(binding).service.recover_admission().get("ok", true)), "checkpoint binds original reservation identities")


func _read(path: String) -> Dictionary:
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}


func _write(path: String, value: Dictionary) -> void:
	_write_text(path, JSON.stringify(value))


func _write_text(path: String, value: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	_require(file != null, "fixture file opens: " + path)
	if file != null:
		file.store_string(value)
		file.close()


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		_require(DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK, "fixture file removed: " + path)


func _same_json(actual: Variant, expected: Variant) -> bool:
	# JSON has one number kind; Godot's nested Dictionary equality distinguishes int/float.
	if (actual is int or actual is float) and (expected is int or expected is float):
		return actual == expected
	if actual is Dictionary and expected is Dictionary:
		if actual.size() != expected.size():
			return false
		for key in expected:
			if not actual.has(key) or not _same_json(actual[key], expected[key]):
				return false
		return true
	if actual is Array and expected is Array:
		if actual.size() != expected.size():
			return false
		for index in range(expected.size()):
			if not _same_json(actual[index], expected[index]):
				return false
		return true
	return typeof(actual) == typeof(expected) and actual == expected


func _require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
