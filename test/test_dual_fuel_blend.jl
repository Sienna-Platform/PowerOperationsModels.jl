const BLENDED = DualFuelCurve(;
    first_fuel_curve = PiecewisePointCurve([
        (100.0, 900.0),
        (200.0, 1700.0),
        (300.0, 2700.0),
    ]),
    second_fuel_curve = PiecewisePointCurve([
        (100.0, 950.0), (250.0, 2225.0), (300.0, 2725.0)]),
    fuel_units = u"MMBtu", first_fuel_cost = 3.0, second_fuel_cost = 5.0,
    second_fuel_share = 0.3)

const F1 = get_first_fuel_curve(blended_curve())
const F2 = get_second_fuel_curve(blended_curve())

const FORMULATIONS = (ThermalBasicUnitCommitment, ThermalStandardUnitCommitment,
    ThermalBasicDispatch, ThermalStandardDispatch, ThermalDispatchNoMin,
    ThermalBasicCompactUnitCommitment, ThermalCompactUnitCommitment,
    ThermalCompactDispatch)

# Linear interpolation of a point curve, written here to check POM's points independently.
# Below the first point it continues along the first segment, as ThermalDispatchNoMin does.
function _interp(curve::PiecewisePointCurve, p::Float64)
    pts = get_points(curve)
    i = clamp(searchsortedlast([q.x for q in pts], p), 1, length(pts) - 1)
    a, b = pts[i], pts[i + 1]
    return a.y + (b.y - a.y) * (p - a.x) / (b.x - a.x)
end

# Expected fuel, or cost with prices `c1` and `c2`, of Alta in one step at output `p` MW.
# A unit committed off burns nothing; a dispatch unit is always on.
function _expected(F, p, share; dt = 1.0, c1 = 1.0, c2 = 1.0)
    F <: POM.AbstractThermalUnitCommitment && p < 1e-6 && return 0.0
    return dt * ((1.0 - share) * c1 * _interp(F1, p) + share * c2 * _interp(F2, p))
end

# One set of piecewise variables on the union of both curves' points, plus the zero point
# that ThermalDispatchNoMin starts from.
_blend_point_count(F) =
    length(union(IS.get_x_coords(F1), IS.get_x_coords(F2))) +
    (F === ThermalDispatchNoMin ? 1 : 0)

# `c_sys5_uc` cannot hold every unit at minimum output, so dispatch runs use `c_sys5`,
# with Alta's 20 MW minimum of `c_sys5_uc` so the blend curves cover its output range.
function _set_alta_min!(sys)
    alta = PSY.get_component(ThermalStandard, sys, "Alta")
    PSY.set_active_power_limits!(alta, (min = 0.2 * u"SU", max = 0.4 * u"SU"))
    return
end
_blend_system_name(F) = F <: POM.AbstractThermalUnitCommitment ? "c_sys5_uc" : "c_sys5"
_blend_system_fix(F) = F <: POM.AbstractThermalUnitCommitment ? identity : _set_alta_min!

# Alta's start-up and shut-down costs are zeroed so its production cost is its fuel cost.
function _free_starts!(sys)
    op = PSY.get_operation_cost(PSY.get_component(ThermalStandard, sys, "Alta"))
    PSY.set_start_up!(op, 0.0)
    PSY.set_shut_down!(op, 0.0)
    return
end

# Alta of `system` with `curve` as its variable cost; `change!` edits the system after.
function _blend_system(curve, F;
    system = _blend_system_name(F), change! = _blend_system_fix(F))
    sys = PSB.build_system(PSITestSystems, system)
    set_unit_variable_cost!(sys, "Alta", curve)
    change!(sys)
    return sys
end

function _blend_model(sys::PSY.System, ::Type{F};
    device_model = DeviceModel(ThermalStandard, F)) where {F}
    template = PowerOperationsProblemTemplate(NetworkModel(CopperPlateNetworkModel))
    set_device_model!(template, device_model)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    optimizer = JuMP.optimizer_with_attributes(
        HiGHS.Optimizer, "mip_rel_gap" => 0.0, "log_to_console" => false)
    # Results are read from the container. No system bundle: PowerSystems refuses to export
    # a system base curve.
    return DecisionModel(template, sys; optimizer = optimizer, initialize_model = false,
        system_to_file = false)
