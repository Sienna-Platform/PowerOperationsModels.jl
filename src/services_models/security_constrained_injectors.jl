function construct_service!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::ServiceModel{SR, F},
    devices_template::Dict{Symbol, DeviceModel},
    ::Set{<:DataType},
    ::NetworkModel{<:AbstractActivePowerModel},
) where {SR <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    name = get_service_name(model)
    service = PSY.get_component(SR, sys, name)
    !PSY.get_available(service) && return
    contributing_devices = get_contributing_devices(model)

    has_requirement_ts = _service_requires_requirement_ts(sys, service, model)
    if has_requirement_ts
        add_parameters!(container, RequirementTimeSeriesParameter, service, model)
        add_variables!(
            container,
            ActivePowerReserveVariable,
            service,
            contributing_devices,
            F(),
        )
        add_to_expression!(container, ActivePowerReserveVariable, model, devices_template)
    end
    add_feedforward_arguments!(container, model, service)

    outage_ids = _service_outage_ids(model)
    if isempty(outage_ids)
        @warn "Service $(SR)('$name'): `service_model.outages` is empty; the \
               security-constrained formulation $(F) will not add any \
               post-contingency variables or constraints."
        return
    end

    attribute_device_map = PSY.get_component_supplemental_attribute_pairs(
        PSY.Generator, PSY.Outage, sys,
    )
    outaged_gens = _outaged_generators_by_outage_id(outage_ids, attribute_device_map)
    add_variables!(
        container,
        PostContingencyActivePowerReserveDeploymentVariable,
        service,
        model,
        contributing_devices,
        F(),
        outage_ids,
        outaged_gens,
    )
    return
end

function construct_service!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::ServiceModel{SR, F},
    ::Dict{Symbol, DeviceModel},
    ::Set{<:DataType},
    network_model::NetworkModel{<:PM.AbstractDCPModel},
) where {SR <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    service, contributing_devices, has_requirement_ts, outage_ids, outaged_gens,
    attribute_device_map = _construct_service_model_prologue!(container, sys, model)
    isempty(outage_ids) && return

    _construct_service_post_contingency_balance!(
        container, service, contributing_devices, model, network_model, outage_ids,
        outaged_gens, attribute_device_map,
    )
    relevant_buses = _injection_relevant_buses(
        get_network_reduction(network_model), contributing_devices, outaged_gens,
    )
    add_to_expression!(
        container, PostContingencyNodalActivePowerDeployment,
        PostContingencyActivePowerReserveDeploymentVariable,
        contributing_devices, relevant_buses, service, model, network_model,
        outage_ids, outaged_gens,
    )
    add_to_expression!(
        container, PostContingencyNodalActivePowerDeployment, ActivePowerVariable,
        attribute_device_map, service, model, network_model,
    )
    resolved_arcs = _resolve_service_monitored_arcs(
        model, get_network_reduction(network_model),
    )
    add_post_contingency_flow_expressions!(
        container, PostContingencyBranchFlow, service, model, network_model,
        resolved_arcs,
    )
    add_constraints!(
        container, PostContingencyFlowRateConstraint, PostContingencyBranchFlow,
        service, model, network_model, resolved_arcs,
    )

    _construct_service_deployment_limits!(
        container, contributing_devices, service, model, network_model,
        has_requirement_ts, outage_ids, outaged_gens,
    )
    return
end

function construct_service!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::ServiceModel{SR, F},
    ::Dict{Symbol, DeviceModel},
    ::Set{<:DataType},
    network_model::NetworkModel{<:CopperPlatePowerModel},
) where {SR <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    service, contributing_devices, has_requirement_ts, outage_ids, outaged_gens,
    attribute_device_map = _construct_service_model_prologue!(container, sys, model)
    isempty(outage_ids) && return

    _construct_service_post_contingency_balance!(
        container, service, contributing_devices, model, network_model, outage_ids,
        outaged_gens, attribute_device_map,
    )

    _construct_service_deployment_limits!(
        container, contributing_devices, service, model, network_model,
        has_requirement_ts, outage_ids, outaged_gens,
    )
    return
end

function construct_service!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::ServiceModel{SR, F},
    ::Dict{Symbol, DeviceModel},
    ::Set{<:DataType},
    network_model::NetworkModel{<:AreaBalancePowerModel},
) where {SR <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    service, contributing_devices, has_requirement_ts, outage_ids, outaged_gens,
    attribute_device_map = _construct_service_model_prologue!(container, sys, model)
    isempty(outage_ids) && return

    # The system-wide `PostContingencyActivePowerBalance` expression built by
    # `_construct_service_post_contingency_balance!` is redundant here (the
    # per-area balance below recovers it on summation), so it is not called;
    # `attribute_device_map` came from the shared prologue scan instead.
    add_to_expression!(
        container, sys, PostContingencyAreaActivePowerDeployment,
        PostContingencyActivePowerReserveDeploymentVariable,
        contributing_devices, service, model, network_model, outage_ids, outaged_gens,
    )
    add_to_expression!(
        container, PostContingencyAreaActivePowerDeployment, ActivePowerVariable,
        attribute_device_map, service, model, network_model,
    )
    add_post_contingency_area_interchange_flow_deviation_variables!(
        container, sys, service, model, network_model, outage_ids,
    )
    add_constraints!(
        container, sys, PostContingencyCopperPlateBalanceConstraint,
        PostContingencyAreaActivePowerDeployment,
        service, model, network_model, outage_ids,
    )
    resolved_area_interchanges =
        _resolve_service_monitored_area_interchanges(sys, model)
    add_post_contingency_flow_expressions!(
        container, sys, PostContingencyAreaInterchangeFlow,
        service, model, network_model, resolved_area_interchanges,
    )
    add_constraints!(
        container, sys, PostContingencyFlowRateConstraint,
        PostContingencyAreaInterchangeFlow,
        service, model, network_model, resolved_area_interchanges,
    )

    _construct_service_deployment_limits!(
        container, contributing_devices, service, model, network_model,
        has_requirement_ts, outage_ids, outaged_gens,
    )
    return
end
