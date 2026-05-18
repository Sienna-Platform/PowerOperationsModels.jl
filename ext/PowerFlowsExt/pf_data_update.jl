# Power flow in-the-loop: data update logic.
# Ported from PowerSimulations.jl/src/network_models/power_flow_evaluation.jl
# (lines 385-576). Defines update_pf_data! (PowerFlowData and PSSEExporter
# variants), _update_component!, update_pf_system!, and helpers.

# How to update the PowerFlowData given a component type. A bit duplicative of code in PowerFlows.jl.
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power},
    ::Type{<:PSY.StaticInjection},
    index,
    t,
    value,
) = (pf_data.bus_active_power_injections[index, t] += value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power},
    ::Type{<:PSY.ElectricLoad},
    index,
    t,
    value,
) = (pf_data.bus_active_power_withdrawals[index, t] -= value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:reactive_power},
    ::Type{<:PSY.StaticInjection},
    index,
    t,
    value,
) = (pf_data.bus_reactive_power_injections[index, t] += value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:reactive_power},
    ::Type{<:PSY.ElectricLoad},
    index,
    t,
    value,
) = (pf_data.bus_reactive_power_withdrawals[index, t] -= value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Union{Val{:voltage_angle_export}, Val{:voltage_angle_opf}},
    ::Type{<:PSY.ACBus},
    index,
    t,
    value,
) = (pf_data.bus_angles[index, t] = value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Union{Val{:voltage_magnitude_export}, Val{:voltage_magnitude_opf}},
    ::Type{<:PSY.ACBus},
    index,
    t,
    value,
) = (pf_data.bus_magnitude[index, t] = value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_hvdc_pst_from_to},
    ::Type{<:PSY.TwoTerminalHVDC},
    index,
    t,
    value,
) = (pf_data.bus_active_power_injections[index, t] -= value)
# FlowActivePowerToFromVariable is signed negative when power flows from→to (since
# `tf_var + ft_var == losses ≥ 0`), so subtracting yields the correct positive
# injection at the receiving bus.
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_hvdc_pst_to_from},
    ::Type{<:PSY.TwoTerminalHVDC},
    index,
    t,
    value,
) = (pf_data.bus_active_power_injections[index, t] -= value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_hvdc_pst_from_to},
    ::Type{<:PSY.PhaseShiftingTransformer},
    index,
    t,
    value,
) = (pf_data.bus_active_power_injections[index, t] -= value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_hvdc_pst_to_from},
    ::Type{<:PSY.PhaseShiftingTransformer},
    index,
    t,
    value,
) = (pf_data.bus_active_power_injections[index, t] += value)

function _write_value_to_pf_data!(
    pf_data::PFS.PowerFlowData,
    category::Symbol,
    container::OptimizationContainer,
    key::OptimizationContainerKey,
    component_map,
)
    result = lookup_value(container, key)
    for (device_name, index) in component_map
        injection_values = result[device_name, :]
        for t in get_time_steps(container)
            value = jump_value(injection_values[t])
            _update_pf_data_component!(
                pf_data,
                Val(category),
                get_component_type(key),
                index,
                t,
                value,
            )
        end
    end
    return
end

function update_pf_data!(
    pf_e_data::PowerFlowEvaluationData{<:PFS.PowerFlowData},
    container::OptimizationContainer,
)
    pf_data = IOM.get_inner_data(pf_e_data)
    PFS.clear_injection_data!(pf_data)
    input_map = get_input_key_map(pf_e_data)
    for (category, inputs) in input_map
        @debug "Writing $category to $(nameof(typeof(pf_data)))"
        for (key, component_map) in inputs
            _write_value_to_pf_data!(pf_data, category, container, key, component_map)
        end
    end
    return
end

# PERF direct dot access + manual unit conversions for performance and convenience
_update_component!(comp::PSY.Component, ::Val{:active_power}, value, sys_base) =
    (comp.active_power = value * sys_base / PSY.get_base_power(comp))
# Sign is flipped for loads
_update_component!(comp::PSY.ElectricLoad, ::Val{:active_power}, value, sys_base) =
    (comp.active_power = -value * sys_base / PSY.get_base_power(comp))
_update_component!(comp::PSY.Component, ::Val{:reactive_power}, value, sys_base) =
    (comp.reactive_power = value * sys_base / PSY.get_base_power(comp))
_update_component!(comp::PSY.ElectricLoad, ::Val{:reactive_power}, value, sys_base) =
    (comp.reactive_power = -value * sys_base / PSY.get_base_power(comp))
_update_component!(
    comp::PSY.ACBus,
    ::Union{Val{:voltage_angle_export}, Val{:voltage_angle_opf}},
    value,
    sys_base,
) = (comp.angle = value)
_update_component!(
    comp::PSY.ACBus,
    ::Union{Val{:voltage_magnitude_export}, Val{:voltage_magnitude_opf}},
    value,
    sys_base,
) = (comp.magnitude = value)

function update_pf_system!(
    sys::PSY.System,
    container::OptimizationContainer,
    input_map::Dict{Symbol, <:Dict{OptimizationContainerKey, <:Any}},
    time_step::Int,
)
    for (category, inputs) in input_map
        @debug "Writing $category to (possibly internal) System"
        for (key, component_map) in inputs
            result = lookup_value(container, key)
            for (device_id, device_name) in component_map
                injection_values = result[device_id, :]
                comp = PSY.get_component(get_component_type(key), sys, device_name)
                val = jump_value(injection_values[time_step])
                _update_component!(
                    comp,
                    Val(category),
                    val,
                    IOM.get_model_base_power(container),
                )
            end
        end
    end
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
