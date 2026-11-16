extends SceneTree

# Build-only entry, executed against an isolated project or its actual PCK.
# Kept outside res:// so authoring tools never enter the shipping package.
const Registry := preload("res://scripts/core/content/content_def_registry.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		_finish({"ok": false, "reason": "usage: draft|seal|verify|pack-check output-or-input.json"})
		return
	var registry := Registry.new()
	var mode := args[0]
	var path := args[1]
	var result := {}
	if mode == "draft":
		result = registry._z2_source_hashes()
		if result.ok:
			var digest := {
				"schema_version": 1, "digest_policy": Registry.Z2_RULE_DIGEST_POLICY,
				"source_sha256": result.digests,
				"source_fingerprint": registry.z2_rule_fingerprint(result.digests),
				"compiled_sha256": {},
				"generated_utc": Time.get_datetime_string_from_system(true) + "Z",
				"godot_version": Engine.get_version_info().string,
				"source_revision": args[2] if args.size() > 2 else "unversioned",
				"script_export_mode": 2,
			}
			result = _write(path, digest)
	elif mode == "seal":
		var digest: Variant = _read(Registry.Z2_RULE_DIGEST_PATH)
		result = registry._z2_compiled_hashes()
		if result.ok and digest is Dictionary:
			digest.compiled_sha256 = result.digests
			result = registry.validate_z2_rule_digest(digest, true)
			if result.ok:
				result = _write(path, digest)
		elif result.ok:
			result = {"ok": false, "reason": "missing_draft_digest"}
	elif mode == "verify":
		var digest: Variant = _read(path)
		result = registry.validate_z2_rule_digest(digest, false) if digest is Dictionary else {"ok": false, "reason": "missing_or_invalid_digest"}
	elif mode == "pack-check":
		result = registry.setup_z2()
		if result.ok:
			result["content_hash"] = RunStateSnapshot.fingerprint(registry.snapshot())
			result["source_fingerprint"] = registry.z2_rule_fingerprint(registry.get_content_def("rules.z2").definition.source_sha256)
			result["raw_source_available"] = FileAccess.file_exists("res://scripts/core/run/run_runtime_controller.gd")
			if result.raw_source_available:
				result = {"ok": false, "reason": "expected_compressed_pack"}
			else:
				result = _write(path, result)
	else:
		result = {"ok": false, "reason": "unknown_digest_mode", "mode": mode}
	# Do not flood build logs with every source hash.
	result.erase("digests")
	_finish(result)


func _read(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null


func _write(path: String, value: Dictionary) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "reason": "digest_write_failed", "path": path}
	file.store_string(JSON.stringify(value, "\t", true) + "\n")
	file.flush()
	return {"ok": file.get_error() == OK, "path": path, "source_fingerprint": value.get("source_fingerprint", "")}


func _finish(result: Dictionary) -> void:
	print("Z2_RULE_BUILD=" + JSON.stringify(result))
	quit(0 if result.get("ok", false) else 1)