end

# Builds and solves on a copper plate. Per step: Alta's output in MW, its
# ProductionCostExpression and its FuelConsumptionExpression; and Alta's piecewise points.
function _blend_cost(sys::PSY.System, ::Type{F}) where {F}
    model = _blend_model(sys, F)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    container = IOM.get_optimization_container(model)
    steps = IOM.get_time_steps(container)
    base_power = IOM.get_model_base_power(container)
    # A compact formulation's power variable is the output above the minimum.
    compact = F <: Union{POM.AbstractCompactUnitCommitment, ThermalCompactDispatch}
    p = IOM.get_variable(container,
        compact ? PowerAboveMinimumVariable : ActivePowerVariable, ThermalStandard)
    on = if IOM.has_container_key(container, OnVariable, ThermalStandard)
        IOM.get_variable(container, OnVariable, ThermalStandard)
    else
        nothing
    end
    pmin = if compact
        PSY.get_active_power_limits(
            PSY.get_component(ThermalStandard, sys, "Alta"), u"SU").min
    else
        0.0
    end
    output_mw = [
        base_power * (
            JuMP.value(p["Alta", t]) +
            pmin * (isnothing(on) ? 1.0 : JuMP.value(on["Alta", t]))
        ) for t in steps]
    cost = IOM.get_expression(container, ProductionCostExpression, ThermalStandard)
    fuel = IOM.get_expression(container, FuelConsumptionExpression, ThermalStandard)
    pwl = IOM.get_variable(container, PiecewiseLinearCostVariable, ThermalStandard)
    return (
        container = container,
        objective = JuMP.objective_value(IOM.get_jump_model(container)),
        output_mw = output_mw,
        unit_cost = [JuMP.value(cost["Alta", t]) for t in steps],
        unit_fuel = [JuMP.value(fuel["Alta", t]) for t in steps],
        pwl_points = count(k -> k[1] == "Alta" && k[3] == 1, eachindex(pwl)),
    )
end

_objective(curve, F; kw...) = _blend_cost(_blend_system(curve, F; kw...), F).objective

# The build log of a model whose build must fail.
function _failed_build_log(sys::PSY.System, ::Type{F}; kw...) where {F}
    dir = mktempdir(; cleanup = true)
    @test build!(_blend_model(sys, F; kw...); output_dir = dir,
        console_level = Logging.AboveMaxLevel) == IOM.ModelBuildStatus.FAILED
    return read(joinpath(dir, "operation_problem.log"), String)
end

