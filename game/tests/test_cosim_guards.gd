extends GdUnitTestSuite
## Contract §2 handshake version rule (Phase-1 hardening): identical MAJOR,
## game-minor <= backend-minor. The old prefix match accepted any "1.x"
## backend even when the game needs 1.1 features.


func test_version_rule_accepts_equal_and_newer_minor() -> void:
	assert_bool(CosimBridge.version_ok("1.1", "1.1")).is_true()
	assert_bool(CosimBridge.version_ok("1.1", "1.2")).is_true()
	assert_bool(CosimBridge.version_ok("1.0", "1.1")).is_true()
	# numeric compare, not lexicographic: "1.10" >= "1.1"
	assert_bool(CosimBridge.version_ok("1.1", "1.10")).is_true()


func test_version_rule_refuses_older_minor_and_other_major() -> void:
	assert_bool(CosimBridge.version_ok("1.1", "1.0")).is_false()
	assert_bool(CosimBridge.version_ok("1.1", "2.1")).is_false()
	assert_bool(CosimBridge.version_ok("1.1", "0.9")).is_false()


func test_version_rule_refuses_malformed() -> void:
	assert_bool(CosimBridge.version_ok("1.1", "")).is_false()
	assert_bool(CosimBridge.version_ok("1.1", "1")).is_false()
	assert_bool(CosimBridge.version_ok("1.1", "1.x")).is_false()


func test_game_requirement_matches_backends() -> void:
	# all three gamebridge backends speak 1.1 — the requirement must pass them
	assert_bool(CosimBridge.version_ok(CosimBridge.EXPECTED_CONTRACT, "1.1")) \
		.is_true()
