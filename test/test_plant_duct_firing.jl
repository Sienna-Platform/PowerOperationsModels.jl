# The quarter-size Luna block on `system`, after `change!(sys, plant)`, built with the CTs
# and the steam turbine fixed, and solved. Returns the model, or `nothing` when infeasible.
function _duct_run(; cts, steam_mw, system = "c_sys5_uc", console_level = Logging.Error,
    change! = (sys, plant) -> nothing, kwargs...)
    sys = PSB.build_system(PSITestSystems, system)
    plant = add_wecc_physical_block!(sys, LUNA_QUARTER; kwargs...)
    change!(sys, plant)
    model = _cc_model(_cc_template(), sys)
    for (i, mw) in enumerate(cts)
        _fix_unit!(model, "CT$(i)", mw)
    end
    _fix_unit!(model, "ST1", steam_mw(plant))
    solve!(model; console_level) == IOM.RunStatus.SUCCESSFULLY_FINALIZED || return nothing
    return model
end

# Duct firing in MW at the first step, or `nothing` when the model is infeasible.
function _duct_mw(; kwargs...)
    model = _duct_run(; kwargs...)
    return isnothing(model) ? nothing : _duct_mw_at(model)
end

function _duct_mw_at(model)
    base = IOM.get_model_base_power(IOM.get_optimization_container(model))
    return JuMP.value(_cc_variable(model, SecondFuelPowerVariable)["ST1", 1]) * base
end

@testset "WECC split of Luna" begin
    split = wecc_split(WECC_LUNA)
    @test split.steam_ratio ≈ 0.627 atol = 1e-3
    @test split.steam_max ≈ 92.7 atol = 0.05
    @test first(split.ct_points)[1] ≈ 84.5 atol = 0.05
    @test last(split.ct_points)[2] ≈ 1721.0 atol = 0.5
    @test split.duct_mw == 59.5 && split.duct_heat_rate == 10.017
    quarter = wecc_split(LUNA_QUARTER)
    @test quarter.steam_ratio ≈ split.steam_ratio
    @test quarter.heat_max ≈ split.heat_max / 4
end

@testset "A stacked steam turbine builds with its duct firing rows" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    add_wecc_physical_block!(sys, LUNA_QUARTER)
    model = _cc_model(_cc_template(), sys)
    c = IOM.get_optimization_container(model)
    @test axes(_cc_variable(model, SecondFuelPowerVariable))[1] == ["ST1"]
    @test IOM.has_container_key(c, SecondFuelPowerLimitConstraint, PSY.ThermalGen)
    # Duct fuel is priced at heat rate times fuel price, per MWh.
    d = _cc_variable(model, SecondFuelPowerVariable)["ST1", 1]
    price = JuMP.coefficient(JuMP.objective_function(IOM.get_jump_model(c)), d)
    @test price ≈ 10.017 * WECC_LUNA.fuel_price * IOM.get_model_base_power(c)
    # Duct fuel is the steam turbine's only fuel cost: its output and commitment are free.
    objective = JuMP.objective_function(IOM.get_jump_model(c))
    @test JuMP.coefficient(objective, _cc_variable(model, ActivePowerVariable)["ST1", 1]) ==
          0.0
    @test JuMP.coefficient(objective, _cc_variable(model, OnVariable)["ST1", 1]) == 0.0
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "Duct firing covers only what CT heat cannot" begin
    full = LUNA_QUARTER.ct_mw
    duct = wecc_split(LUNA_QUARTER).duct_mw
    # Both CTs at full load make the unfired steam; anything above it is duct firing.
    @test _duct_mw(; cts = (full, full), steam_mw = p -> 2 * p.split.steam_max) ≈ 0.0 atol =
        1e-3
    @test _duct_mw(; cts = (full, full), steam_mw = p -> 2 * p.split.steam_max + 10.0) ≈
          10.0 atol =
        1e-3
    @test _duct_mw(; cts = (full, full), steam_mw = p -> 2 * (p.split.steam_max + duct)) ≈
          2 * duct atol = 1e-3
    # Below full CT load the heat falls short of the unfired maximum, so ducts fill the gap.
    low = first(wecc_split(LUNA_QUARTER).ct_points)[1]
    @test _duct_mw(; cts = (low, low), steam_mw = p -> 2 * p.split.steam_max) > 1.0
end

