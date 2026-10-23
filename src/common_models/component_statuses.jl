"""
The time steps a status computation covers: `len` steps of `resolution` starting at
`initial_time` of a model reading series of type `ts_type` (forecasts for decision models,
`SingleTimeSeries` for emulation models). Schedules are read as `ts_type`, except under
`DeterministicSingleTimeSeries`, where they are read from their `SingleTimeSeries`. A
`nothing` resolution reads the series' only resolution.
"""
struct StatusWindow
    ts_type::Type{<:IS.TimeSeriesData}
    initial_time::Dates.DateTime
    len::Int
    resolution::Union{Nothing, Dates.Period}
    interval::Union{Nothing, Dates.Period}
end

"""
    compute_component_statuses(sys, window)

Status of every available component carrying a `PSY.PlannedOutage` or `PSY.SwitchingSchedule`
at each step of `window`: 1.0 in service, 0.0 out. A component is out when any of its planned
outages is 1; a switch is open when any of its switching schedules is 0; a planned outage
overrides a closed switching schedule. A switch that is `OPEN` and has no switching schedule
is not in the network, so it is out at every step. Components other than branches and
static injectors are ignored with a warning, and their schedules are never read. Returns
`(branches, injectors)` dictionaries.
"""
function compute_component_statuses(sys::PSY.System, window::StatusWindow)
    branches = Dict{PSY.Component, Vector{Float64}}()
    injectors = Dict{PSY.Component, Vector{Float64}}()
    scheduled = PNM.topology_schedule_components(sys).components
    for component in scheduled
        _add_component_status!(branches, injectors, component, window)
    end
    return branches, injectors
end

function _add_component_status!(branches, _, branch::PSY.Branch, window::StatusWindow)
    branches[branch] = _component_status(branch, window)
    return
end

function _add_component_status!(
    _,
    injectors,
    injector::PSY.StaticInjection,
    window::StatusWindow,
)
    injectors[injector] = _component_status(injector, window)
    return
end

function _add_component_status!(_, _, component::PSY.Component, ::StatusWindow)
    message =
        "$(typeof(component)) $(PSY.get_name(component)) carries a schedule, but " *
        "schedules only apply to branches and static injectors; it is ignored."
    # Keyed per component so a simulation warns once per component, not at every step.
    @warn message maxlog = 1 _id = (:ignored_schedule, objectid(component))
    return
end

function _component_status(component::PSY.Component, window::StatusWindow)
    status = ones(window.len)
    _apply_planned_outages!(status, component, window)
    _apply_switching_schedules!(status, component, window)
    _apply_unscheduled_open_switch!(status, component)
    return status
end

"""
    unscheduled_component_status(component)

Status of a component that carries no schedule in its system: 1.0 when it is available and
in the network, 0.0 otherwise. A switch that is `OPEN` and has no switching schedule is not
in the network.
"""
function unscheduled_component_status(component::PSY.Component)
    PSY.get_available(component) || return 0.0
    status = [1.0]
    _apply_unscheduled_open_switch!(status, component)
    return only(status)
end

_apply_unscheduled_open_switch!(_, ::PSY.Component) = nothing

function _apply_unscheduled_open_switch!(status, switch::PSY.DiscreteControlledACBranch)
    PSY.get_branch_status(switch) == PSY.DiscreteControlledBranchStatus.OPEN || return
    isempty(PSY.get_supplemental_attributes(PSY.SwitchingSchedule, switch)) || return
    fill!(status, 0.0)
    return
end

function _apply_planned_outages!(status, component, window::StatusWindow)
    for outage in PSY.get_supplemental_attributes(PSY.PlannedOutage, component)
        values =
            _schedule_values(component, outage, PSY.get_outage_schedule(outage), window)
        for t in eachindex(status)
            if values[t] == 1.0
                status[t] = 0.0
            end
        end
    end
    return
end

