#################################################################################
# Two-stage construct_device! for HybridSystem with HybridDispatchWithReserves.
#
# Argument stage: variables, parameters, expression containers, expression
#                 accumulation, feedforward arguments.
# Model stage:    constraints, feedforward constraints, objective function,
#                 dual recording.
#
# Mirrors energy_storage_models/storage_constructor.jl in structure. We provide
# both AbstractPowerModel (with reactive power) and AbstractActivePowerModel
# (without) variants.
#################################################################################

function _filter_hybrids(devices)
    devices_vec = collect(devices)
    return (
        all = devices_vec,
        with_thermal = [d for d in devices_vec if PSY.get_thermal_unit(d) !== nothing],
        with_renewable = [d for d in devices_vec if PSY.get_renewable_unit(d) !== nothing],
        with_storage = [d for d in devices_vec if PSY.get_storage(d) !== nothing],
        with_load = [d for d in devices_vec if PSY.get_electric_load(d) !== nothing],
    )
end

function _add_hybrid_reserve_arguments!(
    container::OptimizationContainer,
    devices,
    hybrids_with_storage,
    hybrids_with_thermal,
    hybrids_with_renewable,
    model::DeviceModel{T, D},
    network_model::NetworkModel{S},
) where {T <: PSY.HybridSystem, D <: HybridDispatchWithReserves, S <: AbstractPowerModel}
    time_steps = get_time_steps(container)

    # Hybrid PCC reserve variables
    add_variables!(container, HybridReserveVariableOut, devices, D)
    add_variables!(container, HybridReserveVariableIn, devices, D)

    # Allocate hybrid-boundary aggregation expression containers
    for E in (
        HybridTotalReserveOutUpExpression, HybridTotalReserveOutDownExpression,
        HybridTotalReserveInUpExpression, HybridTotalReserveInDownExpression,
        HybridServedReserveOutUpExpression, HybridServedReserveOutDownExpression,
        HybridServedReserveInUpExpression, HybridServedReserveInDownExpression,
    )
        lazy_container_addition!(container, E, T, PSY.get_name.(devices), time_steps)
    end

    # Accumulate Out/In reserve variables into Total* and Served* expressions
    for E in (HybridTotalReserveOutUpExpression, HybridTotalReserveOutDownExpression,
        HybridServedReserveOutUpExpression, HybridServedReserveOutDownExpression)
        add_to_expression!(
            container,
            E,
            HybridReserveVariableOut,
            devices,
            model,
            network_model,
        )
    end
    for E in (HybridTotalReserveInUpExpression, HybridTotalReserveInDownExpression,
        HybridServedReserveInUpExpression, HybridServedReserveInDownExpression)
        add_to_expression!(
            container,
            E,
            HybridReserveVariableIn,
            devices,
            model,
            network_model,
        )
    end

    # Per-subcomponent reserve variables
    if !isempty(hybrids_with_thermal)
        add_variables!(container, HybridThermalReserveVariable, hybrids_with_thermal, D)
    end
    if !isempty(hybrids_with_renewable)
        add_variables!(container, HybridRenewableReserveVariable, hybrids_with_renewable, D)
    end
    if !isempty(hybrids_with_storage)
        add_variables!(container, HybridChargingReserveVariable, hybrids_with_storage, D)
        add_variables!(container, HybridDischargingReserveVariable, hybrids_with_storage, D)

        # Storage-side reserve expression containers, keyed by HybridSystem
        for E in (
            ReserveAssignmentBalanceUpDischarge, ReserveAssignmentBalanceUpCharge,
            ReserveAssignmentBalanceDownDischarge, ReserveAssignmentBalanceDownCharge,
            ReserveDeploymentBalanceUpDischarge, ReserveDeploymentBalanceUpCharge,
            ReserveDeploymentBalanceDownDischarge, ReserveDeploymentBalanceDownCharge,
        )
            lazy_container_addition!(
                container,
                E,
                T,
                PSY.get_name.(hybrids_with_storage),
                time_steps,
            )
        end

        # Wire HybridDischargingReserveVariable into Discharge expressions
        for E in (
            ReserveAssignmentBalanceUpDischarge, ReserveAssignmentBalanceDownDischarge,
            ReserveDeploymentBalanceUpDischarge, ReserveDeploymentBalanceDownDischarge,
        )
            add_to_expression!(
                container,
                E,
                HybridDischargingReserveVariable,
                hybrids_with_storage,
                model,
            )
        end
        for E in (
            ReserveAssignmentBalanceUpCharge, ReserveAssignmentBalanceDownCharge,
            ReserveDeploymentBalanceUpCharge, ReserveDeploymentBalanceDownCharge,
        )
            add_to_expression!(
                container,
                E,
                HybridChargingReserveVariable,
                hybrids_with_storage,
                model,
            )
        end

        # TotalReserveOffering aggregation per service, keyed by HybridSystem
        services = Set{PSY.Service}()
        for d in hybrids_with_storage
            union!(services, PSY.get_services(d))
        end
        for s in services
            lazy_container_addition!(container, TotalReserveOffering, T,
                PSY.get_name.(hybrids_with_storage), time_steps;
                meta = "$(typeof(s))_$(PSY.get_name(s))")
        end
        for v in (HybridChargingReserveVariable, HybridDischargingReserveVariable)
            add_to_expression!(
                container,
                TotalReserveOffering,
                v,
                hybrids_with_storage,
                model,
            )
        end
    end
    return
