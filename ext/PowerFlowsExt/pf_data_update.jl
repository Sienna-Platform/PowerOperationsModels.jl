# Power flow in-the-loop: data update logic.
# Three owners share the work.
# The balance contribution of a device holds the value. POM records it when it builds the nodal
# balance.
# PowerFlows selects the array that receives the value.
# This extension routes each contribution to a PowerFlows function. It does not write the active
# or reactive power arrays by field.
# Voltage and HVDC values have no contribution. `PFContribution` resolves their sign and array:
#   quantity : PFActiveQuantity | PFReactiveQuantity | PFAngleQuantity | PFMagnitudeQuantity
#   role     : PFHVDCNetRole (an HVDC flow) | PFNoRole (a voltage, which assigns to a bus-state
#              array selected by quantity)
#   sign     : multiplier of the value (+1 / -1)
# `quantity`/`role` are singleton tag types (not `Symbol`s) so the writers resolve the target
# array by dispatch instead of branching on runtime Symbol values. This keeps `PFContribution`
# concretely typed and the voltage and HVDC method of `_write_value_to_pf_data!` type-stable.
# The contribution method reads an abstractly typed result.
abstract type PFQuantity end
struct PFActiveQuantity <: PFQuantity end
struct PFReactiveQuantity <: PFQuantity end
struct PFAngleQuantity <: PFQuantity end
struct PFMagnitudeQuantity <: PFQuantity end

abstract type PFRole end
struct PFHVDCNetRole <: PFRole end
struct PFNoRole <: PFRole end

struct PFContribution{Q <: PFQuantity, R <: PFRole}
    quantity::Q
    role::R
    sign::Float64
end

const _PF_FLOW_ENTRY = Union{VariableType, AuxVariableType}
const _PF_PARAM_ENTRY = ParameterType

# ---- voltage entries (variable and auxiliary variable) ----
pf_contribution(
    ::Union{Val{:voltage_angle_export}, Val{:voltage_angle_opf}},
    ::Type{<:_PF_FLOW_ENTRY},
    ::Type{<:PSY.ACBus},
) = PFContribution(PFAngleQuantity(), PFNoRole(), 1.0)
pf_contribution(
    ::Union{Val{:voltage_magnitude_export}, Val{:voltage_magnitude_opf}},
    ::Type{<:_PF_FLOW_ENTRY},
    ::Type{<:PSY.ACBus},
) = PFContribution(PFMagnitudeQuantity(), PFNoRole(), 1.0)

# ---- HVDC / PST two-terminal (variable entries) ----
# HVDC re-targets to `:hvdc_net` (`bus_hvdc_net_power`); signs follow the injection convention.
# from_to: -1. to_from: `FlowActivePowerToFromVariable` is -tf, signed negative for from→to flow
# (sign -1); a single `FlowActivePowerVariable` (lossless / PowerModels `:p_dc`) is +flow (sign +1).
pf_contribution(
    ::Val{:active_power_hvdc_pst_from_to},
    ::Type{<:_PF_FLOW_ENTRY},
    ::Type{<:PSY.TwoTerminalHVDC},
) = PFContribution(PFActiveQuantity(), PFHVDCNetRole(), -1.0)
pf_contribution(
    ::Val{:active_power_hvdc_pst_to_from},
    ::Type{POM.FlowActivePowerToFromVariable},
    ::Type{<:PSY.TwoTerminalHVDC},
) = PFContribution(PFActiveQuantity(), PFHVDCNetRole(), -1.0)
pf_contribution(
    ::Val{:active_power_hvdc_pst_to_from},
    ::Type{POM.FlowActivePowerVariable},
    ::Type{<:PSY.TwoTerminalHVDC},
) = PFContribution(PFActiveQuantity(), PFHVDCNetRole(), 1.0)

# ---- voltage entries (parameter) ----
pf_contribution(
    ::Union{Val{:voltage_angle_export}, Val{:voltage_angle_opf}},
    ::Type{<:_PF_PARAM_ENTRY},
    ::Type{<:PSY.ACBus},
) = PFContribution(PFAngleQuantity(), PFNoRole(), 1.0)
pf_contribution(
    ::Union{Val{:voltage_magnitude_export}, Val{:voltage_magnitude_opf}},
    ::Type{<:_PF_PARAM_ENTRY},
    ::Type{<:PSY.ACBus},
) = PFContribution(PFMagnitudeQuantity(), PFNoRole(), 1.0)

