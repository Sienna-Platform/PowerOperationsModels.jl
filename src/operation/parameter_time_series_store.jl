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

Parameters are written here rather than into a results dataset so the bundle carries a real
InfraStore store. The System document's association rows are exported from this same store,
which is what makes every `uri` resolve on read — InfraStore refuses a catalog row naming an
array it does not hold.

This is the only place in PowerOperationsModels or PowerSimulations that knows InfraStore exists.
"""
struct ParameterTimeSeriesStore
    store::IS.Store
    document_association_ids::Set{Int64}
end

"""A fresh, writable, in-memory parameter store."""
ParameterTimeSeriesStore() =
    ParameterTimeSeriesStore(IS.Store(; in_memory = true), Set{Int64}())

"""
Persist the store — arrays and catalog — to `path` (`path` and `path.sqlite`).

The catalog is kept so parameters the System document does not mention (feedforward values,
scalar-built costs) stay readable after reopen.
"""
function persist_parameter_store!(store::ParameterTimeSeriesStore, path::AbstractString)
    IS.serialize(store.store, path)
    return nothing
end

"""Reopen a persisted parameter store with its catalog."""
function open_parameter_store(path::AbstractString)
    return ParameterTimeSeriesStore(IS.open_infrastore_store(path), Set{Int64}())
end

"""
Reopen a persisted parameter store writable in place, so later `write_parameter_*` calls
land directly in the on-disk `.h5`/`.sqlite` pair with no re-persist.

An alias of [`open_parameter_store`](@ref): `IS.open_infrastore_store` already opens its
artifacts in place, writable, by default (`read_only = false`, `catalog = :attached`). The
copy-to-a-temp-location path lives in a different function
(`open_deserialized_infrastore_store`), used only for deserialized `System` artifacts, and
this store never goes through it.
"""
open_parameter_store_writable(path::AbstractString) = open_parameter_store(path)

"""
A borrowed view of a `System`'s own already-open store -- for a caller that already has this
bundle's System loaded (e.g. via `PSY.from_file(...; time_series_read_only = true)`) and wants
to read its realized parameters without opening a second handle to the same sidecar file
(InfraStore allows only one open handle per file per process).

The caller must **not** [`close_parameter_store!`](@ref) the result: the underlying store is
owned by `sys`'s own time series manager, which opened it and will close it.
"""
parameter_store_of(sys::PSY.System) =
    ParameterTimeSeriesStore(IS.get_data_store(sys.data), Set{Int64}())

function close_parameter_store!(store::ParameterTimeSeriesStore)
    IS.close!(store.store)
    return nothing
end

"""
Store one parameter's realized series and return its key.

`owner_id` must be the owner's **document id** — the same id the System document gives that
component — or the row will not attach to anything on read.

`in_document` marks this series as one the System document declares: its `association_id` is
recorded so [`parameter_association_rows`](@ref) exports a catalog row for it. A series written
with `in_document = false` (the default) is still stored and readable — a feedforward value or a
scalar-built cost belongs in the store without becoming a document row.
"""
function write_parameter_series!(
    store::ParameterTimeSeriesStore,
    owner_id::Int,
    owner_type::AbstractString,
    name::AbstractString,
    data::IS.TimeSeries.TimeArray;
    in_document::Bool = false,
)
    key = IS.add_time_series!(
        store.store,
        owner_id,
        String(owner_type),
        IS.get_owner_category(IS.InfrastructureSystemsComponent),
        PSY.SingleTimeSeries(String(name), data),
    )
    _record_document_association!(store, key, in_document)
    return key
end

"""
Record `key`'s association id so [`parameter_association_rows`](@ref) exports a catalog row
for it. Shared by every path that writes a document-declared series, so the bookkeeping lives
in one place regardless of which `IS.add_time_series!` method wrote the row.
"""
function _record_document_association!(
    store::ParameterTimeSeriesStore,
    key::IS.TimeSeriesKey,
    in_document::Bool,
)
    in_document && push!(store.document_association_ids, IS.get_association_id(key))
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
        IS.add_time_series!(
            store.store,
            PARAMETER_ROW_OWNER_ID,
            PARAMETER_ROW_OWNER_TYPE,
            IS.get_owner_category(IS.InfrastructureSystemsComponent),
            PSY.SingleTimeSeries(;
                name = string(label),
                data = vec(array[label, :]),
                initial_timestamp = first(timestamps),
                resolution = resolution,
            );
            features = features,
        )
    end
    return nothing
end

"""
Store one 3-D parameter array's realized values, one `SingleTimeSeries` per
`(axis-1 label, axis-2 label)` slice, the axis-2 label carried in the `"axis2"` feature.
Time is the last axis, matching PSI's HDF5 layout (`(label, label2, time)`).

