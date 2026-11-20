# The steam turbine's stacked curve with the second curve on `x` and `kw` overrides.
function _st1_curve(plant, x; kw...)
    return PSY.TwoFuelCurve(;
        first_fuel_curve = PSY.LinearCurve(plant.line.a, plant.line.b),
        second_fuel_curve = PSY.PiecewiseIncrementalCurve(
            nothing, x, fill(plant.split.duct_heat_rate, length(x) - 1)),
        fuel_units = u"MMBtu", second_fuel_cost = LUNA_QUARTER.fuel_price,
        fuel_curve_type = PSY.TwoFuelCurveType.STACKED, kw...)
end

_st1_limits(plant) = PSY.get_active_power_limits(plant.ca, u"NU")
_st1_threshold(plant) = LUNA_QUARTER.chunks * plant.split.steam_max

@testset "Valid two-fuel units pass template validation" begin
    sys = _two_fuel_system()
    @test PSY.get_variable_operation_cost(
        PSY.get_operation_cost(PSY.get_component(ThermalStandard, sys, "ST1")),
    ) isa PSY.TwoFuelCurve
    @test _validate_two_fuel(sys) === nothing
    set_unit_variable_cost!(sys, "Alta", blended_curve())
    @test _validate_two_fuel(sys) === nothing
end

@testset "A curve with an UNDEFINED fuel_curve_type is rejected" begin
    undefined(c) = PSY.TwoFuelCurve(;
        first_fuel_curve = PSY.get_first_fuel_curve(c),
        second_fuel_curve = PSY.get_second_fuel_curve(c),
        fuel_units = u"MMBtu", first_fuel_cost = 3.0, second_fuel_cost = 5.0)
    @test rejects_template(
        (sys, p) -> set_unit_variable_cost!(sys, "Alta", undefined(blended_curve())),
        "Alta", "UNDEFINED")
    # On a steam turbine of a modeled block, the plant check asks for a STACKED curve.
    @test rejects_template(
        (sys, p) -> set_unit_variable_cost!(sys, "ST1", undefined(stacked_curve())),
        "ST1", "UNDEFINED", "STACKED")
end

@testset "A stacked curve outside a modeled block is rejected" begin
    @test rejects_template(
        (sys, p) -> set_unit_variable_cost!(sys, "Alta", stacked_curve()),
        "stacked", "Alta")
    @test rejects_template((sys, p) -> nothing, "stacked", "ST1"; plant = false)
end

@testset "A blended curve on a steam turbine of a modeled block is rejected" begin
    @test rejects_template(
        (sys, p) -> set_unit_variable_cost!(sys, "ST1", blended_curve()),
        "BLENDED", "STACKED",
    )
end

@testset "A blended curve on a CT of a modeled block is rejected" begin
    @test rejects_template((sys, p) -> set_unit_variable_cost!(sys, "CT1", blended_curve()),
        "CT1", "a stacked TwoFuelCurve on a steam turbine")
end

@testset "A stacked second curve has one segment" begin
    @test rejects_template(
        (sys, p) -> set_unit_variable_cost!(sys, "ST1",
            _st1_curve(p, [_st1_threshold(p), _st1_threshold(p) + 1.0,
                    _st1_limits(p).max])),
        "one segment")
end

@testset "A stacked first fuel is free" begin
    @test rejects_template(
        (sys, p) -> set_unit_variable_cost!(sys, "ST1",
            _st1_curve(p, [_st1_threshold(p), _st1_limits(p).max]; first_fuel_cost = 1.0)),
        "first fuel")
    @test rejects_template(
        (sys, p) -> begin
            initial_time = PSY.get_forecast_initial_timestamp(sys)
            resolution = first(PSY.get_time_series_resolutions(sys))
            stamps = range(initial_time; step = resolution, length = 24)
            PSY.set_first_fuel_cost!(sys, p.ca,
                IS.SingleTimeSeries(; name = "fuel_cost",
                    data = TimeSeries.TimeArray(collect(stamps), fill(1.0, 24))))
        end,
        "first fuel")
