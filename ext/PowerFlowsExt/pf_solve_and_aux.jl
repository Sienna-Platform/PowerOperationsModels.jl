# Power flow in-the-loop: solve dispatcher and auxiliary variable readback.
# Defines IOM.evaluate!, calculate_aux_variable_value! overloads for
# PowerFlowAuxVariableType, and _get_pf_result helpers.

function IOM.evaluate!(
    pf_e_data::PowerFlowEvaluationData,
    container::OptimizationContainer,
    sys::PSY.System,
)
    pf_data = IOM.get_inner_data(pf_e_data)
    if PFS.supports_multi_period(pf_data)
        update_pf_data!(pf_e_data, container)
        _update_area_schedules!(pf_data, container, sys)
        _update_headroom_participation_factors!(
            pf_data, container, sys, get_input_key_map(pf_e_data),
        )
        PFS.solve_power_flow!(pf_data)
        converged = PFS.get_converged(pf_data)
        pf_e_data.is_solved = all(converged)
        pf_e_data.is_solved || @error(
            "Power flow evaluator $(typeof(pf_data)) failed to converge at time steps \
             $(findall(!, converged)); PowerFlows wrote NaN into those steps."
        )
    else
        for t in get_time_steps(container)
            update_pf_data!(pf_e_data, container, t)
            PFS.solve_power_flow!(pf_data)
        end
        # Single-period containers (PSSEExporter) only write data out: nothing to
        # converge.
        pf_e_data.is_solved = true
    end
    return
end

_get_pf_result(::Type{POM.PowerFlowVoltageAngle}, pf_data::PFS.PowerFlowData) =
    PFS.get_bus_angles(pf_data)
_get_pf_result(::Type{POM.PowerFlowVoltageMagnitude}, pf_data::PFS.PowerFlowData) =
    PFS.get_bus_magnitude(pf_data)
_get_pf_result(
    ::Type{POM.PowerFlowBranchReactivePowerFromTo},
    pf_data::PFS.PowerFlowData,
) =
    PFS.get_arc_reactive_power_flow_from_to(pf_data)
_get_pf_result(
    ::Type{POM.PowerFlowBranchReactivePowerToFrom},
    pf_data::PFS.PowerFlowData,
) =
    PFS.get_arc_reactive_power_flow_to_from(pf_data)
_get_pf_result(
    ::Type{POM.PowerFlowBranchActivePowerFromTo},
    pf_data::PFS.PowerFlowData,
) =
    PFS.get_arc_active_power_flow_from_to(pf_data)
_get_pf_result(
    ::Type{POM.PowerFlowBranchActivePowerToFrom},
    pf_data::PFS.PowerFlowData,
) =
    PFS.get_arc_active_power_flow_to_from(pf_data)
_get_pf_result(::Type{POM.PowerFlowLossFactors}, pf_data::PFS.PowerFlowData) =
    PFS.get_loss_factors(pf_data)
_get_pf_result(
    ::Type{POM.PowerFlowVoltageStabilityFactors},
    pf_data::PFS.PowerFlowData,
) =
    PFS.get_voltage_stability_factors(pf_data)
_get_pf_result(
    ::Type{POM.PowerFlowBranchActivePowerLoss},
    pf_data::PFS.PowerFlowData,
) =
    PFS.get_arc_active_power_flow_from_to(pf_data) .+
    PFS.get_arc_active_power_flow_to_from(pf_data)

function _write_aux_variable_value!(
    container::OptimizationContainer,
    key::AuxVarKey{T, <:PSY.ACBus},
    ::PSY.System,
    pf_e_data::PowerFlowEvaluationData{<:PFS.PowerFlowData},
) where {T <: POM.PowerFlowAuxVariableType}
    @debug "Updating $key from PowerFlowData"
    pf_data = IOM.get_inner_data(pf_e_data)
    nrd = PFS.get_network_reduction_data(pf_data)
    src = _get_pf_result(T, pf_data)
    bus_lookup = PFS.get_bus_lookup(pf_data)
    dest = get_aux_variable(container, key)
    for bus_number in axes(dest, 1)
        bus_ix = PNM.get_bus_index(bus_number, bus_lookup, nrd)
        dest[bus_number, :] = src[bus_ix, :]
    end
    return
end

function _write_aux_variable_value!(
    container::OptimizationContainer,
    key::AuxVarKey{T, U},
    sys::PSY.System,
    pf_e_data::PowerFlowEvaluationData{<:PFS.PowerFlowData},
) where {T <: POM.PowerFlowAuxVariableType, U <: PSY.Branch}
    @debug "Updating $key from PowerFlowData"
    pf_data = IOM.get_inner_data(pf_e_data)
    src = _get_pf_result(T, pf_data)
    dest = get_aux_variable(container, key)
    nrd = PFS.get_network_reduction_data(pf_data)
    arc_lookup = PFS.get_arc_lookup(pf_data)
    direct_map = PNM.get_reverse_direct_branch_map(nrd)
    parallel_map = PNM.get_reverse_parallel_branch_map(nrd)
    parallel_branch_map = PNM.get_parallel_branch_map(nrd)
    for name in axes(dest, 1)
        br = PSY.get_component(U, sys, name)
        if haskey(direct_map, br)
            dest[name, :] = src[arc_lookup[direct_map[br]], :]
        elseif haskey(parallel_map, br)
            # Multiplier is susceptance-weighted, so unequal parallel impedances split correctly.
            IS.@assert_op T <: POM.BranchFlowAuxVariableType ||
                          (T == POM.PowerFlowBranchActivePowerLoss)
            arc = parallel_map[br]
            parallel_brs = parallel_branch_map[arc]
            multiplier = PNM.compute_parallel_multiplier(parallel_brs, br)
            dest[name, :] = multiplier .* src[arc_lookup[arc], :]
        end
    end
    return
end

function IOM.calculate_aux_variable_value!(
    container::OptimizationContainer,
    key::AuxVarKey{<:POM.PowerFlowAuxVariableType, <:PSY.Component},
    sys::PSY.System,
    pf_e_data::PowerFlowEvaluationData{<:PFS.PowerFlowData},
)
    # Time steps where the power flow didn't converge get NaNs.
    _write_aux_variable_value!(container, key, sys, pf_e_data)
    return
end
