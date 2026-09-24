"""
The owner id every parameter array row is written under. No component ever holds this id, so a
parameter row never shows up in a restored component's own `list_time_series_metadata`.
"""
const PARAMETER_ROW_OWNER_ID = -1
const PARAMETER_ROW_OWNER_TYPE = "OptimizationParameter"
"""Feature key carrying the encoded `IOM.ParameterKey` a parameter row belongs to."""
const PARAMETER_KEY_FEATURE = "parameter"

"""
The InfraStore-backed store for optimization parameters.

Parameters are written here rather than into an outputs dataset so the bundle carries a real
InfraStore store. The System document's association rows are exported from this same store,
which is what makes every `uri` resolve on read — InfraStore refuses a catalog row naming an
array it does not hold.

This is the only place in PowerOperationsModels or PowerSimulations that knows InfraStore exists.
"""
struct ParameterTimeSeriesStore
    store::IS.Store
end

"""A fresh, writable, in-memory parameter store."""
ParameterTimeSeriesStore() = ParameterTimeSeriesStore(IS.Store(; in_memory = true))

"""
Reopen a persisted parameter store with its catalog, writable in place, so later
`write_parameter_*` calls land directly in the on-disk `.h5`/`.sqlite` pair with no re-persist.
`IS.open_infrastore_store` opens its artifacts in place, writable, by default (`read_only =
false`, `catalog = :attached`); the copy-to-a-temp-location path lives in a different function
(`open_deserialized_infrastore_store`), used only for deserialized `System` artifacts, and this
store never goes through it.
"""
function open_parameter_store(path::AbstractString)
    return ParameterTimeSeriesStore(IS.open_infrastore_store(path))
end

"""
A borrowed view of a `System`'s own already-open store -- for a caller that already has this
bundle's System loaded (e.g. via `PSY.from_file(...; time_series_read_only = true)`) and wants
to read its realized parameters without opening a second handle to the same sidecar file
(InfraStore allows only one open handle per file per process).

The caller must **not** [`close_parameter_store!`](@ref) the result: the underlying store is
owned by `sys`'s own time series manager, which opened it and will close it.
"""
parameter_store_of(sys::PSY.System) =
    ParameterTimeSeriesStore(IS.get_data_store(sys.data))

function close_parameter_store!(store::ParameterTimeSeriesStore)
    IS.close!(store.store)
    return nothing
end

function _check_parameter_array_length(
    key::IOM.ParameterKey,
    array_length::Int,
    timestamps_length::Int,
)
    array_length == timestamps_length || error(
        "parameter array for $key has $array_length time steps but $timestamps_length " *
        "timestamps were given",
    )
    return nothing
end

_parameter_key_features(key::IOM.ParameterKey, extra_features::Dict{String, <:Any}) =
    merge(
        Dict{String, Any}(PARAMETER_KEY_FEATURE => IOM.encode_key_as_string(key)),
        extra_features,
    )

"""
Add one row to `store`, under `owner_id`/`owner_type` (or a component's own id/type). One spot
for the owner-category argument every `IS.add_time_series!` call here repeats.
"""
_add_row!(
    store::ParameterTimeSeriesStore,
    owner_id::Integer,
    owner_type::AbstractString,
    ts::IS.TimeSeriesData,
) = IS.add_time_series!(
    store.store,
    owner_id,
    owner_type,
    IS.get_owner_category(IS.InfrastructureSystemsComponent),
    ts,
)

_add_row!(
    store::ParameterTimeSeriesStore,
    owner_id::Integer,
    owner_type::AbstractString,
    ts::IS.TimeSeriesData,
    features::Dict,
) = IS.add_time_series!(
    store.store,
    owner_id,
    owner_type,
    IS.get_owner_category(IS.InfrastructureSystemsComponent),
    ts;
    features = features,
)

_add_row!(
    store::ParameterTimeSeriesStore,
    c::PSY.Component,
    ts::IS.TimeSeriesData,
) = _add_row!(store, IS.get_id(c), string(nameof(typeof(c))), ts)

