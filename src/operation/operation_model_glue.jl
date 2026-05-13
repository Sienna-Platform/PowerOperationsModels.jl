# OperationModel methods that dispatch on the abstract type but call into
# POM-defined functions on concrete stores or numerical-bounds types. Moved
# out of IOM's operation_model_interface.jl because the call chain terminates
# in POM-only methods (read_outputs, list_keys, get_variable_numerical_bounds,
# instantiate_network_model!, …).

function _check_numerical_bounds(model::OperationModel)
    variable_bounds = get_variable_numerical_bounds(model)
    if variable_bounds.bounds.max - variable_bounds.bounds.min > 1e9
        @warn "Variable bounds range is $(variable_bounds.bounds.max - variable_bounds.bounds.min) and can result in numerical problems for the solver. \\
        max_bound_variable = $(encode_key_as_string(variable_bounds.bounds.max_index)) \\
        min_bound_variable = $(encode_key_as_string(variable_bounds.bounds.min_index)) \\
        Run get_detailed_variable_numerical_bounds on the model for a deeper analysis"
    else
        @info "Variable bounds range is [$(variable_bounds.bounds.min) $(variable_bounds.bounds.max)]"
    end

    constraint_bounds = get_constraint_numerical_bounds(model)
    if constraint_bounds.coefficient.max - constraint_bounds.coefficient.min > 1e9
        @warn "Constraint coefficient bounds range is $(constraint_bounds.coefficient.max - constraint_bounds.coefficient.min) and can result in numerical problems for the solver. \\
        max_bound_constraint = $(encode_key_as_string(constraint_bounds.coefficient.max_index)) \\
        min_bound_constraint = $(encode_key_as_string(constraint_bounds.coefficient.min_index)) \\
        Run get_detailed_constraint_numerical_bounds on the model for a deeper analysis"
    else
        @info "Constraint coefficient bounds range is [$(constraint_bounds.coefficient.min) $(constraint_bounds.coefficient.max)]"
    end

    if constraint_bounds.rhs.max - constraint_bounds.rhs.min > 1e9
        @warn "Constraint right-hand-side bounds range is $(constraint_bounds.rhs.max - constraint_bounds.rhs.min) and can result in numerical problems for the solver. \\
        max_bound_constraint = $(encode_key_as_string(constraint_bounds.rhs.max_index)) \\
        min_bound_constraint = $(encode_key_as_string(constraint_bounds.rhs.min_index)) \\
        Run get_detailed_constraint_numerical_bounds on the model for a deeper analysis"
    else
        @info "Constraint right-hand-side bounds [$(constraint_bounds.rhs.min) $(constraint_bounds.rhs.max)]"
    end
    return
end

function _pre_solve_model_checks(model::OperationModel, optimizer = nothing)
    jump_model = get_jump_model(model)
    if optimizer !== nothing
        JuMP.set_optimizer(jump_model, optimizer)
    end

    if JuMP.mode(jump_model) != JuMP.DIRECT
        if JuMP.backend(jump_model).state == MOIU.NO_OPTIMIZER
            error("No Optimizer has been defined, can't solve the operational problem")
        end
    else
        @assert get_direct_mode_optimizer(get_settings(model))
    end

    optimizer_name = JuMP.solver_name(jump_model)
    @info "$(get_name(model)) optimizer set to: $optimizer_name"
    settings = get_settings(model)
    if get_check_numerical_bounds(settings)
        @info "Checking Numerical Bounds"
        TimerOutputs.@timeit BUILD_PROBLEMS_TIMER "Numerical Bounds Check" begin
            _check_numerical_bounds(model)
        end
    end
    return
end

function list_names(model::OperationModel, ::Type{T}) where {T <: OptimizationKeyType}
    return encode_keys_as_strings(
        list_keys(get_store(model), T),
    )
end

read_dual(model::OperationModel, key::ConstraintKey) = _read_outputs(model, key)
read_parameter(model::OperationModel, key::ParameterKey) = _read_outputs(model, key)
read_aux_variable(model::OperationModel, key::AuxVarKey) = _read_outputs(model, key)
read_variable(model::OperationModel, key::VariableKey) = _read_outputs(model, key)
read_expression(model::OperationModel, key::ExpressionKey) = _read_outputs(model, key)

function _read_outputs(model::OperationModel, key::OptimizationContainerKey)
    array = read_outputs(get_store(model), key)
    return to_outputs_dataframe(array, nothing, Val(TableFormat.LONG))
end

read_optimizer_stats(model::OperationModel) = read_optimizer_stats(get_store(model))

list_aux_variable_keys(x::OperationModel) = list_keys(get_store(x), AuxVariableType)
list_aux_variable_names(x::OperationModel) = list_names(x, AuxVariableType)
list_variable_keys(x::OperationModel) = list_keys(get_store(x), VariableType)
list_variable_names(x::OperationModel) = list_names(x, VariableType)
list_parameter_keys(x::OperationModel) = list_keys(get_store(x), ParameterType)
list_parameter_names(x::OperationModel) = list_names(x, ParameterType)
list_dual_keys(x::OperationModel) = list_keys(get_store(x), ConstraintType)
list_dual_names(x::OperationModel) = list_names(x, ConstraintType)
list_expression_keys(x::OperationModel) = list_keys(get_store(x), ExpressionType)
list_expression_names(x::OperationModel) = list_names(x, ExpressionType)

function list_all_keys(x::OperationModel)
    return Iterators.flatten(
        list_fields(get_store(x), T) for T in STORE_CONTAINER_TYPES
    )
end
