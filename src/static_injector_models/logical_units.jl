#! format: off
requires_initialization(::LogicalUnitStandardCommitment) = true
requires_initialization(::LogicalUnitBasicCommitment) = false
requires_initialization(::LogicalUnitStandardDispatch) = true
requires_initialization(::LogicalUnitBasicDispatch) = false

# The basic commitment drops the ramp and minimum up/down time constraints.
_has_ramp_and_duration_constraints(::Type{LogicalUnitBasicCommitment}) = false

get_initial_conditions_device_model(
    ::IOM.AbstractOptimizationModel,
    ::DeviceModel{PSY.LogicalGenerationUnit, <:AbstractLogicalUnitCommitment},
) = DeviceModel(PSY.LogicalGenerationUnit, LogicalUnitBasicCommitment)

function get_initial_conditions_device_model(
    model::IOM.AbstractOptimizationModel,
    ::DeviceModel{PSY.LogicalGenerationUnit, <:AbstractLogicalUnitDispatch},
)
    if supports_milp(get_optimization_container(model))
        return DeviceModel(PSY.LogicalGenerationUnit, LogicalUnitBasicCommitment)
    else
        return DeviceModel(PSY.LogicalGenerationUnit, LogicalUnitBasicDispatch)
    end
end
#! format: on

function initial_conditions!(
    container::OptimizationContainer,
    devices::Vector{PSY.LogicalGenerationUnit},
    formulation::LogicalUnitBasicCommitment,
)
    add_initial_condition!(container, devices, formulation, DeviceStatus())
    add_initial_condition!(container, devices, formulation, InitialTimeDurationOn())
    add_initial_condition!(container, devices, formulation, InitialTimeDurationOff())
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{PSY.LogicalGenerationUnit, D},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {D <: AbstractLogicalUnitCommitment}
    _add_commitment_arguments!(
        container,
        get_device_cache(device_model),
        device_model,
        network_model,
    )
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{PSY.LogicalGenerationUnit, D},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {D <: AbstractLogicalUnitCommitment}
    _add_commitment_constraints!(
        container,
        sys,
        get_device_cache(device_model),
        device_model,
        network_model,
    )
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{PSY.LogicalGenerationUnit, LogicalUnitBasicDispatch},
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    _add_dispatch_arguments!(
        container,
        get_device_cache(device_model),
        device_model,
        network_model,
    )
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{PSY.LogicalGenerationUnit, LogicalUnitBasicDispatch},
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    _add_dispatch_constraints!(
        container,
        sys,
        get_device_cache(device_model),
        device_model,
        network_model,
    )
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{PSY.LogicalGenerationUnit, LogicalUnitStandardDispatch},
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    _add_standard_dispatch_arguments!(
        container,
        get_device_cache(device_model),
        device_model,
        network_model,
    )
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{PSY.LogicalGenerationUnit, LogicalUnitStandardDispatch},
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    _add_standard_dispatch_constraints!(
        container,
        sys,
        get_device_cache(device_model),
        device_model,
        network_model,
    )
    return
end
