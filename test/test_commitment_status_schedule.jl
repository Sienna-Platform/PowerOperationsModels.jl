# Commitment and operational status schedules: CommitmentStatusTimeSeriesParameter,
# OperationalStatusTimeSeriesParameter, CommitmentStatusConstraint and
# OperationalStatusConstraint.

const CM = PSY.CommitmentModes
const OS = PSY.OperationalStates

# Adds a Deterministic named `ts_name` to `d`, one vector of enum values per forecast window.
function _add_enum_series!(sys, d, ts_name, values_by_window)
    initial_times = collect(PSY.get_forecast_initial_times(sys))
    data = SortedDict(
        it => Float64.(Int.(values)) for
        (it, values) in zip(initial_times, values_by_window)
    )
    PSY.add_time_series!(sys, d, Deterministic(ts_name, data, Hour(1)))
    return
end

_add_commitment_status!(sys, d, windows) =
    _add_enum_series!(sys, d, "commitment_status", windows)
_add_status!(sys, d, windows) = _add_enum_series!(sys, d, "status", windows)

# `default` everywhere except `value` at `steps`.
function _schedule(default, value, steps)
    values = fill(default, 24)
    values[steps] .= value
    return values
end

# A planned outage at `steps` as the two series encode it: OFFLINE and UNCOMMITTED there,
# ONLINE and UNCOMMITTED (free) elsewhere.
function _add_outage!(sys, d, steps)
    _add_status!(sys, d, fill(_schedule(OS.ONLINE, OS.OFFLINE, steps), 2))
    _add_commitment_status!(sys, d, fill(fill(CM.UNCOMMITTED, 24), 2))
    return
end

function _status_uc_model(
    sys;
    formulation = ThermalStandardUnitCommitment,
    device_type = ThermalStandard,
    recurrent = false,
    initial_time = nothing,
    time_series_names = nothing,
    other_models = (),
    service_models = (),
    initialize_model = true,
    model_kwargs...,
)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    for other in other_models
        set_device_model!(template, other)
    end
    for service_model in service_models
        set_service_model!(template, service_model)
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
    model = DecisionModel(
        template, sys;
        optimizer = HiGHS_optimizer, store_variable_names = true, initialize_model,
        kwargs..., model_kwargs...)
    IOM.get_optimization_container(model).built_for_recurrent_solves = recurrent
    return model
end

function _build_status_model(model)
    output_dir = mktempdir(; cleanup = true)
    status = build!(model; console_level = Logging.AboveMaxLevel, output_dir = output_dir)
    return status, output_dir
end

function _build_log(model)
    status, output_dir = _build_status_model(model)
    return status, read(joinpath(output_dir, "operation_problem.log"), String)
end

_on_values(model, T, name) =
    round.(
        Int,
        JuMP.value.(
            IOM.get_variable(IOM.get_optimization_container(model), OnVariable, T)[name, :],
        ).data,
    )

_status_meta(::Type{CommitmentStatusConstraint}) = "lb"
_status_meta(::Type{OperationalStatusConstraint}) = "ub"
_status_constraint(model, C) = IOM.get_constraint(
    IOM.get_optimization_container(model), C, ThermalStandard, _status_meta(C))

@testset "Status series values map to bounds" begin
    commitment = CommitmentStatusTimeSeriesParameter()
    status = OperationalStatusTimeSeriesParameter()
    lower = Dict(
        CM.UNCOMMITTED => 0.0, CM.SELF_SCHEDULED => 0.0,
        CM.COMMITTED => 1.0, CM.RELIABILITY => 1.0, CM.MUST_RUN => 1.0,
    )
    upper = Dict(
        OS.OFFLINE => 0.0, OS.ONLINE => 1.0, OS.STARTUP => 1.0, OS.SHUTDOWN => 1.0,
    )
    # Every enum value has a bound, so a new value added to PSY fails here first.
    @test Set(keys(lower)) == Set(instances(CM.Value))
    @test Set(keys(upper)) == Set(instances(OS.Value))
    for (mode, bound) in lower
        @test IOM.unwrap_for_param(commitment, Float64(Int(mode)), ()) == bound
    end
    for (state, bound) in upper
        @test IOM.unwrap_for_param(status, Float64(Int(state)), ()) == bound
    end
    @test_throws IS.ConflictingInputsError IOM.unwrap_for_param(commitment, 2.5, ())
    @test_throws IS.ConflictingInputsError IOM.unwrap_for_param(status, 4.0, ())
