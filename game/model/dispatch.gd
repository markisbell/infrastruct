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