`resolution` is passed explicitly for the same reason as the 2-D method above.
"""
function write_parameter_array!(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey,
    array::JuMP.Containers.DenseAxisArray{<:Any, 3},
    timestamps::AbstractVector{Dates.DateTime},
    resolution::Dates.Period;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)
    labels = axes(array, 1)
    labels2 = axes(array, 2)
    _check_parameter_array_length(key, length(axes(array, 3)), length(timestamps))
    base_features = _parameter_key_features(key, extra_features)
    for label2 in labels2, label in labels
        features = merge(base_features, Dict{String, Any}("axis2" => string(label2)))
        IS.add_time_series!(
            store.store,
            PARAMETER_ROW_OWNER_ID,
            PARAMETER_ROW_OWNER_TYPE,
            IS.get_owner_category(IS.InfrastructureSystemsComponent),
            PSY.SingleTimeSeries(;
                name = string(label),
                data = vec(array[label, label2, :]),
                initial_timestamp = first(timestamps),
                resolution = resolution,
            );
            features = features,
        )
    end
    return nothing
end

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
    features = _parameter_key_features(key, extra_features)
    rows = IS.list_time_series_metadata(
        store.store; owner_id = PARAMETER_ROW_OWNER_ID, features = features,
    )
    slice_labels = Set{String}()
    for md in rows
        row_features = IS.get_features(md)
        haskey(row_features, "axis2") && push!(slice_labels, string(row_features["axis2"]))
    end
    return sort!(collect(slice_labels))
end

"""
Whether this store holds any parameter row for `key` (narrowed by `extra_features`).
"""
function has_parameter_rows(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Bool
    features = _parameter_key_features(key, extra_features)
    rows = IS.list_time_series_metadata(
        store.store; owner_id = PARAMETER_ROW_OWNER_ID, features = features,
    )
    return !isempty(rows)
end

"""
Read back every parameter array row this store holds for `key`, keyed by its axis-1 label.
"""
function read_parameter_array(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey;
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)::Dict{String, IS.TimeSeries.TimeArray}
    features = _parameter_key_features(key, extra_features)
    rows = IS.list_time_series_metadata(
        store.store; owner_id = PARAMETER_ROW_OWNER_ID, features = features,
    )
    isempty(rows) &&
        error("no parameter arrays found for $key in this results store")
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
        IS.add_time_series!(
            store.store,
            PARAMETER_ROW_OWNER_ID,
            PARAMETER_ROW_OWNER_TYPE,
            IS.get_owner_category(IS.InfrastructureSystemsComponent),
            PSY.Deterministic(string(label), data, resolution, interval);
            features = features,
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
    features = _parameter_key_features(key, extra_features)
    rows = IS.list_time_series_metadata(
        store.store; owner_id = PARAMETER_ROW_OWNER_ID, features = features,
    )
    isempty(rows) &&
        error("no parameter windows found for $key in this results store")
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
Copy a series verbatim into `store`, under `c`'s own document id and type. No
`make_time_array` round trip: the original series object goes in as-is. The store-level
`IS.add_time_series!` dispatches on `ts` itself (static vs. forecast), so one method
covers both.
"""
function _copy_cost_time_series!(
    store::ParameterTimeSeriesStore,
    c::PSY.Component,
    ts::IS.TimeSeriesData,
)::IS.TimeSeriesKey
    return IS.add_time_series!(
        store.store,
        IS.get_id(c),
        string(nameof(typeof(c))),
        IS.get_owner_category(IS.InfrastructureSystemsComponent),
        ts,
    )
end

"""
Copy every time series a System component's operation cost holds into `store`, under that
component's own id and type, and return the map from each series' original
`association_id` to the association id it was written under.

Not derived from parameter arrays: start-up costs are 3-tuples, offer curves split into
slope/breakpoint arrays, and re-deriving a cost series from a parameter array risks a unit
mismatch. This copies the System's own series verbatim instead, keeping every forecast window
and the original series type.
"""
function copy_cost_time_series!(
    store::ParameterTimeSeriesStore,
    sys::PSY.System,
)::Dict{Int64, Int64}
    key_map = Dict{Int64, Int64}()
    for c in PSY.get_components(PSY.Component, sys)
        for key in _cost_time_series_keys(c)
            original_id = IS.get_association_id(key)
            haskey(key_map, original_id) && continue
            ts = IS.get_time_series(c, key)
            new_key = _copy_cost_time_series!(store, c, ts)
            _record_document_association!(store, new_key, true)
            key_map[original_id] = IS.get_association_id(new_key)
        end
    end
    return key_map
