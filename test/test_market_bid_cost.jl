"""
Unit tests for POM's MarketBidCost objective-function construction.

One testset per (device × formulation × cost-type) combo, each built on a single fixture
with multiple dials set to distinct values. Assertions address one observable at a time.
Scaling-sensitive behavior (dt, power-unit conversion, base_power mismatches) lives in
separate "scaling" testsets — that's where dials actually interact.

Underlying PWL math is covered by IOM — here we only verify POM's translations: that the
numbers put on a cost curve reach the container's objective coefficients as expected.
"""

const _LOAD_NAME = "load1"
const _THERMAL_NAME = "thermal1"

# A zero offer curve in SYSTEM_BASE. Used as the "absent" side when only one of the
# incremental/decremental curves is meaningful: PSY requires both offer curves to share
# a unit system, and the default `ZERO_OFFER_CURVE` is NATURAL_UNITS, so we can't leave
# the other side defaulted when the meaningful side is SYSTEM_BASE. A zero value curve is
# still treated as "absent" by the offer-side checks (which inspect slopes, not units).
const _ZERO_OFFER_SB = PSY.CostCurve(
    PSY.PiecewiseIncrementalCurve(0.0, [0.0, 0.0], [0.0]),
    PSY.SU,
)

# A static MBC with a decremental offer curve only (incremental is the zero offer curve,
# which the load-side supply check treats as "absent").
_decr_mbc(initial_input::Float64, xs::Vector{Float64}, slopes::Vector{Float64}) =
    PSY.MarketBidCost(;
        incremental_offer_curves = _ZERO_OFFER_SB,
        decremental_offer_curves = PSY.CostCurve(
            PSY.PiecewiseIncrementalCurve(initial_input, xs, slopes),
            PSY.SU,
        ),
    )

@testset "InterruptiblePowerLoad + PowerLoadDispatch + static MBC" begin
    # Pick distinct slope values so any swap between segments is visible.
    cost = _decr_mbc(0.0, [0.0, 0.5, 1.0], [3.0, 7.0])
    sys = one_bus_one_interruptible_load(cost)
    load = PSY.get_component(PSY.InterruptiblePowerLoad, sys, _LOAD_NAME)

    container = build_test_container(sys, 1:1)
    add_jump_var!(
        container, IOM.ActivePowerVariable, PSY.InterruptiblePowerLoad, _LOAD_NAME, 1)

    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerVariable, load, cost, POM.PowerLoadDispatch)

    # Decremental sign = -1, dt = 1 hr, SYSTEM_BASE ⇒ coefficient == -slope.
    @test pwl_delta_coefs(
        container, IOM.DecrementalOffer(), PSY.InterruptiblePowerLoad, _LOAD_NAME, 1,
    ) ≈ [-3.0, -7.0]
end

@testset "InterruptiblePowerLoad + PowerLoadDispatch: dt and unit conversion" begin
    # NATURAL_UNITS + 15-minute resolution.
    # slope: 3 $/MWh x 100 MW/p.u. x 0.25 hr/period = 75 $/(p.u. period)
    # x breakpoint: 200 MW x 1 p.u./100 MW = 2.0
    cost = PSY.MarketBidCost(;
        decremental_offer_curves = PSY.CostCurve(
            PSY.PiecewiseIncrementalCurve(0.0, [0.0, 200.0], [3.0]),
            PSY.NU,
        ),
    )
    sys = one_bus_one_interruptible_load(cost; system_base_power = 100.0)
    load = PSY.get_component(PSY.InterruptiblePowerLoad, sys, _LOAD_NAME)

    container = build_test_container(sys, 1:1; resolution = Dates.Minute(15))
    add_jump_var!(
        container, IOM.ActivePowerVariable, PSY.InterruptiblePowerLoad, _LOAD_NAME, 1)

    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerVariable, load, cost, POM.PowerLoadDispatch)

    @test pwl_delta_coefs(
        container, IOM.DecrementalOffer(), PSY.InterruptiblePowerLoad, _LOAD_NAME, 1,
    ) ≈ [-75.0]
    @test pwl_delta_widths(
        container, IOM.DecrementalOffer(), PSY.InterruptiblePowerLoad, _LOAD_NAME, 1,
    ) ≈ [2.0]
