"""
    mutable struct OptimizationProblemOutputs <: Outputs

Container for the outputs of an optimization problem, including variable values, dual values,
parameter values, expression values, and optimizer statistics.

This type stores all output data from solving an optimization problem and provides methods
to read, export, and serialize the outputs. Instead of accessing the output dictionary
fields directly, use the `read_foo` functions.

# Fields
- `base_power::Float64`: Base power used for per-unit conversion
- `timestamps::Vector{Dates.DateTime}`: Time stamps for each step in the outputs
- `source_data::Union{Nothing, InfrastructureSystemsType}`: Reference to the source data (e.g., system)
- `source_data_uuid::Base.UUID`: UUID of the source data for validation. Internal usage.
- `aux_variable_values::Dict{AuxVarKey, DataFrame}`: Auxiliary variable outputs. See [`read_aux_variable`](@ref) and [`read_aux_variables`](@ref)
- `variable_values::Dict{VariableKey, DataFrame}`: Decision variable outputs. See [`read_variable`](@ref) and [`read_variables`](@ref)
- `dual_values::Dict{ConstraintKey, DataFrame}`: Dual outputs. See [`read_dual`](@ref) and [`read_duals`](@ref)
- `parameter_values::Dict{ParameterKey, DataFrame}`: Parameter outputs. See [`read_parameter`](@ref) and [`read_parameters`](@ref)
- `expression_values::Dict{ExpressionKey, DataFrame}`: Expression outputs. See [`read_expression`](@ref) and [`read_expressions`](@ref)
- `optimizer_stats::DataFrame`: Optimizer statistics for each solve
- `optimization_container_metadata::OptimizationContainerMetadata`: Metadata about the optimization container. Internal usage.
- `model_type::String`: Type of optimization model. Internal usage.
- `outputs_dir::String`: Directory where outputs are stored
- `output_dir::String`: Directory for exported output

See also: [`OptimizerStats`](@ref), [`OptimizationProblemOutputsExport`](@ref)
"""
mutable struct OptimizationProblemOutputs <: Outputs
    base_power::Float64
    timestamps::Vector{Dates.DateTime}
    source_data::Union{Nothing, InfrastructureSystemsType}
    source_data_uuid::Base.UUID
    aux_variable_values::Dict{AuxVarKey, DataFrame}
    variable_values::Dict{VariableKey, DataFrame}
    dual_values::Dict{ConstraintKey, DataFrame}
    parameter_values::Dict{ParameterKey, DataFrame}
    expression_values::Dict{ExpressionKey, DataFrame}
    optimizer_stats::DataFrame
    optimization_container_metadata::OptimizationContainerMetadata
    model_type::String
    outputs_dir::String
    output_dir::String
end

function OptimizationProblemOutputs(
    base_power,
    timestamps::StepRange{Dates.DateTime, Dates.Millisecond},
    source_data,
    source_data_uuid,
    aux_variable_values,
    variable_values,
    dual_values,
    parameter_values,
    expression_values,
    optimizer_stats,
    optimization_container_metadata,
    model_type,
    outputs_dir,
    output_dir,
)
    return OptimizationProblemOutputs(
        base_power,
        collect(timestamps),
        source_data,
        source_data_uuid,
        aux_variable_values,
        variable_values,
        dual_values,
        parameter_values,
        expression_values,
        optimizer_stats,
        optimization_container_metadata,
        model_type,
        outputs_dir,
        output_dir,
    )
end

list_aux_variable_keys(res::OptimizationProblemOutputs) =
    collect(keys(res.aux_variable_values))
list_aux_variable_names(res::OptimizationProblemOutputs) =
    encode_keys_as_strings(keys(res.aux_variable_values))
list_variable_keys(res::OptimizationProblemOutputs) = collect(keys(res.variable_values))
list_variable_names(res::OptimizationProblemOutputs) =
    encode_keys_as_strings(keys(res.variable_values))
list_parameter_keys(res::OptimizationProblemOutputs) = collect(keys(res.parameter_values))
list_parameter_names(res::OptimizationProblemOutputs) =
    encode_keys_as_strings(keys(res.parameter_values))
list_dual_keys(res::OptimizationProblemOutputs) = collect(keys(res.dual_values))
list_dual_names(res::OptimizationProblemOutputs) =
    encode_keys_as_strings(keys(res.dual_values))
