#################################################################################
# Transformer device families whose formulations are still under development:
#
#   PSY.TapTransformer         under TapControl        — fixed off-nominal tap,
#     a component property scaling the series susceptance in the DC Ohm's law.
#   PSY.PhaseShiftingTransformer under PhaseAngleControl — phase shift as a
#     bounded decision variable entering the DC Ohm's law additively,
#     p = (1/x) * (θ_from - θ_to + α), limited by PhaseAngleControlLimit.
#
# Methods here intentionally duplicate logic from AC_branches.jl. Where a shared
# method's bound straddles these devices and a non-TBD device, the copy below is
# narrower, so dispatch prefers it and the shared method keeps serving the other
# device. The copies are expected to diverge as these formulations are finished.
#
# The variable-tap formulation (VoltageControlTap, where the ratio is a decision
# variable) is NOT part of this file — see voltage_control_tap_models.jl.
#################################################################################

#! format: off
get_variable_upper_bound(::Type{FlowActivePowerFromToVariable}, d::PSY.TapTransformer, ::Type{<:AbstractBranchFormulation}) = PSY.get_rating(d, PSY.SU)
get_variable_lower_bound(::Type{FlowActivePowerFromToVariable}, d::PSY.TapTransformer, ::Type{<:AbstractBranchFormulation}) = -1 * PSY.get_rating(d, PSY.SU)
get_variable_upper_bound(::Type{FlowActivePowerToFromVariable}, d::PSY.TapTransformer, ::Type{<:AbstractBranchFormulation}) = PSY.get_rating(d, PSY.SU)
get_variable_lower_bound(::Type{FlowActivePowerToFromVariable}, d::PSY.TapTransformer, ::Type{<:AbstractBranchFormulation}) = -1 * PSY.get_rating(d, PSY.SU)
#! format: on

"""
Add branch flow constraints for phase shifting transformers with DC Power Model
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{FlowLimitConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, U},
    ::NetworkModel{V},
) where {
    T <: PSY.PhaseShiftingTransformer,
    U <: AbstractBranchFormulation,
    V <: AbstractDCPNetworkModel,
}
    add_range_constraints!(
        container,
        FlowLimitConstraint,
        FlowActivePowerVariable,
        devices,
        model,
        V,
    )
    return
end

############################ Phase shifting transformer ########################
#! format: off
get_variable_binary(::Type{PhaseShifterAngle}, ::Type{PSY.PhaseShiftingTransformer}, ::Type{<:AbstractBranchFormulation}) = false

# Per-device reactance multiplier (1/get_x(d)) computed inline at add_to_expression! call sites.
get_variable_multiplier(::Type{PhaseShifterAngle}, ::Type{<:PSY.PhaseShiftingTransformer}, ::Type{PhaseAngleControl}) = 1.0
#! format: on

"""
Min and max limits for Abstract Branch Formulation
"""
function get_min_max_limits(
    ::PSY.PhaseShiftingTransformer,
    ::Type{PhaseAngleControlLimit},
    ::Type{PhaseAngleControl},
) #  -> Union{Nothing, NamedTuple{(:min, :max), Tuple{Float64, Float64}}}
    return (min = -π / 2, max = π / 2)
end

"""
Add network flow constraints for PhaseShiftingTransformer and NetworkModel with <: AbstractPTDFNetworkModel
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, PhaseAngleControl},
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
) where {T <: PSY.PhaseShiftingTransformer}
    ptdf = get_network_matrix(network_model)
    branches = PSY.get_name.(devices)
    time_steps = get_time_steps(container)
    branch_flow = add_constraints_container!(container, NetworkFlowConstraint,
        T,
        branches,
        time_steps,
    )
    nodal_balance_expressions = get_expression(container, ActivePowerBalance, PSY.ACBus)
    flow_variables = get_variable(container, FlowActivePowerVariable, T)
    angle_variables = get_variable(container, PhaseShifterAngle, T)
    jump_model = get_jump_model(container)
    for br in devices
        arc = PNM.get_arc_tuple(br)
        name = PSY.get_name(br)
        ptdf_col = ptdf[arc, :]
        inv_x = 1 / PSY.get_x(br, PSY.SU)
        for t in time_steps
            branch_flow[name, t] = JuMP.@constraint(
                jump_model,
                sum(
                    ptdf_col[i] * nodal_balance_expressions.data[i, t] for
                    i in 1:length(ptdf_col)
                ) + inv_x * angle_variables[name, t] - flow_variables[name, t] == 0.0
            )
        end
    end
    return
