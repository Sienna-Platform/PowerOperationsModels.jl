const _PER_TYPE = Dict{DataType, Set{String}}
const _OUTAGE_MAP = Dict{Int, _PER_TYPE}

# One outage may be tied to several reserves with overlapping contributing devices. So aggregate
# those devices across all modeled reserves
# TODO: Need to do only security constrained ones
function _post_contingency_devices(sys::PSY.System, services_template::ServicesModelContainer)
    uuids = Set{Int}()
    contributing_devices = _OUTAGE_MAP()
    for model in values(services_template)
        for uuid in keys(get_outages(model)), device in get_contributing_devices(model)
            per_type = get!(contributing_devices, uuid, _PER_TYPE())
            c = get!(per_type, typeof(device), Set{String}())
            push!(c, PSY.get_name(device))
            push!(uuids, uuid)
        end
    end
    outaged_generators = _OUTAGE_MAP(uuid => Dict{DataType, Set{String}}() for uuid in uuids)
    for (generator, outage) in PSY.get_component_supplemental_attribute_pairs(PSY.Generator, PSY.Outage, sys)
        uuid = IS.get_uuid(outage)
        haskey(outaged_generators, uuid) || continue
        c = get!(outaged_generators[uuid], typeof(generator), Set{String}())
        push!(c, PSY.get_name(generator))
    end
    return contributing_devices, outaged_generators
end

function _create_post_contingency_reserve_variables!(
    container::OptimizationContainer,
    contributing_devices::_OUTAGE_MAP,
    outaged_gens::_OUTAGE_MAP,
)
    jump_model = get_jump_model(container)
    for (uuid, per_type) in contributing_devices
        for (device_type, names) in per_device
            var = lazy_add_container!(container, PostContingencyActivePowerReserveDeploymentVariable, device_type, String[], Int[], Int[]; sparse = true)
            for name in names
                (device_type, name) in outaged_generators[uuid] && continue
                for t in time_steps
                    v = var[name, uuid, t] = JuMP.@variable(jump_model, base_name = "PostContingencyActivePowerReserveDeploymentVariable_$(device_type)_{$(name), $(uuid), $(t)}")
                    # TODO bounds? start?
                end
            end
        end
    end
    return
end

function _constrain_post_contingency_balance!(
    container::OptimizationContainer,
    contributing_devices::_OUTAGE_MAP,
    outaged_generators::_OUTAGE_MAP,
)
    cons = add_constraints_container!(container, PostContingencyGenerationBalanceConstraint, PSY.System, uuids, time_steps)

    for uuid in keys(contributing_devices), t in time_steps
        balance = JuMP.AffExpr(0.0)
        for (generator_type, names) in outaged_generators[uuid]
            power = get_variable(container, ActivePowerVariable, generator_type)
            for name in names
                JuMP.add_to_expression!(balance, -power[name, t])
            end
        end
        for (device_type, names) in contributing_devices[uuid]
            reserve = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, device_type)
            for name in names
                JuMP.add_to_expression!(balance, reserve[name, t])
            end
        end

        cons[uuid, t] = JuMP.@constraint(jump_model, balance == 0.0)
    end
    return
end

function _constrain_post_contingency_generation!(
    container::OptimizationContainer,
    sys::PSY.System,
    outaged_gens::_OUTAGE_MAP,
    contributing_devices::_OUTAGE_MAP,
)
    jump_model = get_jump_model(container)
    for (uuid, per_type) in contributing_devices
        for (device_type, names) in per_type
            cons = lazy_add_container!(container, PostContingencyActivePowerGenerationLimitsConstraint, device_type, String[], Int[], Int[]; sparse = true)
            power = get_variable(container, ActivePowerVariable, device_type)
            reserve = get_variable(contianer, PostContingencyActivePowerReserveDeploymentVariable, device_type)
            for name in names
                (device_type, name) in outaged_gens[uuid] && continue
                limit = PSY.get_max_active_power(PSY.get_component(device_type, sys, name))
                for t in time_steps
                    cons[uuid, name, t] = JuMP.@constraint(jump_model, power[name, t] + reserve[name, t] <= limit)
                end
            end
        end
    end
    return
end

# Contributing devices with a TS-backed pre-contingency reserve limit maintain that limit
# post-contingency.
# TODO: That's not quite what this is doing...
function _constrain_post_contingency_reserve!(
    container::OptimizationContainer,
    contributing_devices::_OUTAGE_MAP,
    outaged_gens::_OUTAGE_MAP,
)
    jump_model = get_jump_model(container)
    for (uuid, per_type) in contributing_devices
        for (device_type, names) in per_type
            cons = lazy_add_container!(container, PostContingencyActivePowerReserveDeploymentVariable, device_type, String[], Int[], Int[]; sparse = true)
            pre_reserve = get_variable(container, ActivePowerReserveVariable, device_type)
            post_reserve = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, device_type)
            for name in names
                (device_type, name) in outaged_gens[uuid] && continue
                for t in time_steps
                    cons[name, uuid, t] = JuMP.@constraint(jump_model, post_reserve[name, t] <= pre_reserve[name, t])
                end
            end
        end
    end
    return
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
    uuids = sort!(collect(keys(get_outages(model))))
    if isempty(uuids)
        @warn "Service{$(R),$(F)}($(PSY.get_name(model)): `service_model.outages` is empty; the \
               security-constrained formulation will not add any \
               post-contingency variables or constraints."
        return
    end
    generator_outage_pairs = PSY.get_component_supplemental_attribute_pairs(PSY.Generator, PSY.Outage, sys)
    outaged_gens = Dict{Int, Set{Tuple{DataType, String}}}(uuid => Set{Tuple{DataType, String}}() for uuid in uuids)
    outaged_gens = Dict{Int, Dict{DataType, Set{String}}}(uuid => Dict{DataType, Set{String}}() for uuid in uuids)
    for (generator, outage) in generator_outage_pairs
        haskey(outaged_gens, uuid) || continue
        push!(outaged_gens[uuid], (typeof(generator), PSY.get_name(generator)))
        push!(outaged_gens[uuid][typeof(generator)],)
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