end

@testset "InterruptiblePowerLoad + PowerLoadDispatch + TS MBC" begin
    # TS MBC dispatches through the parameter-container path. We skip `add_parameters!`
    # (which would require real time series on the system) and populate the Decremental
    # slope/breakpoint parameters directly with distinct-per-timestep values.
    # A load has no supply (incremental) offer, so that side is the absent placeholder.
    cost = stub_ts_market_bid_cost(; incremental_trivial = true)
    sys = one_bus_one_interruptible_load(cost)
    load = PSY.get_component(PSY.InterruptiblePowerLoad, sys, _LOAD_NAME)

    container = build_test_container(sys, 1:2)
    add_jump_var!(
        container, IOM.ActivePowerVariable, PSY.InterruptiblePowerLoad, _LOAD_NAME, 1)
    add_jump_var!(
        container, IOM.ActivePowerVariable, PSY.InterruptiblePowerLoad, _LOAD_NAME, 2)

    # Slopes and breakpoints vary over time so a wiring that reads the wrong t is visible.
    slopes_mat = reshape([[3.0, 7.0], [13.0, 17.0]], 1, 2)
    breakpoints_mat = reshape([[0.0, 0.5, 1.0], [0.0, 0.2, 0.7]], 1, 2)
    setup_delta_pwl_parameters!(
        container, PSY.InterruptiblePowerLoad, [_LOAD_NAME],
        slopes_mat, breakpoints_mat, 1:2;
        dir = IOM.DecrementalOffer())

    POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerVariable, load, cost, POM.PowerLoadDispatch)

    variant = IOM.get_variant_terms(IOM.get_objective_expression(container))
    pwl = IOM.get_variable(
        container, IOM.PiecewiseLinearBlockDecrementalOffer,
        PSY.InterruptiblePowerLoad)
    @test [JuMP.coefficient(variant, pwl[(_LOAD_NAME, s, 1)]) for s in 1:2] ≈ [-3.0, -7.0]
    @test [JuMP.coefficient(variant, pwl[(_LOAD_NAME, s, 2)]) for s in 1:2] ≈ [-13.0, -17.0]

    @test pwl_delta_widths(
        container, IOM.DecrementalOffer(), PSY.InterruptiblePowerLoad, _LOAD_NAME, 1,
    ) ≈ [0.5, 0.5]
    @test pwl_delta_widths(
        container, IOM.DecrementalOffer(), PSY.InterruptiblePowerLoad, _LOAD_NAME, 2,
    ) ≈ [0.2, 0.5]
end

@testset "InterruptiblePowerLoad + PowerLoadInterruption + static MBC" begin
    # initial_input = 2 (OnVariable coef dial), plus distinct slopes for PWL.
    cost = _decr_mbc(2.0, [0.0, 0.5, 1.0], [3.0, 7.0])
    sys = one_bus_one_interruptible_load(cost)
    devs = collect(PSY.get_components(PSY.InterruptiblePowerLoad, sys))

    container = build_test_container(sys, 1:1)
    add_jump_var!(
        container, IOM.ActivePowerVariable, PSY.InterruptiblePowerLoad, _LOAD_NAME, 1)
    add_jump_var!(
        container, IOM.OnVariable, PSY.InterruptiblePowerLoad, _LOAD_NAME, 1)

    IOM.add_variable_cost!(
        container, IOM.ActivePowerVariable, devs, POM.PowerLoadInterruption)
    POM.add_proportional_cost!(
        container, IOM.OnVariable, devs, POM.PowerLoadInterruption)

    # OnVariable: coefficient = initial_input × OBJECTIVE_FUNCTION_NEGATIVE = -2.0.
    @test obj_coef(
        container, IOM.OnVariable, PSY.InterruptiblePowerLoad, _LOAD_NAME, 1,
    ) ≈ -2.0

    # PWL decremental: slope × sign × dt = -slope (dt=1, SYSTEM_BASE).
    @test pwl_delta_coefs(
        container, IOM.DecrementalOffer(), PSY.InterruptiblePowerLoad, _LOAD_NAME, 1,
    ) ≈ [-3.0, -7.0]