end

_maybe_add_reactive_power_variable!(
    container,
    devices,
    formulation,
    ::Type{<:AbstractPowerModel},
) =
    add_variables!(container, ReactivePowerVariable, devices, formulation)
_maybe_add_reactive_power_balance!(
    container,
    devices,
    model,
    network_model::NetworkModel{<:AbstractPowerModel},
) =
    add_to_expression!(
        container,
        ReactivePowerBalance,
        ReactivePowerVariable,
        devices,
        model,
        network_model,
    )
_maybe_add_reactive_limits!(
    container,
    devices,
    model,
    network_model::NetworkModel{<:AbstractPowerModel},
) =
    add_constraints!(container, ReactivePowerVariableLimitsConstraint,
        ReactivePowerVariable,
        devices, model, network_model)

_maybe_add_reactive_power_variable!(
    container,
    devices,
    formulation,
    ::Type{AbstractActivePowerModel},
) =
    nothing
_maybe_add_reactive_power_balance!(
    container,
    devices,
    model,
    ::NetworkModel{<:AbstractActivePowerModel},
) =
    nothing
_maybe_add_reactive_power_limits!(
    container,
    devices,
    model,
    ::NetworkModel{<:AbstractActivePowerModel},
) =
    nothing

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{T, D},
    network_model::NetworkModel{S},
) where {T <: PSY.HybridSystem, D <: HybridDispatchWithReserves, S <: AbstractPowerModel}
    devices = get_available_components(model, sys)
    grouped = _filter_hybrids(devices)

    # PCC variables
    add_variables!(container, ActivePowerOutVariable, devices, D)
    add_variables!(container, ActivePowerInVariable, devices, D)
    _maybe_add_reactive_power_variable!(container, devices, D, S)
    add_variables!(container, ReservationVariable, devices, D)

    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerInVariable,
        devices,
        model,
        network_model,
    )
    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerOutVariable,
        devices,
        model,
        network_model,
    )
    _maybe_add_reactive_power_balance!(container, devices, model, network_model)

    # Subcomponent variables
    if !isempty(grouped.with_thermal)
        add_variables!(container, HybridThermalActivePower, grouped.with_thermal, D)
        add_variables!(container, OnVariable, grouped.with_thermal, D)
    end
    if !isempty(grouped.with_renewable)
        add_variables!(container, HybridRenewableActivePower, grouped.with_renewable, D)
        add_parameters!(
            container,
            HybridRenewableActivePowerTimeSeriesParameter,
            grouped.with_renewable,
            model,
        )
    end
    if !isempty(grouped.with_storage)
        add_variables!(container, HybridStorageChargePower, grouped.with_storage, D)
        add_variables!(container, HybridStorageDischargePower, grouped.with_storage, D)
        add_variables!(container, EnergyVariable, grouped.with_storage, D)
        add_variables!(container, HybridStorageReservation, grouped.with_storage, D)
        initial_conditions!(container, devices, D())
    end
    if !isempty(grouped.with_load)
        add_parameters!(
            container,
            HybridElectricLoadTimeSeriesParameter,
            grouped.with_load,
            model,
        )
    end

    if has_service_model(model)
        _add_hybrid_reserve_arguments!(container, devices,
            grouped.with_storage, grouped.with_thermal, grouped.with_renewable,
            model, network_model)
    end

    add_feedforward_arguments!(container, model, devices)
    add_event_arguments!(container, devices, model, network_model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{T, D},
    network_model::NetworkModel{S},
) where {T <: PSY.HybridSystem, D <: HybridDispatchWithReserves, S <: AbstractPowerModel}
    devices = get_available_components(model, sys)
    grouped = _filter_hybrids(devices)

    # PCC reactive-power limits (active-power limits handled via the asset balance + status constraints)
    _maybe_add_reactive_power_limits!(container, devices, model, network_model)

    # PCC ↔ subcomponent plumbing
    add_constraints!(container, HybridStatusOutOnConstraint, devices, model, network_model)
    add_constraints!(container, HybridStatusInOnConstraint, devices, model, network_model)
    add_constraints!(
        container,
        HybridEnergyAssetBalanceConstraint,
        devices,
        model,
        network_model,
    )

    # Thermal subcomponent
    if !isempty(grouped.with_thermal)
        if has_service_model(model)
            add_constraints!(
                container,
                HybridThermalReserveLimitConstraint,
                grouped.with_thermal,
                model,
                network_model,
            )
        else
            add_constraints!(
                container,
                HybridThermalOnVariableUbConstraint,
                grouped.with_thermal,
                model,
                network_model,
            )
            add_constraints!(
                container,
                HybridThermalOnVariableLbConstraint,
                grouped.with_thermal,
                model,
                network_model,
            )
        end
    end

    # Renewable subcomponent
    if !isempty(grouped.with_renewable)
        add_constraints!(
            container,
            HybridRenewableActivePowerLimitConstraint,
            grouped.with_renewable,
            model,
            network_model,
        )
        if has_service_model(model)
            add_constraints!(
                container,
                HybridRenewableReserveLimitConstraint,
                grouped.with_renewable,
                model,
                network_model,
            )
        end
    end

    # Storage subcomponent
    if !isempty(grouped.with_storage)
        add_constraints!(
            container,
            HybridStorageBalanceConstraint,
            grouped.with_storage,
            model,
            network_model,
        )
        if get_attribute(model, "energy_target")
            add_constraints!(
                container,
                StateofChargeTargetConstraint,
                grouped.with_storage,
                model,
                network_model,
            )
        end
        if has_service_model(model)
            add_constraints!(
                container,
                ReserveCoverageConstraint,
                grouped.with_storage,
                model,
                network_model,
            )
            add_constraints!(
                container,
                ReserveCoverageConstraintEndOfPeriod,
                grouped.with_storage,
                model,
                network_model,
            )
            add_constraints!(
                container,
                HybridStorageChargingReservePowerLimitConstraint,
                grouped.with_storage,
                model,
                network_model,
            )
            add_constraints!(
                container,
                HybridStorageDischargingReservePowerLimitConstraint,
                grouped.with_storage,
                model,
                network_model,
            )
        else
            add_constraints!(
                container,
                HybridStorageStatusChargeOnConstraint,
                grouped.with_storage,
                model,
                network_model,
            )
            add_constraints!(
                container,
                HybridStorageStatusDischargeOnConstraint,
                grouped.with_storage,
                model,
                network_model,
            )
        end
    end

    # Hybrid-boundary reserve coupling
    if has_service_model(model)
        add_constraints!(
            container,
            HybridReserveAssignmentConstraint,
            devices,
            model,
            network_model,
        )
        add_constraints!(
            container,
            HybridReserveBalanceConstraint,
            devices,
            model,
            network_model,
        )
    end

    add_feedforward_constraints!(container, model, devices)
    add_event_constraints!(container, devices, model, network_model)
    objective_function!(container, devices, model, S)
    add_constraint_dual!(container, sys, model)
    return
end
