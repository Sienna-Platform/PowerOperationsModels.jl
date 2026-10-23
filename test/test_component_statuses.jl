const _T0 = Dates.DateTime("2024-01-01T00:00:00")

function _status_test_system()
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    switch = PSY.DiscreteControlledACBranch(nothing)
    switch.name = "sw"
    switch.arc = PSY.get_arc(line)
    switch.x = 0.05
    switch.available = true
    PSY.add_component!(sys, switch)
    gen = first(PSY.get_components(PSY.ThermalStandard, sys))
    return sys, line, switch, gen
end

function _attach!(sys, component, attribute, name, values)
    PSY.add_supplemental_attribute!(sys, component, attribute)
    stamps = collect(_T0:Dates.Hour(1):(_T0 + Dates.Hour(length(values) - 1)))
    PSY.add_time_series!(
        sys,
        attribute,
        PSY.SingleTimeSeries(; name = name, data = TimeSeries.TimeArray(stamps, values)),
    )
    return
end

_window(n) = POM.StatusWindow(PSY.SingleTimeSeries, _T0, n, Dates.Hour(1), nothing)

@testset "Planned outage on a branch and an injector" begin
    sys, line, _, gen = _status_test_system()
    _attach!(
        sys,
        line,
        PSY.PlannedOutage(; outage_schedule = "l"),
        "l",
        [0.0, 1.0, 1.0, 0.0],
    )
    _attach!(
        sys,
        gen,
        PSY.PlannedOutage(; outage_schedule = "g"),
        "g",
        [0.0, 0.0, 1.0, 0.0],
    )
    branches, injectors = POM.compute_component_statuses(sys, _window(4))
    @test branches[line] == [1.0, 0.0, 0.0, 1.0]
    @test injectors[gen] == [1.0, 1.0, 0.0, 1.0]
end

@testset "Switching schedules combine with OPEN winning, outages override" begin
    sys, _, switch, _ = _status_test_system()
    _attach!(
        sys,
        switch,
        PSY.SwitchingSchedule(; status_schedule = "a"),
        "a",
        [1.0, 1.0, 0.0, 1.0],
    )
    _attach!(
        sys,
        switch,
        PSY.SwitchingSchedule(; status_schedule = "b"),
        "b",
        [1.0, 0.0, 1.0, 1.0],
    )
    _attach!(
        sys,
        switch,
        PSY.PlannedOutage(; outage_schedule = "o"),
        "o",
        [0.0, 0.0, 0.0, 1.0],
    )
    branches, _ =
        @test_logs (:warn, r"conflicting switching schedules at 2 step\(s\)") POM.compute_component_statuses(
            sys,
            _window(4),
        )
    @test branches[switch] == [1.0, 0.0, 0.0, 0.0]
end

@testset "Unavailable components and unscheduled systems produce nothing" begin
    sys, line, _, _ = _status_test_system()
    _attach!(sys, line, PSY.PlannedOutage(; outage_schedule = "l"), "l", [1.0, 1.0])
    PSY.set_available!(line, false)
    branches, injectors = POM.compute_component_statuses(sys, _window(2))
    @test isempty(branches) && isempty(injectors)
    sys2, _, _, _ = _status_test_system()
    branches2, injectors2 = POM.compute_component_statuses(sys2, _window(2))
    @test isempty(branches2) && isempty(injectors2)
end

@testset "Invalid schedule values and missing series error" begin
    sys, line, _, _ = _status_test_system()
    _attach!(sys, line, PSY.PlannedOutage(; outage_schedule = "l"), "l", [0.0, 0.5])
    @test_throws IS.ConflictingInputsError POM.compute_component_statuses(sys, _window(2))
    sys2, line2, _, _ = _status_test_system()
    PSY.add_supplemental_attribute!(
        sys2,
        line2,
        PSY.PlannedOutage(; outage_schedule = "none"),
    )
    @test_throws IS.ConflictingInputsError POM.compute_component_statuses(sys2, _window(2))
