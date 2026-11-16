extends SceneTree

const Registry := preload("res://scripts/core/content/content_def_registry.gd")
const REQUIRED := [
	"res://scripts/core/run/run_runtime_controller.gd",
	"res://scripts/core/run/run_state_machine.gd",
	"res://scripts/core/run/run_start_config.gd",
	"res://scripts/core/run/run_context.gd",
	"res://scripts/core/run/run_state_snapshot.gd",
	"res://scripts/core/command/command_bus.gd",
	"res://scripts/core/run/g41_in_run_runtime.gd",
	"res://scripts/core/content/m3r_item_usability_model.gd",
	"res://scripts/core/run/encounter/room_encounter_common_rule_schema.gd",
	"res://scripts/core/content/content_delivery_schema.gd",
	"res://scripts/core/run/z2_event_dialogue_catalog.gd",
]
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	var registry := Registry.new()
	var result: Dictionary = registry._z2_rule_sources()
	_check(result.get("ok", false), "actual project sources readable")
	for path: String in REQUIRED:
		_check(result.get("digests", {}).has(path), "actual rule covered: " + path)
	var has_validator := registry.has_method("validate_z2_rule_digest")
	_check(has_validator, "pack digest validator exists")
	if has_validator and result.get("ok", false):
		var digests: Dictionary = result.digests
		var manifest := {
			"schema_version": 1, "digest_policy": "utf8_lf_authoring_paths_excluded_v1",
			"source_sha256": digests, "source_fingerprint": registry.call("z2_rule_fingerprint", digests),
			"compiled_sha256": digests.duplicate(),
		}
		_check(registry.call("validate_z2_rule_digest", manifest, false).get("ok", false), "current source manifest accepted")
		_check(not registry.call("validate_z2_rule_digest", {}, false).get("ok", true), "missing manifest rejected")
		var incomplete := manifest.duplicate(true)
		incomplete.source_sha256.erase(REQUIRED[0])
		_check(not registry.call("validate_z2_rule_digest", incomplete, false).get("ok", true), "incomplete source coverage rejected")
		incomplete = manifest.duplicate(true)
		incomplete.compiled_sha256.erase(REQUIRED[0])
		_check(not registry.call("validate_z2_rule_digest", incomplete, false).get("ok", true), "incomplete compiled coverage rejected")
		var stale := manifest.duplicate(true)
		stale.source_sha256[REQUIRED[0]] = "0".repeat(64)
		stale.source_fingerprint = registry.call("z2_rule_fingerprint", stale.source_sha256)
		_check(not registry.call("validate_z2_rule_digest", stale, false).get("ok", true), "self-consistent stale source manifest rejected")
		stale = manifest.duplicate(true)
		stale.source_sha256[REQUIRED[0]] = ""
		_check(not registry.call("validate_z2_rule_digest", stale, false).get("ok", true), "empty hash rejected")
	if OS.get_cmdline_user_args().has("--source-probes"):
		_test_unavailable_source(registry)
	for failure in failures:
		printerr("Z2_RULE_DIGEST_FAIL " + failure)
	print("Z2_RULE_DIGEST=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _test_unavailable_source(registry) -> void:
	var expected := OS.get_environment("Z2_RULE_QA_PROJECT").replace("\\", "/").trim_suffix("/")
	if expected.is_empty() or expected != ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/"):
		_check(false, "source probes require explicit isolated project path")
		return
	var path: String = REQUIRED[0]
	var original := FileAccess.get_file_as_bytes(path)
	var writer := FileAccess.open(path, FileAccess.WRITE)
	writer.close()
	var empty: Dictionary = registry._z2_rule_sources()
	_check(not empty.get("ok", true) and empty.get("reason") == "empty_z2_rule_source", "empty actual source cannot fall back to manifest")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var missing: Dictionary = registry._z2_rule_sources()
	_check(not missing.get("ok", true) and missing.get("reason") == "missing_z2_rule_source", "missing actual source cannot fall back to manifest")
	writer = FileAccess.open(path, FileAccess.WRITE)
	writer.store_buffer(original)
	writer.close()
	_check(registry._z2_rule_sources().get("ok", false), "mirror source restored")
