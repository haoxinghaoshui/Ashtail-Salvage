extends RefCounted
class_name RunActionTransaction

const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")

static func plan(state: Dictionary, request: Dictionary) -> Dictionary:
	var revision := int(state.get("revision", 0))
	if int(request.get("expected_revision", revision)) != revision:
		return {"ok": false, "reason": "stale_revision"}
	var action_id := str(request.get("action_id", ""))
	if action_id.is_empty():
		return {"ok": false, "reason": "missing_action_id"}
	var next_state: Variant = request.get("computed_state")
	if not next_state is Dictionary or not Snapshot.can_encode(next_state):
		return {"ok": false, "reason": "invalid_candidate_state"}
	var identity := {"kind": request.get("kind", ""), "payload": request.get("payload", {})}
	return {"ok": true, "plan": {
		"base_revision": revision,
		"action_id": action_id,
		"request_fingerprint": Snapshot.fingerprint(identity),
		"next_state": next_state.duplicate(true),
		"result": request.get("result", {}).duplicate(true),
		"durability_required": bool(request.get("durability_required", true)),
		"new_run": str(next_state.get("run_id", "")) != str(state.get("run_id", "")),
		"record_receipt": bool(request.get("record_receipt", true)),
	}}

static func commit(runtime, action_plan: Dictionary) -> Dictionary:
	if int(action_plan.get("base_revision", -1)) != runtime.transaction_revision:
		return {"ok": false, "reason": "stale_revision"}
	var next_state: Dictionary = action_plan["next_state"].duplicate(true)
	var result: Dictionary = action_plan.get("result", {}).duplicate(true)
	if bool(action_plan.get("durability_required", true)):
		next_state["revision"] = 0 if bool(action_plan.get("new_run", false)) else runtime.transaction_revision + 1
		if bool(action_plan.get("new_run", false)):
			next_state["receipts"] = {}
		result["revision"] = next_state["revision"]
		result["action_id"] = action_plan["action_id"]
		if bool(action_plan.get("record_receipt", true)):
			var receipt := {"fingerprint": action_plan["request_fingerprint"], "result": result.duplicate(true)}
			next_state["receipts"][action_plan["action_id"]] = receipt
		var saved: Dictionary = runtime.persist_candidate_state(next_state)
		if not bool(saved.get("ok", false)):
			return {"ok": false, "reason": str(saved.get("reason", saved.get("error", "checkpoint_save_failed"))), "status": &"save_failed", "storage_error": saved}
	var installed: Dictionary = runtime.install_authoritative_state(next_state)
	if not bool(installed.get("ok", false)):
		return installed
	result["revision"] = runtime.transaction_revision
	result["action_id"] = action_plan["action_id"]
	return result