end

@testset "InterruptiblePowerLoad + PowerLoadInterruption + TS MBC" begin
    # A load has no supply (incremental) offer, so that side is the absent placeholder.
    cost = stub_ts_market_bid_cost(; incremental_trivial = true)
    sys = one_bus_one_interruptible_load(cost)
    devs = collect(PSY.get_components(PSY.InterruptiblePowerLoad, sys))

    container = build_test_container(sys, 1:2)
    for t in 1:2
        add_jump_var!(
            container, IOM.ActivePowerVariable, PSY.InterruptiblePowerLoad, _LOAD_NAME, t)
        add_jump_var!(
            container, IOM.OnVariable, PSY.InterruptiblePowerLoad, _LOAD_NAME, t)
    end

    # Params vary over t so reading-wrong-t bugs are visible.
    setup_delta_pwl_parameters!(
        container, PSY.InterruptiblePowerLoad, [_LOAD_NAME],
        reshape([[3.0, 7.0], [13.0, 17.0]], 1, 2),
        reshape([[0.0, 0.5, 1.0], [0.0, 0.2, 0.7]], 1, 2),
        1:2;
        dir = IOM.DecrementalOffer())
    add_test_parameter!(
        container, IOM.DecrementalCostAtMinParameter, PSY.InterruptiblePowerLoad,
        [_LOAD_NAME], 1:2, reshape([2.5, 4.5], 1, 2))

    IOM.add_variable_cost!(
        container, IOM.ActivePowerVariable, devs, POM.PowerLoadInterruption)
    POM.add_proportional_cost!(
        container, IOM.OnVariable, devs, POM.PowerLoadInterruption)

    variant = IOM.get_variant_terms(IOM.get_objective_expression(container))
    on_var = IOM.get_variable(container, IOM.OnVariable, PSY.InterruptiblePowerLoad)
    pwl = IOM.get_variable(
        container, IOM.PiecewiseLinearBlockDecrementalOffer,
        PSY.InterruptiblePowerLoad)

    # OnVariable: param × OBJECTIVE_FUNCTION_NEGATIVE.
    @test JuMP.coefficient(variant, on_var[_LOAD_NAME, 1]) ≈ -2.5
    @test JuMP.coefficient(variant, on_var[_LOAD_NAME, 2]) ≈ -4.5

    # PWL slopes in variant terms, one set per time step.
    @test [JuMP.coefficient(variant, pwl[(_LOAD_NAME, s, 1)]) for s in 1:2] ≈ [-3.0, -7.0]
    @test [JuMP.coefficient(variant, pwl[(_LOAD_NAME, s, 2)]) for s in 1:2] ≈ [-13.0, -17.0]
end

@testset "InterruptiblePowerLoad + PowerLoadDispatch: supply-side rejection" begin
    # Non-trivial incremental curve on a load should throw.
    cost = PSY.MarketBidCost(;
        incremental_offer_curves = PSY.CostCurve(
            PSY.PiecewiseIncrementalCurve(0.0, [0.0, 1.0], [5.0]),
            PSY.SU,
        ),
        decremental_offer_curves = _ZERO_OFFER_SB,
    )
    sys = one_bus_one_interruptible_load(cost)
    load = PSY.get_component(PSY.InterruptiblePowerLoad, sys, _LOAD_NAME)

    container = build_test_container(sys, 1:1)
    add_jump_var!(
        container, IOM.ActivePowerVariable, PSY.InterruptiblePowerLoad, _LOAD_NAME, 1)

    @test_throws ArgumentError POM.add_variable_cost_to_objective!(
        container, IOM.ActivePowerVariable, load, cost, POM.PowerLoadDispatch)
end

