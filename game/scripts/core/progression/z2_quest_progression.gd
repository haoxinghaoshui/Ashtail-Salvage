extends RefCounted
class_name Z2QuestProgression

# Compatibility only: the canonical engine owns all detection and claim state.
const Goals := preload("res://scripts/core/progression/z2_goals/goal_progression.gd")

static func initial_state(meta: Dictionary = {}) -> Dictionary:
	return Goals.initial_state(meta)

static func activate_available(meta: Dictionary) -> Dictionary:
	return Goals.activate_available(meta)

static func apply_settlement(meta: Dictionary, facts: Dictionary, result_id: String) -> Dictionary:
	return Goals.apply_settlement(meta, facts, result_id)

static func claim_evaluation(meta: Dictionary, id: String, tier: int = 1) -> Dictionary:
	return Goals.claim_evaluation(meta, id, tier)
