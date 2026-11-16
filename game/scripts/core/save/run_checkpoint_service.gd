extends RefCounted
class_name RunCheckpointService

const SaveAdapterScript := preload("res://scripts/core/save/save_adapter.gd")
const FORMAT := "graytail_run_checkpoint"
const SCHEMA_VERSION := 1

var save_adapter: SaveAdapter = SaveAdapterScript.new()
var meta_adapter: MetaProgressAdapter
var profile_id := ""
var checkpoint_path := ""
var ruleset_id := "z2"
var content_version := "z2"
var last_error := ""


func configure(adapter: MetaProgressAdapter, expected_ruleset: String = "z2", expected_content: String = "z2") -> Dictionary:
	meta_adapter = adapter
	ruleset_id = expected_ruleset
	content_version = expected_content
	profile_id = adapter.active_profile_id if adapter != null else ""
	checkpoint_path = adapter.active_meta_progress_path.get_base_dir().path_join("run_checkpoint.json") if adapter != null else ""
	var error := _profile_error()
	if not error.is_empty():
		return _failure(error)
	return {"ok": true, "status": "configured", "profile_id": profile_id, "checkpoint_path": checkpoint_path}


func begin_admission(snapshot: Dictionary, reserved_ids: Array = []) -> Dictionary:
	var error := _profile_error()
	if error.is_empty():
		error = _snapshot_error(snapshot)
	if not error.is_empty():
		return _failure(error)
	if int(snapshot.revision) != 0:
		return _failure("initial_revision_required")
	var run_id: String = snapshot.run_id
	if _receipts().has(run_id):
		return _settled(run_id, true)
	var ids: Array = reserved_ids.duplicate()
	for id in ids:
		if not id is String or str(id).is_empty() or ids.count(id) != 1:
			return _failure("invalid_reserved_identity")
	ids.sort()
	var admission := _admission()
	if not admission.is_empty():
		if admission.get("run_id", "") != run_id:
			return _failure("active_run_exists")
		if admission.get("initial_snapshot_hash", "") != SaveAdapterScript.json_fingerprint(snapshot) or admission.get("reserved_instance_ids", []) != ids:
			return _failure("admission_conflict")
		return recover_admission()
	var cleanup_id := str(meta_adapter.data.get("checkpoint_cleanup_run_id", ""))
	if not cleanup_id.is_empty():
		var cleanup := _settled(cleanup_id, true)
		if bool(cleanup.get("cleanup_pending", false)):
			return _failure("checkpoint_cleanup_required")
	for suffix in ["", SaveAdapterScript.LAST_VALID_BACKUP_SUFFIX]:
		if FileAccess.file_exists(checkpoint_path + str(suffix)):
			return _failure("orphan_checkpoint")
	error = _reservation_error(ids)
	if not error.is_empty():
		return _failure(error)
	admission = {
		"schema_version": SCHEMA_VERSION, "phase": "prepared", "profile_id": profile_id,
		"run_id": run_id, "ruleset_id": ruleset_id, "content_version": content_version,
		"snapshot_schema_version": SCHEMA_VERSION, "reserved_instance_ids": ids,
		"initial_snapshot": snapshot.duplicate(true), "initial_snapshot_hash": SaveAdapterScript.json_fingerprint(snapshot),
	}
	admission["admission_hash"] = _admission_hash(admission)
	var prepared := meta_adapter.commit_admission(admission)
	if not bool(prepared.get("ok", false)):
		return _failure(str(prepared.get("status", "save_failed")), str(prepared.get("error", "")))
	return recover_admission()


