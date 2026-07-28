extends GdUnitTestSuite
## Unit tests for the logical world model (headless — no scene tree needed).
## This is the pattern for all model/ code: pure data, testable without Godot
## rendering (ADR-002).


func test_set_and_remove_cable() -> void:
	var model := WorldModel.new()
	model.set_cable(Vector2i(3, 4), 1)
	assert_bool(model.has_cable(Vector2i(3, 4))).is_true()
	assert_bool(model.has_cable(Vector2i(4, 3))).is_false()
	model.remove_cable(Vector2i(3, 4))
	assert_bool(model.has_cable(Vector2i(3, 4))).is_false()


func test_json_roundtrip_is_lossless() -> void:
	var model := WorldModel.new()
	model.set_cable(Vector2i(0, 0), 1)
	model.set_cable(Vector2i(255, 255), 2)
	model.set_cable(Vector2i(-5, 12), 1)  # negative coords must survive
	var restored := WorldModel.from_json(model.to_json())
	assert_bool(restored.equals(model)).is_true()
	assert_int(restored.cables.size()).is_equal(3)
	assert_int(restored.cables[Vector2i(-5, 12)]).is_equal(1)


func test_from_json_rejects_garbage() -> void:
	assert_int(WorldModel.from_json("not json").cables.size()).is_equal(0)
	assert_int(WorldModel.from_json("[1,2,3]").cables.size()).is_equal(0)
	assert_int(WorldModel.from_json("{}").cables.size()).is_equal(0)


func test_empty_model_roundtrip() -> void:
	var model := WorldModel.new()
	var restored := WorldModel.from_json(model.to_json())
	assert_bool(restored.equals(model)).is_true()
