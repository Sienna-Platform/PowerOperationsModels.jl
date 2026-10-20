# Per-step minimum active power: parameter types, multipliers, accessors, validation, rebuild.

const MIN_POWER_UC_NAMES = Dict(
    ActivePowerTimeSeriesParameter => "max_active_power",
    MinActivePowerTimeSeriesParameter => "min_active_power",
)

# Adds a Deterministic named "min_active_power" (fraction of Pmax) to `d`, one window per
# forecast initial time of `sys`.
function add_min_power_series!(
    sys::PSY.System,
    d::PSY.Component,
    values::Vector{Float64};
    name::String = "min_active_power",
)
    data = Dict(
        it => values for it in PSY.get_forecast_initial_times(sys)
    )
    PSY.add_time_series!(
        sys,
        d,
        PSY.Deterministic(; name = name, data = data, resolution = Hour(1)),
    )
    return
end

function _min_power_uc_model(
    sys;
    recurrent = false,
    rebuild_model = false,
    initialize_model = true,
    formulation = ThermalStandardUnitCommitment,
    names = MIN_POWER_UC_NAMES,
)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(
        template,
        DeviceModel(
            ThermalStandard,
            formulation;
            time_series_names = names,
        ),
    )
    model = DecisionModel(
        template,
        sys;
        optimizer = HiGHS_optimizer,
        rebuild_model,
        initialize_model,
    )
    IOM.get_optimization_container(model).built_for_recurrent_solves = recurrent
    return model
end

function _min_power_system(
    values::Vector{Float64};
    max_values::Vector{Float64} = ones(24),
)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    unit = get_component(ThermalStandard, sys, "Brighton")
    add_min_power_series!(sys, unit, values)
    add_min_power_series!(sys, unit, max_values; name = "max_active_power")
    return sys, unit
end

@testset "Parameter types are time-series LHS parameters" begin
    for P in (MinActivePowerTimeSeriesParameter, MinActivePowerInTimeSeriesParameter)
        @test P <: IOM.LeftHandSideTimeSeriesParameter
        @test P <: POM.TimeSeriesParameter
    end
end

@testset "Accessor: profiled unit reads Pmax * series, others the static minimum" begin
    values = collect(range(0.1, 0.4; length = 24))
    sys, unit = _min_power_system(values)
    model = _min_power_uc_model(sys)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")

    @test POM.has_min_active_power_series(
        container,
        MinActivePowerTimeSeriesParameter,
        unit,
    )
    @test POM.min_active_power_values(container, unit) ≈ pmax .* values
    other = get_component(ThermalStandard, sys, "Alta")
    @test !POM.has_min_active_power_series(
        container,
        MinActivePowerTimeSeriesParameter,
        other,
    )
    @test POM.min_active_power_values(container, other) ≈
          fill(PSY.get_active_power_limits(other, u"SU").min, 24)
    @test !POM.has_min_active_power_series(
        container,
        MinActivePowerInTimeSeriesParameter,
        unit,
    )
end

@testset "No profiled unit: no parameter container" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    unit = get_component(ThermalStandard, sys, "Brighton")
    add_min_power_series!(sys, unit, ones(24); name = "max_active_power")
    model = _min_power_uc_model(sys)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    @test !IOM.has_container_key(
        container,
        MinActivePowerTimeSeriesParameter,
        ThermalStandard,
    )
end

@testset "Validation: a value outside [0, Pmax] fails the build" begin
    for bad in (-0.1, 1.5)
        values = fill(0.2, 24)
        values[3] = bad
        sys, _ = _min_power_system(values)
        model = _min_power_uc_model(sys)
        output_dir = mktempdir(; cleanup = true)
        @test build!(model; output_dir = output_dir) == ModelBuildStatus.FAILED
        log = read(joinpath(output_dir, "operation_problem.log"), String)
        @test occursin("MinActivePowerTimeSeriesParameter for Brighton at step 3", log)
    end
end

@testset "Validation: a minimum above the maximum series fails the build" begin
    max_values = ones(24)
    max_values[5] = 0.5
    sys, _ = _min_power_system(fill(0.6, 24); max_values)
    model = _min_power_uc_model(sys)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == ModelBuildStatus.FAILED
    log = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("MinActivePowerTimeSeriesParameter for Brighton at step 5", log)
end

@testset "Rebuild: a profiled unit under recurrent solves turns on rebuild_model" begin
    sys, _ = _min_power_system(fill(0.2, 24))
    model = _min_power_uc_model(sys; recurrent = true)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    @test IOM.get_rebuild_model(IOM.get_settings(model))

    sys, _ = _min_power_system(fill(0.2, 24))
    model = _min_power_uc_model(sys)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    @test !IOM.get_rebuild_model(IOM.get_settings(model))
end

@testset "Multipliers" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_hy")
    hydro = only(get_components(HydroDispatch, sys))
    @test POM.get_multiplier_value(
        MinActivePowerTimeSeriesParameter,
        hydro,
        HydroDispatchRunOfRiver,
    ) == PSY.get_max_active_power(hydro, u"SU")

    thermal = first(get_components(ThermalStandard, sys))
    @test POM.get_multiplier_value(
        MinActivePowerTimeSeriesParameter,
        thermal,
        ThermalStandardUnitCommitment,
    ) == PSY.get_max_active_power(thermal, u"SU")

    pump_sys = PSB.build_system(PSITestSystems, "c_sys5_hydro_pump_energy")
    pump = first(get_components(HydroPumpTurbine, pump_sys))
    @test POM.get_multiplier_value(
        MinActivePowerInTimeSeriesParameter,
        pump,
        HydroPumpEnergyDispatch,
    ) == PSY.get_active_power_limits_pump(pump, u"SU").max
end

function _built_min_power_container(sys; kwargs...)
    model = _min_power_uc_model(sys; kwargs...)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    return model, IOM.get_optimization_container(model)
end

_limit_rows(container, meta) = IOM.get_constraint(
    container,
    IOM.ConstraintKey(ActivePowerVariableLimitsConstraint, ThermalStandard, meta),
)

const MIN_POWER_VALUES = [0.3 + 0.01 * t for t in 1:24]

@testset "Standard UC: lower row coefficient is -Pmax * series" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    _, container = _built_min_power_container(sys)
    pmax = PSY.get_max_active_power(unit, u"SU")
    rows = _limit_rows(container, "lb")
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    for t in 1:24
        func = JuMP.constraint_object(rows["Brighton", t]).func
        @test JuMP.coefficient(func, on["Brighton", t]) ≈ -pmax * MIN_POWER_VALUES[t]
    end
    other = JuMP.constraint_object(rows["Alta", 1]).func
    @test JuMP.coefficient(other, on["Alta", 1]) ≈
          -PSY.get_active_power_limits(
        get_component(ThermalStandard, sys, "Alta"),
        u"SU",
    ).min
end

@testset "Standard dispatch: lower row bound is Pmax * series" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    _, container = _built_min_power_container(sys; formulation = ThermalStandardDispatch)
    pmax = PSY.get_max_active_power(unit, u"SU")
    rows = _limit_rows(container, "lb")
    for t in 1:24
        @test JuMP.normalized_rhs(rows["Brighton", t]) ≈ pmax * MIN_POWER_VALUES[t]
    end
end

@testset "Dispatch no minimum keeps static limits" begin
    sys, _ = _min_power_system(MIN_POWER_VALUES)
    _, container = _built_min_power_container(sys; formulation = ThermalDispatchNoMin)
    rows = _limit_rows(container, "lb")
    for t in 1:24
        @test iszero(JuMP.normalized_rhs(rows["Brighton", t]))
    end
end

@testset "Must-run: rows and variable bound follow the series" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    _, container = _built_min_power_container(sys)
    pmax = PSY.get_max_active_power(unit, u"SU")
    rows = _limit_rows(container, "lb")
    for t in 1:24
        @test JuMP.normalized_rhs(rows["Brighton", t]) ≈ pmax * MIN_POWER_VALUES[t]
    end
    p = IOM.get_variable(container, ActivePowerVariable, ThermalStandard)
    @test JuMP.lower_bound(p["Brighton", 1]) ≈ pmax * minimum(MIN_POWER_VALUES)
end

