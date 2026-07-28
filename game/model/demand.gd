class_name DemandModel
extends RefCounted
## Household electricity demand v1 (ROADMAP Phase 3 task 1: static profile).
## Phase 6 replaces this with demandlib-generated profile packs.

## Diversified per-house peak (evening), kW.
const HOUSE_PEAK_KW := 1.8

## 24 hourly factors (fraction of peak), classic residential double peak.
const HOURLY: Array[float] = [
	0.36, 0.33, 0.31, 0.30, 0.31, 0.38,
	0.55, 0.72, 0.66, 0.55, 0.52, 0.55,
	0.58, 0.54, 0.50, 0.52, 0.62, 0.80,
	0.95, 1.00, 0.92, 0.78, 0.58, 0.44,
]


static func house_factor(t: int) -> float:
	var minute := (t * 15) % 1440
	var hour := minute / 60
	var next_hour := (hour + 1) % 24
	var within := float(minute % 60) / 60.0
	return lerpf(HOURLY[hour], HOURLY[next_hour], within)


static func zone_demand_kw(n_houses: int, t: int) -> float:
	return n_houses * HOUSE_PEAK_KW * house_factor(t)
