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
