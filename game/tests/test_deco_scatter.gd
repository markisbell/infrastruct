extends GdUnitTestSuite
## DecoScatter (Phase-5 extraction): the deterministic prop scatter that
## previously hid behind city_view's headless early-return — cluster
## classification, density gates, the riparian strip, and the occupancy
## filter (incl. bulldozer-remembered clears) are unit-tested here for
## the first time.

const AREA := 64  # a corner of the world is plenty (and fast)


func test_scatter_is_deterministic_per_seed() -> void:
	var terrain_a := Terrain.new(19)
	var terrain_b := Terrain.new(19)
	var a := DecoScatter.compute(terrain_a, AREA)
	var b := DecoScatter.compute(terrain_b, AREA)
	assert_int(a.size()).is_equal(b.size())
	for i in a.size():
		assert_that(a[i]).is_equal(b[i])
	assert_bool(a.is_empty()).is_false()


func test_different_seed_different_scatter() -> void:
	var a := DecoScatter.compute(Terrain.new(19), AREA)
	var b := DecoScatter.compute(Terrain.new(20), AREA)
	var a_keys := {}
	for entry: Dictionary in a:
		a_keys["%s|%s" % [entry["pos"], entry["variant"]]] = true
	var overlap := 0
	for entry: Dictionary in b:
		if a_keys.has("%s|%s" % [entry["pos"], entry["variant"]]):
			overlap += 1
	# some coincidence is fine; identical fields would mean the seed is dead
	assert_int(overlap).is_less(mini(a.size(), b.size()))


func test_water_carries_no_props_and_grows_a_riparian_strip() -> void:
	# NOTE: the cluster noise is independent of terrain heights, so even a
	# flat map carries groves/stone fields — compare the BANK band with and
	# without the river, not against a "bare" whole-map count.
	var count_band := func(scatter: Array[Dictionary]) -> Array[int]:
		var on_water := 0
		var banks := 0
		for entry: Dictionary in scatter:
			var pos: Vector2i = entry["pos"]
			if pos.x >= 10 and pos.x <= 12:
				on_water += 1
			elif pos.x >= 8 and pos.x <= 14:
				banks += 1
		return [on_water, banks]
	var dry := Terrain.new(0)
	var before: Array[int] = count_band.call(DecoScatter.compute(dry, AREA))
	var wet := Terrain.new(0)
	wet.force_water(Vector2i(10, 0), Vector2i(12, 63))  # a river column
	var after: Array[int] = count_band.call(DecoScatter.compute(wet, AREA))
	assert_int(after[0]).is_equal(0)          # water tiles never carry props
	assert_int(before[0]).is_greater(0)       # ...but the dry column did
	# riparian upgrade (0.45) on the neutral bank tiles beats the sparse
	# background (0.012) — the banks visibly thicken
	assert_int(after[1]).is_greater(before[1])


func test_placements_respect_occupancy_and_bulldozer_clears() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(19)
	var scatter := DecoScatter.compute(model.terrain, AREA)
	assert_bool(scatter.is_empty()).is_false()
	var ground := func(_pos: Vector2i) -> float: return 0.0
	var baseline_total := 0
	for variant: String in DecoScatter.placements(scatter, model, ground):
		baseline_total += (DecoScatter.placements(scatter, model, ground)[variant] as Array).size()
	# occupy/clear the first three scattered tiles three different ways
	var first: Vector2i = scatter[0]["pos"]
	var second: Vector2i = scatter[1]["pos"]
	var third: Vector2i = scatter[2]["pos"]
	model.set_road(first)
	model.zoning[second] = true
	model.deco_cleared[third] = true
	var filtered_total := 0
	for variant: String in DecoScatter.placements(scatter, model, ground):
		filtered_total += (DecoScatter.placements(scatter, model, ground)[variant] as Array).size()
	assert_int(filtered_total).is_equal(baseline_total - 3)


func test_placement_transforms_sit_on_the_ground_callable() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(19)
	var scatter := DecoScatter.compute(model.terrain, AREA)
	var buckets := DecoScatter.placements(scatter, model,
		func(_pos: Vector2i) -> float: return 7.5)
	var seen := 0
	for variant: String in buckets:
		for transform: Transform3D in buckets[variant]:
			assert_float(transform.origin.y).is_equal(7.5)
			seen += 1
	assert_int(seen).is_greater(0)