@testset "blended_fuel_points" begin
    pts = POM.blended_fuel_points(BLENDED, (min = 100.0, max = 300.0))
    @test pts.x == [100.0, 200.0, 250.0, 300.0]
    @test pts.first ≈ [900.0, 1700.0, 2200.0, 2700.0]
    @test pts.second ≈ [950.0, 1800.0, 2225.0, 2725.0]
    linear = DualFuelCurve(; first_fuel_curve = LinearCurve(8.0, 100.0),
        second_fuel_curve = LinearCurve(9.0, 50.0), fuel_units = u"MMBtu",
        first_fuel_cost = 3.0, second_fuel_cost = 5.0, second_fuel_share = 0.5)
    lin = POM.blended_fuel_points(linear, (min = 50.0, max = 200.0))
    @test lin.x == [50.0, 200.0]
    @test lin.first ≈ [500.0, 1700.0] && lin.second ≈ [500.0, 1850.0]
    # incremental and average rate input give the same points as the input-output form
    inc = DualFuelCurve(;
        first_fuel_curve = PiecewiseIncrementalCurve(900.0, [100.0, 200.0, 300.0],
            [8.0, 10.0]),
        second_fuel_curve = PiecewiseIncrementalCurve(950.0, [100.0, 250.0, 300.0],
            [8.5, 10.0]),
        fuel_units = u"MMBtu", first_fuel_cost = 3.0, second_fuel_cost = 5.0,
        second_fuel_share = 0.3)
    avg = DualFuelCurve(;
        first_fuel_curve = PiecewiseAverageCurve(900.0, [100.0, 200.0, 300.0],
            [1700.0 / 200.0, 2700.0 / 300.0]),
        second_fuel_curve = PiecewiseAverageCurve(950.0, [100.0, 250.0, 300.0],
            [2225.0 / 250.0, 2725.0 / 300.0]),
        fuel_units = u"MMBtu", first_fuel_cost = 3.0, second_fuel_cost = 5.0,
        second_fuel_share = 0.3)
    for curve in (inc, avg)
        other = POM.blended_fuel_points(curve, (min = 100.0, max = 300.0))
        @test other.x == pts.x
        @test other.first ≈ pts.first
        @test other.second ≈ pts.second
    end
    # Both curves cover the same range up to rounding; neither is read outside its points.
    near = DualFuelCurve(;
        first_fuel_curve = PiecewisePointCurve([
            (20.0, 200.0),
            (30.0, 300.0),
            (40.0, 420.0),
        ]),
        second_fuel_curve = PiecewisePointCurve([
            (20.0 - 1e-10, 210.0), (35.0, 380.0), (40.0, 440.0)]),
        fuel_units = u"MMBtu", first_fuel_cost = 3.0, second_fuel_cost = 5.0,
        second_fuel_share = 0.5)
    clipped = POM.blended_fuel_points(near, (min = 20.0, max = 40.0))
    @test clipped.x == [20.0, 30.0, 35.0, 40.0]
    @test clipped.first ≈ [200.0, 300.0, 360.0, 420.0]
    @test clipped.second ≈ [210.0, 380.0 - 170.0 / 3.0, 380.0, 440.0] rtol = 1e-6
end

@testset "A blend at share 0 or 1 is the single fuel: $F" for F in FORMULATIONS
    # Second price 3.0, so Alta also dispatches on the second fuel alone.
    for (share, single) in
        ((0.0, FuelCurve(F1, u"MMBtu", 3.0)), (1.0, FuelCurve(F2, u"MMBtu", 3.0)))
        blend = _blend_cost(
            _blend_system(blended_curve(; share, second_price = 3.0), F), F)
        @test any(>(0.0), blend.output_mw)
        @test blend.objective ≈ _objective(single, F) rtol = 1e-6
        @test blend.pwl_points == _blend_point_count(F)
        # Checked against the curves at Alta's own output: the single fuel run can dispatch
        # Alta differently at the same cost, since F1's top segment ties another unit.
        for (p, fuel) in zip(blend.output_mw, blend.unit_fuel)
            @test fuel ≈ _expected(F, p, share) rtol = 1e-6 atol = 1e-6
        end
    end
end

@testset "No double dip: equal curves and prices blend to the single fuel: $F" for F in
                                                                                   FORMULATIONS
    same = DualFuelCurve(; first_fuel_curve = F1, second_fuel_curve = F1,
        fuel_units = u"MMBtu", first_fuel_cost = 3.0, second_fuel_cost = 3.0,
        second_fuel_share = 0.4)
    @test _objective(same, F) ≈ _objective(FuelCurve(F1, u"MMBtu", 3.0), F) rtol = 1e-6
end

