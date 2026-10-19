"""
Extension point for downstream packages to define how to map initial condition types
to variable types for specific device formulations.

This function should be implemented by packages like PowerOperationsModels to specify
which variable type corresponds to a given initial condition type for a particular
device and formulation.

# Arguments
- `ic_type`: An instance of an InitialConditionType (e.g., DeviceStatus(), DevicePower())
- `component`: The device component
- `formulation`: An instance of the device formulation

# Returns
A VariableType instance that corresponds to this initial condition.
"""
function initial_condition_variable(
    ic_type::InitialConditionType,
    component::PSY.Component,
    formulation::Union{AbstractDeviceFormulation, AbstractServiceFormulation},
)
    error(
        "initial_condition_variable not implemented for initial condition type " *
        "$(typeof(ic_type)) with device $(typeof(component)) and formulation " *
        "$(typeof(formulation)). Implement this method in PowerOperationsModels.",
    )
end

"""
Extension point for downstream packages to define default values for initial conditions.
"""
function initial_condition_default(
    ::I,
    ::C,
    ::F,
) where {
    I <: InitialConditionType,
    C <: IS.InfrastructureSystemsComponent,
    F <: Union{AbstractDeviceFormulation, AbstractServiceFormulation},
}
    error(
        "initial_condition_default not implemented for initial condition type " *
        "$I with device $C and formulation " *
        "$F. Implement this method in PowerOperationsModels.",
    )
end

"""
Default value of an initial condition, read with the container. The default calls the method
without the container. A device whose default depends on the per-step data of the container
implements this method.
"""
function initial_condition_default(
    ic::InitialConditionType,
    component::PSY.Component,
    formulation::Union{AbstractDeviceFormulation, AbstractServiceFormulation},
    ::OptimizationContainer,
)
    return initial_condition_default(ic, component, formulation)
end

#################################################################################
# Generic get_initial_conditions_value implementations
# Device-specific overloads should be defined in POM
#################################################################################

# Generic fallback for InitialCondition with Nothing value type
function get_initial_conditions_value(
    ::Vector{T},
    component::W,
    ::U,
    ::V,
    container::OptimizationContainer,
) where {
    T <: InitialCondition{U, Nothing},
    V <: Union{AbstractDeviceFormulation, AbstractServiceFormulation},
    W <: PSY.Component,
} where {U <: InitialConditionType}
    return InitialCondition{U, Nothing}(component, nothing)
end

# Wraps an initial-condition value: a constant, or a parameter when the model is built for
# recurrent solves.
_initial_condition(
    ::Vector{Union{InitialCondition{U, Float64}, InitialCondition{U, Nothing}}},
    component,
    ::OptimizationContainer,
    val,
) where {U} =
    InitialCondition{U, Float64}(component, val)
_initial_condition(
    ::Vector{Union{InitialCondition{U, JuMP.VariableRef}, InitialCondition{U, Nothing}}},
    component,
    container::OptimizationContainer,
    val,
) where {U} = InitialCondition{U, JuMP.VariableRef}(
    component,
    add_jump_parameter(get_jump_model(container), val),
)

# Generic implementation: the initial-condition data if present, else the default.
function get_initial_conditions_value(
    ini_cond_vector::Union{
        Vector{Union{InitialCondition{U, Float64}, InitialCondition{U, Nothing}}},
        Vector{Union{InitialCondition{U, JuMP.VariableRef}, InitialCondition{U, Nothing}}},
    },
    component::W,
    ::U,
    ::V,
    container::OptimizationContainer,
) where {
    U <: InitialConditionType,
    V <: Union{AbstractDeviceFormulation, AbstractServiceFormulation},
    W <: PSY.Component,
}
    ic_data = get_initial_conditions_data(container)
    var_type = initial_condition_variable(U(), component, V())
    if !has_initial_condition_value(ic_data, var_type, W)
        val = initial_condition_default(U(), component, V(), container)
    else
        val = get_initial_condition_value(ic_data, var_type, W)[PSY.get_name(component), 1]
    end
    @debug "Device $(PSY.get_name(component)) initialized $U as $val" _group =
        LOG_GROUP_BUILD_INITIAL_CONDITIONS
    return _initial_condition(ini_cond_vector, component, container, val)
end

#################################################################################
# Generic add_initial_condition! implementation
# Device-specific overloads should be defined in POM
#################################################################################

function add_initial_condition!(
    container::OptimizationContainer,
    components::Vector{T},
    ::U,
    ::D,
) where {
    T <: PSY.Component,
    U <: Union{AbstractDeviceFormulation, AbstractServiceFormulation},
    D <: InitialConditionType,
}
    if get_rebuild_model(get_settings(container)) && has_container_key(container, D, T)
        return
    end

    ini_cond_vector = add_initial_condition_container!(container, D(), T, components)
    for (ix, component) in enumerate(components)
        ini_cond_vector[ix] =
            get_initial_conditions_value(ini_cond_vector, component, D(), U(), container)
    end
    return
end