function _apply_switching_schedules!(status, component, window::StatusWindow)
    schedules = collect(PSY.get_supplemental_attributes(PSY.SwitchingSchedule, component))
    isempty(schedules) && return
    closed = trues(window.len)
    any_closed = falses(window.len)
    for schedule in schedules
        values = _schedule_values(
            component,
            schedule,
            PSY.get_status_schedule(schedule),
            window,
        )
        for t in eachindex(values)
            is_closed = values[t] == 1.0
            closed[t] = closed[t] && is_closed
            any_closed[t] = any_closed[t] || is_closed
        end
    end
    conflicts = count(any_closed .& .!closed)
    if conflicts > 0
        message =
            "Switch $(PSY.get_name(component)) has conflicting switching schedules at " *
            "$conflicts step(s); it is open wherever any schedule opens it."
        @warn message maxlog = 1 _id =
            (:conflicting_switching_schedules, objectid(component))
    end
    for t in eachindex(status)
        if !closed[t]
            status[t] = 0.0
        end
    end
    return
end

# `transform_single_time_series!` derives `DeterministicSingleTimeSeries` views for component
# series only; a schedule on a supplemental attribute keeps its `SingleTimeSeries`, and the
# window of a view is that series read from the window's initial time.
_schedule_series_type(::Type{T}) where {T <: IS.TimeSeriesData} = T
_schedule_series_type(::Type{<:IS.DeterministicSingleTimeSeries}) = IS.SingleTimeSeries

_schedule_interval(::Type{<:IS.Forecast}, window::StatusWindow) = window.interval
_schedule_interval(::Type{<:IS.TimeSeriesData}, ::StatusWindow) = nothing

# The first and last timestamps a read of the schedule `series` starting at `initial_time`
# can cover.
function _schedule_coverage(
    metadata::IS.TimeSeriesMetadata{<:IS.SingleTimeSeries},
    ::Dates.DateTime,
    ::String,
)
    first_time = IS.get_initial_timestamp(metadata)
    last_time = first_time + (IS.get_length(metadata) - 1) * IS.get_resolution(metadata)
    return first_time, last_time
end

# A forecast is read from the one window that starts at the read's initial time, so the read
# is covered from that time to the end of the window's horizon.
function _schedule_coverage(
    metadata::IS.TimeSeriesMetadata{<:IS.Forecast},
    initial_time::Dates.DateTime,
    series::String,
)
    first_time = IS.get_initial_timestamp(metadata)
    interval = IS.get_interval(metadata)
    last_window = first_time + (IS.get_count(metadata) - 1) * interval
    # A single-window forecast has a zero interval, so the grid test needs the first window
    # handled on its own.
    starts_window =
        initial_time == first_time || (
            first_time < initial_time <= last_window && iszero(
                Dates.Millisecond(initial_time - first_time) %
                Dates.Millisecond(interval),
            )
        )
    if !starts_window
        windows = if IS.get_count(metadata) == 1
            "has one window, at $first_time"
        else
            "has windows starting every $(Dates.canonicalize(interval)) from " *
            "$first_time to $last_window"
        end
        throw(
            IS.ConflictingInputsError(
                "$series $windows, but the model reads from $initial_time.",
            ),
        )
    end
    return initial_time,
    initial_time + IS.get_horizon(metadata) - IS.get_resolution(metadata)
end

