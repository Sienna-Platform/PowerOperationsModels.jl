# Shared AC/DC converter control primitives. They operate on plain JuMP variable
# arrays + scalars so both TwoTerminalVSCLine (once per from/to terminal) and
# InterconnectingConverter (once per converter) reuse them.

# PSY stores HVDC quantities in natural units. System per-unit bases: S in MVA,
# V in kV, Z = V^2 / S (ohm), Y = 1 / Z (S), I = 1000 * S / V (A).
_ohm_to_su(z::Float64, v_base::Float64, s_base::Float64) = z * s_base / v_base^2
_siemens_to_su(g::Float64, v_base::Float64, s_base::Float64) = g * v_base^2 / s_base
_amps_to_su(i::Float64, v_base::Float64, s_base::Float64) = i * v_base / (1000.0 * s_base)
_kv_to_su(v::Float64, v_base::Float64) = v / v_base
_kv_per_mw_to_su(droop::Float64, v_base::Float64, s_base::Float64) =
    droop * s_base / v_base

_bus_base_voltage(bus::PSY.Bus) = _bus_base_voltage(PSY.get_base_voltage(bus), bus)
_bus_base_voltage(v::Float64, ::PSY.Bus) = v
_bus_base_voltage(::Nothing, bus::PSY.Bus) = error(
    "Bus $(PSY.get_name(bus)) has no base_voltage, so the HVDC quantities in kV, ohm, " *
    "S, or A at it cannot be per-unitized.",
)

# A kV base field where 0.0 means "unspecified".
function _nonzero_base_voltage(v::Float64, field::String, d::PSY.Component)
    if iszero(v)
        error(
            "$(nameof(typeof(d))) $(PSY.get_name(d)): $(field) is 0.0, so the fields in " *
            "kV, ohm, S, or A cannot be per-unitized. Set $(field) in kV.",
        )
    end
    return v
end

# A control mode selects one setpoint field; every other setpoint field is `nothing`.
_mode_setpoint(value::Float64, ::String, ::PSY.Component) = value
_mode_setpoint(::Nothing, field::String, d::PSY.Component) = error(
    "$(nameof(typeof(d))) $(PSY.get_name(d)): its control mode needs $(field), which " *
    "is nothing.",
)

# Pin a converter/terminal reactive injection at its setpoint. Shared by both AC
# control primitives so the AC_REACTIVE_POWER enforcement lives in one place.
# `setpoint` is system-base reactive power (pu MVAr).
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