@testset "ThermalStandard + ThermalBasicUnitCommitment + static MBC" begin
    # Distinct values on every dial so a wiring swap is visible.
    mbc = PSY.MarketBidCost(;
        minimum_energy_offer = PSY.LinearCurve(10.0),  # unused by thermal objective; kept as a
        # canary for accidental wiring into obj.
        start_up = (hot = 50.0, warm = 80.0, cold = 100.0),
        shut_down = PSY.LinearCurve(30.0),
        incremental_offer_curves = PSY.CostCurve(
            PSY.PiecewiseIncrementalCurve(2.5, [0.1, 0.5, 1.0], [3.0, 7.0]),
            PSY.SU,
        ),
        decremental_offer_curves = _ZERO_OFFER_SB,
    )
    sys = one_bus_one_thermal(mbc; name = _THERMAL_NAME)
    devs = collect(PSY.get_components(PSY.ThermalStandard, sys))

    container = build_test_container(sys, 1:1)
    for V in (IOM.ActivePowerVariable, IOM.OnVariable, IOM.StartVariable, IOM.StopVariable)
        add_jump_var!(container, V, PSY.ThermalStandard, _THERMAL_NAME, 1)
    end

    IOM.add_variable_cost!(
        container, IOM.ActivePowerVariable, devs, POM.ThermalBasicUnitCommitment)
    IOM.add_start_up_cost!(
        container, IOM.StartVariable, devs, POM.ThermalBasicUnitCommitment)
    IOM.add_shut_down_cost!(
        container, IOM.StopVariable, devs, POM.ThermalBasicUnitCommitment)
    POM.add_proportional_cost!(
        container, IOM.OnVariable, devs, POM.ThermalBasicUnitCommitment)

    # StartVariable takes the max over StartUpStages for basic UC formulations.
    @test obj_coef(
        container, IOM.StartVariable, PSY.ThermalStandard, _THERMAL_NAME, 1,
    ) ≈ 100.0
    # StopVariable gets the LinearCurve shut_down's proportional term.
    @test obj_coef(
        container, IOM.StopVariable, PSY.ThermalStandard, _THERMAL_NAME, 1,
    ) ≈ 30.0
    # OnVariable picks up the incremental curve's initial_input (cost-at-min-gen).
    @test obj_coef(
        container, IOM.OnVariable, PSY.ThermalStandard, _THERMAL_NAME, 1,
    ) ≈ 2.5
    # Incremental PWL slopes (positive sign for supply, dt=1, SYSTEM_BASE).
    @test pwl_delta_coefs(
        container, IOM.IncrementalOffer(), PSY.ThermalStandard, _THERMAL_NAME, 1,
    ) ≈ [3.0, 7.0]
end

@testset "ThermalStandard + ThermalBasicUnitCommitment + TS MBC" begin
    # A generator has no demand (decremental) offer, so that side is the absent placeholder.
    cost = stub_ts_market_bid_cost(; decremental_trivial = true)
    sys = one_bus_one_thermal(cost; name = _THERMAL_NAME)
    devs = collect(PSY.get_components(PSY.ThermalStandard, sys))

    container = build_test_container(sys, 1:2)
    for V in (IOM.ActivePowerVariable, IOM.OnVariable, IOM.StartVariable, IOM.StopVariable),
        t in 1:2

        add_jump_var!(container, V, PSY.ThermalStandard, _THERMAL_NAME, t)
    end

    # All param values differ between t=1 and t=2 to catch off-by-t wiring.
    setup_delta_pwl_parameters!(
        container, PSY.ThermalStandard, [_THERMAL_NAME],
        reshape([[3.0, 7.0], [13.0, 17.0]], 1, 2),
        reshape([[0.1, 0.5, 1.0], [0.1, 0.3, 0.9]], 1, 2),
        1:2;
        dir = IOM.IncrementalOffer())
    add_test_parameter!(
        container, IOM.IncrementalCostAtMinParameter, PSY.ThermalStandard,
        [_THERMAL_NAME], 1:2, reshape([2.5, 4.5], 1, 2))
    # Scalar Float64 startup — covers the basic path. A separate testset below covers
    # the Tuple-valued path used by multi-start formulations.
    add_test_parameter!(
        container, IOM.StartupCostParameter, PSY.ThermalStandard,
        [_THERMAL_NAME], 1:2, reshape([100.0, 110.0], 1, 2))
    add_test_parameter!(
        container, IOM.ShutdownCostParameter, PSY.ThermalStandard,
        [_THERMAL_NAME], 1:2, reshape([30.0, 45.0], 1, 2))

    IOM.add_variable_cost!(
        container, IOM.ActivePowerVariable, devs, POM.ThermalBasicUnitCommitment)
    IOM.add_start_up_cost!(
        container, IOM.StartVariable, devs, POM.ThermalBasicUnitCommitment)
    IOM.add_shut_down_cost!(
        container, IOM.StopVariable, devs, POM.ThermalBasicUnitCommitment)
    POM.add_proportional_cost!(
        container, IOM.OnVariable, devs, POM.ThermalBasicUnitCommitment)

    variant = IOM.get_variant_terms(IOM.get_objective_expression(container))
    for (V, expected_t1, expected_t2) in (
        (IOM.StartVariable, 100.0, 110.0),
        (IOM.StopVariable, 30.0, 45.0),
        (IOM.OnVariable, 2.5, 4.5),
    )
        var = IOM.get_variable(container, V, PSY.ThermalStandard)
        @test JuMP.coefficient(variant, var[_THERMAL_NAME, 1]) ≈ expected_t1
        @test JuMP.coefficient(variant, var[_THERMAL_NAME, 2]) ≈ expected_t2
    end
    pwl = IOM.get_variable(
        container, IOM.PiecewiseLinearBlockIncrementalOffer, PSY.ThermalStandard)
    @test [JuMP.coefficient(variant, pwl[(_THERMAL_NAME, s, 1)]) for s in 1:2] ≈ [3.0, 7.0]
    @test [JuMP.coefficient(variant, pwl[(_THERMAL_NAME, s, 2)]) for s in 1:2] ≈
          [13.0, 17.0]
