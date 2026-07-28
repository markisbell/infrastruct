extends Node
## GameClock — the game owns time (ROADMAP §2.5).
## In-game minutes advance with wall time × speed; every SIM_STEP_MINUTES of
## game time one sim_step fires (the Orchestrator maps these onto /gb/step
## calls from Phase 2 on). Seasons: 4 × DAYS_PER_SEASON-day year.

signal sim_step(t: int)
signal day_changed(day: int)
signal season_changed(season: int)
signal speed_changed(speed: float)

const MINUTES_PER_DAY := 1440
const SIM_STEP_MINUTES := 15
const DAYS_PER_SEASON := 90
const SEASON_NAMES: Array[String] = ["spring", "summer", "autumn", "winter"]

## In-game minutes that pass per real second at speed 1.0
## (1× ⇒ one full day in 24 real minutes).
var base_minutes_per_real_second := 1.0
var speed := 1.0:
	set(value):
		speed = maxf(0.0, value)
		speed_changed.emit(speed)

var total_minutes := 0.0
var _emitted_step := -1
var _last_day := 0
var _last_season := 0


func _process(delta: float) -> void:
	if speed <= 0.0:
		return
	total_minutes += delta * base_minutes_per_real_second * speed
	var step_index := int(total_minutes / SIM_STEP_MINUTES)
	while _emitted_step < step_index:
		_emitted_step += 1
		sim_step.emit(_emitted_step)
	if day() != _last_day:
		_last_day = day()
		day_changed.emit(_last_day)
	if season() != _last_season:
		_last_season = season()
		season_changed.emit(_last_season)


func pause() -> void:
	speed = 0.0


func day() -> int:
	return int(total_minutes / MINUTES_PER_DAY)


func minute_of_day() -> int:
	return int(total_minutes) % MINUTES_PER_DAY


func season() -> int:
	return (day() / DAYS_PER_SEASON) % SEASON_NAMES.size()


func season_name() -> String:
	return SEASON_NAMES[season()]


func time_of_day_string() -> String:
	var m := minute_of_day()
	return "%02d:%02d" % [m / 60, m % 60]


# ─── persistence (ROADMAP Phase 1 task 3) ───

func serialize() -> Dictionary:
	return {"total_minutes": total_minutes, "speed": speed}


func restore(data: Dictionary) -> void:
	total_minutes = float(data.get("total_minutes", 0.0))
	speed = float(data.get("speed", 1.0))
	# do not re-emit historical steps after a load
	_emitted_step = int(total_minutes / SIM_STEP_MINUTES)
	_last_day = day()
	_last_season = season()
