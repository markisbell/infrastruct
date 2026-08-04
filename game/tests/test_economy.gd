extends GdUnitTestSuite
## EconomyBooks (Phase-2 extraction): booking rules, fractional-euro cash
## accrual, the clock tick, loans, and every tariff formula — pinned so a
## balance change is a conscious commit (economy.md contract).


func test_apply_accrues_fractional_euros_without_drift() -> void:
	var books := EconomyBooks.new()
	var cash := 0
	for _i in 3:
		cash += books.apply("income_base", 0.4)
	assert_int(cash).is_equal(1)  # 1.2 accrued -> 1 whole euro landed
	assert_float(float(books.today["income_base"])).is_equal_approx(1.2, 0.0001)
	assert_float(float(books.total["income_base"])).is_equal_approx(1.2, 0.0001)


func test_tick_books_upkeep_base_fee_and_interest() -> void:
	var books := EconomyBooks.new()
	books.loans = 100_000.0
	books.tick(0, 960.0, 10)
	assert_float(float(books.today["cost_upkeep"])).is_equal_approx(-10.0, 0.0001)
	assert_float(float(books.today["income_base"])) \
		.is_equal_approx(10.0 * 0.4 / 96.0, 0.0001)
	assert_float(float(books.today["cost_interest"])) \
		.is_equal_approx(-100_000.0 * 0.0005 / 96.0, 0.0001)


func test_tick_midnight_rolls_today_into_yesterday() -> void:
	var books := EconomyBooks.new()
	assert_bool(bool(books.tick(10, 0.0, 0)["day_rolled"])).is_true()  # first tick
	books.apply("income_elec", 42.0)
	assert_bool(bool(books.tick(11, 0.0, 0)["day_rolled"])).is_false()
	var rolled := books.tick(96, 0.0, 0)
	assert_bool(bool(rolled["day_rolled"])).is_true()
	assert_float(float(books.yesterday["income_elec"])).is_equal_approx(42.0, 0.0001)
	assert_bool(books.today.has("income_elec")).is_false()


func test_delivered_elec_bills_only_positive_net_import() -> void:
	# 100 kW net for a quarter hour = 25 kWh * 0.35
	assert_float(EconomyBooks.delivered_elec_eur(100.0)).is_equal_approx(8.75, 0.0001)
	# rooftop-PV export (negative net load): nothing delivered, nothing sold
	assert_float(EconomyBooks.delivered_elec_eur(-50.0)).is_equal(0.0)


func test_slack_settlement_import_buys_export_sells() -> void:
	var buying := EconomyBooks.slack_settlement(100.0)
	assert_str(buying[0]).is_equal("cost_grid")
	assert_float(buying[1]).is_equal_approx(-100.0 * 0.25 * 0.22, 0.0001)
	var selling := EconomyBooks.slack_settlement(-100.0)
	assert_str(selling[0]).is_equal("income_feedin")
	assert_float(selling[1]).is_equal_approx(100.0 * 0.25 * 0.06, 0.0001)


func test_fuel_formulas() -> void:
	# gas: 100 kW(el) at eta 0.40 for 15 min at 0.09 €/kWh fuel
	assert_float(EconomyBooks.gas_fuel_eur(100.0)) \
		.is_equal_approx(100.0 / 0.40 * 0.25 * 0.09, 0.0001)
	# boiler prefers the SOLVED fuel figure, falls back to q/0.95
	assert_float(EconomyBooks.boiler_fuel_kw(95.0, {"p_fuel_kw": 104.2})) \
		.is_equal_approx(104.2, 0.0001)
	assert_float(EconomyBooks.boiler_fuel_kw(95.0, {})).is_equal_approx(100.0, 0.0001)
	# CHP covers heat + coupled electricity over total efficiency
	assert_float(EconomyBooks.chp_fuel_kw(60.0, 28.0)) \
		.is_equal_approx(88.0 / 0.88, 0.0001)


func test_water_income_scales_with_pdd_fraction() -> void:
	var full := EconomyBooks.water_income_eur(4.0, 1.0)   # 1 m³ delivered
	assert_float(full).is_equal_approx(3.0, 0.0001)
	assert_float(EconomyBooks.water_income_eur(4.0, 0.5)).is_equal_approx(1.5, 0.0001)
	assert_float(EconomyBooks.water_income_eur(4.0, 0.0)).is_equal(0.0)


func test_loans_take_and_clamped_repay() -> void:
	var books := EconomyBooks.new()
	var cash := books.take_loan(100_000.0)
	assert_int(cash).is_equal(100_000)
	assert_float(books.loans).is_equal(100_000.0)
	# repay is clamped by CASH on hand...
	var poor := books.repay_loan(50_000.0, 20_000)
	assert_float(float(poor["repaid"])).is_equal(20_000.0)
	assert_float(books.loans).is_equal(80_000.0)
	# ...and by the outstanding balance
	var rich := books.repay_loan(500_000.0, 900_000)
	assert_float(float(rich["repaid"])).is_equal(80_000.0)
	assert_float(books.loans).is_equal(0.0)
	assert_int(int(books.repay_loan(10.0, 100)["cash"])).is_equal(0)


func test_book_paid_cost_touches_books_not_cash() -> void:
	var books := EconomyBooks.new()
	books.book_paid_cost("cost_maintenance", 1_500.0)
	assert_float(float(books.today["cost_maintenance"])).is_equal(-1_500.0)
	assert_float(float(books.total["cost_maintenance"])).is_equal(-1_500.0)


func test_blackout_day_books_zero_elec_income() -> void:
	# the City rule: unsupplied zones are skipped entirely — at books level
	# that means NO income_elec application happens; pin the formula edge
	# that a zero-delivery day stays absent from the books
	var books := EconomyBooks.new()
	books.tick(0, 0.0, 5)  # houses still pay the Grundgebühr
	assert_bool(books.today.has("income_elec")).is_false()
	assert_bool(books.today.has("income_base")).is_true()
