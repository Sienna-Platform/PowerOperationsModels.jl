# Power flow in-the-loop: data update logic.
# Ported from PowerSimulations.jl/src/network_models/power_flow_evaluation.jl
# (lines 385-576). Defines update_pf_data! (PowerFlowData and PSSEExporter
# variants), _update_component!, update_pf_system!, and helpers.

# How to update the PowerFlowData given a component type. A bit duplicative of code in PowerFlows.jl.
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power},
    ::Type{<:PSY.StaticInjection},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_active_power_injections[index, t] += value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power},
    ::Type{<:PSY.ElectricLoad},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_active_power_withdrawals[index, t] -= value)
# ActivePowerOutVariable represents power output (positive injection into the grid)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_out},
    ::Type{<:PSY.StaticInjection},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_active_power_injections[index, t] += value)
# ActivePowerInVariable represents power input (withdrawal from the grid, e.g. storage charging)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_in},
    ::Type{<:PSY.StaticInjection},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_active_power_injections[index, t] -= value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:reactive_power},
    ::Type{<:PSY.StaticInjection},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_reactive_power_injections[index, t] += value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:reactive_power},
    ::Type{<:PSY.ElectricLoad},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_reactive_power_withdrawals[index, t] -= value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Union{Val{:voltage_angle_export}, Val{:voltage_angle_opf}},
    ::Type{<:PSY.ACBus},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_angles[index, t] = value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Union{Val{:voltage_magnitude_export}, Val{:voltage_magnitude_opf}},
    ::Type{<:PSY.ACBus},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_magnitude[index, t] = value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_hvdc_pst_from_to},
    ::Type{<:PSY.TwoTerminalHVDC},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_active_power_injections[index, t] -= value)
# FlowActivePowerToFromVariable is signed negative when power flows from→to (since
# `tf_var + ft_var == losses ≥ 0`), so subtracting yields the correct positive
# injection at the receiving bus.
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_hvdc_pst_to_from},
    ::Type{<:PSY.TwoTerminalHVDC},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_active_power_injections[index, t] -= value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_hvdc_pst_from_to},
    ::Type{<:PSY.PhaseShiftingTransformer},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_active_power_injections[index, t] -= value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_hvdc_pst_to_from},
    ::Type{<:PSY.PhaseShiftingTransformer},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_active_power_injections[index, t] += value)

# Parameters store the already-signed nodal contribution (`param_array .* multiplier_array`,
# applied by `lookup_value`/`calculate_parameter_values`), identical to what
# `add_to_expression!` adds to the system balance. Variables/aux-vars instead store an
# unsigned magnitude whose direction comes from the input category. The two therefore need
# different sign handling when written into the PowerFlowData injections.
_pf_input_presigned(::OptimizationContainerKey) = false
_pf_input_presigned(::ParameterKey) = true

# Add a parameter's already-signed nodal contribution directly to the net bus injection.
# A `StaticInjection` contributes to injections (`+=`); an `ElectricLoad`'s withdrawal is the
# negated contribution (`withdrawals -= value`). No category sign is applied here — direction
# already lives in the parameter multiplier, so re-applying it would double-count.
_add_signed_pf_injection!(
    pf_data::PFS.PowerFlowData,
    ::Union{Val{:active_power}, Val{:active_power_in}, Val{:active_power_out}},
    ::Type{<:PSY.StaticInjection},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_active_power_injections[index, t] += value)
_add_signed_pf_injection!(
    pf_data::PFS.PowerFlowData,
    ::Val{:reactive_power},
    ::Type{<:PSY.StaticInjection},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_reactive_power_injections[index, t] += value)
_add_signed_pf_injection!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power},
    ::Type{<:PSY.ElectricLoad},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_active_power_withdrawals[index, t] -= value)
_add_signed_pf_injection!(
    pf_data::PFS.PowerFlowData,
    ::Val{:reactive_power},
    ::Type{<:PSY.ElectricLoad},
    index::Int,
    t::Int,
    value::Float64,
) = (pf_data.bus_reactive_power_withdrawals[index, t] -= value)
# Sign-agnostic categories (voltage exports / opf) carry no direction, so delegate to the
# shared writer. Parameters never feed these today; this keeps the dispatch total.
_add_signed_pf_injection!(
    pf_data::PFS.PowerFlowData,
    category::Val,
    comp_type::Type,
    index::Int,
    t::Int,
    value::Float64,
) = _update_pf_data_component!(pf_data, category, comp_type, index, t, value)