@testset "A 2x1 on one CT fires half its ducts" begin
    full = LUNA_QUARTER.ct_mw
    duct = wecc_split(LUNA_QUARTER).duct_mw
    one_ct = (; cts = (full, nothing), steam = :hrsg_loss)
    @test _duct_mw(; one_ct..., steam_mw = p -> p.split.steam_max + duct) ≈ duct atol = 1e-3
    # Infeasible: the solve's error log is expected, so it is kept off the console.
    @test _duct_mw(; one_ct..., steam_mw = p -> p.split.steam_max + duct + 2.0,
        console_level = Logging.Error + 1) === nothing
end

@testset "A 2x1 with one CT unavailable fires half its ducts" begin
    full = LUNA_QUARTER.ct_mw
    duct = wecc_split(LUNA_QUARTER).duct_mw
    # An outage: CT2 is out of the model, and so are the ducts of its HRSG.
    one_ct = (; cts = (full,), steam = :hrsg_loss,
        change! = (sys, p) -> PSY.set_available!(p.cts[2], false))
    @test _duct_mw(; one_ct..., steam_mw = p -> p.split.steam_max + duct) ≈ duct atol = 1e-3
    @test _duct_mw(; one_ct..., steam_mw = p -> p.split.steam_max + duct + 2.0,
        console_level = Logging.Error + 1) === nothing
end

@testset "A heat loss per committed CT reproduces the ADS steam with one or two CTs" begin
    split = wecc_split(LUNA_QUARTER)
    low, full = first(split.ct_points)[1], last(split.ct_points)[1]
    # Free steam runs to the heat on hand; with no duct firing that is the ADS steam.
    for (cts, ads_steam) in (
        ((full, nothing), split.steam_max),
        ((low, nothing), split.steam_min),
        ((full, full), 2 * split.steam_max),
        ((low, low), 2 * split.steam_min),
    )
        @test _duct_mw(; cts, steam = :hrsg_loss, steam_mw = p -> ads_steam) ≈ 0.0 atol =
            0.05
        @test _duct_mw(; cts, steam = :hrsg_loss, steam_mw = p -> ads_steam + 1.0) ≈ 1.0 atol =
            0.05
    end
end

