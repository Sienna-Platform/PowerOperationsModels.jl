const _PER_TYPE = Dict{DataType, Set{String}}
const _OUTAGE_MAP = Dict{Int, _PER_TYPE}

# One outage may be tied to several reserves with overlapping contributing devices. So aggregate
# those devices across all modeled reserves
# TODO: Need to do only security constrained ones
# TODO: separate? we aggregate across services for contributing devices because services across different templates may have different contributing devices. as for outaged generators and monitored lines which are just per-outage and keep no info about the services... I think it makes sense to group them and do them at the construct_serviceS level (plural) because the constraints e.g. on the monitored lines need to only be added once per outage, but if we do it at the construct_service (singular) level, then we are setting ourselves up to do it once per service per outage... it's a convenience thing
# TODO: monitored lines?

"""
Collect all devices contributing to security-constrained reserves.
We perform this aggregation because an outage may be tied to reserves with different contributing
devices and different service models.
"""
function _security_constrained_contributing_devices(sys::PSY.System, services_template::ServicesModelContainer)
    uuids = Set{Int}()
    contributing_devices = _OUTAGE_MAP()
    for model in values(services_template)
        get_formulation(model) <: AbstractSecurityConstrainedReservesFormulation || continue
        for uuid in keys(get_outages(model)), device in get_contributing_devices(model)
            per_type = get!(contributing_devices, uuid, _PER_TYPE())
            c = get!(per_type, typeof(device), Set{String}())
            push!(c, PSY.get_name(device))
            push!(uuids, uuid)
        end
    end
    return contributing_devices
end

function _outaged_generators(sys::PSY.System, uuids::Set{Int})
    outaged_generators = _OUTAGE_MAP(uuid => Dict{DataType, Set{String}}() for uuid in uuids)
    for (generator, outage) in PSY.get_component_supplemental_attribute_pairs(PSY.Generator, PSY.Outage, sys)
        uuid = IS.get_uuid(outage)
        uuid in uuids || continue
        c = get!(outaged_generators[uuid], typeof(generator), Set{String}())
        push!(c, PSY.get_name(generator))
    end
    return outaged_generators
end

