#################################################################################
# VoltageControlConverter — AC-network construct + count-invariant control layer
# for `PSY.InterconnectingConverter`.
#
# The DC-side physics (ActivePowerVariable, ConverterCurrent /
# CurrentAbsoluteValueVariable, per-DCBus DCVoltage via DCCurrentBalance, and the
# quadratic ConverterLossConstraint) is built by the shared
# `_add_converter_dc_arguments!` / `_add_converter_dc_model!` helpers in
# hvdcsystems_constructor.jl — exactly the same builders the active-power-network
# QuadraticLossConverter construct uses. This file adds the AC-side layer:
#
#   - a bounded ReactivePowerVariable injected into ReactivePowerBalance at the
#     converter's AC bus (via `_maybe_add_reactive_power_variables!`),
#   - a component-owned RegulatedVoltageMagnitude aux variable for ACR/IVR voltage
#     regulation (no-op under ACP, which regulates the network VoltageMagnitude),
#   - the apparent-power capability disk p² + q² ≤ rating²,
#   - one always-present HVDCDCControlConstraint per converter per time step
#     (DC_VOLTAGE / DC_POWER / DC_VOLTAGE_DROOP), and per-mode AC control
#     (AC_VOLTAGE pins the regulated voltage, AC_REACTIVE_POWER pins Q).
#
# Count-invariance: the aux voltage variable + its constraint and the
# HVDCDCControlConstraint container are created regardless of control mode; only
# per-mode coefficients / JuMP.fix differ. A template differing only in a
# converter's ac_control / dc_control therefore produces identical
# variable/constraint containers.
#################################################################################

const _VoltageControlConverterACNetwork =
    Union{ACPNetworkModel, ACRNetworkModel, IVRNetworkModel}

# The converter regulates its AC bus (get_bus), not its DC bus.
_regulated_buses(d::PSY.InterconnectingConverter, bus_by_number) = [("1", PSY.get_bus(d))]

# Apparent-power capability disk p² + q² ≤ rating² (one entry per converter per
# time step). rating is a required InterconnectingConverter field, so always finite.
function _add_ic_apparent_power_limit!(
    container::OptimizationContainer,
    devices,
    ::DeviceModel{PSY.InterconnectingConverter, VoltageControlConverter},
    ::NetworkModel{<:_VoltageControlConverterACNetwork},
)
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    jump_model = get_jump_model(container)
    p_var = get_variable(container, ActivePowerVariable, PSY.InterconnectingConverter)
    q_var = get_variable(container, ReactivePowerVariable, PSY.InterconnectingConverter)
    cons = add_constraints_container!(
        container, ConverterPowerCapabilityConstraint, PSY.InterconnectingConverter,
        names, time_steps,
    )
    for d in devices
        name = PSY.get_name(d)
        s2 = PSY.get_rating(d, PSY.SU)^2
        for t in time_steps
            cons[name, t] = JuMP.@constraint(
                jump_model, p_var[name, t]^2 + q_var[name, t]^2 <= s2,
            )
        end
    end
    return
end

# Name-keyed view of the per-DCBus DCVoltage variable: the shared
# `_fill_converter_dc_control!` indexes vdc by the same converter `name` key as
# p_var/con, so re-key each converter's DCVoltage[dc_bus] under its own name. The
# elements are the same VariableRefs (`_voltage_expr_per_converter`).
function _vdc_by_converter_name(container, devices, names, time_steps)
    return _voltage_expr_per_converter(container, devices, names, time_steps)
end