function _schedule_values(component, attribute, name::String, window::StatusWindow)
    ts_type = _schedule_series_type(window.ts_type)
    interval = _schedule_interval(ts_type, window)
    owner =
        "$(nameof(typeof(attribute))) $(IS.get_id(attribute)) on " *
        "$(nameof(typeof(component))) " *
        "\"$(PSY.get_name(component))\""
    if !PSY.has_time_series(attribute, ts_type, name)
        throw(
            IS.ConflictingInputsError(
                "$owner has no $(ts_type) time series named \"$name\".",
            ),
        )
    end
    metadata = IS.get_time_series_metadata(
        ts_type,
        attribute,
        name;
        resolution = window.resolution,
        interval = interval,
    )
    series = "Time series \"$name\" of $owner"
    available_first, available_last =
        _schedule_coverage(metadata, window.initial_time, series)
    required_last =
        window.initial_time + (window.len - 1) * IS.get_resolution(metadata)
    if window.initial_time < available_first || required_last > available_last
        throw(
            IS.ConflictingInputsError(
                "$series covers $available_first to $available_last, but the model " *
                "reads $(window.initial_time) to $required_last.",
            ),
        )
    end
    values = IS.get_time_series_values(
        ts_type,
        attribute,
        name;
        start_time = window.initial_time,
        len = window.len,
        resolution = window.resolution,
        interval = interval,
    )
    for v in values
        if v != 0.0 && v != 1.0
            throw(
                IS.ConflictingInputsError(
                    "Time series \"$name\" of $owner has value $v; schedules must be " *
                    "0 or 1.",
                ),
            )
        end
    end
    return values
end

"""
    status_before_window(component, window)

Injector status of `component` at the step before `window` starts, from its planned outages:
1.0 in service, 0.0 out, or `nothing` when one of its schedules has no value at that step,
as before the first window of a run.
"""
function status_before_window(component::PSY.StaticInjection, window::StatusWindow)
    status = 1.0
    for outage in PSY.get_supplemental_attributes(PSY.PlannedOutage, component)
        value = _schedule_value_before(outage, PSY.get_outage_schedule(outage), window)
        isnothing(value) && return nothing
        value == 1.0 && (status = 0.0)
    end
    return status
end

function _schedule_value_before(attribute, name::String, window::StatusWindow)
    ts_type = _schedule_series_type(window.ts_type)
    PSY.has_time_series(attribute, ts_type, name) || return nothing
    metadata = IS.get_time_series_metadata(
        ts_type,
        attribute,
        name;
        resolution = window.resolution,
        interval = _schedule_interval(ts_type, window),
    )
    previous = window.initial_time - IS.get_resolution(metadata)
    return _schedule_value_at(metadata, ts_type, attribute, name, previous, window)
end

function _schedule_value_at(
    metadata::IS.TimeSeriesMetadata{<:IS.SingleTimeSeries},
    ts_type,
    attribute,
    name::String,
    time::Dates.DateTime,
    window::StatusWindow,
)
    first_time = IS.get_initial_timestamp(metadata)
    last_time = first_time + (IS.get_length(metadata) - 1) * IS.get_resolution(metadata)
    first_time <= time <= last_time || return nothing
    values = IS.get_time_series_values(
        ts_type,
        attribute,
        name;
        start_time = time,
        len = 1,
        resolution = window.resolution,
    )
    return Float64(only(values))
end

# A forecast is read from the latest window that starts at or before `time`, which is the
# window of the previous step of a rolling simulation.
function _schedule_value_at(
    metadata::IS.TimeSeriesMetadata{<:IS.Forecast},
    ts_type,
    attribute,
    name::String,
    time::Dates.DateTime,
    window::StatusWindow,
)
    first_time = IS.get_initial_timestamp(metadata)
    time < first_time && return nothing
    resolution = Dates.Millisecond(IS.get_resolution(metadata))
    interval = Dates.Millisecond(IS.get_interval(metadata))
    count = IS.get_count(metadata)
    elapsed = Dates.Millisecond(time - first_time)
    k = count == 1 ? 0 : min(count - 1, fld(Dates.value(elapsed), Dates.value(interval)))
    start = first_time + k * interval
    offset = Dates.value(Dates.Millisecond(time - start)) ÷ Dates.value(resolution)
    steps =
        Dates.value(Dates.Millisecond(IS.get_horizon(metadata))) ÷ Dates.value(resolution)
    offset < steps || return nothing
    values = IS.get_time_series_values(
        ts_type,
        attribute,
        name;
        start_time = start,
        len = offset + 1,
        resolution = window.resolution,
        interval = window.interval,
    )
    return Float64(last(values))
