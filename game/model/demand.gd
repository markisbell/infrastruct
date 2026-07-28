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


# ─── heat (Phase 4): space heating follows outdoor temperature (heating-limit
# curve at 16 °C), hot water is a small diurnal base — weather drives the
# seasonality (ROADMAP Phase 4 task 3) ───

const HOUSE_HEAT_DESIGN_KW := 4.0   # SH design load per house at -14 °C
const HOUSE_DHW_KW := 0.25          # diversified DHW average per house


static func heat_zone_demand_kw(n_houses: int, t: int, temp_c: float) -> float:
	var sh_factor := clampf((16.0 - temp_c) / 30.0, 0.0, 1.15)
	var minute := (t * 15) % 1440
	var night_setback := 0.82 if (minute < 300 or minute >= 1380) else 1.0
	var dhw_hour := (minute / 60) % 24
	var dhw_factor := 1.8 if (dhw_hour >= 6 and dhw_hour < 9) \
		else (1.5 if (dhw_hour >= 18 and dhw_hour < 21) else 0.7)
	return n_houses * (HOUSE_HEAT_DESIGN_KW * sh_factor * night_setback
		+ HOUSE_DHW_KW * dhw_factor)
