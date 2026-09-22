"""
The owner id every parameter array row is written under. No component ever holds this id, so a
parameter row never shows up in a restored component's own `list_time_series_metadata`.
"""
const PARAMETER_ROW_OWNER_ID = -1
const PARAMETER_ROW_OWNER_TYPE = "OptimizationParameter"
"""Feature key carrying the encoded `IOM.ParameterKey` a parameter row belongs to."""
const PARAMETER_KEY_FEATURE = "parameter"

"""
A synthetic, non-domain `IS.InfrastructureSystemsComponent`. It exists only to satisfy
`IS`'s time-series-owner interface for a parameter forecast row: a forecast must go
through `IS.TimeSeriesManager`'s owner-typed `add_time_series!`, which validates window
parameters against the rest of the store, whereas the bare owner-id path
[`write_parameter_array!`](@ref) uses accepts only static series. No instance of this
type is ever attached to a `SystemData`; it carries [`PARAMETER_ROW_OWNER_ID`](@ref)
through that call and nothing else.
"""
struct OptimizationParameter <: IS.InfrastructureSystemsComponent
    internal::IS.InfrastructureSystemsInternal
end

OptimizationParameter() =
    OptimizationParameter(IS.InfrastructureSystemsInternal(; id = PARAMETER_ROW_OWNER_ID))

IS.supports_time_series(::OptimizationParameter) = true

const PARAMETER_ROW_OWNER = OptimizationParameter()

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
    if in_document
        push!(store.document_association_ids, IS.get_association_id(key))
    end
    return key
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
"""
function write_parameter_array!(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey,
    array::JuMP.Containers.DenseAxisArray{<:Any, 2},
    timestamps::AbstractVector{Dates.DateTime};
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)
    labels = axes(array, 1)
    _check_parameter_array_length(key, length(axes(array, 2)), length(timestamps))
    features = _parameter_key_features(key, extra_features)
    for label in labels
        data = IS.TimeSeries.TimeArray(timestamps, vec(array[label, :]))
        IS.add_time_series!(
            store.store,
            PARAMETER_ROW_OWNER_ID,
            PARAMETER_ROW_OWNER_TYPE,
            IS.get_owner_category(IS.InfrastructureSystemsComponent),
            PSY.SingleTimeSeries(string(label), data);
            features = features,
        )
    end
    return nothing
end

"""
Store one 3-D parameter array's realized values, one `SingleTimeSeries` per
`(axis-1 label, axis-3 label)` slice, the axis-3 label carried in the `"axis3"` feature.
"""
function write_parameter_array!(
    store::ParameterTimeSeriesStore,
    key::IOM.ParameterKey,
    array::JuMP.Containers.DenseAxisArray{<:Any, 3},
    timestamps::AbstractVector{Dates.DateTime};
    extra_features::Dict{String, <:Any} = Dict{String, Any}(),
)
    labels = axes(array, 1)
    labels3 = axes(array, 3)
    _check_parameter_array_length(key, length(axes(array, 2)), length(timestamps))
    base_features = _parameter_key_features(key, extra_features)
    for label3 in labels3, label in labels
        features = merge(base_features, Dict{String, Any}("axis3" => string(label3)))
        data = IS.TimeSeries.TimeArray(timestamps, vec(array[label, :, label3]))
        IS.add_time_series!(
            store.store,
            PARAMETER_ROW_OWNER_ID,
            PARAMETER_ROW_OWNER_TYPE,
            IS.get_owner_category(IS.InfrastructureSystemsComponent),
            PSY.SingleTimeSeries(string(label), data);
            features = features,
        )
    end
    return nothing
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
        ts = IS._infrastore_read_key(store.store, IS.get_time_series_key(md))
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
    mgr = IS.TimeSeriesManager(store.store, false)
    for label in labels
        data = Dict(
            initial_time => collect(vec(window[label, :])) for
            (initial_time, window) in windows
        )
        IS.add_time_series!(
            mgr,
            PARAMETER_ROW_OWNER,
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
        ts = IS._infrastore_read_key(store.store, IS.get_time_series_key(md))
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
Copy every time series a System component's operation cost holds into `store`, under that
component's own id and type, and return the map from each series' original
`association_id` to the association id it was written under.

Not derived from parameter arrays: start-up costs are 3-tuples, offer curves split into
slope/breakpoint arrays, and re-deriving a cost series from a parameter array risks a unit
mismatch. This copies the System's own series verbatim instead.
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
            data = IS.make_time_array(ts, IS.get_initial_timestamp(ts))
            new_key = write_parameter_series!(
                store, IS.get_id(c), string(nameof(typeof(c))), IS.get_name(ts), data;
                in_document = true,
            )
            key_map[original_id] = IS.get_association_id(new_key)
        end
    end
    return key_map
end

"""
Build a fresh [`ParameterTimeSeriesStore`](@ref) from `model`'s realized parameters and its
System's cost time series, ready for [`write_results_system_bundle!`](@ref).
"""
function parameter_store_from_model(
    model,
)::Tuple{ParameterTimeSeriesStore, Dict{Int64, Int64}}
    container = IOM.get_optimization_container(model)
    timestamps = collect(
        range(
            IOM.get_initial_time(container);
            step = IOM.get_resolution(container),
            length = length(IOM.get_time_steps(container)),
        ),
    )
    store = ParameterTimeSeriesStore()
    for (key, array) in IOM.read_parameters(container)
        write_parameter_array!(store, key, array, timestamps)
    end
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
    ts = IS._infrastore_read_key(store.store, IS.get_time_series_key(only(rows)))
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