_validate_reserve_formulation(::ServiceModel{<:PSY.AbstractReserve{PSY.ReserveUp}, AbstractSecurityConstrainedReservesFormulation}) = true
_validate_reserve_formulation(::ServiceModel) = false
_validate_reserve_formulation(::ServiceModel{<:PSY.AbstractReserve, AbstractSecurityConstrainedReservesFormulation}) = throw(IS.ConflictingInputsError("Security-constrained formulations currently only support ReserveUp.")

# TODO move to template_validation or keep here?
# TODO: split between ptdf and area?
function _monitored_components(sys::PSY.System, services_template::ServicesModelContainer)
    components = _OUTAGE_MAP()
    for model in service_models
        _validate_reserve_formulation(model) || continue
        # TODO: validate that its nonempty?
        for service in get_available_components(sys, model)
            for outage in PSY.get_supplemental_attributes(PSY.Outage, service)
                outage_uuid = IS.get_uuid(outage)
                per_type = PER_TYPE()
                for component_uuid in PSY.get_monitored_components(outage)
                    component = IS.get_component(sys, component_uuid)
                    names = get!(per_type, typeof(component), Set{String})
                    push!(names, PSY.get_name(component))
                end
                components[outage_uuid] = per_type
            end
        end
    end
    return components
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

function _modeled_interchange_names(container::OptimizationContainer)
    if !has_container_key(container, FlowActivePowerVariable, PSY.AreaInterchange)
        @warn "An AreaBalancePowerModel with security-constrained reserves needs PSY.AreaInterchange(s) and DeviceModel{PSY.AreaInterchange} for reserve deployment to cross area boundaries. Otherwise, each area must cover its own outages." _group = LOG_GROUP_SERVICE_CONSTUCTORS maxlog = 1
        String[]
    else
        var = get_variable(container, FlowActivePowerVariable, PSY.AreaInterchange)
        collect(axes(var, 1))
    end
end

function _create_post_contingency_interchange_variables!(
    container::OptimizationContainer,
    uuids::Vector{Int},
    ::NetworkModel{AreaBalancePowerModel},
)
    names = _modeled_interchange_names(container)
    isempty(names) && return

    time_steps = get_time_steps(container)
    var = add_variable_container!(container, PostContingencyAreaInterchangeFlowDeviationVariable, PSY.AreaInterchange, names, uuids, time_steps)
    for name in names, uuid in uuids, t in time_steps
        var[name, uuid, t] = JuMP.@variable(jump_model, base_name = "PostContignencyAreaInterchangeFlowDeviationVariable_AreaInterchange_{$(name), $(uuid), $(t)}", start = 0.0)
    end
end

_create_post_contingency_interchange_variables(::OptimizationContainer, ::Vector, ::NetworkModel) = nothing

_deployment_expression(::NetworkModel{<:AbstractPTDFNetworkModel}) = PostContingencyNodalActivePowerDeployment
_deployment_expression(::NetworkModel{AreaBalancePowerModel}) = PostContingencyAreaActivePowerDeployment

_location_key(component, network_model::NetworkModel{<:AbstractPTDFNetworkModel}) = string(PNM.get_mapped_bus_number(network_reduction, PSY.get_bus(component)))
# TODO are there reductions on area models?
_location_key(component, ::NetworkModel{AreaBalancePowerModel}) = PSY.get_name(PSY.get_area(PSY.get_bus(component)))

# TODO: What about outaged gens? Subtract their power on the node?
function _build_post_contingency_locational_power!(
    container::OptimizationContainer,
    sys::PSY.System,
    contributing_devices::_OUTAGE_MAP,
    outaged_gens::_OUTAGE_MAP,
    network_model::NetworkModel
)
    jump_model = get_jump_model(container)
    for (uuid, per_type) in contributing_devices
        for (device_type, names) in per_type
            expr = lazy_add_container(container, _deployment_expression(network_model), PSY.ACBus, String[], Int[], Int[]; sparse = true)
            power = get_variable(container, ActivePowerReserveVariable, device_type)
            reserve = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, device_type)
            for name in names
                (device_type, name) in outaged_gens[uuid] && continue
                bus = PNM.get_mapped_bus_number(network_reduction, PSY.get_bus(PSY.get_component(device_type, sys, name)))
                key = _location_key(PSY.get_component(device_type, sys, name), network_model)
                for t in time_steps
                    ex = expr[key, uuid, t] = JuMP.AffExpr(0.0)
                    JuMP.add_to_expression!(ex, power[name, t])
                    JuMP.add_to_expression!(ex, reserve[name, t])
                end
            end
        end
    end
    return
end

function _build_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_lines::_OUTAGE_MAP,
    ::NetworkModel{<:AbstractPTDFNetworkModel}
)
    catalog = get_branch_catalog(network_model)
    reduction_name_map = PNM.get_component_to_reduction_name_map(catalog, M)
    name_to_arc_map = PNM.get_name_to_arc_map(catalog, M)

    ptdf = get_PTDF_matrix(network_model)
    bus_axis = PNM.get_bus_axis(ptdf)

    nodal = get_expression(container, PostContingencyNodalActivePowerDeployment, PSY.ACBus)

    dfs = Dict{String, Vector{Float64}}()
    for (uuid, per_type) in monitored_lines
        for (line_type, names) in per_type
            expr = lazy_add_container!(container, PostContingencyBranchFlow, line_type, String[], Int[], Int[]; sparse = true)
            # TODO is pre_flow needed when nodal already considers active power?
            pre_flow = get_expression(container, PTDFBranchFlow, line_type)

            # Build distribution factor cache (if needed)
            for name in names
                (line_type, name) in dfs && continue
                arc = name_to_arc_map[reduction_name_map[name]]
                ptdf_col = ptdf[arc, :]
                sign = get_ptdf_orientation_sign(catalog, line_type, name)
                for bus in buses
                    # TODO: am I indexing the bus correctly?
                    df = sign * ptdf_col[bus_axis[bus]]
                    abs(df) < PTDF_ZERO_TOL && continue
                    push!(dfs[name], df)
                end
            end

            for name in names, t in time_steps
                ex = expr[name, uuid, t] = JuMP.AffExpr(0.0)
                JuMP.add_to_expression!(ex, pre_flow)
                for bus in buses
                    JuMP.add_to_expression!(ex, dfs[name][bus], nodal[bus, uuid, t])
                end
            end
        end
    end
    return
