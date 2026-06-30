#################################################################################
# VoltageControlVSC (Family C) — count-invariant control-mode layer.
#
# The full VSC NLP (variables, cable Ohm's law, converter power balance, bounded
# reactive injection into ReactivePowerBalance, and the apparent-power capability
# disk) is built by the shared
#   construct_device!(TwoTerminalVSCLine, <:AbstractTwoTerminalVSCFormulation)
# path in branch_constructor.jl. This file adds the control constraints: one
# HVDCDCControlConstraint per terminal per time step (always present regardless
# of DC control mode), plus per-mode handling for AC control.
#
# DC control modes:
#   DC_VOLTAGE:       vdc[t] == dc_setpoint
#   DC_POWER:         p[t]   == dc_setpoint
#   DC_VOLTAGE_DROOP: vdc[t] + droop_gain * p[t] == dc_setpoint
# Constraint containers (meta = "from" / "to") are allocated once before the
# device loop, so variable + constraint counts are identical across all modes.
#
# AC voltage control is supported under ACP, ACR, and IVR. Under ACR/IVR, each
# terminal owns a RegulatedVoltageMagnitude aux variable (meta = "from" or "to")
# so both terminals can hold AC_VOLTAGE simultaneously (each pins its own bus).
# HVDCTwoTerminalVSC keeps its control-free behavior (the no-ops below).
#################################################################################

# Argument-stage: add one RegulatedVoltageMagnitude aux variable per terminal
# (tags "from" and "to") under ACR/IVR (no-op under ACP). Only VoltageControlVSC
# regulates voltage; other VSC formulations fall through to the no-op below.
function _add_vsc_regulated_voltage!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, VoltageControlVSC},
    network_model::NetworkModel{<:AbstractPowerModel},
) where {U <: PSY.TwoTerminalVSCLine}
    add_regulated_voltage_magnitude!(
        container, devices, _vsc_regulated_buses, network_model,
    )
    return
end

function _add_vsc_regulated_voltage!(
    ::OptimizationContainer,
    ::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, <:AbstractTwoTerminalVSCFormulation},
    ::NetworkModel{<:AbstractPowerModel},
) where {U <: PSY.TwoTerminalVSCLine}
    return
end

# Model-stage: tie each per-terminal aux variable to (vr, vi) at its bus (ACR/IVR).
function _add_vsc_regulated_voltage_constraints!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, VoltageControlVSC},
    network_model::NetworkModel{<:AbstractPowerModel},
) where {U <: PSY.TwoTerminalVSCLine}
    add_regulated_voltage_magnitude_constraints!(
        container, devices, _vsc_regulated_buses, network_model,
    )
    return
end

function _add_vsc_regulated_voltage_constraints!(
    ::OptimizationContainer,
    ::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, <:AbstractTwoTerminalVSCFormulation},
    ::NetworkModel{<:AbstractPowerModel},
) where {U <: PSY.TwoTerminalVSCLine}
    return
end

# AC control (_fix_converter_ac_control!), DC control (_fill_converter_dc_control!),
# and AC reactive control (_fix_converter_ac_reactive!) are the shared primitives in
# common_models/converter_control.jl, applied here once per terminal (from/to).

# Default: no control layer (covers HVDCTwoTerminalVSC and any non-ACP network).
function _apply_vsc_control_objective!(
    ::OptimizationContainer,
    ::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, <:AbstractTwoTerminalVSCFormulation},
    ::NetworkModel{<:AbstractPowerModel},
) where {U <: PSY.TwoTerminalVSCLine}
    return
end

