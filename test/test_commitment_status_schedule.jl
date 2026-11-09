# Commitment status schedule: StatusScheduleTimeSeriesParameter and CommitmentStatusConstraint.

const CM = PSY.CommitmentModes

# Adds a "commitment_status" Deterministic to `d`, one vector of modes per forecast window.
function _add_status_schedule!(sys, d, modes_by_window::Vector{Vector{CM.Value}})
    initial_times = collect(PSY.get_forecast_initial_times(sys))
    data = SortedDict(
        it => Float64.(Int.(modes)) for (it, modes) in zip(initial_times, modes_by_window)
    )
    PSY.add_time_series!(sys, d, Deterministic("commitment_status", data, Hour(1)))
    return
end

# All COMMITTED (free) except `mode` at `steps`.
function _schedule(mode::CM.Value, steps)
    modes = fill(CM.COMMITTED, 24)
    modes[steps] .= mode
    return modes
end

function _status_uc_model(
    sys;
    formulation = ThermalStandardUnitCommitment,
    device_type = ThermalStandard,
    recurrent = false,
    initial_time = nothing,
    time_series_names = nothing,
    other_models = (),
)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    for other in other_models
        set_device_model!(template, other)
    end
    device_model = if isnothing(time_series_names)
        DeviceModel(device_type, formulation)
    else
        DeviceModel(device_type, formulation; time_series_names = time_series_names)
    end
    set_device_model!(template, device_model)
    kwargs = if isnothing(initial_time)
        (;)
    else
        (; initial_time = initial_time)
    end
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, kwargs...)
    IOM.get_optimization_container(model).built_for_recurrent_solves = recurrent
    return model
end

function _build_status_model(model)
    output_dir = mktempdir(; cleanup = true)
    status = build!(model; console_level = Logging.AboveMaxLevel, output_dir = output_dir)
    return status, output_dir
end

_on_values(model, T, name) =
    round.(
        Int,
        JuMP.value.(
            IOM.get_variable(IOM.get_optimization_container(model), OnVariable, T)[name, :],
        ).data,
    )

@testset "CommitmentModes ordering assumed by CommitmentStatusConstraint" begin
    # The rows are affine in the raw value only while UNCOMMITTED is the smallest value and
    # MUST_RUN the largest, with integer spacing.
    values = sort(Int.(collect(instances(CM.Value))))
    @test first(values) == Int(CM.UNCOMMITTED)
    @test last(values) == Int(CM.MUST_RUN)
    @test values == collect(first(values):last(values))
end

@testset "No schedule: no parameter, no constraint, same model" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    model = _status_uc_model(sys)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    @test !IOM.has_container_key(
        container, StatusScheduleTimeSeriesParameter, ThermalStandard)
    @test !IOM.has_container_key(
        container,
        CommitmentStatusConstraint,
        ThermalStandard,
        "ub",
    )
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # Same model as one that does not map the series at all.
    sys_ref = PSB.build_system(PSITestSystems, "c_sys5_uc")
    ref = _status_uc_model(
        sys_ref;
        time_series_names = Dict{Type{<:ParameterType}, String}(
            FuelCostParameter => "fuel_cost",
        ),
    )
    @test first(_build_status_model(ref)) == ModelBuildStatus.BUILT
    @test solve!(ref) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    jm = IOM.get_jump_model(container)
    jm_ref = IOM.get_jump_model(IOM.get_optimization_container(ref))
    @test JuMP.num_constraints(jm; count_variable_in_set_constraints = true) ==
          JuMP.num_constraints(jm_ref; count_variable_in_set_constraints = true)
    @test JuMP.objective_value(jm) ≈ JuMP.objective_value(jm_ref)
end

