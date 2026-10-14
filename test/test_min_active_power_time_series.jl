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
        @test JuMP.coefficient(func, start["115_STEAM_1", t]) ≈
              max(range_t - startup, 0.0)
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

@testset "Compact dispatch with feedforward: range upper row follows the series" begin
    sys, unit = _min_power_system(MIN_POWER_VALUES)
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
    mock_construct_device!(model, device_model; built_for_recurrent_solves = true)
    container = IOM.get_optimization_container(model)
    pmax = PSY.get_max_active_power(unit, u"SU")
    param = IOM.get_parameter_array(container, OnStatusParameter, ThermalStandard)
    expr = IOM.get_expression(container, ActivePowerRangeExpressionUB, ThermalStandard)
    for t in 1:24
        @test JuMP.coefficient(expr["Brighton", t], param["Brighton", t]) ≈
              -(pmax - pmax * MIN_POWER_VALUES[t])
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
    mock_construct_device!(model, device_model; built_for_recurrent_solves = true)
    container = IOM.get_optimization_container(model)
    return unit, container, container.objective_function.invariant_terms
end

@testset "Compact dispatch with feedforward: the offset term uses the OnStatusParameter" begin
    slope = 17.0
    _, container0, obj0 = _compact_dispatch_feedforward_build(0.0)
    unit, container, obj1 = _compact_dispatch_feedforward_build(slope)
    status0 = IOM.get_parameter_array(container0, OnStatusParameter, ThermalStandard)
    status = IOM.get_parameter_array(container, OnStatusParameter, ThermalStandard)
    pmin = POM.min_active_power_values(container, unit)
    base = IOM.get_model_base_power(container)
    for t in 1:24
        delta =
            JuMP.coefficient(obj1, status["Brighton", t]) -
            JuMP.coefficient(obj0, status0["Brighton", t])
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

function _compact_dispatch_ff_container(values)
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
    mock_construct_device!(model, device_model; built_for_recurrent_solves = true)
    return unit, IOM.get_optimization_container(model)
end

const LEVEL_VALUES = vcat(0.5, 0.6, 0.7, 0.5, 0.6, 0.4, 0.5, fill(0.5, 17))

# The compact dispatch rows have a term `Pmin_t - Pmax` on the status s_t in the up row, from
# the start allowance. The term of the level change is what the pass adds on top of it.
function _level_term(row, ref_row, status, status_ref, t, base_shift, values)
    s_t, s_p = status["Brighton", t], status["Brighton", t - 1]
    r_t, r_p = status_ref["Brighton", t], status_ref["Brighton", t - 1]
    coef_t =
        JuMP.normalized_coefficient(row, s_t) -
        JuMP.normalized_coefficient(ref_row, r_t) - base_shift
    coef_p =
        JuMP.normalized_coefficient(row, s_p) -
        JuMP.normalized_coefficient(ref_row, r_p)
    rhs = JuMP.normalized_rhs(row) - JuMP.normalized_rhs(ref_row)
    return coef_t * values[1] + coef_p * values[2] - rhs
end

_relaxes(::JuMP.MOI.LessThan, term, exact) = term <= exact + 1e-9
_relaxes(::JuMP.MOI.GreaterThan, term, exact) = term >= exact - 1e-9
_row_set(row) = JuMP.constraint_object(row).set

function _check_level_term(prof, ref, status, status_ref, pmax, t, values)
    delta = pmax * (LEVEL_VALUES[t] - LEVEL_VALUES[t - 1])
    base_shift = pmax * (LEVEL_VALUES[t] - 0.5)
    exact = delta * values[1] * values[2]
    up_row, dn_row = prof.up["Brighton", t], prof.dn["Brighton", t]
    up = _level_term(
        up_row, ref.up["Brighton", t], status, status_ref, t, base_shift, values,
    )
    dn = _level_term(dn_row, ref.dn["Brighton", t], status, status_ref, t, 0.0, values)
    @test _relaxes(_row_set(up_row), up, exact)
    @test _relaxes(_row_set(dn_row), dn, -exact)
    if isone(values[1] * values[2])
        @test up ≈ exact
        @test dn ≈ -exact
    end
    return