end

@testset "A schedule shorter than the window names the series and both ranges" begin
    sys, line, _, _ = _status_test_system()
    outage = PSY.PlannedOutage(; outage_schedule = "short")
    _attach!(sys, line, outage, "short", zeros(3))
    window = POM.StatusWindow(
        PSY.SingleTimeSeries,
        _T0 + Dates.Hour(1),
        4,
        Dates.Hour(1),
        nothing,
    )
    err = try
        POM.compute_component_statuses(sys, window)
        nothing
    catch e
        e
    end
    @test err isa IS.ConflictingInputsError
    message = err.msg
    @test occursin("\"short\"", message)
    @test occursin("PlannedOutage $(IS.get_id(outage))", message)
    @test occursin("Line \"$(PSY.get_name(line))\"", message)
    @test occursin("covers 2024-01-01T00:00:00 to 2024-01-01T02:00:00", message)
    @test occursin("reads 2024-01-01T01:00:00 to 2024-01-01T04:00:00", message)
end

@testset "A schedule starting after the window is reported the same way" begin
    sys, line, _, _ = _status_test_system()
    PSY.add_supplemental_attribute!(
        sys,
        line,
        PSY.PlannedOutage(; outage_schedule = "late"),
    )
    outage = only(PSY.get_supplemental_attributes(PSY.PlannedOutage, line))
    stamps = collect((_T0 + Dates.Hour(2)):Dates.Hour(1):(_T0 + Dates.Hour(5)))
    PSY.add_time_series!(
        sys,
        outage,
        PSY.SingleTimeSeries(;
            name = "late",
            data = TimeSeries.TimeArray(stamps, zeros(4)),
        ),
    )
    err = try
        POM.compute_component_statuses(sys, _window(2))
        nothing
    catch e
        e
    end
    @test err isa IS.ConflictingInputsError
    @test occursin(
        "covers 2024-01-01T02:00:00 to 2024-01-01T05:00:00, but the model reads " *
        "2024-01-01T00:00:00 to 2024-01-01T01:00:00",
        err.msg,
    )
end

# Forecast schedule with windows at hours 0 and 1, each 3 hours long.
function _status_test_system_with_forecast()
    sys, line, _, _ = _status_test_system()
    outage = PSY.PlannedOutage(; outage_schedule = "fc")
    PSY.add_supplemental_attribute!(sys, line, outage)
    data = SortedDict(_T0 => zeros(3), _T0 + Dates.Hour(1) => zeros(3))
    PSY.add_time_series!(
        sys,
        outage,
        PSY.Deterministic(; name = "fc", data = data, resolution = Dates.Hour(1)),
    )
    return sys, line
end

_forecast_window(initial_time, len) =
    POM.StatusWindow(PSY.Deterministic, initial_time, len, Dates.Hour(1), Dates.Hour(1))

function _status_error(sys, window)
    try
        POM.compute_component_statuses(sys, window)
        return nothing
    catch e
        return e
    end
end

@testset "A forecast schedule shorter than the window names the series and both ranges" begin
    sys, line = _status_test_system_with_forecast()
    branches, _ = POM.compute_component_statuses(sys, _forecast_window(_T0, 3))
    @test branches[line] == ones(3)
    for (initial_time, covered) in (
        (_T0, "2024-01-01T00:00:00 to 2024-01-01T02:00:00"),
        (_T0 + Dates.Hour(1), "2024-01-01T01:00:00 to 2024-01-01T03:00:00"),
    )
        err = _status_error(sys, _forecast_window(initial_time, 4))
        @test err isa IS.ConflictingInputsError
        @test occursin("Time series \"fc\" of PlannedOutage", err.msg)
        @test occursin(
            "covers $covered, but the model reads $initial_time to " *
            "$(initial_time + Dates.Hour(3))", err.msg)
    end
end