list_expression_keys(res::OptimizationProblemOutputs) = collect(keys(res.expression_values))
list_expression_names(res::OptimizationProblemOutputs) =
    encode_keys_as_strings(keys(res.expression_values))
get_timestamps(res::OptimizationProblemOutputs) = res.timestamps
get_model_base_power(res::OptimizationProblemOutputs) = res.base_power
get_dual_values(res::OptimizationProblemOutputs) = res.dual_values
get_expression_values(res::OptimizationProblemOutputs) = res.expression_values
get_variable_values(res::OptimizationProblemOutputs) = res.variable_values
get_aux_variable_values(res::OptimizationProblemOutputs) = res.aux_variable_values
get_total_cost(res::OptimizationProblemOutputs) = get_objective_value(res)
get_optimizer_stats(res::OptimizationProblemOutputs) = res.optimizer_stats
get_parameter_values(res::OptimizationProblemOutputs) = res.parameter_values
get_source_data(res::OptimizationProblemOutputs) = res.source_data

make_system_filename(sys::IS.InfrastructureSystemsContainer) =
    make_system_filename(get_system_uuid(sys))
make_system_filename(sys_uuid::Union{Base.UUID, AbstractString}) = "system-$(sys_uuid).json"

"""
Load the system from disk if not already set, and return it.

Currently only used in the tests, not downstream in POM.
"""
function load_system(res::OptimizationProblemOutputs; kwargs...)
    !isnothing(get_source_data(res)) && return
    file = joinpath(get_outputs_dir(res), make_system_filename(get_source_data_uuid(res)))
    if isfile(file)
        sys = IS.InfrastructureSystemsContainer(file; time_series_read_only = true)
        @info "De-serialized the system from files."
    else
        error("Could not locate system file: $file")
    end
    set_source_data!(res, sys)
    return
end

get_forecast_horizon(res::OptimizationProblemOutputs) = length(get_timestamps(res))
get_output_dir(res::OptimizationProblemOutputs) = res.output_dir
get_outputs_dir(res::OptimizationProblemOutputs) = res.outputs_dir
get_source_data_uuid(res::OptimizationProblemOutputs) = res.source_data_uuid

get_output_values(x::OptimizationProblemOutputs, ::AuxVarKey) = x.aux_variable_values
get_output_values(x::OptimizationProblemOutputs, ::ConstraintKey) = x.dual_values
get_output_values(x::OptimizationProblemOutputs, ::ExpressionKey) = x.expression_values
get_output_values(x::OptimizationProblemOutputs, ::ParameterKey) = x.parameter_values
get_output_values(x::OptimizationProblemOutputs, ::VariableKey) = x.variable_values

function get_objective_value(res::OptimizationProblemOutputs, execution = 1)
    return res.optimizer_stats[execution, :objective_value]
end

function get_resolution(res::OptimizationProblemOutputs)
    # Method return the resolution between timestamps.
    # If multiple resolutions are present it returns the first observed.
    # If single timestamp is used, it return.
    diff_res = diff(get_timestamps(res))
    if !isempty(diff_res)
        unique!(diff_res)
        if length(diff_res) == 1
            return only(diff_res)
        else
            @warn "Multiple resolutions detected, returning the first resolution."
            return first(diff_res)
        end
    end
    return
end

function get_realized_timestamps(
    res::IS.Outputs;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
)
    timestamps = get_timestamps(res)
    resolution = get_resolution(res)
    intervals = diff(timestamps)
    if isempty(intervals) && isnothing(resolution)
        interval = Dates.Millisecond(1)
        resolution = Dates.Millisecond(1)
    elseif !isempty(intervals) && isnothing(resolution)
        interval = first(intervals)
        resolution = interval
    elseif isempty(intervals) && !isnothing(resolution)
        interval = resolution
    else
        interval = first(intervals)
    end
    horizon = get_forecast_horizon(res)
    start_time = isnothing(start_time) ? first(timestamps) : start_time
    end_time =
        if isnothing(len)
            last(timestamps) + interval - resolution
        else
            start_time + (len - 1) * resolution
        end

    requested_range = start_time:resolution:end_time
    available_range =
        first(timestamps):resolution:(last(timestamps) + (horizon - 1) * resolution)
    invalid_timestamps = setdiff(requested_range, available_range)

    if !isempty(invalid_timestamps)
        msg = "Requested time does not match available outputs"
        @error msg
        throw(IS.InvalidValue(msg))
    end

    return requested_range
end