end

@testset "No schedule: no parameter, no constraint, same model" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    model = _status_uc_model(sys)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    for (P, C) in (
        (CommitmentStatusTimeSeriesParameter, CommitmentStatusConstraint),
        (OperationalStatusTimeSeriesParameter, OperationalStatusConstraint),
    )
        @test !IOM.has_container_key(container, P, ThermalStandard)
        @test !IOM.has_container_key(container, C, ThermalStandard, _status_meta(C))
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # Same model as one that does not map either series.
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

@testset "OFFLINE forces a shutdown and a paid restart ($formulation)" for formulation in (
    ThermalBasicUnitCommitment,
    ThermalStandardUnitCommitment,
    ThermalCompactUnitCommitment,
)
    # Brighton is online at the start and committed all day without a schedule.
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    brighton = get_component(ThermalStandard, sys, "Brighton")
    outage = 7:12
    _add_outage!(sys, brighton, outage)
    model = _status_uc_model(sys; formulation = formulation)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)

    # Mixed system: only the scheduled unit gets the parameters and the rows.
    for (P, C) in (
        (CommitmentStatusTimeSeriesParameter, CommitmentStatusConstraint),
        (OperationalStatusTimeSeriesParameter, OperationalStatusConstraint),
    )
        @test axes(IOM.get_parameter_multiplier_array(container, P, ThermalStandard), 1) ==
              ["Brighton"]
        @test axes(_status_constraint(model, C), 1) == ["Brighton"]
    end
    ub = _status_constraint(model, OperationalStatusConstraint)
    @test JuMP.normalized_rhs(ub["Brighton", 7]) == 0.0
    @test JuMP.normalized_rhs(ub["Brighton", 6]) == 1.0
    lb = _status_constraint(model, CommitmentStatusConstraint)
    @test all(JuMP.normalized_rhs(lb["Brighton", t]) == 0.0 for t in 1:24)

    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    on = _on_values(model, ThermalStandard, "Brighton")
    @test all(on[outage] .== 0)
    @test on[first(outage) - 1] == 1
    @test any(on[(last(outage) + 1):end] .== 1)

    jm = IOM.get_jump_model(container)
    start = IOM.get_variable(container, StartVariable, ThermalStandard)
    stop = IOM.get_variable(container, StopVariable, ThermalStandard)
    @test round(Int, JuMP.value(stop["Brighton", first(outage)])) == 1
    restart = first(outage) - 1 + findfirst(==(1), on[first(outage):end])
    @test round(Int, JuMP.value(start["Brighton", restart])) == 1
    # The restart is paid: the start variable carries the startup cost in the objective.
    @test JuMP.coefficient(JuMP.objective_function(jm), start["Brighton", restart]) > 0.0
end

@testset "OFFLINE from step 1 stops a unit that starts online" begin
    # Alta starts online at its minimum; its fast ramp lets it stop in one step.
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    alta = get_component(ThermalStandard, sys, "Alta")
    PSY.set_status!(alta, OS.ONLINE)
    PSY.set_active_power!(alta, PSY.get_active_power_limits(alta, u"SU").min * u"SU")
    _add_outage!(sys, alta, 1:3)
    # The initialization solve would see the outage and start Alta off; read its PSY
    # status instead.
    model = _status_uc_model(sys; initialize_model = false)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test all(_on_values(model, ThermalStandard, "Alta")[1:3] .== 0)
    stop = IOM.get_variable(
        IOM.get_optimization_container(model), StopVariable, ThermalStandard)
    @test round(Int, JuMP.value(stop["Alta", 1])) == 1
end

@testset "COMMITTED, RELIABILITY and MUST_RUN force the unit on" begin
    # Sundance stays offline all day without a schedule.
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    sundance = get_component(ThermalStandard, sys, "Sundance")
    modes = fill(CM.UNCOMMITTED, 24)
    modes[10:12] .= CM.MUST_RUN
    modes[14:15] .= CM.RELIABILITY
    modes[17:18] .= CM.COMMITTED
    _add_commitment_status!(sys, sundance, fill(modes, 2))
    _add_status!(sys, sundance, fill(fill(OS.ONLINE, 24), 2))
    model = _status_uc_model(sys)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    lb = _status_constraint(model, CommitmentStatusConstraint)
    forced = vcat(10:12, 14:15, 17:18)
    for t in 1:24
        @test JuMP.normalized_rhs(lb["Sundance", t]) == Float64(t in forced)
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test all(_on_values(model, ThermalStandard, "Sundance")[forced] .== 1)
end