@testset "A forecast schedule with no window at the model's initial time is reported" begin
    sys, _ = _status_test_system_with_forecast()
    for initial_time in (_T0 - Dates.Hour(1), _T0 + Dates.Hour(2))
        err = _status_error(sys, _forecast_window(initial_time, 1))
        @test err isa IS.ConflictingInputsError
        @test occursin(
            "has windows starting every 1 hour from 2024-01-01T00:00:00 to " *
            "2024-01-01T01:00:00, but the model reads from $initial_time",
            err.msg,
        )
    end
end

@testset "A single-window forecast schedule is read at its initial time only" begin
    sys, line, _, _ = _status_test_system()
    outage = PSY.PlannedOutage(; outage_schedule = "one")
    PSY.add_supplemental_attribute!(sys, line, outage)
    PSY.add_time_series!(
        sys,
        outage,
        PSY.Deterministic(;
            name = "one",
            data = SortedDict(_T0 => [0.0, 1.0, 0.0]),
            resolution = Dates.Hour(1),
        ),
    )
    window(initial_time) = POM.StatusWindow(
        PSY.Deterministic, initial_time, 3, Dates.Hour(1), Dates.Hour(0))
    branches, _ = POM.compute_component_statuses(sys, window(_T0))
    @test branches[line] == [1.0, 0.0, 1.0]
    err = _status_error(sys, window(_T0 + Dates.Hour(1)))
    @test err isa IS.ConflictingInputsError
    @test occursin(
        "has one window, at 2024-01-01T00:00:00, but the model reads from " *
        "2024-01-01T01:00:00",
        err.msg,
    )
end

@testset "Conflict warning counts steps, once per switch" begin
    sys, _, switch, _ = _status_test_system()
    _attach!(sys, switch, PSY.SwitchingSchedule(; status_schedule = "a"), "a", [0.0, 1.0])
    _attach!(sys, switch, PSY.SwitchingSchedule(; status_schedule = "b"), "b", [1.0, 1.0])
    _attach!(sys, switch, PSY.SwitchingSchedule(; status_schedule = "c"), "c", [1.0, 1.0])
    branches, _ =
        @test_logs (:warn, r"conflicting switching schedules at 1 step\(s\)") POM.compute_component_statuses(
            sys,
            _window(2),
        )
    @test branches[switch] == [0.0, 1.0]
    sys2, _, switch2, _ = _status_test_system()
    _attach!(
        sys2,
        switch2,
        PSY.SwitchingSchedule(; status_schedule = "a"),
        "a",
        [0.0, 1.0, 0.0, 1.0],
    )
    _attach!(
        sys2,
        switch2,
        PSY.SwitchingSchedule(; status_schedule = "b"),
        "b",
        [1.0, 0.0, 0.0, 1.0],
    )
    branches2, _ =
        @test_logs (:warn, r"conflicting switching schedules at 2 step\(s\)") POM.compute_component_statuses(
            sys2,
            _window(4),
        )
    @test branches2[switch2] == [0.0, 0.0, 0.0, 1.0]
end

@testset "Conflict warning is logged once per switch across recomputations" begin
    sys, _, switch, _ = _status_test_system()
    _attach!(sys, switch, PSY.SwitchingSchedule(; status_schedule = "a"), "a", [0.0, 1.0])
    _attach!(sys, switch, PSY.SwitchingSchedule(; status_schedule = "b"), "b", [1.0, 1.0])
    @test_logs (:warn, r"conflicting switching schedules") begin
        POM.compute_component_statuses(sys, _window(2))
        POM.compute_component_statuses(sys, _window(2))
    end
end

@testset "A schedule on a bus is ignored without reading its series" begin
    sys, _, _, _ = _status_test_system()
    bus = first(sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number))
    PSY.add_supplemental_attribute!(
        sys,
        bus,
        PSY.PlannedOutage(; outage_schedule = "missing"),
    )
    branches, injectors = @test_logs (:warn, r"ACBus .* carries a schedule") begin
        POM.compute_component_statuses(sys, _window(2))
        POM.compute_component_statuses(sys, _window(2))
    end
    @test isempty(branches) && isempty(injectors)
