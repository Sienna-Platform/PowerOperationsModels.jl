# Helpers for variables/constraints that should only appear when the network
# model actually represents the relevant physical quantity (e.g. reactive
# power on AC networks). Each helper has a no-op method that dispatches on
# `NetworkModel{<:AbstractActivePowerModel}`; Julia's method resolution picks
# the more specific no-op over the AC body for DC formulations.

"""
Add reactive-power variables for a device and register them in the system's
`ReactivePowerBalance` expression. `var_types` is a tuple/iterable of
`VariableType` subtypes; each is added via `add_variables!` and then linked
into `ReactivePowerBalance` via `add_to_expression!`. The caller's
device-specific `add_to_expression!` methods are responsible for the actual
bus mapping and sign convention.
"""
function _maybe_add_reactive_power_variables!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{D, F},
    network_model::NetworkModel{<:AbstractPowerModel},
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

"""
Add a reactive-power-related constraint for a device on AC networks.
"""
function _maybe_add_reactive_power_constraints!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{D, F},
    network_model::NetworkModel{<:AbstractPowerModel},
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