end

@testset "ThermalMultiStart + ThermalMultiStartUnitCommitment + TS MBC (Tuple startup)" begin
    # Multi-start UC splits the startup cost across three variables (hot/warm/cold),
    # each reading one field of the Tuple-valued `StartupCostParameter`. This exercises
    # `param .* mult` with a Tuple cell, plus the per-stage dispatch in `start_up_cost`.
    cost = stub_ts_market_bid_cost()
    ms_name = "thermal_ms1"
    sys = one_bus_one_thermal_multistart(cost; name = ms_name)
    devs = collect(PSY.get_components(PSY.ThermalMultiStart, sys))

    container = build_test_container(sys, 1:1)
    for V in (POM.HotStartVariable, POM.WarmStartVariable, POM.ColdStartVariable)
        add_jump_var!(container, V, PSY.ThermalMultiStart, ms_name, 1)
    end

    # (hot, warm, cold) = (50, 100, 150). Each stage's variable should see its own field.
    add_test_parameter!(
        container, IOM.StartupCostParameter, PSY.ThermalMultiStart,
        [ms_name], 1:1, reshape([(50.0, 100.0, 150.0)], 1, 1))

    for V in (POM.HotStartVariable, POM.WarmStartVariable, POM.ColdStartVariable)
        IOM.add_start_up_cost!(
            container, V, devs, POM.ThermalMultiStartUnitCommitment)
    end

    variant = IOM.get_variant_terms(IOM.get_objective_expression(container))
    for (V, expected) in (
        (POM.HotStartVariable, 50.0),
        (POM.WarmStartVariable, 100.0),
        (POM.ColdStartVariable, 150.0),
    )
        var = IOM.get_variable(container, V, PSY.ThermalMultiStart)
        @test JuMP.coefficient(variant, var[ms_name, 1]) ≈ expected
    end
end

# A static thermal offer with breakpoints starting at `x1` (system base).
_thermal_offer(x1) = PSY.MarketBidCost(;
    incremental_offer_curves = PSY.CostCurve(
        PSY.PiecewiseIncrementalCurve(0.0, [x1, 0.5, 1.0], [3.0, 7.0]),
        PSY.SU,
    ),
    decremental_offer_curves = _ZERO_OFFER_SB,
)

# Container with only ActivePowerVariable: dispatch formulations have no OnVariable.
function _dispatch_container(cost, ::Type{F}, time_steps = 1:1) where {F}
    sys = one_bus_one_thermal(cost; name = _THERMAL_NAME)
    container = build_test_container(sys, time_steps)
    for t in time_steps
        add_jump_var!(
            container, IOM.ActivePowerVariable, PSY.ThermalStandard, _THERMAL_NAME, t)
    end
    devs = collect(PSY.get_components(PSY.ThermalStandard, sys))
    return container, devs