end

@testset "Compact dispatch ramp level term: affine in the status parameters" begin
    unit, profiled = _compact_dispatch_ff_container(LEVEL_VALUES)
    _, ref_container = _compact_dispatch_ff_container(fill(0.5, 24))
    pmax = PSY.get_max_active_power(unit, u"SU")
    prof = _ramp_rows(profiled, ThermalStandard)
    ref = _ramp_rows(ref_container, ThermalStandard)
    status = IOM.get_parameter_array(profiled, OnStatusParameter, ThermalStandard)
    status_ref = IOM.get_parameter_array(ref_container, OnStatusParameter, ThermalStandard)
    @test "Brighton" in axes(prof.up, 1)
    for t in 2:24
        iszero(LEVEL_VALUES[t] - LEVEL_VALUES[t - 1]) && continue
        # The coefficients on the parameter variables carry the term, not the right side.
        @test !iszero(
            JuMP.normalized_coefficient(prof.dn["Brighton", t], status["Brighton", t]) -
            JuMP.normalized_coefficient(
                ref.dn["Brighton", t],
                status_ref["Brighton", t],
            ) + JuMP.normalized_coefficient(
                prof.dn["Brighton", t],
                status["Brighton", t - 1],
            ),
        )
        for values in Iterators.product((0.0, 1.0), (0.0, 1.0))
            _check_level_term(prof, ref, status, status_ref, pmax, t, values)
        end
    end
end

@testset "Compact dispatch ramp level term: fixed status pattern" begin
    unit, profiled = _compact_dispatch_ff_container(LEVEL_VALUES)
    _, ref_container = _compact_dispatch_ff_container(fill(0.5, 24))
    pmax = PSY.get_max_active_power(unit, u"SU")
    prof = _ramp_rows(profiled, ThermalStandard)
    ref = _ramp_rows(ref_container, ThermalStandard)
    status = IOM.get_parameter_array(profiled, OnStatusParameter, ThermalStandard)
    status_ref = IOM.get_parameter_array(ref_container, OnStatusParameter, ThermalStandard)
    # On-on steps 2, 3, 6; shut-downs 4, 7; start-up 5. Each step changes the minimum.
    pattern = vcat(1.0, 1.0, 1.0, 0.0, 1.0, 1.0, 0.0, fill(1.0, 17))
    for t in 1:24
        JuMP.fix(status["Brighton", t], pattern[t]; force = true)
        JuMP.fix(status_ref["Brighton", t], pattern[t]; force = true)
    end
    fixed = [IOM.jump_fixed_value(status["Brighton", t]) for t in 1:24]
    @test fixed == pattern
    on_on = Int[]
    for t in 2:24
        iszero(LEVEL_VALUES[t] - LEVEL_VALUES[t - 1]) && continue
        values = (fixed[t], fixed[t - 1])
        isone(values[1] * values[2]) && push!(on_on, t)
        _check_level_term(prof, ref, status, status_ref, pmax, t, values)
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
    mock_construct_device!(model, device_model; built_for_recurrent_solves = true)
    return IOM.get_optimization_container(model), pump
end

@testset "Pump with feedforward: lower expression coefficient is -Pmax * series" begin
    container, pump = _pump_feedforward_container(; profiled = true)
    name = PSY.get_name(pump)
    pmax = PSY.get_max_active_power(pump, u"SU")
    param = IOM.get_parameter_array(container, OnStatusParameter, HydroPumpTurbine)
    expr = IOM.get_expression(container, ActivePowerRangeExpressionLB, HydroPumpTurbine)
    for t in 1:24
        @test JuMP.coefficient(expr[name, t], param[name, t]) ≈
              -pmax * PUMP_GEN_MIN_VALUES[t]
    end
end

@testset "Pump with feedforward without a series keeps the static minimum" begin
    container, pump = _pump_feedforward_container(; profiled = false)
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