"""
Store one parameter array's realized values under the synthetic parameter owner, one
`SingleTimeSeries` per axis-1 label. Never becomes a document row: it is read back through
[`read_parameter_array`](@ref), not through the restored System's own component listing.

`resolution` is passed explicitly rather than inferred from `timestamps`, and `data` is built
directly from `array` rather than routed through `IS.TimeSeries.TimeArray`: a single-time-step
array (e.g. a model built with `horizon = Dates.Hour(1)`) gives `SingleTimeSeries` only one
timestamp, and `IS.check_resolution` requires at least two timestamps to validate a resolution
against, TimeArray-backed or not. `timestamps` is always a `range(initial_time; step =
resolution, length = ...)` in every caller, so the stride is already correct by construction —
`initial_timestamp`/`resolution` alone are enough to place `data`.
"""
function write_parameter_array!(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey,
    array::JuMP.Containers.DenseAxisArray{<:Any, 2},
    timestamps::AbstractVector{Dates.DateTime},
    resolution::Dates.Period;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)
    labels = axes(array, 1)
    _check_parameter_array_length(key, length(axes(array, 2)), length(timestamps))
    features = _parameter_key_features(key, extra_features)
    for label in labels
        _add_row!(
            store,
            PARAMETER_ROW_OWNER_ID,
            PARAMETER_ROW_OWNER_TYPE,
            PSY.SingleTimeSeries(;
                name = string(label),
                data = vec(array[label, :]),
                initial_timestamp = first(timestamps),
                resolution = resolution,
            ),
            features,
        )
    end
    return nothing
end

"""
Store one 3-D parameter array's realized values, one `SingleTimeSeries` per
`(axis-1 label, axis-2 label)` slice, the axis-2 label carried in the `"axis2"` feature.
Time is the last axis, matching PSI's HDF5 layout (`(label, label2, time)`). Delegates to the
2-D method per axis-2 slice; only the slice and the `"axis2"` feature differ.
"""
function write_parameter_array!(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey,
    array::JuMP.Containers.DenseAxisArray{<:Any, 3},
    timestamps::AbstractVector{Dates.DateTime},
    resolution::Dates.Period;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)
    for label2 in axes(array, 2)
        write_parameter_array!(
            store,
            key,
            array[:, label2, :],
            timestamps,
            resolution;
            extra_features = merge(
                extra_features, Dict{String, Any}("axis2" => string(label2)),
            ),
        )
    end
    return nothing
end

"""
The parameter-owner rows this store holds for `key` (further narrowed by `extra_features`, e.g.
`"model"`). Shared by every parameter reader below.
"""
_parameter_rows(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey,
    extra_features::Dict{String, <:Any},
) = IS.list_time_series_metadata(
    store.store;
    owner_id = PARAMETER_ROW_OWNER_ID,
    features = _parameter_key_features(key, extra_features),
)