# ---- PowerFlowData writer ----
# Active and reactive power go to PowerFlows through the balance contributions. An HVDC flow
# accumulates into `bus_hvdc_net_power`. Voltage quantities are assigned to a bus-state array
# selected by quantity.
_pf_writes_voltage(::PFQuantity) = false
_pf_writes_voltage(::PFAngleQuantity) = true
_pf_writes_voltage(::PFMagnitudeQuantity) = true

_pf_array(pfd::PFS.PowerFlowData, ::PFActiveQuantity, ::PFHVDCNetRole) =
    pfd.bus_hvdc_net_power
_pf_bus_state_array(pfd::PFS.PowerFlowData, ::PFAngleQuantity) = pfd.bus_angles
_pf_bus_state_array(pfd::PFS.PowerFlowData, ::PFMagnitudeQuantity) = pfd.bus_magnitude

# Function barrier: `category`, `T` (entry type) and `U` (component type) are compile-time
# constants here, so `pf_contribution` resolves statically and the resulting singleton
# `quantity`/`role` dispatch the array lookup with no runtime Symbol branching. One (dynamic)
# dispatch into this method happens per (category, key) in the caller's loop.
function _write_value_to_pf_data!(
    pf_data::PFS.PowerFlowData,
    ::Val{category},
    container::OptimizationContainer,
    key::OptimizationContainerKey{T, U},
    component_map,
    ::PSY.System,
) where {category, T, U}
    result = lookup_value(container, key)
    c = pf_contribution(Val(category), T, U)
    # Resolve the target array once per key so the inner write loop runs on a concrete `Matrix`.
    if _pf_writes_voltage(c.quantity)
        _write_pf_array!(_pf_bus_state_array(pf_data, c.quantity), true, c.sign,
            component_map, container, result)
    else
        _write_pf_array!(_pf_array(pf_data, c.quantity, c.role), false, c.sign,
            component_map, container, result)
    end
    return
end

_contribution_quantity(::Type{POM.ActivePowerBalanceContribution}) = PFActiveQuantity()
_contribution_quantity(::Type{POM.ReactivePowerBalanceContribution}) = PFReactiveQuantity()

_add_pf_power!(
    pf_data::PFS.PowerFlowData,
    ::PFActiveQuantity,
    comp::PSY.StaticInjection,
    values,
) = PFS.add_active_power!(pf_data, comp, values)
_add_pf_power!(
    pf_data::PFS.PowerFlowData,
    ::PFReactiveQuantity,
    comp::PSY.StaticInjection,
    values,
) = PFS.add_reactive_power!(pf_data, comp, values)

_add_pf_load!(
    pf_data::PFS.PowerFlowData,
    ::PFActiveQuantity,
    load::PSY.ElectricLoad,
    parts,
) = PFS.add_active_power!(
    pf_data, load, parts.constant_power, parts.constant_current, parts.constant_impedance,
)
_add_pf_load!(
    pf_data::PFS.PowerFlowData,
    ::PFReactiveQuantity,
    load::PSY.ElectricLoad,
    parts,
) = PFS.add_reactive_power!(
    pf_data, load, parts.constant_power, parts.constant_current, parts.constant_impedance,
)

# A load goes to PowerFlows as three arrays: constant power, current and impedance.
function _load_parts(::PFS.PowerFlowData, ::PFQuantity, ::PSY.ElectricLoad, row)
    return (
        constant_power = row,
        constant_current = zeros(length(row)),
        constant_impedance = zeros(length(row)),
    )
end

function _load_parts(::PFS.PowerFlowData, quantity::PFQuantity, load::POM.ZipLoad, row)
    parameter = _zip_parameter(quantity)
    constant_power = zeros(length(row))
    constant_current = zeros(length(row))
    constant_impedance = zeros(length(row))
    for t in eachindex(row)
        amounts = POM.split_zip_value(parameter, load, Float64(row[t]))
        constant_power[t] = amounts.constant_power
        constant_current[t] = amounts.constant_current
        constant_impedance[t] = amounts.constant_impedance
    end
    return (;
        constant_power = constant_power,
        constant_current = constant_current,
        constant_impedance = constant_impedance,
    )
end