function export_output(
    ::Type{CSV.File},
    path,
    key::OptimizationContainerKey,
    timestamp::Dates.DateTime,
    df::DataFrame,
)
    name = encode_key_as_string(key)
    export_output(CSV.File, path, name, timestamp, df)
    return
end

function export_output(
    ::Type{CSV.File},
    path,
    name::AbstractString,
    timestamp::Dates.DateTime,
    df::DataFrame,
)
    filename = joinpath(path, name * "_" * convert_for_path(timestamp) * ".csv")
    export_output(CSV.File, filename, df)
    return
end

function export_output(
    ::Type{CSV.File},
    path,
    key::OptimizationContainerKey,
    df::DataFrame,
)
    name = encode_key_as_string(key)
    export_output(CSV.File, path, name, df)
    return
end

function export_output(
    ::Type{CSV.File},
    path,
    name::AbstractString,
    df::DataFrame,
)
    filename = joinpath(path, name * ".csv")
    export_output(CSV.File, filename, df)
    return
end

function export_output(::Type{CSV.File}, filename, df::DataFrame)
    open(filename, "w") do io
        CSV.write(io, df)
    end

    @debug "Exported $filename"
    return
end

"""
Exports all outputs from the operations problem.
"""
function export_outputs(outputs::OptimizationProblemOutputs; kwargs...)
    exports = OptimizationProblemOutputsExport(
        "Problem";
        store_all_duals = true,
        store_all_parameters = true,
        store_all_variables = true,
        store_all_aux_variables = true,
    )
    return export_outputs(outputs, exports; kwargs...)
end

function export_outputs(
    outputs::OptimizationProblemOutputs,
    exports::OptimizationProblemOutputsExport;
    file_type = CSV.File,
)
    file_type != CSV.File && error("only CSV.File is currently supported")
    for (source, decider, label) in [
        (outputs.variable_values, should_export_variable, "variables"),
        (outputs.aux_variable_values, should_export_aux_variable, "aux_variables"),
        (outputs.dual_values, should_export_dual, "duals"),
        (outputs.parameter_values, should_export_parameter, "parameters"),
        (outputs.expression_values, should_export_expression, "expressions"),
    ]
        export_path = mkpath(joinpath(get_output_dir(outputs), label))
        for (key, df) in source
            if decider(exports, key)
                export_output(file_type, export_path, key, df)
            end
        end
    end

    if exports.optimizer_stats
        export_output(
            file_type,
            joinpath(get_output_dir(outputs), "optimizer_stats.csv"),
            outputs.optimizer_stats,
        )
    end

    @info "Exported OptimizationProblemOutputs to $(get_output_dir(outputs))"
end

function _deserialize_key(
    ::Type{<:OptimizationContainerKey},
    outputs::OptimizationProblemOutputs,
    name::AbstractString,
)
    return deserialize_key(outputs.optimization_container_metadata, name)
end

function _deserialize_key(
    ::Type{T},
    ::OptimizationProblemOutputs,
    args...,
) where {T <: OptimizationContainerKey}
    return make_key(T, args...)
end

function _validate_keys(existing_keys, output_keys)
    diff = setdiff(output_keys, existing_keys)
    if !isempty(diff)
        throw(InvalidValue("These keys are not stored: $diff"))
    end
    return
end

read_optimizer_stats(res::OptimizationProblemOutputs) = res.optimizer_stats

"""
Set the system in the outputs instance.

Throws InvalidValue if the source UUID is incorrect.
"""
function set_source_data!(
    res::OptimizationProblemOutputs,
    source::InfrastructureSystemsType,
)
    source_uuid = get_uuid(source)
    if source_uuid != res.source_data_uuid
        throw(
            InvalidValue(
                "System mismatch. $source_uuid does not match the stored value of $(res.source_data_uuid)",
            ),
        )
    end

    res.source_data = source
    return
end

const _PROBLEM_OUTPUTS_FILENAME = "problem_outputs.bin"

# TODO test this in IS
"""
Serialize the outputs to a binary file.

It is recommended that `directory` be the directory that contains a serialized
OperationModel. That will allow automatic deserialization of the PowerSystems.System.
The `OptimizationProblemOutputs` instance can be deserialized with `OptimizationProblemOutputs(directory)`.
"""
function serialize_outputs(res::OptimizationProblemOutputs, directory::AbstractString)
    mkpath(directory)
    filename = joinpath(directory, _PROBLEM_OUTPUTS_FILENAME)
    isfile(filename) && rm(filename)
    Serialization.serialize(filename, _copy_for_serialization(res))
    @info "Serialize OptimizationProblemOutputs to $filename"