@testset "Maintenance window forces a shutdown and a paid restart ($formulation)" for formulation in
                                                                                      (
    ThermalBasicUnitCommitment,
    ThermalStandardUnitCommitment,
    ThermalCompactUnitCommitment,
)
    # Brighton is online at the start and committed all day without a schedule.
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    brighton = get_component(ThermalStandard, sys, "Brighton")
    maintenance = 7:12
    _add_status_schedule!(sys, brighton, fill(_schedule(CM.UNCOMMITTED, maintenance), 2))
    model = _status_uc_model(sys; formulation = formulation)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)

    # Mixed system: only the scheduled unit gets the parameter and the rows.
    multiplier = IOM.get_parameter_multiplier_array(
        container, StatusScheduleTimeSeriesParameter, ThermalStandard)
    @test axes(multiplier, 1) == ["Brighton"]
    for meta in ("ub", "lb")
        con = IOM.get_constraint(
            container, CommitmentStatusConstraint, ThermalStandard, meta)
        @test axes(con, 1) == ["Brighton"]
    end
    ub = IOM.get_constraint(container, CommitmentStatusConstraint, ThermalStandard, "ub")
    @test JuMP.normalized_rhs(ub["Brighton", 7]) == 0.0
    @test JuMP.normalized_rhs(ub["Brighton", 6]) == 1.0

    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    on = _on_values(model, ThermalStandard, "Brighton")
    @test all(on[maintenance] .== 0)
    @test on[first(maintenance) - 1] == 1
    @test any(on[(last(maintenance) + 1):end] .== 1)

    jm = IOM.get_jump_model(container)
    start = IOM.get_variable(container, StartVariable, ThermalStandard)
    stop = IOM.get_variable(container, StopVariable, ThermalStandard)
    @test round(Int, JuMP.value(stop["Brighton", first(maintenance)])) == 1
    restart = first(maintenance) - 1 + findfirst(==(1), on[first(maintenance):end])
    @test round(Int, JuMP.value(start["Brighton", restart])) == 1
    # The restart is paid: the start variable carries the startup cost in the objective.
    @test JuMP.coefficient(JuMP.objective_function(jm), start["Brighton", restart]) > 0.0
end

@testset "MUST_RUN period forces the unit on" begin
    # Sundance stays offline all day without a schedule.
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    sundance = get_component(ThermalStandard, sys, "Sundance")
    must_run = 10:12
    _add_status_schedule!(sys, sundance, fill(_schedule(CM.MUST_RUN, must_run), 2))
    model = _status_uc_model(sys)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    lb = IOM.get_constraint(container, CommitmentStatusConstraint, ThermalStandard, "lb")
    @test JuMP.normalized_rhs(lb["Sundance", 10]) == 1.0
    @test JuMP.normalized_rhs(lb["Sundance", 9]) <= 0.0
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test all(_on_values(model, ThermalStandard, "Sundance")[must_run] .== 1)
end

@testset "SELF_SCHEDULED and RELIABILITY leave the unit free" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    sundance = get_component(ThermalStandard, sys, "Sundance")
    modes = fill(CM.SELF_SCHEDULED, 24)
    modes[13:24] .= CM.RELIABILITY
    _add_status_schedule!(sys, sundance, fill(modes, 2))
    model = _status_uc_model(sys)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    # Sundance is not economic, so a free schedule keeps it off.
    @test all(_on_values(model, ThermalStandard, "Sundance") .== 0)
end

@testset "Multi-start unit commitment honors the schedule" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_pglib")
    unit = first(get_components(ThermalMultiStart, sys))
    name = get_name(unit)
    _add_status_schedule!(sys, unit, fill(_schedule(CM.UNCOMMITTED, 1:24), 2))
    model = _status_uc_model(
        sys;
        formulation = ThermalMultiStartUnitCommitment,
        device_type = ThermalMultiStart,
        other_models = (DeviceModel(ThermalStandard, ThermalBasicUnitCommitment),),
    )
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test all(_on_values(model, ThermalMultiStart, name) .== 0)
end