func recover_admission() -> Dictionary:
	var error := _profile_error()
	if not error.is_empty():
		return _failure(error)
	var admission := _admission()
	if admission.is_empty():
		var cleanup_id := str(meta_adapter.data.get("checkpoint_cleanup_run_id", ""))
		return _settled(cleanup_id, true) if _receipts().has(cleanup_id) else _failure("no_admission")
	var run_id := str(admission.get("run_id", ""))
	if _receipts().has(run_id):
		return _settled(run_id, true)
	error = _admission_error(admission)
	if not error.is_empty():
		return _failure(error)
	var loaded := load_checkpoint()
	if admission.phase == "active":
		return loaded
	if not bool(loaded.get("ok", false)):
		if loaded.get("status", "") != "checkpoint_missing":
			return loaded
		var initial: Dictionary = admission.initial_snapshot
		if not save_adapter.save_json(_envelope(initial, 0, admission), checkpoint_path, false):
			return _failure("save_failed", save_adapter.last_error)
		loaded = load_checkpoint()
	if not bool(loaded.get("ok", false)):
		return loaded
	if loaded.get("status", "") == "recovered_backup":
		return _failure("checkpoint_recovery_required")
	var active := admission.duplicate(true)
	active["phase"] = "active"
	active["initial_checkpoint_hash"] = str(loaded.snapshot_hash)
	var committed := meta_adapter.commit_admission(active)
	if not bool(committed.get("ok", false)):
		return _failure(str(committed.get("status", "save_failed")), str(committed.get("error", "")))
	return load_checkpoint()


func load_checkpoint(requested_profile_id: String = "") -> Dictionary:
	var error := _profile_error()
	if not error.is_empty():
		return _failure(error)
	if requested_profile_id != "" and requested_profile_id != profile_id:
		return _failure("profile_mismatch")
	var admission := _admission()
	if admission.is_empty():
		var cleanup_id := str(meta_adapter.data.get("checkpoint_cleanup_run_id", ""))
		return _settled(cleanup_id, false) if _receipts().has(cleanup_id) else _failure("no_admission")
	if _receipts().has(str(admission.get("run_id", ""))):
		return _settled(str(admission.run_id), false)
	error = _admission_error(admission)
	if not error.is_empty():
		return _failure(error)
	var loaded := save_adapter.load_json_result(checkpoint_path, {"schema_version": SCHEMA_VERSION}, false)
	if not bool(loaded.get("ok", false)):
		return _failure(str(loaded.get("status", "checkpoint_invalid")), str(loaded.get("error", "")))
	if loaded.get("status", "") == "missing":
		return _failure("checkpoint_missing")
	var envelope: Dictionary = loaded.get("data", {})
	error = _envelope_error(envelope, admission)
	if not error.is_empty():
		return _failure(error)
	last_error = ""
	return {
		"ok": true, "status": str(loaded.status), "can_simulate": admission.phase == "active",
		"profile_id": profile_id, "run_id": str(admission.run_id), "phase": str(admission.phase),
		"snapshot": envelope.snapshot.duplicate(true), "generation": int(envelope.generation),
		"revision": int(envelope.revision), "snapshot_hash": str(envelope.snapshot_hash),
		"initial_snapshot_hash": str(envelope.initial_snapshot_hash),
		"recovery_path": str(loaded.get("recovery_path", "")), "error": "",
	}


func save_checkpoint(snapshot: Dictionary) -> Dictionary:
	var loaded := load_checkpoint()
	if not bool(loaded.get("ok", false)) or not bool(loaded.get("can_simulate", false)):
		return loaded if not bool(loaded.get("ok", false)) else _failure("active_admission_required")
	if loaded.get("status", "") == "recovered_backup":
		return _failure("checkpoint_recovery_required")
	var error := _snapshot_error(snapshot, str(loaded.run_id))
	if not error.is_empty():
		return _failure(error)
	var fingerprint := SaveAdapterScript.json_fingerprint(snapshot)
	var revision := int(snapshot.revision)
	if revision == int(loaded.revision) and fingerprint == loaded.snapshot_hash:
		loaded["status"] = "duplicate"
		return loaded
	if revision != int(loaded.revision) + 1:
		return _failure("checkpoint_revision_conflict")
	var envelope := _envelope(snapshot, int(loaded.generation) + 1, _admission())
	if not save_adapter.save_json(envelope, checkpoint_path, false):
		return _failure("save_failed", save_adapter.last_error)
	return load_checkpoint()


func confirm_checkpoint_recovery(generation: int, snapshot_hash: String) -> Dictionary:
	var loaded := load_checkpoint()
	if not bool(loaded.get("ok", false)):
		return loaded
	if int(loaded.get("generation", -1)) != generation or loaded.get("snapshot_hash", "") != snapshot_hash:
		return _failure("checkpoint_recovery_conflict")
	if loaded.get("status", "") != "recovered_backup":
		return loaded
	var envelope := _envelope(loaded.snapshot, generation, _admission())
	if not save_adapter.save_json(envelope, checkpoint_path, false):
		return _failure("save_failed", save_adapter.last_error)
	var repaired := load_checkpoint()
	repaired["recovered"] = true
	return repaired


