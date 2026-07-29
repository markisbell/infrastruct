extends Node
## SaveGame — versioned save/load envelope. v2 (Phase 3): world model v2 +
## city state (money/happiness/outages/weather seed) + clock. Solver-side
## state is NOT saved: networks rebuild from the model via /gb/net/reset on
## load (device SoC replay is Phase 8 hardening).

const ENVELOPE_VERSION := 3  # v3: city payload carries the game context
                             # (scenario state, difficulty, sandbox flags)
const DEFAULT_PATH := "user://save.json"


func save_to(path: String, model: WorldModel = null) -> Error:
	var envelope := {
		"version": ENVELOPE_VERSION,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
		"clock": GameClock.serialize(),
		"model": JSON.parse_string((model if model else City.model).to_json()),
		"city": City.serialize(),
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(envelope, "  "))
	f.close()
	return OK


## Returns {"ok": bool, "model": WorldModel?, "error": String?}.
## Restores GameClock + City state as a side effect when ok.
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
	City.model = model
	City.restore(envelope.get("city", {}))  # v1 saves: defaults
	return {"ok": true, "model": model}
