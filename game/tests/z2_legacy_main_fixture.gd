extends RefCounted

const StartConfig := preload("res://scripts/core/run/run_start_config.gd")
const Catalog := preload("res://scripts/core/content/m7_content_catalog.gd")


# Eligibility setup for legacy UI/transaction probes, not a natural tutorial journey.
# All profile changes use Meta's persisted qualification APIs; Main owns admission.
static func qualify(scene) -> Dictionary:
	var meta = scene.meta_progress_adapter
	if not bool(meta.data.get("tutorial_completed", false)):
		var begun: Dictionary = meta.begin_tutorial_training()
		if not begun.get("ok", false):
			return begun
		var purchased: Dictionary = meta.purchase_tutorial_flag()
		if not purchased.get("ok", false):
			return purchased
		var completed: Dictionary = meta._apply_tutorial_settlement({
			"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"},
		}, "legacy-main-fixture-teaching")
		if not completed.get("ok", false):
			return completed
	return {"ok": int(meta.data.get("profile_level", 0)) >= 1, "status": "fixture_qualified"}


static func config(seed_value: int = 71) -> Dictionary:
	var result := StartConfig.default_config()
	result.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "seed_value": seed_value}, true)
	result.selected_objective_id = Catalog.commission_offer_candidates("classic_7x7_simple", 0)[0].id
	return result


static func start(scene, seed_value: int = 71) -> Dictionary:
	var qualified := qualify(scene)
	if not qualified.get("ok", false):
		return qualified
	return scene.command_bus.dispatch(&"start_standard_run", {"run_start_config": config(seed_value)})


static func event_choices(scene) -> Array[Button]:
	var dialogue: Control = scene.z2_event_adapter.dialogue
	for _advance in range(16):
		if dialogue.get_node("%ChoicesFrame").visible:
			break
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		dialogue.get_node("%DialogueText").gui_input.emit(click)
	var buttons: Array[Button] = []
	for child in dialogue.find_children("Option_*", "Button", true, false):
		buttons.append(child as Button)
	return buttons