end

@testset "An open switch with only a planned outage is out at every step" begin
    sys, _, switch, _ = _status_test_system()
    PSY.set_branch_status!(switch, PSY.DiscreteControlledBranchStatus.OPEN)
    _attach!(
        sys,
        switch,
        PSY.PlannedOutage(; outage_schedule = "o"),
        "o",
        [0.0, 1.0, 0.0],
    )
    branches, _ = POM.compute_component_statuses(sys, _window(3))
    @test branches[switch] == [0.0, 0.0, 0.0]

    sys2, _, switch2, _ = _status_test_system()
    PSY.set_branch_status!(switch2, PSY.DiscreteControlledBranchStatus.CLOSED)
    _attach!(
        sys2,
        switch2,
        PSY.PlannedOutage(; outage_schedule = "o"),
        "o",
        [0.0, 1.0, 0.0],
    )
    branches2, _ = POM.compute_component_statuses(sys2, _window(3))
    @test branches2[switch2] == [1.0, 0.0, 1.0]
end

@testset "A window without a resolution reads the series' only resolution" begin
    sys, line, _, _ = _status_test_system()
    _attach!(sys, line, PSY.PlannedOutage(; outage_schedule = "l"), "l", [0.0, 1.0])
    window = POM.StatusWindow(PSY.SingleTimeSeries, _T0, 2, nothing, nothing)
    branches, _ = POM.compute_component_statuses(sys, window)
    @test branches[line] == [1.0, 0.0]
end

function _scheduled_dispatch_model(;
    schedules = true,
    injector_schedule = false,
    network = NetworkModel(PTDFNetworkModel),
    kwargs...,
)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_forecasts = true)
    if schedules
        line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
        outage = PSY.PlannedOutage(; outage_schedule = "maint")
        PSY.add_supplemental_attribute!(sys, line, outage)
        _attach_forecast_schedule!(sys, outage, "maint", h -> h in 3:5 ? 1.0 : 0.0)
    end
    if injector_schedule
        gen = first(
            sort!(collect(PSY.get_components(PSY.ThermalStandard, sys)); by = PSY.get_name),
        )
        outage = PSY.PlannedOutage(; outage_schedule = "gen_maint")
        PSY.add_supplemental_attribute!(sys, gen, outage)
        _attach_forecast_schedule!(sys, outage, "gen_maint", h -> h in 2:3 ? 1.0 : 0.0)
    end
    template = get_thermal_dispatch_template_network(network)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, kwargs...)
    return model, sys
end

@testset "Status parameter containers are Float64 and hold computed values" begin
    model, sys = _scheduled_dispatch_model()
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    key = IOM.ParameterKey(POM.BranchStatusParameter, PSY.Line)
    @test IOM.has_container_key(container, POM.BranchStatusParameter, PSY.Line)
    values = IOM.get_parameter_array(container, key)
    @test eltype(values) == Float64
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    @test collect(values[PSY.get_name(line), :])[3:5] == [0.0, 0.0, 0.0]
    @test collect(values[PSY.get_name(line), :])[1:2] == [1.0, 1.0]
end

@testset "Status parameters are written to the outputs" begin
    model, sys = _scheduled_dispatch_model()
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    outputs = IOM.OptimizationProblemOutputs(model)
    @test "BranchStatusParameter__Line" in IOM.list_parameter_names(outputs)
    statuses = read_parameter(
        outputs,
        "BranchStatusParameter__Line";
        table_format = TableFormat.WIDE,
    )
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    @test names(statuses) == ["DateTime", PSY.get_name(line)]
    @test statuses[!, PSY.get_name(line)] == [1.0, 1.0, 0.0, 0.0, 0.0, ones(19)...]
end

@testset "No schedules: no status containers" begin
    model, _ = _scheduled_dispatch_model(; schedules = false)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    @test !IOM.has_container_key(container, POM.BranchStatusParameter, PSY.Line)
    @test !IOM.get_rebuild_model(IOM.get_settings(model))