# The stacked rows of ST1 at t = 1, from a block whose second curve starts `shift` MW lower
# and is stored in `units`, with ST1 on a `base_power` MVA base.
function _stacked_rows(shift; units = u"NU", base_power = 100.0)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    plant = add_wecc_physical_block!(sys, LUNA_QUARTER)
    PSY.rebase_component!(plant.ca, base_power)
    curve = PSY.get_variable_operation_cost(PSY.get_operation_cost(plant.ca))
    x0, x1 = IS.get_x_coords(IS.get_function_data(PSY.get_second_fuel_curve(curve)))
    moved = PSY.DualFuelCurve(;
        first_fuel_curve = PSY.get_first_fuel_curve(curve),
        second_fuel_curve = PSY.PiecewiseIncrementalCurve(
            nothing, [x0 - shift, x1], [wecc_split(LUNA_QUARTER).duct_heat_rate]),
        fuel_units = u"MMBtu", second_fuel_cost = LUNA_QUARTER.fuel_price)
    set_unit_variable_cost!(sys, "ST1", IS.convert_power_units(plant.ca, moved, units))
    # No system bundle: PowerSystems refuses to export a system base curve.
    model = DecisionModel(_cc_template(), sys;
        optimizer = HiGHS_optimizer, store_variable_names = true, system_to_file = false,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    c = IOM.get_optimization_container(model)
    d = _cc_variable(model, SecondFuelPowerVariable)["ST1", 1]
    return (
        draw = _cc_constraint(model, HRSGHeatDrawConstraint)["ST1", 1],
        p = _cc_variable(model, ActivePowerVariable)["ST1", 1],
        d = d,
        upper = IOM.get_constraint(c, FirstFuelPowerLimitConstraint, PSY.ThermalGen, "ub")[
            "ST1",
            1,
        ],
        duct = _cc_constraint(model, SecondFuelPowerLimitConstraint)["ST1", 1],
        u_st = _cc_variable(model, OnVariable)["ST1", 1],
        u_ct = _cc_variable(model, OnVariable)["CT1", 1],
        price = JuMP.coefficient(JuMP.objective_function(IOM.get_jump_model(c)), d),
        base = IOM.get_model_base_power(c),
    )
end

@testset "The threshold comes from the second curve" begin
    # The second curve starts 5 MW lower and ends at the same maximum: the recovered steam
    # bound falls by 5 MW and the duct limit per CT rises by 2.5 MW.
    at = _stacked_rows(0.0)
    lower = _stacked_rows(5.0)
    x0 = 2 * wecc_split(LUNA_QUARTER).steam_max
    @test -JuMP.normalized_coefficient(at.upper, at.u_st) * at.base ≈ x0
    @test (
        JuMP.normalized_coefficient(lower.upper, lower.u_st) -
        JuMP.normalized_coefficient(at.upper, at.u_st)
    ) * at.base ≈ 5.0
    @test (
        JuMP.normalized_coefficient(at.duct, at.u_ct) -
        JuMP.normalized_coefficient(lower.duct, lower.u_ct)
    ) * at.base ≈ 2.5
end

@testset "A stacked curve in system base builds the same rows" begin
    natural = _stacked_rows(5.0)
    system = _stacked_rows(5.0; units = u"SU")
    @test JuMP.normalized_coefficient(system.upper, system.u_st) ≈
          JuMP.normalized_coefficient(natural.upper, natural.u_st)
    @test JuMP.normalized_coefficient(system.duct, system.u_ct) ≈
          JuMP.normalized_coefficient(natural.duct, natural.u_ct)
    @test system.price ≈ natural.price
    for row in (:p, :d)
        @test JuMP.normalized_coefficient(system.draw, getproperty(system, row)) ≈
              JuMP.normalized_coefficient(natural.draw, getproperty(natural, row))
    end
end

@testset "A steam turbine on a 50 MVA base builds the same rows: $units" for units in (
    u"NU", u"CU")
    at_100 = _stacked_rows(5.0; units)
    at_50 = _stacked_rows(5.0; units, base_power = 50.0)
    @test at_50.price ≈ at_100.price
    for (row, var) in ((:upper, :u_st), (:upper, :p), (:upper, :d), (:duct, :u_ct),
        (:duct, :d), (:draw, :p), (:draw, :d), (:draw, :u_st))
        @test JuMP.normalized_coefficient(
            getproperty(at_50, row), getproperty(at_50, var)) ≈
              JuMP.normalized_coefficient(
            getproperty(at_100, row), getproperty(at_100, var))
    end
end

# The objective coefficients of ST1's commitment, start and output, with fixed, start-up and
# VOM costs set and `curve` as its variable cost (`nothing` keeps the stacked curve).
function _st_cost_coefficients(curve)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    plant = add_wecc_physical_block!(sys, LUNA_QUARTER)
    op = PSY.get_operation_cost(plant.ca)
    PSY.set_fixed!(op, 5.0)
    PSY.set_start_up!(op, 100.0)
    stacked = PSY.get_variable_operation_cost(op)
    vom = PSY.LinearCurve(2.0)
    PSY.set_variable_operation_cost!(
        op,
        something(
            curve,
            PSY.DualFuelCurve(;
                first_fuel_curve = PSY.get_first_fuel_curve(stacked),
                second_fuel_curve = PSY.get_second_fuel_curve(stacked),
                fuel_units = u"MMBtu", second_fuel_cost = LUNA_QUARTER.fuel_price,
                vom_cost = vom),
        ),
    )
    model = _cc_model(_cc_template(), sys)
    objective = JuMP.objective_function(
        IOM.get_jump_model(IOM.get_optimization_container(model)))
    return [
        JuMP.coefficient(objective, _cc_variable(model, V)["ST1", 1]) for
        V in (OnVariable, StartVariable, ActivePowerVariable)
    ]
end

@testset "The steam turbine keeps its fixed, start-up and VOM costs" begin
    line = wecc_steam_line(LUNA_QUARTER, wecc_split(LUNA_QUARTER), :chord)
    plain = PSY.FuelCurve(; value_curve = PSY.LinearCurve(line.a, line.b),
        fuel_units = u"MMBtu", fuel_cost = 0.0, vom_cost = PSY.LinearCurve(2.0))
    stacked = _st_cost_coefficients(nothing)
    reference = _st_cost_coefficients(plain)
    @test all(!iszero, reference)
    @test stacked ≈ reference
end

@testset "Duct fuel is in FuelConsumptionExpression" begin
    full = LUNA_QUARTER.ct_mw
    # Both CTs at full load and steam 10 MW above the unfired maximum: d = 10 MW.
    model = _duct_run(; cts = (full, full), steam_mw = p -> 2 * p.split.steam_max + 10.0)
    c = IOM.get_optimization_container(model)
    fuel = IOM.get_expression(c, FuelConsumptionExpression, ThermalStandard)
    # Only the duct fuel: the recovered heat is CT exhaust the CTs already count.
    d = _cc_variable(model, SecondFuelPowerVariable)["ST1", 1]
    @test length(collect(JuMP.linear_terms(fuel["ST1", 1]))) == 1
    @test JuMP.coefficient(fuel["ST1", 1], d) ≈ 10.017 * IOM.get_model_base_power(c)
    @test JuMP.value(fuel["ST1", 1]) ≈ 10.017 * 10.0 atol = 1e-3
    cost = IOM.get_expression(c, FuelCostExpression, ThermalStandard)
    @test JuMP.value(cost["ST1", 1]) ≈ 10.017 * 10.0 * WECC_LUNA.fuel_price atol = 1e-2
end

@testset "Duct output is written to results in MW" begin
    full = LUNA_QUARTER.ct_mw
    model = _duct_run(; cts = (full, full), steam_mw = p -> 2 * p.split.steam_max + 10.0)
    res = IOM.OptimizationProblemOutputs(model)
    wide(key) = read_variable(res, key; table_format = TableFormat.WIDE)[!, "ST1"]
    d = wide("SecondFuelPowerVariable__ThermalStandard")
    p = wide("ActivePowerVariable__ThermalStandard")
    @test all(isapprox.(d, 10.0; atol = 1e-3))
    @test all(isapprox.(p .- d, 2 * wecc_split(LUNA_QUARTER).steam_max; atol = 1e-3))
end

@testset "Duals of the duct firing rows" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    add_wecc_physical_block!(sys, LUNA_QUARTER)
    template = _cc_template(;
        duals = [FirstFuelPowerLimitConstraint, SecondFuelPowerLimitConstraint])
    model = _cc_model(template, sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    res = IOM.OptimizationProblemOutputs(model)
    for key in (
        "FirstFuelPowerLimitConstraint__ThermalGen__lb",
        "FirstFuelPowerLimitConstraint__ThermalGen__ub",
        "SecondFuelPowerLimitConstraint__ThermalGen",
    )
        @test all(isfinite, read_dual(res, key; table_format = TableFormat.WIDE)[!, "ST1"])
    end
end

@testset "Duct fuel and its cost scale with the step length" begin
    # 5-minute steps: d = 10 MW for one step burns 1/12 of the hourly duct fuel. The CTs
    # run at minimum, since c_sys5_ed cannot take the block at full load.
    low = first(wecc_split(LUNA_QUARTER).ct_points)[1]
    model = _duct_run(; cts = (low, low), steam = :hrsg_loss, system = "c_sys5_ed",
        steam_mw = p -> 2 * p.split.steam_min + 10.0)
    c = IOM.get_optimization_container(model)
    @test IOM.get_resolution(c) == Dates.Minute(5)
    dt = 5.0 / 60.0
    d_mw = _duct_mw_at(model)
    @test d_mw ≈ 10.0 atol = 0.05
    fuel = IOM.get_expression(c, FuelConsumptionExpression, ThermalStandard)
    @test JuMP.value(fuel["ST1", 1]) ≈ 10.017 * d_mw * dt atol = 1e-6
    d = _cc_variable(model, SecondFuelPowerVariable)["ST1", 1]
    price = JuMP.coefficient(JuMP.objective_function(IOM.get_jump_model(c)), d)
    @test price ≈ 10.017 * WECC_LUNA.fuel_price * IOM.get_model_base_power(c) * dt
end

# A steam turbine without a commitment variable is always on: its recovered steam runs from
# its minimum, and every CT opens its share of the ducts.
@testset "A stacked steam turbine under ThermalStandardDispatch" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    plant = add_wecc_physical_block!(sys, LUNA_QUARTER)
    model = _cc_model(_cc_template(; formulation = ThermalStandardDispatch), sys)
    c = IOM.get_optimization_container(model)
    base = IOM.get_model_base_power(c)
    lower = IOM.get_constraint(c, FirstFuelPowerLimitConstraint, PSY.ThermalGen, "lb")
    @test JuMP.normalized_rhs(lower["ST1", 1]) * base ≈
          0.75 * wecc_split(LUNA_QUARTER).steam_min atol = 1e-6
    # CTs cannot run under ThermalDispatchNoMin, but a steam turbine of another type can.
    @test all(iszero, POM.first_fuel_min_power(c, plant.ca, ThermalDispatchNoMin))
    upper = IOM.get_constraint(c, FirstFuelPowerLimitConstraint, PSY.ThermalGen, "ub")
    @test JuMP.normalized_rhs(upper["ST1", 1]) * base ≈
          2 * wecc_split(LUNA_QUARTER).steam_max
    duct = _cc_constraint(model, SecondFuelPowerLimitConstraint)["ST1", 1]
    @test JuMP.normalized_rhs(duct) * base ≈ 2 * wecc_split(LUNA_QUARTER).duct_mw
    d = _cc_variable(model, SecondFuelPowerVariable)["ST1", 1]
    @test JuMP.coefficient(JuMP.objective_function(IOM.get_jump_model(c)), d) ≈
          10.017 * WECC_LUNA.fuel_price * base
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "A stacked steam turbine under a compact formulation" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    add_wecc_physical_block!(sys, LUNA_QUARTER)
    model = _cc_model(_cc_template(; formulation = ThermalBasicCompactUnitCommitment), sys)
    c = IOM.get_optimization_container(model)
    # Output is the minimum on commitment plus the power above it: P - d >= Pmin u leaves
    # the power above the minimum at least the duct output.
    lower = IOM.get_constraint(c, FirstFuelPowerLimitConstraint, PSY.ThermalGen, "lb")
    above = _cc_variable(model, PowerAboveMinimumVariable)["ST1", 1]
    d = _cc_variable(model, SecondFuelPowerVariable)["ST1", 1]
    on = _cc_variable(model, OnVariable)["ST1", 1]
    @test JuMP.normalized_coefficient(lower["ST1", 1], above) ≈ 1.0
    @test JuMP.normalized_coefficient(lower["ST1", 1], d) ≈ -1.0
    @test JuMP.normalized_coefficient(lower["ST1", 1], on) ≈ 0.0 atol = 1e-12
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "A stacked steam turbine under FixedOutput is rejected" begin
    # FixedOutput builds no cost, so it would drop the duct fuel; the block check names ST1.
    sys = _dual_fuel_system(
        (sys, plant) -> foreach(ct -> PSY.set_available!(ct, false),
            plant.cts),
    )
    template = _cc_template(; formulation = FixedOutput)
    err = try
        Logging.with_logger(Logging.ConsoleLogger(stderr, Logging.Error)) do
            POM.validate_template(DecisionModel(template, sys; optimizer = HiGHS_optimizer))
        end
    catch e
        e
    end
    @test err isa IS.ConflictingInputsError
    @test occursin(r"ST1 is modeled under \S*FixedOutput", sprint(showerror, err))
end

# A varying second fuel price on the stacked steam turbine reaches the objective each step.
@testset "A duct fuel price time series reaches the objective" begin
    t0 = DateTime("2024-01-01T00:00:00")
    series = [4.5 - 0.1 * (t - 1) for t in 1:24]
    price = PSY.Deterministic(; name = "second_fuel_cost",
        data = Dict(t0 => series, t0 + Hour(24) => reverse(series)),
        resolution = Hour(1), interval = Hour(24))
    full = LUNA_QUARTER.ct_mw
    model = _duct_run(; cts = (full, full), steam_mw = p -> 2 * p.split.steam_max + 10.0,
        system = "c_sys5_re_fuel_cost",
        change! = (sys, p) -> set_second_fuel_cost!(sys, p.ca, price))
    c = IOM.get_optimization_container(model)
    steps = IOM.get_time_steps(c)
    @test length(steps) == 24
    base = IOM.get_model_base_power(c)
    d = _cc_variable(model, SecondFuelPowerVariable)["ST1", :]
    @test all(t -> JuMP.value(d[t]) * base ≈ 10.0, steps)
    steam_cost = IOM.get_expression(c, FuelCostExpression, ThermalStandard)
    for t in steps
        @test JuMP.value(steam_cost["ST1", t]) ≈ 10.017 * 10.0 * series[t] atol = 1e-6
    end
end
