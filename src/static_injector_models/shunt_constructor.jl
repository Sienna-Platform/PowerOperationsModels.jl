#################################################################################
# construct_device! for ShuntSusceptanceDispatch
#
# Two-stage construction:
#   ArgumentConstructStage — ShuntSusceptanceVariable + ReactivePowerVariable
#                            (both bounded per Principle 0); Q wired into balance.
#   ModelConstructStage    — Q = b·V² constraint (always); control-objective
#                            JuMP.fix (voltage control for FACTSControlDevice
#                            in NML mode).
#
# Active-power-only network no-ops are defensive; reactive formulations under DC
# templates are dropped by template_validation.jl before construction begins.
#################################################################################

# Fetch the voltage variable array(s) needed for V² once, before the device loop.
function _fetch_voltage_arrays(container, ::NetworkModel{ACPNetworkModel})
    return (get_variable(container, VoltageMagnitude, PSY.ACBus),)
end

function _fetch_voltage_arrays(
    container,
    ::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
)
    return (
        get_variable(container, VoltageReal, PSY.ACBus),
        get_variable(container, VoltageImaginary, PSY.ACBus),
    )
end

# Compute V² from pre-fetched variable array(s) — no container lookup in hot loop.
function _bus_voltage_squared(
    ::NetworkModel{ACPNetworkModel},
    vars,
    bus_name::String,
    t::Int,
)
    return vars[1][bus_name, t]^2
end

function _bus_voltage_squared(
    ::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
    vars,
    bus_name::String,
    t::Int,
)
    return vars[1][bus_name, t]^2 + vars[2][bus_name, t]^2
end

#################################################################################
# ArgumentConstructStage
#################################################################################

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{R, ShuntSusceptanceDispatch},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {R <: Union{PSY.SwitchedAdmittance, PSY.FACTSControlDevice}}
    devices = get_available_components(model, sys)
    add_variables!(container, ShuntSusceptanceVariable, devices, ShuntSusceptanceDispatch)
    add_variables!(container, ReactivePowerVariable, devices, ShuntSusceptanceDispatch)
    _add_shunt_regulated_voltage!(container, devices, sys, network_model)
    add_to_expression!(
        container,
        ReactivePowerBalance,
        ReactivePowerVariable,
        devices,
        model,
        network_model,
    )
    add_feedforward_arguments!(container, model, devices)
    return
end

# Defensive no-op for active-power-only networks; template_validation drops the
# reactive formulation first, so this path is only reached if someone bypasses
# template validation.
function construct_device!(
    ::OptimizationContainer,
    ::PSY.System,
    ::ArgumentConstructStage,
    ::DeviceModel{R, ShuntSusceptanceDispatch},
    ::NetworkModel{<:AbstractActivePowerModel},
) where {R <: Union{PSY.SwitchedAdmittance, PSY.FACTSControlDevice}}
    return
end

#################################################################################
# ModelConstructStage
#################################################################################

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{R, ShuntSusceptanceDispatch},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {R <: Union{PSY.SwitchedAdmittance, PSY.FACTSControlDevice}}
    devices = get_available_components(model, sys)
    add_constraints!(
        container,
        ShuntReactivePowerConstraint,
        sys,
        devices,
        model,
        network_model,
    )
    _add_shunt_regulated_voltage_constraints!(container, devices, sys, network_model)
    _apply_shunt_control_objective!(container, devices, network_model)
    add_feedforward_constraints!(container, model, devices)
    return
end

function construct_device!(
    ::OptimizationContainer,
    ::PSY.System,
    ::ModelConstructStage,
    ::DeviceModel{R, ShuntSusceptanceDispatch},
    ::NetworkModel{<:AbstractActivePowerModel},
) where {R <: Union{PSY.SwitchedAdmittance, PSY.FACTSControlDevice}}
    return
end

#################################################################################
# Q = b·V² constraint (always added; count-invariant across control modes)
#################################################################################

