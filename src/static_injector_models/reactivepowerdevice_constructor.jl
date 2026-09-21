function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{R, D},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {
    R <: PSY.SynchronousCondenser,
    D <: AbstractReactivePowerDeviceFormulation,
}
    devices = get_device_cache(model)
    add_variables!(container, ReactivePowerVariable, devices, D)
    add_to_expression!(
        container,
        ReactivePowerBalance,
        ReactivePowerVariable,
        devices,
        model,
        network_model,
    )
    add_feedforward_arguments!(container, model, devices)
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{R, D},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {
    R <: PSY.SynchronousCondenser,
    D <: AbstractReactivePowerDeviceFormulation,
}
    devices = get_device_cache(model)
    # No constraints
    # Add FFs
    add_feedforward_constraints!(container, model, devices)
    # No objective function
    return
end
