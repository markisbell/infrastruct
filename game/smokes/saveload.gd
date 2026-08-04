extends SmokeBase
## --smoke=saveload (extracted from main.gd, Phase-3 refactor plan).


func run() -> void:
	City.model.set_cable(Vector2i(10, 20), 1)
	City.model.set_road(Vector2i(0, 0))
	City.money = 123_456
	GameClock.restore({"total_minutes": 3 * 1440.0 + 125.0, "speed": 3.0})
	var path := "user://smoke_save.json"
	var save_err := SaveGame.save_to(path)
	City.model = WorldModel.new()
	City.money = City.START_MONEY
	GameClock.restore({"total_minutes": 0.0, "speed": 1.0})
	var loaded: Dictionary = SaveGame.load_from(path)
	var ok: bool = (
		save_err == OK and loaded["ok"]
		and City.model.has_cable(Vector2i(10, 20)) and City.model.roads.has(Vector2i(0, 0))
		and City.money == 123_456
		and GameClock.day() == 3 and GameClock.time_of_day_string() == "02:05"
	)
	print("SMOKE_SAVELOAD ", JSON.stringify({"ok": ok}))
	get_tree().quit(0 if ok else 1)