end

@testset "A schedule on an unavailable component changes nothing" begin
    model, sys = _scheduled_dispatch_model()
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    PSY.set_available!(line, false)
    IOM.get_optimization_container(model).built_for_recurrent_solves = true
    @test_logs min_level = Logging.Warn POM.validate_template(model)
    @test !IOM.get_rebuild_model(IOM.get_settings(model))
end

@testset "Schedules force a rebuild under recurrent solves" begin
    model, sys = _scheduled_dispatch_model()
    IOM.get_optimization_container(model).built_for_recurrent_solves = true
    @test_logs (:info, r"rebuild_model = true") match_mode = :any POM.validate_template(
        model,
    )
    @test IOM.get_rebuild_model(IOM.get_settings(model))
end

@testset "Rebuild keeps written status values; a fresh build recomputes them" begin
    model, sys = _scheduled_dispatch_model()
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    name = PSY.get_name(line)
    container = IOM.get_optimization_container(model)
    values = IOM.get_parameter_array(
        container,
        IOM.ParameterKey(POM.BranchStatusParameter, PSY.Line),
    )
    @test values[name, 1] == 1.0
    values[name, 1] = 0.0

    IOM.set_rebuild_model!(IOM.get_settings(container), true)
    IOM.reset_optimization_model!(container)
    POM.build_problem!(container, IOM.get_template(model), IOM.get_system(model))
    IOM.set_rebuild_model!(IOM.get_settings(container), false)
    kept = IOM.get_parameter_array(
        container,
        IOM.ParameterKey(POM.BranchStatusParameter, PSY.Line),
    )
    @test kept[name, 1] == 0.0
    @test kept[name, 3] == 0.0

    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    fresh = IOM.get_parameter_array(
        IOM.get_optimization_container(model),
        IOM.ParameterKey(POM.BranchStatusParameter, PSY.Line),
    )
    @test fresh[name, 1] == 1.0
    @test fresh[name, 3] == 0.0
end

@testset "Conflict warning is logged once for each of two systems" begin
    function conflicted_system()
        sys, _, switch, _ = _status_test_system()
        _attach!(
            sys,
            switch,
            PSY.SwitchingSchedule(; status_schedule = "a"),
            "a",
            [0.0, 1.0],
        )
        _attach!(
            sys,
            switch,
            PSY.SwitchingSchedule(; status_schedule = "b"),
            "b",
            [1.0, 1.0],
        )
        return sys
    end
    sys1 = conflicted_system()
    sys2 = conflicted_system()
    @test_logs (:warn, r"conflict") (:warn, r"conflict") begin
        POM.compute_component_statuses(sys1, _window(2))
        POM.compute_component_statuses(sys2, _window(2))
    end
end

@testset "An explicit model resolution reports the same statuses" begin
    function line_statuses(model)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        values = IOM.get_parameter_array(
            IOM.get_optimization_container(model),
            IOM.ParameterKey(POM.BranchStatusParameter, PSY.Line),
        )
        return collect(values.data)
    end
    default_model, _ = _scheduled_dispatch_model()
    explicit_model, _ = _scheduled_dispatch_model(; resolution = Dates.Hour(1))
    @test line_statuses(explicit_model) == line_statuses(default_model)
end

@testset "A rebuild adds the status containers that are missing" begin
    model, _ = _scheduled_dispatch_model(; injector_schedule = true)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    @test IOM.has_container_key(container, POM.InjectorStatusParameter, PSY.ThermalStandard)
    delete!(
        IOM.get_parameters(container),
        IOM.ParameterKey(POM.InjectorStatusParameter, PSY.ThermalStandard),
    )
    @test IOM.has_container_key(container, POM.BranchStatusParameter, PSY.Line)
    @test !IOM.has_container_key(
        container,
        POM.InjectorStatusParameter,
        PSY.ThermalStandard,
    )

    IOM.set_rebuild_model!(IOM.get_settings(container), true)
    IOM.reset_optimization_model!(container)
    POM.build_problem!(container, IOM.get_template(model), IOM.get_system(model))
    @test IOM.has_container_key(container, POM.InjectorStatusParameter, PSY.ThermalStandard)