"""
The distinct `"axis2"` feature values among this store's rows for `key` (further narrowed by
`extra_features`, e.g. `"model"`), sorted for a deterministic order. Empty for a 2-D parameter,
which carries no `"axis2"` feature on any of its rows -- a caller merging by slice treats that
as "merge once, with no axis2 filter" rather than iterating zero times.
"""
function parameter_slice_labels(
    store::ParameterTimeSeriesStore,
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

"""
Whether this store holds any parameter row for `key` (narrowed by `extra_features`).
"""
has_parameter_rows(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Bool = !isempty(_parameter_rows(store, key, extra_features))

"""
Read back every parameter array row this store holds for `key`, keyed by its axis-1 label.
"""
function read_parameter_array(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Dict{String, IS.TimeSeries.TimeArray}
    rows = _parameter_rows(store, key, extra_features)
    isempty(rows) &&
        error("no parameter arrays found for $key in this outputs store")
    result = Dict{String, IS.TimeSeries.TimeArray}()
    for md in rows
        ts = IS.get_time_series(store.store, IS.get_time_series_key(md))
        result[IS.get_name(md)] = IS.make_time_array(ts, IS.get_initial_timestamp(ts))
    end
    return result
end

function _check_parameter_windows(
    key::IOM.ParameterKey,
    windows::AbstractDict{Dates.DateTime, <:JuMP.Containers.DenseAxisArray{<:Any, 2}},
)
    isempty(windows) && error("no parameter windows given for $key")
    _, reference_window = first(windows)
    labels = axes(reference_window, 1)
    steps = length(axes(reference_window, 2))
    for (initial_time, window) in windows
        axes(window, 1) == labels || error(
            "parameter windows for $key do not share the same axis-1 labels: window at " *
            "$initial_time has $(collect(axes(window, 1))), expected $(collect(labels))",
        )
        length(axes(window, 2)) == steps || error(
            "parameter windows for $key do not share the same time-axis length: window " *
            "at $initial_time has $(length(axes(window, 2))) steps, expected $steps",
        )
    end
    return labels
end

"""
Store one parameter's realized per-execution windows under the synthetic parameter owner,
one `PSY.Deterministic` per axis-1 label, keyed by each window's initial time. Never
becomes a document row: it is read back through [`read_parameter_windows`](@ref).
"""
function write_parameter_windows!(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey,
    windows::AbstractDict{Dates.DateTime, <:JuMP.Containers.DenseAxisArray{<:Any, 2}},
    resolution::Dates.Period,
    interval::Dates.Period;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Nothing
    labels = _check_parameter_windows(key, windows)
    features = _parameter_key_features(key, extra_features)
    for label in labels
        data = Dict(
            initial_time => collect(vec(window[label, :])) for
            (initial_time, window) in windows
        )
        _add_row!(
            store,
            PARAMETER_ROW_OWNER_ID,
            PARAMETER_ROW_OWNER_TYPE,
            PSY.Deterministic(string(label), data, resolution, interval),
            features,
        )
    end
    return nothing
end

"""
Store one 3-D parameter window set. Not supported: a 3-D window has no `Deterministic`
counterpart in this store, so this errors naming the key rather than silently dropping
the third axis.
"""
function write_parameter_windows!(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey,
    windows::AbstractDict{Dates.DateTime, <:JuMP.Containers.DenseAxisArray{<:Any, 3}},
    resolution::Dates.Period,
    interval::Dates.Period;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Nothing
    error("3-D parameter windows are not stored: $key")
end

"""
Read back every parameter window row this store holds for `key`, keyed by its axis-1
label and then by each window's initial time.
"""
function read_parameter_windows(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Dict{String, Dict{Dates.DateTime, Vector{Float64}}}
    rows = _parameter_rows(store, key, extra_features)
    isempty(rows) &&
        error("no parameter windows found for $key in this outputs store")
    result = Dict{String, Dict{Dates.DateTime, Vector{Float64}}}()
    for md in rows
        ts = IS.get_time_series(store.store, IS.get_time_series_key(md))
        result[IS.get_name(md)] = Dict{Dates.DateTime, Vector{Float64}}(IS.get_data(ts))
    end
    return result
end

"""
Every `TimeSeriesKey` component `c`'s operation cost holds, or an empty vector for a
component type that carries no `operation_cost` field. One method per abstract type that
covers only components with an `operation_cost`; never `isa`/`hasfield` on `Component`.
"""
_cost_time_series_keys(::PSY.Component) = IS.TimeSeriesKey[]
_cost_time_series_keys(c::PSY.Storage) =
    PSY.get_time_series_keys(PSY.get_operation_cost(c))
_cost_time_series_keys(c::PSY.StaticInjectionSubsystem) =
    PSY.get_time_series_keys(PSY.get_operation_cost(c))
_cost_time_series_keys(c::PSY.ControllableLoad) =
    PSY.get_time_series_keys(PSY.get_operation_cost(c))
_cost_time_series_keys(c::PSY.ThermalGen) =
    PSY.get_time_series_keys(PSY.get_operation_cost(c))
_cost_time_series_keys(c::PSY.HydroGen) =
    PSY.get_time_series_keys(PSY.get_operation_cost(c))
_cost_time_series_keys(c::PSY.RenewableDispatch) =
    PSY.get_time_series_keys(PSY.get_operation_cost(c))
_cost_time_series_keys(c::PSY.Source) =
    PSY.get_time_series_keys(PSY.get_operation_cost(c))
_cost_time_series_keys(c::PSY.HydroReservoir) =
    PSY.get_time_series_keys(PSY.get_operation_cost(c))
_cost_time_series_keys(c::PSY.VirtualParticipant) =
    PSY.get_time_series_keys(PSY.get_operation_cost(c))

"""
An online/offline reserve's own `TimeSeriesKey`, when its operating-reserve-demand-curve
`variable` is time-series-backed, else none. A reserve's variable curve is not an
`operation_cost`, so it is not reached by the `PSY.get_time_series_keys(PSY.get_operation_cost(c))`
methods above; it is exported to the document the same way a device's cost is
(`PowerSystems.convert_cost_to_openapi` on the curve's `TimeSeriesFunctionData`), so it must be
copied here too or the exported document ends up with a dangling association id.
"""
function _cost_time_series_keys(c::Union{PSY.OnlineReserve, PSY.OfflineReserve})
    value_curve = PSY.get_value_curve(PSY.get_variable(c))
    IS.is_time_series_backed(value_curve) || return IS.TimeSeriesKey[]
    return IS.TimeSeriesKey[IS.get_time_series_key(value_curve)]
end

"""
The window grid a run realized: one forecast window per execution, `horizon_count` steps each.
Every forecast row in a bundle is shaped to this grid. InfraStore requires all forecasts sharing a
`(resolution, interval)` to agree on count, initial time and horizon, and the parameter rows
already have the run's shape, so the cost copies must take it too.
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

"""The per-step timestamps the first window in `windows` covers."""
_window_timestamps(windows::RunWindows) = collect(
    range(
        first(windows.initial_times);
        step = windows.resolution,
        length = windows.horizon_count,
    ),
)

"""
One window at the model's initial time. A standalone model has no execution interval; when its
`Settings` leave it unset the horizon stands in, which keeps a single window self-consistent.
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

"""
Copy a static series verbatim into `store`, under `c`'s own document id and type. No
`make_time_array` round trip: the original series object goes in as-is. Statics have no
cross-forecast compatibility constraint, so no re-windowing is needed.
"""
function _copy_cost_time_series!(
    store::ParameterTimeSeriesStore,
    c::PSY.Component,
    ::IS.TimeSeriesKey,
    ts::IS.StaticTimeSeries,
    ::RunWindows,
)::IS.TimeSeriesKey
    return _add_row!(store, c, ts)
end

"""
Re-window a forecast cost onto `windows`: one window per run execution, `horizon_count` steps
each, read starting at each of `windows.initial_times`.

A horizon under two steps cannot hold a re-windowed forecast (InfraStore's own floor; see
[`parameter_store_from_model`](@ref) for the identical constraint on parameter rows) — every
run this short writes no parameter rows either, so nothing downstream depends on this cost
sharing their grid, and the original series is copied verbatim instead. Skipping it outright
is not an option: `sys`'s own cost still points at the original series, and every reader of the
key map (`write_outputs_system_bundle!`'s `PSY.to_openapi` remap, `decision_model.jl`'s
`system_to_file` path) requires an entry for every association id `sys` still references.
"""
function _copy_cost_time_series!(
    store::ParameterTimeSeriesStore,
    c::PSY.Component,
    key::IS.TimeSeriesKey,
    ts::IS.Forecast,
    windows::RunWindows,
)::IS.TimeSeriesKey
    windows.horizon_count < 2 && return _add_row!(store, c, ts)
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
    return _add_row!(store, c, copy)
end

"""
Copy every time series a System component's operation cost holds into `store`, under that
component's own id and type, and return the map from each series' original
`association_id` to the association id it was written under.

Not derived from parameter arrays: start-up costs are 3-tuples, offer curves split into
slope/breakpoint arrays, and re-deriving a cost series from a parameter array risks a unit
mismatch. This copies the System's own series instead: statics verbatim, forecasts re-windowed
onto the run grid `windows` (or copied verbatim too, on a horizon too short to re-window).
"""
function copy_cost_time_series!(
    store::ParameterTimeSeriesStore,
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
Build a fresh [`ParameterTimeSeriesStore`](@ref) from `model`'s realized parameters and its
System's cost time series re-windowed to the run, plus every time-series parameter recast as
component-owned input series, ready for [`write_outputs_system_bundle!`](@ref).

Writes no parameter arrays, only warns, on a single-point time axis (e.g. `horizon =
Dates.Hour(1)`): `IS.SingleTimeSeries`, `NonSequentialTimeSeries`, and `Forecast` all require at
least two points at the InfraStore layer (R32: not something this store patches around). The
model's realized parameters stay readable through `OptimizationProblemOutputs`, only the exported
outputs bundle loses them.
"""
function parameter_store_from_model(
    model,
)::Tuple{ParameterTimeSeriesStore, Dict{Int64, Int64}}
    container = IOM.get_optimization_container(model)
    windows = run_windows(model)
    timestamps = _window_timestamps(windows)
    store = ParameterTimeSeriesStore()
    if length(timestamps) < 2
        @warn "$(typeof(model)) has a $(length(timestamps))-point time axis " *
              "($(Dates.canonicalize(windows.resolution * length(timestamps))) horizon); the " *
              "outputs bundle will carry no parameter rows because an InfraStore time series " *
              "needs at least two points. Parameters remain readable through " *
              "OptimizationProblemOutputs."
    else
        for (key, array) in IOM.read_parameters(container)
            write_parameter_array!(store, key, array, timestamps, windows.resolution)
        end
    end
    key_map = copy_cost_time_series!(store, IOM.get_system(model), windows)
    write_model_inputs!(store, IOM.get_system(model), container, windows)
    return store, key_map
end

"""
The association rows the System document declares: every row whose owner is a real component,
not the synthetic parameter-array owner. Parameter arrays and windows are the only series
written under [`PARAMETER_ROW_OWNER_ID`](@ref); every document-declared series (cost copies,
input rows) is written under its owning component's own id. Exported from the store that wrote
the arrays, so each row's `uri` names an array the store genuinely holds, and each
`association_id` is the one the catalog will answer for on load.
"""
function parameter_association_rows(store::ParameterTimeSeriesStore)
    rows = IS.openapi_time_series_association_rows(store.store)
    return filter(row -> row.value.owner_id != PARAMETER_ROW_OWNER_ID, rows)
end

"""
Write an outputs bundle: the System document plus the parameter store it points at.

The layout is PowerSystems' ordinary directory form, so `PSY.from_file(bundle_dir)` reads it
with no special casing and PowerAnalytics needs no changes. What differs from a normal bundle is
only *which* series the sidecar holds — the parameters the model used, not a second copy of the
System's original series — and that the sidecar keeps its catalog, so parameters the document
does not declare stay readable.

`key_map` sends each time-series-backed cost's `association_id` to the parameter series that
replaces it, so the restored System's costs resolve against the sidecar.

The store is persisted first and the rows exported from that same store, so every row names an
array already on disk.
"""
function write_outputs_system_bundle!(
    sys::PSY.System,
    store::ParameterTimeSeriesStore,
    key_map::AbstractDict{Int64, Int64},
    bundle_dir::AbstractString,
)
    mkpath(bundle_dir)
    sidecar = joinpath(bundle_dir, PSY.TIME_SERIES_FILE)
    IS.serialize(store.store, sidecar)
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
    PSY.PD.write_document(doc, joinpath(bundle_dir, PSY.SYSTEM_DOCUMENT_FILE))
    return nothing
end

"""
Build `model`'s outputs-system bundle at `sys_dir` and write it, unless one is already there —
re-solving into an existing directory must not rewrite the bundle.
"""
function _write_outputs_bundle!(model, sys::PSY.System, sys_dir::AbstractString)
    ispath(sys_dir) && return nothing
    store, key_map = parameter_store_from_model(model)
    write_outputs_system_bundle!(sys, store, key_map, sys_dir)
    close_parameter_store!(store)
    return nothing
end

"""
Marks a row the bundle writer derived from a model's realized parameter values. One marker only:
IS resolves a by-name read as a subset match on features, so a rebuild's plain
`get_time_series(Deterministic, component, name)` still finds the row, and the partition merge can
list every input row without knowing the parameter keys. No `parameter`/`model` feature here — two
parameters reading one series would make two rows and an ambiguous read.
"""
const INPUT_ROW_FEATURES = Dict{String, Any}("source" => "parameter")

"""
What one time-series parameter needs to come back as component series: the series name and type
the model read, and each parameter label's owner `(id, type name)`. Labels that are not components
of the System (network-reduction aggregates) are listed in `unresolved`; their values stay
readable through the parameter rows under the synthetic owner.
"""
struct InputSeriesDescriptor
    name::String
    time_series_type::Type
    owners::Dict{String, Tuple{Int64, String}}
    unresolved::Vector{String}
end

_is_input_attributes(::IOM.TimeSeriesAttributes) = true
_is_input_attributes(::IOM.ParameterAttributes) = false

"""
Whether `key`'s realized values are a component input series the bundle recasts. IOM only ever
pairs `TimeSeriesAttributes` with a `TimeSeriesParameter` key, so the attributes check alone
decides it.
"""
is_input_parameter(::IOM.ParameterKey, pc::IOM.ParameterContainer)::Bool =
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
            owners[name] = (IS.get_id(c), string(nameof(typeof(c))))
        else
            push!(unresolved, name)
        end
    end
    sort!(unresolved)
    isempty(unresolved) ||
        @warn "$(IOM.encode_key_as_string(key)): labels $(unresolved) " *
              "are not components of the System; their input series are not written to the " *
              "bundle (values remain in the parameter rows)."
    return InputSeriesDescriptor(
        IOM.get_time_series_name(attributes),
        IOM.get_time_series_type(attributes),
        owners,
        unresolved,
    )
end

"""
Whether this store already has an input row for `(owner_id, name)` of exactly `T`. Scoped by
type, not just `(owner, name)`: a `Deterministic` input row (decision models) and a
`SingleTimeSeries` input row (the emulation model) are different series derived from the same
underlying source, and a shared bundle -- the Emulator aggregator borrows a decision model's
bundle when it has none of its own -- can legitimately hold one of each for the same owner and
name. Scoping the existence check by type keeps them from colliding under write-once.
"""
_input_row_exists(
    store::ParameterTimeSeriesStore,
    ::Type{T},
    owner_id::Int64,
    name::String,
) where {T <: IS.TimeSeriesData} =
    !isempty(
        IS.list_time_series_metadata(
            store.store; owner_id = owner_id, name = name, time_series_type = T,
            features = INPUT_ROW_FEATURES,
        ),
    )

"""
Add one component-owned `Deterministic` input row, declared in the document. Returns `false`
without writing when this `(owner, name)` already has a `Deterministic` input row: two
parameters may read the same series, and a re-merge may see rows it wrote before.
"""
function write_input_forecast_row!(
    store::ParameterTimeSeriesStore,
    owner_id::Int64,
    owner_type::String,
    name::String,
    data::AbstractDict{Dates.DateTime, <:AbstractVector},
    resolution::Dates.Period,
    interval::Dates.Period,
)::Bool
    _input_row_exists(store, PSY.Deterministic, owner_id, name) && return false
    _add_row!(
        store,
        owner_id,
        owner_type,
        PSY.Deterministic(name, Dict(data), resolution, interval),
        INPUT_ROW_FEATURES,
    )
    return true
end

"""
Static counterpart of [`write_input_forecast_row!`](@ref), for emulation models. Returns `false`
without writing when this `(owner, name)` already has a `SingleTimeSeries` input row -- a
`Deterministic` input row for the same `(owner, name)` (e.g. a decision model's, in a bundle the
Emulator aggregator borrows) does not block this write; see [`_input_row_exists`](@ref).
"""
function write_input_series_row!(
    store::ParameterTimeSeriesStore,
    owner_id::Int64,
    owner_type::String,
    name::String,
    values::AbstractVector{Float64},
    initial_timestamp::Dates.DateTime,
    resolution::Dates.Period,
)::Bool
    _input_row_exists(store, PSY.SingleTimeSeries, owner_id, name) && return false
    _add_row!(
        store,
        owner_id,
        owner_type,
        PSY.SingleTimeSeries(;
            name = name,
            data = collect(values),
            initial_timestamp = initial_timestamp,
            resolution = resolution,
        ),
        INPUT_ROW_FEATURES,
    )
    return true
end

"""
One `Deterministic` per resolved label, its windows sliced from `windows` (each a
`(label, time)` array keyed by the execution's initial time).
"""
function write_input_forecasts!(
    store::ParameterTimeSeriesStore,
    d::InputSeriesDescriptor,
    windows::AbstractDict{Dates.DateTime, <:JuMP.Containers.DenseAxisArray{Float64, 2}},
    resolution::Dates.Period,
    interval::Dates.Period,
)
    for (label, (owner_id, owner_type)) in d.owners
        data = Dict(t => collect(vec(w[label, :])) for (t, w) in windows)
        write_input_forecast_row!(
            store,
            owner_id,
            owner_type,
            d.name,
            data,
            resolution,
            interval,
        )
    end
    return nothing
end

"""One `SingleTimeSeries` per resolved label, from a `(label, time)` array."""
function write_input_series!(
    store::ParameterTimeSeriesStore,
    d::InputSeriesDescriptor,
    array::JuMP.Containers.DenseAxisArray{Float64, 2},
    timestamps::AbstractVector{Dates.DateTime},
    resolution::Dates.Period,
)
    for (label, (owner_id, owner_type)) in d.owners
        write_input_series_row!(
            store, owner_id, owner_type, d.name, vec(array[label, :]), first(timestamps),
            resolution,
        )
    end
    return nothing
end

_write_input!(
    store::ParameterTimeSeriesStore,
    ::Type{<:IS.Forecast},
    d::InputSeriesDescriptor,
    raw::JuMP.Containers.DenseAxisArray{Float64, 2},
    windows::RunWindows,
) = write_input_forecasts!(
    store, d, Dict(first(windows.initial_times) => raw), windows.resolution,
    windows.interval,
)

_write_input!(
    store::ParameterTimeSeriesStore,
    ::Type{<:IS.StaticTimeSeries},
    d::InputSeriesDescriptor,
    raw::JuMP.Containers.DenseAxisArray{Float64, 2},
    windows::RunWindows,
) = write_input_series!(store, d, raw, _window_timestamps(windows), windows.resolution)

"""A 3-D parameter has no input-series counterpart in this store; warn and skip it."""
function _write_input!(
    ::ParameterTimeSeriesStore,
    ::Type{<:IS.TimeSeriesData},
    d::InputSeriesDescriptor,
    ::JuMP.Containers.DenseAxisArray{Float64, 3},
    ::RunWindows,
)
    @warn "input series \"$(d.name)\" comes from a 3-D parameter array; not recast into the bundle"
    return nothing
end

"""
Recast every time-series parameter of a standalone model as component-owned input series, one
window at the model's initial time. Skips a horizon under two steps: InfraStore needs at least two
points per series, and [`parameter_store_from_model`](@ref) already warned about it.
"""
function write_model_inputs!(
    store::ParameterTimeSeriesStore,
    sys::PSY.System,
    container::IOM.OptimizationContainer,
    windows::RunWindows,
)
    windows.horizon_count < 2 && return nothing
    for (key, pc) in IOM.get_parameters(container)
        is_input_parameter(key, pc) || continue
        d = input_series_descriptor(sys, key, pc)
        _write_input!(store, d.time_series_type, d, IOM.get_parameter_values(pc), windows)
    end
    return nothing
end

"""Every input row this store holds, any owner — the rows carrying [`INPUT_ROW_FEATURES`](@ref)."""
list_input_series(store::ParameterTimeSeriesStore) =
    IS.list_time_series_metadata(store.store; features = INPUT_ROW_FEATURES)

"""The series behind one input row."""
read_input_time_series(store::ParameterTimeSeriesStore, md::IS.TimeSeriesMetadata) =
    IS.get_time_series(store.store, IS.get_time_series_key(md))
