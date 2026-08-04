class_name FakeSidecarHealth
extends RefCounted
## Health-source double for Orchestrator suites (Phase-4 refactor plan):
## per-id scripted states, HEALTHY by default.

var states := {}  # id -> SidecarManager.State


func state_of(id: String) -> SidecarManager.State:
	return states.get(id, SidecarManager.State.HEALTHY)