end

@testset "A planned outage on a thermal unit builds an injector status container" begin
    model, sys = _scheduled_dispatch_model(; schedules = false, injector_schedule = true)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    gen = first(
        sort!(collect(PSY.get_components(PSY.ThermalStandard, sys)); by = PSY.get_name),
    )
    values = IOM.get_parameter_array(
        container,
        IOM.ParameterKey(POM.InjectorStatusParameter, PSY.ThermalStandard),
    )
    row = collect(values[PSY.get_name(gen), :])
    @test row[1] == 1.0
    @test row[2:3] == [0.0, 0.0]
    @test all(==(1.0), row[4:end])
end

function _scheduled_emulation_model(; kwargs...)
    sys = PSB.build_system(PSITestSystems, "c_sys5"; add_single_time_series = true)
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    outage = PSY.PlannedOutage(; outage_schedule = "maint")
    PSY.add_supplemental_attribute!(sys, line, outage)
    resolution = first(PSY.get_time_series_resolutions(sys))
    load = first(PSY.get_components(PSY.PowerLoad, sys))
    load_values =
        PSY.get_time_series_array(PSY.SingleTimeSeries, load, "max_active_power")
    initial_time = first(TimeSeries.timestamp(load_values))
    stamps = collect(range(initial_time; length = length(load_values), step = resolution))
    PSY.add_time_series!(
        sys,
        outage,
        PSY.SingleTimeSeries(;
            name = "maint",
            data = TimeSeries.TimeArray(stamps, [1.0; zeros(length(stamps) - 1)]),
        ),
    )
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    model = EmulationModel(template, sys; optimizer = HiGHS_optimizer, kwargs...)
    return model, sys, line
end

@testset "An emulation model builds with the statuses of its first window" begin
    model, _, line = _scheduled_emulation_model()
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    values = IOM.get_parameter_array(
        IOM.get_optimization_container(model),
        IOM.ParameterKey(POM.BranchStatusParameter, PSY.Line),
    )
    @test values[PSY.get_name(line), 1] == 0.0
end

@testset "A bad schedule on an ignored component warns and does not error" begin
    sys, _, _, _ = _status_test_system()
    bus = first(sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number))
    _attach!(sys, bus, PSY.PlannedOutage(; outage_schedule = "b"), "b", [2.0, 0.0])
    branches, injectors =
        @test_logs (:warn, r"ACBus .* carries a schedule") POM.compute_component_statuses(
            sys,
            _window(2),
        )
    @test isempty(branches) && isempty(injectors)
end

@testset "A system whose only schedule is on a bus does not force a rebuild" begin
    model, sys = _scheduled_dispatch_model(; schedules = false)
    bus = first(sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number))
    PSY.add_supplemental_attribute!(
        sys,
        bus,
        PSY.PlannedOutage(; outage_schedule = "unused"),
    )
    IOM.get_optimization_container(model).built_for_recurrent_solves = true
    POM.validate_template(model)
    @test !IOM.get_rebuild_model(IOM.get_settings(model))
end

@testset "A deterministic schedule is read from each forecast window" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_forecasts = true)
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    outage = PSY.PlannedOutage(; outage_schedule = "maint")
    PSY.add_supplemental_attribute!(sys, line, outage)
    initial_times = sort!(collect(PSY.get_forecast_initial_times(sys)))
    @test length(initial_times) >= 2
    resolution = first(PSY.get_time_series_resolutions(sys))
    steps = Int(PSY.get_forecast_horizon(sys) ÷ resolution)
    data = SortedDict{Dates.DateTime, Vector{Float64}}()
    for (i, t0) in enumerate(initial_times)
        data[t0] = [Float64(h == i) for h in 1:steps]
    end
    PSY.add_time_series!(
        sys,
        outage,
        PSY.Deterministic(; name = "maint", data = data, resolution = resolution),
    )
    window = POM.StatusWindow(
        PSY.Deterministic,
        initial_times[2],
        steps,
        resolution,
        initial_times[2] - initial_times[1],
    )
    branches, _ = POM.compute_component_statuses(sys, window)
    expected = ones(steps)
    expected[2] = 0.0
    @test branches[line] == expected