_exponential_exponent(::PFActiveQuantity, load::PSY.ExponentialLoad) = PSY.get_α(load)
_exponential_exponent(::PFReactiveQuantity, load::PSY.ExponentialLoad) = PSY.get_β(load)

# Same rule as the PowerFlows System build. P0 * V^e is a constant power (e = 0), constant
# current (e = 1) or constant impedance (e = 2) term. DC data sums the three, so any exponent
# is a constant power term there.
function _load_parts(
    ::PFS.PowerFlowData{<:PFS.AbstractACPowerFlow},
    quantity::PFQuantity,
    load::PSY.ExponentialLoad,
    row,
)
    exponent = _exponential_exponent(quantity, load)
    zero_row = zeros(length(row))
    if iszero(exponent)
        return (
            constant_power = row, constant_current = zero_row, constant_impedance = zero_row,
        )
    elseif exponent == 1.0
        return (
            constant_power = zero_row, constant_current = row, constant_impedance = zero_row,
        )
    elseif exponent == 2.0
        return (
            constant_power = zero_row, constant_current = zero_row, constant_impedance = row,
        )
    end
    error(
        "ExponentialLoad $(PSY.get_name(load)) has voltage exponent $exponent. Only 0, 1 " *
        "and 2 map to a ZIP term.",
    )
end

function _add_pf_load_row!(
    pf_data::PFS.PowerFlowData,
    quantity::PFQuantity,
    load::PSY.ElectricLoad,
    row,
)
    _add_pf_load!(pf_data, quantity, load, _load_parts(pf_data, quantity, load, row))
    return
end

_add_pf_power!(
    pf_data::PFS.PowerFlowData,
    quantity::PFActiveQuantity,
    load::PSY.ElectricLoad,
    row,
) = _add_pf_load_row!(pf_data, quantity, load, row)
_add_pf_power!(
    pf_data::PFS.PowerFlowData,
    quantity::PFReactiveQuantity,
    load::PSY.ElectricLoad,
    row,
) = _add_pf_load_row!(pf_data, quantity, load, row)

# `update_pf_data!` writes the admittance of a switched shunt from the susceptance variable or
# the System.
_add_pf_power!(::PFS.PowerFlowData, ::PFActiveQuantity, ::PSY.SwitchedAdmittance, _) =
    nothing
_add_pf_power!(::PFS.PowerFlowData, ::PFReactiveQuantity, ::PSY.SwitchedAdmittance, _) =
    nothing

# Row `i` of `result.data` is the net injection of device `i` at every time step. The call passes
# a view of that row to PowerFlows.
function _write_value_to_pf_data!(
    pf_data::PFS.PowerFlowData,
    ::Val,
    container::OptimizationContainer,
    key::OptimizationContainerKey{T, U},
    _,
    sys::PSY.System,
) where {
    T <: Union{POM.ActivePowerBalanceContribution, POM.ReactivePowerBalanceContribution},
    U,
}
    result = lookup_value(container, key)
    quantity = _contribution_quantity(T)
    for (i, name) in enumerate(axes(result, 1))
        _add_pf_power!(
            pf_data,
            quantity,
            PSY.get_component(U, sys, name),
            view(result.data, i, :),
        )
    end
    return
end

# Function barrier: `arr` is a concrete `Matrix{Float64}`, so the per-(device, time) loop is
# monomorphic. `assign` overwrites (voltages); otherwise contributions accumulate.
function _write_pf_array!(
    arr::Matrix{Float64},
    assign::Bool,
    value_sign::Float64,
    component_map,
    container::OptimizationContainer,
    result,
)
    for (device_name, index) in component_map
        for t in get_time_steps(container)
            value = result[device_name, t]
            if assign
                arr[index, t] = value
            else
                arr[index, t] += value_sign * value
            end
        end
    end
    return
end

# Net-interchange schedules (PDES) per time step. PowerFlows reads the `Area` field once at
# construction. POM writes the schedule of the optimization (series if the area has one, else the
# field) for every enrolled area. Only `ACPowerFlowData` has enrolled areas.
_update_area_schedules!(::PFS.PowerFlowData, ::OptimizationContainer, ::PSY.System) = nothing

