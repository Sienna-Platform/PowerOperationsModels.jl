"""
Unit tests for POM's storage MarketBidCost objective-function construction (the
`EnergyReservoirStorage` overrides added in `common_models/market_bid_overrides.jl`).

A storage device bids both sides of the market: discharge is an incremental (supply)
offer carried on `ActivePowerOutVariable`, charge is a decremental (demand) offer carried
on `ActivePowerInVariable`. This mirrors the Source ImportExport pair in
`test_import_export_cost.jl`, with the same conventions: system base == device base == 100,
curves in `SYSTEM_BASE` power units, hourly resolution, one time step - so translated slopes
arrive at the objective unchanged. Scaling (dt + unit conversion) gets its own testset.

Sign convention for `EnergyReservoirStorage` with `StorageDispatchWithReserves`:
- Discharge (`ActivePowerOutVariable`, `IncrementalOffer`) -> `OBJECTIVE_FUNCTION_POSITIVE`.
- Charge   (`ActivePowerInVariable`,  `DecrementalOffer`) -> `OBJECTIVE_FUNCTION_NEGATIVE`.
"""

# A static MarketBidCost with both offer sides nontrivial: incremental (discharge) and
# decremental (charge). Both curves in SYSTEM_BASE so the translated slopes equal the inputs.
_storage_mbc(inc_xs, inc_ys, dec_xs, dec_ys) = PSY.MarketBidCost(;
    incremental_offer_curves = PSY.CostCurve(
        PSY.PiecewiseIncrementalCurve(0.0, inc_xs, inc_ys),
        PSY.SU,
    ),
    decremental_offer_curves = PSY.CostCurve(
        PSY.PiecewiseIncrementalCurve(0.0, dec_xs, dec_ys),
        PSY.SU,
    ),
)

