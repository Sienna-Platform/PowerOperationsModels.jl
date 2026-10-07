"""
The owner id of every parameter array row. No component holds this id, so a parameter row never
appears in a restored component's own `list_time_series_metadata`.
"""
const PARAMETER_ROW_OWNER_ID = -1
const PARAMETER_ROW_OWNER_TYPE = "OptimizationParameter"
"""Feature key that holds the encoded `IOM.ParameterKey` of a parameter row."""
const PARAMETER_KEY_FEATURE = "parameter"

"""
The open `IS.Store` of a loaded `System`. Use it to read the parameters of a bundle without a
second open: InfraStore allows one open handle per file. Do not close it; `sys` owns it.
"""
parameter_store_of(sys::PSY.System) = IS.get_data_store(sys.data)

_parameter_key_features(key::IOM.ParameterKey, extra_features::Dict{String, <:Any}) =
    merge(
        Dict{String, Any}(PARAMETER_KEY_FEATURE => IOM.encode_key_as_string(key)),
        extra_features,
    )

"""The owner type name of a component row: the name of its type, without type parameters."""
_owner_type(::T) where {T <: PSY.Component} = string(nameof(T))

function _add_row!(
    store::IS.Store,
    owner_id::Integer,
    owner_type::AbstractString,
    ts::IS.TimeSeriesData;
    features::Union{Nothing, Dict} = nothing,
)
    return IS.add_time_series!(
        store,
        owner_id,
        owner_type,
        IS.get_owner_category(IS.InfrastructureSystemsComponent),
        ts;
        features = features,
    )
end

"""The windows of one axis-1 label, as `initial time => values`."""
_label_windows(windows::AbstractDict, label) =
    Dict(t => collect(vec(w[label, :])) for (t, w) in windows)

"""
Store one parameter array under the synthetic parameter owner, one `SingleTimeSeries` per
axis-1 label. `resolution` is explicit because one timestamp cannot give a resolution.
"""
function write_parameter_array!(
    store::IS.Store,
    key::IOM.ParameterKey,
    array::JuMP.Containers.DenseAxisArray{<:Any, 2},
    initial_timestamp::Dates.DateTime,
    resolution::Dates.Period;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)
    features = _parameter_key_features(key, extra_features)
    for label in axes(array, 1)
        ts = PSY.SingleTimeSeries(;
            name = string(label),
            data = vec(array[label, :]),
            initial_timestamp = initial_timestamp,
            resolution = resolution,
        )
        _add_row!(store, PARAMETER_ROW_OWNER_ID, PARAMETER_ROW_OWNER_TYPE, ts;
            features = features)
    end
    return nothing
end

"""
Store a 3-D parameter array as one 2-D array per axis-2 label. The `"axis2"` feature holds the
label. Time is the last axis, as in the PSI HDF5 layout.
"""
function write_parameter_array!(
    store::IS.Store,
    key::IOM.ParameterKey,
    array::JuMP.Containers.DenseAxisArray{<:Any, 3},
    initial_timestamp::Dates.DateTime,
    resolution::Dates.Period;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)
    for label2 in axes(array, 2)
        write_parameter_array!(
            store,
            key,
            array[:, label2, :],
            initial_timestamp,
            resolution;
            extra_features = merge(
                extra_features, Dict{String, Any}("axis2" => string(label2)),
            ),
        )
    end
    return nothing
end

_parameter_rows(
    store::IS.Store,
    key::IOM.ParameterKey,
    extra_features::Dict{String, <:Any},
) = IS.list_time_series_metadata(
    store;
    owner_id = PARAMETER_ROW_OWNER_ID,
    features = _parameter_key_features(key, extra_features),
)

