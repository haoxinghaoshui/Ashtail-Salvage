extends SceneTree

const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Progress = preload("res://scripts/core/progression/m7_progression_service.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
const Model = preload("res://scripts/ui/long_term/long_term_model.gd")

class CutSave extends SaveAdapter:
	var cut := false
	func _rename_file(source: String, target: String) -> bool:
		if cut and source.ends_with(ATOMIC_TEMP_SUFFIX):
			cut = false
			return false
		return super._rename_file(source, target)

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var meta := Meta.new()
	meta.set_active_profile_path("user://z2_research_%d/meta.json" % Time.get_ticks_usec(), "crafting")
	meta.initialize_z2_profile(Rules.CONTENT_VERSION)
	meta.data.tutorial_completed = true
	meta.data.profile_level = 1
	meta.data.talent_flags = ["z2_talent_01"]
	meta.data.talent_spent = 100
	meta.data.talent_points = 0
	meta.data.gold = 1000
	var runtime := Runtime.new()
	runtime.bind_meta_progress_adapter(meta)
	for recipe in Eligibility.research_definitions():
		for _count in range(2):
			Progress.add_item_instance(meta.data, str(recipe.material_item_id), "test_material")
		meta.save()
		var request := {"request_id": "craft-" + str(recipe.id), "source_page": "long_term", "action": "complete_research", "research_id": recipe.id}
		var crafted: Dictionary = runtime.execute_meta_action(request)
		_check(crafted.get("ok", false), str(recipe.id) + " first craft")
		_check(_count_items(meta.data, str(recipe.unlock_item_id)) == 1, "exactly one product")
		_check(_count_items(meta.data, str(recipe.material_item_id)) == 1, "exactly one material consumed")
		var after_first: Dictionary = meta.data.duplicate(true)
		runtime.execute_meta_action(request)
		_check(meta.data == after_first, "same request cannot duplicate craft")
		meta.load_or_create_default()
		var fresh := Runtime.new()
		fresh.bind_meta_progress_adapter(meta)
		fresh.execute_meta_action(request)
		_check(_same_saved_profile(meta, after_first), "request receipt survives restart")
		request.request_id += "-repeat"
		_check(fresh.execute_meta_action(request).get("ok", false), "fresh request repeats recipe")
		_check(_count_items(meta.data, str(recipe.unlock_item_id)) == 2 and _count_items(meta.data, str(recipe.material_item_id)) == 0, "repeat yields separate second product")
		request.request_id += "-no-material"
		var before_failure := meta.data.duplicate(true)
		_check(not fresh.execute_meta_action(request).get("ok", true) and meta.data == before_failure, "missing material rejects whole craft")
		var frozen := Eligibility.freeze_profile(meta.data)
		for channel in ["search", "chest", "monster", "altar", "camp_shop", "shop"]:
			_check(not Eligibility.is_eligible(str(recipe.unlock_item_id), channel, frozen, "classic_13x13_hell"), "research product excluded from " + channel)
		_release(fresh)
	_check(meta.data.gold == 620 and meta.data.research_completed_ids.size() == 3, "six crafts cost380 and record three research types")
	Progress.add_item_instance(meta.data, "mon_old_gear_set", "test_material")
	meta.save()
	var before_disk_failure := meta.data.duplicate(true)
	var cutter := CutSave.new()
	cutter.cut = true
	meta.save_adapter = cutter
	var failed: Dictionary = runtime.execute_meta_action({"request_id": "cut-craft", "source_page": "long_term", "action": "complete_research", "research_id": "research_hard_shell_patch"})
	_check(not failed.get("ok", true) and meta.data == before_disk_failure, "disk failure rolls back material money product and receipt")
	meta.load_or_create_default()
	_check(_same_saved_profile(meta, before_disk_failure), "disk failure preserves durable prior profile")
	var cards: Array = Model._research_cards(meta.get_summary())
	var hard_shell: Dictionary = cards.filter(func(card: Dictionary) -> bool: return card.id == "research_hard_shell_patch")[0]
	_check(hard_shell.get("action", {}).get("action", "") == &"complete_research", "completed recipe remains actionable in UI")
	_release(runtime)
	for failure in failures:
		print("Z2_RESEARCH_CASE_FAIL " + failure)
	print("Z2_RESEARCH_CRAFTING=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _count_items(data: Dictionary, id: String) -> int:
	return data.warehouse_items.filter(func(item: Dictionary) -> bool: return str(item.item_id) == id).size()

func _same_saved_profile(meta, expected: Dictionary) -> bool:
	# JSON loads numbers as floats. Compare the entire canonical saved value,
	# retaining every business field, rather than Variant numeric type identity.
	var actual_hash: String = SaveAdapter.json_fingerprint(meta._json_safe(meta.data))
	return not actual_hash.is_empty() and actual_hash == SaveAdapter.json_fingerprint(meta._json_safe(expected))

func _release(runtime) -> void:
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
