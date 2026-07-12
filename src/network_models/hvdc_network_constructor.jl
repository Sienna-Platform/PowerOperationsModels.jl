function construct_hvdc_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    transmission_model::NetworkModel{T},
    hvdc_model::Nothing,
    ::PowerOperationsProblemTemplate,
) where {T <: AbstractNetworkModel}
    return
end

function construct_hvdc_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    transmission_model::NetworkModel{T},
    hvdc_model::TransportHVDCNetworkModel,
    ::PowerOperationsProblemTemplate,
) where {T <: AbstractNetworkModel}
    add_constraints!(
        container,
        NodalBalanceActiveConstraint,
        sys,
        transmission_model,
        hvdc_model,
    )
    # TODO: duals
    #add_constraint_dual!(container, sys, hvdc_model)
    return
end

function construct_hvdc_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    transmission_model::NetworkModel{T},
    hvdc_model::VoltageDispatchHVDCNetworkModel,
    ::PowerOperationsProblemTemplate,
) where {T <: AbstractNetworkModel}
    add_constraints!(
        container,
        NodalBalanceCurrentConstraint,
        sys,
        transmission_model,
        hvdc_model,
    )
    # TODO: duals
    #add_constraint_dual!(container, sys, hvdc_model)
    return
end
