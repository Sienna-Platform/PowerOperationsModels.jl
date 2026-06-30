# Shared AC/DC converter control primitives. They operate on plain JuMP variable
# arrays + scalars so both TwoTerminalVSCLine (once per from/to terminal) and
# InterconnectingConverter (once per converter) reuse them.

# Pin a converter/terminal reactive injection at its setpoint. Shared by both AC
# control primitives so the AC_REACTIVE_POWER enforcement lives in one place.
function _pin_converter_reactive!(q_var, name::String, setpoint::Float64, time_steps)
    for t in time_steps
        JuMP.fix(q_var[name, t], setpoint; force = true)
    end
    return
end

# AC control on one terminal/converter: AC_VOLTAGE pins the regulated bus
# VoltageMagnitude; AC_REACTIVE_POWER pins the reactive injection to its setpoint.
function _fix_converter_ac_control!(
    mode::PSY.VSCACControlModes,
    setpoint::Float64,
    vm,
    bus_name::String,
    q_var,
    name::String,
    time_steps,
)
    if mode == PSY.VSCACControlModes.AC_VOLTAGE
        for t in time_steps
            JuMP.fix(vm[bus_name, t], setpoint; force = true)
        end
    elseif mode == PSY.VSCACControlModes.AC_REACTIVE_POWER
        _pin_converter_reactive!(q_var, name, setpoint, time_steps)
    end
    return
end

# Fill one terminal/converter's HVDCDCControlConstraint row for all time steps.
# Always written (count-invariant across DC control modes). `vdc_var` is indexed by
# the same `name` key as `p_var` and `con`.
function _fill_converter_dc_control!(
    jump_model,
    con::AbstractArray,
    mode::PSY.VSCDCControlModes,
    setpoint::Float64,
    droop_gain::Float64,
    vdc_var,
    p_var,
    name::String,
    time_steps,
)
    if mode == PSY.VSCDCControlModes.DC_VOLTAGE
        for t in time_steps
            con[name, t] = JuMP.@constraint(jump_model, vdc_var[name, t] == setpoint)
        end
    elseif mode == PSY.VSCDCControlModes.DC_POWER
        for t in time_steps
            con[name, t] = JuMP.@constraint(jump_model, p_var[name, t] == setpoint)
        end
    elseif mode == PSY.VSCDCControlModes.DC_VOLTAGE_DROOP
        for t in time_steps
            con[name, t] = JuMP.@constraint(
                jump_model,
                vdc_var[name, t] + droop_gain * p_var[name, t] == setpoint,
            )
        end
    else
        error("Unrecognized VSCDCControlModes value $(mode) on converter $(name).")
    end
    return
end

# AC reactive control (ACR/IVR path, where AC_VOLTAGE is routed once-per-device
# through the RegulatedVoltageMagnitude aux variable by the caller, not here):
# AC_REACTIVE_POWER pins the reactive injection; AC_VOLTAGE is a no-op here.
function _fix_converter_ac_reactive!(
    mode::PSY.VSCACControlModes,
    setpoint::Float64,
    q_var,
    name::String,
    time_steps,
)
    if mode == PSY.VSCACControlModes.AC_REACTIVE_POWER
        _pin_converter_reactive!(q_var, name, setpoint, time_steps)
    end
    return
end