@testset "ThermalMultiStartUnitCommitment prices the blend at its points" begin
    F = ThermalMultiStartUnitCommitment
    # 101_CT_1 of c_sys5_pglib, a ThermalMultiStart, runs from 8 to 20 MW.
    first_curve = PiecewisePointCurve([(8.0, 72.0), (14.0, 132.0), (20.0, 204.0)])
    second_curve = PiecewisePointCurve([(8.0, 76.0), (17.0, 175.0), (20.0, 214.0)])
    x = sort(union(IS.get_x_coords(first_curve), IS.get_x_coords(second_curve)))
    blend(share) = DualFuelCurve(; first_fuel_curve = first_curve,
        second_fuel_curve = second_curve, fuel_units = u"MMBtu", first_fuel_cost = 3.0,
        second_fuel_cost = 5.0, second_fuel_share = share)
    # Objective coefficients of the unit's piecewise variables at t = 1, in point order.
    function coefficients(curve)
        sys = PSB.build_system(PSITestSystems, "c_sys5_pglib")
        set_unit_variable_cost!(sys, "101_CT_1", curve)
        model = _blend_model(sys, F; device_model = DeviceModel(ThermalMultiStart, F))
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        c = IOM.get_optimization_container(model)
        @test IOM.get_resolution(c) == Hour(1)
        objective = JuMP.objective_function(IOM.get_jump_model(c))
        pwl = IOM.get_variable(c, PiecewiseLinearCostVariable, ThermalMultiStart)
        n = count(k -> k[1] == "101_CT_1" && k[3] == 1, eachindex(pwl))
        return [JuMP.coefficient(objective, pwl["101_CT_1", i, 1]) for i in 1:n]
    end
    @test coefficients(blend(0.3)) ≈ [
        0.7 * 3.0 * _interp(first_curve, p) + 0.3 * 5.0 * _interp(second_curve, p) for
        p in x
    ]
    at_share_zero = coefficients(blend(0.0))
    single = coefficients(FuelCurve(first_curve, u"MMBtu", 3.0))
    @test at_share_zero[[findfirst(==(p), x) for p in IS.get_x_coords(first_curve)]] ≈
          single
end

# Hourly runs in every formulation, and 5-minute steps under ThermalDispatchNoMin.
const FORMULA_CASES = (
    [(F, _blend_system_name(F), 1.0) for F in FORMULATIONS]...,
    (ThermalDispatchNoMin, "c_sys5_ed", 5.0 / 60.0),
)

@testset "Blend at share 0.3 matches the formula: $F on $system" for (F, system, dt) in
                                                                     FORMULA_CASES
    change! = sys -> (_blend_system_fix(F)(sys); _free_starts!(sys))
    run = _blend_cost(_blend_system(blended_curve(), F; system, change!), F)
    @test any(>(0.0), run.output_mw)
    for (p, unit_cost, unit_fuel) in zip(run.output_mw, run.unit_cost, run.unit_fuel)
        @test unit_cost ≈ _expected(F, p, 0.3; dt, c1 = 3.0, c2 = 5.0) rtol = 1e-6 atol =
            1e-6
        @test unit_fuel ≈ _expected(F, p, 0.3; dt) rtol = 1e-6 atol = 1e-6
    end
end

@testset "Blend cost scales with the step length: share $share" for (share, single) in (
    (0.0, FuelCurve(F1, u"MMBtu", 3.0)), (1.0, FuelCurve(F2, u"MMBtu", 3.0)))
    # 5-minute steps: both paths must price fuel per step, not per hour.
    F = ThermalDispatchNoMin
    blend = _blend_cost(
        _blend_system(blended_curve(; share, second_price = 3.0), F; system = "c_sys5_ed"),
        F)
    @test any(>(0.0), blend.output_mw)
    @test blend.objective ≈ _objective(single, F; system = "c_sys5_ed") rtol = 1e-6
    for (p, fuel) in zip(blend.output_mw, blend.unit_fuel)
        @test fuel ≈ _expected(F, p, share; dt = 5.0 / 60.0) rtol = 1e-6 atol = 1e-6
    end
end

@testset "VOM is priced once on the unit's output: $F" for F in FORMULATIONS
    # VOM can move Alta's dispatch, so the blend is checked against the single fuel path.
    with_vom = DualFuelCurve(; first_fuel_curve = F1, second_fuel_curve = F2,
        fuel_units = u"MMBtu", first_fuel_cost = 3.0, second_fuel_cost = 5.0,
        second_fuel_share = 0.0, vom_cost = LinearCurve(2.0))
    single = FuelCurve(F1, u"MMBtu", 3.0, LinearCurve(0.0), LinearCurve(2.0))
    vom = _blend_cost(_blend_system(with_vom, F), F)
    @test any(>(0.0), vom.output_mw)
    @test vom.objective ≈ _objective(single, F) rtol = 1e-6
    @test vom.objective > _objective(blended_curve(; share = 0.0), F)
