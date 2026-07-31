class_name WeatherSystem
extends RefCounted
## Deterministic seeded weather (ROADMAP Phase 3 task 5). One source for the
## game AND the solvers: sample(t) feeds the contract step weather; the game
## derives wind/solar availability from the same values.
##
## Wind uses low-frequency synoptic noise raised to a power, so multi-day calm
## windows genuinely occur (the whole point of the game). force_calm()/clear
## is the test hook for scripted scenarios.

const STEPS_PER_DAY := 96

var seed_value: int
var _wind_noise := FastNoiseLite.new()
var _cloud_noise := FastNoiseLite.new()
var _temp_noise := FastNoiseLite.new()
## Scripted wind overrides for scenarios/tests: {from, to, wind}; the LAST
## matching entry wins, so force_calm inside a force_wind window works.
var _wind_overrides: Array[Dictionary] = []


func _init(seed_arg: int = 42) -> void:
	seed_value = seed_arg
	for pair: Array in [[_wind_noise, 1], [_cloud_noise, 2], [_temp_noise, 3]]:
		var noise: FastNoiseLite = pair[0]
		noise.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
		noise.seed = seed_value + pair[1]
		noise.frequency = 1.0


## Test/scenario hook: wind is near-zero for t in [from, to).
func force_calm(from_t: int, to_t: int) -> void:
	force_wind(from_t, to_t, 0.8)


## Test/scenario hook: constant wind speed for t in [from, to).
func force_wind(from_t: int, to_t: int, wind: float) -> void:
	_wind_overrides.append({"from": from_t, "to": to_t, "wind": wind})


func clear_calm() -> void:
	_wind_overrides.clear()
	_temp_overrides.clear()
	_drought_overrides.clear()


func wind_ms(t: int) -> float:
	for i in range(_wind_overrides.size() - 1, -1, -1):
		var override: Dictionary = _wind_overrides[i]
		if t >= override["from"] and t < override["to"]:
			return override["wind"]
	# synoptic systems: ~4-day period noise, skewed so lows are LOW
	var synoptic := clampf(_wind_noise.get_noise_1d(t / (STEPS_PER_DAY * 4.0) * 100.0) * 0.5 + 0.5, 0.0, 1.0)
	var diurnal := 1.0 + 0.15 * sin(TAU * (float(t % STEPS_PER_DAY) / STEPS_PER_DAY - 0.35))
	return 14.0 * pow(synoptic, 1.6) * diurnal


## Wind direction in radians on the world XZ plane (0 = +x, positive toward
## +z). Slow synoptic veer: seeded noise on a ~3-day timescale, offset far
## from the speed samples so direction and speed stay decorrelated. Purely
## visual/ambient for now — turbine output depends on speed only.
## Takes a FLOAT step so visuals can sample the continuous clock
## (GameClock.total_minutes / 15.0) — integer sim steps would snap the
## whole arrow field once per step.
func wind_dir_rad(t: float) -> float:
	return _wind_noise.get_noise_1d(t / (STEPS_PER_DAY * 3.0) * 100.0 + 500.0) * TAU


## Sky clearness 0 (overcast) .. 1 (clear) — the cloud field that attenuates
## ghi_wm2. ~1.5-day noise timescale, so whole overcast days genuinely occur.
## Also drives the visual cloud density and (as a daylight average) which
## MEASURED pv day shape DemandModel picks — sky, solve and dispatch agree.
func clearness(t: int) -> float:
	return clampf(_cloud_noise.get_noise_1d(t / (STEPS_PER_DAY * 1.5) * 100.0) * 0.5 + 0.5, 0.0, 1.0)


## Daylight-window average clearness of a game day (08:00–16:00 samples):
## one committed value per day for the pv measured-day pick.
func clearness_day(day: int) -> float:
	var total := 0.0
	for i in 8:
		total += clearness(day * STEPS_PER_DAY + 32 + i * 4)
	return total / 8.0


func ghi_wm2(t: int) -> float:
	var day_frac := float(t % STEPS_PER_DAY) / STEPS_PER_DAY
	var season := _season_factor(t)  # 0 winter .. 1 summer
	var half_day := lerpf(0.17, 0.33, season)  # daylight half-width (fraction of day)
	var elevation := 1.0 - absf(day_frac - 0.5) / half_day
	if elevation <= 0.0:
		return 0.0
	var clear_sky := lerpf(280.0, 880.0, season) * pow(elevation, 1.3)
	return clear_sky * lerpf(0.22, 1.0, clearness(t))


## Scripted temperature overrides (cold-snap scenarios), same semantics as
## the wind overrides: last matching entry wins.
var _temp_overrides: Array[Dictionary] = []


func force_temp(from_t: int, to_t: int, temp: float) -> void:
	_temp_overrides.append({"from": from_t, "to": to_t, "temp": temp})


func temp_c(t: int) -> float:
	for i in range(_temp_overrides.size() - 1, -1, -1):
		var override: Dictionary = _temp_overrides[i]
		if t >= override["from"] and t < override["to"]:
			return override["temp"]
	var season := _season_factor(t)
	var day_frac := float(t % STEPS_PER_DAY) / STEPS_PER_DAY
	var diurnal := 4.0 * sin(TAU * (day_frac - 0.4))
	var noise := 3.0 * _temp_noise.get_noise_1d(t / (STEPS_PER_DAY * 2.0) * 100.0)
	return lerpf(-2.0, 19.0, season) + diurnal + noise


# ─── drought (Phase 5): slow aquifer state driving well yields. 1.0 = full
# yield; late summer dips naturally, force_drought scripts scenarios ───

var _drought_overrides: Array[Dictionary] = []


func force_drought(from_t: int, to_t: int, factor: float) -> void:
	_drought_overrides.append({"from": from_t, "to": to_t, "factor": factor})


## Well yield_factor ∈ [0,1] (contract §3.1 `well` setpoint). Uses the cloud
## noise channel at a very low frequency — dry spells span weeks.
func drought_factor(t: int) -> float:
	for i in range(_drought_overrides.size() - 1, -1, -1):
		var override: Dictionary = _drought_overrides[i]
		if t >= override["from"] and t < override["to"]:
			return override["factor"]
	var season := _season_factor(t)  # aquifers lowest in late summer
	var wetness := clampf(_cloud_noise.get_noise_1d(t / (STEPS_PER_DAY * 20.0) * 100.0) * 0.5 + 0.5, 0.0, 1.0)
	return clampf(1.0 - 0.35 * season * (1.0 - wetness), 0.3, 1.0)


func sample(t: int) -> Dictionary:
	return {"wind_ms": snappedf(wind_ms(t), 0.01),
		"ghi_wm2": snappedf(ghi_wm2(t), 0.1),
		"temp_c": snappedf(temp_c(t), 0.1)}


## 0.0 mid-winter .. 1.0 mid-summer (360-day year, GameClock seasons).
func _season_factor(t: int) -> float:
	var day := t / STEPS_PER_DAY
	return 0.5 - 0.5 * cos(TAU * float(day % 360) / 360.0)


# ─── generation availability (game-side models, ROADMAP §2.2 note) ───

## Wind turbine curve: cut-in 3 m/s, rated at 12, cut-out 25 (storms, Phase 7).
static func wind_availability(wind: float) -> float:
	if wind < 3.0 or wind >= 25.0:
		return 0.0
	if wind >= 12.0:
		return 1.0
	return pow((wind - 3.0) / 9.0, 3.0)


static func pv_availability(ghi: float) -> float:
	return clampf(ghi / 1000.0, 0.0, 1.0) * 0.9