function _write_value_to_pf_data!(
    pf_data::PFS.PowerFlowData,
    category::Symbol,
    container::OptimizationContainer,
    key::OptimizationContainerKey,
    component_map,
)
    result = lookup_value(container, key)
    presigned = _pf_input_presigned(key)
    for (device_name, index) in component_map
        injection_values = result[device_name, :]
        for t in get_time_steps(container)
            value = jump_value(injection_values[t])
            if presigned
                _add_signed_pf_injection!(
                    pf_data,
                    Val(category),
                    get_component_type(key),
                    index,
                    t,
                    value,
                )
            else
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
_update_component!(
    comp::PSY.Component,
    ::Val{:active_power},
    value::Float64,
    sys_base::Float64,
) = (comp.active_power = value * sys_base / PSY.get_base_power(comp, PSY.NU))
# Sign is flipped for loads
_update_component!(
    comp::PSY.ElectricLoad,
    ::Val{:active_power},
    value::Float64,
    sys_base::Float64,
) = (comp.active_power = -value * sys_base / PSY.get_base_power(comp, PSY.NU))
_update_component!(
    comp::PSY.Component,
    ::Val{:reactive_power},
    value::Float64,
    sys_base::Float64,
) = (comp.reactive_power = value * sys_base / PSY.get_base_power(comp, PSY.NU))
_update_component!(
    comp::PSY.ElectricLoad,
    ::Val{:reactive_power},
    value::Float64,
    sys_base::Float64,
) = (comp.reactive_power = -value * sys_base / PSY.get_base_power(comp, PSY.NU))
# ActivePowerOutVariable represents power output (positive contribution to active_power)
_update_component!(
    comp::PSY.Component,
    ::Val{:active_power_out},
    value::Float64,
    sys_base::Float64,
) = (comp.active_power += value * sys_base / PSY.get_base_power(comp, PSY.NU))
# ActivePowerInVariable represents power input / withdrawal (negative contribution to active_power)
_update_component!(
    comp::PSY.Component,
    ::Val{:active_power_in},
    value::Float64,
    sys_base::Float64,
) = (comp.active_power -= value * sys_base / PSY.get_base_power(comp, PSY.NU))
_update_component!(
    comp::PSY.ACBus,
    ::Union{Val{:voltage_angle_export}, Val{:voltage_angle_opf}},
    value::Float64,
    sys_base::Float64,
) = (comp.angle = value)
_update_component!(
    comp::PSY.ACBus,
    ::Union{Val{:voltage_magnitude_export}, Val{:voltage_magnitude_opf}},
    value::Float64,
    sys_base::Float64,
) = (comp.magnitude = value)

# Parameter (pre-signed) counterparts of `_update_component!`. The signed nodal contribution
# is written directly: separate in/out categories accumulate (`+=`) onto the active power that
# `update_pf_system!` has already reset to zero, while a single `:active_power` assigns (`=`).
# An `ElectricLoad`'s stored active/reactive power is the negated contribution.
_add_signed_component_update!(
    comp::PSY.Component,
    ::Val{:active_power},
    value::Float64,
    sys_base::Float64,
) = (comp.active_power = value * sys_base / PSY.get_base_power(comp, PSY.NU))
_add_signed_component_update!(
    comp::PSY.Component,
    ::Union{Val{:active_power_in}, Val{:active_power_out}},
    value::Float64,
    sys_base::Float64,
) = (comp.active_power += value * sys_base / PSY.get_base_power(comp, PSY.NU))
_add_signed_component_update!(
    comp::PSY.Component,
    ::Val{:reactive_power},
    value::Float64,
    sys_base::Float64,
) = (comp.reactive_power = value * sys_base / PSY.get_base_power(comp, PSY.NU))
_add_signed_component_update!(
    comp::PSY.ElectricLoad,
    ::Val{:active_power},
    value::Float64,
    sys_base::Float64,
) = (comp.active_power = -value * sys_base / PSY.get_base_power(comp, PSY.NU))
_add_signed_component_update!(
    comp::PSY.ElectricLoad,
    ::Val{:reactive_power},
    value::Float64,
    sys_base::Float64,
) = (comp.reactive_power = -value * sys_base / PSY.get_base_power(comp, PSY.NU))
# Sign-agnostic categories (voltage) delegate to the shared writer.
_add_signed_component_update!(
    comp::PSY.Component,
    category::Val,
    value::Float64,
    sys_base::Float64,
) = _update_component!(comp, category, value, sys_base)

function update_pf_system!(
    sys::PSY.System,
    container::OptimizationContainer,
    input_map::Dict{Symbol, <:Dict{OptimizationContainerKey, <:Any}},
    time_step::Int,
)
    # Reset active_power to zero for components that use separate in/out variables
    # (e.g. storage, import/export sources) before the additive += / -= updates.
    # Collect unique (type, name) pairs to avoid resetting the same component twice.
    reset_components = Set{Tuple{DataType, String}}()
    for category in (:active_power_in, :active_power_out)
        haskey(input_map, category) || continue
        for (key, component_map) in input_map[category]
            for (_, device_name) in component_map
                push!(reset_components, (get_component_type(key), device_name))
            end
        end
    end
    for (comp_type, device_name) in reset_components
        comp = PSY.get_component(comp_type, sys, device_name)
        comp.active_power = 0.0
    end
    for (category, inputs) in input_map
        @debug "Writing $category to (possibly internal) System"
        for (key, component_map) in inputs
            result = lookup_value(container, key)
            presigned = _pf_input_presigned(key)
            for (device_id, device_name) in component_map
                comp = PSY.get_component(get_component_type(key), sys, device_name)
                val = jump_value(result[device_id, time_step])
                if presigned
                    _add_signed_component_update!(
                        comp,
                        Val(category),
                        val,
                        IOM.get_model_base_power(container),
                    )
                else
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
