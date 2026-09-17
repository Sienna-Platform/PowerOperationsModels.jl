function add_variables!(
    container::OptimizationContainer,
    ::Type{T},
    service::PSY.AbstractReserve
    service_model::ServiceModel{R, <:AbstractSecurityConstrainedReservesFormulation},
    contributing_devices::Vector{V},
    ::Type{F},
    outage_uuids::Vector{String},
    outaged_gens::Dict{String, Set{PSY.Generator}},
) where {
    T <: AbstractContingencyVariableType,
    R <: PSY.AbstractReserve,
    V <: PSY.StaticInjection,
    F <: AbstractSecurityConstrainedReservesFormulation,
}
    service_name = PSY.get_name(service)
    device_names = [PSY.get_name(d) for d in contributing_devices]
    time_steps = get_time_steps(container)
    binary = get_variable_binary(T, R, F)
    jump_model = get_jump_model(container)

    # TODO: keep service name axis?
    variable = lazy_container_addition!(container, T, R, [PSY.get_name(service)], outage_uuids, device_names, time_steps; sparse = true)

    prefix = "$(T)_$(R)_$(service_name)_"
    for uuid in outage_uuids, device in contributing_devices
        for (i, device) in enumerate(contributing_devices)
            device_name = PSY.get_name(device)
            for t in time_steps
                v = variable[uuid, device_name, t] = JuMP.@variable(jump_model, base_name = "$(prefix){$(uuid), $(device_name), $(t)}", binary = binary)
                if device in outaged_gens[uuid]
                    JuMP.fix(v, 0.0)
                    continue
                end
                ub = get_variable_upper_bound(T, service, device, F)
                isnothing(ub) || JuMP.set_upper_bound(v, ub)
                lb = get_variable_lower_bound(T, service, device, F)
                isnothing(lb) || JuMP.set_lower_bound(v, lb)
                if get_warm_start(get_settings(container))
                    start = get_variable_warm_start_value(T, device, F)
                    isnothing(start) || JuMP.set_start_value(v, start)
                end
            end
        end
    end
    return
end

_generator_power(container::OptimizationContainer, generator::G, t::Int) where {G <: PSY.Generator} =
    get_variable(container, ActivePowerVariable, G)[PSY.get_name(generator), t]

"""Post-contingency reserve deployment must match outaged generator's
pre-contingency generation."""
function _constrain_post_contingency_balance!(
    container::OptimizationContainer,
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    constraint = add_constraints_container!(container, PostContingencyGenerationBalanceConstraint, R, outage_uuids, time_steps)
    deployment = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, R)
    for uuid in outage_uuids, t in time_steps
        # Not registering because balance == 0.0
        balance = JuMP.AffExpr(0.0)
        for generator in outaged_gens[uuid]
            JuMP.add_to_expression!(balance, -_generator_power(container, generator, t))
        end
        for device in contributing_devices
            JuMP.add_to_expression!(balance, deployment[uuid, PSY.get_name(device), t])
        end
        constraint[uuid, t] = JuMP.@constraint(jump_model, balance == 0)
    end
    return
end

function fn()
    power = get_variable(container, ActivePowerVariable, G)
    deployment = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, R)
    limit = generator in outaged_gens ? 0.0 : PSY.get_active_power_limits(generator).max
    for t in time_steps
        container[name, t] = JuMP.@constraint(jump_model, power[name, t] + deployment[name, t] <= limit)
    end
    return
end

"""Contributing devices inject and reserve up to their max, or nothing
if they are outaged."""
function _constrain_post_contingency_generation!()
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for uuid in outage_uuids, device in contributing_devices
        limits = PSY.get_active_power_limits(device)
    for uuid in outage_uuids, d in contributing_devices, t in time_steps
        if device in outaged_gens[uuid]
            JuMP.@constraint(jump_model, power + reserve == 0)
        else
            JuMP.@constraint(jump_model, power + reserve <= limits.max)
        end
    end
    return
end

###############################################################################
###############################################################################
###############################################################################

_service_outage_uuids(model::ServiceModel) = string.(sort!(collect(keys(get_outages(model)))))

function _outaged_generators(uuids::Vector{String}, generator_outage_pairs::Vector{Tuple{PSY.Generator, PSY.Outage}})
    outaged_gens = Dict{String, Set{PSY.Generator}}(uuid => Set{PSY.Generator}() for uuid in uuids)
    for (generator, outage) in generator_outage_pairs
        uuid = string(IS.get_uuid(outage))
        haskey(outaged_gens, uuid) || continue
        push!(outaged_gens[uuid], generator)
    end
    return outaged_gens
end

function construct_service!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::ServiceModel{SR, F},
    devices_template::Dict{Symbol, DeviceModel},
    ::Set{<:DataType},
    ::NetworkModel{<:AbstractActivePowerModel},
) where {SR <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    services = _services_with_contributors(model, sys)
    isempty(services) && return

    ts_services = [s for s in _demand_services(model, services) if _has_ts_requirement(model, s)]
    isempty(ts_services) || add_parameters!(container, RequirementTimeSeriesParameter, ts_services, model)

    outage_uuids = _service_outage_uuids(model)
    if isempty(outage_uuids)
        @warn "Service $(SR)('$name'): `service_model.outages` is empty; the \
               security-constrained formulation $(F) will not add any \
               post-contingency variables or constraints."
        return
    end
    generator_outage_pairs = PSY.get_component_supplemental_attribute_pairs(PSY.Generator, PSY.Outage, sys)
    outaged_gens = _outaged_generators(outage_uuids, generator_outage_pairs)

    for service in services
        contributing_devices = get_contributing_devices(model, PSY.get_name(service))
        add_variables!(container, PostContingencyActivePowerReserveDeploymentVariable, service, model, contributing_devices, F, outage_uuids, outaged_gens)
        add_service_variables!(container, ActivePowerReserveVariable, service, contributing_devices, F)
        add_to_expression!(container, ActivePowerReserveVariable, service, model, devices_template)
        add_feedforward_arguments!(container, model, service)
    end
    return
end

function construct_service!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::ServiceModel{SR, F},
    ::Dict{Symbol, DeviceModel},
    ::Set{<:DataType},
    network_model::NetworkModel{<:AbstractDCPNetworkModel},
) where {SR <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    service, contributing_devices, has_requirement_ts, outage_ids, outaged_gens,
    attribute_device_map = _construct_ervice_model_prologue!(container, sys, model)
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
    network_model::NetworkModel{<:CopperPlateNetworkModel},
) where {SR <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    services = _services_with_contributors(model, sys)
    isempty(services) && return

    _constrain_post_contingency_balance!()

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
    network_model::NetworkModel{<:AreaBalanceNetworkModel},
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