@testset "A static MUST_RUN unit ignores its schedule with a warning" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    sundance = get_component(ThermalStandard, sys, "Sundance")
    PSY.set_commitment_mode!(sundance, CM.MUST_RUN)
    _add_status_schedule!(sys, sundance, fill(_schedule(CM.UNCOMMITTED, 1:3), 2))
    model = _status_uc_model(sys)
    status, output_dir = _build_status_model(model)
    @test status == ModelBuildStatus.BUILT
    log = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("Sundance carries a commitment_status time series", log)
    @test occursin("the series is ignored", log)
    # The only scheduled unit was skipped, so nothing is built for the schedule.
    container = IOM.get_optimization_container(model)
    @test !IOM.has_container_key(
        container, StatusScheduleTimeSeriesParameter, ThermalStandard)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "A value that is not a CommitmentModes value fails the build" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    sundance = get_component(ThermalStandard, sys, "Sundance")
    initial_times = collect(PSY.get_forecast_initial_times(sys))
    values = ones(24)
    values[5] = 2.5
    data = SortedDict(it => values for it in initial_times)
    PSY.add_time_series!(sys, sundance, Deterministic("commitment_status", data, Hour(1)))
    status, output_dir = _build_status_model(_status_uc_model(sys))
    @test status == ModelBuildStatus.FAILED
    log = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("StatusScheduleTimeSeriesParameter for Sundance at step 5", log)
end

@testset "Each window reads its own schedule" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    alta = get_component(ThermalStandard, sys, "Alta")
    windows = [_schedule(CM.UNCOMMITTED, 7:9), _schedule(CM.MUST_RUN, 3:5)]
    _add_status_schedule!(sys, alta, windows)
    for (it, modes) in zip(PSY.get_forecast_initial_times(sys), windows)
        model = _status_uc_model(sys; initial_time = it)
        @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        ub =
            IOM.get_constraint(container, CommitmentStatusConstraint, ThermalStandard, "ub")
        lb =
            IOM.get_constraint(container, CommitmentStatusConstraint, ThermalStandard, "lb")
        for t in 1:24
            forced_off = JuMP.normalized_rhs(ub["Alta", t]) <= 0.0
            forced_on = JuMP.normalized_rhs(lb["Alta", t]) >= 1.0
            @test forced_off == (modes[t] == CM.UNCOMMITTED)
            @test forced_on == (modes[t] == CM.MUST_RUN)
        end
    end
end

@testset "A parameter update moves the forced periods without a rebuild" begin
    # Without a schedule, Alta is on at steps 7:9 and off at steps 3:5.
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    alta = get_component(ThermalStandard, sys, "Alta")
    _add_status_schedule!(
        sys, alta, [_schedule(CM.UNCOMMITTED, 7:9), _schedule(CM.MUST_RUN, 3:5)])
    model = _status_uc_model(sys; recurrent = true)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    jm = IOM.get_jump_model(container)
    refs = get_parameter_column_refs(
        IOM.get_parameter(container, StatusScheduleTimeSeriesParameter, ThermalStandard),
        "Alta",
    )
    @test eltype(refs) == JuMP.VariableRef

    JuMP.optimize!(jm)
    on = _on_values(model, ThermalStandard, "Alta")
    @test all(on[7:9] .== 0)
    @test any(on[3:5] .== 0)

    # Write the second window's values, as a simulation step does, and re-solve.
    second = last(collect(PSY.get_forecast_initial_times(sys)))
    values = PSY.get_time_series_values(
        Deterministic, alta, "commitment_status"; start_time = second)
    for t in 1:24
        IOM.fix_parameter_value(refs[t], values[t])
    end
    JuMP.optimize!(jm)
    @test JuMP.termination_status(jm) == JuMP.MOI.OPTIMAL
    on = _on_values(model, ThermalStandard, "Alta")
    @test all(on[3:5] .== 1)
    @test any(on[7:9] .== 1)
end