function add_constraints!(
    container::OptimizationContainer,
    ::Type{ShuntReactivePowerConstraint},
    ::PSY.System,
    devices::IS.FlattenIteratorWrapper{R},
    model::DeviceModel{R, ShuntSusceptanceDispatch},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {R <: Union{PSY.SwitchedAdmittance, PSY.FACTSControlDevice}}
    time_steps = get_time_steps(container)
    b = get_variable(container, ShuntSusceptanceVariable, R)
    q = get_variable(container, ReactivePowerVariable, R)
    names = [PSY.get_name(d) for d in devices]
    cons = add_constraints_container!(
        container,
        ShuntReactivePowerConstraint,
        R,
        names,
        time_steps,
    )
    jm = get_jump_model(container)
    v_arrays = _fetch_voltage_arrays(container, network_model)
    for (name, d) in zip(names, devices)
        bus_name = PSY.get_name(PSY.get_bus(d))
        _assert_bus_has_voltage_variables(
            v_arrays[1], bus_name, "connection bus of shunt $(name)",
        )
        for t in time_steps
            v2 = _bus_voltage_squared(network_model, v_arrays, bus_name, t)
            cons[name, t] = JuMP.@constraint(jm, q[name, t] == b[name, t] * v2)
        end
    end
    return
end

#################################################################################
# Regulated-voltage wiring (ACR/IVR aux magnitude variable).
#
# The regulating subset of ShuntSusceptanceDispatch is FACTSControlDevice, which
# regulates its own bus. SwitchedAdmittance does not regulate voltage. Both the
# aux variable (Argument) and its defining constraint (Model) are added for every
# FACTS device under ACR/IVR regardless of control mode (count-invariance); under
# ACP and for SwitchedAdmittance these wrappers fall through to the shared no-op.
#################################################################################

_regulated_buses(d::PSY.FACTSControlDevice, bus_by_number) = [("1", PSY.get_bus(d))]

function _add_shunt_regulated_voltage!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{PSY.FACTSControlDevice},
    sys::PSY.System,
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    add_regulated_voltage_magnitude!(
        container, devices, sys, network_model,
    )
    return
end

function _add_shunt_regulated_voltage_constraints!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{PSY.FACTSControlDevice},
    sys::PSY.System,
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    add_regulated_voltage_magnitude_constraints!(
        container, devices, sys, network_model,
    )
    return
end

# Non-regulating shunt devices (SwitchedAdmittance and any other StaticInjection):
# no aux variable/constraint.
function _add_shunt_regulated_voltage!(
    ::OptimizationContainer,
    ::IS.FlattenIteratorWrapper,
    ::PSY.System,
    ::NetworkModel{<:AbstractNetworkModel},
)
    return
end

function _add_shunt_regulated_voltage_constraints!(
    ::OptimizationContainer,
    ::IS.FlattenIteratorWrapper,
    ::PSY.System,
    ::NetworkModel{<:AbstractNetworkModel},
)
    return
end

#################################################################################
# Control-objective dispatch — pin voltage or free-optimize via JuMP.fix.
# Dispatch on device collection type (no isa checks).
#################################################################################

# SwitchedAdmittance: b and Q are pure optimization variables; no fix.
function _apply_shunt_control_objective!(
    ::OptimizationContainer,
    ::IS.FlattenIteratorWrapper{PSY.SwitchedAdmittance},
    ::NetworkModel{<:AbstractNetworkModel},
)
    return
end

# FACTSControlDevice under ACP/ACR/IVR: voltage-control (NML) mode pins the
# regulated bus magnitude — directly on the network VoltageMagnitude under ACP, or
# on the component-owned RegulatedVoltageMagnitude aux variable under ACR/IVR (see
# fix_regulated_voltage!). All other modes free-optimize (Q adjusts to network
# needs). The aux variable/constraint are always present under ACR/IVR, so only the
# fix is mode-conditional (count-invariance).
function _apply_shunt_control_objective!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{PSY.FACTSControlDevice},
    network_model::NetworkModel{
        <:Union{ACPNetworkModel, ACRNetworkModel, IVRNetworkModel},
    },
)
    for d in devices
        mode = PSY.get_control_mode(d)
        if mode == PSY.FACTSOperationModes.NML
            fix_regulated_voltage!(
                container, d, "1", PSY.get_bus(d), PSY.get_voltage_setpoint(d),
                network_model,
            )
        end
    end
    return
end

# FACTSControlDevice under any other AC network (no scalar/aux magnitude support):
# no voltage fix.
function _apply_shunt_control_objective!(
    ::OptimizationContainer,
    ::IS.FlattenIteratorWrapper{PSY.FACTSControlDevice},
    ::NetworkModel{<:AbstractNetworkModel},
)
    return
end
