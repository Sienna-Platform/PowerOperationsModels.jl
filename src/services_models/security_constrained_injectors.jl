function add_variables!(
    container::OptimizationContainer,
    ::Type{T},
    service::PSY.AbstractReserve
    service_model::ServiceModel{R, <:AbstractSecurityConstrainedReservesFormulation},
    contributing_devices::Vector{V},
    ::Type{F},
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
    outaged_gens::Dict{Int, Set{Tuple{DataType, String}}}
    contributing_devices::Vector{D},
) where {D <: PSY.StaticInjection}
    time_steps = get_time_steps(container)
    cons = add_constraints_container!(container, PostContingencyGenerationBalanceConstraint, D, outage_uuids, time_steps)
    deployment = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, D)
    jump_model = get_jump_model(container)
    for (uuid, gens) in outaged_gens, t in time_steps
        balance = JuMP.AffExpr(0.0)
        for (gen_type, name) in gens
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
    outaged_gens::Dict{Int, Set{Tuple{DataType, String}}},
    contributing_devices::Vector{D},
) where {D <: PSY.StaticInjection}
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    cons = add_constraints_container!(container, PostContingencyActivePowerGenerationLimitsConstraint, D, time_steps)
    power = get_variable(container, ActivePowerVariable, D)
    reserve = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, D)
    for device in contributing_devices, (uuid, gens) in outaged_gens
        name = PSY.get_name(device)
        (D, name) in gens && continue
        # TODO: max deployment fraction?
        limit = PSY.get_max_active_power(device)
        for t in time_steps
            cons[name, uuid, t] = JuMP.@constraint(jump_model, power[name, t] + reserve[name, t] <= limit)
        end
    end
    return
end

"""Contributing devices with a TS-backed pre-contingency reserve limit maintain
that limit post-contingency."""
function _constrain_post_contingency_reserve!(
    container::OptimizationContainer,
    outaged_gens::Dict{Int, Set{Tuple{DataType, String}}},
    contributing_devices::Vector{D},
) where {D <: PSY.StaticInjection}
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    cons = add_constraints_container!(container, PostContingencyActivePowerReserveDeploymentVariableLimitsConstraint, D, time_steps)
    pre_reserve = get_variable(container, ActivePowerReserveVariable, D)
    post_reserve = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, D)
    for device in contributing_devices, (uuid, gens) in outaged_gens
        name = PSY.get_name(device)
        (D, name) in gens && continue
        for t in time_steps
            cons[name, uuid, t] = JuMP.@constraint(jump_model, post_reserve[name, t] <= pre_reserve[name, t])
        end
    end
end

# TODO: What about outaged gens? Subtract their power on the node?
function _build_post_contingency_nodal_power!(
    container::OptimizationContainer,
    outaged_gens::Dict{Int, Set{Tuple{DataType, String}}},
    contributing_devices::Vector{D},
) where {R <: PSY.AbstractReserve, D <: PSY.StaticInjection}
    expr = lazy_container_addition!(container, PostContingencyNodalActivePowerDeployment, PSY.Outage, Int[], Int[], Int[]; sparse = true)
    power = get_variable(container, ActivePowerVariable, D)
    reserve = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, D)
    for device in contributing_devices, (uuid, gens) in outaged_gens
        name = PSY.get_name(device)
        (D, name) in gens && continue
        bus = PNM.get_mapped_bus_number(network_reduction, PSY.get_bus(device))
        for uuid in values(outaged_gens), t in time_steps
            ex = expr[uuid, bus, t] = JuMP.AffExpr(0.0)
            JuMP.add_to_expression!(ex, power[name, t])
            JuMP.add_to_expression!(ex, reserve[name, t])
        end
    end
    return
end

# Go through monitored lines, find what arc they reduced to, build flow on that arc.
# Flow on arc will consider pre-conting. flow and post-conting. nodal power.
function _build_post_contingency_flow!(
    container::OptimizationContainer,
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
    monitored_lines::Dict{M, Vector{Int}},
) where {R <: PSY.AbstractReserve, M <: PSY.ACTransmission}
    catalog = get_branch_catalog(network_model)
    reduction_name_map = PNM.get_component_to_reduction_name_map(catalog, M)
    name_to_arc_map = PNM.get_name_to_arc_map(catalog, M)

    expr = add_expression_container!(container, PostContingencyBranchFlow, M, String[], Int[], Int[]; sparse = true)
    nodal = get_expression(container, PostContingencyNodalActivePowerDeployment, PSY.Outage)
    # TODO is pre_flow needed when nodal already considers active power?
    pre_flow = get_expression(container, PTDFBranchFlow, M)

    ptdf = get_PTDF_matrix(network_model)
    bus_axis = PNM.get_bus_axis(ptdf)

    dfs = Dict{String, Vector{Float64}}()
    for line in monitored_lines
        name = PSY.get_name(line)
        arc = name_to_arc_map[reduction_name_map[name]]
        ptdf_col = ptdf[arc, :]
        sign = get_ptdf_orientation_sign(catalog, M, name)
        for bus in buses
            # TODO: am I indexing the bus correctly?
            df = sign * ptdf_col[bus_axis[bus]]
            abs(df) < PTDF_ZERO_TOL && continue
            push!(dfs[name], df)
        end
    end

    for (line, uuids) in monitored_lines
        name = PSY.get_name(line)
        for uuid in uuids, t in time_steps
            ex = expr[name, uuid, t] = JuMP.AffExpr(0.0)
            JuMP.add_to_expression!(ex, pre_flow)
            for bus in buses
                JuMP.add_to_expression!(ex, dfs[name][bus], nodal[uuid, bus, t])
            end
        end
    end
    return
