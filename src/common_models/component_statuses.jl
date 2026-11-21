"""
Name of the time series that schedules a device's `available` field: 1.0 when available,
0.0 when not.
"""
const AVAILABLE_SCHEDULE = "available"

"""
Name of the time series that schedules a switch's `branch_status` field: 1.0 when `CLOSED`,
0.0 when `OPEN`. Only a `PSY.DiscreteControlledACBranch` carries it.
"""
const BRANCH_STATUS_SCHEDULE = "branch_status"

"""
    schedule_candidates(sys::PSY.System) -> Vector{PSY.Device}

Every device of `sys`, available or not, that carries an [`AVAILABLE_SCHEDULE`](@ref) time
series or, for switches, a [`BRANCH_STATUS_SCHEDULE`](@ref) time series; the series' values
are never read. Pass the result to [`topology_schedule_components`](@ref) to derive the
scheduled components without probing the time series store again, for instance after
availabilities change.

A `BRANCH_STATUS_SCHEDULE` series on a device that is not a switch is an error raised by
this scan; the `candidates` form of [`topology_schedule_components`](@ref) does not check
for it.
"""
function schedule_candidates(sys::PSY.System)
    candidates = PSY.Device[]
    for device in PSY.get_components(PSY.Device, sys)
        if _has_branch_status_schedule(device) ||
           PSY.has_time_series(device, AVAILABLE_SCHEDULE)
            push!(candidates, device)
        end
    end
    return candidates
end

"""
    topology_schedule_components(sys::PSY.System)
    topology_schedule_components(sys::PSY.System, candidates::Vector{PSY.Device})

Collect what scheduled topology changes act on: the available members of `candidates`,
which default to [`schedule_candidates`](@ref)`(sys)`. With `candidates` given, the time
series store is probed only to tell which candidate switches carry a branch status series;
availabilities are read at the time of the call.

Returns a named tuple:
- `components`: every available candidate, each once
- `closed_switches`: available switches carrying a [`BRANCH_STATUS_SCHEDULE`](@ref) series
- `scheduled_branches`: every available candidate that is a `PSY.ACTransmission`

A `BRANCH_STATUS_SCHEDULE` series on a device that is not a switch is an error.
"""
topology_schedule_components(sys::PSY.System) =
    topology_schedule_components(sys, schedule_candidates(sys))

function topology_schedule_components(::PSY.System, candidates::Vector{PSY.Device})
    components = PSY.Component[]
    closed_switches = PSY.DiscreteControlledACBranch[]
    scheduled_branches = PSY.ACTransmission[]
    for device in candidates
        PSY.get_available(device) || continue
        push!(components, device)
        device isa PSY.ACTransmission && push!(scheduled_branches, device)
        if device isa PSY.DiscreteControlledACBranch && _has_branch_status_schedule(device)
            push!(closed_switches, device)
        end
    end
    return (
        components = components,
        closed_switches = closed_switches,
        scheduled_branches = scheduled_branches,
    )
end

_has_branch_status_schedule(switch::PSY.DiscreteControlledACBranch) =
    PSY.has_time_series(switch, BRANCH_STATUS_SCHEDULE)

function _has_branch_status_schedule(device::PSY.Device)
    PSY.has_time_series(device, BRANCH_STATUS_SCHEDULE) || return false
    throw(
        IS.ConflictingInputsError(
            "$(nameof(typeof(device))) $(PSY.get_name(device)) carries a \"$(BRANCH_STATUS_SCHEDULE)\" time series, but only a DiscreteControlledACBranch has a branch status; schedule its outages with an \"$(AVAILABLE_SCHEDULE)\" time series.",
        ),
    )
end

"""
The time steps a status computation covers: `len` steps of `resolution` starting at
`initial_time` of a model reading series of type `ts_type` (forecasts for decision models,
`SingleTimeSeries` for emulation models). A `nothing` resolution reads the series' only
resolution.
"""
struct StatusWindow
    ts_type::Type{<:IS.TimeSeriesData}
    initial_time::Dates.DateTime
    len::Int
    resolution::Union{Nothing, Dates.Period}
    interval::Union{Nothing, Dates.Period}
end

"""
    compute_component_statuses(components, window)

Status of each of `components` at each step of `window`: 1.0 in service, 0.0 out.
Only available devices carrying a [`AVAILABLE_SCHEDULE`](@ref) or, for a switch, a
[`BRANCH_STATUS_SCHEDULE`](@ref) time series are included.
A device is out where its availability series is 0; a switch is also out where its branch
status series is 0 (`OPEN`). A switch that is `OPEN` and has no branch status series is not in
the network, so it is out at every step. Devices other than branches and static injectors are
ignored with a warning, and their series are never read. Returns `(branches, injectors)`
dictionaries.
"""
function compute_component_statuses(
    components::AbstractVector{<:PSY.Component},
    window::StatusWindow,
)
    branches = Dict{PSY.Component, Vector{Float64}}()
    injectors = Dict{PSY.Component, Vector{Float64}}()
    for component in components
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
        "$(typeof(component)) $(PSY.get_name(component)) carries an availability " *
        "schedule, but schedules only apply to branches and static injectors; it is ignored."
    # Keyed per component so a simulation warns once per component, not at every step.
    @warn message maxlog = 1 _id = (:ignored_schedule, objectid(component))
    return
end

