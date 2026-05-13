# Helpers for variables/constraints that should only appear when the network
# model actually represents the relevant physical quantity (e.g. reactive
# power on AC networks). Generic over device type, variable types, and
# constraint type so any formulation can adopt the pattern.

"""
Add reactive-power variables for a device and register them in the system's
`ReactivePowerBalance` expression. Only fires on AC networks
(`NetworkModel{<:AbstractPowerModel}`); no-op on active-power-only networks.

`var_types` is a tuple/iterable of `VariableType` subtypes; each is added via
`add_variables!` and then linked into `ReactivePowerBalance` via
`add_to_expression!`. The caller's device-specific `add_to_expression!`
methods are responsible for the actual bus mapping and sign convention.
"""
function _maybe_add_reactive_power_variables!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{D, F},
    network_model::NetworkModel{N},
    var_types,
) where {D <: PSY.Device, F, N <: AbstractPowerModel}
    if N <: AbstractActivePowerModel
        return
    end
    for V in var_types
        add_variables!(container, V, devices, F)
        add_to_expression!(
            container, ReactivePowerBalance, V,
            devices, model, network_model,
        )
    end
    return
end

"""
Add a reactive-power-related constraint for a device only on AC networks
(`NetworkModel{<:AbstractPowerModel}`). No-op on active-power-only networks.
"""
function _maybe_add_reactive_power_constraints!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{D, F},
    network_model::NetworkModel{N},
    constraint_type::Type{<:ConstraintType},
) where {D <: PSY.Device, F, N <: AbstractPowerModel}
    if N <: AbstractActivePowerModel
        return
    end
    add_constraints!(container, constraint_type, devices, model, network_model)
    return
end
