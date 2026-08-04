class_name TelemetryRings
extends RefCounted
## Element telemetry for the click-inspector graphs (rtpowerflow's daily
## profile convention): per key, TODAY's 96 step slots fill as solved, and
## YESTERDAY's completed day renders as the faded reference curve.
## key -> {"day": int, "today": Array[96], "yesterday": Array[96]} (NAN = no
## sample). Keys: dev:<id> kW · soc:<id> % · q:<id> m³/h · v:<zone> pu ·
## d:<zone> kW · t:<zone> °C · pb:<zone> bar · trafo:<sub_id> %.
## Extracted from City (Phase-2 refactor plan) — pure ring logic, no autoload
## reads, so the day-rollover and backwards-restore rules are unit-testable.

const STEPS_PER_DAY := 96

var rings := {}


func put(key: String, t: int, value: float) -> void:
	var day := t / STEPS_PER_DAY
	var entry: Dictionary = rings.get(key, {})
	if entry.is_empty() or int(entry["day"]) != day:
		var blank := []
		blank.resize(STEPS_PER_DAY)
		blank.fill(NAN)
		# yesterday only carries over on an ADJACENT day rollover — a jump
		# (seek, or a BACKWARDS clock restore) blanks it rather than showing
		# another day's (or the future's) curve as "yesterday"
		entry = {"day": day,
			"yesterday": entry.get("today", blank.duplicate()) if not entry.is_empty()
				and int(entry.get("day", -99)) == day - 1 else blank.duplicate(),
			"today": blank.duplicate()}
		rings[key] = entry
	entry["today"][t % STEPS_PER_DAY] = value


func clear() -> void:
	rings.clear()