@testset "UNCOMMITTED and SELF_SCHEDULED with ONLINE, STARTUP or SHUTDOWN leave the unit free" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    sundance = get_component(ThermalStandard, sys, "Sundance")
    modes = _schedule(CM.SELF_SCHEDULED, CM.UNCOMMITTED, 13:24)
    states = fill(OS.ONLINE, 24)
    states[5:8] .= OS.STARTUP
    states[15:18] .= OS.SHUTDOWN
    _add_commitment_status!(sys, sundance, fill(modes, 2))
    _add_status!(sys, sundance, fill(states, 2))
    model = _status_uc_model(sys)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    # Sundance is not economic, so a free schedule keeps it off.
    @test all(_on_values(model, ThermalStandard, "Sundance") .== 0)
end

@testset "OFFLINE with $mode fails the build" for mode in
                                                  (
    CM.COMMITTED,
    CM.SELF_SCHEDULED,
    CM.RELIABILITY,
    CM.MUST_RUN,
)
    # The contradiction sits in the second window, which the build window does not read.
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    alta = get_component(ThermalStandard, sys, "Alta")
    _add_status!(sys, alta, fill(_schedule(OS.ONLINE, OS.OFFLINE, 5:6), 2))
    _add_commitment_status!(
        sys, alta, [fill(CM.UNCOMMITTED, 24), _schedule(CM.UNCOMMITTED, mode, 6:6)])
    status, log = _build_log(_status_uc_model(sys))
    @test status == ModelBuildStatus.FAILED
    second = last(collect(PSY.get_forecast_initial_times(sys)))
    @test occursin(
        "Alta, window $second, step 6: status is OFFLINE but commitment_status is $mode",
        log,
    )
end

@testset "A value outside the enum fails the build ($ts_name)" for (ts_name, P) in (
    ("commitment_status", CommitmentStatusTimeSeriesParameter),
    ("status", OperationalStatusTimeSeriesParameter),
)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    sundance = get_component(ThermalStandard, sys, "Sundance")
    initial_times = collect(PSY.get_forecast_initial_times(sys))
    values = ones(24)
    values[5] = 2.5
    data = SortedDict(it => values for it in initial_times)
    PSY.add_time_series!(sys, sundance, Deterministic(ts_name, data, Hour(1)))
    status, log = _build_log(_status_uc_model(sys))
    @test status == ModelBuildStatus.FAILED
    @test occursin("$(nameof(P)) for Sundance, window $(first(initial_times)), step 5", log)
end

@testset "Series of the same names at another resolution are not the model's series" begin
    # Alta also carries half-hourly series of both names. They contradict each other, and
    # they would force Alta off at every step.
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    alta = get_component(ThermalStandard, sys, "Alta")
    outage = 7:12
    _add_outage!(sys, alta, outage)
    initial_times = collect(PSY.get_forecast_initial_times(sys))
    for (ts_name, value) in (("status", OS.OFFLINE), ("commitment_status", CM.RELIABILITY))
        data = SortedDict(it => fill(Float64(Int(value)), 24) for it in initial_times)
        PSY.add_time_series!(sys, alta, Deterministic(ts_name, data, Minute(30)))
    end
    model = _status_uc_model(sys; resolution = Hour(1))
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    ub = _status_constraint(model, OperationalStatusConstraint)
    lb = _status_constraint(model, CommitmentStatusConstraint)
    for t in 1:24
        @test (JuMP.normalized_rhs(ub["Alta", t]) == 0.0) == (t in outage)
        @test JuMP.normalized_rhs(lb["Alta", t]) == 0.0
    end
end