end

function _build_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_interchanges::_OUTAGE_MAP,
    ::NetworkModel{AreaBalancePowerModel},
)
    expr = add_expression_container!(container, PostContingencyAreaInterchangeFlow, PSY.AreaInterchange, String[], Int[], Int[]; sparse = true)
    flow = get_variable(container, FlowActivePowerVariable, PSY.AreaInterchange)
    deviation = get_variable(container, PostContingencyAreaInterchangeFlowDeviationVariable, PSY.AreaInterchange)
    for (uuid, per_type) in monitored_interchanges
        for name in per_type[PSY.AreaInterchange], t in time_steps
            ex = expr[name, uuid, t] = JuMP.AffExpr(0.0)
            JuMP.add_to_expression!(ex, flow[name, t])
            JuMP.add_to_expression!(ex, deviation[name, uuid, t])
        end
    end
    return
end

function _constrain_post_contingency_balance!(
    container::OptimizationContainer,
    contributing_devices::_OUTAGE_MAP,
    outaged_generators::_OUTAGE_MAP,
    ::NetworkModel,
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

# TODO Why does each area listen to every outage? but not every bus?
function _constrain_post_contingency_balance!(
    container::OptimizationContainer,
    contributing_devices::_OUTAGE_MAP,
    outaged_generators::_OUTAGE_MAP,
    ::NetworkModel{AreaBalancePowerModel},
)
    interchanges = Dict{String, Vector{Tuple{Float64, String}}}()
    for interchange in PSY.get_components(PSY.AreaInterchange, sys)
        name = PYS.get_name(interchange)
        name in modeled_interchange_areas || continue
        push!(get!(interchanges, PSY.get_name(PSY.get_from_area(interchange)), Vector{Tuple{Float64, String}}()), (-1.0, name))
        push!(get!(interchanges, PSY.get_name(PSY.get_to_area(interchange)), Vector{Tuple{Float64, String}}()), (1.0, name))
    end
    deployment = get_expression(container, PostContingencyAreaActivePowerDeployment, PSY.Area)

    for area_name in names
        exchange = JuMP.AffExpr(0.0)
        for (sign, interchange_name) in interchanges[area_name]
            JuMP.add_to_expression!(exchange, sign, deviation[interchange_name, uuid, t])
        end
        JuMP.@constraint(jump_model, deployment[area_name, uuid, t] + exchange == 0.0)
    end
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
            reserve = get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, device_type)
            for name in names
                (device_type, name) in outaged_gens[uuid] && continue
                limit = PSY.get_max_active_power(PSY.get_component(device_type, sys, name))
                for t in time_steps
                    cons[name, uuid, t] = JuMP.@constraint(jump_model, power[name, t] + reserve[name, t] <= limit)
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
            # TODO: shorter name
            cons = lazy_add_container!(container, PostContingencyActivePowerReserveDeploymentVariableLimitsConstraint, device_type, String[], Int[], Int[]; sparse = true)
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

# TODO Why do we support area interchanges here but not on N-1?
# TODO refactor with add_constraints!(PostContingencyFlowRate, ACTransmission) from N-1?
# TODO I think we don't need to check for shared sources because we're creating at the create_services level
function _constrain_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_components::_OUTAGE_MAP,
    network_model::NetworkModel{Union{AbstractPTDFNetworkModel, AreaBalancePowerModel}},
)
    for (uuid, per_type) in monitored_components
        for (component_type, names) in per_type
            limits = _flow_limits(network_model)
            # TODO: slacks?
            for name in names, t in time_steps
                cons_ub[name, uuid, t] = JuMP.@constraint(jump_model, flow[name, uuid, t] <= limits.max)
                cons_lb[name, uuid, t] = JuMP.@constraint(jump_model, flow[name, uuid, t] >= limits.min)
            end
        end
    end
    return
end

_constrain_post_contingency_flow!(::OptimizationContainer, ::_OUTAGE_MAP, ::NetworkModel) = nothing

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
    outaged_gens = _OUTAGE_MAP(uuid => PER_TYPE() for uuid in uuids)
    for (generator, outage) in generator_outage_pairs
        haskey(outaged_gens, uuid) || continue
        push!(outaged_gens[uuid][typeof(generator)], PSY,get_name(generator))
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