function _update_area_schedules!(
    pf_data::PFS.ACPowerFlowData,
    container::OptimizationContainer,
    sys::PSY.System,
)
    for area in PSY.get_components(PSY.Area, sys)
        name = PSY.get_name(area)
        PFS.has_controlled_area(pf_data, name) || continue
        for t in get_time_steps(container)
            PFS.set_scheduled_net_interchange!(
                pf_data, name, t, _area_schedule_pu(container, area, t),
            )
        end
    end
    return
end

# System base, positive for export.
function _area_schedule_pu(container::OptimizationContainer, area::PSY.Area, t::Int)
    name = PSY.get_name(area)
    if POM._has_net_interchange_series_parameter(container, name)
        series = lookup_value(
            container, ParameterKey(POM.ScheduledNetInterchangeParameter, PSY.Area),
        )
        return Float64(series[name, t])
    end
    return PSY.get_scheduled_net_interchange(area, u"SU")
end

# A shunt with a susceptance variable takes its susceptance from the model. PowerFlows reads
# the admittance of every other one from the `System`.
function _add_switched_admittances!(
    pf_data::PFS.PowerFlowData,
    container::OptimizationContainer,
    sys::PSY.System,
)
    modeled = Dict{String, Vector{Float64}}()
    if has_container_key(container, POM.ShuntSusceptanceVariable, PSY.SwitchedAdmittance)
        modeled = _status_by_name(
            lookup_value(
                container,
                VariableKey(POM.ShuntSusceptanceVariable, PSY.SwitchedAdmittance),
            ),
        )
    end
    for sa in PSY.get_available_components(PSY.SwitchedAdmittance, sys)
        _add_switched_admittance!(pf_data, sa, modeled)
    end
    return
end

function _add_switched_admittance!(pf_data, sa, modeled::Dict{String, Vector{Float64}})
    name = PSY.get_name(sa)
    if haskey(modeled, name)
        PFS.add_switched_admittance!(pf_data, sa, modeled[name])
    else
        PFS.add_switched_admittance!(pf_data, sa)
    end
    return
end

function update_pf_data!(
    pf_e_data::PowerFlowEvaluationData{<:PFS.PowerFlowData},
    container::OptimizationContainer,
    sys::PSY.System,
)
    pf_data = IOM.get_inner_data(pf_e_data)
    PFS.clear_injection_data!(pf_data)
    _add_switched_admittances!(pf_data, container, sys)
    for sc in PSY.get_available_components(PSY.SynchronousCondenser, sys)
        PFS.add_active_power_losses!(pf_data, sc)
    end
    # `clear_injection_data!` does not reset `bus_hvdc_net_power`, which PowerFlows seeds from the
    # system at construction. Zero it before re-writing optimized HVDC flows, else the seed
    # double-counts (AC, #1635) or shadows the optimized DC flow. Co-located with the repopulate
    # below so they can't desync; skipped only if a `PowerFlowData` opts out of hvdc_pst.
    isempty(pf_input_keys_hvdc_pst(pf_data)) || (pf_data.bus_hvdc_net_power .= 0.0)
    input_map = get_input_key_map(pf_e_data)
    for (category, inputs) in input_map
        @debug "Writing $category to $(nameof(typeof(pf_data)))"
        for (key, component_map) in inputs
            _write_value_to_pf_data!(
                pf_data, Val(category), container, key, component_map, sys,
            )
        end
    end
    return
end

# ---- System writer: contributions and `PFContribution`, sunk into component fields ----
# PERF direct dot access + manual unit conversions for performance and convenience.
# active/reactive convert to the component base; voltages are written raw.
_pf_to_comp(::Union{PFActiveQuantity, PFReactiveQuantity}, value::Float64, sys_base::Float64,
    comp::PSY.Component) = value * sys_base / PSY.get_base_power(comp, u"NU")
_pf_to_comp(
    ::Union{PFAngleQuantity, PFMagnitudeQuantity},
    value::Float64,
    ::Float64,
    ::PSY.Component,
) = value

# Set the signed quantity on the component's field. A ZIP load has three fields per quantity,
# so `_write_contribution!` handles it.
_set_comp_quantity!(comp::PSY.Component, ::PFActiveQuantity, v::Float64) =
    (comp.active_power = v)
_set_comp_quantity!(comp::PSY.Component, ::PFReactiveQuantity, v::Float64) =
    (comp.reactive_power = v)
