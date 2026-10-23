# TODO: Security constrained models implement the correct functions for the model
function has_security_arguments(device_model::DeviceModel)::Bool
    return true
end

# TODO: Security constrained models implement the correct functions for the model
function has_security_model(device_model::DeviceModel)::Bool
    return true
end

@inline function _handle_common_thermal_parameters!(
    container::OptimizationContainer,
    devices::Vector{T},
    model::DeviceModel{T},
) where {T <: PSY.ThermalGen}
    add_min_active_power_parameters!(
        container,
        MinActivePowerTimeSeriesParameter,
        devices,
        model,
    )
    set_min_power_variable_bounds!(container, devices, model)

    if haskey(get_time_series_names(model), FuelCostParameter)
        add_parameters!(container, FuelCostParameter, devices, model)
    end

    process_market_bid_parameters!(container, devices, model)
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, FixedOutput},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {T <: PSY.ThermalGen}
    devices = get_device_cache(device_model)
    add_parameters!(container, ActivePowerTimeSeriesParameter, devices, device_model)
    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerTimeSeriesParameter,
        devices,
        device_model,
        network_model,
    )
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, FixedOutput},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {T <: PSY.ThermalGen}
    devices = get_device_cache(device_model)
    add_parameters!(container, ActivePowerTimeSeriesParameter, devices, device_model)
    add_parameters!(container, ReactivePowerTimeSeriesParameter, devices, device_model)
    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerTimeSeriesParameter,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ReactivePowerBalance,
        ReactivePowerTimeSeriesParameter,
        devices,
        device_model,
        network_model,
    )
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

function construct_device!(
    ::OptimizationContainer,
    ::PSY.System,
    ::ModelConstructStage,
    ::DeviceModel{<:PSY.ThermalGen, FixedOutput},
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    # FixedOutput doesn't add any constraints to the model. This function covers
    # AbstractNetworkModel and AbtractActivePowerModel
    return
end

"""
This function creates the arguments for the model for a full thermal dispatch formulation depending on combination of devices, device_formulation and system_formulation
"""
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, D},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {
    T <: PSY.ThermalGen,
    D <: AbstractStandardUnitCommitment,
}
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        ActivePowerVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        ReactivePowerVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        OnVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StartVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StopVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    add_variables!(container, TimeDurationOn, devices, D)
    add_variables!(container, TimeDurationOff, devices, D)

    initial_conditions!(container, devices, D())

    if haskey(get_time_series_names(device_model), ActivePowerTimeSeriesParameter)
        add_parameters!(container, ActivePowerTimeSeriesParameter, devices, device_model)
    end

    _handle_common_thermal_parameters!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ReactivePowerBalance,
        ReactivePowerVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        ActivePowerVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end
    add_feedforward_arguments!(container, device_model, devices)
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

# The basic UC formulations drop the ramp and minimum up/down time constraints.
_has_ramp_and_duration_constraints(::Type{<:AbstractThermalUnitCommitment}) = true
_has_ramp_and_duration_constraints(::Type{ThermalBasicUnitCommitment}) = false
_has_ramp_and_duration_constraints(::Type{ThermalBasicCompactUnitCommitment}) = false

"""
This function creates the constraints for the model for a full thermal dispatch formulation depending on combination of devices, device_formulation and system_formulation
"""
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{T, U},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {
    T <: PSY.ThermalGen,
    U <: Union{
        AbstractStandardUnitCommitment,
        ThermalCompactUnitCommitment,
        ThermalBasicCompactUnitCommitment,
    },
}
    devices = get_device_cache(device_model)

    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionLB,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionUB,
        devices,
        device_model,
        network_model,
    )
    if _has_offline_reserve_service(device_model)
        # Offline awards bound against the step's available max, so an off unit keeps them.
        add_constraints!(
            container,
            OfflineReserveBandConstraint,
            devices,
            device_model,
            network_model,
        )
    end
    add_constraints!(
        container,
        ReactivePowerVariableLimitsConstraint,
        ReactivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(container, CommitmentConstraint, devices, device_model, network_model)
    if _has_ramp_and_duration_constraints(U)
        add_constraints!(container, RampConstraint, devices, device_model, network_model)
        add_constraints!(
            container,
            DurationConstraint,
            devices,
            device_model,
            network_model,
        )
    end

    if haskey(get_time_series_names(device_model), ActivePowerTimeSeriesParameter)
        add_constraints!(
            container,
            ActivePowerVariableTimeSeriesLimitsConstraint,
            ActivePowerRangeExpressionUB,
            devices,
            device_model,
            network_model,
        )
    end

    add_feedforward_constraints!(container, device_model, devices)
    add_event_constraints!(container, devices, device_model, network_model)

    add_to_objective_function!(
        container,
        devices,
        device_model,
        get_network_formulation(network_model),
    )

    if has_security_arguments(device_model)
        # TODO: SecurityConstrainedModels Implemenation of G-1
        #add_constraints!(
        #    container,
        #    SecurityConstraint,
        #    devices,
        #    device_model,
        #    network_model,
        #)
    end

    add_constraint_dual!(container, sys, device_model)
    return
end

"""
This function creates the arguments model for a full thermal dispatch formulation depending on combination of devices, device_formulation and system_formulation
"""
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, D},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {T <: PSY.ThermalGen, D <: AbstractStandardUnitCommitment}
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        ActivePowerVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        OnVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StartVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StopVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    add_variables!(container, TimeDurationOn, devices, D)
    add_variables!(container, TimeDurationOff, devices, D)

    initial_conditions!(container, devices, D())

    if haskey(get_time_series_names(device_model), ActivePowerTimeSeriesParameter)
        add_parameters!(container, ActivePowerTimeSeriesParameter, devices, device_model)
    end

    _handle_common_thermal_parameters!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        ActivePowerVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end

    add_feedforward_arguments!(container, device_model, devices)
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

