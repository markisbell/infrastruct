extends GdUnitTestSuite
## Cloud morphology. The field itself needs a renderer (build() early-returns
## headless), but the shape rules are pure statics — which is the whole point
## of them being statics.


func test_size_distribution_is_a_bounded_power_law() -> void:
	var lo := CloudField.SIZE_MIN
	var hi := CloudField.SIZE_MAX
	var alpha := CloudField.SIZE_ALPHA
	# the bounds are exact, so the "exponential scale break" can never be
	# outrun by an unlucky draw
	assert_float(CloudField.power_law_size(0.0, lo, hi, alpha)) \
		.is_equal_approx(lo, 0.001)
	assert_float(CloudField.power_law_size(1.0, lo, hi, alpha)) \
		.is_equal_approx(hi, 0.001)
	# out-of-range u is clamped, not extrapolated into a map-sized cloud
	assert_float(CloudField.power_law_size(4.0, lo, hi, alpha)) \
		.is_equal_approx(hi, 0.001)
	assert_float(CloudField.power_law_size(-2.0, lo, hi, alpha)) \
		.is_equal_approx(lo, 0.001)
	var sizes: Array[float] = []
	var previous := 0.0
	for i in 1001:
		var u := float(i) / 1000.0
		var size := CloudField.power_law_size(u, lo, hi, alpha)
		assert_float(size).is_between(lo, hi)
		assert_float(size).is_greater_equal(previous)  # monotonic in u
		previous = size
		sizes.append(size)
	# THE property that makes a sky read as real: most clouds are small.
	# A uniform range would put the median at 3.5; the power law pulls it
	# down near 2 while still producing the occasional big one.
	sizes.sort()
	assert_float(sizes[500]).is_less(2.5)
	assert_float(sizes[sizes.size() - 1]).is_greater(4.5)


func test_cover_drives_count_swell_and_street_dissolve() -> void:
	var clear := CloudField.cover_response(0.0)
	var overcast := CloudField.cover_response(1.0)
	# a clear sky keeps a few fair-weather puffs rather than an empty dome
	assert_float(clear["visible"]).is_between(0.0, 0.2)
	assert_float(overcast["visible"]).is_equal_approx(1.0, 0.001)
	# connected cover comes from SWELLING, not only from counting
	assert_float(overcast["swell"]).is_greater(float(clear["swell"]) * 1.5)
	# streets hold until the sky is genuinely closing in
	assert_float(clear["fill"]).is_equal(0.0)
	assert_float(CloudField.cover_response(0.5)["fill"]).is_equal(0.0)
	assert_float(overcast["fill"]).is_equal_approx(1.0, 0.001)
	# monotone in cover, so a thickening sky never briefly thins
	var last := CloudField.cover_response(0.0)
	for i in range(1, 21):
		var step := CloudField.cover_response(float(i) / 20.0)
		assert_float(step["visible"]).is_greater_equal(float(last["visible"]))
		assert_float(step["swell"]).is_greater_equal(float(last["swell"]))
		assert_float(step["fill"]).is_greater_equal(float(last["fill"]))
		last = step
	# out-of-range cover is clamped (clearness is a noise field)
	assert_float(CloudField.cover_response(2.0)["swell"]) \
		.is_equal_approx(float(overcast["swell"]), 0.001)


func test_puffs_sit_on_a_flat_base() -> void:
	# the lifting condensation level is a property of the air mass, so no
	# puff may hang BELOW its cloud's base — this is the single most
	# recognisable thing about a cumulus field
	for size: float in [1.0, 2.5, 6.0]:
		var layout := CloudField.puff_layout(4242, size)
		var lowest := INF
		for puff: Dictionary in layout:
			lowest = minf(lowest, (puff["pos"] as Vector3).y)
			assert_float((puff["pos"] as Vector3).y).is_greater_equal(0.0)
		assert_float(lowest).is_equal(0.0)  # something actually touches it


func test_bigger_clouds_are_taller_wider_and_lumpier() -> void:
	var small := CloudField.puff_layout(99, CloudField.SIZE_MIN)
	var big := CloudField.puff_layout(99, CloudField.SIZE_MAX)
	assert_int(big.size()).is_greater(small.size())
	assert_float(_extent(big).y).is_greater(_extent(small).y * 2.0)
	assert_float(_extent(big).x).is_greater(_extent(small).x * 2.0)
	# growth is vertical too, not just a wider pancake: real cumulus build
	# turrets as they deepen
	assert_float(_extent(big).y / _extent(big).x) \
		.is_greater(_extent(small).y / _extent(small).x * 0.9)


func test_layout_is_deterministic_per_seed() -> void:
	var a := CloudField.puff_layout(7, 3.0)
	var b := CloudField.puff_layout(7, 3.0)
	var c := CloudField.puff_layout(8, 3.0)
	assert_int(a.size()).is_equal(b.size())
	for i in a.size():
		assert_that(a[i]["pos"]).is_equal(b[i]["pos"])
	assert_bool(a[a.size() - 1]["pos"] == c[c.size() - 1]["pos"]).is_false()


## Half-extent of a puff layout including each puff's own radius.
func _extent(layout: Array[Dictionary]) -> Vector3:
	var out := Vector3.ZERO
	for puff: Dictionary in layout:
		var pos: Vector3 = puff["pos"]
		var scale: Vector3 = puff["scale"]
		out.x = maxf(out.x, absf(pos.x) + scale.x)
		out.y = maxf(out.y, pos.y + scale.y)
		out.z = maxf(out.z, absf(pos.z) + scale.z)
	return out