end

"""
Add phase angle limits for phase shifters
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{PhaseAngleControlLimit},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, PhaseAngleControl},
    ::NetworkModel{U},
) where {T <: PSY.PhaseShiftingTransformer, U <: AbstractActivePowerModel}
    add_range_constraints!(
        container,
        PhaseAngleControlLimit,
        PhaseShifterAngle,
        devices,
        model,
        U,
    )
    return
end

"""
Add network flow constraints for PhaseShiftingTransformer and NetworkModel with DCPNetworkModel
"""
function add_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, PhaseAngleControl},
    network_model::NetworkModel{DCPNetworkModel},
) where {T <: PSY.PhaseShiftingTransformer}
    time_steps = get_time_steps(container)
    number_to_name = _retained_number_to_name(sys, network_model)
    flow_variables = get_variable(container, FlowActivePowerVariable, T)
    ps_angle_variables = get_variable(container, PhaseShifterAngle, T)
    bus_angle_variables = get_variable(container, VoltageAngle, PSY.ACBus)
    jump_model = get_jump_model(container)
    branch_flow = add_constraints_container!(container, NetworkFlowConstraint,
        T,
        axes(flow_variables)[1],
        time_steps,
    )

    for br in devices
        name = PSY.get_name(br)
        inv_x = 1.0 / PSY.get_x(br, PSY.SU)
        flow_variables_ = flow_variables[name, :]
        from_no, to_no = PNM.get_arc_tuple(br, get_network_reduction(network_model))
        from_no == to_no && continue
        from_bus = number_to_name[from_no]
        to_bus = number_to_name[to_no]
        angle_variables_ = ps_angle_variables[name, :]
        bus_angle_from = bus_angle_variables[from_bus, :]
        bus_angle_to = bus_angle_variables[to_bus, :]
        @assert inv_x > 0.0
        for t in time_steps
            branch_flow[name, t] = JuMP.@constraint(
                jump_model,
                flow_variables_[t] ==
                inv_x * (bus_angle_from[t] - bus_angle_to[t] + angle_variables_[t])
            )
        end
    end
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{PSY.PhaseShiftingTransformer, PhaseAngleControl},
    network_model::NetworkModel{DCPNetworkModel},
)
    devices = get_available_components(device_model, sys)
    _validate_controlled_branch_not_reduced(network_model, devices, "PhaseAngleControl")
    add_variables!(container, FlowActivePowerVariable, devices, PhaseAngleControl)
    add_variables!(container, PhaseShifterAngle, devices, PhaseAngleControl)
    add_to_expression!(
        container,
        ActivePowerBalance,
        FlowActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_feedforward_arguments!(container, device_model, devices)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{PSY.PhaseShiftingTransformer, PhaseAngleControl},
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
)
    devices = get_available_components(device_model, sys)
    add_variables!(container, FlowActivePowerVariable, devices, PhaseAngleControl)
    add_variables!(container, PhaseShifterAngle, devices, PhaseAngleControl)
    add_to_expression!(
        container,
        ActivePowerBalance,
        PhaseShifterAngle,
        devices,
        device_model,
        network_model,
    )
    add_feedforward_arguments!(container, device_model, devices)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{PSY.PhaseShiftingTransformer, PhaseAngleControl},
    network_model::NetworkModel{DCPNetworkModel},
)
    devices = get_available_components(device_model, sys)
    add_constraints!(container, FlowLimitConstraint, devices, device_model, network_model)
    add_constraints!(
        container,
        PhaseAngleControlLimit,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(
        container, sys, NetworkFlowConstraint, devices, device_model, network_model,
    )
    add_constraint_dual!(container, sys, device_model)
    add_feedforward_constraints!(container, device_model, devices)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{PSY.PhaseShiftingTransformer, PhaseAngleControl},
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
)
    devices = get_available_components(device_model, sys)
    add_constraints!(container, FlowLimitConstraint, devices, device_model, network_model)
    add_constraints!(
        container,
        PhaseAngleControlLimit,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(container, NetworkFlowConstraint, devices, device_model, network_model)
    add_constraint_dual!(container, sys, device_model)
    add_feedforward_constraints!(container, device_model, devices)
    return
end