end

###############################################################################
###############################################################################
###############################################################################

function _outaged_generators(sys::PSY.System, model::ServiceModel{R, F}) where {R <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    uuids = string.(sort!(collect(keys(get_outages(model)))))
    if isempty(uuids)
        @warn "Service{$(R),$(F)}($(PSY.get_name(model)): `service_model.outages` is empty; the \
               security-constrained formulation will not add any \
               post-contingency variables or constraints."
        return
    end
    generator_outage_pairs = PSY.get_component_supplemental_attribute_pairs(PSY.Generator, PSY.Outage, sys)
    outaged_gens = Dict{Int, Set{Tuple{DataType, String}}}(uuid => Set{Tuple{DataType, String}}() for uuid in uuids)
    for (generator, outage) in generator_outage_pairs
        haskey(outaged_gens, uuid) || continue
        push!(outaged_gens[uuid], (typeof(generator), PSY.get_name(generator)))
    end
    return outaged_gens
end

_formulation_needs_requirement_ts(::Type{SecurityConstrainedContingencyReserve}) = false
_formulation_needs_requirement_ts(::Type{SecurityConstrainedRampReserve}) = true

function _service_needs_requirement_ts(sys::PSY.System, service::S, model::ServiceModel{S, F}) where {S <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    _formulation_needs_requirement_ts(F) && return true
    ts_names = get_time_series_names(model)
    has(ts_names, RequirementTimeSeriesParameter) || return false
    return PSY.has_time_series(service, get_deterministic_time_series_type(sys), ts_name[RequirementTimeSeriesParameter])
end

function construct_service!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::ServiceModel{S, F},
    devices_template::Dict{Symbol, DeviceModel},
    ::Set{<:DataType},
    ::NetworkModel{<:AbstractActivePowerModel},
) where {S <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    services = _services_with_contributors(model, sys)
    isempty(services) && return

    outaged_gens = _outaged_generators(sys, model)
    isempty(outaged_gens) && return

    ts_services = [s for s in _demand_services(model, services) if _has_ts_requirement(model, s)]
    isempty(ts_services) || add_parameters!(container, RequirementTimeSeriesParameter, ts_services, model)

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
    model::ServiceModel{S, F},
    ::Dict{Symbol, DeviceModel},
    ::Set{<:DataType},
    network_model::NetworkModel{<:CopperPlateNetworkModel},
) where {S <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    services = _services_with_contributors(model, sys)
    isempty(services) && return
    outaged_gens = _outaged_generators(sys, model)
    isempty(outaged_gens) && return

    for service in services
        per_type = get_contributing_devices(model, PSY.get_name(service))
        has_requirement = _service_needs_requirement_ts(sys, service, model)
        for contributing_devices in values(per_type)
            _constrain_post_contingency_balance!(container, outaged_gens, contributing_devices)
            _constrain_post_contingency_generation!(container, outaged_gens, contributing_devices)
            if has_requirement
                # TODO: Both are needed? Cause what if pre-conting. is too loose?
                # TODO: Don't I have to enforce the pre-conting. level too?
                _constrain_post_contingency_reserve!(container, outaged_gens, contributing_devices)
            end
        end
    end
    return
end

function construct_service!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::ServiceModel{S, F},
    ::Dict{Symbol, DeviceModel},
    ::Set{<:DataType},
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
) where {S <: PSY.AbstractReserve, F <: AbstractSecurityConstrainedReservesFormulation}
    services = _services_with_contributors(model, sys)
    isempty(services) && return
    outaged_gens = _outaged_generators(sys, model)
    isempty(services) && return

    # Build PC nodal power before building and constraining PC flows
    for service in services
        per_type = get_contributing_devices(model, PSY.get_name(services))
        for contributing_devices in values(per_type)
            _build_post_contingency_nodal_power(model, outaged_gens, service, contributing_devices)
        end
    end

    for service in services
        per_type = get_contributing_devices(model, PSY.get_name(service))
        for contributing_devices in values(per_type)
            _constrain_post_contingency_balance!(container, outaged_gens, contributing_devices)
            _constrain_post_contingency_generation!(container, outaged_gens, contributing_devices)
            if has_requirement
                _constrain_post_contingency_reserve!(container, outaged_gens, contributing_devices)
            end

            _constrain_post_contingency_flow!(container, outaged_gens, contributing_devices)
        end
    end
    return
end