_set_comp_quantity!(comp::PSY.ACBus, ::PFAngleQuantity, v::Float64) = (comp.angle = v)
_set_comp_quantity!(comp::PSY.ACBus, ::PFMagnitudeQuantity, v::Float64) =
    (comp.magnitude = v)

# A type with no field for a quantity accepts only a zero value.
function _reject_nonzero_quantity(comp::PSY.Component, quantity::PFQuantity, v::Float64)
    iszero(v) && return
    error(
        "$(nameof(typeof(comp))) $(PSY.get_name(comp)) has no field for the " *
        "$(nameof(typeof(quantity))), but its contribution is $v.",
    )
end

_set_comp_quantity!(comp::PSY.SynchronousCondenser, q::PFActiveQuantity, v::Float64) =
    _reject_nonzero_quantity(comp, q, v)
_set_comp_quantity!(comp::PSY.InterconnectingConverter, q::PFReactiveQuantity, v::Float64) =
    _reject_nonzero_quantity(comp, q, v)
_set_comp_quantity!(comp::PSY.SwitchedAdmittance, q::PFActiveQuantity, v::Float64) =
    _reject_nonzero_quantity(comp, q, v)
_set_comp_quantity!(comp::PSY.FACTSControlDevice, q::PFActiveQuantity, v::Float64) =
    _reject_nonzero_quantity(comp, q, v)

# The FACTS device holds its voltage setpoint. The power flow solves its reactive power.
_set_comp_quantity!(::PSY.FACTSControlDevice, ::PFReactiveQuantity, ::Float64) = nothing

# PSY stores a load as a positive consumption, but its contribution is a negative injection.
_system_sign(::PSY.StaticInjection) = 1.0
_system_sign(::PSY.ElectricLoad) = -1.0

function _apply_component_contribution!(
    comp::PSY.Component,
    c::PFContribution,
    value::Float64,
    sys_base::Float64,
)
    v = c.sign * _pf_to_comp(c.quantity, value, sys_base, comp)
    _set_comp_quantity!(comp, c.quantity, v)
    return
end

# Function barrier mirroring `_write_value_to_pf_data!`: `category`/`T`/`U` are compile-time
# constants, so `pf_contribution` and `PSY.get_component(U, …)` resolve statically and the
# singleton `quantity` dispatches the field writes in `_apply_component_contribution!`.
function _write_component_contributions!(
    sys::PSY.System,
    container::OptimizationContainer,
    ::Val{category},
    key::OptimizationContainerKey{T, U},
    component_map,
    time_step::Int,
) where {category, T, U}
    result = lookup_value(container, key)
    c = pf_contribution(Val(category), T, U)
    sys_base = IOM.get_model_base_power(container)
    for (device_id, device_name) in component_map
        comp = PSY.get_component(U, sys, device_name)
        val = result[device_id, time_step]
        _apply_component_contribution!(comp, c, val, sys_base)
    end
    return
end

# A contribution is a signed injection. `_system_sign` gives the sign that the component field
# uses.
function _write_component_contributions!(
    sys::PSY.System,
    container::OptimizationContainer,
    ::Val,
    key::OptimizationContainerKey{T, U},
    component_map,
    time_step::Int,
) where {
    T <: Union{POM.ActivePowerBalanceContribution, POM.ReactivePowerBalanceContribution},
    U,
}
    result = lookup_value(container, key)
    quantity = _contribution_quantity(T)
    sys_base = IOM.get_model_base_power(container)
    for (device_id, device_name) in component_map
        comp = PSY.get_component(U, sys, device_name)
        _write_contribution!(
            container, comp, quantity, result[device_id, time_step], sys_base, time_step,
        )
    end
    return
end

function _write_contribution!(
    ::OptimizationContainer,
    comp::PSY.Component,
    quantity::PFQuantity,
    value::Float64,
    sys_base::Float64,
    ::Int,
)
    _set_comp_quantity!(
        comp,
        quantity,
        _system_sign(comp) * _pf_to_comp(quantity, value, sys_base, comp),
    )
    return
end

_zip_parameter(::PFActiveQuantity) = POM.ActivePowerTimeSeriesParameter
_zip_parameter(::PFReactiveQuantity) = POM.ReactivePowerTimeSeriesParameter