end

"""
Construct a OptimizationProblemOutputs instance from a serialized directory. It is up to the
user or a higher-level package to set the source data using [`set_source_data!`](@ref).
"""
function OptimizationProblemOutputs(directory::AbstractString)
    filename = joinpath(directory, _PROBLEM_OUTPUTS_FILENAME)
    isfile(filename) || error("No outputs file exists in $directory")
    return Serialization.deserialize(filename)
end

function _copy_for_serialization(res::OptimizationProblemOutputs)
    return OptimizationProblemOutputs(
        res.base_power,
        res.timestamps,
        nothing,
        res.source_data_uuid,
        res.aux_variable_values,
        res.variable_values,
        res.dual_values,
        res.parameter_values,
        res.expression_values,
        res.optimizer_stats,
        res.optimization_container_metadata,
        res.model_type,
        res.outputs_dir,
        res.output_dir,
    )
end

function _read_outputs(
    output_values::Dict{<:OptimizationContainerKey, DataFrame},
    container_keys,
    timestamps::Vector{Dates.DateTime},
    time_ids,
    base_power::Float64,
    base_timestamps::Vector{Dates.DateTime},
    table_format::TableFormat,
)
    existing_keys = keys(output_values)
    container_keys = container_keys === nothing ? existing_keys : container_keys
    _validate_keys(existing_keys, container_keys)
    outputs = Dict{OptimizationContainerKey, DataFrame}()
    IS.@assert_op length(time_ids) == length(timestamps)
    df_timestamps = DataFrame(:DateTime => timestamps, :time_index => time_ids)
    filter_timestamps = timestamps != base_timestamps

    for (key, df) in output_values
        if !in(key, container_keys)
            continue
        end
        if filter_timestamps
            df = @subset(df, :time_index .∈ Ref(time_ids))
        end
        first_dim_col = get_first_dimension_output_column_name(key)
        second_dim_col = get_second_dimension_output_column_name(key)
        component_cols = [first_dim_col]
        if second_dim_col in names(df)
            push!(component_cols, second_dim_col)
            if table_format == TableFormat.WIDE
                error(
                    "Wide format is not supported with 3-dimensional outputs",
                )
            end
        end
        num_components = DataFrames.nrow(unique(df[:, component_cols]))
        num_rows = DataFrames.nrow(df)
        if num_rows % num_components != 0
            error(
                "num_rows = $num_rows is not divisible by num_components = $num_components",
            )
        end
        num_rows_per_component = num_rows ÷ num_components
        if num_rows_per_component == length(time_ids) == length(timestamps)
            tmp_df = innerjoin(df, df_timestamps; on = :time_index)
            if DataFrames.nrow(tmp_df) != DataFrames.nrow(df)
                error(
                    "Bug: Unexpectedly dropped rows: df2 = $tmp_df orig = $(outputs[key])",
                )
            end
            outputs[key] = select(tmp_df, [:DateTime, Symbol.(component_cols)..., :value])
        else
            @warn "Length of variables is different than timestamps. Ignoring timestamps."
            outputs[key] = deepcopy(df)
        end
        outputs[key] = _handle_natural_units(outputs[key], base_power, key)
        if table_format == TableFormat.WIDE
            outputs[key] = DataFrames.unstack(outputs[key], first_dim_col, "value")
        end
    end
    return outputs
end

"""
Convert the value column to natural units, if required by the key.
Does not mutate the input dataframe.
"""
function _handle_natural_units(
    df::DataFrame,
    base_power::Float64,
    key::OptimizationContainerKey,
)
    return if convert_output_to_natural_units(key)
        @transform(df, :value = :value * base_power)
    else
        df
    end
end

