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


func wind_ms(t: int) -> float:
	for i in range(_wind_overrides.size() - 1, -1, -1):
		var override: Dictionary = _wind_overrides[i]
		if t >= override["from"] and t < override["to"]:
			return override["wind"]
	# synoptic systems: ~4-day period noise, skewed so lows are LOW
	var synoptic := clampf(_wind_noise.get_noise_1d(t / (STEPS_PER_DAY * 4.0) * 100.0) * 0.5 + 0.5, 0.0, 1.0)
	var diurnal := 1.0 + 0.15 * sin(TAU * (float(t % STEPS_PER_DAY) / STEPS_PER_DAY - 0.35))
	return 14.0 * pow(synoptic, 1.6) * diurnal


func ghi_wm2(t: int) -> float:
	var day_frac := float(t % STEPS_PER_DAY) / STEPS_PER_DAY
	var season := _season_factor(t)  # 0 winter .. 1 summer
	var half_day := lerpf(0.17, 0.33, season)  # daylight half-width (fraction of day)
	var elevation := 1.0 - absf(day_frac - 0.5) / half_day
	if elevation <= 0.0:
		return 0.0
	var clear_sky := lerpf(280.0, 880.0, season) * pow(elevation, 1.3)
	var cloud := clampf(_cloud_noise.get_noise_1d(t / (STEPS_PER_DAY * 1.5) * 100.0) * 0.5 + 0.5, 0.0, 1.0)
	return clear_sky * lerpf(0.22, 1.0, cloud)


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