@testset "Static series with different $label fail the build" for (label, shift, len) in (
    ("starts", Hour(2), 24),
    ("lengths", Hour(0), 12),
)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_single_time_series = true)
    alta = get_component(ThermalStandard, sys, "Alta")
    load = first(get_components(PowerLoad, sys))
    t0 = IS.get_initial_timestamp(
        PSY.get_time_series(SingleTimeSeries, load, "max_active_power"),
    )
    states = Float64.(Int.(_schedule(OS.ONLINE, OS.OFFLINE, 20:20)))
    commitment = fill(Float64(Int(CM.UNCOMMITTED)), len)
    PSY.add_time_series!(sys, alta, SingleTimeSeries("status", t0, Hour(1), states))
    PSY.add_time_series!(
        sys, alta, SingleTimeSeries("commitment_status", t0 + shift, Hour(1), commitment))
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    # An explicit initial time skips the system-wide check of the static series grid.
    model = EmulationModel(template, sys; optimizer = HiGHS_optimizer, initial_time = t0)
    status, log = _build_log(model)
    @test status == ModelBuildStatus.FAILED
    @test occursin(
        "Alta: the status window at $t0 with 24 steps has no commitment_status window " *
        "with the same start and length",
        log,
    )
end

@testset "Multi-start unit commitment honors OFFLINE" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_pglib")
    unit = first(get_components(ThermalMultiStart, sys))
    name = get_name(unit)
    _add_outage!(sys, unit, 1:24)
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

@testset "A static MUST_RUN unit ignores both series with a warning" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    sundance = get_component(ThermalStandard, sys, "Sundance")
    PSY.set_commitment_mode!(sundance, CM.MUST_RUN)
    _add_outage!(sys, sundance, 1:3)
    status, log = _build_log(_status_uc_model(sys))
    @test status == ModelBuildStatus.BUILT
    for ts_name in ("commitment_status", "status")
        @test occursin("Sundance carries a $(ts_name) time series", log)
    end
    @test occursin("the series is ignored", log)
end

@testset "Each window reads its own schedule" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    alta = get_component(ThermalStandard, sys, "Alta")
    states = [_schedule(OS.ONLINE, OS.OFFLINE, 7:9), _schedule(OS.ONLINE, OS.OFFLINE, 3:5)]
    modes = [
        _schedule(CM.UNCOMMITTED, CM.RELIABILITY, 12:13),
        _schedule(CM.UNCOMMITTED, CM.MUST_RUN, 20:21),
    ]
    _add_status!(sys, alta, states)
    _add_commitment_status!(sys, alta, modes)
    for (it, window_states, window_modes) in
        zip(PSY.get_forecast_initial_times(sys), states, modes)
        model = _status_uc_model(sys; initial_time = it)
        @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
        ub = _status_constraint(model, OperationalStatusConstraint)
        lb = _status_constraint(model, CommitmentStatusConstraint)
        for t in 1:24
            @test (JuMP.normalized_rhs(ub["Alta", t]) == 0.0) ==
                  (window_states[t] == OS.OFFLINE)
            @test (JuMP.normalized_rhs(lb["Alta", t]) == 1.0) ==
                  (window_modes[t] != CM.UNCOMMITTED)
        end
    end
end

@testset "A parameter update moves the forced periods without a rebuild" begin
    # Without a schedule, Alta is on at steps 7:9 and off at steps 3:5.
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    alta = get_component(ThermalStandard, sys, "Alta")
    _add_status!(
        sys, alta, [_schedule(OS.ONLINE, OS.OFFLINE, 7:9), fill(OS.ONLINE, 24)])
    _add_commitment_status!(
        sys, alta,
        [fill(CM.UNCOMMITTED, 24), _schedule(CM.UNCOMMITTED, CM.RELIABILITY, 3:5)])
    model = _status_uc_model(sys; recurrent = true)
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    jm = IOM.get_jump_model(container)

    JuMP.optimize!(jm)
    on = _on_values(model, ThermalStandard, "Alta")
    @test all(on[7:9] .== 0)
    @test any(on[3:5] .== 0)

    # Write the second window's values through the same hook a simulation step uses.
    second = last(collect(PSY.get_forecast_initial_times(sys)))
    for (P, ts_name) in (
        (CommitmentStatusTimeSeriesParameter, "commitment_status"),
        (OperationalStatusTimeSeriesParameter, "status"),
    )
        refs = get_parameter_column_refs(
            IOM.get_parameter(container, P, ThermalStandard),
            "Alta",
        )
        @test eltype(refs) == JuMP.VariableRef
        values =
            PSY.get_time_series_values(Deterministic, alta, ts_name; start_time = second)
        for t in 1:24
            IOM.fix_parameter_value(refs[t], IOM.unwrap_for_param(P(), values[t], ()))
        end
    end
    JuMP.optimize!(jm)
    @test JuMP.termination_status(jm) == JuMP.MOI.OPTIMAL
    on = _on_values(model, ThermalStandard, "Alta")
    @test all(on[3:5] .== 1)
    @test any(on[7:9] .== 1)