end

@testset "A blend in system base prices as in natural units: $F" for F in (
    ThermalStandardUnitCommitment, ThermalCompactDispatch)
    function to_system_base!(sys)
        _blend_system_fix(F)(sys)
        alta = PSY.get_component(ThermalStandard, sys, "Alta")
        curve = IS.convert_power_units(alta, blended_curve(), u"SU")
        @test IS.get_power_units(curve) isa IS.SystemBaseUnit
        set_unit_variable_cost!(sys, "Alta", curve)
        return
    end
    @test _objective(blended_curve(), F; change! = to_system_base!) ≈
          _objective(blended_curve(), F) rtol = 1e-6
end

@testset "A blend on a 50 MVA unit prices as on 100 MVA: $F, $units" for F in (
        ThermalStandardUnitCommitment, ThermalCompactDispatch),
    units in (u"NU", u"CU")

    function rebase!(sys)
        _blend_system_fix(F)(sys)
        alta = PSY.get_component(ThermalStandard, sys, "Alta")
        PSY.rebase_component!(alta, 50.0)
        @test PSY.get_base_power(alta, u"NU") == 50.0
        set_unit_variable_cost!(
            sys,
            "Alta",
            IS.convert_power_units(alta, blended_curve(), units),
        )
        return
    end
    @test _objective(blended_curve(), F; change! = rebase!) ≈
          _objective(blended_curve(), F) rtol = 1e-6
end

@testset "ThermalDispatchNoMin rejects a blend with negative fuel at zero output" begin
    # The first curve's first segment, 10 MMBtu/MWh from 50 MMBtu at 15 MW, is -100 at zero.
    curve = DualFuelCurve(;
        first_fuel_curve = PiecewisePointCurve([(15.0, 50.0), (30.0, 200.0),
            (45.0, 400.0)]),
        second_fuel_curve = F2, fuel_units = u"MMBtu", first_fuel_cost = 3.0,
        second_fuel_cost = 5.0, second_fuel_share = 0.3)
    F = ThermalDispatchNoMin
    log = _failed_build_log(_blend_system(curve, F), F)
    @test occursin(
        "Alta has a blended DualFuelCurve that ThermalDispatchNoMin extends",
        log,
    )
    @test occursin("negative fuel use", log)
end

@testset "ThermalDispatchNoMin extends a blend of lines through zero" begin
    # Heat rate only lines are 0 at zero output; the extension must not read rounding as < 0.
    curve = DualFuelCurve(; first_fuel_curve = LinearCurve(6.5),
        second_fuel_curve = LinearCurve(7.5), fuel_units = u"MMBtu",
        first_fuel_cost = 3.0, second_fuel_cost = 5.0, second_fuel_share = 0.3)
    F = ThermalDispatchNoMin
    limits! =
        sys -> PSY.set_active_power_limits!(
            PSY.get_component(ThermalStandard, sys, "Alta"),
            (min = 0.333 * u"SU", max = 1.2345 * u"SU"))
    run = _blend_cost(_blend_system(curve, F; change! = limits!), F)
    @test any(>(0.0), run.output_mw)
    for (p, fuel) in zip(run.output_mw, run.unit_fuel)
        @test fuel ≈ (0.7 * 6.5 + 0.3 * 7.5) * p rtol = 1e-6 atol = 1e-6
    end
end

@testset "A blend whose first fuel is zero everywhere fails the build: $F" for F in (
    ThermalStandardUnitCommitment, ThermalDispatchNoMin,
)
    curve = DualFuelCurve(; first_fuel_curve = LinearCurve(0.0), second_fuel_curve = F2,
        fuel_units = u"MMBtu", first_fuel_cost = 3.0, second_fuel_cost = 5.0,
        second_fuel_share = 0.3)
    log = _failed_build_log(_blend_system(curve, F), F)
    @test occursin("Alta has a blended DualFuelCurve whose first fuel use is zero", log)