func apply_settlement(result_snapshot: Dictionary) -> Dictionary:
	var error := _profile_error()
	if not error.is_empty():
		return _failure(error)
	var result := meta_adapter.apply_settlement(result_snapshot)
	if not bool(result.get("ok", false)):
		return result
	var run_id := str(result_snapshot.get("run_id", ""))
	if _receipts().has(run_id):
		var settled := _settled(run_id, true)
		result["cleanup_pending"] = bool(settled.get("cleanup_pending", false))
		if bool(result.cleanup_pending):
			result["cleanup_error"] = str(settled.get("cleanup_error", ""))
	return result


func _envelope(snapshot: Dictionary, generation: int, admission: Dictionary) -> Dictionary:
	return {
		"format": FORMAT, "schema_version": SCHEMA_VERSION, "profile_id": profile_id,
		"run_id": str(snapshot.run_id), "ruleset_id": ruleset_id, "content_version": content_version,
		"snapshot_schema_version": SCHEMA_VERSION, "generation": generation, "revision": int(snapshot.revision),
		"initial_snapshot_hash": str(admission.initial_snapshot_hash),
		"admission_hash": str(admission.admission_hash),
		"snapshot_hash": SaveAdapterScript.json_fingerprint(snapshot), "snapshot": snapshot.duplicate(true),
	}


func _profile_error() -> String:
	if meta_adapter == null or profile_id.is_empty() or checkpoint_path.is_empty():
		return "checkpoint_service_not_configured"
	if meta_adapter.active_profile_id != profile_id or meta_adapter.active_meta_progress_path.get_base_dir().path_join("run_checkpoint.json") != checkpoint_path:
		return "profile_mismatch"
	if not meta_adapter.can_write_persistence():
		return "meta_write_blocked"
	if ruleset_id != "z2" or meta_adapter.data.get("ruleset_id", "") != ruleset_id:
		return "z2_profile_required"
	if meta_adapter.data.get("profile_id", "") != profile_id or content_version.is_empty() or meta_adapter.data.get("content_version", "") != content_version:
		return "profile_reference_mismatch"
	return SaveAdapterScript.z2_meta_error(meta_adapter.data)


func _snapshot_error(snapshot: Dictionary, expected_run_id: String = "") -> String:
	if not SaveAdapterScript.is_json_safe(snapshot):
		return "snapshot_not_json_safe"
	if snapshot.get("schema_version") != SCHEMA_VERSION:
		return "snapshot_schema_mismatch"
	if snapshot.get("profile_id") != profile_id or snapshot.get("ruleset_id") != ruleset_id or snapshot.get("content_version") != content_version:
		return "snapshot_reference_mismatch"
	if not snapshot.get("run_id") is String or str(snapshot.run_id).is_empty() or (expected_run_id != "" and snapshot.run_id != expected_run_id):
		return "snapshot_run_mismatch"
	if not SaveAdapterScript.is_nonnegative_integer(snapshot.get("revision")):
		return "invalid_snapshot_revision"
	if not snapshot.get("state") is Dictionary or snapshot.state.is_empty():
		return "complete_snapshot_required"
	return ""


func _admission_error(admission: Dictionary) -> String:
	# A prepared backup of a lost active meta marker is indistinguishable from
	# an interrupted activation. Never reconstruct generation zero in that case.
	if admission.get("phase") == "prepared" and meta_adapter.last_load_status == "recovered_backup":
		return "prepared_meta_recovery_ambiguous"
	if admission.get("admission_hash", "") != _admission_hash(admission):
		return "admission_hash_mismatch"
	var initial: Dictionary = admission.get("initial_snapshot", {})
	var error := _snapshot_error(initial, str(admission.get("run_id", "")))
	if not error.is_empty():
		return error
	if initial.get("revision") != 0 or admission.get("initial_snapshot_hash", "") != SaveAdapterScript.json_fingerprint(initial):
		return "admission_initial_binding_mismatch"
	return _reservation_error(admission.get("reserved_instance_ids", []))