end

@testset "ThermalStandard + thermal dispatch + static MBC" begin
    # p == Σδ + x1: the offer's first breakpoint is a constant offset.
    for (F, x1) in (
        (POM.ThermalBasicDispatch, 0.1),
        (POM.ThermalStandardDispatch, 0.1),
        (POM.ThermalDispatchNoMin, 0.0),
    )
        container, devs = _dispatch_container(_thermal_offer(x1), F)
        IOM.add_variable_cost!(container, IOM.ActivePowerVariable, devs, F)
        @test pwl_delta_coefs(
            container, IOM.IncrementalOffer(), PSY.ThermalStandard, _THERMAL_NAME, 1,
        ) ≈ [3.0, 7.0]
        con = IOM.get_constraint(
            container,
            IOM.PiecewiseLinearBlockIncrementalOfferConstraint,
            PSY.ThermalStandard,
        )[
            _THERMAL_NAME,
            1,
        ]
        p = IOM.get_variable(container, IOM.ActivePowerVariable, PSY.ThermalStandard)
        @test JuMP.normalized_coefficient(con, p[_THERMAL_NAME, 1]) ≈ 1.0
        @test JuMP.normalized_rhs(con) ≈ x1
    end
end

@testset "ThermalDispatchNoMin rejects offers starting above zero" begin
    container, devs = _dispatch_container(_thermal_offer(0.1), POM.ThermalDispatchNoMin)
    @test_throws "start at zero power" IOM.add_variable_cost!(
        container, IOM.ActivePowerVariable, devs, POM.ThermalDispatchNoMin)

    # Time-series offers are checked per step: only t = 2 starts above zero.
    cost = stub_ts_market_bid_cost(; decremental_trivial = true)
    container, devs = _dispatch_container(cost, POM.ThermalDispatchNoMin, 1:2)
    setup_delta_pwl_parameters!(
        container, PSY.ThermalStandard, [_THERMAL_NAME],
        reshape([[3.0, 7.0], [3.0, 7.0]], 1, 2),
        reshape([[0.0, 0.5, 1.0], [0.2, 0.5, 1.0]], 1, 2),
        1:2;
        dir = IOM.IncrementalOffer())
    @test_throws "start at zero power" IOM.add_variable_cost!(
        container, IOM.ActivePowerVariable, devs, POM.ThermalDispatchNoMin)
end

# `case` with Park City (limits 65-170 MW) offering one block from `x1` MW at `price`.
function _dispatch_offer_system(x1, price; case = "c_sys5_uc")
    sys = PSB.build_system(PSITestSystems, case)
    g = PSY.get_component(PSY.ThermalStandard, sys, "Park City")
    PSY.set_operation_cost!(
        g,
        PSY.MarketBidCost(;
            minimum_energy_offer = PSY.LinearCurve(0.0),
            start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
            shut_down = PSY.LinearCurve(0.0),
            incremental_offer_curves = PSY.make_market_bid_curve(
                [x1, PSY.get_max_active_power(g, u"NU")], [price], 0.0;
                power_units = IS.NaturalUnit(),
            ),
        ),
    )
    return sys
end

function _dispatch_offer_model(sys, ::Type{F}) where {F}
    template = get_thermal_dispatch_template_network(CopperPlateNetworkModel)
    set_device_model!(template, PSY.ThermalStandard, F)
    return DecisionModel(template, sys; optimizer = HiGHS_optimizer)
end

