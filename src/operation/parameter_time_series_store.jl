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
