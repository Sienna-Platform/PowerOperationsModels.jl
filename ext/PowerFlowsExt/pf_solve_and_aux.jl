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
        # Single-period containers (PSSEExporter) only write data out: no convergence
        # to report.
        pf_e_data.is_solved = true
    end
    return
end

# Currently nothing to write back to the optimization container from a PSSEExporter
IOM.calculate_aux_variable_value!(
    ::OptimizationContainer,
    ::AuxVarKey{T, <:Any} where {T <: POM.PowerFlowAuxVariableType},
    ::PSY.System,
    ::PowerFlowEvaluationData{PFS.PSSEExporter},
) = nothing

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
# PERF: unlike the others, this one requires a bit of computation.
_get_pf_result(
    ::Type{POM.PowerFlowBranchActivePowerLoss},
    pf_data::PFS.PowerFlowData,
) =
    PFS.get_arc_active_power_flow_from_to(pf_data) .+
    PFS.get_arc_active_power_flow_to_from(pf_data)

function _write_aux_variable_value!(
    container::OptimizationContainer,
    key::AuxVarKey{T, <:PSY.ACBus},
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
    pf_e_data::PowerFlowEvaluationData{<:PFS.PowerFlowData},
) where {T <: POM.PowerFlowAuxVariableType, U <: PSY.Branch}
    @debug "Updating $key from PowerFlowData"
    pf_data = IOM.get_inner_data(pf_e_data)
    src = _get_pf_result(T, pf_data)
    dest = get_aux_variable(container, key)
    nrd = PFS.get_network_reduction_data(pf_data)
    arc_lookup = PFS.get_arc_lookup(pf_data)
    # PERF: could pre-compute a Dict of branch type to arcs, then intersect the arcs
    # for the type U with the keys of the branch maps.
    for (arc, br) in PNM.get_direct_branch_map(nrd)
        if br isa U
            name = PSY.get_name(br)
            arc_ix = arc_lookup[arc]
            dest[name, :] = src[arc_ix, :]
        end
    end
    for (arc, parallel_brs) in PNM.get_parallel_branch_map(nrd)
        # `PNM.compute_parallel_multiplier` susceptance-weights each branch, so parallel
        # branches with unequal impedances are handled correctly.
        for br in parallel_brs
            if br isa U
                name = PSY.get_name(br)
                IS.@assert_op T <: POM.BranchFlowAuxVariableType ||
                              (T == POM.PowerFlowBranchActivePowerLoss)
                multiplier = PNM.compute_parallel_multiplier(parallel_brs, name)
                arc_ix = arc_lookup[arc]
                dest[name, :] = multiplier .* src[arc_ix, :]
            end
        end
    end
    return
end

function IOM.calculate_aux_variable_value!(
    container::OptimizationContainer,
    key::AuxVarKey{<:POM.PowerFlowAuxVariableType, <:PSY.Component},
    ::PSY.System,
    pf_e_data::PowerFlowEvaluationData{<:PFS.PowerFlowData},
)
    # Skip the aux vars this evaluator isn't meant to update: with several
    # evaluators registered, each one only owns part of the aux var keys.
    pf_data = IOM.get_inner_data(pf_e_data)
    key_type = IOM.get_entry_type(key)
    (key_type in branch_aux_vars(pf_data) || key_type in bus_aux_vars(pf_data)) ||
        return
    # non-converged time steps get NaNs.
    _write_aux_variable_value!(container, key, pf_e_data)
    return
end