@testset "EnergyReservoirStorage + StorageDispatchWithReserves + static MBC" begin
    # Distinct breakpoints & slopes for the discharge vs charge side so any swap is visible.
    cost = _storage_mbc(
        [0.0, 0.25, 1.0], [40.0, 55.0],    # incremental (discharge) side
        [0.0, 0.40, 0.9], [25.0, 35.0],    # decremental (charge) side
    )
    sys = one_bus_one_storage(cost; name = "storage1")
    storage = PSY.get_component(PSY.EnergyReservoirStorage, sys, "storage1")

    container = build_test_container(sys, 1:1)
    add_jump_var!(
        container, IOM.ActivePowerOutVariable, PSY.EnergyReservoirStorage, "storage1", 1,
    )
    add_jump_var!(
        container, IOM.ActivePowerInVariable, PSY.EnergyReservoirStorage, "storage1", 1)

    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerOutVariable, storage, cost,
        POM.StorageDispatchWithReserves)
    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerInVariable, storage, cost,
        POM.StorageDispatchWithReserves)

    # Discharge side: IncrementalOffer sign = +1, dt = 1 hr, SYSTEM_BASE => coefficient == slope.
    @test pwl_delta_coefs(
        container, IOM.IncrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [40.0, 55.0]
    @test pwl_delta_widths(
        container, IOM.IncrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [0.25, 0.75]
    # Charge side: DecrementalOffer sign = -1 (a positive willingness-to-pay enters the
    # objective as a benefit), distinct breakpoints.
    @test pwl_delta_coefs(
        container, IOM.DecrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [-25.0, -35.0]
    @test pwl_delta_widths(
        container, IOM.DecrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [0.4, 0.5]
end

@testset "EnergyReservoirStorage + StorageDispatchWithReserves: dt and unit conversion" begin
    # NATURAL_UNITS + 15-minute resolution. Slope scaling: y × sys_base × dt.
    # Break scaling: x / sys_base.
    cost = PSY.MarketBidCost(;
        incremental_offer_curves = PSY.CostCurve(
            PSY.PiecewiseIncrementalCurve(0.0, [0.0, 200.0], [40.0]),
            PSY.NU,
        ),
        decremental_offer_curves = PSY.CostCurve(
            PSY.PiecewiseIncrementalCurve(0.0, [0.0, 200.0], [25.0]),
            PSY.NU,
        ),
    )
    sys = one_bus_one_storage(cost; name = "storage1")
    storage = PSY.get_component(PSY.EnergyReservoirStorage, sys, "storage1")

    container = build_test_container(sys, 1:1; resolution = Dates.Minute(15))
    add_jump_var!(
        container, IOM.ActivePowerOutVariable, PSY.EnergyReservoirStorage, "storage1", 1,
    )
    add_jump_var!(
        container, IOM.ActivePowerInVariable, PSY.EnergyReservoirStorage, "storage1", 1)

    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerOutVariable, storage, cost,
        POM.StorageDispatchWithReserves)
    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerInVariable, storage, cost,
        POM.StorageDispatchWithReserves)

    # Discharge slope coefficient = +(40 × 100) × 0.25 = +1000.
    @test pwl_delta_coefs(
        container, IOM.IncrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [1000.0]
    # Charge slope coefficient = -(25 × 100) × 0.25 = -625.
    @test pwl_delta_coefs(
        container, IOM.DecrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [-625.0]
    # Breakpoint widths = 200 / 100 = 2.0 for both directions.
    @test pwl_delta_widths(
        container, IOM.IncrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [2.0]
    @test pwl_delta_widths(
        container, IOM.DecrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [2.0]
end

@testset "EnergyReservoirStorage + StorageDispatchWithReserves + TS MBC" begin
    # Time-varying MBC dispatches through the parameter-container path. We skip
    # `add_parameters!` (which would require real time series on the system) and populate the
    # Incremental/Decremental slope & breakpoint parameters directly with distinct-per-timestep
    # values. A two-sided storage carries both offer curves (neither is the placeholder).
    cost = stub_ts_market_bid_cost()
    sys = one_bus_one_storage(cost; name = "storage1")
    storage = PSY.get_component(PSY.EnergyReservoirStorage, sys, "storage1")

    container = build_test_container(sys, 1:2)
    for t in 1:2
        add_jump_var!(
            container, IOM.ActivePowerOutVariable, PSY.EnergyReservoirStorage,
            "storage1", t)
        add_jump_var!(
            container, IOM.ActivePowerInVariable, PSY.EnergyReservoirStorage,
            "storage1", t)
    end

    # Distinct values per direction AND per time step so a wiring that reads the wrong
    # direction or the wrong t is visible.
    setup_delta_pwl_parameters!(
        container, PSY.EnergyReservoirStorage, ["storage1"],
        reshape([[40.0, 55.0], [44.0, 60.0]], 1, 2),
        reshape([[0.0, 0.25, 1.0], [0.0, 0.35, 0.8]], 1, 2),
        1:2;
        dir = IOM.IncrementalOffer())
    setup_delta_pwl_parameters!(
        container, PSY.EnergyReservoirStorage, ["storage1"],
        reshape([[25.0, 35.0], [27.0, 38.0]], 1, 2),
        reshape([[0.0, 0.40, 0.9], [0.0, 0.50, 0.8]], 1, 2),
        1:2;
        dir = IOM.DecrementalOffer())

    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerOutVariable, storage, cost,
        POM.StorageDispatchWithReserves)
    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerInVariable, storage, cost,
        POM.StorageDispatchWithReserves)

    variant = IOM.get_variant_terms(IOM.get_objective_expression(container))
    incr_pwl = IOM.get_variable(
        container, IOM.PiecewiseLinearBlockIncrementalOffer, PSY.EnergyReservoirStorage,
    )
    decr_pwl = IOM.get_variable(
        container, IOM.PiecewiseLinearBlockDecrementalOffer, PSY.EnergyReservoirStorage,
    )

    # Discharge (incremental) slopes enter with +1 sign.
    @test [JuMP.coefficient(variant, incr_pwl[("storage1", s, 1)]) for s in 1:2] ≈
          [40.0, 55.0]
    @test [JuMP.coefficient(variant, incr_pwl[("storage1", s, 2)]) for s in 1:2] ≈
          [44.0, 60.0]
    # Charge (decremental) slopes enter with -1 sign.
    @test [JuMP.coefficient(variant, decr_pwl[("storage1", s, 1)]) for s in 1:2] ≈
          [-25.0, -35.0]
    @test [JuMP.coefficient(variant, decr_pwl[("storage1", s, 2)]) for s in 1:2] ≈
          [-27.0, -38.0]

    @test pwl_delta_widths(
        container, IOM.IncrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [0.25, 0.75]
    @test pwl_delta_widths(
        container, IOM.IncrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 2,
    ) ≈ [0.35, 0.45]
    @test pwl_delta_widths(
        container, IOM.DecrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [0.4, 0.5]
    @test pwl_delta_widths(
        container, IOM.DecrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 2,
    ) ≈ [0.5, 0.3]
end

@testset "EnergyReservoirStorage + StorageDispatchWithReserves: one-sided offers skip" begin
    # A storage that only bids to discharge (incremental) should add no charge (decremental)
    # PWL terms, and vice versa. The override guards each side on `is_nontrivial_offer`.
    zero_offer = PSY.CostCurve(
        PSY.PiecewiseIncrementalCurve(0.0, [0.0, 0.0], [0.0]),
        PSY.SU,
    )
    cost = PSY.MarketBidCost(;
        incremental_offer_curves = PSY.CostCurve(
            PSY.PiecewiseIncrementalCurve(0.0, [0.0, 0.5, 1.0], [40.0, 55.0]),
            PSY.SU,
        ),
        decremental_offer_curves = zero_offer,
    )
    sys = one_bus_one_storage(cost; name = "storage1")
    storage = PSY.get_component(PSY.EnergyReservoirStorage, sys, "storage1")

    container = build_test_container(sys, 1:1)
    add_jump_var!(
        container, IOM.ActivePowerOutVariable, PSY.EnergyReservoirStorage, "storage1", 1,
    )
    add_jump_var!(
        container, IOM.ActivePowerInVariable, PSY.EnergyReservoirStorage, "storage1", 1)

    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerOutVariable, storage, cost,
        POM.StorageDispatchWithReserves)
    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerInVariable, storage, cost,
        POM.StorageDispatchWithReserves)

    # Discharge side present.
    @test pwl_delta_coefs(
        container, IOM.IncrementalOffer(), PSY.EnergyReservoirStorage, "storage1", 1,
    ) ≈ [40.0, 55.0]
    # Charge side absent: no decremental block-offer variables were created.
    @test !IOM.has_container_key(
        container, IOM.PiecewiseLinearBlockDecrementalOffer, PSY.EnergyReservoirStorage)
end