end

@testset "A stacked second curve reaches maximum output" begin
    @test rejects_template(
        (sys, p) -> set_unit_variable_cost!(sys, "ST1",
            _st1_curve(p, [_st1_threshold(p), _st1_limits(p).max - 5.0])),
        "maximum output")
end

@testset "A stacked threshold is not below minimum output" begin
    @test rejects_template(
        (sys, p) -> set_unit_variable_cost!(sys, "ST1",
            _st1_curve(p, [_st1_limits(p).min - 1.0, _st1_limits(p).max])),
        "threshold")
end

@testset "A blend takes no quadratic curve" begin
    quadratic = PSY.QuadraticCurve(0.01, 9.0, 20.0)
    for (first_curve, second_curve) in (
        (quadratic, PSY.LinearCurve(9.5, 20.0)),
        (PSY.LinearCurve(9.5, 20.0), quadratic),
    )
        curve = PSY.TwoFuelCurve(; first_fuel_curve = first_curve,
            second_fuel_curve = second_curve, fuel_units = u"MMBtu",
            first_fuel_cost = 3.0, second_fuel_cost = 5.0,
            fuel_curve_type = PSY.TwoFuelCurveType.BLENDED,
            second_fuel_output_share = 0.3)
        @test rejects_template(
            (sys, p) -> set_unit_variable_cost!(sys, "Alta", curve),
            "quadratic",
        )
    end
end

@testset "A blend takes no non-convex piecewise curve" begin
    concave = PSY.TwoFuelCurve(;
        first_fuel_curve = PSY.PiecewisePointCurve([(15.0, 135.0), (30.0, 300.0),
            (45.0, 405.0)]),
        second_fuel_curve = PSY.get_second_fuel_curve(blended_curve()),
        fuel_units = u"MMBtu", first_fuel_cost = 3.0, second_fuel_cost = 5.0,
        fuel_curve_type = PSY.TwoFuelCurveType.BLENDED,
        second_fuel_output_share = 0.3)
    @test rejects_template(
        (sys, p) -> set_unit_variable_cost!(sys, "Alta", concave),
        "convex",
    )
end

@testset "A blend's piecewise curve covers the unit's output range" begin
    # blended_curve() spans 15 to 45 MW; Sundance runs from 100 to 200 MW.
    @test rejects_template(
        (sys, p) -> set_unit_variable_cost!(sys, "Sundance", blended_curve()),
        "output range")
end

@testset "A HybridSystem's thermal unit cannot carry a TwoFuelCurve" begin
    sys = PSB.build_system(PSB.PSITestSystems, "test_RTS_GMLC_sys")
    # The load's series are in component base, which the hybrid model rejects first.
    hybrid = add_hybrid_to_chuhsi_bus!(sys; with_load = false)
    curve = PSY.TwoFuelCurve(; first_fuel_curve = PSY.LinearCurve(7.0),
        second_fuel_curve = PSY.LinearCurve(8.0), fuel_units = u"MMBtu",
        first_fuel_cost = 3.0, second_fuel_cost = 5.0,
        fuel_curve_type = PSY.TwoFuelCurveType.BLENDED,
        second_fuel_output_share = 0.3)
    PSY.set_variable_operation_cost!(
        PSY.get_operation_cost(PSY.get_thermal_unit(hybrid)), curve)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, HybridSystem, HybridDispatchWithReserves)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, horizon = Hour(3))
    dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = dir, console_level = Logging.AboveMaxLevel) ==
          IOM.ModelBuildStatus.FAILED
    log = read(joinpath(dir, "operation_problem.log"), String)
    @test occursin("ConflictingInputsError", log)
    @test occursin("$(PSY.get_name(hybrid)) has a TwoFuelCurve", log)
    @test occursin("thermal units only", log)
end
