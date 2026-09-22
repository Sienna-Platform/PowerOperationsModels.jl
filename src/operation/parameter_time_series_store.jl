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
end

"""A fresh, writable, in-memory parameter store."""
ParameterTimeSeriesStore() = ParameterTimeSeriesStore(IS.Store(; in_memory = true))

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
    return ParameterTimeSeriesStore(IS.open_infrastore_store(path))
end

function close_parameter_store!(store::ParameterTimeSeriesStore)
    IS.close!(store.store)
    return nothing
end

"""
Store one parameter's realized series and return its key.

`owner_id` must be the owner's **document id** — the same id the System document gives that
component — or the row will not attach to anything on read.
"""
function write_parameter_series!(
    store::ParameterTimeSeriesStore,
    owner_id::Int,
    owner_type::AbstractString,
    name::AbstractString,
    data::IS.TimeSeries.TimeArray,
)
    return IS.add_time_series!(
        store.store,
        owner_id,
        String(owner_type),
        IS.get_owner_category(IS.InfrastructureSystemsComponent),
        PSY.SingleTimeSeries(String(name), data),
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