end

function status_window(container::OptimizationContainer, initial_time::Dates.DateTime)
    settings = get_settings(container)
    ts_type = get_default_time_series_type(container)
    return StatusWindow(
        ts_type,
        initial_time,
        length(get_time_steps(container)),
        _to_is_resolution(get_resolution(settings)),
        _status_interval(ts_type, settings),
    )
end

_status_interval(::Type{<:IS.Forecast}, settings) =
    _to_is_interval(get_interval(settings))
_status_interval(::Type{<:IS.TimeSeriesData}, _) = nothing

function fill_component_status_parameters!(
    container::OptimizationContainer,
    sys::PSY.System,
    initial_time::Dates.DateTime,
)
    branches, injectors =
        compute_component_statuses(sys, status_window(container, initial_time))
    _write_status_parameters!(container, BranchStatusParameter, branches)
    _write_status_parameters!(container, InjectorStatusParameter, injectors)
    return
end

function _write_status_parameters!(
    container::OptimizationContainer,
    ::Type{T},
    statuses::Dict{PSY.Component, Vector{Float64}},
) where {T <: ComponentStatusParameter}
    by_type = Dict{DataType, Vector{PSY.Component}}()
    for component in keys(statuses)
        push!(get!(Vector{PSY.Component}, by_type, typeof(component)), component)
    end
    time_steps = get_time_steps(container)
    for (D, components) in by_type
        key = ParameterKey(T, D)
        param = if has_container_key(container, T, D)
            get_parameter_array(container, key)
        else
            names = sort!(PSY.get_name.(components))
            param_container = IOM.add_param_container_shared_axes!(
                container, key, IOM.NoAttributes(), get_param_eltype(container, T),
                names, time_steps,
            )
            fill!(IOM.get_multiplier_array(param_container), 1.0)
            IOM.get_parameter_array(param_container)
        end
        for component in components
            name = PSY.get_name(component)
            for t in time_steps
                param[name, t] = statuses[component][t]
            end
        end
    end
    return
end

# A simulation refreshes the statuses once per step, for the window that starts at the
# model's current time, before it updates the other parameters.
function IOM.update_model_parameters!(
    container::OptimizationContainer,
    model::Union{
        DecisionModel{<:AbstractPowerOperationProblem},
        EmulationModel{<:AbstractPowerOperationProblem},
    },
    _,
)
    _has_status_parameters(container) || return
    fill_component_status_parameters!(
        container,
        get_system(model),
        IOM.get_current_time(model),
    )
    return
end

_has_status_parameters(container::OptimizationContainer) = any(
    key -> IOM.get_entry_type(key) <: ComponentStatusParameter,
    keys(IOM.get_parameters(container)),
)

"""
Add the component status parameters at build time. On a rebuild the containers already hold
the values written for the new window, so they are left as they are.
"""
function construct_component_status_parameters!(
    container::OptimizationContainer,
    ::PowerOperationsProblemTemplate,
    sys::PSY.System,
)
    _has_topology_schedules(sys) || return
    _check_steps_start_at_one(get_time_steps(container))
    _has_all_status_containers(container, sys) && return
    fill_component_status_parameters!(
        container,
        sys,
        get_initial_time(get_settings(container)),
    )
    return
end

_has_topology_schedules(sys::PSY.System) =
    any(_is_status_component, PNM.topology_schedule_components(sys).components)

_is_status_component(::PSY.Branch) = true
_is_status_component(::PSY.StaticInjection) = true
_is_status_component(::PSY.Component) = false

_status_parameter_type(::PSY.Branch) = BranchStatusParameter
_status_parameter_type(::PSY.StaticInjection) = InjectorStatusParameter

function _has_all_status_containers(container::OptimizationContainer, sys::PSY.System)
    components =
        filter(_is_status_component, PNM.topology_schedule_components(sys).components)
    return all(
        c -> has_container_key(container, _status_parameter_type(c), typeof(c)),
        components,
    )
end