"""
This function creates the constraints for the model for a full thermal dispatch formulation depending on combination of devices, device_formulation and system_formulation
"""
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{T, U},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {
    T <: PSY.ThermalGen,
    U <: Union{
        AbstractStandardUnitCommitment,
        ThermalCompactUnitCommitment,
        ThermalBasicCompactUnitCommitment,
    },
}
    devices = get_device_cache(device_model)
    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionLB,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionUB,
        devices,
        device_model,
        network_model,
    )
    if _has_offline_reserve_service(device_model)
        # Offline awards bound against the step's available max, so an off unit keeps them.
        add_constraints!(
            container,
            OfflineReserveBandConstraint,
            devices,
            device_model,
            network_model,
        )
    end

    add_constraints!(container, CommitmentConstraint, devices, device_model, network_model)
    if _has_ramp_and_duration_constraints(U)
        add_constraints!(container, RampConstraint, devices, device_model, network_model)
        add_constraints!(
            container,
            DurationConstraint,
            devices,
            device_model,
            network_model,
        )
    end
    if haskey(get_time_series_names(device_model), ActivePowerTimeSeriesParameter)
        add_constraints!(
            container,
            ActivePowerVariableTimeSeriesLimitsConstraint,
            ActivePowerRangeExpressionUB,
            devices,
            device_model,
            network_model,
        )
    end

    add_feedforward_constraints!(container, device_model, devices)

    add_to_objective_function!(
        container,
        devices,
        device_model,
        get_network_formulation(network_model),
    )
    add_event_constraints!(container, devices, device_model, network_model)
    add_constraint_dual!(container, sys, device_model)
    return
end

"""
This function creates the model for a full thermal dispatch formulation depending on combination of devices, device_formulation and system_formulation
"""
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, ThermalStandardDispatch},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {T <: PSY.ThermalGen}
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        ActivePowerVariable,
        devices,
        ThermalStandardDispatch,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        ReactivePowerVariable,
        devices,
        ThermalStandardDispatch,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    initial_conditions!(container, devices, ThermalStandardDispatch())

    _handle_common_thermal_parameters!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ReactivePowerBalance,
        ReactivePowerVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        ActivePowerVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            ThermalStandardDispatch,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            ThermalStandardDispatch,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end

    add_feedforward_arguments!(container, device_model, devices)
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

"""
This function creates the model for a full thermal dispatch formulation depending on combination of devices, device_formulation and system_formulation
"""
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{T, <:Union{ThermalStandardDispatch, ThermalCompactDispatch}},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {T <: PSY.ThermalGen}
    devices = get_device_cache(device_model)

    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionLB,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionUB,
        devices,
        device_model,
        network_model,
    )

    add_constraints!(
        container,
        ReactivePowerVariableLimitsConstraint,
        ReactivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(container, RampConstraint, devices, device_model, network_model)

    add_feedforward_constraints!(container, device_model, devices)

    add_to_objective_function!(
        container,
        devices,
        device_model,
        get_network_formulation(network_model),
    )
    add_event_constraints!(container, devices, device_model, network_model)
    add_constraint_dual!(container, sys, device_model)
    return
end

"""
This function creates the arguments for the model for a full thermal dispatch formulation depending on combination of devices, device_formulation and system_formulation
"""
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, ThermalStandardDispatch},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {T <: PSY.ThermalGen}
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        ActivePowerVariable,
        devices,
        ThermalStandardDispatch,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    initial_conditions!(container, devices, ThermalStandardDispatch())

    _handle_common_thermal_parameters!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        ActivePowerVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            ThermalStandardDispatch,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            ThermalStandardDispatch,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end

    add_feedforward_arguments!(container, device_model, devices)
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

