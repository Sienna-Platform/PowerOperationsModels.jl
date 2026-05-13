"""Typed container for export configuration parameters used during model output writing."""
struct ExportParameters{E}
    exports::E
    exports_path::String
    file_type::Type
    resolution::Dates.Millisecond
    horizon_count::Int
end

function _export_container_output!(
    export_params::ExportParameters,
    exports_path,
    key,
    index,
    data,
)
    df = to_dataframe(data, key)
    time_col =
        range(index; length = export_params.horizon_count, step = export_params.resolution)
    DataFrames.insertcols!(df, 1, :DateTime => time_col)
    ISOPT.export_output(export_params.file_type, exports_path, key, index, df)
    return
end

"""Sanitize a model name for use as a filesystem path component.
Replaces path separators, null bytes, and control characters with underscores."""
function _sanitize_model_name(name::AbstractString)
    _is_path_safe(c::AbstractChar) =
        isprint(c) && c ∉ ('/', '\\', ':', '*', '?', '"', '<', '>', '|')
    sanitized = map(c -> _is_path_safe(c) ? c : '_', name)
    if isempty(sanitized) || sanitized == "." || sanitized == ".."
        throw(
            IS.InvalidValue("Model name '$name' is not valid for use as a path component"),
        )
    end
    return sanitized
end

# Aliases used for clarity in the method dispatches so it is possible to know if writing to
# DecisionModel data or EmulationModel data
# Note: DecisionModelIndexType and EmulationModelIndexType are defined in core/definitions.jl

function write_outputs!(
    store::AbstractModelStore,
    model::OperationModel,
    index::Union{DecisionModelIndexType, EmulationModelIndexType},
    update_timestamp::Dates.DateTime;
    exports = nothing,
)
    if exports !== nothing
        export_params = ExportParameters(
            exports,
            joinpath(exports.path, _sanitize_model_name(string(get_name(model)))),
            get_export_file_type(exports),
            get_resolution(model),
            get_horizon(get_settings(model)) ÷ get_resolution(model),
        )
    else
        export_params = nothing
    end

    write_model_dual_outputs!(store, model, index, update_timestamp, export_params)
    write_model_parameter_outputs!(store, model, index, update_timestamp, export_params)
    write_model_variable_outputs!(store, model, index, update_timestamp, export_params)
    write_model_aux_variable_outputs!(store, model, index, update_timestamp, export_params)
    write_model_expression_outputs!(store, model, index, update_timestamp, export_params)
    return
end

function write_model_dual_outputs!(
    store,
    model::T,
    index::Union{DecisionModelIndexType, EmulationModelIndexType},
    update_timestamp::Dates.DateTime,
    export_params::Union{ExportParameters, Nothing},
) where {T <: OperationModel}
    container = get_optimization_container(model)
    model_name = get_name(model)
    if export_params !== nothing
        exports_path = joinpath(export_params.exports_path, "duals")
        mkpath(exports_path)
    end

    for (key, constraint) in get_duals(container)
        !should_write_resulting_value(key) && continue
        data = jump_value.(constraint)
        write_output!(store, model_name, key, index, update_timestamp, data)

        if export_params !== nothing &&
           should_export_dual(export_params.exports, update_timestamp, model_name, key)
            _export_container_output!(export_params, exports_path, key, index, data)
        end
    end
    return
end

function write_model_parameter_outputs!(
    store,
    model::T,
    index::Union{DecisionModelIndexType, EmulationModelIndexType},
    update_timestamp::Dates.DateTime,
    export_params::Union{ExportParameters, Nothing},
) where {T <: OperationModel}
    container = get_optimization_container(model)
    model_name = get_name(model)
    if export_params !== nothing
        exports_path = joinpath(export_params.exports_path, "parameters")
        mkpath(exports_path)
    end

    parameters = get_parameters(container)
    for (key, param_container) in parameters
        !should_write_resulting_value(key) && continue
        data = calculate_parameter_values(param_container)
        write_output!(store, model_name, key, index, update_timestamp, data)

        if export_params !== nothing &&
           should_export_parameter(
            export_params.exports,
            update_timestamp,
            model_name,
            key,
        )
            _export_container_output!(export_params, exports_path, key, index, data)
        end
    end
    return
end

function write_model_variable_outputs!(
    store,
    model::T,
    index::Union{DecisionModelIndexType, EmulationModelIndexType},
    update_timestamp::Dates.DateTime,
    export_params::Union{ExportParameters, Nothing},
) where {T <: OperationModel}
    container = get_optimization_container(model)
    model_name = get_name(model)
    if export_params !== nothing
        exports_path = joinpath(export_params.exports_path, "variables")
        mkpath(exports_path)
    end

    if !isempty(container.primal_values_cache)
        variables = container.primal_values_cache.variables_cache
    else
        variables = get_variables(container)
    end

    for (key, variable) in variables
        !should_write_resulting_value(key) && continue
        data = jump_value.(variable)
        write_output!(store, model_name, key, index, update_timestamp, data)

        if export_params !== nothing &&
           should_export_variable(
            export_params.exports,
            update_timestamp,
            model_name,
            key,
        )
            _export_container_output!(export_params, exports_path, key, index, data)
        end
    end
    return
end

function write_model_aux_variable_outputs!(
    store,
    model::T,
    index::Union{DecisionModelIndexType, EmulationModelIndexType},
    update_timestamp::Dates.DateTime,
    export_params::Union{ExportParameters, Nothing},
) where {T <: OperationModel}
    container = get_optimization_container(model)
    model_name = get_name(model)
    if export_params !== nothing
        exports_path = joinpath(export_params.exports_path, "aux_variables")
        mkpath(exports_path)
    end

    for (key, variable) in get_aux_variables(container)
        !should_write_resulting_value(key) && continue
        data = jump_value.(variable)
        write_output!(store, model_name, key, index, update_timestamp, data)

        if export_params !== nothing &&
           should_export_aux_variable(
            export_params.exports,
            update_timestamp,
            model_name,
            key,
        )
            _export_container_output!(export_params, exports_path, key, index, data)
        end
    end
    return
end

function write_model_expression_outputs!(
    store,
    model::T,
    index::Union{DecisionModelIndexType, EmulationModelIndexType},
    update_timestamp::Dates.DateTime,
    export_params::Union{ExportParameters, Nothing},
) where {T <: OperationModel}
    container = get_optimization_container(model)
    model_name = get_name(model)
    if export_params !== nothing
        exports_path = joinpath(export_params.exports_path, "expressions")
        mkpath(exports_path)
    end

    if !isempty(container.primal_values_cache)
        expressions = container.primal_values_cache.expressions_cache
    else
        expressions = get_expressions(container)
    end

    for (key, expression) in expressions
        !should_write_resulting_value(key) && continue
        data = jump_value.(expression)
        write_output!(store, model_name, key, index, update_timestamp, data)

        if export_params !== nothing &&
           should_export_expression(
            export_params.exports,
            update_timestamp,
            model_name,
            key,
        )
            _export_container_output!(export_params, exports_path, key, index, data)
        end
    end
    return
end