end

# c_sys5_uc on MarketBidCost with an OfflineReserve ORDC ("NSPIN") that every thermal offers
# into. `cheap` units offer at almost no cost, so their offline offer clears when allowed.
function _nspin_system(cheap)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    thermals = collect(get_components(ThermalStandard, sys))
    for g in thermals
        slope = PSY.get_proportional_term(
            PSY.get_value_curve(PSY.get_variable_operation_cost(get_operation_cost(g))),
        )
        PSY.set_operation_cost!(
            g,
            MarketBidCost(;
                minimum_energy_offer = LinearCurve(0.0),
                start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
                shut_down = LinearCurve(0.0),
                incremental_offer_curves = make_market_bid_curve(
                    [0.0, PSY.get_max_active_power(g, u"NU")], [slope], 0.0;
                    power_units = IS.NaturalUnit(),
                ),
            ),
        )
    end
    nspin = OfflineReserve(;
        name = "NSPIN",
        available = true,
        time_frame = 30.0,
        variable = make_market_bid_curve(
            [0.0, 100.0, 200.0], [65.0, 11.0], 0.0; power_units = IS.NaturalUnit()),
    )
    add_service!(sys, nspin, PSY.Device[thermals...])
    initial_times = PSY.get_forecast_initial_times(sys)
    for (i, g) in enumerate(thermals)
        price = PSY.get_name(g) in cheap ? 0.01 : 6.0 + i
        offer = Deterministic(
            "NSPIN",
            Dict(
                it => [IS.PiecewiseStepData([0.0, 80.0], [price]) for _ in 1:24]
                for it in initial_times
            ),
            Hour(1),
        )
        PSY.set_service_bid!(sys, g, nspin, offer, IS.NaturalUnit())
    end
    return sys
end

function _add_max_active_power!(sys, d, values)
    data = SortedDict(it => values for it in PSY.get_forecast_initial_times(sys))
    PSY.add_time_series!(sys, d, Deterministic("max_active_power", data, Hour(1)))
    return
end

@testset "OFFLINE units supply offline NSPIN only up to max_active_power" begin
    # Alta is on outage (no energy, no reserves) and Sundance is off for energy but still
    # offers offline NSPIN in steps 7:12. Both are OFFLINE and UNCOMMITTED there; only
    # Alta also sets max_active_power to 0.
    window = 7:12
    sys = _nspin_system(("Alta", "Sundance"))
    alta = get_component(ThermalStandard, sys, "Alta")
    sundance = get_component(ThermalStandard, sys, "Sundance")
    for d in (alta, sundance)
        _add_outage!(sys, d, window)
    end
    _add_max_active_power!(sys, alta, _schedule(1.0, 0.0, window))
    _add_max_active_power!(sys, sundance, ones(24))
    model = _status_uc_model(
        sys;
        time_series_names = Dict{Type{<:ParameterType}, String}(
            ActivePowerTimeSeriesParameter => "max_active_power",
            CommitmentStatusTimeSeriesParameter => "commitment_status",
            OperationalStatusTimeSeriesParameter => "status",
        ),
        service_models = (ServiceModel(OfflineReserve, StepwiseCostReserve),),
    )
    @test first(_build_status_model(model)) == ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    res = IOM.OptimizationProblemOutputs(model)
    awards = read_variable(
        res, "ActivePowerReserveVariable__ThermalStandard__OfflineReserve";
        table_format = TableFormat.WIDE,
    )
    @test all(_on_values(model, ThermalStandard, "Alta")[window] .== 0)
    @test all(_on_values(model, ThermalStandard, "Sundance")[window] .== 0)
    for t in window
        @test awards[t, "NSPIN__Alta"] ≈ 0.0 atol = 1e-6
        @test awards[t, "NSPIN__Sundance"] > 1.0
    end
end
