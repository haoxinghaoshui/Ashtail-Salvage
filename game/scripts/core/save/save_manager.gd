extends RefCounted
class_name SaveManager

const SaveAdapterScript := preload("res://scripts/core/save/save_adapter.gd")
const SaveProfileManifestScript := preload("res://scripts/core/save/save_profile_manifest.gd")
const SaveProfilePreviewScript := preload("res://scripts/core/save/save_profile_preview.gd")
const SaveImportStagingScript := preload("res://scripts/core/save/save_import_staging.gd")
const Z2Rules := preload("res://scripts/core/progression/z2_progression_rules.gd")

var save_adapter: SaveAdapter = SaveAdapterScript.new()
var manifest: Dictionary = SaveProfileManifestScript.default_manifest()
var active_profile_id: String = SaveProfileManifestScript.DEFAULT_PROFILE_ID
var last_result: Dictionary = {}
var last_error: String = ""


func load_manifest() -> Dictionary:
	var result := save_adapter.load_json_result(SaveProfileManifestScript.MANIFEST_PATH, SaveProfileManifestScript.default_manifest(), false)
	last_result = result.duplicate(true)
	last_error = str(result.get("error", ""))
	manifest = SaveProfileManifestScript.normalize_manifest(_dictionary_from(result.get("data", SaveProfileManifestScript.default_manifest())))
	active_profile_id = str(manifest.get("active_profile_id", SaveProfileManifestScript.DEFAULT_PROFILE_ID))
	if bool(result.get("read_only_fallback", false)):
		manifest["read_only"] = true
	return manifest.duplicate(true)


func save_manifest() -> Dictionary:
	if bool(manifest.get("read_only", false)):
		return _blocked("manifest_read_only_fallback")
	_ensure_profile_dirs(active_profile_id)
	var ok := save_adapter.save_json(manifest, SaveProfileManifestScript.MANIFEST_PATH, false)
	last_error = save_adapter.last_error
	last_result = {"ok": ok, "status": "saved" if ok else "save_failed", "error": last_error}
	return last_result.duplicate(true)


func active_profile_paths() -> Dictionary:
	return SaveProfileManifestScript.profile_paths(active_profile_id)


func reset_outdated_profiles_for_z2() -> Dictionary:
	if bool(manifest.get("read_only", false)):
		return _blocked("manifest_read_only_fallback")
	var profile_ids: Array = manifest.get("profiles", {}).keys()
	# Only this game's canonical profile directory is in scope.
	if DirAccess.dir_exists_absolute(SaveProfileManifestScript.PROFILES_DIR):
		for id in DirAccess.get_directories_at(SaveProfileManifestScript.PROFILES_DIR):
			if id == SaveProfileManifestScript.sanitize_profile_id(id) and not profile_ids.has(id):
				profile_ids.append(id)
	var reset_ids: Array[String] = []
	for id in profile_ids:
		var paths := SaveProfileManifestScript.profile_paths(str(id))
		var adapter := MetaProgressAdapter.new()
		adapter.save_adapter = save_adapter
		adapter.set_active_profile_path(str(paths.meta_progress), str(id))
		adapter.load_or_create_default()
		if not adapter.can_write_persistence():
			return _blocked(adapter.write_block_reason)
		if not Z2Rules.applies_to(adapter.data):
			var reset := adapter.reset_as_current_z2_profile()
			if not reset.get("ok", false):
				return reset
			reset_ids.append(str(id))
		if adapter.data.get("reset_checkpoint_pending", false):
			if not save_adapter.remove_json(str(paths.run_checkpoint)):
				return _blocked("old_checkpoint_cleanup_failed")
			adapter.data.erase("reset_checkpoint_pending")
			if not adapter.save():
				return _blocked("reset_cleanup_save_failed")
	return {"ok": true, "status": "profiles_ready", "reset_profile_ids": reset_ids}


func meta_progress_path() -> String:
	return str(active_profile_paths().get("meta_progress", SaveProfileManifestScript.default_meta_progress_path()))


func configure_meta_adapter(adapter: MetaProgressAdapter) -> Dictionary:
	if adapter == null:
		return _blocked("meta_progress_adapter_missing")
	adapter.set_active_profile_path(meta_progress_path(), active_profile_id)
	return {
		"ok": true,
		"status": "configured",
		"profile_id": active_profile_id,
		"meta_progress_path": meta_progress_path(),
	}


func configure_checkpoint_service(service: RefCounted, adapter: MetaProgressAdapter, ruleset_id: String = "z2", content_version: String = "z2") -> Dictionary:
	if service == null or not service.has_method("configure") or adapter == null:
		return _blocked("checkpoint_service_missing")
	if adapter.active_profile_id != active_profile_id or adapter.active_meta_progress_path != meta_progress_path():
		return _blocked("checkpoint_profile_mismatch")
	return service.configure(adapter, ruleset_id, content_version)


func switch_profile(profile_id: String, active_run: bool = false) -> Dictionary:
	if active_run:
		return SaveImportStagingScript.blocked_mid_run_result("switch_profile")
	var clean_id := SaveProfileManifestScript.sanitize_profile_id(profile_id)
	if manifest.is_empty():
		load_manifest()
	var profiles: Dictionary = _dictionary_from(manifest.get("profiles", {}))
	if not profiles.has(clean_id):
		profiles[clean_id] = SaveProfileManifestScript.default_profile_entry(clean_id)
	manifest["profiles"] = profiles
	manifest["active_profile_id"] = clean_id
	active_profile_id = clean_id
	_ensure_profile_dirs(clean_id)
	return {
		"ok": true,
		"status": "profile_selected",
		"profile_id": clean_id,
		"paths": SaveProfileManifestScript.profile_paths(clean_id),
		"requires_meta_adapter_reconfigure": true,
	}


func build_import_stage(profile_id: String, source_path: String, active_run: bool = false) -> Dictionary:
	if active_run:
		return SaveImportStagingScript.blocked_mid_run_result("import_profile")
	return SaveImportStagingScript.build_import_stage(profile_id, source_path, manifest)


func build_export_stage(profile_id: String, target_path: String, active_run: bool = false) -> Dictionary:
	if active_run:
		return SaveImportStagingScript.blocked_mid_run_result("export_profile")
	return SaveImportStagingScript.build_export_stage(profile_id, target_path, manifest)


func build_preview() -> Dictionary:
	return SaveProfilePreviewScript.build_manifest_preview(manifest)


func _ensure_profile_dirs(profile_id: String) -> void:
	var paths := SaveProfileManifestScript.profile_paths(profile_id)
	for path_key in ["profile_root"]:
		var dir_path := str(paths.get(path_key, ""))
		if dir_path != "":
			DirAccess.make_dir_recursive_absolute(dir_path)


func _blocked(reason: String) -> Dictionary:
	last_error = reason
	last_result = {
		"ok": false,
		"status": "blocked",
		"reason": reason,
	}
	return last_result.duplicate(true)


func _dictionary_from(value: Variant) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}