function _set_zip_field!(load::POM.ZipLoad, ::PFActiveQuantity, amounts)
    load.constant_active_power = amounts.constant_power
    load.current_active_power = amounts.constant_current
    load.impedance_active_power = amounts.constant_impedance
    return
end

function _set_zip_field!(load::POM.ZipLoad, ::PFReactiveQuantity, amounts)
    load.constant_reactive_power = amounts.constant_power
    load.current_reactive_power = amounts.constant_current
    load.impedance_reactive_power = amounts.constant_impedance
    return
end

# The contribution is the total of the three ZIP parts. Each part gets its share.
function _write_contribution!(
    ::OptimizationContainer,
    load::POM.ZipLoad,
    quantity::Union{PFActiveQuantity, PFReactiveQuantity},
    value::Float64,
    sys_base::Float64,
    ::Int,
)
    amounts = POM.split_zip_value(_zip_parameter(quantity), load, value)
    sign = _system_sign(load)
    _set_zip_field!(
        load,
        quantity,
        map(a -> sign * _pf_to_comp(quantity, a, sys_base, load), amounts),
    )
    return
end

# The susceptance variable is the solved admittance. A shunt with a fixed admittance has no
# variable, and its System admittance is the value that the model uses.
function _write_contribution!(
    container::OptimizationContainer,
    shunt::PSY.SwitchedAdmittance,
    ::PFReactiveQuantity,
    ::Float64,
    ::Float64,
    time_step::Int,
)
    if has_container_key(container, POM.ShuntSusceptanceVariable, PSY.SwitchedAdmittance)
        susceptance = lookup_value(
            container,
            VariableKey(POM.ShuntSusceptanceVariable, PSY.SwitchedAdmittance),
        )
        shunt.solved_admittance = susceptance[PSY.get_name(shunt), time_step]
    end
    return
end

function _pumped_power(
    container::OptimizationContainer,
    ::Type{U},
    name::String,
    time_step::Int,
) where {U <: PSY.HydroPumpTurbine}
    if has_container_key(container, POM.ActivePowerPumpVariable, U)
        pump = lookup_value(container, VariableKey(POM.ActivePowerPumpVariable, U))
        return pump[name, time_step]
    end
    return 0.0
end

# The turbine and the pump have separate variables. The net contribution would hide both.
function _write_contribution!(
    container::OptimizationContainer,
    comp::PSY.HydroPumpTurbine,
    quantity::PFActiveQuantity,
    ::Float64,
    sys_base::Float64,
    time_step::Int,
)
    name = PSY.get_name(comp)
    turbine = lookup_value(container, VariableKey(IOM.ActivePowerVariable, typeof(comp)))
    comp.active_power =
        _pf_to_comp(quantity, Float64(turbine[name, time_step]), sys_base, comp)
    comp.active_power_pump = _pf_to_comp(
        quantity,
        Float64(_pumped_power(container, typeof(comp), name, time_step)),
        sys_base,
        comp,
    )
    return
end

function update_pf_system!(
    sys::PSY.System,
    container::OptimizationContainer,
    input_map::Dict{Symbol, <:Dict{OptimizationContainerKey, <:Any}},
    time_step::Int,
)
    for (category, inputs) in input_map
        @debug "Writing $category to (possibly internal) System"
        for (key, component_map) in inputs
            _write_component_contributions!(
                sys, container, Val(category), key, component_map, time_step)
        end
    end
    return
end

"""
Update a `PowerFlowEvaluationData` containing a `PowerFlowContainer` that does not
`supports_multi_period` using a single `time_step` of the `OptimizationContainer`. To
properly keep track of outer step number, time steps must be passed in sequentially,
starting with 1.
"""
function update_pf_data!(
    pf_e_data::PowerFlowEvaluationData{PFS.PSSEExporter},
    container::OptimizationContainer,
    time_step::Int,
)
    pf_data = IOM.get_inner_data(pf_e_data)
    input_map = get_input_key_map(pf_e_data)
    update_pf_system!(PFS.get_system(pf_data), container, input_map, time_step)
    if !isnothing(pf_data.step)
        outer_step, _... = pf_data.step
        # time_step == 1 means we have rolled over to a new outer step
        # NOTE this is brittle but there is currently no way of getting this information
        # from upstream; may change in the future.
        (time_step == 1) && (outer_step += 1)
        pf_data.step = (outer_step, time_step)
    end
    return
end
