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
    var = add_variable_container!(container, T, V, String[], Int[], Int[]; sparse = true)
    binary = get_variable_binary(T, R, F)
    jump_model = get_jump_model(container)
    for uuid in outage_uuids, device in contributing_devices, t in time_steps
        device_name = PSY.get_name(device)
        v = var[device_name, uuid, t] = JuMP.@variable(jump_model, base_name = "$(T)_$(R)_$(service_name)_{$(uuid), $(device_name), $(t)}", binary = binary)
        if device in outaged_gens[uuid]
            JuMP.fix(v, 0.0)
            continue
        end
        # TODO Check about this trait... I don't see where it's defined
        ub = get_variable_upper_bound(T, service, device, F)
        isnothing(ub) || JuMP.set_upper_bound(v, ub)
        lb = get_variable_lower_bound(T, service, device, F)
        isnothing(lb) || JuMP.set_lower_bound(v, lb)
        if get_warm_start(get_settings(container))
            start = get_variable_warm_start_value(T, device, F)
            isnothing(start) || JuMP.set_start_value(v, start)
        end
    end
    return
end

"""Post-contingency reserve deployment must match outaged generator's
pre-contingency generation."""
function _constrain_post_contingency_balance!(
    container::OptimizationContainer,
    outage_uuids::Vector{Int},
    outaged_gens::Dict{Int, Set{Tuple{DataType, String}}}
    contributing_devices::Vector{D},
) where {D <: PSY.StaticInjection}
    time_steps = get_time_steps(container)
    cons = add_constraints_container!(container, PostContingencyGenerationBalanceConstraint, D, outage_uuids, time_steps)
    deployment = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, D)
    jump_model = get_jump_model(container)
    for uuid in outage_uuids, t in time_steps
        balance = JuMP.AffExpr(0.0)
        for (gen_type, name) in outaged_gens[uuid]
            power = get_variable(container, ActivePowerVariable, gen_type)
            JuMP.add_to_expression!(balance, -power[name, t])
        end
        for device in contributing_devices
            JuMP.add_to_expression!(balance, deployment[uuid, PSY.get_name(device), t])
        end
        cons[uuid, t] = JuMP.@constraint(jump_model, balance == 0)
    end
    return
end

"""Contributing devices inject and reserve up to their max, or nothing
if they are outaged."""
function _constrain_post_contingency_generation!(
    container::OptimizationContainer,
    outage_uuids::Vector{Int},
    outaged_gens::Dict{Int, Set{Tuple{DataType, String}}},
    contributing_devices::Vector{D},
) where {D <: PSY.StaticInjection}
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    cons = add_constraints_container!(container, PostContingencyActivePowerGenerationLimitsConstraint, R, time_steps)
    for device in contributing_devices, uuid in outage_uuids
        name = PSY.get_name(device)
        power = get_variable(container, ActivePowerVariable, D)
        reserve = get_varaible(container, PostContingencyActivePowerReserveDeploymentVariable, D)
        limit = (D, name) in outaged_gens[uuid] ? 0.0 : PSY.get_active_power_limits(device).max
        # TODO: max deployment fraction?
        for t in time_steps
            cons[name, uuid, t] = JuMP.@constraint(jump_model, power[name, t] + reserve[name, t] <= limit)
        end
    end
    return
end

###############################################################################
###############################################################################
###############################################################################

_service_outage_uuids(model::ServiceModel) = string.(sort!(collect(keys(get_outages(model)))))

function _outaged_generators(sys::PSY.System, uuids::Vector{Int})
    generator_outage_pairs = PSY.get_component_supplemental_attribute_pairs(PSY.Generator, PSY.Outage, sys)
    outaged_gens = Dict{Int, Set{Tuple{DataType, String}}}(uuid => Set{Tuple{DataType, String}}() for uuid in uuids)
    for (generator, outage) in generator_outage_pairs
        haskey(outaged_gens, uuid) || continue
        push!(outaged_gens[uuid], (typeof(generator), PSY.get_name(generator)))
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
    outaged_gens = _outaged_generators(sys, outage_uuids)

    for service in services
        per_type = get_contributing_devices(model, PSY.get_name(service))
        for contributing_devices in values(per_type)
            add_variables!(container, PostContingencyActivePowerReserveDeploymentVariable, service, model, contributing_devices, F, outage_uuids, outaged_gens)
        end
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
