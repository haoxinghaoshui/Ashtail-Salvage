extends RefCounted

const Catalog := preload("res://scripts/core/progression/z2_goals/goal_catalog.gd")
const Facts := preload("res://scripts/core/progression/z2_goals/goal_run_facts.gd")
const Conditions := preload("res://scripts/core/progression/z2_goals/goal_conditions.gd")
const Maps := preload("res://scripts/core/content/m7_content_catalog.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const STATE_KEY := "z2_goals"
const RESEARCH_IDS := ["research_hard_shell_patch", "research_red_battery", "research_black_box_bell"]


static func initial_state(meta: Dictionary = {}) -> Dictionary:
	return activate_available(meta)


static func activate_available(meta: Dictionary) -> Dictionary:
	return refresh_available(meta, "activation").meta


static func refresh_available(meta: Dictionary, cause_id: String) -> Dictionary:
	var next := meta.duplicate(true)
	var rows := Catalog.definitions()
	_ensure_state(next, rows)
	var notices: Array[Dictionary] = []
	_activate(next, rows, cause_id, notices)
	return _result(next, true, "refreshed", notices)


static func apply_settlement(meta: Dictionary, facts: Dictionary, result_id: String) -> Dictionary:
	var start := Facts.dictionary(facts.get("run_start_config"))
	var map_id := str(start.get("map_config_id", ""))
	if str(facts.get("mode", "")) == "tutorial" or map_id == "tutorial_5x5" or facts.get("debug_used") == true:
		return _result(meta, true, "excluded_run")
	var run_id := str(facts.get("run_id", ""))
	if result_id.is_empty() or run_id.is_empty() or facts.get("finalized") != true or facts.get("preview") == true:
		return _result(meta, false, "unfinalized_result")
	if str(facts.get("ending", "")) not in ["success", "failure", "abandon"]:
		return _result(meta, false, "invalid_ending")
	var map := Maps.map_definition_exact(map_id)
	if map.is_empty() or not map_id.begins_with("classic_"):
		return _result(meta, false, "unknown_map")
	if not meta.get("tutorial_completed", false):
		return _result(meta, true, "locked_until_tutorial")
	if not _valid_journal(facts, int(map.width)):
		return _result(meta, false, "incomplete_run_journal")
	var persisted := Facts.dictionary(meta.get(STATE_KEY))
	var existing := Facts.dictionary(Facts.dictionary(persisted.get("run_receipts")).get(run_id))
	var fingerprint := Snapshot.fingerprint(facts)
	if not existing.is_empty():
		var duplicate: bool = existing.result_id == result_id and existing.fingerprint == fingerprint
		return _result(meta, duplicate, "duplicate_ignored" if duplicate else "run_receipt_conflict")
	if Facts.dictionary(persisted.get("result_receipts")).has(result_id):
		return _result(meta, false, "result_receipt_conflict")
	var departure_sequence := int(facts.get("departure_sequence", 0))
	var settlement_sequence := int(facts.get("settlement_sequence", 0))
	if facts.has("departure_sequence") or facts.has("settlement_sequence"):
		if departure_sequence <= 0 or settlement_sequence <= departure_sequence:
			return _result(meta, false, "invalid_profile_sequence")
		if settlement_sequence <= int(persisted.get("fact_sequence", 0)):
			return _result(meta, false, "stale_fact_sequence")

	var next := meta.duplicate(true)
	var rows := Catalog.definitions()
	var ledger := _ensure_state(next, rows)
	var states: Dictionary = ledger.states
	var notices: Array[Dictionary] = []
	if Facts.dictionary(persisted.get("states")).is_empty():
		_activate(next, rows, result_id, notices)
	var run := Facts.collect(facts, map)
	for row in rows:
		var state: Dictionary = states[row.id]
		if not state.unlocked or int(state.progress) >= int(row.milestones.back().target):
			continue
		if departure_sequence > 0 and departure_sequence <= int(state.get("activated_after_seq", 0)):
			continue
		var progress := int(state.progress)
		var value := Conditions.advance(row.id, progress, state.evidence, run, facts)
		_set_progress(next, row, state, value, result_id, notices)
	ledger.run_receipts[run_id] = {"result_id": result_id, "fingerprint": fingerprint}
	ledger.result_receipts[result_id] = run_id
	if settlement_sequence > 0:
		ledger.fact_sequence = settlement_sequence
	_activate(next, rows, result_id, notices)
	return _result(next, true, "applied", notices)


static func apply_camp_action(meta: Dictionary, action: Dictionary) -> Dictionary:
	var sequence := int(action.get("sequence", 0))
	if sequence <= 0 or action.get("preview") == true:
		return _result(meta, false, "invalid_camp_action")
	var cursor := int(Facts.dictionary(meta.get(STATE_KEY)).get("fact_sequence", 0))
	if sequence <= cursor:
		return _result(meta, true, "duplicate_ignored")

	var next := meta.duplicate(true)
	var rows := Catalog.definitions()
	var ledger := _ensure_state(next, rows)
	var cause_id := "camp:%d" % sequence
	var notices: Array[Dictionary] = []
	ledger.fact_sequence = sequence
	_activate(next, rows, cause_id, notices)
	var status: Dictionary = ledger.states.S03
	if status.unlocked and int(status.progress) < 1:
		_record_reinvestment(status.evidence, action)
	return _result(next, true, "applied", notices)


static func goal_state(meta: Dictionary, id: String) -> Dictionary:
	var row := Catalog.definition(id)
	if row.is_empty():
		return {}
	var ledger := Facts.dictionary(meta.get(STATE_KEY))
	var state := Facts.dictionary(Facts.dictionary(ledger.get("states")).get(id))
	var progress := int(state.get("progress", 0))
	var claimed: Array[int] = []
	for prior in Facts.entries(state.get("claimed_tiers")):
		var tier := int(prior)
		if tier >= 1 and tier <= row.milestones.size() and not claimed.has(tier):
			claimed.append(tier)
	var achieved: Array[int] = []
	var claimable: Array[int] = []
	for milestone: Dictionary in row.milestones:
		var tier := int(milestone.tier)
		if state.get("unlocked", false) and progress >= int(milestone.target):
			achieved.append(tier)
			if not claimed.has(tier):
				claimable.append(tier)
	var status := "locked"
	if state.get("unlocked", false):
		status = "active"
		if not claimable.is_empty():
			status = "claimable"
		elif achieved.size() == row.milestones.size():
			status = "claimed"
	return {"id": id, "status": status, "progress": progress, "target": row.milestones.back().target,
		"achieved_tiers": achieved, "claimed_tiers": claimed.duplicate(), "claimable_tiers": claimable}


# Returns a candidate and reward payload. The caller credits the currencies and
# saves both parts in the same MetaProgress transaction before emitting success.
static func claim_evaluation(meta: Dictionary, id: String, tier: int = 1) -> Dictionary:
	var row := Catalog.definition(id)
	var response := {"ok": false, "status": "unknown_goal", "goal_id": id, "tier": tier, "reward": {}, "meta": meta}
	if row.is_empty():
		return response
	if tier < 1 or tier > row.milestones.size():
		response.status = "unknown_tier"
		return response
	var state := goal_state(meta, id)
	response["reward_id"] = "z2-goal:%s:%d" % [id, tier]
	if state.claimed_tiers.has(tier):
		response.ok = true
		response.status = "duplicate_ignored"
		return response
	if not state.claimable_tiers.has(tier):
		response.status = "not_claimable"
		return response
	var next := meta.duplicate(true)
	next[STATE_KEY].states[id].claimed_tiers.append(tier)
	response.ok = true
	response.status = "claimed"
	response.reward = row.milestones[tier - 1].reward.duplicate()
	response.meta = next
	return response


static func _ensure_state(meta: Dictionary, rows: Array) -> Dictionary:
	var ledger: Dictionary = meta.get_or_add(STATE_KEY, {})
	ledger.get_or_add("run_receipts", {})
	ledger.get_or_add("result_receipts", {})
	ledger.get_or_add("fact_sequence", 0)
	var states: Dictionary = ledger.get_or_add("states", {})
	for row: Dictionary in rows:
		states.get_or_add(row.id, {"unlocked": false, "progress": 0, "claimed_tiers": [], "evidence": {}, "activated_after_seq": -1})
	return ledger


static func _activate(meta: Dictionary, rows: Array, cause_id: String, notices: Array[Dictionary]) -> void:
	if not meta.get("tutorial_completed", false):
		return
	var states: Dictionary = meta[STATE_KEY].states
	for row: Dictionary in rows:
		var state: Dictionary = states[row.id]
		if not state.unlocked:
			var required := int(row.required_main)
			if required > 0:
				var prerequisite := "M%02d" % required
				var previous: Dictionary = states[prerequisite]
				var gate := int(Catalog.definition(prerequisite).milestones.back().target)
				if not previous.unlocked or int(previous.progress) < gate:
					continue
			if row.requires_opening_batch_one and not _opening_batch_one_unlocked(meta):
				continue
			state.unlocked = true
			state["activated_after_seq"] = int(meta[STATE_KEY].fact_sequence)
		if row.id == "M04":
			_set_progress(meta, row, state, _non_teaching_talents(meta), cause_id, notices)
		elif row.id == "S07":
			for research in Facts.entries(meta.get("research_completed_ids")):
				if str(research) in RESEARCH_IDS:
					_set_progress(meta, row, state, 1, cause_id, notices)
					break


static func _non_teaching_talents(meta: Dictionary) -> int:
	var known := {}
	for flag in Facts.entries(meta.get("talent_flags")):
		var id := str(flag)
		if not id.begins_with("z2_talent_"):
			continue
		var number := id.trim_prefix("z2_talent_").to_int()
		if number >= 2 and number <= 39 and id == "z2_talent_%02d" % number:
			known[id] = true
	return known.size()


static func _opening_batch_one_unlocked(meta: Dictionary) -> bool:
	return meta.get("first_opening_batch_unlocked", false) == true or Facts.entries(meta.get("talent_flags")).has("z2_talent_15")


static func _set_progress(meta: Dictionary, row: Dictionary, state: Dictionary, candidate: int, cause_id: String, notices: Array[Dictionary]) -> void:
	var previous := int(state.progress)
	if candidate <= previous:
		return
	state.progress = candidate
	for milestone: Dictionary in row.milestones:
		var target := int(milestone.target)
		if previous < target and candidate >= target:
			notices.append({
				"receipt_id": "goal:%s:%s" % [str(meta.get("profile_id", "local")), cause_id],
				"goal_id": row.id, "kind": row.kind, "tier": milestone.tier,
				"title": row.display_name, "body": row.condition, "committed": false,
			})


static func _record_reinvestment(evidence: Dictionary, action: Dictionary) -> void:
	var items := Facts.entries(action.get("items", [action.get("item")]))
	var kind := str(action.get("kind", ""))
	for raw in items:
		var item := Facts.dictionary(raw)
		var id := str(item.get("instance_id", ""))
		if id.is_empty():
			continue
		if kind == "sell_collectible" and Facts.collectible(item):
			evidence["has_sale"] = true
		elif kind == "purchase" and evidence.get("has_sale", false) and str(item.get("item_type", "")) in ["equipment", "consumable"]:
			var purchased: Dictionary = evidence.get_or_add("purchased_instance_ids", {})
			purchased[id] = true


static func _valid_journal(facts: Dictionary, map_size: int) -> bool:
	var events := Facts.entries(facts.get("run_events"))
	if events.is_empty():
		return false
	var first := Facts.dictionary(events[0])
	var position: Variant = Facts.dictionary(first.get("payload")).get("position")
	if str(first.get("event_type", "")) != "run_started" or not position is Vector2i:
		return false
	if position.x < 0 or position.y < 0 or position.x >= map_size or position.y >= map_size:
		return false
	var last_sequence := 0
	var identities := {}
	for raw in events:
		var event := Facts.dictionary(raw)
		var id := str(event.get("event_id", ""))
		var sequence := int(event.get("sequence", 0))
		if id.is_empty() or identities.has(id) or sequence <= last_sequence or not event.get("payload") is Dictionary:
			return false
		last_sequence = sequence
		identities[id] = true
	return true


static func _result(meta: Dictionary, ok: bool, status: String, notices: Array[Dictionary] = []) -> Dictionary:
	return {"ok": ok, "status": status, "meta": meta, "completions": notices}
