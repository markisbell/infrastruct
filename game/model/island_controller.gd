class_name IslandController
extends RefCounted
## Microgrid EMS (power islands, 2026-08-05). Each island's grid-forming
## device (battery inverter or gas plant) is the component's slack in the
## solver doc, so the SOLVED slack flow IS the former's dispatch — the
## power flow computes the balance. This controller does what a real EMS
## does with that measurement, one pass per solved step (decisions apply
## to the NEXT boundary read — the architecture's one-step lag):
## - integrate the forming battery's SoC from the solved slack flow,
## - CURTAIL renewables when the charge path saturates (inverter
##   curtailment — a battery can only absorb p_max / its headroom; a
##   forming gas plant can absorb nothing and keeps a stability floor),
## - start reserve (non-forming) gas before shedding,
## - SHED zones in rotation when the former can't carry the load
##   (rolling blackout), restoring one zone per step with headroom,
## - collapse the island on sustained overload or an empty forming
##   battery (frequency collapse), black-starting once SoC recovers /
## a collapsed gas island cools down.
## Pure and deterministic — City feeds it and applies the consequences.

const SOC_START := 0.5          # first-seen forming battery (backend parity)
const SOC_RESERVE := 0.05       # stop discharging below this — shed instead
const SOC_RESTORE := 0.15       # restore shed zones only above (hysteresis)
const RESTART_SOC := 0.25       # black-start threshold after a collapse
const GAS_FLOOR_FRAC := 0.05    # forming gas can't absorb backfeed: curtail
								# renewables to keep >=5 % rating on the machine
const OVERLOAD_TOL := 1.05      # solved |slack| beyond rating counts as overload
const OVERLOAD_TRIP_STREAK := 3 # sustained overload steps before collapse
const GAS_RESTART_STEPS := 8    # collapsed gas island restarts after ~2 h
const RESTORE_HEADROOM := 1.2   # capability needed to pick a shed zone back up

## island_id -> {soc, shed: {zone_id: true}, blackout: bool, streak: int,
##   curtail: float (0..1 renewable factor), gas_kw: float (reserve
##   dispatch), restart_at: int, rotate: int (shed rotation pointer)}
var state := {}


## Topology rebuilds call this: new islands get fresh state (SoC seeded
## from the persisted device_soc so save/load and resets never silently
## recharge the former), vanished islands are dropped. Idempotent.
func sync_islands(islands: Dictionary, device_soc: Dictionary) -> void:
	for island_id: String in islands:
		if not state.has(island_id):
			state[island_id] = {
				"soc": clampf(float(device_soc.get(
					islands[island_id]["former"], SOC_START)), 0.0, 1.0),
				"shed": {}, "blackout": false, "streak": 0,
				"curtail": 1.0, "gas_kw": 0.0, "restart_at": -1, "rotate": 0}
	for island_id: String in state.keys():
		if not islands.has(island_id):
			state.erase(island_id)


func reset() -> void:
	state.clear()


func curtail_of(island_id: String) -> float:
	return float((state.get(island_id, {}) as Dictionary).get("curtail", 1.0))


func gas_kw_of(island_id: String) -> float:
	return float((state.get(island_id, {}) as Dictionary).get("gas_kw", 0.0))


func is_blackout(island_id: String) -> bool:
	return bool((state.get(island_id, {}) as Dictionary).get("blackout", false))


func soc_of(island_id: String) -> float:
	return float((state.get(island_id, {}) as Dictionary).get("soc", 0.0))


## Dark = the whole island collapsed, or this zone is shed by rotation.
func zone_dark(island_id: String, zone_id: String) -> bool:
	if island_id == "" or not state.has(island_id):
		return false
	var s: Dictionary = state[island_id]
	return bool(s["blackout"]) or (s["shed"] as Dictionary).has(zone_id)