function _process_timestamps(
    res::OptimizationProblemOutputs,
    start_time::Union{Nothing, Dates.DateTime},
    len::Union{Int, Nothing},
)
    if start_time === nothing
        start_time = first(get_timestamps(res))
    elseif start_time ∉ get_timestamps(res)
        throw(InvalidValue("start_time not in output timestamps"))
    end

    if startswith(res.model_type, "EmulationModel{")
        def_len = DataFrames.nrow(get_optimizer_stats(res))
        requested_range =
            collect(findfirst(x -> x >= start_time, get_timestamps(res)):def_len)
        timestamps = repeat(get_timestamps(res), def_len)
    else
        timestamps = get_timestamps(res)
        requested_range = findall(x -> x >= start_time, timestamps)
        def_len = length(requested_range)
    end
    actual_len = if len === nothing
        def_len
    elseif len < 0
        throw(InvalidValue("len cannot be negative: $len"))
    elseif len > def_len
        throw(InvalidValue("requested outputs have less than $len values"))
    else
        len
    end
    timestamp_ids = requested_range[1:actual_len]
    return timestamp_ids, timestamps[timestamp_ids]
end

"""
Return the values for the requested variable key for a problem.
Accepts a vector of keys for the return of the values.

# Arguments

- `res::OptimizationProblemOutputs`: Optimization problem outputs
- `variable::Tuple{Type{<:VariableType}, Type{<:IS.InfrastructureSystemsComponent}`: Tuple with variable type
  and device type for the desired outputs
- `start_time::Dates.DateTime`: Start time of the requested outputs
- `len::Int`: length of outputs
- `table_format::TableFormat`: Format of the table to be returned. Default is
  `TableFormat.LONG` where the columns are `DateTime`, `name`, and `value` when the data
  has two dimensions and `DateTime`, `name`, `name2`, and `value` when the data has three
  dimensions.
  Set to it `TableFormat.WIDE` to pivot the names as columns.
  Note: `TableFormat.WIDE` is not supported when the data has more than two dimensions.
"""
function read_variable(
    res::OptimizationProblemOutputs,
    args...;
    kwargs...,
)
    key = VariableKey(args...)
    return read_variable(res, key; kwargs...)
end

function read_variable(res::OptimizationProblemOutputs, key::AbstractString; kwargs...)
    return read_variable(res, _deserialize_key(VariableKey, res, key); kwargs...)
end

