function _maybe_add_reactive_power_variables!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{D, F},
    network_model::NetworkModel{<:AbstractNetworkModel},
    var_types,
) where {D <: PSY.Device, F}
    for V in var_types
        add_variables!(container, V, devices, F)
        add_to_expression!(
            container, ReactivePowerBalance, V, devices, model, network_model,
        )
    end
    return
end

_maybe_add_reactive_power_variables!(
    ::OptimizationContainer,
    _devices,
    ::DeviceModel{D, F},
    ::NetworkModel{<:AbstractActivePowerModel},
    _var_types,
) where {D <: PSY.Device, F} = nothing

function _maybe_add_reactive_power_constraints!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{D, F},
    network_model::NetworkModel{<:AbstractNetworkModel},
    constraint_type::Type{<:ConstraintType},
) where {D <: PSY.Device, F}
    add_constraints!(container, constraint_type, devices, model, network_model)
    return
end

_maybe_add_reactive_power_constraints!(
    ::OptimizationContainer,
    _devices,
    ::DeviceModel{D, F},
    ::NetworkModel{<:AbstractActivePowerModel},
    ::Type{<:ConstraintType},
) where {D <: PSY.Device, F} = nothing

function _maybe_add_reactive_power_constraints!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{D, F},
    network_model::NetworkModel{<:AbstractNetworkModel},
    constraint_type::Type{<:ConstraintType},
    variable_type::Type{<:VariableType},
) where {D <: PSY.Device, F}
    add_constraints!(
        container, constraint_type, variable_type, devices, model, network_model,
    )
    return
end

_maybe_add_reactive_power_constraints!(
    ::OptimizationContainer,
    _devices,
    ::DeviceModel{D, F},
    ::NetworkModel{<:AbstractActivePowerModel},
    ::Type{<:ConstraintType},
    ::Type{<:VariableType},
) where {D <: PSY.Device, F} = nothing

function _maybe_relax_binaries(
    container::OptimizationContainer,
    model::DeviceModel{D},
    var_types::Vector{<:Type},
) where {D <: PSY.Component}
    get_attribute(model, RELAX_BINARIES_ATTRIBUTE) === true || return
    for V in var_types
        _relax_binaries(container, V, D)
    end
    return
end

function _relax_binaries(
    container::OptimizationContainer,
    ::Type{V},
    ::Type{D},
) where {V <: VariableType, D <: PSY.Component}
    has_container_key(container, V, D) || return
    for var in get_variable(container, V, D)
        JuMP.unset_binary(var)
        JuMP.set_lower_bound(var, 0.0)
        JuMP.set_upper_bound(var, 1.0)
    end
    return
end
