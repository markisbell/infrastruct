extends Node
## SaveGame — versioned save/load envelope (ROADMAP Phase 1 task 3).
## Persists the logical world model (ADR-002) + GameClock state. Solver-side
## state is deliberately NOT saved: networks are rebuilt from the model via
## /gb/net/reset on load (ROADMAP Phase 8 hardening owns device SoC replay).

const ENVELOPE_VERSION := 1
const DEFAULT_PATH := "user://save.json"


func save_to(path: String, model: WorldModel) -> Error:
	var envelope := {
		"version": ENVELOPE_VERSION,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
		"clock": GameClock.serialize(),
		"model": JSON.parse_string(model.to_json()),
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(envelope, "  "))
	f.close()
	return OK


## Returns {"ok": bool, "model": WorldModel?, "error": String?}.
## Restores GameClock as a side effect when ok.
func load_from(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "no save at " + path}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not (parsed is Dictionary):
		return {"ok": false, "error": "corrupt save"}
	var envelope: Dictionary = parsed
	var version := int(envelope.get("version", 0))
	if version < 1 or version > ENVELOPE_VERSION:
		return {"ok": false, "error": "unsupported save version %d" % version}
	var model := WorldModel.from_json(JSON.stringify(envelope.get("model", {})))
	GameClock.restore(envelope.get("clock", {}))
	return {"ok": true, "model": model}