@testset "Behavior: a committed unit meets the raised minimum" begin
    values = fill(0.2, 24)
    values[10] = 0.9
    sys, unit = _min_power_system(values)
    model, container = _built_min_power_container(sys)
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    JuMP.fix(on["Brighton", 10], 1.0; force = true)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    res = IOM.OptimizationProblemOutputs(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    base = IOM.get_model_base_power(res)
    power = read_variable(
        res,
        "ActivePowerVariable__ThermalStandard";
        table_format = TableFormat.WIDE,
    )
    @test power[10, "Brighton"] / base >= 0.9 * pmax - 1e-6
end

@testset "Dispatch no minimum: feedforward multiplier stays static" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    _, container = _built_min_power_container(sys; formulation = ThermalDispatchNoMin)
    mult = POM._on_status_multipliers(
        container,
        ActivePowerRangeExpressionLB,
        unit,
        ThermalDispatchNoMin,
    )
    static = POM.get_expression_multiplier(
        OnStatusParameter,
        ActivePowerRangeExpressionLB,
        unit,
        ThermalDispatchNoMin,
    )
    @test mult == fill(static, 24)
    uc = POM._on_status_multipliers(
        container,
        ActivePowerRangeExpressionLB,
        unit,
        ThermalStandardUnitCommitment,
    )
    @test uc ≈ PSY.get_max_active_power(unit, u"SU") .* MIN_POWER_VALUES
end

@testset "Unmapped series: same rows as no series" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    unit = get_component(ThermalStandard, sys, "Brighton")
    add_min_power_series!(sys, unit, ones(24); name = "max_active_power")
    _, mapped = _built_min_power_container(sys)
    _, unmapped = _built_min_power_container(
        sys;
        names = Dict(ActivePowerTimeSeriesParameter => "max_active_power"),
    )
    for meta in ("lb", "ub")
        a = _limit_rows(mapped, meta)
        b = _limit_rows(unmapped, meta)
        @test axes(a) == axes(b)
        for idx in eachindex(a)
            ca = JuMP.constraint_object(a[idx])
            cb = JuMP.constraint_object(b[idx])
            @test string(ca.func) == string(cb.func)
            @test ca.set == cb.set
        end
    end
end

@testset "Ramp start term follows the series" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    _, container = _built_min_power_container(sys)
    pmax = PSY.get_max_active_power(unit, u"SU")
    rows = IOM.get_constraint(
        container,
        IOM.ConstraintKey(RampConstraint, ThermalStandard, "up"),
    )
    start = IOM.get_variable(container, StartVariable, ThermalStandard)
    for t in 1:24
        func = JuMP.constraint_object(rows["Brighton", t]).func
        @test abs(JuMP.coefficient(func, start["Brighton", t])) ≈
              pmax * MIN_POWER_VALUES[t]
    end
end

_compact_model(sys; kwargs...) =
    _min_power_uc_model(sys; formulation = ThermalCompactUnitCommitment, kwargs...)

# Constant and `OnVariable` coefficient of the first balance row at step `t`.
function _balance_row(container, t)
    bal = IOM.get_expression(container, ActivePowerBalance, System)
    return bal[first(axes(bal, 1)), t]
end

@testset "Compact UC: range row and balance follow the series" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    model = _compact_model(sys)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    ub = _limit_rows(container, "ub")
    for t in 1:24
        pmin_t = pmax * MIN_POWER_VALUES[t]
        func = JuMP.constraint_object(ub["Brighton", t]).func
        @test JuMP.coefficient(func, on["Brighton", t]) ≈ -(pmax - pmin_t)
        @test JuMP.coefficient(_balance_row(container, t), on["Brighton", t]) ≈ pmin_t
    end
    other = get_component(ThermalStandard, sys, "Alta")
    @test JuMP.coefficient(_balance_row(container, 1), on["Alta", 1]) ≈
          PSY.get_active_power_limits(other, u"SU").min
end

@testset "Compact UC must-run: the balance constant follows the series" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    _, profiled =
        _built_min_power_container(sys; formulation = ThermalCompactUnitCommitment)
    sys2, unit2 = _min_power_system(MIN_POWER_VALUES)
    PSY.set_commitment_mode!(unit2, PSY.CommitmentModes.MUST_RUN)
    _, static = _built_min_power_container(
        sys2;
        formulation = ThermalCompactUnitCommitment,
        names = Dict(ActivePowerTimeSeriesParameter => "max_active_power"),
    )
    pmax = PSY.get_max_active_power(unit, u"SU")
    static_min = PSY.get_active_power_limits(unit, u"SU").min
    for t in 1:24
        delta =
            JuMP.constant(_balance_row(profiled, t)) -
            JuMP.constant(_balance_row(static, t))
        @test delta ≈ pmax * MIN_POWER_VALUES[t] - static_min
    end
end

@testset "Compact UC: PowerOutput equals Pmin_t * u_t + dp_t" begin
    values = fill(0.2, 24)
    values[10] = 0.9
    sys, unit = _min_power_system(values)
    model = _compact_model(sys)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    res = IOM.OptimizationProblemOutputs(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    base = IOM.get_model_base_power(res)
    on = read_variable(res, "OnVariable__ThermalStandard"; table_format = TableFormat.WIDE)
    dp = read_variable(
        res,
        "PowerAboveMinimumVariable__ThermalStandard";
        table_format = TableFormat.WIDE,
    )
    out = read_aux_variable(
        res,
        "PowerOutput__ThermalStandard";
        table_format = TableFormat.WIDE,
    )
    for t in 1:24
        @test out[t, "Brighton"] ≈
              on[t, "Brighton"] * base * pmax * values[t] + dp[t, "Brighton"] atol = 1e-5
    end
end

@testset "Compact UC: variable bound, initial condition, and warm start use the series" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    model = _compact_model(sys; initialize_model = false)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    p0 = PSY.get_active_power(unit, u"SU")
    pmin_1 = pmax * MIN_POWER_VALUES[1]
    dp = IOM.get_variable(container, PowerAboveMinimumVariable, ThermalStandard)
    @test JuMP.upper_bound(dp["Brighton", 5]) ≈ pmax - pmax * minimum(MIN_POWER_VALUES)
    @test JuMP.start_value(dp["Brighton", 1]) ≈ max(0.0, p0 - pmin_1)
    alta = get_component(ThermalStandard, sys, "Alta")
    alta_min = PSY.get_active_power_limits(alta, u"SU").min
    @test JuMP.upper_bound(dp["Alta", 5]) ≈
          PSY.get_active_power_limits(alta, u"SU").max - alta_min
    ics = IOM.get_initial_condition(container, POM.DeviceAboveMinPower(), ThermalStandard)
    ic = only([i for i in ics if IOM.get_component_name(i) == "Brighton"])
    @test IOM.jump_fixed_value(IOM.get_value(ic)) ≈ max(0.0, p0 - pmin_1)
end

@testset "Compact dispatch: range row bound is Pmax - Pmin_t" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    _, container = _built_min_power_container(sys; formulation = ThermalCompactDispatch)
    pmax = PSY.get_max_active_power(unit, u"SU")
    rows = _limit_rows(container, "ub")
    for t in 1:24
        @test JuMP.normalized_rhs(rows["Brighton", t]) ≈
              pmax - pmax * MIN_POWER_VALUES[t]
    end
end

@testset "Multi-start: the on row follows the series" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_pglib")
    unit = get_component(ThermalMultiStart, sys, "115_STEAM_1")
    add_min_power_series!(sys, unit, MIN_POWER_VALUES)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, ThermalStandard, ThermalStandardDispatch)
    set_device_model!(
        template,
        DeviceModel(
            ThermalMultiStart,
            ThermalMultiStartUnitCommitment;
            time_series_names = Dict(
                MinActivePowerTimeSeriesParameter => "min_active_power",
            ),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    startup = PSY.get_power_trajectory(unit, u"SU").startup
    on = IOM.get_variable(container, OnVariable, ThermalMultiStart)
    start = IOM.get_variable(container, StartVariable, ThermalMultiStart)
    rows = IOM.get_constraint(
        container,
        IOM.ConstraintKey(ActivePowerVariableLimitsConstraint, ThermalMultiStart, "ubon"),
    )
    for t in 1:24
        func = JuMP.constraint_object(rows["115_STEAM_1", t]).func
        range_t = pmax - pmax * MIN_POWER_VALUES[t]
        @test JuMP.coefficient(func, on["115_STEAM_1", t]) ≈ -range_t
        @test JuMP.coefficient(func, start["115_STEAM_1", t]) ≈ max(pmax - startup, 0.0)
    end
end

@testset "Compact fuel term: coefficient on u_t over coefficient on dp_t is Pmin_t" begin
    sys = PSB.build_system(PSITestSystems, "c_linear_fuel_test")
    unit = get_component(ThermalStandard, sys, "Test Unit")
    values = MIN_POWER_VALUES[1:5]
    add_min_power_series!(sys, unit, values)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(
        template,
        DeviceModel(
            ThermalStandard,
            ThermalCompactUnitCommitment;
            time_series_names = Dict(
                MinActivePowerTimeSeriesParameter => "min_active_power",
            ),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    dp = IOM.get_variable(container, PowerAboveMinimumVariable, ThermalStandard)
    fuel = IOM.get_expression(container, FuelConsumptionExpression, ThermalStandard)
    for t in 1:5
        coef_dp = JuMP.coefficient(fuel["Test Unit", t], dp["Test Unit", t])
        coef_on = JuMP.coefficient(fuel["Test Unit", t], on["Test Unit", t])
        @test !iszero(coef_dp)
        @test coef_on / coef_dp ≈ pmax * values[t]
    end
end

@testset "Compact VOM term: coefficient on u_t over coefficient on dp_t is Pmin_t" begin
    sys = PSB.build_system(PSITestSystems, "c_linear_cost_test")
    unit = get_component(ThermalStandard, sys, "Test Unit")
    set_variable_operation_cost!(
        get_operation_cost(unit),
        CostCurve(LinearCurve(10.23), LinearCurve(3.0)),
    )
    values = MIN_POWER_VALUES[1:5]
    add_min_power_series!(sys, unit, values)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(
        template,
        DeviceModel(
            ThermalStandard,
            ThermalCompactUnitCommitment;
            time_series_names = Dict(
                MinActivePowerTimeSeriesParameter => "min_active_power",
            ),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    dp = IOM.get_variable(container, PowerAboveMinimumVariable, ThermalStandard)
    vom = IOM.get_expression(container, IOM.VOMCostExpression, ThermalStandard)
    for t in 1:5
        coef_dp = JuMP.coefficient(vom["Test Unit", t], dp["Test Unit", t])
        coef_on = JuMP.coefficient(vom["Test Unit", t], on["Test Unit", t])
        @test !iszero(coef_dp)
        @test coef_on / coef_dp ≈ pmax * values[t]
    end
end

# A model with a minimum power series rebuilds at every step of a recurrent solve, so its
# `OnStatusParameter` holds numbers that the rows read when they are built. A probe writes a
# status pattern and rebuilds, as a simulation step does; the term of the status is the
# change it makes in the rows.
function _rebuild_with_on_status!(model, device_model, ::Type{D}, name, pattern) where {D}
    container = IOM.get_optimization_container(model)
    status = IOM.get_parameter_array(container, OnStatusParameter, D)
    for t in axes(status, 2)
        status[name, t] = pattern[t]
    end
    mock_rebuild_devices!(model, (device_model,))
    return container
end

function _compact_dispatch_ff_model(values)
    sys, unit = _min_power_system(values)
    ff = SemiContinuousFeedforward(;
        component_type = ThermalStandard,
        source = OnVariable,
        affected_values = [PowerAboveMinimumVariable],
    )
    device_model = DeviceModel(
        ThermalStandard,
        ThermalCompactDispatch;
        time_series_names = MIN_POWER_UC_NAMES,
    )
    attach_feedforward!(device_model, ff)
    model = DecisionModel(MockOperationProblem, DCPNetworkModel, sys)
    mock_construct_device!(model, device_model)
    return unit, model, device_model
end

@testset "Compact dispatch with feedforward: range upper row follows the series" begin
    unit, model, device_model = _compact_dispatch_ff_model(MIN_POWER_VALUES)
    pmax = PSY.get_max_active_power(unit, u"SU")
    function constants(pattern)
        container =
            _rebuild_with_on_status!(
                model,
                device_model,
                ThermalStandard,
                "Brighton",
                pattern,
            )
        expr = IOM.get_expression(container, ActivePowerRangeExpressionUB, ThermalStandard)
        return [JuMP.constant(expr["Brighton", t]) for t in 1:24]
    end
    on = constants(ones(24))
    off = constants(zeros(24))
    for t in 1:24
        @test on[t] - off[t] ≈ -(pmax - pmax * MIN_POWER_VALUES[t])
    end
end

@testset "Offline reserve ReservePowerConstraint: limit follows Pmin_t" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc_non_spin"; add_reserves = true)
    unit = first(get_components(ThermalMultiStart, sys))
    name = PSY.get_name(unit)
    add_min_power_series!(sys, unit, MIN_POWER_VALUES)
    template = get_thermal_standard_uc_template()
    set_device_model!(
        template,
        DeviceModel(
            ThermalMultiStart,
            ThermalStandardUnitCommitment;
            time_series_names = Dict(
                MinActivePowerTimeSeriesParameter => "min_active_power",
            ),
        ),
    )
    set_service_model!(template, ServiceModel(OfflineReserve, NonSpinningReserve))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    on = IOM.get_variable(container, OnVariable, ThermalMultiStart)
    rows = IOM.get_constraint(
        container,
        POM.ReservePowerConstraint,
        IOM.ComponentPairKey{ThermalMultiStart, OfflineReserve},
    )
    service = first(get_components(OfflineReserve, sys))
    ramp_up = PSY.get_ramp_limits(unit, u"SU/minute").up
    startup = POM._nonspin_startup_time(unit)
    response = PSY.get_time_frame(service)
    @test response > startup
    for t in 1:24
        expected = min(pmax, pmax * MIN_POWER_VALUES[t] + (response - startup) * ramp_up)
        c = rows[(PSY.get_name(service), name, t)]
        @test JuMP.normalized_coefficient(c, on[name, t]) ≈ expected
    end
end

@testset "Ramp reserve filter: a profiled device with a wider range is kept" begin
    function ramp_devices(sys, names)
        template = get_thermal_dispatch_template_network(CopperPlateNetworkModel)
        if !isnothing(names)
            set_device_model!(
                template,
                DeviceModel(
                    ThermalStandard,
                    ThermalStandardDispatch;
                    time_series_names = names,
                ),
            )
        end
        set_service_model!(
            template,
            ServiceModel(OnlineReserve{ReserveUp}, RampReserve),
        )
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        rows = IOM.get_constraint(
            container,
            RampConstraint,
            IOM.ComponentPairKey{ThermalStandard, OnlineReserve{ReserveUp}},
        )
        return Set(idx[2] for idx in keys(rows.data))
    end
    function ramp_system()
        sys = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_reserves = true)
        unit = get_component(ThermalStandard, sys, "Brighton")
        pmax = PSY.get_max_active_power(unit, u"SU")
        pmin = PSY.get_active_power_limits(unit, u"SU").min
        # Above the static maximum rate for every service: the static filter drops the unit.
        rate =
            1.1 * (pmax - pmin) / minimum(
                PSY.get_time_frame(s) for s in get_components(OnlineReserve{ReserveUp}, sys)
            )
        PSY.set_ramp_limits!(unit, (up = rate * u"SU/minute", down = rate * u"SU/minute"))
        return sys, unit
    end
    sys, unit = ramp_system()
    @test !("Brighton" in ramp_devices(sys, nothing))
    sys, unit = ramp_system()
    add_min_power_series!(sys, unit, fill(0.1, 24))
    add_min_power_series!(sys, unit, ones(24); name = "max_active_power")
    @test "Brighton" in ramp_devices(sys, MIN_POWER_UC_NAMES)
end

@testset "Compact UC ramp level term: u_t and start_t coefficients shift by the Pmin change" begin
    values = copy(MIN_POWER_VALUES)
    values[3] = 0.6
    sys, unit = _min_power_system(values)
    model = _compact_model(sys)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    start = IOM.get_variable(container, StartVariable, ThermalStandard)
    stop = IOM.get_variable(container, StopVariable, ThermalStandard)
    up = IOM.get_constraint(
        container,
        IOM.ConstraintKey(RampConstraint, ThermalStandard, "up"),
    )
    dn = IOM.get_constraint(
        container,
        IOM.ConstraintKey(RampConstraint, ThermalStandard, "dn"),
    )
    @test iszero(JuMP.normalized_coefficient(up["Brighton", 1], on["Brighton", 1]))
    for t in 2:24
        delta = pmax * (values[t] - values[t - 1])
        @test JuMP.normalized_coefficient(up["Brighton", t], on["Brighton", t]) ≈ delta
        @test JuMP.normalized_coefficient(up["Brighton", t], start["Brighton", t]) ≈
              -delta
        @test JuMP.normalized_coefficient(dn["Brighton", t], on["Brighton", t]) ≈ -delta
        @test JuMP.normalized_coefficient(dn["Brighton", t], start["Brighton", t]) ≈
              delta
        @test iszero(JuMP.normalized_coefficient(dn["Brighton", t], stop["Brighton", t]))
    end
    other = first(setdiff(axes(up, 1), ["Brighton"]))
    for t in 1:24
        @test iszero(JuMP.normalized_coefficient(up[other, t], on[other, t]))
        @test iszero(JuMP.normalized_coefficient(dn[other, t], on[other, t]))
    end
end

function _ramp_binding_system(values)
    sys, unit = _min_power_system(values)
    PSY.set_ramp_limits!(unit, (up = 0.045 * u"SU/minute", down = 0.045 * u"SU/minute"))
    return sys, unit
end

# Step changes stay within the ramp limit. The series has a zero block.
const RAMP_LEVEL_VALUES = vcat(
    fill(0.2, 3),
    fill(0.4, 3),
    fill(0.0, 3),
    fill(0.3, 3),
    fill(0.5, 3),
    fill(0.25, 3),
    fill(0.4, 6),
)

function _solved_outputs(formulation, sys)
    model = _min_power_uc_model(sys; formulation = formulation)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    return model, IOM.OptimizationProblemOutputs(model)
end

# The compact cost misses the minimum power term until the compact cost gap is closed, so the
# two models can pick different dispatch. The compact feasible set is compared instead: the
# standard solution must be feasible in the compact model, and the compact total power
# must obey the ramp limit between two steps with the unit on.
@testset "Compact equals standard: ramp feasible set with a changing minimum series" begin
    sys, unit = _ramp_binding_system(RAMP_LEVEL_VALUES)
    std_model, std_res = _solved_outputs(ThermalStandardUnitCommitment, sys)
    std_power = read_variable(
        std_res,
        "ActivePowerVariable__ThermalStandard";
        table_format = TableFormat.WIDE,
    )
    std_on = read_variable(
        std_res,
        "OnVariable__ThermalStandard";
        table_format = TableFormat.WIDE,
    )
    std_obj = IOM.get_objective_value(std_res)
    base = IOM.get_model_base_power(std_res)

    cmp_model = _min_power_uc_model(sys; formulation = ThermalCompactUnitCommitment)
    @test build!(cmp_model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(cmp_model)
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    dp = IOM.get_variable(container, PowerAboveMinimumVariable, ThermalStandard)
    for d in get_components(ThermalStandard, sys)
        name = PSY.get_name(d)
        pmin = POM.min_active_power_values(container, d)
        for t in 1:24
            u = round(std_on[t, name])
            JuMP.fix(on[name, t], u; force = true)
            JuMP.fix(
                dp[name, t],
                max(0.0, std_power[t, name] / base - pmin[t] * u);
                force = true,
            )
        end
    end
    @test solve!(cmp_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    _, cmp_res = _solved_outputs(
        ThermalCompactUnitCommitment,
        _ramp_binding_system(RAMP_LEVEL_VALUES)[1],
    )
    cmp_power = read_aux_variable(
        cmp_res,
        "PowerOutput__ThermalStandard";
        table_format = TableFormat.WIDE,
    )
    cmp_on = read_variable(
        cmp_res,
        "OnVariable__ThermalStandard";
        table_format = TableFormat.WIDE,
    )
    ramp = 0.045 * 60 * base
    for t in 2:24
        if cmp_on[t, "Brighton"] > 0.5 && cmp_on[t - 1, "Brighton"] > 0.5
            @test abs(cmp_power[t, "Brighton"] - cmp_power[t - 1, "Brighton"]) <=
                  ramp + 1e-5
        end
    end
    @test isapprox(std_obj, IOM.get_objective_value(cmp_res); rtol = 1e-6)
end

@testset "Compact equals standard: power and objective match with a changing minimum series" begin
    sys, _ = _ramp_binding_system(RAMP_LEVEL_VALUES)
    _, std_res = _solved_outputs(ThermalStandardUnitCommitment, sys)
    _, cmp_res = _solved_outputs(ThermalCompactUnitCommitment, sys)
    std_power = read_variable(
        std_res,
        "ActivePowerVariable__ThermalStandard";
        table_format = TableFormat.WIDE,
    )
    cmp_power = read_aux_variable(
        cmp_res,
        "PowerOutput__ThermalStandard";
        table_format = TableFormat.WIDE,
    )
    for name in names(std_power), t in 1:24
        name == "DateTime" && continue
        @test std_power[t, name] ≈ cmp_power[t, name] atol = 1e-5
    end
    @test isapprox(
        IOM.get_objective_value(std_res),
        IOM.get_objective_value(cmp_res);
        rtol = 1e-6,
    )
end

function _linear_cost_system(values; slope, constant, must_run = false)
    sys, unit = _min_power_system(values)
    cost = PSY.get_operation_cost(unit)
    PSY.set_operation_cost!(
        unit,
        PSY.ThermalGenerationCost(;
            variable_operation_cost = PSY.CostCurve(
                PSY.LinearCurve(slope, constant),
            ),
            fixed = PSY.get_fixed(cost),
            start_up = PSY.get_start_up(cost),
            shut_down = PSY.get_shut_down(cost),
        ),
    )
    if must_run
        PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    end
    return sys, unit
end

function _objective_of(sys; formulation = ThermalCompactUnitCommitment)
    _, container = _built_min_power_container(sys; formulation = formulation)
    return container, JuMP.objective_function(IOM.get_jump_model(container))
end

@testset "Compact linear cost: the OnVariable coefficient includes slope * Pmin_t" begin
    slope = 17.0
    sys0, _ = _linear_cost_system(MIN_POWER_VALUES; slope = 0.0, constant = 3.0)
    sys1, unit = _linear_cost_system(MIN_POWER_VALUES; slope = slope, constant = 3.0)
    container0, obj0 = _objective_of(sys0)
    container, obj1 = _objective_of(sys1)
    on0 = IOM.get_variable(container0, OnVariable, ThermalStandard)
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    pmin = POM.min_active_power_values(container, unit)
    base = IOM.get_model_base_power(container)
    for t in 1:24
        delta =
            JuMP.coefficient(obj1, on["Brighton", t]) -
            JuMP.coefficient(obj0, on0["Brighton", t])
        @test delta ≈ slope * base * pmin[t]
    end
end

@testset "Compact linear cost, must-run: the objective constant grows by slope * Pmin_t" begin
    slope = 17.0
    sys0, _ = _linear_cost_system(
        MIN_POWER_VALUES;
        slope = 0.0,
        constant = 3.0,
        must_run = true,
    )
    sys1, unit = _linear_cost_system(
        MIN_POWER_VALUES;
        slope = slope,
        constant = 3.0,
        must_run = true,
    )
    _, obj0 = _objective_of(sys0)
    container, obj1 = _objective_of(sys1)
    pmin = POM.min_active_power_values(container, unit)
    base = IOM.get_model_base_power(container)
    @test JuMP.constant(obj1) - JuMP.constant(obj0) ≈ slope * base * sum(pmin)
end

function _set_variable_cost!(unit, curve)
    cost = PSY.get_operation_cost(unit)
    PSY.set_operation_cost!(
        unit,
        PSY.ThermalGenerationCost(;
            variable_operation_cost = curve,
            fixed = PSY.get_fixed(cost),
            start_up = PSY.get_start_up(cost),
            shut_down = PSY.get_shut_down(cost),
        ),
    )
    return
end

function _fuel_cost_system(
    values;
    slope,
    fuel_cost,
    units = IS.NaturalUnit(),
    rebase = nothing,
)
    sys, unit = _min_power_system(values)
    if !isnothing(rebase)
        PSY.rebase_component!(unit, rebase)
    end
    _set_variable_cost!(
        unit,
        PSY.FuelCurve(;
            value_curve = PSY.LinearCurve(slope, 3.0),
            power_units = units,
            fuel_cost = fuel_cost,
        ),
    )
    return sys, unit
end

@testset "Compact static fuel linear cost: the OnVariable coefficient includes slope * fuel_cost * Pmin_t" begin
    slope = 17.0
    fuel_cost = 2.5
    device_base = 50.0
    rebase = device_base * u"NU"
    units = IS.ComponentBaseUnit()
    sys0, _ = _fuel_cost_system(
        MIN_POWER_VALUES; slope = 0.0, fuel_cost = fuel_cost, units = units,
        rebase = rebase)
    sys1, unit = _fuel_cost_system(
        MIN_POWER_VALUES; slope = slope, fuel_cost = fuel_cost, units = units,
        rebase = rebase)
    @test PSY.get_base_power(unit, u"NU") == device_base
    container0, obj0 = _objective_of(sys0)
    container, obj1 = _objective_of(sys1)
    on0 = IOM.get_variable(container0, OnVariable, ThermalStandard)
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    pmin = POM.min_active_power_values(container, unit)
    base = IOM.get_model_base_power(container)
    @test base != device_base
    per_unit = IOM.get_proportional_cost_per_system_unit(
        slope, units, base, device_base)
    @test !isapprox(per_unit, slope * base)
    for t in 1:24
        delta =
            JuMP.coefficient(obj1, on["Brighton", t]) -
            JuMP.coefficient(obj0, on0["Brighton", t])
        @test delta ≈ per_unit * fuel_cost * pmin[t]
    end
end

@testset "Compact UC: a nonzero quadratic term in the cost throws" begin
    quad = PSY.QuadraticCurve(0.5, 17.0, 3.0)
    for curve in (
        PSY.CostCurve(quad),
        PSY.FuelCurve(; value_curve = quad, fuel_cost = 2.5),
    )
        sys, unit = _min_power_system(MIN_POWER_VALUES)
        _set_variable_cost!(unit, curve)
        model = _min_power_uc_model(sys; formulation = ThermalCompactUnitCommitment)
        @test_throws IS.ConflictingInputsError POM.add_variable_cost_to_objective!(
            IOM.get_optimization_container(model),
            PowerAboveMinimumVariable,
            unit,
            curve,
            ThermalCompactUnitCommitment,
        )
    end
end

function _compact_dispatch_feedforward_build(s::Float64)
    sys, unit = _linear_cost_system(MIN_POWER_VALUES; slope = s, constant = 3.0)
    ff = SemiContinuousFeedforward(;
        component_type = ThermalStandard,
        source = OnVariable,
        affected_values = [PowerAboveMinimumVariable],
    )
    device_model = DeviceModel(
        ThermalStandard,
        ThermalCompactDispatch;
        time_series_names = MIN_POWER_UC_NAMES,
    )
    attach_feedforward!(device_model, ff)
    model = DecisionModel(MockOperationProblem, DCPNetworkModel, sys)
    mock_construct_device!(model, device_model)
    return unit, model, device_model
end

@testset "Compact dispatch with feedforward: the offset term uses the OnStatusParameter" begin
    slope = 17.0
    _, model0, device_model0 = _compact_dispatch_feedforward_build(0.0)
    unit, model1, device_model1 = _compact_dispatch_feedforward_build(slope)
    function objective_constant(model, device_model, pattern)
        container = _rebuild_with_on_status!(
            model, device_model, ThermalStandard, "Brighton", pattern)
        return JuMP.constant(container.objective_function.invariant_terms)
    end
    # The offset of each step is the change one status makes in the objective.
    offset(model, device_model, t) =
        objective_constant(model, device_model, [s == t ? 1.0 : 0.0 for s in 1:24]) -
        objective_constant(model, device_model, zeros(24))
    container = IOM.get_optimization_container(model1)
    pmin = POM.min_active_power_values(container, unit)
    base = IOM.get_model_base_power(container)
    for t in 1:24
        delta = offset(model1, device_model1, t) - offset(model0, device_model0, t)
        @test delta ≈ slope * base * pmin[t]
    end
end

@testset "Compact dispatch linear cost: the offset uses status 1 without feedforward" begin
    slope = 17.0
    sys0, _ = _linear_cost_system(MIN_POWER_VALUES; slope = 0.0, constant = 3.0)
    sys1, unit = _linear_cost_system(MIN_POWER_VALUES; slope = slope, constant = 3.0)
    _, obj0 = _objective_of(sys0; formulation = ThermalCompactDispatch)
    container, obj1 = _objective_of(sys1; formulation = ThermalCompactDispatch)
    pmin = POM.min_active_power_values(container, unit)
    base = IOM.get_model_base_power(container)
    @test JuMP.constant(obj1) - JuMP.constant(obj0) ≈ slope * base * sum(pmin)
end

# The first value of the maximum series sets the initial power to 1.2 SU. The first minimum is
# also 1.2 SU. The unit is forced on and the ramp limit is 1.2 SU per step. The unit can reach a
# minimum of 1.8 SU at step 2, but not 4.2 SU. The compact rows catch this only through the
# level term.
@testset "Compact ramp: a minimum rise above the ramp limit is infeasible with the unit on" begin
    for (high, feasible) in ((0.3, true), (0.7, false)),
        formulation in (ThermalStandardUnitCommitment, ThermalCompactUnitCommitment)

        values = vcat(0.2, fill(high, 23))
        sys, unit = _min_power_system(values; max_values = vcat(0.2, ones(23)))
        PSY.set_ramp_limits!(unit, (up = 0.02 * u"SU/minute", down = 0.02 * u"SU/minute"))
        model = _min_power_uc_model(sys; formulation = formulation)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        on = IOM.get_variable(container, OnVariable, ThermalStandard)
        for t in 1:24
            JuMP.fix(on["Brighton", t], 1.0; force = true)
        end
        solve!(model)
        status = JuMP.termination_status(IOM.get_jump_model(container))
        @test (status == JuMP.MOI.OPTIMAL) == feasible
    end
end

@testset "Multi-start ramp level term: u_t and start_t coefficients shift by the Pmin change" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_pglib")
    unit = get_component(ThermalMultiStart, sys, "115_STEAM_1")
    add_min_power_series!(sys, unit, MIN_POWER_VALUES)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, ThermalStandard, ThermalStandardDispatch)
    set_device_model!(
        template,
        DeviceModel(
            ThermalMultiStart,
            ThermalMultiStartUnitCommitment;
            time_series_names = Dict(
                MinActivePowerTimeSeriesParameter => "min_active_power",
            ),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    on = IOM.get_variable(container, OnVariable, ThermalMultiStart)
    start = IOM.get_variable(container, StartVariable, ThermalMultiStart)
    up = IOM.get_constraint(
        container,
        IOM.ConstraintKey(RampConstraint, ThermalMultiStart, "up"),
    )
    name = "115_STEAM_1"
    @test name in axes(up, 1)
    for t in 2:24
        delta = pmax * (MIN_POWER_VALUES[t] - MIN_POWER_VALUES[t - 1])
        @test JuMP.normalized_coefficient(up[name, t], on[name, t]) ≈ delta
        @test JuMP.normalized_coefficient(up[name, t], start[name, t]) ≈ -delta
    end
end

function _ramp_rows(container, ::Type{V}) where {V}
    return (
        up = IOM.get_constraint(container, IOM.ConstraintKey(RampConstraint, V, "up")),
        dn = IOM.get_constraint(container, IOM.ConstraintKey(RampConstraint, V, "dn")),
    )
end

const STATIC_MIN_NAMES = Dict(ActivePowerTimeSeriesParameter => "max_active_power")

@testset "Compact UC must-run ramp level term: the right side shifts by the Pmin change" begin
    values = copy(MIN_POWER_VALUES)
    values[3] = 0.6
    sys, unit = _min_power_system(values)
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    _, profiled =
        _built_min_power_container(sys; formulation = ThermalCompactUnitCommitment)
    sys2, unit2 = _min_power_system(values)
    PSY.set_commitment_mode!(unit2, PSY.CommitmentModes.MUST_RUN)
    _, static = _built_min_power_container(
        sys2;
        formulation = ThermalCompactUnitCommitment,
        names = STATIC_MIN_NAMES,
    )
    pmax = PSY.get_max_active_power(unit, u"SU")
    prof = _ramp_rows(profiled, ThermalStandard)
    ref = _ramp_rows(static, ThermalStandard)
    @test "Brighton" in axes(prof.up, 1)
    for t in 2:24
        delta = pmax * (values[t] - values[t - 1])
        @test JuMP.normalized_rhs(prof.up["Brighton", t]) -
              JuMP.normalized_rhs(ref.up["Brighton", t]) ≈ -delta
        @test JuMP.normalized_rhs(prof.dn["Brighton", t]) -
              JuMP.normalized_rhs(ref.dn["Brighton", t]) ≈ delta
    end
end

# The level term of a must-run compact unit is the change of `s_t Pmin_t`, with `s` its
# injector status and the unit in service at its first minimum before step 1.
function _status_level(pmin, out_steps)
    level = [t in out_steps ? 0.0 : pmin[t] for t in eachindex(pmin)]
    return [level[t] - (t == 1 ? pmin[1] : level[t - 1]) for t in eachindex(level)]
end

@testset "Compact UC must-run ramp level term follows the outage, series $(profiled)" for profiled in
                                                                                          (
    true,
    false,
)
    names = profiled ? MIN_POWER_UC_NAMES : STATIC_MIN_NAMES
    function ramp_rows(out)
        sys, unit = _min_power_system(MIN_POWER_VALUES)
        PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
        out && _schedule_outage!(sys, unit, "maint", _maintenance)
        _, container = _built_min_power_container(
            sys;
            formulation = ThermalCompactUnitCommitment,
            names = names,
        )
        return _ramp_rows(container, ThermalStandard), unit
    end
    rows, unit = ramp_rows(true)
    ref, _ = ramp_rows(false)
    pmin = if profiled
        PSY.get_max_active_power(unit, u"SU") .* MIN_POWER_VALUES
    else
        fill(PSY.get_active_power_limits(unit, u"SU").min, 24)
    end
    shift = _status_level(pmin, _OUT_STEPS) .- _status_level(pmin, ())
    @test any(!iszero, shift)
    for t in 1:24
        @test JuMP.normalized_rhs(rows.up["Brighton", t]) -
              JuMP.normalized_rhs(ref.up["Brighton", t]) ≈ -shift[t] atol = 1e-9
        @test JuMP.normalized_rhs(rows.dn["Brighton", t]) -
              JuMP.normalized_rhs(ref.dn["Brighton", t]) ≈ shift[t] atol = 1e-9
    end
end

# Brighton must-run on c_sys5_uc with loads at 40%, no minimum times, a loose ramp-up and a
# ramp-down of `ramp_down` times its minimum per hour; at the default of one half, a drop from
# its minimum to zero in one step is infeasible. `pattern(t0, h)` is 1.0 where the unit is out at step `h` of the forecast window
# starting at `t0`. The model starts at `initial_time`.
function _slow_must_run_status(
    formulation;
    initial_power,
    pattern,
    initial_time = nothing,
    ramp_down = 0.5,
)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    for load in PSY.get_components(PSY.PowerLoad, sys)
        PSY.set_max_active_power!(
            load,
            0.4 * PSY.get_max_active_power(load, u"SU") * u"SU",
        )
    end
    unit = get_component(ThermalStandard, sys, "Brighton")
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    PSY.set_time_limits!(unit, nothing)
    pmin = PSY.get_active_power_limits(unit, u"SU").min
    PSY.set_ramp_limits!(
        unit,
        (up = 100.0 * u"SU/minute", down = ramp_down * pmin / 60 * u"SU/minute"),
    )
    PSY.set_active_power!(unit, initial_power(pmin) * u"SU")
    outage = PSY.PlannedOutage(; outage_schedule = "maint")
    PSY.add_supplemental_attribute!(sys, unit, outage)
    data = SortedDict{Dates.DateTime, Vector{Float64}}(
        t0 => [Float64(pattern(t0, h)) for h in 1:24] for
        t0 in PSY.get_forecast_initial_times(sys)
    )
    PSY.add_time_series!(
        sys,
        outage,
        PSY.Deterministic(; name = "maint", data = data, resolution = Hour(1)),
    )
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, formulation)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    kwargs = isnothing(initial_time) ? (;) : (; initial_time = initial_time)
    model = DecisionModel(
        template,
        sys;
        optimizer = HiGHS_optimizer,
        initialize_model = false,
        kwargs...,
    )
    @test build!(
        model;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.AboveMaxLevel,
    ) == ModelBuildStatus.BUILT
    return solve!(model; console_level = Logging.AboveMaxLevel)
end

const _SECOND_WINDOW = DateTime("2024-01-02T00:00:00")

# In the first window the schedule has no value before the start, so the initial power decides
# whether the unit was in service: from zero there is no drop to ramp down, from the minimum
# there is. The compact formulation agrees with the standard one in both cases.
@testset "A must-run unit out at the first step of the first window, initial power $(label)" for (
    label,
    initial_power,
    feasible,
) in (
    ("zero", _ -> 0.0, true),
    ("at the minimum", pmin -> pmin, false),
)
    expected =
        feasible ? IOM.RunStatus.SUCCESSFULLY_FINALIZED : IOM.RunStatus.FAILED
    for formulation in (ThermalStandardUnitCommitment, ThermalCompactUnitCommitment)
        @test _slow_must_run_status(
            formulation;
            initial_power = initial_power,
            pattern = (_, _) -> 1.0,
        ) == expected
    end
end

# A later window reads the unit's status before its start from the schedule, not from the
# stored initial power, which a simulation does not update between windows.
@testset "A must-run compact unit in a window starting mid-outage follows the schedule" begin
    # Out through the previous window and this one: no drop at the first step, even with the
    # stored initial power still at the minimum. The standard formulation, given the initial
    # power a simulation would carry over (zero), agrees.
    @test _slow_must_run_status(
        ThermalCompactUnitCommitment;
        initial_power = pmin -> pmin,
        pattern = (_, _) -> 1.0,
        initial_time = _SECOND_WINDOW,
    ) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test _slow_must_run_status(
        ThermalStandardUnitCommitment;
        initial_power = _ -> 0.0,
        pattern = (_, _) -> 1.0,
        initial_time = _SECOND_WINDOW,
    ) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    # In service through the previous window and out through this one: the drop from the
    # minimum at the first step must respect the ramp, even with a stored initial power of
    # zero. The standard formulation, given the minimum as initial power, agrees.
    out_from_second_window = (t0, _) -> t0 >= _SECOND_WINDOW ? 1.0 : 0.0
    @test _slow_must_run_status(
        ThermalCompactUnitCommitment;
        initial_power = _ -> 0.0,
        pattern = out_from_second_window,
        initial_time = _SECOND_WINDOW,
    ) == IOM.RunStatus.FAILED
    @test _slow_must_run_status(
        ThermalStandardUnitCommitment;
        initial_power = pmin -> pmin,
        pattern = out_from_second_window,
        initial_time = _SECOND_WINDOW,
    ) == IOM.RunStatus.FAILED
    # The same window with a ramp-down that covers the drop solves: the failure above is the
    # ramp, not the outage itself.
    @test _slow_must_run_status(
        ThermalCompactUnitCommitment;
        initial_power = _ -> 0.0,
        pattern = out_from_second_window,
        initial_time = _SECOND_WINDOW,
        ramp_down = 2.0,
    ) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

# The on status of a compact dispatch unit is the `OnStatusParameter`. An out step enters its
# level term as a zero status, so the terms touching an out step drop.
@testset "Compact dispatch ramp level term drops at the out steps" begin
    function ramp_rows(out)
        sys, unit = _min_power_system(MIN_POWER_VALUES)
        out && _schedule_outage!(sys, unit, "maint", _maintenance)
        _, container = _built_min_power_container(sys; formulation = ThermalCompactDispatch)
        return _ramp_rows(container, ThermalStandard), unit
    end
    rows, unit = ramp_rows(true)
    ref, _ = ramp_rows(false)
    pmin = PSY.get_max_active_power(unit, u"SU") .* MIN_POWER_VALUES
    dropped = (first(_OUT_STEPS)):(last(_OUT_STEPS) + 1)
    for t in 2:24
        delta = t in dropped ? pmin[t] - pmin[t - 1] : 0.0
        @test JuMP.normalized_rhs(rows.up["Brighton", t]) -
              JuMP.normalized_rhs(ref.up["Brighton", t]) ≈ delta atol = 1e-9
        @test JuMP.normalized_rhs(rows.dn["Brighton", t]) -
              JuMP.normalized_rhs(ref.dn["Brighton", t]) ≈ -delta atol = 1e-9
    end
end

# Rises and drops of the minimum. Step 1 has the static minimum 0.5.
const DISPATCH_VALUES = vcat(0.5, 0.6, 0.6, 0.5, fill(0.5, 20))

@testset "Compact dispatch ramp level term: no feedforward shifts the right side" begin
    sys, unit = _min_power_system(DISPATCH_VALUES)
    _, profiled = _built_min_power_container(sys; formulation = ThermalCompactDispatch)
    sys2, _ = _min_power_system(fill(0.5, 24))
    _, ref_container =
        _built_min_power_container(sys2; formulation = ThermalCompactDispatch)
    pmax = PSY.get_max_active_power(unit, u"SU")
    prof = _ramp_rows(profiled, ThermalStandard)
    ref = _ramp_rows(ref_container, ThermalStandard)
    @test "Brighton" in axes(prof.up, 1)
    for t in 2:24
        delta = pmax * (DISPATCH_VALUES[t] - DISPATCH_VALUES[t - 1])
        @test JuMP.normalized_rhs(prof.up["Brighton", t]) -
              JuMP.normalized_rhs(ref.up["Brighton", t]) ≈ -delta
        @test JuMP.normalized_rhs(prof.dn["Brighton", t]) -
              JuMP.normalized_rhs(ref.dn["Brighton", t]) ≈ delta
    end
end

const LEVEL_VALUES = vcat(0.5, 0.6, 0.7, 0.5, 0.6, 0.4, 0.5, fill(0.5, 17))

# The compact dispatch rows have a term `Pmin_t - Pmax` on the status s_t in the up row, from
# the start allowance. The term of the level change is what the pass adds on top of it. With
# the statuses `values = (s_t, s_{t-1})` written before the build, every status term sits on
# the right-hand side.
function _level_term(row, ref_row, base_shift, values)
    rhs = JuMP.normalized_rhs(ref_row) - JuMP.normalized_rhs(row)
    return rhs - base_shift * values[1]
end

_relaxes(::JuMP.MOI.LessThan, term, exact) = term <= exact + 1e-9
_relaxes(::JuMP.MOI.GreaterThan, term, exact) = term >= exact - 1e-9
_row_set(row) = JuMP.constraint_object(row).set

function _level_terms(prof, ref, pmax, t, values)
    base_shift = pmax * (LEVEL_VALUES[t] - 0.5)
    up = _level_term(prof.up["Brighton", t], ref.up["Brighton", t], base_shift, values)
    dn = _level_term(prof.dn["Brighton", t], ref.dn["Brighton", t], 0.0, values)
    return up, dn
end

function _check_level_term(prof, ref, pmax, t, values)
    delta = pmax * (LEVEL_VALUES[t] - LEVEL_VALUES[t - 1])
    exact = delta * values[1] * values[2]
    up, dn = _level_terms(prof, ref, pmax, t, values)
    @test _relaxes(_row_set(prof.up["Brighton", t]), up, exact)
    @test _relaxes(_row_set(prof.dn["Brighton", t]), dn, -exact)
    if isone(values[1] * values[2])
        @test up ≈ exact
        @test dn ≈ -exact
    end
    return
end

# The profiled and reference models rebuilt with the same status pattern.
function _level_rows(profiled, reference, pattern)
    prof = _ramp_rows(
        _rebuild_with_on_status!(profiled..., ThermalStandard, "Brighton", pattern),
        ThermalStandard,
    )
    ref = _ramp_rows(
        _rebuild_with_on_status!(reference..., ThermalStandard, "Brighton", pattern),
        ThermalStandard,
    )
    return prof, ref
end

@testset "Compact dispatch ramp level term: affine in the status parameters" begin
    unit, prof_model, prof_device = _compact_dispatch_ff_model(LEVEL_VALUES)
    _, ref_model, ref_device = _compact_dispatch_ff_model(fill(0.5, 24))
    profiled = (prof_model, prof_device)
    reference = (ref_model, ref_device)
    pmax = PSY.get_max_active_power(unit, u"SU")
    steps = [t for t in 2:24 if !iszero(LEVEL_VALUES[t] - LEVEL_VALUES[t - 1])]
    # Together the four patterns give every pair (s_t, s_{t-1}) at every step.
    patterns = (
        ones(24),
        zeros(24),
        [isodd(t) ? 1.0 : 0.0 for t in 1:24],
        [iseven(t) ? 1.0 : 0.0 for t in 1:24],
    )
    dn_terms = Dict{Tuple{Int, Float64}, Float64}()
    for pattern in patterns
        prof, ref = _level_rows(profiled, reference, pattern)
        @test "Brighton" in axes(prof.up, 1)
        for t in steps
            values = (pattern[t], pattern[t - 1])
            _check_level_term(prof, ref, pmax, t, values)
            if values[1] == values[2]
                dn_terms[(t, values[1])] = last(_level_terms(prof, ref, pmax, t, values))
            end
        end
    end
    # The statuses carry the term, not a constant of the row.
    for t in steps
        @test !(dn_terms[(t, 1.0)] ≈ dn_terms[(t, 0.0)])
    end
end

@testset "Compact dispatch ramp level term: fixed status pattern" begin
    unit, prof_model, prof_device = _compact_dispatch_ff_model(LEVEL_VALUES)
    _, ref_model, ref_device = _compact_dispatch_ff_model(fill(0.5, 24))
    pmax = PSY.get_max_active_power(unit, u"SU")
    # On-on steps 2, 3, 6; shut-downs 4, 7; start-up 5. Each step changes the minimum.
    pattern = vcat(1.0, 1.0, 1.0, 0.0, 1.0, 1.0, 0.0, fill(1.0, 17))
    prof, ref = _level_rows((prof_model, prof_device), (ref_model, ref_device), pattern)
    status = IOM.get_parameter_array(
        IOM.get_optimization_container(prof_model), OnStatusParameter, ThermalStandard)
    @test [status["Brighton", t] for t in 1:24] == pattern
    on_on = Int[]
    for t in 2:24
        iszero(LEVEL_VALUES[t] - LEVEL_VALUES[t - 1]) && continue
        values = (pattern[t], pattern[t - 1])
        isone(values[1] * values[2]) && push!(on_on, t)
        _check_level_term(prof, ref, pmax, t, values)
    end
    @test on_on == [2, 3, 6]
end

_time_series_upper_rows(container) = IOM.get_constraint(
    container,
    IOM.ConstraintKey(ActivePowerVariableTimeSeriesLimitsConstraint, ThermalStandard, "ub"),
)

function _max_only_system()
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    unit = get_component(ThermalStandard, sys, "Brighton")
    add_min_power_series!(sys, unit, ones(24); name = "max_active_power")
    return sys, unit
end

@testset "Compact UC time-series upper row: static minimum multiplies the on-status" begin
    sys, unit = _max_only_system()
    model = _compact_model(sys; names = STATIC_MIN_NAMES)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    pmin = PSY.get_active_power_limits(unit, u"SU").min
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    dp = IOM.get_variable(container, PowerAboveMinimumVariable, ThermalStandard)
    ub = _time_series_upper_rows(container)
    for t in 1:24
        func = JuMP.constraint_object(ub["Brighton", t]).func
        @test JuMP.coefficient(func, on["Brighton", t]) ≈ pmin
        @test JuMP.coefficient(func, dp["Brighton", t]) ≈ 1.0
        @test JuMP.normalized_rhs(ub["Brighton", t]) ≈ pmax
    end
end

@testset "Compact UC time-series upper row: profiled minimum multiplies the on-status" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    model = _compact_model(sys)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    dp = IOM.get_variable(container, PowerAboveMinimumVariable, ThermalStandard)
    ub = _time_series_upper_rows(container)
    for t in 1:24
        func = JuMP.constraint_object(ub["Brighton", t]).func
        @test JuMP.coefficient(func, on["Brighton", t]) ≈ pmax * MIN_POWER_VALUES[t]
        @test JuMP.coefficient(func, dp["Brighton", t]) ≈ 1.0
        @test JuMP.normalized_rhs(ub["Brighton", t]) ≈ pmax
    end
end

@testset "Compact UC must-run time-series upper row: minimum moves to the right side" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    model = _compact_model(sys)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    dp = IOM.get_variable(container, PowerAboveMinimumVariable, ThermalStandard)
    ub = _time_series_upper_rows(container)
    for t in 1:24
        func = JuMP.constraint_object(ub["Brighton", t]).func
        @test JuMP.coefficient(func, dp["Brighton", t]) ≈ 1.0
        @test JuMP.normalized_rhs(ub["Brighton", t]) ≈ pmax - pmax * MIN_POWER_VALUES[t]
    end
end

# Below the smallest value of the run-of-river maximum series (0.1295).
const HYDRO_MIN_VALUES = [0.02 + 0.004 * t for t in 1:24]

const HYDRO_MIN_POWER_NAMES = Dict(
    ActivePowerTimeSeriesParameter => "max_active_power",
    MinActivePowerTimeSeriesParameter => "min_active_power",
)

function _hydro_ror_container(formulation; profiled = true)
    sys = PSB.build_system(PSITestSystems, "c_sys5_hy")
    unit = only(get_components(HydroDispatch, sys))
    profiled && add_min_power_series!(sys, unit, HYDRO_MIN_VALUES)
    template = get_thermal_dispatch_template_network()
    set_device_model!(
        template,
        DeviceModel(HydroDispatch, formulation; time_series_names = HYDRO_MIN_POWER_NAMES),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    return model, IOM.get_optimization_container(model), unit
end

function _hydro_turbine_container(turbine_formulation; profiled = true)
    sys = PSB.build_system(PSITestSystems, "c_sys5_hy_turbine_energy")
    unit = first(get_components(HydroTurbine, sys))
    profiled && add_min_power_series!(sys, unit, HYDRO_MIN_VALUES)
    template = get_thermal_dispatch_template_network()
    set_device_model!(
        template,
        DeviceModel(
            HydroTurbine,
            turbine_formulation;
            time_series_names = HYDRO_MIN_POWER_NAMES,
        ),
    )
    set_device_model!(template, HydroReservoir, HydroEnergyModelReservoir)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    return model, IOM.get_optimization_container(model), unit
end

_hydro_limit_rows(container, ::Type{V}, meta) where {V} = IOM.get_constraint(
    container,
    IOM.ConstraintKey(ActivePowerVariableLimitsConstraint, V, meta),
)

@testset "Hydro run-of-river commitment: lower row coefficient is -Pmax * series" begin
    _, container, unit = _hydro_ror_container(HydroCommitmentRunOfRiver)
    name = PSY.get_name(unit)
    pmax = PSY.get_max_active_power(unit, u"SU")
    rows = _hydro_limit_rows(container, HydroDispatch, "lb")
    on = IOM.get_variable(container, OnVariable, HydroDispatch)
    for t in 1:24
        func = JuMP.constraint_object(rows[name, t]).func
        @test JuMP.coefficient(func, on[name, t]) ≈ -pmax * HYDRO_MIN_VALUES[t]
    end
end

@testset "Hydro run-of-river dispatch: lower row bound is Pmax * series" begin
    _, container, unit = _hydro_ror_container(HydroDispatchRunOfRiver)
    name = PSY.get_name(unit)
    pmax = PSY.get_max_active_power(unit, u"SU")
    rows = _hydro_limit_rows(container, HydroDispatch, "lb")
    for t in 1:24
        @test JuMP.normalized_rhs(rows[name, t]) ≈ pmax * HYDRO_MIN_VALUES[t]
    end
    p = IOM.get_variable(container, ActivePowerVariable, HydroDispatch)
    @test JuMP.lower_bound(p[name, 1]) ≈ pmax * minimum(HYDRO_MIN_VALUES)
end

@testset "Hydro run-of-river dispatch without a series keeps range minimum 0" begin
    _, container, unit = _hydro_ror_container(HydroDispatchRunOfRiver; profiled = false)
    name = PSY.get_name(unit)
    rows = _hydro_limit_rows(container, HydroDispatch, "lb")
    for t in 1:24
        @test iszero(JuMP.normalized_rhs(rows[name, t]))
    end
end

@testset "Hydro turbine energy commitment: lower row coefficient is -Pmax * series" begin
    _, container, unit = _hydro_turbine_container(HydroTurbineEnergyCommitment)
    name = PSY.get_name(unit)
    pmax = PSY.get_max_active_power(unit, u"SU")
    rows = _hydro_limit_rows(container, HydroTurbine, "lb")
    on = IOM.get_variable(container, OnVariable, HydroTurbine)
    for t in 1:24
        func = JuMP.constraint_object(rows[name, t]).func
        @test JuMP.coefficient(func, on[name, t]) ≈ -pmax * HYDRO_MIN_VALUES[t]
    end
end

@testset "Hydro turbine energy dispatch: lower row bound is Pmax * series" begin
    _, container, unit = _hydro_turbine_container(HydroTurbineEnergyDispatch)
    name = PSY.get_name(unit)
    pmax = PSY.get_max_active_power(unit, u"SU")
    rows = _hydro_limit_rows(container, HydroTurbine, "lb")
    for t in 1:24
        @test JuMP.normalized_rhs(rows[name, t]) ≈ pmax * HYDRO_MIN_VALUES[t]
    end
end

@testset "Hydro behavior: a committed unit meets the raised minimum" begin
    values = fill(0.05, 24)
    values[10] = 0.55
    sys = PSB.build_system(PSITestSystems, "c_sys5_hy")
    unit = only(get_components(HydroDispatch, sys))
    add_min_power_series!(sys, unit, values)
    template = get_thermal_dispatch_template_network()
    set_device_model!(
        template,
        DeviceModel(
            HydroDispatch,
            HydroCommitmentRunOfRiver;
            time_series_names = HYDRO_MIN_POWER_NAMES,
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    name = PSY.get_name(unit)
    on = IOM.get_variable(container, OnVariable, HydroDispatch)
    JuMP.fix(on[name, 10], 1.0; force = true)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    res = IOM.OptimizationProblemOutputs(model)
    base = IOM.get_model_base_power(res)
    pmax = PSY.get_max_active_power(unit, u"SU")
    power = read_variable(
        res,
        "ActivePowerVariable__HydroDispatch";
        table_format = TableFormat.WIDE,
    )
    @test power[10, name] / base >= 0.55 * pmax - 1e-6
end

@testset "Hydro validation: a minimum above the maximum series fails the build" begin
    values = fill(0.05, 24)
    values[10] = 0.9
    sys = PSB.build_system(PSITestSystems, "c_sys5_hy")
    unit = only(get_components(HydroDispatch, sys))
    add_min_power_series!(sys, unit, values)
    template = get_thermal_dispatch_template_network()
    set_device_model!(
        template,
        DeviceModel(
            HydroDispatch,
            HydroDispatchRunOfRiver;
            time_series_names = HYDRO_MIN_POWER_NAMES,
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == ModelBuildStatus.FAILED
    log = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin(
        "MinActivePowerTimeSeriesParameter for $(PSY.get_name(unit)) at step 10",
        log,
    )
end

const PUMP_GEN_MIN_VALUES = [0.05 + 0.002 * t for t in 1:24]
const PUMP_IN_MIN_VALUES = [0.1 + 0.003 * t for t in 1:24]

const PUMP_MIN_POWER_NAMES = Dict(
    MinActivePowerTimeSeriesParameter => "min_active_power",
    MinActivePowerInTimeSeriesParameter => "min_active_power_pump",
)

function _add_pump_min_series!(sys, pump, values::Vector{Float64}, name::String)
    start = Dates.DateTime("2024-01-01T00:00:00")
    stamps = collect(start:Dates.Hour(1):(start + Dates.Hour(47)))
    PSY.add_time_series!(
        sys,
        pump,
        PSY.SingleTimeSeries(;
            name = name,
            data = TimeArray(stamps, repeat(values, 2)),
        ),
    )
    return
end

function _pump_system(; profiled = true)
    sys = PSB.build_system(
        PSITestSystems,
        "c_sys5_hydro_pump_energy";
        add_single_time_series = true,
    )
    pump = only(get_components(HydroPumpTurbine, sys))
    if profiled
        _add_pump_min_series!(sys, pump, PUMP_GEN_MIN_VALUES, "min_active_power")
        _add_pump_min_series!(sys, pump, PUMP_IN_MIN_VALUES, "min_active_power_pump")
    end
    transform_single_time_series!(sys, Hour(24), Hour(24))
    return sys, pump
end

function _pump_container(formulation; reservation, profiled = true)
    sys, pump = _pump_system(; profiled = profiled)
    template = get_thermal_dispatch_template_network()
    set_device_model!(
        template,
        DeviceModel(
            HydroPumpTurbine,
            formulation;
            time_series_names = PUMP_MIN_POWER_NAMES,
            attributes = Dict{String, Any}("reservation" => reservation),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    return model, IOM.get_optimization_container(model), pump
end

_pump_rows(container, ::Type{T}, meta) where {T} =
    IOM.get_constraint(container, IOM.ConstraintKey(T, HydroPumpTurbine, meta))

@testset "Pump dispatch without reservation: lower rows use both series" begin
    _, container, pump = _pump_container(HydroPumpEnergyDispatch; reservation = false)
    name = PSY.get_name(pump)
    gen_max = PSY.get_max_active_power(pump, u"SU")
    in_max = PSY.get_active_power_limits_pump(pump, u"SU").max
    gen_rows = _pump_rows(container, ActivePowerVariableLimitsConstraint, "lb")
    in_rows = _pump_rows(container, InputActivePowerVariableLimitsConstraint, "lb")
    for t in 1:24
        @test JuMP.normalized_rhs(gen_rows[name, t]) ≈ gen_max * PUMP_GEN_MIN_VALUES[t]
        @test JuMP.normalized_rhs(in_rows[name, t]) ≈ in_max * PUMP_IN_MIN_VALUES[t]
    end
end

@testset "Pump dispatch with reservation: lower rows use both series" begin
    _, container, pump = _pump_container(HydroPumpEnergyDispatch; reservation = true)
    name = PSY.get_name(pump)
    gen_max = PSY.get_max_active_power(pump, u"SU")
    in_max = PSY.get_active_power_limits_pump(pump, u"SU").max
    reservation = IOM.get_variable(container, ReservationVariable, HydroPumpTurbine)
    gen_rows = _pump_rows(container, ActivePowerVariableLimitsConstraint, "lb")
    in_rows = _pump_rows(container, InputActivePowerVariableLimitsConstraint, "lb")
    for t in 1:24
        gen = JuMP.constraint_object(gen_rows[name, t]).func
        inp = JuMP.constraint_object(in_rows[name, t]).func
        @test JuMP.coefficient(gen, reservation[name, t]) ≈
              -gen_max * PUMP_GEN_MIN_VALUES[t]
        @test JuMP.coefficient(inp, reservation[name, t]) ≈
              in_max * PUMP_IN_MIN_VALUES[t]
    end
end

@testset "Pump commitment without reservation: lower rows use both series" begin
    _, container, pump = _pump_container(HydroPumpEnergyCommitment; reservation = false)
    name = PSY.get_name(pump)
    gen_max = PSY.get_max_active_power(pump, u"SU")
    in_max = PSY.get_active_power_limits_pump(pump, u"SU").max
    on = IOM.get_variable(container, OnVariable, HydroPumpTurbine)
    gen_rows = _pump_rows(container, ActivePowerVariableLimitsConstraint, "lb")
    in_rows = _pump_rows(container, InputActivePowerVariableLimitsConstraint, "lb")
    for t in 1:24
        gen = JuMP.constraint_object(gen_rows[name, t]).func
        inp = JuMP.constraint_object(in_rows[name, t]).func
        @test JuMP.coefficient(gen, on[name, t]) ≈ -gen_max * PUMP_GEN_MIN_VALUES[t]
        @test JuMP.coefficient(inp, on[name, t]) ≈ -in_max * PUMP_IN_MIN_VALUES[t]
    end
end

@testset "Pump commitment with reservation: lower rows use both series" begin
    _, container, pump = _pump_container(HydroPumpEnergyCommitment; reservation = true)
    name = PSY.get_name(pump)
    gen_max = PSY.get_max_active_power(pump, u"SU")
    in_max = PSY.get_active_power_limits_pump(pump, u"SU").max
    on = IOM.get_variable(container, OnVariable, HydroPumpTurbine)
    reservation = IOM.get_variable(container, ReservationVariable, HydroPumpTurbine)
    gen_rows = _pump_rows(container, ActivePowerVariableLimitsConstraint, "lb")
    in_rows = _pump_rows(container, InputActivePowerVariableLimitsConstraint, "lb")
    for t in 1:24
        gen = JuMP.constraint_object(gen_rows[name, t]).func
        inp = JuMP.constraint_object(in_rows[name, t]).func
        @test JuMP.coefficient(gen, reservation[name, t]) ≈
              -gen_max * PUMP_GEN_MIN_VALUES[t]
        @test JuMP.coefficient(inp, on[name, t]) ≈ -in_max * PUMP_IN_MIN_VALUES[t]
        @test JuMP.coefficient(inp, reservation[name, t]) ≈
              in_max * PUMP_IN_MIN_VALUES[t]
    end
end

@testset "Pump without series keeps the static rows" begin
    _, container, pump = _pump_container(
        HydroPumpEnergyCommitment;
        reservation = true,
        profiled = false,
    )
    name = PSY.get_name(pump)
    in_min = PSY.get_active_power_limits_pump(pump, u"SU").min
    on = IOM.get_variable(container, OnVariable, HydroPumpTurbine)
    in_rows = _pump_rows(container, InputActivePowerVariableLimitsConstraint, "lb")
    for t in 1:24
        inp = JuMP.constraint_object(in_rows[name, t]).func
        @test JuMP.coefficient(inp, on[name, t]) ≈ -in_min
    end
end

function _pump_feedforward_container(; profiled)
    sys, pump = _pump_system(; profiled = profiled)
    ff = SemiContinuousFeedforward(;
        component_type = HydroPumpTurbine,
        source = OnVariable,
        affected_values = [ActivePowerVariable],
    )
    device_model = DeviceModel(
        HydroPumpTurbine,
        HydroPumpEnergyCommitment;
        time_series_names = PUMP_MIN_POWER_NAMES,
        attributes = Dict{String, Any}("reservation" => false),
    )
    attach_feedforward!(device_model, ff)
    model = DecisionModel(MockOperationProblem, CopperPlateNetworkModel, sys)
    # A profiled pump carries a minimum power series, so it rebuilds instead of holding its
    # statuses as JuMP parameters.
    mock_construct_device!(model, device_model; built_for_recurrent_solves = !profiled)
    return IOM.get_optimization_container(model), pump, model, device_model
end

@testset "Pump with feedforward: lower expression coefficient is -Pmax * series" begin
    _, pump, model, device_model = _pump_feedforward_container(; profiled = true)
    name = PSY.get_name(pump)
    pmax = PSY.get_max_active_power(pump, u"SU")
    function constants(pattern)
        container =
            _rebuild_with_on_status!(model, device_model, HydroPumpTurbine, name, pattern)
        expr = IOM.get_expression(container, ActivePowerRangeExpressionLB, HydroPumpTurbine)
        return [JuMP.constant(expr[name, t]) for t in 1:24]
    end
    on = constants(ones(24))
    off = constants(zeros(24))
    for t in 1:24
        @test on[t] - off[t] ≈ -pmax * PUMP_GEN_MIN_VALUES[t]
    end
end

@testset "Pump with feedforward without a series keeps the static minimum" begin
    container, pump, _, _ = _pump_feedforward_container(; profiled = false)
    name = PSY.get_name(pump)
    pmin = PSY.get_active_power_limits(pump, u"SU").min
    param = IOM.get_parameter_array(container, OnStatusParameter, HydroPumpTurbine)
    expr = IOM.get_expression(container, ActivePowerRangeExpressionLB, HydroPumpTurbine)
    for t in 1:24
        @test JuMP.coefficient(expr[name, t], param[name, t]) ≈ -pmin
    end
end

function _multi_start_must_run_container(; profiled)
    sys = PSB.build_system(PSITestSystems, "c_sys5_pglib")
    unit = get_component(ThermalMultiStart, sys, "115_STEAM_1")
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    profiled && add_min_power_series!(sys, unit, MIN_POWER_VALUES)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, ThermalStandard, ThermalStandardDispatch)
    set_device_model!(
        template,
        DeviceModel(
            ThermalMultiStart,
            ThermalMultiStartUnitCommitment;
            time_series_names = Dict(
                MinActivePowerTimeSeriesParameter => "min_active_power",
            ),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    return unit, IOM.get_optimization_container(model)
end

@testset "Multi-start must-run ramp level term: the right side shifts by the Pmin change" begin
    unit, profiled = _multi_start_must_run_container(; profiled = true)
    _, static = _multi_start_must_run_container(; profiled = false)
    pmax = PSY.get_max_active_power(unit, u"SU")
    prof = _ramp_rows(profiled, ThermalMultiStart)
    ref = _ramp_rows(static, ThermalMultiStart)
    name = "115_STEAM_1"
    @test name in axes(prof.up, 1)
    for t in 2:24
        delta = pmax * (MIN_POWER_VALUES[t] - MIN_POWER_VALUES[t - 1])
        iszero(delta) && continue
        @test JuMP.normalized_rhs(prof.up[name, t]) -
              JuMP.normalized_rhs(ref.up[name, t]) ≈ -delta
        @test JuMP.normalized_rhs(prof.dn[name, t]) -
              JuMP.normalized_rhs(ref.dn[name, t]) ≈ delta
    end
end

@testset "Hydro ReservePowerConstraint uses Pmin_t" begin
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5_hy"))
    hydro = only(get_components(HydroDispatch, sys))
    thermal = first(get_components(ThermalStandard, sys))
    PSY.set_ramp_limits!(hydro, (up = 0.01 * u"SU/minute", down = 0.01 * u"SU/minute"))
    add_min_power_series!(sys, hydro, HYDRO_MIN_VALUES)
    service = OfflineReserve(;
        name = "NSPIN", available = true, time_frame = 30.0, requirement = 0.1,
    )
    add_service!(sys, service, PSY.Device[hydro, thermal])
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(
        template,
        DeviceModel(
            HydroDispatch,
            HydroCommitmentRunOfRiver;
            time_series_names = HYDRO_MIN_POWER_NAMES,
        ),
    )
    set_service_model!(template, ServiceModel(OfflineReserve, NonSpinningReserve))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)

    function limit_at(rows, unit, on, t, pmin)
        name = PSY.get_name(unit)
        startup = POM._nonspin_startup_time(unit)
        window = PSY.get_time_frame(service) - startup
        expected = POM._nonspin_reserve_limit(
            POM._get_ramp_limits(unit),
            (min = pmin, max = PSY.get_active_power_limits(unit, u"SU").max),
            window,
        )
        c = rows[("NSPIN", name, t)]
        return JuMP.normalized_coefficient(c, on[name, t]), expected
    end

    hydro_rows = IOM.get_constraint(
        container,
        POM.ReservePowerConstraint,
        IOM.ComponentPairKey{HydroDispatch, OfflineReserve},
    )
    hydro_on = IOM.get_variable(container, OnVariable, HydroDispatch)
    pmax = PSY.get_max_active_power(hydro, u"SU")
    @test PSY.get_time_frame(service) > POM._nonspin_startup_time(hydro)
    for t in 1:24
        actual, expected =
            limit_at(hydro_rows, hydro, hydro_on, t, pmax * HYDRO_MIN_VALUES[t])
        @test actual ≈ expected
        @test actual > PSY.get_active_power_limits(hydro, u"SU").min
    end

    thermal_rows = IOM.get_constraint(
        container,
        POM.ReservePowerConstraint,
        IOM.ComponentPairKey{ThermalStandard, OfflineReserve},
    )
    thermal_on = IOM.get_variable(container, OnVariable, ThermalStandard)
    static_min = PSY.get_active_power_limits(thermal, u"SU").min
    for t in 1:24
        actual, expected = limit_at(thermal_rows, thermal, thermal_on, t, static_min)
        @test actual ≈ expected
    end
end

function _power_of(model, ::Type{V}, name) where {V}
    res = IOM.OptimizationProblemOutputs(model)
    power = read_variable(
        res,
        "ActivePowerVariable__$(nameof(V))";
        table_format = TableFormat.WIDE,
    )
    return power[!, name]
end

# Ramp and minimum up and down time rows stay in the model, so the outage is feasible only
# when every unit can cover its whole range in one step and the out unit has no minimum
# times.
function _allow_outage_transitions!(sys, unit)
    for g in PSY.get_components(PSY.ThermalStandard, sys)
        ramp = PSY.get_active_power_limits(g, u"SU").max
        PSY.set_ramp_limits!(g, (up = ramp * u"SU/minute", down = ramp * u"SU/minute"))
    end
    PSY.set_time_limits!(unit, nothing)
    return
end

@testset "A unit with minimum and maximum series scheduled out builds and is off under $(formulation)" for formulation in
                                                                                                           (
    ThermalStandardUnitCommitment,
    ThermalBasicUnitCommitment,
    ThermalStandardDispatch,
)
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    _allow_outage_transitions!(sys, unit)
    _schedule_outage!(sys, unit, "maint", _maintenance)
    model, container = _built_min_power_container(sys; formulation = formulation)
    pmax = PSY.get_max_active_power(unit, u"SU")
    rows = _limit_rows(container, "lb")
    for t in setdiff(1:24, _OUT_STEPS)
        func = JuMP.constraint_object(rows["Brighton", t]).func
        if formulation == ThermalStandardDispatch
            @test JuMP.normalized_rhs(rows["Brighton", t]) ≈ pmax * MIN_POWER_VALUES[t]
        else
            on = IOM.get_variable(container, OnVariable, ThermalStandard)
            @test JuMP.coefficient(func, on["Brighton", t]) ≈ -pmax * MIN_POWER_VALUES[t]
        end
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    power = _power_of(model, ThermalStandard, "Brighton")
    @test all(iszero, power[collect(_OUT_STEPS)])
end

@testset "A must-run compact unit with minimum and maximum series scheduled out is off" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    _allow_outage_transitions!(sys, unit)
    _schedule_outage!(sys, unit, "maint", _maintenance)
    model, container =
        _built_min_power_container(sys; formulation = ThermalCompactUnitCommitment)
    pmax = PSY.get_max_active_power(unit, u"SU")
    ub = _time_series_upper_rows(container)
    for t in 1:24
        expected = t in _OUT_STEPS ? 0.0 : pmax - pmax * MIN_POWER_VALUES[t]
        @test JuMP.normalized_rhs(ub["Brighton", t]) ≈ expected atol = 1e-12
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    output = read_aux_variable(
        IOM.OptimizationProblemOutputs(model),
        "PowerOutput__ThermalStandard";
        table_format = TableFormat.WIDE,
    )[
        !,
        "Brighton",
    ]
    @test all(t -> isapprox(output[t], 0.0; atol = 1e-6), _OUT_STEPS)
end

@testset "Minimum above the maximum series: rejected in service, accepted while out" begin
    for (step, status) in ((7, ModelBuildStatus.FAILED), (4, ModelBuildStatus.BUILT))
        max_values = ones(24)
        max_values[step] = 0.5
        sys, unit = _min_power_system(fill(0.6, 24); max_values)
        _schedule_outage!(sys, unit, "maint", _maintenance)
        model = _min_power_uc_model(sys)
        output_dir = mktempdir(; cleanup = true)
        @test build!(model; output_dir = output_dir) == status
        log = read(joinpath(output_dir, "operation_problem.log"), String)
        @test occursin(
            "MinActivePowerTimeSeriesParameter for Brighton at step $step",
            log,
        ) ==
              (status == ModelBuildStatus.FAILED)
    end
end

@testset "A hydro unit with minimum and maximum series scheduled out builds and is off under $(formulation)" for formulation in
                                                                                                                 (
    HydroDispatchRunOfRiver,
    HydroCommitmentRunOfRiver,
)
    sys = PSB.build_system(PSITestSystems, "c_sys5_hy")
    unit = only(get_components(HydroDispatch, sys))
    add_min_power_series!(sys, unit, HYDRO_MIN_VALUES)
    _schedule_outage!(sys, unit, "maint", _maintenance)
    template = get_thermal_dispatch_template_network()
    set_device_model!(
        template,
        DeviceModel(HydroDispatch, formulation; time_series_names = HYDRO_MIN_POWER_NAMES),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    power = _power_of(model, HydroDispatch, PSY.get_name(unit))
    @test all(iszero, power[collect(_OUT_STEPS)])
end

const _IN_SERVICE_STEPS = setdiff(1:24, _OUT_STEPS)

@testset "Compact linear cost: an out unit pays no minimum power cost under $(formulation), must-run $(must_run)" for (
    formulation,
    must_run,
) in (
    (ThermalCompactUnitCommitment, true),
    (ThermalCompactDispatch, false),
)
    slope = 17.0
    objective_constant(s) =
        let (sys, unit) = _linear_cost_system(
                MIN_POWER_VALUES;
                slope = s,
                constant = 3.0,
                must_run = must_run,
            )
            _allow_outage_transitions!(sys, unit)
            _schedule_outage!(sys, unit, "maint", _maintenance)
            container, obj = _objective_of(sys; formulation = formulation)
            (JuMP.constant(obj), IOM.get_model_base_power(container), unit)
        end
    constant0, _, _ = objective_constant(0.0)
    constant1, base, unit = objective_constant(slope)
    pmax = PSY.get_max_active_power(unit, u"SU")
    expected = slope * base * pmax * sum(MIN_POWER_VALUES[_IN_SERVICE_STEPS])
    @test constant1 - constant0 ≈ expected
end

@testset "Compact fuel term: an out must-run unit consumes no fuel at its minimum" begin
    sys = PSB.build_system(PSITestSystems, "c_linear_fuel_test")
    unit = get_component(ThermalStandard, sys, "Test Unit")
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    values = MIN_POWER_VALUES[1:5]
    add_min_power_series!(sys, unit, values)
    _schedule_outage!(sys, unit, "maint", _maintenance)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(
        template,
        DeviceModel(
            ThermalStandard,
            ThermalCompactUnitCommitment;
            time_series_names = Dict(
                MinActivePowerTimeSeriesParameter => "min_active_power",
            ),
        ),
    )
    # The unit serves the whole load, so only the build is checked: with it out the load
    # cannot be met.
    model = DecisionModel(
        template,
        sys;
        optimizer = HiGHS_optimizer,
        initialize_model = false,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    dp = IOM.get_variable(container, PowerAboveMinimumVariable, ThermalStandard)
    fuel = IOM.get_expression(container, FuelConsumptionExpression, ThermalStandard)
    for t in 1:5
        coef_dp = JuMP.coefficient(fuel["Test Unit", t], dp["Test Unit", t])
        @test !iszero(coef_dp)
        expected = t in _OUT_STEPS ? 0.0 : pmax * values[t]
        @test JuMP.constant(fuel["Test Unit", t]) / coef_dp ≈ expected atol = 1e-12
    end
end

@testset "An out must-run unit books no fixed cost at its out steps" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    cost = PSY.get_operation_cost(unit)
    PSY.set_operation_cost!(
        unit,
        PSY.ThermalGenerationCost(;
            variable_operation_cost = PSY.get_variable_operation_cost(cost),
            fixed = 5.0,
            start_up = PSY.get_start_up(cost),
            shut_down = PSY.get_shut_down(cost),
        ),
    )
    _schedule_outage!(sys, unit, "maint", _maintenance)
    _, container = _built_min_power_container(sys; formulation = ThermalBasicUnitCommitment)
    costs = IOM.get_expression(container, FixedCostExpression, ThermalStandard)
    for t in 1:24
        @test iszero(JuMP.constant(costs["Brighton", t])) == (t in _OUT_STEPS)
    end
end
