#! format: off
requires_initialization(::LogicalUnitStandardCommitment) = true
requires_initialization(::LogicalUnitBasicCommitment) = false

# The basic commitment drops the ramp and minimum up/down time constraints.
_has_ramp_and_duration_constraints(::Type{LogicalUnitBasicCommitment}) = false

get_initial_conditions_device_model(
    ::IOM.AbstractOptimizationModel,
    ::DeviceModel{PSY.LogicalGenerationUnit, <:AbstractLogicalUnitCommitment},
) = DeviceModel(PSY.LogicalGenerationUnit, LogicalUnitBasicCommitment)
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
