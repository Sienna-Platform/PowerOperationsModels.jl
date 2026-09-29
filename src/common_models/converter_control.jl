# Shared AC/DC converter control primitives. They operate on plain JuMP variable
# arrays + scalars so both TwoTerminalVSCLine (once per from/to terminal) and
# InterconnectingConverter (once per converter) reuse them.

# The setpoint a converter's control mode selects; PSY leaves the others `nothing`.
function _required_setpoint(value::Union{Nothing, Float64}, field::String, name::String)
    isnothing(value) && throw(
        ArgumentError(
            "Converter $(name): its control mode selects $(field), which is nothing.",
        ),
    )
    return value
end

# AC-side target: the AC voltage (pu) under AC_VOLTAGE, the reactive injection (pu) under
# AC_REACTIVE_POWER. A fixed power factor is modeled at unity only, where Q = 0 for any P.
function _converter_ac_setpoint(
    mode::PSY.VSCACControlModes.Value,
    ac_voltage_setpoint::Union{Nothing, Float64},
    power_factor_setpoint::Union{Nothing, Float64},
    name::String,
)
    if mode == PSY.VSCACControlModes.AC_VOLTAGE
        return _required_setpoint(ac_voltage_setpoint, "ac_voltage_setpoint", name)
    elseif mode == PSY.VSCACControlModes.AC_REACTIVE_POWER
        pf = _required_setpoint(power_factor_setpoint, "power_factor_setpoint", name)
        isapprox(abs(pf), 1.0) || throw(
            ArgumentError(
                "Converter $(name): power_factor_setpoint $(pf) is not unity; \
                 AC_REACTIVE_POWER is modeled at unity power factor only.",
            ),
        )
        return 0.0
    end
    error("Unrecognized VSCACControlModes value $(mode) on converter $(name).")
end

# DC-side target: the active-power order (system pu) under DC_POWER, the DC voltage (pu)
# under DC_VOLTAGE and DC_VOLTAGE_DROOP.
function _converter_dc_setpoint(
    mode::PSY.VSCDCControlModes.Value,
    dc_power_setpoint::Union{Nothing, Float64},
    dc_voltage_setpoint::Union{Nothing, Float64},
    name::String,
)
    mode == PSY.VSCDCControlModes.DC_POWER &&
        return _required_setpoint(dc_power_setpoint, "dc_power_setpoint", name)
    return _required_setpoint(dc_voltage_setpoint, "dc_voltage_setpoint", name)
end

_ac_setpoint(d::PSY.InterconnectingConverter) = _converter_ac_setpoint(
    PSY.get_ac_control(d), PSY.get_ac_voltage_setpoint(d),
    PSY.get_power_factor_setpoint(d), PSY.get_name(d),
)
_dc_setpoint(d::PSY.InterconnectingConverter) = _converter_dc_setpoint(
    PSY.get_dc_control(d), PSY.get_dc_power_setpoint(d, PSY.SU),
    PSY.get_dc_voltage_setpoint(d), PSY.get_name(d),
)
_ac_setpoint_from(d::PSY.TwoTerminalVSCLine) = _converter_ac_setpoint(
    PSY.get_ac_control_from(d), PSY.get_ac_voltage_setpoint_from(d),
    PSY.get_power_factor_setpoint_from(d), "$(PSY.get_name(d)) from",
)
_ac_setpoint_to(d::PSY.TwoTerminalVSCLine) = _converter_ac_setpoint(
    PSY.get_ac_control_to(d), PSY.get_ac_voltage_setpoint_to(d),
    PSY.get_power_factor_setpoint_to(d), "$(PSY.get_name(d)) to",
)
_dc_setpoint_from(d::PSY.TwoTerminalVSCLine) = _converter_dc_setpoint(
    PSY.get_dc_control_from(d), PSY.get_dc_power_setpoint_from(d, PSY.SU),
    PSY.get_dc_voltage_setpoint_from(d), "$(PSY.get_name(d)) from",
)
_dc_setpoint_to(d::PSY.TwoTerminalVSCLine) = _converter_dc_setpoint(
    PSY.get_dc_control_to(d), PSY.get_dc_power_setpoint_to(d, PSY.SU),
    PSY.get_dc_voltage_setpoint_to(d), "$(PSY.get_name(d)) to",
)

# Pin a converter/terminal reactive injection (system pu) at its setpoint. Shared by
# both AC control primitives so the AC_REACTIVE_POWER enforcement lives in one place.
function _pin_converter_reactive!(q_var, name::String, setpoint::Float64, time_steps)
    for t in time_steps
        JuMP.fix(q_var[name, t], setpoint; force = true)
    end
    return
end

# AC control on one terminal/converter: AC_VOLTAGE pins the regulated bus
# VoltageMagnitude; AC_REACTIVE_POWER pins the reactive injection to its setpoint.
function _fix_converter_ac_control!(
    mode::PSY.VSCACControlModes.Value,
    setpoint::Float64,
    vm,
    bus_name::String,
    q_var,
    name::String,
    time_steps,
)
    if mode == PSY.VSCACControlModes.AC_VOLTAGE
        _assert_bus_has_voltage_variables(
            vm, bus_name, "AC-voltage-controlled terminal of converter $(name)",
        )
        for t in time_steps
            JuMP.fix(vm[bus_name, t], setpoint; force = true)
        end
    elseif mode == PSY.VSCACControlModes.AC_REACTIVE_POWER
        _pin_converter_reactive!(q_var, name, setpoint, time_steps)
    end
    return
end

# LPACC twin of `_fix_converter_ac_control!`: the network voltage variable is the
# magnitude deviation phi = |V| - 1, so AC_VOLTAGE pins phi to setpoint - 1.
# AC_REACTIVE_POWER pins the reactive injection to its setpoint, unshifted.
function _fix_converter_ac_control_lpacc!(
    mode::PSY.VSCACControlModes.Value,
    setpoint::Float64,
    phi,
    bus_name::String,
    q_var,
    name::String,
    time_steps,
)
    if mode == PSY.VSCACControlModes.AC_VOLTAGE
        _assert_bus_has_voltage_variables(
            phi, bus_name, "AC-voltage-controlled terminal of converter $(name)",
        )
        for t in time_steps
            JuMP.fix(phi[bus_name, t], setpoint - 1.0; force = true)
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
    mode::PSY.VSCDCControlModes.Value,
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
    mode::PSY.VSCACControlModes.Value,
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