"""
The sorted `"axis2"` labels of the rows for `key`. Empty for a 2-D parameter.
"""
function parameter_slice_labels(
    store::IS.Store,
    key::IOM.ParameterKey;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Vector{String}
    slice_labels = Set{String}()
    for md in _parameter_rows(store, key, extra_features)
        row_features = IS.get_features(md)
        haskey(row_features, "axis2") && push!(slice_labels, string(row_features["axis2"]))
    end
    return sort!(collect(slice_labels))
end

has_parameter_rows(
    store::IS.Store,
    key::IOM.ParameterKey;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Bool = !isempty(_parameter_rows(store, key, extra_features))

"""Read every parameter array row for `key`, keyed by its axis-1 label."""
function read_parameter_array(
    store::IS.Store,
    key::IOM.ParameterKey;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Dict{String, IS.TimeSeries.TimeArray}
    rows = _parameter_rows(store, key, extra_features)
    isempty(rows) &&
        error("no parameter arrays found for $key in this outputs store")
    result = Dict{String, IS.TimeSeries.TimeArray}()
    for md in rows
        ts = IS.get_time_series(store, IS.get_time_series_key(md))
        result[IS.get_name(md)] = IS.make_time_array(ts, IS.get_initial_timestamp(ts))
    end
    return result
end

function _check_parameter_windows(
    key::IOM.ParameterKey,
    windows::AbstractDict{Dates.DateTime, <:JuMP.Containers.DenseAxisArray{<:Any, 2}},
)
    isempty(windows) && error("no parameter windows given for $key")
    labels = axes(first(values(windows)), 1)
    for (initial_time, window) in windows
        axes(window, 1) == labels || error(
            "parameter windows for $key do not share the same axis-1 labels: window at " *
            "$initial_time has $(collect(axes(window, 1))), expected $(collect(labels))",
        )
    end
    return labels
end

"""
Store the windows of one parameter under the synthetic parameter owner, one `Deterministic`
per axis-1 label.
"""
function write_parameter_windows!(
    store::IS.Store,
    key::IOM.ParameterKey,
    windows::AbstractDict{Dates.DateTime, <:JuMP.Containers.DenseAxisArray{<:Any, 2}},
    resolution::Dates.Period,
    interval::Dates.Period;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Nothing
    features = _parameter_key_features(key, extra_features)
    for label in _check_parameter_windows(key, windows)
        ts = PSY.Deterministic(
            string(label), _label_windows(windows, label), resolution, interval,
        )
        _add_row!(store, PARAMETER_ROW_OWNER_ID, PARAMETER_ROW_OWNER_TYPE, ts;
            features = features)
    end
    return nothing
end

"""
Store 3-D parameter windows as one 2-D window set per axis-2 label, with the `"axis2"` feature.
"""
function write_parameter_windows!(
    store::IS.Store,
    key::IOM.ParameterKey,
    windows::AbstractDict{Dates.DateTime, <:JuMP.Containers.DenseAxisArray{<:Any, 3}},
    resolution::Dates.Period,
    interval::Dates.Period;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Nothing
    isempty(windows) && error("no parameter windows given for $key")
    for label2 in axes(first(values(windows)), 2)
        write_parameter_windows!(
            store,
            key,
            Dict(t => w[:, label2, :] for (t, w) in windows),
            resolution,
            interval;
            extra_features = merge(
                extra_features, Dict{String, Any}("axis2" => string(label2)),
            ),
        )
    end
    return nothing
end

"""Read every parameter window row for `key`, keyed by axis-1 label, then initial time."""
function read_parameter_windows(
    store::IS.Store,
    key::IOM.ParameterKey;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Dict{String, Dict{Dates.DateTime, Vector{Float64}}}
    rows = _parameter_rows(store, key, extra_features)
    isempty(rows) &&
        error("no parameter windows found for $key in this outputs store")
    result = Dict{String, Dict{Dates.DateTime, Vector{Float64}}}()
    for md in rows
        ts = IS.get_time_series(store, IS.get_time_series_key(md))
        result[IS.get_name(md)] = Dict{Dates.DateTime, Vector{Float64}}(IS.get_data(ts))
    end
    return result
end

"""
Every `TimeSeriesKey` that the operation cost of `c` holds. Empty for a component type with no
`operation_cost`.
"""
_cost_time_series_keys(::PSY.Component) = IS.TimeSeriesKey[]
for T in (
    PSY.Storage,
    PSY.StaticInjectionSubsystem,
    PSY.ControllableLoad,
    PSY.ThermalGen,
    PSY.HydroGen,
    PSY.RenewableDispatch,
    PSY.Source,
    PSY.VirtualParticipant,
)
    @eval _cost_time_series_keys(c::$T) =
        PSY.get_time_series_keys(PSY.get_operation_cost(c))
end

"""
The keys of a `HydroReservoir`: its operation cost and its head-to-volume function. The
document exports both, so the store must hold both.
"""
function _cost_time_series_keys(c::PSY.HydroReservoir)
    return vcat(
        PSY.get_time_series_keys(PSY.get_operation_cost(c)),
        _function_data_keys(PSY.get_head_to_volume_factor(c)),
    )
end

_function_data_keys(::IS.FunctionData) = IS.TimeSeriesKey[]
_function_data_keys(fd::IS.TimeSeriesFunctionData) =
    IS.TimeSeriesKey[IS.get_time_series_key(fd)]

# The key of a time-series-backed reserve demand curve. The document exports this curve like
# an operation cost, so the store must hold it too.
for T in (PSY.OnlineReserve, PSY.OfflineReserve, PSY.GroupReserve)
    @eval function _cost_time_series_keys(c::$T)
        value_curve = PSY.get_value_curve(PSY.get_variable(c))
        IS.is_time_series_backed(value_curve) || return IS.TimeSeriesKey[]
        return IS.TimeSeriesKey[IS.get_time_series_key(value_curve)]
    end
end

"""
The keys of the spread bid of a `PointToPointBid`. The document exports the spread bid like an
operation cost.
"""
_cost_time_series_keys(c::PSY.PointToPointBid) =
    PSY.get_time_series_keys(PSY.get_spread_bid(c))

"""
The window grid of a run: one forecast window per execution, `horizon_count` steps each.
InfraStore requires all forecasts with the same `(resolution, interval)` to agree on count,
initial time and horizon, so every forecast row in a bundle uses this grid.
"""
struct RunWindows
    initial_times::Vector{Dates.DateTime}
    horizon_count::Int
    resolution::Dates.Period
    interval::Dates.Period
end

function RunWindows(
    initial_time::Dates.DateTime,
    steps::Int,
    horizon_count::Int,
    resolution::Dates.Period,
    interval::Dates.Period,
)
    initial_times = collect(range(initial_time; step = interval, length = steps))
    return RunWindows(initial_times, horizon_count, resolution, interval)
end

"""
One window at the initial time of `model`. A standalone model has no execution interval, so an
unset interval becomes the horizon.
"""
function run_windows(model)
    container = IOM.get_optimization_container(model)
    resolution = IOM.get_resolution(container)
    horizon_count = length(IOM.get_time_steps(container))
    interval = IOM.get_interval(IOM.get_settings(model))
    if iszero(Dates.Millisecond(interval))
        interval = resolution * horizon_count
    end
    return RunWindows(
        [IOM.get_initial_time(container)],
        horizon_count,
        resolution,
        interval,
    )
end

"""Copy a static cost series as-is. Statics have no window grid."""
function _copy_cost_time_series!(
    store::IS.Store,
    c::PSY.Component,
    ::IS.TimeSeriesKey,
    ts::IS.StaticTimeSeries,
    ::RunWindows,
)::IS.TimeSeriesKey
    return _add_row!(store, IS.get_id(c), _owner_type(c), ts)
end

"""
Copy a forecast cost onto the run grid `windows`. A horizon under two steps cannot hold a
forecast, so the series is then copied as-is: the cost of `sys` still references it.
"""
function _copy_cost_time_series!(
    store::IS.Store,
    c::PSY.Component,
    key::IS.TimeSeriesKey,
    ts::IS.Forecast,
    windows::RunWindows,
)::IS.TimeSeriesKey
    owner_type = _owner_type(c)
    windows.horizon_count < 2 && return _add_row!(store, IS.get_id(c), owner_type, ts)
    data = Dict(
        t => collect(
            IS.get_time_series_values(c, key; start_time = t, len = windows.horizon_count),
        )
        for t in windows.initial_times
    )
    copy = PSY.Deterministic(
        IS.get_name(ts),
        data,
        windows.resolution,
        windows.interval;
        units = IS.get_units(ts),
        quantity_kind = IS.get_quantity_kind(ts),
        unit_system = IS.get_unit_system(ts),
    )
    return _add_row!(store, IS.get_id(c), owner_type, copy)
end

"""
Copy every time series that a component operation cost holds into `store`, under the id and
type of that component. Return the map from each original `association_id` to the new one.

The copies come from the System, not from the parameter arrays: start-up costs are 3-tuples,
offer curves split into slope and breakpoint arrays, and a units mismatch is possible.
"""
function copy_cost_time_series!(
    store::IS.Store,
    sys::PSY.System,
    windows::RunWindows,
)::Dict{Int64, Int64}
    key_map = Dict{Int64, Int64}()
    for c in PSY.get_components(PSY.Component, sys)
        for key in _cost_time_series_keys(c)
            original_id = IS.get_association_id(key)
            haskey(key_map, original_id) && continue
            ts = IS.get_time_series(c, key)
            new_key = _copy_cost_time_series!(store, c, key, ts, windows)
            key_map[original_id] = IS.get_association_id(new_key)
        end
    end
    return key_map
end

"""
Build a new in-memory store from `model`: the cost series of its System on the run grid, its
parameters, and its time-series parameters as component-owned input series.

A horizon under two steps writes no parameter or input rows and warns: an InfraStore series
needs at least two points. `OptimizationProblemOutputs` still holds the parameters.
"""
function parameter_store_from_model(model)::Tuple{IS.Store, Dict{Int64, Int64}}
    container = IOM.get_optimization_container(model)
    sys = IOM.get_system(model)
    windows = run_windows(model)
    store = IS.Store(; in_memory = true)
    key_map = copy_cost_time_series!(store, sys, windows)
    if windows.horizon_count < 2
        @warn "$(typeof(model)) has a $(windows.horizon_count)-point time axis " *
              "($(Dates.canonicalize(windows.resolution * windows.horizon_count)) horizon); " *
              "the outputs bundle will carry no parameter rows because an InfraStore time " *
              "series needs at least two points. Parameters remain readable through " *
              "OptimizationProblemOutputs."
        return store, key_map
    end
    initial_time = first(windows.initial_times)
    for (key, array) in IOM.read_parameters(container)
        write_parameter_array!(store, key, array, initial_time, windows.resolution)
    end
    write_model_inputs!(store, sys, container, windows)
    return store, key_map
end

"""
The association rows of the System document: every row of a real component. Only parameter
rows use [`PARAMETER_ROW_OWNER_ID`](@ref).
"""
function parameter_association_rows(store::IS.Store)
    rows = IS.openapi_time_series_association_rows(store)
    return filter(row -> row.value.owner_id != PARAMETER_ROW_OWNER_ID, rows)
end

"""
Write an outputs bundle: the System document and the store it points at, in the PowerSystems
directory layout, so `PSY.from_file(bundle_dir)` reads it. `key_map` sends each cost
`association_id` to its copy in `store`. The store keeps its catalog, so rows that the document
does not declare stay readable.
"""
function write_outputs_system_bundle!(
    sys::PSY.System,
    store::IS.Store,
    key_map::AbstractDict{Int64, Int64},
    bundle_dir::AbstractString,
)
    mkpath(bundle_dir)
    sidecar = joinpath(bundle_dir, PSY.TIME_SERIES_FILE)
    IS.serialize(store, sidecar)
    rows = parameter_association_rows(store)
    doc = PSY.to_openapi(
        sys;
        time_series_storage_path = sidecar,
        write_time_series_data = false,
        store_rows = PSY.ExportStoreRows(
            IS.openapi_supplemental_attribute_association_rows(sys.data),
            length(rows),
            rows,
        ),
        association_id_map = key_map,
    )
    PSY.PC.write_document(doc, joinpath(bundle_dir, PSY.SYSTEM_DOCUMENT_FILE))
    return nothing
end

"""
Write the outputs bundle of `model` when its settings ask for one. Do not rewrite a bundle that
already exists.
"""
function _write_outputs_bundle!(model)
    IOM.get_system_to_file(IOM.get_settings(model)) || return nothing
    sys = IOM.get_system(model)
    sys_dir = joinpath(IOM.get_output_dir(model), IOM.make_system_dirname(sys))
    ispath(sys_dir) && return nothing
    store, key_map = parameter_store_from_model(model)
    write_outputs_system_bundle!(sys, store, key_map, sys_dir)
    IS.close!(store)
    return nothing
end

"""
The feature of every input row. IS matches features as a subset, so a by-name read still finds
the row. No `parameter` feature: two parameters that read one series must make one row.
"""
const INPUT_ROW_FEATURES = Dict{String, Any}("source" => "parameter")

"""
The series name and type that one time-series parameter reads, and the owner `(id, type name)`
of each label. Labels that are not System components are left out.
"""
struct InputSeriesDescriptor
    name::String
    time_series_type::Type
    owners::Dict{String, Tuple{Int64, String}}
end

_is_input_attributes(::IOM.TimeSeriesAttributes) = true
_is_input_attributes(::IOM.ParameterAttributes) = false

"""Whether the values of `pc` are a component input series."""
is_input_parameter(pc::IOM.ParameterContainer)::Bool =
    _is_input_attributes(IOM.get_attributes(pc))

function input_series_descriptor(
    sys::PSY.System,
    key::IOM.ParameterKey,
    pc::IOM.ParameterContainer,
)::InputSeriesDescriptor
    attributes = IOM.get_attributes(pc)
    D = IOM.get_component_type(key)
    owners = Dict{String, Tuple{Int64, String}}()
    unresolved = String[]
    for label in IOM.get_component_names(attributes)
        name = String(label)
        if PSY.has_component(sys, D, name)
            c = PSY.get_component(D, sys, name)
            owners[name] = (IS.get_id(c), _owner_type(c))
        else
            push!(unresolved, name)
        end
    end
    isempty(unresolved) ||
        @warn "$(IOM.encode_key_as_string(key)): labels $(sort!(unresolved)) " *
              "are not components of the System; their input series are not written to the " *
              "bundle (values remain in the parameter rows)."
    return InputSeriesDescriptor(
        IOM.get_time_series_name(attributes),
        IOM.get_time_series_type(attributes),
        owners,
    )
end

"""
Whether `store` has an input row of type `T` for `(owner_id, name)`. The type is part of the
check: a decision model `Deterministic` row and an emulation model `SingleTimeSeries` row can
share one bundle with the same owner and name.
"""
_input_row_exists(
    store::IS.Store,
    ::Type{T},
    owner_id::Int64,
    name::String,
) where {T <: IS.TimeSeriesData} =
    !isempty(
        IS.list_time_series_metadata(
            store; owner_id = owner_id, name = name, time_series_type = T,
            features = INPUT_ROW_FEATURES,
        ),
    )

"""
Add one component-owned `Deterministic` input row. Write once: do nothing when the row exists,
because two parameters can read the same series.
"""
function write_input_forecast_row!(
    store::IS.Store,
    owner_id::Int64,
    owner_type::String,
    name::String,
    data::AbstractDict{Dates.DateTime, <:AbstractVector},
    resolution::Dates.Period,
    interval::Dates.Period,
)
    _input_row_exists(store, PSY.Deterministic, owner_id, name) && return nothing
    ts = PSY.Deterministic(name, Dict(data), resolution, interval)
    _add_row!(store, owner_id, owner_type, ts; features = INPUT_ROW_FEATURES)
    return nothing
end

"""The `SingleTimeSeries` form of [`write_input_forecast_row!`](@ref), for emulation models."""
function write_input_series_row!(
    store::IS.Store,
    owner_id::Int64,
    owner_type::String,
    name::String,
    values::AbstractVector{Float64},
    initial_timestamp::Dates.DateTime,
    resolution::Dates.Period,
)
    _input_row_exists(store, PSY.SingleTimeSeries, owner_id, name) && return nothing
    ts = PSY.SingleTimeSeries(;
        name = name,
        data = collect(values),
        initial_timestamp = initial_timestamp,
        resolution = resolution,
    )
    _add_row!(store, owner_id, owner_type, ts; features = INPUT_ROW_FEATURES)
    return nothing
end

"""One `Deterministic` per resolved label, from `(label, time)` windows."""
function write_input_forecasts!(
    store::IS.Store,
    d::InputSeriesDescriptor,
    windows::AbstractDict{Dates.DateTime, <:JuMP.Containers.DenseAxisArray{Float64, 2}},
    resolution::Dates.Period,
    interval::Dates.Period,
)
    for (label, (owner_id, owner_type)) in d.owners
        write_input_forecast_row!(
            store,
            owner_id,
            owner_type,
            d.name,
            _label_windows(windows, label),
            resolution,
            interval,
        )
    end
    return nothing
end

"""One `SingleTimeSeries` per resolved label, from a `(label, time)` array."""
function write_input_series!(
    store::IS.Store,
    d::InputSeriesDescriptor,
    array::JuMP.Containers.DenseAxisArray{Float64, 2},
    initial_timestamp::Dates.DateTime,
    resolution::Dates.Period,
)
    for (label, (owner_id, owner_type)) in d.owners
        write_input_series_row!(
            store, owner_id, owner_type, d.name, vec(array[label, :]), initial_timestamp,
            resolution,
        )
    end
    return nothing
end

_write_input!(
    store::IS.Store,
    ::Type{<:IS.Forecast},
    d::InputSeriesDescriptor,
    raw::JuMP.Containers.DenseAxisArray{Float64, 2},
    windows::RunWindows,
) = write_input_forecasts!(
    store, d, Dict(first(windows.initial_times) => raw), windows.resolution,
    windows.interval,
)

_write_input!(
    store::IS.Store,
    ::Type{<:IS.StaticTimeSeries},
    d::InputSeriesDescriptor,
    raw::JuMP.Containers.DenseAxisArray{Float64, 2},
    windows::RunWindows,
) = write_input_series!(
    store, d, raw, first(windows.initial_times), windows.resolution,
)

"""A 3-D parameter has no input-series form; warn and skip it."""
function _write_input!(
    ::IS.Store,
    ::Type{<:IS.TimeSeriesData},
    d::InputSeriesDescriptor,
    ::JuMP.Containers.DenseAxisArray{Float64, 3},
    ::RunWindows,
)
    @warn "input series \"$(d.name)\" comes from a 3-D parameter array; not recast into the bundle"
    return nothing
end

"""
Write every time-series parameter of a standalone model as component-owned input series, one
window at the initial time of the model.
"""
function write_model_inputs!(
    store::IS.Store,
    sys::PSY.System,
    container::IOM.OptimizationContainer,
    windows::RunWindows,
)
    for (key, pc) in IOM.get_parameters(container)
        is_input_parameter(pc) || continue
        d = input_series_descriptor(sys, key, pc)
        _write_input!(store, d.time_series_type, d, IOM.get_parameter_values(pc), windows)
    end
    return nothing
end

"""Every input row in `store`: the rows with [`INPUT_ROW_FEATURES`](@ref)."""
list_input_series(store::IS.Store) =
    IS.list_time_series_metadata(store; features = INPUT_ROW_FEATURES)

"""The series of one input row."""
read_input_time_series(store::IS.Store, md::IS.TimeSeriesMetadata) =
    IS.get_time_series(store, IS.get_time_series_key(md))
