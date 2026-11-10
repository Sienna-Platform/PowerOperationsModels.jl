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
# array by dispatch instead of branching on runtime Symbol values — this keeps
# `PFContribution` concretely typed and `_write_value_to_pf_data!` type-stable.
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
# accumulates into `bus_hvdc_net_power`; voltage quantities are assigned to a bus-state array
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

_add_pf_power!(pf_data::PFS.PowerFlowData, ::PFActiveQuantity, comp, values) =
    PFS.add_active_power!(pf_data, comp, values)
_add_pf_power!(pf_data::PFS.PowerFlowData, ::PFReactiveQuantity, comp, values) =
    PFS.add_reactive_power!(pf_data, comp, values)

# Row `i` of `result.data` is the net injection of device `i` at every time step. The call passes
# a view of that row to PowerFlows.
function _write_value_to_pf_data!(
    pf_data::PFS.PowerFlowData,
    ::Val,
    container::OptimizationContainer,
    key::OptimizationContainerKey{T, U},
    component_map,
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

# A `SwitchedAdmittance` that the optimization models has a row in its reactive contribution.
# PowerFlows reads the admittance of every other one from the `System`.
function _modeled_switched_admittance_names(container::OptimizationContainer)
    if has_container_key(
        container,
        POM.ReactivePowerBalanceContribution,
        PSY.SwitchedAdmittance,
    )
        contribution = IOM.get_expression(
            container,
            POM.ReactivePowerBalanceContribution,
            PSY.SwitchedAdmittance,
        )
        return Set{String}(axes(contribution, 1))
    end
    return Set{String}()
end

function _add_unmodeled_switched_admittances!(
    pf_data::PFS.PowerFlowData,
    container::OptimizationContainer,
    sys::PSY.System,
)
    modeled = _modeled_switched_admittance_names(container)
    for sa in PSY.get_available_components(PSY.SwitchedAdmittance, sys)
        if PSY.get_name(sa) ∉ modeled
            PFS.add_switched_admittance!(pf_data, sa)
        end
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
    _add_unmodeled_switched_admittances!(pf_data, container, sys)
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

# Set the signed quantity on the component's field. `StandardLoad` (ZIP) has no scalar power
# field, so it routes to its constant-power component
# (`constant_active_power`/`constant_reactive_power`).
_set_comp_quantity!(comp::PSY.Component, ::PFActiveQuantity, v::Float64) =
    (comp.active_power = v)
_set_comp_quantity!(comp::PSY.Component, ::PFReactiveQuantity, v::Float64) =
    (comp.reactive_power = v)
_set_comp_quantity!(comp::PSY.StandardLoad, ::PFActiveQuantity, v::Float64) =
    (comp.constant_active_power = v)
_set_comp_quantity!(comp::PSY.StandardLoad, ::PFReactiveQuantity, v::Float64) =
    (comp.constant_reactive_power = v)
_set_comp_quantity!(comp::PSY.ACBus, ::PFAngleQuantity, v::Float64) = (comp.angle = v)
_set_comp_quantity!(comp::PSY.ACBus, ::PFMagnitudeQuantity, v::Float64) =
    (comp.magnitude = v)

function _set_comp_quantity!(
    comp::PSY.SynchronousCondenser,
    ::PFActiveQuantity,
    v::Float64,
)
    iszero(v) && return
    error(
        "SynchronousCondenser $(PSY.get_name(comp)) has no active power field, but its " *
        "active power contribution is $v.",
    )
end

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
        value = result[device_id, time_step]
        _set_comp_quantity!(
            comp,
            quantity,
            _system_sign(comp) * _pf_to_comp(quantity, value, sys_base, comp),
        )
    end
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