# VoltageControlVSC under ACP: pin the AC-controlled quantity per terminal via
# JuMP.fix; add one HVDCDCControlConstraint per terminal per time step for the
# DC-controlled quantity (mode-invariant containers, meta = "from" / "to").
function _apply_vsc_control_objective!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, VoltageControlVSC},
    ::NetworkModel{ACPNetworkModel},
) where {U <: PSY.TwoTerminalVSCLine}
    time_steps = get_time_steps(container)
    vm = get_variable(container, VoltageMagnitude, PSY.ACBus)
    q_f = get_variable(container, HVDCReactivePowerFromVariable, U)
    q_t = get_variable(container, HVDCReactivePowerToVariable, U)
    p_ft = get_variable(container, FlowActivePowerFromToVariable, U)
    p_tf = get_variable(container, FlowActivePowerToFromVariable, U)
    v_f = get_variable(container, HVDCFromDCVoltage, U)
    v_t = get_variable(container, HVDCToDCVoltage, U)
    names = [PSY.get_name(d) for d in devices]
    jump_model = get_jump_model(container)
    con_from = add_constraints_container!(
        container, HVDCDCControlConstraint, U, names, time_steps; meta = "from",
    )
    con_to = add_constraints_container!(
        container, HVDCDCControlConstraint, U, names, time_steps; meta = "to",
    )
    for d in devices
        name = PSY.get_name(d)
        arc = PSY.get_arc(d)
        from_bus = PSY.get_name(PSY.get_from(arc))
        to_bus = PSY.get_name(PSY.get_to(arc))
        _fix_converter_ac_control!(
            PSY.get_ac_control_from(d), PSY.get_ac_setpoint_from(d),
            vm, from_bus, q_f, name, time_steps,
        )
        _fill_converter_dc_control!(
            jump_model,
            con_from,
            PSY.get_dc_control_from(d),
            PSY.get_dc_setpoint_from(d),
            PSY.get_dc_voltage_droop_from(d),
            v_f, p_ft, name, time_steps,
        )
        _fix_converter_ac_control!(
            PSY.get_ac_control_to(d), PSY.get_ac_setpoint_to(d),
            vm, to_bus, q_t, name, time_steps,
        )
        _fill_converter_dc_control!(
            jump_model,
            con_to,
            PSY.get_dc_control_to(d),
            PSY.get_dc_setpoint_to(d),
            PSY.get_dc_voltage_droop_to(d),
            v_t, p_tf, name, time_steps,
        )
    end
    return
end

# Both AC terminals are always declared as regulatable; tags "from" and "to" key
# the per-terminal RegulatedVoltageMagnitude aux variables under ACR/IVR.
function _vsc_regulated_buses(d::PSY.TwoTerminalVSCLine)
    arc = PSY.get_arc(d)
    return [("from", PSY.get_from(arc)), ("to", PSY.get_to(arc))]
end

# VoltageControlVSC under ACR/IVR: DC controls use HVDCDCControlConstraint
# containers (mode-invariant, meta = "from" / "to"); AC reactive control pins
# existing variables via JuMP.fix; AC voltage control pins the per-terminal
# RegulatedVoltageMagnitude aux variable. Both terminals can hold AC_VOLTAGE
# simultaneously — each pins its own tagged aux var at its own bus.
function _apply_vsc_control_objective!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, VoltageControlVSC},
    network_model::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
) where {U <: PSY.TwoTerminalVSCLine}
    time_steps = get_time_steps(container)
    q_f = get_variable(container, HVDCReactivePowerFromVariable, U)
    q_t = get_variable(container, HVDCReactivePowerToVariable, U)
    p_ft = get_variable(container, FlowActivePowerFromToVariable, U)
    p_tf = get_variable(container, FlowActivePowerToFromVariable, U)
    v_f = get_variable(container, HVDCFromDCVoltage, U)
    v_t = get_variable(container, HVDCToDCVoltage, U)
    names = [PSY.get_name(d) for d in devices]
    jump_model = get_jump_model(container)
    con_from = add_constraints_container!(
        container, HVDCDCControlConstraint, U, names, time_steps; meta = "from",
    )
    con_to = add_constraints_container!(
        container, HVDCDCControlConstraint, U, names, time_steps; meta = "to",
    )
    for d in devices
        name = PSY.get_name(d)
        arc = PSY.get_arc(d)
        ac_from = PSY.get_ac_control_from(d)
        ac_to = PSY.get_ac_control_to(d)
        if ac_from == PSY.VSCACControlModes.AC_VOLTAGE
            fix_regulated_voltage!(
                container, d, "from", PSY.get_from(arc), PSY.get_ac_setpoint_from(d),
                network_model,
            )
        end
        if ac_to == PSY.VSCACControlModes.AC_VOLTAGE
            fix_regulated_voltage!(
                container, d, "to", PSY.get_to(arc), PSY.get_ac_setpoint_to(d),
                network_model,
            )
        end
        _fix_converter_ac_reactive!(
            ac_from,
            PSY.get_ac_setpoint_from(d),
            q_f,
            name,
            time_steps,
        )
        _fix_converter_ac_reactive!(ac_to, PSY.get_ac_setpoint_to(d), q_t, name, time_steps)
        _fill_converter_dc_control!(
            jump_model,
            con_from,
            PSY.get_dc_control_from(d),
            PSY.get_dc_setpoint_from(d),
            PSY.get_dc_voltage_droop_from(d),
            v_f, p_ft, name, time_steps,
        )
        _fill_converter_dc_control!(
            jump_model,
            con_to,
            PSY.get_dc_control_to(d),
            PSY.get_dc_setpoint_to(d),
            PSY.get_dc_voltage_droop_to(d),
            v_t, p_tf, name, time_steps,
        )
    end
    return
end