end

# Price time series on c_sys5_re_fuel_cost: two day-ahead windows of 24 hourly prices.
# Over the model's first window the first price rises and the second falls.
const PRICE_A = [2.0 + 0.1 * (t - 1) for t in 1:24]
const PRICE_B = [4.5 - 0.1 * (t - 1) for t in 1:24]

function _price_series(name::String, day1::Vector{Float64})
    t0 = DateTime("2024-01-01T00:00:00")
    return PSY.Deterministic(; name,
        data = Dict(t0 => day1, t0 + Hour(24) => reverse(day1)),
        resolution = Hour(1), interval = Hour(24))
end

# Alta at 20 to 40 MW with free starts, on `curve` (a blend at share 0.3 by default);
# `price!(sys, alta)` sets prices.
function _price_system(price!; curve = blended_curve())
    sys = PSB.build_system(PSITestSystems, "c_sys5_re_fuel_cost")
    alta = set_unit_variable_cost!(sys, "Alta", curve)
    _set_alta_min!(sys)
    _free_starts!(sys)
    price!(sys, alta)
    return sys
end

function _set_both_price_series!(sys, alta)
    set_first_fuel_cost!(sys, alta, _price_series("fuel_cost", PRICE_A))
    set_second_fuel_cost!(sys, alta, _price_series("second_fuel_cost", PRICE_B))
    return
end

@testset "Blend with a price time series on each fuel: $F" for F in
                                                               (
    ThermalStandardUnitCommitment, ThermalDispatchNoMin, ThermalBasicCompactUnitCommitment)
    run = _blend_cost(_price_system(_set_both_price_series!), F)
    @test IOM.has_container_key(run.container, SecondFuelCostParameter, ThermalStandard)
    # Alta runs in most steps, so a price read at the wrong step shows.
    @test count(>(0.0), run.output_mw) >= length(run.output_mw) ÷ 2
    for (t, (p, unit_cost)) in enumerate(zip(run.output_mw, run.unit_cost))
        @test unit_cost ≈ _expected(F, p, 0.3; c1 = PRICE_A[t], c2 = PRICE_B[t]) rtol =
            1e-6 atol = 1e-6
    end
end

@testset "One fixed price and one time series" begin
    F = ThermalStandardUnitCommitment
    sys = _price_system(
        (sys, alta) -> set_second_fuel_cost!(
            sys, alta, _price_series("second_fuel_cost", PRICE_B)),
    )
    run = _blend_cost(sys, F)
    # Alta runs in most steps, so a price read at the wrong step shows.
    @test count(>(0.0), run.output_mw) >= length(run.output_mw) ÷ 2
    for (t, (p, unit_cost)) in enumerate(zip(run.output_mw, run.unit_cost))
        @test unit_cost ≈ _expected(F, p, 0.3; c1 = 3.0, c2 = PRICE_B[t]) rtol = 1e-6 atol =
            1e-6
    end
end

@testset "A blend at share 0 or 1 with a price series is the single fuel: $F" for F in (
    ThermalStandardUnitCommitment, ThermalDispatchNoMin)
    # Share 0 prices the first series, share 1 the second, stored under the second's name.
    for (share, series, single) in ((0.0, PRICE_A, F1), (1.0, PRICE_B, F2))
        blend = _price_system(; curve = blended_curve(; share)) do sys, alta
            set_first_fuel_cost!(sys, alta, _price_series("fuel_cost", PRICE_A))
            set_second_fuel_cost!(sys, alta, _price_series("second_fuel_cost", PRICE_B))
        end
        reference = _price_system(; curve = FuelCurve(single, u"MMBtu", 3.0)) do sys, alta
            set_fuel_cost!(sys, alta, _price_series("fuel_cost", series))
        end
        run = _blend_cost(blend, F)
        @test count(>(0.0), run.output_mw) >= length(run.output_mw) ÷ 2
        @test run.objective ≈ _blend_cost(reference, F).objective rtol = 1e-6
    end