end

"""
Write every realized parameter array into `store`, or none of them. `IS.SingleTimeSeries`,
`NonSequentialTimeSeries`, and `Forecast` all require at least two points at the InfraStore
layer (R32: not something this store patches around), so a model whose time axis has a single
step (e.g. `horizon = Dates.Hour(1)`) cannot store a single parameter row. Warning once here,
rather than letting [`write_parameter_array!`](@ref) error once per key, is the loud-but-not-fatal
choice: the model's realized parameters stay readable through `OptimizationProblemOutputs`, only
the exported results bundle loses them.
"""
function _write_parameter_arrays!(
    store::ParameterTimeSeriesStore,
    params,
    timestamps::AbstractVector{Dates.DateTime},
    resolution::Dates.Period,
    model_type_name::AbstractString,
)
    if length(timestamps) < 2
        @warn "$model_type_name has a $(length(timestamps))-point time axis " *
              "($(Dates.canonicalize(resolution * length(timestamps))) horizon); the results " *
              "bundle will carry no parameter rows because an InfraStore time series needs at " *
              "least two points. Parameters remain readable through OptimizationProblemOutputs."
        return nothing
    end
    for (key, array) in params
        write_parameter_array!(store, key, array, timestamps, resolution)
    end
    return nothing
end

"""
Build a fresh [`ParameterTimeSeriesStore`](@ref) from `model`'s realized parameters and its
System's cost time series, ready for [`write_results_system_bundle!`](@ref).
"""
function parameter_store_from_model(
    model,
)::Tuple{ParameterTimeSeriesStore, Dict{Int64, Int64}}
    container = IOM.get_optimization_container(model)
    resolution = IOM.get_resolution(container)
    timestamps = collect(
        range(
            IOM.get_initial_time(container);
            step = resolution,
            length = length(IOM.get_time_steps(container)),
        ),
    )
    store = ParameterTimeSeriesStore()
    _write_parameter_arrays!(
        store,
        IOM.read_parameters(container),
        timestamps,
        resolution,
        string(typeof(model)),
    )
    key_map = copy_cost_time_series!(store, IOM.get_system(model))
    return store, key_map
end

"""
Unwrap an OpenAPI `oneOf` wrapper to the concrete row it carries. Association rows come back
from InfraStore as `oneOf` wrappers whose `.value` holds the type-specific struct; this
recurses so a plain (already-unwrapped) row passes through unchanged.
"""
_unwrap_oneof(row::IC.OneOfAPIModel) = _unwrap_oneof(row.value)
_unwrap_oneof(row) = row

"""
The association rows the System document declares: only the series written with
`in_document = true`. Exported from the store that wrote the arrays, so each row's `uri` names
an array the store genuinely holds, and each `association_id` is the one the catalog will
answer for on load.
"""
function parameter_association_rows(store::ParameterTimeSeriesStore)
    rows = IS.openapi_time_series_association_rows(store.store)
    return filter(
        row -> _unwrap_oneof(row).association_id in store.document_association_ids,
        rows,
    )
end

"""Read back a series this store holds, by owner id and name."""
function read_parameter_series(
    store::ParameterTimeSeriesStore,
    owner_id::Int,
    name::AbstractString,
)
    rows =
        IS.list_time_series_metadata(store.store; owner_id = owner_id, name = String(name))
    isempty(rows) && error(
        "no parameter series named \"$name\" for owner id $owner_id in this results store",
    )
    ts = IS.get_time_series(store.store, IS.get_time_series_key(only(rows)))
    return IS.make_time_array(ts, IS.get_initial_timestamp(ts))
end

"""
Write a results bundle: the System document plus the parameter store it points at.

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
function write_results_system_bundle!(
    sys::PSY.System,
    store::ParameterTimeSeriesStore,
    key_map::AbstractDict{Int64, Int64},
    bundle_dir::AbstractString,
)
    mkpath(bundle_dir)
    sidecar = joinpath(bundle_dir, PSY.TIME_SERIES_FILE)
    persist_parameter_store!(store, sidecar)
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