## One EMS pass for one island, fed from the SOLVED step. input:
## former_kind ("battery"|"gas_plant"), e_kwh, p_max_kw,
## slack_kw (solved former power, positive = feeding the island),
## zone_kw ({zone_id: potential demand kW} — ALL island zones, shed too),
## renew_kw (available renewables, uncurtailed), gas_max_kw (reserve gas
## capacity, 0 if none/down), former_down (MTBF/maintenance), t, dt_h.
## Returns transition labels for City's event log
## ("blackout"|"black_start"|"shed"|"restore").
func update_island(island_id: String, input: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if not state.has(island_id):
		return out
	var s: Dictionary = state[island_id]
	var battery: bool = str(input.get("former_kind", "battery")) == "battery"
	var e_kwh := maxf(float(input.get("e_kwh", 0.0)), 0.001)
	var p_max := float(input.get("p_max_kw", 0.0))
	var slack_kw := float(input.get("slack_kw", 0.0))
	var dt_h := float(input.get("dt_h", 0.25))
	var zone_kw: Dictionary = input.get("zone_kw", {})
	var renew := float(input.get("renew_kw", 0.0))
	var gas_max := float(input.get("gas_max_kw", 0.0))
	var t := int(input.get("t", 0))

	# the solved slack flow is what the former actually delivered/absorbed.
	# Since contract 1.2 the BACKEND integrates the grid_forming SoC from
	# that flow and reports it — the reported value is authoritative and
	# this controller is supervisory (M3). The local integration stays as
	# the fallback for formers the backend doesn't SoC-track.
	if battery:
		var reported: Variant = input.get("soc")
		if reported is float or reported is int:
			s["soc"] = clampf(float(reported), 0.0, 1.0)
		else:
			s["soc"] = clampf(float(s["soc"]) - slack_kw * dt_h / e_kwh, 0.0, 1.0)

	# a dead former (equipment failure / maintenance) collapses the island
	# until the crew is done — the blackout branch re-evaluates afterwards
	if bool(input.get("former_down", false)):
		if not bool(s["blackout"]):
			out.append("blackout")
		s["blackout"] = true
		_shed_all(s, zone_kw)
		s["curtail"] = 0.0
		s["gas_kw"] = 0.0
		s["restart_at"] = t + 1
		return out

	# sustained operation beyond the former's rating collapses the island
	# (inverter/frequency limits); an empty forming battery still asked to
	# discharge collapses too — the reserve shed below is the normal path,
	# this is the backstop
	s["streak"] = int(s["streak"]) + 1 \
		if absf(slack_kw) > OVERLOAD_TOL * maxf(p_max, 0.001) else 0
	if not bool(s["blackout"]) and (int(s["streak"]) >= OVERLOAD_TRIP_STREAK
			or (battery and float(s["soc"]) <= 0.0 and slack_kw > 0.0)):
		s["blackout"] = true
		s["restart_at"] = t + GAS_RESTART_STEPS
		out.append("blackout")

	if bool(s["blackout"]):
		_shed_all(s, zone_kw)
		if battery:
			# dark island, load disconnected: renewables may still charge the
			# forming battery (EMS black-start charging), capped by its limits.
			# Restart needs BOTH the cooldown and a recovered SoC — an
			# overload collapse with a full battery must still cost an outage
			var charge_cap := minf(p_max, (1.0 - float(s["soc"])) * e_kwh / dt_h)
			s["curtail"] = clampf(charge_cap / maxf(renew, 0.001), 0.0, 1.0)
			s["gas_kw"] = 0.0
			if float(s["soc"]) >= RESTART_SOC and t >= int(s["restart_at"]):
				s["blackout"] = false
				(s["shed"] as Dictionary).clear()
				s["streak"] = 0
				out.append("black_start")
		else:
			s["curtail"] = 0.0
			s["gas_kw"] = 0.0
			if t >= int(s["restart_at"]):
				s["blackout"] = false
				(s["shed"] as Dictionary).clear()
				s["streak"] = 0
				out.append("black_start")
		return out

	var zones_sorted: Array = zone_kw.keys()
	zones_sorted.sort()
	var unshed := 0.0
	for zone_id: String in zones_sorted:
		if not (s["shed"] as Dictionary).has(zone_id):
			unshed += float(zone_kw[zone_id])
	var deficit := unshed - renew

	if battery:
		# PREDICTIVE reserve: the battery may only promise the power that
		# the energy above its reserve can sustain for the coming step —
		# a binary above/below-reserve gate lets one coarse 15-min step
		# blow straight through the reserve into the blackout backstop
		var discharge_cap := minf(p_max,
			maxf(float(s["soc"]) - SOC_RESERVE, 0.0) * e_kwh / dt_h)
		var charge_cap := minf(p_max, (1.0 - float(s["soc"])) * e_kwh / dt_h)
		if deficit <= 0.0:
			# surplus charges the battery; curtail what it cannot absorb
			s["gas_kw"] = 0.0
			s["curtail"] = 1.0 if -deficit <= charge_cap \
				else clampf((unshed + charge_cap) / maxf(renew, 0.001), 0.0, 1.0)
		else:
			# deficit: battery first, reserve gas second, shed last
			s["curtail"] = 1.0
			s["gas_kw"] = clampf(deficit - discharge_cap, 0.0, gas_max)
			var uncovered := deficit - discharge_cap - float(s["gas_kw"])
			if uncovered > 0.0:
				_shed_zones(s, zones_sorted, zone_kw, uncovered)
				out.append("shed")
		if not out.has("shed"):
			_maybe_restore(s, zones_sorted, zone_kw, renew,
				p_max if float(s["soc"]) > SOC_RESTORE else 0.0, gas_max, out)
	else:
		# forming gas: a synchronous machine cannot absorb backfeed — curtail
		# renewables so the solved slack stays above its stability floor
		var floor_kw := GAS_FLOOR_FRAC * p_max
		var allowed_renew := maxf(unshed - floor_kw, 0.0)
		s["curtail"] = 1.0 if renew <= allowed_renew \
			else clampf(allowed_renew / maxf(renew, 0.001), 0.0, 1.0)
		s["gas_kw"] = 0.0  # the former IS the gas — solved, not dispatched
		var over := unshed - renew * float(s["curtail"]) - p_max
		if over > 0.0:
			_shed_zones(s, zones_sorted, zone_kw, over)
			out.append("shed")
		if not out.has("shed"):
			_maybe_restore(s, zones_sorted, zone_kw,
				renew * float(s["curtail"]), p_max, 0.0, out)
	return out


static func _shed_all(s: Dictionary, zone_kw: Dictionary) -> void:
	for zone_id: String in zone_kw:
		(s["shed"] as Dictionary)[zone_id] = true


## Rolling shed: darken zones starting at the rotation pointer until the
## uncovered deficit is gone, then advance the pointer — so repeated
## shortfalls rotate through the town instead of always hitting the same
## households.
static func _shed_zones(s: Dictionary, zones_sorted: Array,
		zone_kw: Dictionary, uncovered: float) -> void:
	var n := zones_sorted.size()
	if n == 0:
		return
	for i in n:
		if uncovered <= 0.0:
			break
		var zone_id: String = zones_sorted[(int(s["rotate"]) + i) % n]
		if (s["shed"] as Dictionary).has(zone_id):
			continue
		(s["shed"] as Dictionary)[zone_id] = true
		uncovered -= float(zone_kw[zone_id])
	s["rotate"] = (int(s["rotate"]) + 1) % n


## Rolling restore: at most ONE shed zone per step, and only when the
## island can carry it with headroom on top of what it already serves —
## the hysteresis that keeps shed/restore from flapping.
static func _maybe_restore(s: Dictionary, zones_sorted: Array,
		zone_kw: Dictionary, renew: float, former_cap: float,
		gas_max: float, out: Array[String]) -> void:
	if (s["shed"] as Dictionary).is_empty():
		return
	var unshed := 0.0
	for zone_id: String in zones_sorted:
		if not (s["shed"] as Dictionary).has(zone_id):
			unshed += float(zone_kw[zone_id])
	for zone_id: String in zones_sorted:
		if (s["shed"] as Dictionary).has(zone_id):
			var need := (unshed + float(zone_kw[zone_id])) * RESTORE_HEADROOM
			if need <= renew + former_cap + gas_max:
				(s["shed"] as Dictionary).erase(zone_id)
				out.append("restore")
			return  # consider ONE zone per step (no flap)