end

@testset "A model on a transformed system reads each window from the schedule's series" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_single_time_series = true)
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    stamps = collect(_T0:Dates.Hour(1):(_T0 + Dates.Hour(47)))
    out = Set(_T0 + Dates.Hour(h) for h in 6:9)
    _attach!(sys, line, PSY.PlannedOutage(; outage_schedule = "maint"), "maint",
        [t in out ? 1.0 : 0.0 for t in stamps])
    PSY.transform_single_time_series!(sys, Dates.Hour(12), Dates.Hour(4))
    for initial_time in (_T0, _T0 + Dates.Hour(4))
        model = DecisionModel(
            get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel)),
            sys;
            optimizer = HiGHS_optimizer,
            initial_time = initial_time,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        values = IOM.get_parameter_array(
            IOM.get_optimization_container(model),
            IOM.ParameterKey(POM.BranchStatusParameter, PSY.Line),
        )
        window = initial_time .+ Dates.Hour.(0:11)
        @test collect(values[PSY.get_name(line), :]) ==
              [t in out ? 0.0 : 1.0 for t in window]
    end
end

@testset "Schedules under a formulation that cannot model them fail the build" begin
    model, _ = _scheduled_dispatch_model(; network = NetworkModel(ACPNetworkModel))
    @test _build_for_log(model) == IOM.ModelBuildStatus.FAILED
    log_text = _read_build_log(model)
    @test occursin("cannot model them", log_text)
    @test occursin("ACPNetworkModel", log_text)
end

@testset "Branch schedules under CopperPlate are ignored with a warning" begin
    model, _ = _scheduled_dispatch_model(; network = NetworkModel(CopperPlateNetworkModel))
    @test _build_for_log(model) == IOM.ModelBuildStatus.BUILT
    @test occursin("Branch schedules are ignored", _read_build_log(model))
end

@testset "Branch schedules under DCP build without the formulation messages" begin
    model, _ = _scheduled_dispatch_model(; network = NetworkModel(DCPNetworkModel))
    @test _build_for_log(model) == IOM.ModelBuildStatus.BUILT
    log_text = _read_build_log(model)
    @test !occursin("Branch schedules are ignored", log_text)
    @test !occursin("cannot model them", log_text)
end

@testset "Power flow in the loop rejects branch schedules but accepts injector schedules" begin
    network() = NetworkModel(
        PTDFNetworkModel;
        evaluations = power_flow_evaluations(ACPowerFlow()),
    )
    model, _ = _scheduled_dispatch_model(; network = network())
    @test _build_for_log(model) == IOM.ModelBuildStatus.FAILED
    @test occursin("cannot follow scheduled topology", _read_build_log(model))

    injector_model, _ = _scheduled_dispatch_model(;
        schedules = false,
        injector_schedule = true,
        network = network(),
    )
    @test _build_for_log(injector_model) == IOM.ModelBuildStatus.BUILT
end

@testset "A schedule on a hybrid system is rejected" begin
    sys = PSB.build_system(PSB.PSITestSystems, "test_RTS_GMLC_sys")
    hybrid = add_hybrid_to_chuhsi_bus!(sys)
    PSY.add_supplemental_attribute!(
        sys,
        hybrid,
        PSY.PlannedOutage(; outage_schedule = "hybrid_maint"),
    )
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, horizon = Hour(3))
    @test_throws r"HybridSystem .* not covered by injector statuses" POM.validate_template(
        model,
    )
end