func _admission_hash(admission: Dictionary) -> String:
	var identity := admission.duplicate(true)
	for key in ["phase", "initial_snapshot", "initial_checkpoint_hash", "admission_hash"]:
		identity.erase(key)
	return SaveAdapterScript.json_fingerprint(identity)


func _reservation_error(ids: Array) -> String:
	for id in ids:
		if not id is String or str(id).is_empty() or ids.count(id) != 1:
			return "invalid_reserved_identity"
		var count := 0
		for raw_item in meta_adapter.data.get("warehouse_items", []):
			if raw_item is Dictionary and raw_item.get("instance_id", "") == id:
				count += 1
		if count != 1:
			return "reserved_identity_missing_or_duplicated"
	return ""


func _envelope_error(envelope: Dictionary, admission: Dictionary) -> String:
	if envelope.get("format") != FORMAT or envelope.get("schema_version") != SCHEMA_VERSION:
		return "unknown_checkpoint_format"
	for key in ["profile_id", "run_id", "ruleset_id", "content_version", "snapshot_schema_version", "initial_snapshot_hash", "admission_hash"]:
		if envelope.get(key) != admission.get(key):
			return "checkpoint_reference_mismatch"
	if not SaveAdapterScript.is_nonnegative_integer(envelope.get("generation")) or not SaveAdapterScript.is_nonnegative_integer(envelope.get("revision")):
		return "invalid_checkpoint_revision"
	if not envelope.get("snapshot") is Dictionary:
		return "invalid_checkpoint_snapshot"
	var error := _snapshot_error(envelope.snapshot, str(admission.run_id))
	if not error.is_empty():
		return error
	if envelope.revision != envelope.snapshot.revision or envelope.generation != envelope.revision:
		return "checkpoint_revision_mismatch"
	if envelope.get("snapshot_hash", "") != SaveAdapterScript.json_fingerprint(envelope.snapshot):
		return "checkpoint_hash_mismatch"
	if int(envelope.generation) == 0 and envelope.snapshot_hash != admission.initial_snapshot_hash:
		return "initial_checkpoint_mismatch"
	if admission.phase == "prepared" and (int(envelope.generation) != 0 or int(envelope.revision) != 0):
		return "prepared_checkpoint_advanced"
	return ""


func _settled(run_id: String, cleanup: bool) -> Dictionary:
	var receipt: Dictionary = _receipts().get(run_id, {})
	if receipt.is_empty():
		return _failure("run_receipt_missing")
	var result := {"ok": true, "status": "settled", "can_simulate": false, "run_id": run_id, "receipt": receipt.duplicate(true), "cleanup_pending": false}
	var admission := _admission()
	# A late duplicate from an older run must never delete the new run's checkpoint.
	if not admission.is_empty() and admission.get("run_id", "") != run_id:
		return result
	if str(meta_adapter.data.get("checkpoint_cleanup_run_id", "")) != run_id:
		return result
	if cleanup:
		for suffix in ["", SaveAdapterScript.LAST_VALID_BACKUP_SUFFIX]:
			var path := checkpoint_path + str(suffix)
			var raw := save_adapter._read_json_file(path)
			if bool(raw.get("ok", false)):
				var envelope: Dictionary = raw.data
				if envelope.get("format") != FORMAT or envelope.get("schema_version") != SCHEMA_VERSION or envelope.get("run_id") != run_id or envelope.get("profile_id") != profile_id:
					result["cleanup_pending"] = true
					result["cleanup_error"] = "unknown_checkpoint_cleanup_blocked"
					return result
		if not save_adapter.remove_json(checkpoint_path):
			result["cleanup_pending"] = true
			result["cleanup_error"] = save_adapter.last_error
	return result


func _admission() -> Dictionary:
	return meta_adapter.data.get("admission", {}).duplicate(true)


func _receipts() -> Dictionary:
	return meta_adapter.data.get("run_receipts", {})


func _failure(status: String, error: String = "") -> Dictionary:
	last_error = error if not error.is_empty() else status
	return {"ok": false, "status": status, "error": last_error, "can_simulate": false, "profile_id": profile_id}