@testset "Market offers build and solve under thermal dispatch" begin
    # A dear offer from zero: NoMin backs Park City off below its 65 MW minimum.
    # ThermalStandardDispatch is infeasible on c_sys5_uc, offers or not.
    for (F, x1, price, below_min, case) in (
        (POM.ThermalBasicDispatch, 65.0, 5.0, false, "c_sys5_uc"),
        (POM.ThermalStandardDispatch, 65.0, 5.0, false, "c_sys5"),
        (POM.ThermalDispatchNoMin, 0.0, 1.0e4, true, "c_sys5_uc"),
    )
        model = _dispatch_offer_model(_dispatch_offer_system(x1, price; case), F)
        @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        container = IOM.get_optimization_container(model)
        base = IOM.get_model_base_power(container)
        p = IOM.get_variable(container, IOM.ActivePowerVariable, PSY.ThermalStandard)
        blocks = IOM.get_variable(
            container, IOM.PiecewiseLinearBlockIncrementalOffer, PSY.ThermalStandard)
        for t in axes(p)[2]
            δ = sum(
                JuMP.value(v) for (k, v) in blocks.data if k[1] == "Park City" && k[3] == t
            )
            @test JuMP.value(p["Park City", t]) * base ≈ δ * base + x1 atol = 1e-4
        end
        @test any(JuMP.value(p["Park City", t]) * base < 65.0 - 1e-3 for t in axes(p)[2]) ==
              below_min
    end
    dir = mktempdir()
    model =
        _dispatch_offer_model(_dispatch_offer_system(65.0, 5.0), POM.ThermalDispatchNoMin)
    @test build!(model; output_dir = dir) == IOM.ModelBuildStatus.FAILED
    @test occursin(
        "start at zero power",
        read(joinpath(dir, "operation_problem.log"), String),
    )
end

# `case` with Park City at 65-170 MW, offering 0.1 $/MWh from `x1` to 120 MW and `price2`
# from 120 to 170 MW.
function _two_block_offer_system(case, x1, price2)
    sys = PSB.build_system(PSITestSystems, case)
    g = PSY.get_component(PSY.ThermalStandard, sys, "Park City")
    PSY.set_active_power_limits!(g, (min = 0.65 * u"SU", max = 1.70 * u"SU"))
    PSY.set_operation_cost!(
        g,
        PSY.MarketBidCost(;
            minimum_energy_offer = PSY.LinearCurve(0.0),
            start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
            shut_down = PSY.LinearCurve(0.0),
            incremental_offer_curves = PSY.make_market_bid_curve(
                [x1, 120.0, 170.0], [0.1, price2], 0.0;
                power_units = IS.NaturalUnit(),
            ),
        ),
    )
    return sys
end

# Park City's commitment status at each step: OnVariable, or OnStatusParameter for
# ThermalCompactDispatch.
function _park_city_status(container, ::Type{F}) where {F}
    F == ThermalCompactDispatch && return [
        IOM.get_parameter_array(container, OnStatusParameter, PSY.ThermalStandard)[
            "Park City",
            t,
        ] for t in IOM.get_time_steps(container)
    ]
    on = IOM.get_variable(container, OnVariable, PSY.ThermalStandard)
    return [JuMP.value(on["Park City", t]) for t in IOM.get_time_steps(container)]
end

# Park City's output in MW at each step. Compact formulations add P_min (65 MW) back.
function _park_city_power(container, ::Type{F}) where {F}
    base = IOM.get_model_base_power(container)
    steps = IOM.get_time_steps(container)
    if F <: Union{POM.AbstractCompactUnitCommitment, ThermalCompactDispatch}
        p̂ = IOM.get_variable(container, PowerAboveMinimumVariable, PSY.ThermalStandard)
        on = _park_city_status(container, F)
        return [65.0 * on[t] + JuMP.value(p̂["Park City", t]) * base for t in steps]
    end
    p = IOM.get_variable(container, ActivePowerVariable, PSY.ThermalStandard)
    return [JuMP.value(p["Park City", t]) * base for t in steps]
end