"""
This function creates the constraints for the model for a full thermal dispatch formulation depending on combination of devices, device_formulation and system_formulation
"""
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{T, <:Union{ThermalStandardDispatch, ThermalCompactDispatch}},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {T <: PSY.ThermalGen}
    devices = get_device_cache(device_model)

    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionLB,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionUB,
        devices,
        device_model,
        network_model,
    )

    add_constraints!(container, RampConstraint, devices, device_model, network_model)

    add_feedforward_constraints!(container, device_model, devices)

    add_to_objective_function!(
        container,
        devices,
        device_model,
        get_network_formulation(network_model),
    )
    add_event_constraints!(container, devices, device_model, network_model)
    add_constraint_dual!(container, sys, device_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, D},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {
    T <: PSY.ThermalGen,
    D <: AbstractThermalDispatchFormulation,
}
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        ActivePowerVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        ReactivePowerVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    _handle_common_thermal_parameters!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ReactivePowerBalance,
        ReactivePowerVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        ActivePowerVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end

    add_feedforward_arguments!(container, device_model, devices)
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{T, <:AbstractThermalDispatchFormulation},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {T <: PSY.ThermalGen}
    devices = get_device_cache(device_model)

    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionLB,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionUB,
        devices,
        device_model,
        network_model,
    )

    add_constraints!(
        container,
        ReactivePowerVariableLimitsConstraint,
        ReactivePowerVariable,
        devices,
        device_model,
        network_model,
    )

    add_feedforward_constraints!(container, device_model, devices)

    add_to_objective_function!(
        container,
        devices,
        device_model,
        get_network_formulation(network_model),
    )
    add_event_constraints!(container, devices, device_model, network_model)
    add_constraint_dual!(container, sys, device_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, D},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {
    T <: PSY.ThermalGen,
    D <: AbstractThermalDispatchFormulation,
}
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        ActivePowerVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    _handle_common_thermal_parameters!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        ActivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        ActivePowerVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end

    add_feedforward_arguments!(container, device_model, devices)
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{T, <:AbstractThermalDispatchFormulation},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {T <: PSY.ThermalGen}
    devices = get_device_cache(device_model)

    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionLB,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionUB,
        devices,
        device_model,
        network_model,
    )

    add_feedforward_constraints!(container, device_model, devices)
    add_event_constraints!(container, devices, device_model, network_model)

    add_to_objective_function!(
        container,
        devices,
        device_model,
        get_network_formulation(network_model),
    )
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{PSY.ThermalMultiStart, ThermalMultiStartUnitCommitment},
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        PowerAboveMinimumVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        ReactivePowerVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        OnVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StopVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StartVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        ColdStartVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        WarmStartVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        HotStartVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    add_variables!(container, TimeDurationOn, devices, ThermalMultiStartUnitCommitment)
    add_variables!(container, TimeDurationOff, devices, ThermalMultiStartUnitCommitment)
    add_variables!(container, PowerOutput, devices, ThermalMultiStartUnitCommitment)

    if haskey(get_time_series_names(device_model), ActivePowerTimeSeriesParameter)
        add_parameters!(container, ActivePowerTimeSeriesParameter, devices, device_model)
    end

    _handle_common_thermal_parameters!(container, devices, device_model)

    initial_conditions!(container, devices, ThermalMultiStartUnitCommitment())

    add_to_expression!(
        container,
        ActivePowerBalance,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerBalance,
        OnVariable,
        devices,
        device_model,
        network_model,
    )

    add_to_expression!(
        container,
        ReactivePowerBalance,
        ReactivePowerVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        PowerAboveMinimumVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            ThermalMultiStartUnitCommitment,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            ThermalMultiStartUnitCommitment,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end

    add_feedforward_arguments!(container, device_model, devices)
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{PSY.ThermalMultiStart, ThermalMultiStartUnitCommitment},
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    devices = get_device_cache(device_model)
    # Must-run units never start or stop, so the start and initial-condition rows leave them out.
    committable = filter(!_is_must_run, devices)

    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionLB,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionUB,
        devices,
        device_model,
        network_model,
    )
    if _has_offline_reserve_service(device_model)
        # Offline awards bound against the step's available max, so an off unit keeps them.
        add_constraints!(
            container,
            OfflineReserveBandConstraint,
            devices,
            device_model,
            network_model,
        )
    end

    add_constraints!(
        container,
        ReactivePowerVariableLimitsConstraint,
        ReactivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(container, CommitmentConstraint, devices, device_model, network_model)
    add_constraints!(container, RampConstraint, devices, device_model, network_model)
    add_constraints!(container, DurationConstraint, devices, device_model, network_model)
    add_constraints!(
        container,
        StartupTimeLimitTemperatureConstraint,
        committable,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        StartTypeConstraint,
        committable,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        StartupInitialConditionConstraint,
        committable,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        ActiveRangeICConstraint,
        committable,
        device_model,
        network_model,
    )

    if haskey(get_time_series_names(device_model), ActivePowerTimeSeriesParameter)
        add_constraints!(
            container,
            ActivePowerVariableTimeSeriesLimitsConstraint,
            ActivePowerRangeExpressionUB,
            devices,
            device_model,
            network_model,
        )
    end

    add_feedforward_constraints!(container, device_model, devices)

    add_to_objective_function!(
        container,
        devices,
        device_model,
        get_network_formulation(network_model),
    )
    add_event_constraints!(container, devices, device_model, network_model)
    add_constraint_dual!(container, sys, device_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{PSY.ThermalMultiStart, ThermalMultiStartUnitCommitment},
    network_model::NetworkModel{<:AbstractActivePowerModel},
)
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        PowerAboveMinimumVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        OnVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StopVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StartVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        ColdStartVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        WarmStartVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        HotStartVariable,
        devices,
        ThermalMultiStartUnitCommitment,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    add_variables!(container, TimeDurationOn, devices, ThermalMultiStartUnitCommitment)
    add_variables!(container, TimeDurationOff, devices, ThermalMultiStartUnitCommitment)
    add_variables!(container, PowerOutput, devices, ThermalMultiStartUnitCommitment)

    if haskey(get_time_series_names(device_model), ActivePowerTimeSeriesParameter)
        add_parameters!(container, ActivePowerTimeSeriesParameter, devices, device_model)
    end

    _handle_common_thermal_parameters!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerBalance,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )

    add_to_expression!(
        container,
        ActivePowerBalance,
        OnVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        PowerAboveMinimumVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            ThermalMultiStartUnitCommitment,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            ThermalMultiStartUnitCommitment,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end

    add_feedforward_arguments!(container, device_model, devices)
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{PSY.ThermalMultiStart, ThermalMultiStartUnitCommitment},
    network_model::NetworkModel{<:AbstractActivePowerModel},
)
    devices = get_device_cache(device_model)
    # Must-run units never start or stop, so the start and initial-condition rows leave them out.
    committable = filter(!_is_must_run, devices)

    initial_conditions!(container, devices, ThermalMultiStartUnitCommitment())

    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionLB,
        devices,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionUB,
        devices,
        device_model,
        network_model,
    )
    if _has_offline_reserve_service(device_model)
        # Offline awards bound against the step's available max, so an off unit keeps them.
        add_constraints!(
            container,
            OfflineReserveBandConstraint,
            devices,
            device_model,
            network_model,
        )
    end

    add_constraints!(container, CommitmentConstraint, devices, device_model, network_model)
    add_constraints!(container, RampConstraint, devices, device_model, network_model)
    add_constraints!(container, DurationConstraint, devices, device_model, network_model)
    add_constraints!(
        container,
        StartupTimeLimitTemperatureConstraint,
        committable,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        StartTypeConstraint,
        committable,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        StartupInitialConditionConstraint,
        committable,
        device_model,
        network_model,
    )
    add_constraints!(
        container,
        ActiveRangeICConstraint,
        committable,
        device_model,
        network_model,
    )

    if haskey(get_time_series_names(device_model), ActivePowerTimeSeriesParameter)
        add_constraints!(
            container,
            ActivePowerVariableTimeSeriesLimitsConstraint,
            ActivePowerRangeExpressionUB,
            devices,
            device_model,
            network_model,
        )
    end

    add_feedforward_constraints!(container, device_model, devices)

    add_to_objective_function!(
        container,
        devices,
        device_model,
        get_network_formulation(network_model),
    )
    add_event_constraints!(container, devices, device_model, network_model)
    add_constraint_dual!(container, sys, device_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, D},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {
    T <: PSY.ThermalGen,
    D <: Union{ThermalCompactUnitCommitment, ThermalBasicCompactUnitCommitment},
}
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        PowerAboveMinimumVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        ReactivePowerVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        OnVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StartVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StopVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    add_variables!(container, TimeDurationOn, devices, D)
    add_variables!(container, TimeDurationOff, devices, D)
    add_variables!(container, PowerOutput, devices, D)

    if haskey(get_time_series_names(device_model), ActivePowerTimeSeriesParameter)
        add_parameters!(container, ActivePowerTimeSeriesParameter, devices, device_model)
    end

    _handle_common_thermal_parameters!(container, devices, device_model)

    initial_conditions!(container, devices, D())

    add_to_expression!(
        container,
        ActivePowerBalance,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerBalance,
        OnVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ReactivePowerBalance,
        ReactivePowerVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        PowerAboveMinimumVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end

    add_feedforward_arguments!(container, device_model, devices)
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, D},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {
    T <: PSY.ThermalGen,
    D <: Union{ThermalCompactUnitCommitment, ThermalBasicCompactUnitCommitment},
}
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        PowerAboveMinimumVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        OnVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StartVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        StopVariable,
        devices,
        D,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    add_variables!(container, TimeDurationOn, devices, D)
    add_variables!(container, TimeDurationOff, devices, D)
    add_variables!(container, PowerOutput, devices, D)

    if haskey(get_time_series_names(device_model), ActivePowerTimeSeriesParameter)
        add_parameters!(container, ActivePowerTimeSeriesParameter, devices, device_model)
    end

    _handle_common_thermal_parameters!(container, devices, device_model)

    initial_conditions!(container, devices, D())

    add_to_expression!(
        container,
        ActivePowerBalance,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerBalance,
        OnVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        PowerAboveMinimumVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            D,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end

    add_feedforward_arguments!(container, device_model, devices)
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, ThermalCompactDispatch},
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {T <: PSY.ThermalGen}
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        PowerAboveMinimumVariable,
        devices,
        ThermalCompactDispatch,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )
    add_variables!(
        container,
        ReactivePowerVariable,
        devices,
        ThermalCompactDispatch,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    add_variables!(container, PowerOutput, devices, ThermalCompactDispatch)

    add_parameters!(container, OnStatusParameter, devices, device_model)

    _handle_common_thermal_parameters!(container, devices, device_model)

    add_feedforward_arguments!(container, device_model, devices)

    initial_conditions!(container, devices, ThermalCompactDispatch())

    add_to_expression!(
        container,
        ActivePowerBalance,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ReactivePowerBalance,
        ReactivePowerVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerBalance,
        OnStatusParameter,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        PowerAboveMinimumVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            ThermalCompactDispatch,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            ThermalCompactDispatch,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end
    add_event_arguments!(container, devices, device_model, network_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, ThermalCompactDispatch},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {T <: PSY.ThermalGen}
    devices = get_device_cache(device_model)

    add_variables!(
        container,
        PowerAboveMinimumVariable,
        devices,
        ThermalCompactDispatch,
        get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
    )

    add_variables!(container, PowerOutput, devices, ThermalCompactDispatch)

    add_parameters!(container, OnStatusParameter, devices, device_model)

    _handle_common_thermal_parameters!(container, devices, device_model)

    add_feedforward_arguments!(container, device_model, devices)

    add_to_expression!(
        container,
        ActivePowerBalance,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )

    add_to_expression!(
        container,
        ActivePowerBalance,
        OnStatusParameter,
        devices,
        device_model,
        network_model,
    )

    initial_conditions!(container, devices, ThermalCompactDispatch())

    add_cost_expressions!(container, devices, device_model)

    add_to_expression!(
        container,
        ActivePowerRangeExpressionLB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerRangeExpressionUB,
        PowerAboveMinimumVariable,
        devices,
        device_model,
        network_model,
    )
    add_to_expression!(
        container,
        FuelConsumptionExpression,
        PowerAboveMinimumVariable,
        devices,
        device_model,
    )
    if get_use_slacks(device_model)
        add_variables!(
            container,
            RateofChangeConstraintSlackUp,
            devices,
            ThermalCompactDispatch,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
        add_variables!(
            container,
            RateofChangeConstraintSlackDown,
            devices,
            ThermalCompactDispatch,
            get_attribute(device_model, RELAX_BINARIES_ATTRIBUTE),
        )
    end
    add_event_arguments!(container, devices, device_model, network_model)
    return
end