end

@testset "FixedOutput builds no cost, so its dual fuel curve is not checked: $name" for (
    name, curve, price!) in (
    ("blend with a price series",
        blended_curve(),
        (sys, alta) -> set_second_fuel_cost!(
            sys, alta, _price_series("second_fuel_cost", PRICE_B))),
    ("stacked curve outside a block", stacked_curve(), (sys, alta) -> nothing))
    sys = _price_system(price!; curve)
    # FixedOutput follows max_active_power, which thermal units of the fixture lack.
    load = first(PSY.get_components(PowerLoad, sys))
    forecast = PSY.get_time_series(Deterministic, load, "max_active_power")
    for gen in PSY.get_components(ThermalStandard, sys)
        PSY.add_time_series!(sys, gen, forecast)
    end
    @test build!(_blend_model(sys, FixedOutput); output_dir = mktempdir(; cleanup = true),
        console_level = Logging.AboveMaxLevel) == IOM.ModelBuildStatus.BUILT
end

@testset "A missing price time series fails the build" begin
    # Removed through IS, so the curve still points at the series.
    sys = _price_system(_set_both_price_series!)
    alta = PSY.get_component(ThermalStandard, sys, "Alta")
    IS.remove_time_series!(sys.data, PSY.Deterministic, alta, "second_fuel_cost")
    log = _failed_build_log(sys, ThermalStandardUnitCommitment)
    @test occursin("Alta", log)
    @test occursin("second_fuel_cost", log)
end

@testset "Price series stored under each other's names fail the build" begin
    sys = _price_system() do sys, alta
        set_first_fuel_cost!(sys, alta, _price_series("second_fuel_cost", PRICE_A))
        set_second_fuel_cost!(sys, alta, _price_series("fuel_cost", PRICE_B))
    end
    log = _failed_build_log(sys, ThermalStandardUnitCommitment)
    # The log holds the exception's repr, with its quotes escaped.
    @test occursin(
        escape_string(
            "Alta has its first fuel price in time series \"second_fuel_cost\", but the " *
            "device model reads FuelCostParameter from \"fuel_cost\"",
        ),
        log,
    )
end

@testset "A price series name mapped by the device model" begin
    sys = _price_system() do sys, alta
        set_first_fuel_cost!(sys, alta, _price_series("fuel_cost", PRICE_A))
        set_second_fuel_cost!(sys, alta, _price_series("gas_price", PRICE_B))
    end
    F = ThermalStandardUnitCommitment
    log = _failed_build_log(sys, F)
    @test occursin(escape_string("has no time series \"second_fuel_cost\""), log)
    names = Dict{Type{<:ParameterType}, String}(
        FuelCostParameter => "fuel_cost", SecondFuelCostParameter => "gas_price")
    model = _blend_model(sys, F;
        device_model = DeviceModel(ThermalStandard, F; time_series_names = names))
    @test build!(model; output_dir = mktempdir(; cleanup = true),
        console_level = Logging.AboveMaxLevel) == IOM.ModelBuildStatus.BUILT
    second = IOM.get_parameter_array(IOM.get_optimization_container(model),
        SecondFuelCostParameter, ThermalStandard)
    @test [second["Alta", t] for t in 1:24] == PRICE_B
end

@testset "A price series of a type the model does not read fails the build" begin
    # A SingleTimeSeries passes the name check, but the model reads Deterministic series.
    sys = _price_system() do sys, alta
        hours = DateTime("2024-01-01T00:00:00") .+ Hour.(0:47)
        set_second_fuel_cost!(
            sys,
            alta,
            PSY.SingleTimeSeries(;
                name = "second_fuel_cost",
                data = TimeArray(hours, vcat(PRICE_B, PRICE_B))),
        )
    end
    log = _failed_build_log(sys, ThermalStandardUnitCommitment)
    @test occursin("Alta has its second fuel price in a time series", log)
    @test occursin("SecondFuelCostParameter", log)
end