@testset "Market offers under compact formulations start at the first breakpoint" begin
    # #436: compact power is measured above P_min, so the blocks offset by x1 - P_min.
    # The compact UC result must match ThermalBasicUnitCommitment on the same offer.
    for (F, case, x1, price2, p_top) in (
        (ThermalBasicCompactUnitCommitment, "c_sys5_uc", 100.0, 0.2, 170.0),
        (ThermalBasicCompactUnitCommitment, "c_sys5_uc", 0.0, 1.0e5, 120.0),
        (ThermalCompactDispatch, "c_sys5", 100.0, 0.2, 170.0),
    )
        model = _dispatch_offer_model(_two_block_offer_system(case, x1, price2), F)
        @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        container = IOM.get_optimization_container(model)
        base = IOM.get_model_base_power(container)
        p = _park_city_power(container, F)
        @test maximum(p) ≈ p_top atol = 1e-4

        # Blocks start at x1 in absolute power: p == x1·on + Σδ.
        on = _park_city_status(container, F)
        blocks = IOM.get_variable(
            container, IOM.PiecewiseLinearBlockIncrementalOffer, PSY.ThermalStandard)
        for t in eachindex(p)
            δ = sum(
                JuMP.value(v) for (k, v) in blocks.data if k[1] == "Park City" && k[3] == t
            )
            @test p[t] ≈ x1 * on[t] + δ * base atol = 1e-4
        end

        F == ThermalCompactDispatch && continue
        basic = _dispatch_offer_model(
            _two_block_offer_system(case, x1, price2), ThermalBasicUnitCommitment)
        @test build!(basic; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
        @test solve!(basic) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        basic_container = IOM.get_optimization_container(basic)
        @test JuMP.objective_value(IOM.get_jump_model(container)) ≈
              JuMP.objective_value(IOM.get_jump_model(basic_container)) rtol = 1e-6
        @test p ≈ _park_city_power(basic_container, ThermalBasicUnitCommitment) atol = 1e-4
    end
end

@testset "Market offers with SemiContinuousFeedforward under thermal dispatch" begin
    # #436: the offset follows OnStatusParameter, so an off unit (status 0) gets p = 0.
    template = get_thermal_dispatch_template_network(
        NetworkModel(CopperPlateNetworkModel; use_slacks = true))
    device_model = DeviceModel(PSY.ThermalStandard, ThermalBasicDispatch)
    attach_feedforward!(
        device_model,
        SemiContinuousFeedforward(;
            component_type = PSY.ThermalStandard,
            source = OnVariable,
            affected_values = [ActivePowerVariable],
        ),
    )
    set_device_model!(template, device_model)
    model = DecisionModel(
        template, _dispatch_offer_system(65.0, 5.0); optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    container = IOM.get_optimization_container(model)
    on_status = IOM.get_parameter_array(container, OnStatusParameter, PSY.ThermalStandard)
    p = IOM.get_variable(container, IOM.ActivePowerVariable, PSY.ThermalStandard)
    for t in axes(p)[2]
        @test JuMP.value(p["Park City", t]) ≈ 0.0 atol = 1e-6
        @test on_status["Park City", t] == 0.0
    end
end

@testset "Market offers build and solve under hydro turbine dispatch" begin
    # #436: hydro dispatch has no OnVariable, so the offer offset is a constant.
    sys = PSB.build_system(PSITestSystems, "c_sys5_hy_turbine_energy")
    h = first(PSY.get_components(PSY.HydroTurbine, sys))
    x1 = 0.1 * PSY.get_max_active_power(h, u"NU")
    PSY.set_operation_cost!(
        h,
        PSY.MarketBidCost(;
            minimum_energy_offer = PSY.LinearCurve(0.0),
            start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
            shut_down = PSY.LinearCurve(0.0),
            incremental_offer_curves = PSY.make_market_bid_curve(
                [x1, PSY.get_max_active_power(h, u"NU")], [1.0], 0.0;
                power_units = IS.NaturalUnit(),
            ),
        ),
    )
    template = get_thermal_dispatch_template_network(
        NetworkModel(CopperPlateNetworkModel; use_slacks = true))
    set_device_model!(template, PSY.HydroTurbine, HydroTurbineEnergyDispatch)
    set_device_model!(
        template,
        DeviceModel(
            PSY.HydroReservoir,
            HydroEnergyModelReservoir;
            attributes = Dict{String, Any}(
                "energy_target" => false, "hydro_budget" => false),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    container = IOM.get_optimization_container(model)
    con = IOM.get_constraint(
        container, IOM.PiecewiseLinearBlockIncrementalOfferConstraint, PSY.HydroTurbine,
    )
    base = IOM.get_model_base_power(container)
    @test JuMP.normalized_rhs(con[PSY.get_name(h), 1]) ≈ x1 / base
end