function read_variable(
    res::OptimizationProblemOutputs,
    key::VariableKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    return read_outputs_with_keys(
        res,
        [key];
        start_time = start_time,
        len = len,
        table_format = table_format,
    )[key]
end

"""
Return the values for the requested variable keys for a problem.
Accepts a vector of keys for the return of the values.

# Arguments

  - `variables::Vector{Tuple{Type{<:VariableType}, Type{<:IS.InfrastructureSystemsComponent}}` : Tuple with variable type and device type for the desired outputs
  - `start_time::Dates.DateTime` : initial time of the requested outputs
  - `len::Int`: length of outputs
"""
function read_variables(res::OptimizationProblemOutputs, variables; kwargs...)
    return read_variables(res, [VariableKey(x...) for x in variables]; kwargs...)
end

function read_variables(
    res::OptimizationProblemOutputs,
    variables::Vector{<:AbstractString};
    kwargs...,
)
    return read_variables(
        res,
        [_deserialize_key(VariableKey, res, x) for x in variables];
        kwargs...,
    )
end

function read_variables(
    res::OptimizationProblemOutputs,
    variables::Vector{<:OptimizationContainerKey};
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    output_values =
        read_outputs_with_keys(
            res,
            variables;
            start_time = start_time,
            len = len,
            table_format = table_format,
        )
    return Dict(encode_key_as_string(k) => v for (k, v) in output_values)
end

"""
Return the values for all variables.
"""
function read_variables(res::Outputs; kwargs...)
    return Dict(x => read_variable(res, x; kwargs...) for x in list_variable_names(res))
end

"""
Return the values for the requested dual key for a problem.
Accepts a vector of keys for the return of the values.

# Arguments

  - `dual::Tuple{Type{<:ConstraintType}, Type{<:IS.InfrastructureSystemsComponent}` : Tuple with dual type and device type for the desired outputs
  - `start_time::Dates.DateTime` : initial time of the requested outputs
  - `len::Int`: length of outputs
"""
function read_dual(
    res::OptimizationProblemOutputs,
    args...;
    kwargs...,
)
    key = ConstraintKey(args...)
    return read_dual(res, key; kwargs...)
end

function read_dual(res::OptimizationProblemOutputs, key::AbstractString; kwargs...)
    return read_dual(res, _deserialize_key(ConstraintKey, res, key); kwargs...)
end

function read_dual(
    res::OptimizationProblemOutputs,
    key::ConstraintKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    return read_outputs_with_keys(
        res,
        [key];
        start_time = start_time,
        len = len,
        table_format = table_format,
    )[key]
end

"""
Return the values for the requested dual keys for a problem.
Accepts a vector of keys for the return of the values.

# Arguments

  - `duals::Vector{Tuple{Type{<:ConstraintType}, Type{<:IS.InfrastructureSystemsComponent}}` : Tuple with dual type and device type for the desired outputs
  - `start_time::Dates.DateTime` : initial time of the requested outputs
  - `len::Int`: length of outputs
"""
function read_duals(res::OptimizationProblemOutputs, duals; kwargs...)
    return read_duals(res, [ConstraintKey(x...) for x in duals]; kwargs...)
end

function read_duals(
    res::OptimizationProblemOutputs,
    duals::Vector{<:AbstractString};
    kwargs...,
)
    return read_duals(
        res,
        [_deserialize_key(ConstraintKey, res, x) for x in duals];
        kwargs...,
    )
end

function read_duals(
    res::OptimizationProblemOutputs,
    duals::Vector{<:OptimizationContainerKey};
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    output_values = read_outputs_with_keys(
        res,
        duals;
        start_time = start_time,
        len = len,
        table_format = table_format,
    )
    return Dict(encode_key_as_string(k) => v for (k, v) in output_values)
end

"""
Return the values for all duals.
"""
function read_duals(res::Outputs; kwargs...)
    duals = Dict(x => read_dual(res, x; kwargs...) for x in list_dual_names(res))
end

"""
Return the values for the requested parameter key for a problem.
Accepts a vector of keys for the return of the values.

# Arguments

  - `parameter::Tuple{Type{<:ParameterType}, Type{<:IS.InfrastructureSystemsComponent}` : Tuple with parameter type and device type for the desired outputs
  - `start_time::Dates.DateTime` : initial time of the requested outputs
  - `len::Int`: length of outputs
"""
function read_parameter(
    res::OptimizationProblemOutputs,
    args...;
    kwargs...,
)
    key = ParameterKey(args...)
    return read_parameter(res, key; kwargs...)
end

function read_parameter(res::OptimizationProblemOutputs, key::AbstractString; kwargs...)
    return read_parameter(res, _deserialize_key(ParameterKey, res, key); kwargs...)
end

function read_parameter(
    res::OptimizationProblemOutputs,
    key::ParameterKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    return read_outputs_with_keys(
        res,
        [key];
        start_time = start_time,
        len = len,
        table_format = table_format,
    )[key]
end

"""
Return the values for the requested parameter keys for a problem.
Accepts a vector of keys for the return of the values.

# Arguments

  - `parameters::Vector{Tuple{Type{<:ParameterType}, Type{<:IS.InfrastructureSystemsComponent}}` : Tuple with parameter type and device type for the desired outputs
  - `start_time::Dates.DateTime` : initial time of the requested outputs
  - `len::Int`: length of outputs
"""
function read_parameters(res::OptimizationProblemOutputs, parameters; kwargs...)
    return read_parameters(res, [ParameterKey(x...) for x in parameters]; kwargs...)
end

function read_parameters(
    res::OptimizationProblemOutputs,
    parameters::Vector{<:AbstractString};
    kwargs...,
)
    return read_parameters(
        res,
        [_deserialize_key(ParameterKey, res, x) for x in parameters];
        kwargs...,
    )
end

function read_parameters(
    res::OptimizationProblemOutputs,
    parameters::Vector{<:OptimizationContainerKey};
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    output_values =
        read_outputs_with_keys(
            res,
            parameters;
            start_time = start_time,
            len = len,
            table_format = table_format,
        )
    return Dict(encode_key_as_string(k) => v for (k, v) in output_values)
end

"""
Return the values for all parameters.
"""
function read_parameters(res::Outputs; kwargs...)
    parameters =
        Dict(x => read_parameter(res, x; kwargs...) for x in list_parameter_names(res))
end

"""
Return the values for the requested aux_variable key for a problem.
Accepts a vector of keys for the return of the values.

# Arguments

  - `aux_variable::Tuple{Type{<:AuxVariableType}, Type{<:IS.InfrastructureSystemsComponent}` : Tuple with aux_variable type and device type for the desired outputs
  - `start_time::Dates.DateTime` : initial time of the requested outputs
  - `len::Int`: length of outputs
"""
function read_aux_variable(
    res::OptimizationProblemOutputs,
    args...;
    kwargs...,
)
    key = AuxVarKey(args...)
    return read_aux_variable(res, key; kwargs...)
end

function read_aux_variable(res::OptimizationProblemOutputs, key::AbstractString; kwargs...)
    return read_aux_variable(res, _deserialize_key(AuxVarKey, res, key); kwargs...)
end

function read_aux_variable(
    res::OptimizationProblemOutputs,
    key::AuxVarKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    return read_outputs_with_keys(
        res,
        [key];
        start_time = start_time,
        len = len,
        table_format = table_format,
    )[key]
end

"""
Return the values for the requested aux_variable keys for a problem.
Accepts a vector of keys for the return of the values.

# Arguments

  - `aux_variables::Vector{Tuple{Type{<:AuxVariableType}, Type{<:IS.InfrastructureSystemsComponent}}` : Tuple with aux_variable type and device type for the desired outputs
  - `start_time::Dates.DateTime` : initial time of the requested outputs
  - `len::Int`: length of outputs
"""
function read_aux_variables(res::OptimizationProblemOutputs, aux_variables; kwargs...)
    return read_aux_variables(res, [AuxVarKey(x...) for x in aux_variables]; kwargs...)
end

function read_aux_variables(
    res::OptimizationProblemOutputs,
    aux_variables::Vector{<:AbstractString};
    kwargs...,
)
    return read_aux_variables(
        res,
        [_deserialize_key(AuxVarKey, res, x) for x in aux_variables];
        kwargs...,
    )
end

function read_aux_variables(
    res::OptimizationProblemOutputs,
    aux_variables::Vector{<:OptimizationContainerKey};
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    output_values =
        read_outputs_with_keys(
            res,
            aux_variables;
            start_time = start_time,
            len = len,
            table_format = table_format,
        )
    return Dict(encode_key_as_string(k) => v for (k, v) in output_values)
end

"""
Return the values for all auxiliary variables.
"""
function read_aux_variables(res::Outputs; kwargs...)
    return Dict(
        x => read_aux_variable(res, x; kwargs...) for x in list_aux_variable_names(res)
    )
end

"""
Return the values for the requested expression key for a problem.
Accepts a vector of keys for the return of the values.

# Arguments

  - `expression::Tuple{Type{<:ExpressionType}, Type{<:IS.InfrastructureSystemsComponent}` : Tuple with expression type and device type for the desired outputs
  - `start_time::Dates.DateTime` : initial time of the requested outputs
  - `len::Int`: length of outputs
"""
function read_expression(
    res::OptimizationProblemOutputs,
    args...;
    kwargs...,
)
    key = ExpressionKey(args...)
    return read_expression(res, key; kwargs...)
end

function read_expression(res::OptimizationProblemOutputs, key::AbstractString; kwargs...)
    return read_expression(res, _deserialize_key(ExpressionKey, res, key); kwargs...)
end

function read_expression(
    res::OptimizationProblemOutputs,
    key::ExpressionKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    return read_outputs_with_keys(
        res,
        [key];
        start_time = start_time,
        len = len,
        table_format = table_format,
    )[key]
end

"""
Return the values for the requested expression keys for a problem.
Accepts a vector of keys for the return of the values.

# Arguments

  - `expressions::Vector{Tuple{Type{<:ExpressionType}, Type{<:IS.InfrastructureSystemsComponent}}` : Tuple with expression type and device type for the desired outputs
  - `start_time::Dates.DateTime` : initial time of the requested outputs
  - `len::Int`: length of outputs
"""
function read_expressions(res::OptimizationProblemOutputs; kwargs...)
    return read_expressions(res, collect(keys(res.expression_values)); kwargs...)
end

function read_expressions(res::OptimizationProblemOutputs, expressions; kwargs...)
    return read_expressions(res, [ExpressionKey(x...) for x in expressions]; kwargs...)
end

function read_expressions(
    res::OptimizationProblemOutputs,
    expressions::Vector{<:AbstractString};
    kwargs...,
)
    return read_expressions(
        res,
        [_deserialize_key(ExpressionKey, res, x) for x in expressions];
        kwargs...,
    )
end

function read_expressions(
    res::OptimizationProblemOutputs,
    expressions::Vector{<:OptimizationContainerKey};
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    output_values =
        read_outputs_with_keys(
            res,
            expressions;
            start_time = start_time,
            len = len,
            table_format = table_format,
        )
    return Dict(encode_key_as_string(k) => v for (k, v) in output_values)
end

"""
Return the values for all expressions.
"""
function read_expressions(res::Outputs; kwargs...)
    return Dict(x => read_expression(res, x) for x in list_expression_names(res))
end

function read_outputs_with_keys(
    res::OptimizationProblemOutputs,
    output_keys::Vector{<:OptimizationContainerKey};
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Int, Nothing} = nothing,
    table_format::TableFormat = TableFormat.LONG,
)
    isempty(output_keys) && return Dict{OptimizationContainerKey, DataFrame}()
    (timestamp_ids, timestamps) = _process_timestamps(res, start_time, len)

    base_timestamps = get_timestamps(res)
    return _read_outputs(
        get_output_values(res, first(output_keys)),
        output_keys,
        timestamps,
        timestamp_ids,
        get_model_base_power(res),
        base_timestamps,
        table_format,
    )
end

"""
Save the realized outputs to CSV files for all variables, paramaters, duals, auxiliary variables,
expressions, and optimizer statistics.

# Arguments

  - `res::Outputs`: Outputs
  - `save_path::AbstractString` : path to save outputs (defaults to simulation path)
"""
function export_realized_outputs(res::Outputs)
    save_path = mkpath(joinpath(get_output_dir(res), "export"))
    return export_realized_outputs(res, save_path)
end

function export_realized_outputs(
    res::Outputs,
    save_path::AbstractString,
)
    if !isdir(save_path)
        throw(IS.ConflictingInputsError("Specified path is not valid."))
    end
    write_data(read_outputs_with_keys(res, list_variable_keys(res)), save_path)
    !isempty(list_dual_keys(res)) &&
        write_data(
            read_outputs_with_keys(res, list_dual_keys(res)),
            save_path;
            name = "dual",
        )
    !isempty(list_parameter_keys(res)) && write_data(
        read_outputs_with_keys(res, list_parameter_keys(res)),
        save_path;
        name = "parameter",
    )
    !isempty(list_aux_variable_keys(res)) && write_data(
        read_outputs_with_keys(res, list_aux_variable_keys(res)),
        save_path;
        name = "aux_variable",
    )
    !isempty(list_expression_keys(res)) && write_data(
        read_outputs_with_keys(res, list_expression_keys(res)),
        save_path;
        name = "expression",
    )
    export_optimizer_stats(res, save_path)
    files = readdir(save_path)
    compute_file_hash(save_path, files)
    @info("Files written to $save_path folder.")
    return save_path
end

"""
Save the optimizer statistics to CSV or JSON

# Arguments

  - `res::OptimizationProblemOutputs`: Outputs
  - `directory::AbstractString`: target directory
  - `format = "CSV"`: can be `"csv"` or `"json"`
"""
function export_optimizer_stats(
    res::Outputs,
    directory::AbstractString;
    format = "csv",
)
    data = read_optimizer_stats(res)
    isnothing(data) && return
    if uppercase(format) == "CSV"
        CSV.write(joinpath(directory, "optimizer_stats.csv"), data)
    elseif uppercase(format) == "JSON"
        cols = Dict(string(n) => data[!, n] for n in names(data))
        write(joinpath(directory, "optimizer_stats.json"), JSON3.write(cols))
    else
        throw(error("writing optimizer stats only supports csv or json formats"))
    end
end

function write_data(
    vars_outputs::Dict,
    time::DataFrame,
    save_path::AbstractString,
)
    for (k, v) in vars_outputs
        var = DataFrame()
        if size(time, 1) == size(v, 1)
            var = hcat(time, v)
        else
            var = v
        end
        file_path = joinpath(save_path, "$(k).csv")
        CSV.write(file_path, var)
    end
end

function write_data(
    data::DataFrame,
    save_path::AbstractString,
    file_name::String,
)
    if isfile(save_path)
        save_path = dirname(save_path)
    end
    file_path = joinpath(save_path, "$(file_name).csv")
    CSV.write(file_path, data)
    return
end

# writing a dictionary of dataframes to files
function write_data(vars_outputs::Dict, save_path::String; kwargs...)
    name = get(kwargs, :name, "")
    for (k, v) in vars_outputs
        keyname = encode_key_as_string(k)
        file_path = joinpath(save_path, "$name$keyname.csv")
        @debug "writing" file_path
        if isempty(vars_outputs[k])
            @debug "$name$k is empty, not writing $file_path"
        else
            CSV.write(file_path, vars_outputs[k])
        end
    end
end
