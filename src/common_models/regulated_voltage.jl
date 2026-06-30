#################################################################################
# Component-owned auxiliary voltage-magnitude variable for ACR/IVR voltage
# regulation — one per (component, tag).
#
# Under ACP a VOLTAGE control objective is enforced by `JuMP.fix`-ing the network
# `VoltageMagnitude` (a scalar real variable) at the regulated bus. ACR/IVR expose
# only `VoltageReal`/`VoltageImaginary`, with no scalar magnitude primitive, so a
# regulating component (shunt FACTS device, voltage-controlling tap transformer,
# voltage-controlling VSC) instead owns one or more auxiliary
# `RegulatedVoltageMagnitude` variables:
#   - keyed by (regulating component name, tag),
#   - bounded by its regulated bus's voltage limits (finite — Principle 0),
#   - tied to the bus by `RegulatedVoltageMagnitudeConstraint`:
#         vm_reg² == vr[reg_bus]² + vi[reg_bus]²
#   - pinned to the setpoint by `fix_regulated_voltage!` only when the device's
#     control objective for that tag's terminal is VOLTAGE.
#
# The `tag` is a caller-supplied string that names the terminal being regulated:
# "1" for single-bus devices (shunt, tap); "from"/"to" for two-terminal VSCs.
#
# Count-invariance: the aux variable and its defining constraint are created for
# EVERY (component, tag) pair regardless of control objective, so a
# voltage-objective and a reactive-objective template produce identical
# variable/constraint containers. Only the `JuMP.fix` is conditional.
#
# Under ACP every helper here is a no-op (ACP regulates the network
# `VoltageMagnitude`), which keeps the existing ACP count-invariance unchanged.
#
# Callers supply `reg_buses_of(d) -> Vector{Tuple{String, PSY.ACBus}}` returning
# (tag, bus) pairs. Single-bus devices return a one-element vector.
# All components in the iterator must return the same tag set.
#################################################################################

# Find the regulated bus for a given tag in a tag-bus list.
function _reg_bus_for_tag(tag_buses, tag::String)
    for (t, bus) in tag_buses
        if t == tag
            return bus
        end
    end
    error("No bus registered for voltage-regulation tag $(repr(tag))")
end

# --- ARGUMENT stage: declare the bounded aux variable (no network-var dependency) ---

function add_regulated_voltage_magnitude!(
    container::OptimizationContainer,
    components::IS.FlattenIteratorWrapper{T},
    reg_buses_of,
    ::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
) where {T <: PSY.Component}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in components]
    jm = get_jump_model(container)
    # Collect (name, tag_buses) once; all components share the same tag set
    # (count-invariant formulation guarantee).
    rows = [(PSY.get_name(d), reg_buses_of(d)) for d in components]
    for (tag, _) in rows[1][2]
        var = add_variable_container!(
            container, RegulatedVoltageMagnitude, T, names, time_steps; meta = tag,
        )
        for (name, tag_buses) in rows
            bus = _reg_bus_for_tag(tag_buses, tag)
            vlim = PSY.get_voltage_limits(bus)
            lo = vlim.min
            hi = vlim.max
            if !(isfinite(lo) && isfinite(hi))
                error(
                    "Regulated bus $(PSY.get_name(bus)) for $(T) $(name) has non-finite ",
                    "voltage_limits ($(lo), $(hi)); cannot bound RegulatedVoltageMagnitude",
                )
            end
            v0 = PSY.get_magnitude(bus)
            for t in time_steps
                var[name, t] = JuMP.@variable(
                    jm,
                    base_name = "RegulatedVoltageMagnitude_$(T)_{$(name), $(t)}_$(tag)",
                    lower_bound = lo,
                    upper_bound = hi,
                    start = v0,
                )
            end
        end
    end
    return
end

function add_regulated_voltage_magnitude!(
    ::OptimizationContainer,
    ::IS.FlattenIteratorWrapper,
    reg_buses_of,
    ::NetworkModel{<:AbstractPowerModel},
)
    return
end

# --- MODEL stage: tie each aux variable to (vr, vi) at its regulated bus ---

function add_regulated_voltage_magnitude_constraints!(
    container::OptimizationContainer,
    components::IS.FlattenIteratorWrapper{T},
    reg_buses_of,
    ::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
) where {T <: PSY.Component}
    time_steps = get_time_steps(container)
    vr = get_variable(container, VoltageReal, PSY.ACBus)
    vi = get_variable(container, VoltageImaginary, PSY.ACBus)
    names = [PSY.get_name(d) for d in components]
    jm = get_jump_model(container)
    rows = [(PSY.get_name(d), reg_buses_of(d)) for d in components]
    for (tag, _) in rows[1][2]
        vm_reg = get_variable(container, RegulatedVoltageMagnitude, T, tag)
        cons = add_constraints_container!(
            container, RegulatedVoltageMagnitudeConstraint, T, names, time_steps;
            meta = tag,
        )
        for (name, tag_buses) in rows
            bus_name = PSY.get_name(_reg_bus_for_tag(tag_buses, tag))
            for t in time_steps
                cons[name, t] = JuMP.@constraint(
                    jm,
                    vm_reg[name, t]^2 == vr[bus_name, t]^2 + vi[bus_name, t]^2,
                )
            end
        end
    end
    return
end

function add_regulated_voltage_magnitude_constraints!(
    ::OptimizationContainer,
    ::IS.FlattenIteratorWrapper,
    reg_buses_of,
    ::NetworkModel{<:AbstractPowerModel},
)
    return
end

# --- Pin the regulated magnitude to its setpoint (VOLTAGE objective only) ---

# ACP: pin the network VoltageMagnitude at the regulated bus. The tag is unused.
function fix_regulated_voltage!(
    container::OptimizationContainer,
    ::T,
    ::String,
    reg_bus::PSY.ACBus,
    setpoint::Float64,
    ::NetworkModel{ACPNetworkModel},
) where {T <: PSY.Component}
    time_steps = get_time_steps(container)
    vm = get_variable(container, VoltageMagnitude, PSY.ACBus)
    bus_name = PSY.get_name(reg_bus)
    for t in time_steps
        JuMP.fix(vm[bus_name, t], setpoint; force = true)
    end
    return
end

# ACR/IVR: pin the (component, tag)-owned RegulatedVoltageMagnitude aux variable.
# The defining constraint then forces vr² + vi² == setpoint² at the regulated bus.
function fix_regulated_voltage!(
    container::OptimizationContainer,
    component::T,
    tag::String,
    ::PSY.ACBus,
    setpoint::Float64,
    ::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
) where {T <: PSY.Component}
    time_steps = get_time_steps(container)
    vm_reg = get_variable(container, RegulatedVoltageMagnitude, T, tag)
    name = PSY.get_name(component)
    for t in time_steps
        JuMP.fix(vm_reg[name, t], setpoint; force = true)
    end
    return
end