# ACP: pin the AC-controlled quantity via JuMP.fix on the network VoltageMagnitude /
# the reactive injection; one HVDCDCControlConstraint per converter per time step.
function _apply_ic_control_objective!(
    container::OptimizationContainer,
    devices,
    ::DeviceModel{PSY.InterconnectingConverter, VoltageControlConverter},
    ::NetworkModel{ACPNetworkModel},
)
    time_steps = get_time_steps(container)
    vm = get_variable(container, VoltageMagnitude, PSY.ACBus)
    q_var = get_variable(container, ReactivePowerVariable, PSY.InterconnectingConverter)
    p_var = get_variable(container, ActivePowerVariable, PSY.InterconnectingConverter)
    names = [PSY.get_name(d) for d in devices]
    vdc = _vdc_by_converter_name(container, devices, names, time_steps)
    jump_model = get_jump_model(container)
    con = add_constraints_container!(
        container, HVDCDCControlConstraint, PSY.InterconnectingConverter,
        names, time_steps,
    )
    for d in devices
        name = PSY.get_name(d)
        bus_name = PSY.get_name(PSY.get_bus(d))
        _fix_converter_ac_control!(
            PSY.get_ac_control(d), PSY.get_ac_setpoint(d),
            vm, bus_name, q_var, name, time_steps,
        )
        _fill_converter_dc_control!(
            jump_model, con,
            PSY.get_dc_control(d), PSY.get_dc_setpoint(d), PSY.get_dc_voltage_droop(d),
            vdc, p_var, name, time_steps,
        )
    end
    return
end

# ACR/IVR: AC_VOLTAGE pins the component-owned RegulatedVoltageMagnitude aux
# variable; AC_REACTIVE_POWER pins the reactive injection; one
# HVDCDCControlConstraint per converter per time step.
function _apply_ic_control_objective!(
    container::OptimizationContainer,
    devices,
    ::DeviceModel{PSY.InterconnectingConverter, VoltageControlConverter},
    network_model::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
)
    time_steps = get_time_steps(container)
    q_var = get_variable(container, ReactivePowerVariable, PSY.InterconnectingConverter)
    p_var = get_variable(container, ActivePowerVariable, PSY.InterconnectingConverter)
    names = [PSY.get_name(d) for d in devices]
    vdc = _vdc_by_converter_name(container, devices, names, time_steps)
    jump_model = get_jump_model(container)
    con = add_constraints_container!(
        container, HVDCDCControlConstraint, PSY.InterconnectingConverter,
        names, time_steps,
    )
    for d in devices
        name = PSY.get_name(d)
        ac_mode = PSY.get_ac_control(d)
        if ac_mode == PSY.VSCACControlModes.AC_VOLTAGE
            fix_regulated_voltage!(
                container, d, "1", PSY.get_bus(d), PSY.get_ac_setpoint(d), network_model,
            )
        end
        _fix_converter_ac_reactive!(
            ac_mode,
            PSY.get_ac_setpoint(d),
            q_var,
            name,
            time_steps,
        )
        _fill_converter_dc_control!(
            jump_model, con,
            PSY.get_dc_control(d), PSY.get_dc_setpoint(d), PSY.get_dc_voltage_droop(d),
            vdc, p_var, name, time_steps,
        )
    end
    return
end

############################################
########## AC-network construct ############
############################################

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{PSY.InterconnectingConverter, VoltageControlConverter},
    network_model::NetworkModel{<:_VoltageControlConverterACNetwork},
)
    devices = get_available_components(model, sys)
    _add_converter_dc_arguments!(container, devices, model, network_model)
    _maybe_add_reactive_power_variables!(
        container, devices, model, network_model, (ReactivePowerVariable,),
    )
    # Component-owned aux magnitude var for ACR/IVR voltage regulation (no-op under
    # ACP); created regardless of ac_control mode for count-invariance.
    add_regulated_voltage_magnitude!(
        container, devices, sys, network_model,
    )
    add_feedforward_arguments!(container, model, devices)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{PSY.InterconnectingConverter, VoltageControlConverter},
    network_model::NetworkModel{<:_VoltageControlConverterACNetwork},
)
    devices = get_available_components(model, sys)
    _add_converter_dc_model!(container, devices, model, network_model)
    add_regulated_voltage_magnitude_constraints!(
        container, devices, sys, network_model,
    )
    _add_ic_apparent_power_limit!(container, devices, model, network_model)
    _apply_ic_control_objective!(container, devices, model, network_model)
    add_feedforward_constraints!(container, model, devices)
    add_to_objective_function!(
        container, devices, model, get_network_formulation(network_model),
    )
    add_constraint_dual!(container, sys, model)
    return
end