function _component_status(component::PSY.Component, window::StatusWindow)
    status = ones(window.len)
    _apply_schedule!(status, component, AVAILABLE_SCHEDULE, window)
    _apply_branch_status_schedule!(status, component, window)
    _apply_unscheduled_open_switch!(status, component)
    return status
end

"""
    unscheduled_component_status(component)

Status of a component that carries no schedule in its system: 1.0 when it is available and
in the network, 0.0 otherwise. A switch that is `OPEN` and has no branch status series is not
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
    PSY.has_time_series(switch, BRANCH_STATUS_SCHEDULE) && return
    fill!(status, 0.0)
    return
end

# Sets the steps where the schedule `name` of `component` is 0 out; a component without that
# series is left as it is.
function _apply_schedule!(status, component, name::String, window::StatusWindow)
    PSY.has_time_series(component, name) || return
    values = _schedule_values(component, name, window)
    for t in eachindex(status)
        if values[t] == 0.0
            status[t] = 0.0
        end
    end
    return
end

_apply_branch_status_schedule!(_, ::PSY.Component, ::StatusWindow) = nothing
_apply_branch_status_schedule!(
    status,
    switch::PSY.DiscreteControlledACBranch,
    window::StatusWindow,
) = _apply_schedule!(status, switch, BRANCH_STATUS_SCHEDULE, window)

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

function _schedule_values(component, name::String, window::StatusWindow)
    ts_type = window.ts_type
    interval = _schedule_interval(ts_type, window)
    owner = "$(nameof(typeof(component))) \"$(PSY.get_name(component))\""
    if !PSY.has_time_series(component, ts_type, name)
        throw(
            IS.ConflictingInputsError(
                "$owner has no $(nameof(ts_type)) time series named \"$name\".",
            ),
        )
    end
    metadata = IS.get_time_series_metadata(
        ts_type,
        component,
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
        component,
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

Injector status of `component` at the step before `window` starts, from its availability
schedule: 1.0 in service, 0.0 out, or `nothing` when the schedule has no value at that step,
as before the first window of a run. A component without the schedule is in service.
"""
function status_before_window(component::PSY.StaticInjection, window::StatusWindow)
    PSY.has_time_series(component, AVAILABLE_SCHEDULE) || return 1.0
    return _schedule_value_before(component, AVAILABLE_SCHEDULE, window)
end

function _schedule_value_before(component, name::String, window::StatusWindow)
    ts_type = window.ts_type
    PSY.has_time_series(component, ts_type, name) || return nothing
    metadata = IS.get_time_series_metadata(
        ts_type,
        component,
        name;
        resolution = window.resolution,
        interval = _schedule_interval(ts_type, window),
    )
    previous = window.initial_time - IS.get_resolution(metadata)
    value = _schedule_value_at(metadata, ts_type, component, name, previous, window)
    _check_binary_schedule_value(value, component, name, previous)
    return value
end

_check_binary_schedule_value(::Nothing, component, name::String, time::Dates.DateTime) =
    nothing

function _check_binary_schedule_value(
    value::Float64,
    component,
    name::String,
    time::Dates.DateTime,
)
    (value == 0.0 || value == 1.0) && return
    owner = "$(nameof(typeof(component))) \"$(PSY.get_name(component))\""
    throw(
        IS.ConflictingInputsError(
            "Time series \"$name\" of $owner has value $value at $time; schedules must " *
            "be 0 or 1.",
        ),
    )
end

function _schedule_value_at(
    metadata::IS.TimeSeriesMetadata{<:IS.SingleTimeSeries},
    ts_type,
    component,
    name::String,
    time::Dates.DateTime,
    window::StatusWindow,
)
    first_time = IS.get_initial_timestamp(metadata)
    last_time = first_time + (IS.get_length(metadata) - 1) * IS.get_resolution(metadata)
    first_time <= time <= last_time || return nothing
    values = IS.get_time_series_values(
        ts_type,
        component,
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
    component,
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
        component,
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
    template::PowerOperationsProblemTemplate,
    sys::PSY.System,
    initial_time::Dates.DateTime,
)
    branches, injectors = compute_component_statuses(
        scheduled_components(template, sys).components,
        status_window(container, initial_time),
    )
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
        get_template(model),
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
the values written for the new window by `IOM.update_model_parameters!`, so they are left as
they are.
"""
function construct_component_status_parameters!(
    container::OptimizationContainer,
    template::PowerOperationsProblemTemplate,
    sys::PSY.System,
)
    _has_topology_schedules(template, sys) || return
    _check_steps_start_at_one(get_time_steps(container))
    _has_status_parameters(container) && return
    fill_component_status_parameters!(
        container,
        template,
        sys,
        get_initial_time(get_settings(container)),
    )
    return
end

# Statuses are stored in vectors indexed by the step itself, so the steps must be the
# positions 1, 2, ….
function _check_steps_start_at_one(time_steps)
    first(time_steps) == 1 && return
    throw(
        ArgumentError(
            "Component statuses need time steps starting at 1; got $time_steps.",
        ),
    )
end

_has_topology_schedules(template::PowerOperationsProblemTemplate, sys::PSY.System) =
    any(_is_status_component, scheduled_components(template, sys).components)

_is_status_component(::PSY.Branch) = true
_is_status_component(::PSY.StaticInjection) = true
_is_status_component(::PSY.Component) = false
