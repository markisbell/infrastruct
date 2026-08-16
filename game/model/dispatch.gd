class_name DispatchPolicy
extends RefCounted
## Dispatch rules (Phase-2 extraction from City): the battery peak-shave
## EMA, the heat-storage day windows, and the small pure gates the three
## setpoint builders share. City still assembles the per-device setpoint
## dicts (they read live topology docs); the RULES live here under test.

const PEAK_SHAVE_ALPHA := 1.0 / 96.0  # ~one-day EMA horizon (battery threshold)

## Battery = peak shaving ALWAYS (user direction): discharge the net load
## above its slow-moving average, recharge below it — flattening what the
## grid connection sees instead of bridging only after gas dispatch.
var peak_ema := 0.0
var _ema_t := -1


## Per-step shave target per battery: updates the EMA once per t (seeded
## with the first demand it ever sees), splits across n_batteries.
func battery_shave_kw(t: int, total_demand: float, n_batteries: int) -> float:
	if _ema_t != t:
		peak_ema = total_demand if _ema_t < 0 \
			else lerpf(peak_ema, total_demand, PEAK_SHAVE_ALPHA)
		_ema_t = t
	return (total_demand - peak_ema) / maxf(float(n_batteries), 1.0)


func reset() -> void:
	peak_ema = 0.0
	_ema_t = -1


static func battery_p_kw(shave: float, p_max: float) -> float:
	return clampf(shave, -p_max, p_max)


## Gas covers what is left AFTER renewables and the battery pass.
static func gas_p_kw(residual: float, p_max: float, down: bool) -> float:
	return 0.0 if down else clampf(residual, 0.0, p_max)


## Heat storage windows (Phase 4 storage acceptance behavior): charge from
## the net at night (00-05 h), discharge into the morning peak (06-10 h) —
## capped at 0.6x live demand because discharging more than the net
## consumes is hydraulically infeasible (the pressure slack cannot absorb
## reverse flow; the solver rightly fails).
## Merit order for district-heat plants: base load first, peak boilers
## last. A real network runs the cheap plant flat out and lights the boiler
## only when it cannot keep up — Heidelberg's Spitzenlastkessel sit idle
## most of the year.
const HEAT_MERIT := {"chp_plant": 0, "heat_pump_plant": 1, "boiler_plant": 2}

## Share of demand the SLACK plant is left to carry. A feed-in that covers
## the whole load leaves the pressure reference nothing to do and the flow
## direction goes ambiguous — measured on the backend: pushing 200 kW of
## secondary dispatch into a 70 kW network fails every retry tier, honestly.
const HEAT_SLACK_SHARE := 0.5


## How much each SECONDARY (non-slack) heat plant injects this step.
##
## Only the slack is a pressure reference; every other plant is a pump of
## its own along the line, which is exactly how a real network runs several
## boilers. But they have to cover the demand that EXISTS: dispatching each
## at its catalog nameplate pushed ~300 kW into a network that wanted less,
## and the solver rightly refused. Merit order, capped at each plant's
## rating, cheapest first.
##
## Zero is a legitimate dispatch here — an idle station burns no fuel. Its
## pump still circulates a trickle so the branch never sits at exactly zero
## flow, but that is a FLOW floor and belongs where the flow lives (the
## backend's MIN_PUMP_MDOT_KG_PER_S), not in a kW setpoint: heat added to a
## stalled branch makes its temperature rise explode, it does not move water.
static func heat_feed_in_kw(demand_kw: float, plants: Array,
		slack_share: float = HEAT_SLACK_SHARE) -> Dictionary:
	var order := plants.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ma := int(HEAT_MERIT.get(a.get("kind", ""), 9))
		var mb := int(HEAT_MERIT.get(b.get("kind", ""), 9))
		if ma != mb:
			return ma < mb
		return str(a.get("id", "")) < str(b.get("id", "")))
	var budget := maxf(0.0, demand_kw * (1.0 - clampf(slack_share, 0.0, 1.0)))
	var out := {}
	for plant: Dictionary in order:
		var rating := maxf(0.0, float(plant["rating_kw"]))
		var take := clampf(budget, 0.0, rating)
		out[plant["id"]] = snappedf(take, 0.1)
		budget -= take
	return out


static func storage_heat_q_kw(t: int, p_max: float, total_demand: float) -> float:
	var hour := (t * 15 % 1440) / 60
	if hour >= 0 and hour < 5:
		return -p_max
	if hour >= 6 and hour < 10:
		return minf(p_max, 0.6 * total_demand)
	return 0.0


## Pumps run only while their electric feed is alive — cable-connected to
## a slack-reachable grid that is neither tripped nor failed. THE
## cross-vector consequence: a blackout at the pumping station drains the
## tower, then taps run dry.
static func pump_enabled(power_ok: bool, down: bool, connected: bool) -> bool:
	return power_ok and not down and connected


## Well yield follows the aquifer (drought factor); a downed well is dry.
static func well_yield(drought_factor: float, down: bool) -> float:
	return 0.0 if down else snappedf(drought_factor, 0.01)
