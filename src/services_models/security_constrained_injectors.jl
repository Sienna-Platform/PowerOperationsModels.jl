const _PER_TYPE = Dict{DataType, Set{String}}
const _OUTAGE_MAP = Dict{Int, _PER_TYPE}

# One outage may be tied to several reserves with overlapping contributing devices. So aggregate
# those devices across all modeled reserves
# TODO: Need to do only security constrained ones
# TODO: separate? we aggregate across services for contributing devices because services across different templates may have different contributing devices. as for outaged generators and monitored lines which are just per-outage and keep no info about the services... I think it makes sense to group them and do them at the construct_serviceS level (plural) because the constraints e.g. on the monitored lines need to only be added once per outage, but if we do it at the construct_service (singular) level, then we are setting ourselves up to do it once per service per outage... it's a convenience thing
# TODO: monitored lines?

# Keeps G-1 post-contingency flow containers apart from the N-1 ones keyed on the same
# branch type.
const _G1_META = "G1"

_validate_reserve_formulation(::ServiceModel) = false
_validate_reserve_formulation(
    ::ServiceModel{<:PSY.Reserve{PSY.ReserveUp}, <:AbstractSecurityConstrainedReservesFormulation},
) = true
_validate_reserve_formulation(
    ::ServiceModel{<:PSY.AbstractReserve, <:AbstractSecurityConstrainedReservesFormulation},
) = throw(
    IS.ConflictingInputsError(
        "Security-constrained formulations currently only support Reserve{ReserveUp}.",
    ),
)

_valid_component_type(::PSY.ACTransmission, ::NetworkModel{<:AbstractPTDFNetworkModel}) = true
_valid_component_type(::PSY.AreaInterchange, ::NetworkModel{AreaBalanceNetworkModel}) = true
_valid_component_type(::PSY.Component, ::NetworkModel) = false

# TODO move to template_validation or keep here?
# TODO: split between ptdf and area?
"""
Per outage attached to a security-constrained reserve: the devices contributing to any
reserve responding to it, the outaged generators, and
the available, modeled monitored components.

Contributing devices are aggregated across services because one outage may be tied to
reserves with different contributing devices and different service models.
"""
function _security_constrained_outages(
    sys::PSY.System,
    services_template::ServicesModelContainer,
    network_model::NetworkModel,
)
    contributing_devices = _OUTAGE_MAP()
    outaged_generators = _OUTAGE_MAP()
    monitored_components = _OUTAGE_MAP()
    modeled_types = network_model.modeled_branch_types
    for model in values(services_template)
        _validate_reserve_formulation(model) || continue
        service_type = get_component_type(model)
        # TODO: validate that its nonempty?
        for (service_name, per_type) in get_contributing_devices_map(model)
            service = PSY.get_component(service_type, sys, service_name)
            for outage in PSY.get_supplemental_attributes(PSY.Outage, service)
                uuid = IS.get_id(outage)
                devices = get!(_PER_TYPE, contributing_devices, uuid)
                for (device_type, ds) in per_type
                    union!(get!(Set{String}, devices, device_type), PSY.get_name.(ds))
                end

                haskey(outaged_generators, uuid) && continue
                outaged = outaged_generators[uuid] = _PER_TYPE()
                for generator in PSY.get_associated_components(
                    sys,
                    outage;
                    component_type = PSY.Generator,
                )
                    push!(get!(Set{String}, outaged, typeof(generator)), PSY.get_name(generator))
                end

                monitored = monitored_components[uuid] = _PER_TYPE()
                for component_uuid in PSY.get_monitored_components(outage)
                    component = IS.get_component(sys, component_uuid)
                    _valid_component_type(component, network_model) || continue
                    PSY.get_available(component) || continue
                    typeof(component) in modeled_types || continue
                    push!(
                        get!(Set{String}, monitored, typeof(component)),
                        PSY.get_name(component),
                    )
                end
            end
        end
    end
    return contributing_devices, outaged_generators, monitored_components
end

function _create_post_contingency_reserve_variables!(
    container::OptimizationContainer,
    contributing_devices::_OUTAGE_MAP,
    outaged_generators::_OUTAGE_MAP,
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for (uuid, per_type) in contributing_devices
        for (device_type, names) in per_type
            var = lazy_container_addition!(
                container,
                PostContingencyActivePowerReserveDeploymentVariable,
                device_type,
                String[],
                Int[],
                Int[];
                sparse = true,
            )
            outaged = get(outaged_generators[uuid], device_type, Set{String}())
            for name in names
                name in outaged && continue
                for t in time_steps
                    # TODO bounds? start?
                    var[name, uuid, t] = JuMP.@variable(
                        jump_model,
                        base_name = "PostContingencyActivePowerReserveDeploymentVariable_$(device_type)_{$(name), $(uuid), $(t)}",
                        lower_bound = 0.0,
                    )
                end
            end
        end
    end
    return
end

function _modeled_interchange_names(container::OptimizationContainer)
    if !has_container_key(container, FlowActivePowerVariable, PSY.AreaInterchange)
        @warn "An AreaBalanceNetworkModel with security-constrained reserves needs PSY.AreaInterchange(s) and DeviceModel{PSY.AreaInterchange} for reserve deployment to cross area boundaries. Otherwise, each area must cover its own outages." _group =
            LOG_GROUP_SERVICE_CONSTUCTORS maxlog = 1
        String[]
    else
        var = get_variable(container, FlowActivePowerVariable, PSY.AreaInterchange)
        collect(axes(var, 1))
    end
end

# Runs in the ModelConstructStage: the AreaInterchange flow variables are created in the
# branch ArgumentConstructStage, which runs after the services one.
function _create_post_contingency_interchange_variables!(
    container::OptimizationContainer,
    uuids::Vector{Int},
    ::NetworkModel{AreaBalanceNetworkModel},
)
    names = _modeled_interchange_names(container)
    (isempty(names) || isempty(uuids)) && return

    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    var = add_variable_container!(
        container,
        PostContingencyAreaInterchangeFlowDeviationVariable,
        PSY.AreaInterchange,
        names,
        uuids,
        time_steps,
    )
    for name in names, uuid in uuids, t in time_steps
        var[name, uuid, t] = JuMP.@variable(
            jump_model,
            base_name = "PostContingencyAreaInterchangeFlowDeviationVariable_AreaInterchange_{$(name), $(uuid), $(t)}",
            start = 0.0,
        )
    end
    return
end

_create_post_contingency_interchange_variables!(
    ::OptimizationContainer,
    ::Vector{Int},
    ::NetworkModel,
) = nothing

_deployment_expression(::NetworkModel{<:AbstractPTDFNetworkModel}) = PostContingencyNodalActivePowerDeployment
_deployment_expression(::NetworkModel{AreaBalanceNetworkModel}) = PostContingencyAreaActivePowerDeployment

_location_key(component, network_model::NetworkModel{<:AbstractPTDFNetworkModel}) = string(PNM.get_mapped_bus_number(network_reduction, PSY.get_bus(component)))
# TODO are there reductions on area models?
_location_key(component, ::NetworkModel{AreaBalanceNetworkModel}) = PSY.get_name(PSY.get_area(PSY.get_bus(component)))

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

# Monitored names resolve to their reduction entry, the row the pre-contingency
# `PTDFBranchFlow` and the post-contingency expression are keyed by.
function _build_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_components::_OUTAGE_MAP,
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
)
    time_steps = get_time_steps(container)
    catalog = get_branch_catalog(network_model)
    ptdf = get_network_matrix(network_model)
    bus_axis = PNM.get_bus_axis(ptdf)

    nodal = get_expression(container, PostContingencyNodalActivePowerDeployment, PSY.ACBus)
    buses = Dict{Int, Vector{String}}()
    for (bus, uuid, t) in keys(nodal.data)
        t == first(time_steps) && push!(get!(Vector{String}, buses, uuid), bus)
    end

    # Signed distribution factors per monitored branch, keyed by the nodal bus key.
    dfs = Dict{Tuple{DataType, String}, Dict{String, Float64}}()
    for (uuid, per_type) in monitored_components
        outage_buses = get(buses, uuid, String[])
        for (line_type, names) in per_type
            expr = lazy_container_addition!(
                container,
                PostContingencyBranchFlow,
                line_type,
                String[],
                Int[],
                Int[];
                sparse = true,
                meta = _G1_META,
            )
            # TODO is pre_flow needed when nodal already considers active power?
            pre_flow = get_expression(container, PTDFBranchFlow, line_type)
            arc_map = PNM.get_name_to_arc_map(catalog, line_type)
            reduction_name_map = PNM.get_component_to_reduction_name_map(catalog, line_type)
            for name in names
                entry_name = haskey(arc_map, name) ? name : reduction_name_map[name]
                # Build distribution factor cache (if needed)
                df = get!(dfs, (line_type, name)) do
                    ptdf_col = ptdf[arc_map[entry_name], :]
                    sign = get_ptdf_orientation_sign(catalog, line_type, name)
                    # TODO: am I indexing the bus correctly?
                    Dict{String, Float64}(
                        string(bus_axis[i]) => sign * ptdf_col[i] for
                        i in eachindex(ptdf_col) if abs(ptdf_col[i]) > PTDF_ZERO_TOL
                    )
                end
                for t in time_steps
                    ex = expr[entry_name, uuid, t] = JuMP.AffExpr(0.0)
                    JuMP.add_to_expression!(ex, pre_flow[entry_name, t])
                    for bus in outage_buses
                        haskey(df, bus) || continue
                        JuMP.add_to_expression!(ex, df[bus], nodal[bus, uuid, t])
                    end
                end
            end
        end
    end
    return
end

function _build_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_components::_OUTAGE_MAP,
    ::NetworkModel{AreaBalanceNetworkModel},
)
    has_container_key(
        container,
        PostContingencyAreaInterchangeFlowDeviationVariable,
        PSY.AreaInterchange,
    ) || return
    time_steps = get_time_steps(container)
    flow = get_variable(container, FlowActivePowerVariable, PSY.AreaInterchange)
    deviation = get_variable(
        container,
        PostContingencyAreaInterchangeFlowDeviationVariable,
        PSY.AreaInterchange,
    )
    modeled = Set{String}(axes(deviation, 1))
    expr = add_expression_container!(
        container,
        PostContingencyAreaInterchangeFlow,
        PSY.AreaInterchange,
        String[],
        Int[],
        Int[];
        sparse = true,
        meta = _G1_META,
    )
    for (uuid, per_type) in monitored_components
        for name in get(per_type, PSY.AreaInterchange, Set{String}())
            name in modeled || throw(
                IS.ConflictingInputsError(
                    "Monitored AreaInterchange $(name) has no modeled flow; it is excluded by the AreaInterchange DeviceModel's filter_function.",
                ),
            )
            for t in time_steps
                ex = expr[name, uuid, t] = JuMP.AffExpr(0.0)
                JuMP.add_to_expression!(ex, flow[name, t])
                JuMP.add_to_expression!(ex, deviation[name, uuid, t])
            end
        end
    end
    return
end

_build_post_contingency_flow!(::OptimizationContainer, ::_OUTAGE_MAP, ::NetworkModel) =
    nothing

function _constrain_post_contingency_balance!(
    container::OptimizationContainer,
    ::PSY.System,
    contributing_devices::_OUTAGE_MAP,
    outaged_generators::_OUTAGE_MAP,
    ::NetworkModel,
)
    uuids = sort!(collect(keys(contributing_devices)))
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    cons = add_constraints_container!(
        container,
        PostContingencyGenerationBalanceConstraint,
        PSY.System,
        uuids,
        time_steps,
    )

    for uuid in uuids, t in time_steps
        balance = JuMP.AffExpr(0.0)
        for (generator_type, names) in outaged_generators[uuid]
            power = get_variable(container, ActivePowerVariable, generator_type)
            for name in names
                JuMP.add_to_expression!(balance, -1.0, power[name, t])
            end
        end
        for (device_type, names) in contributing_devices[uuid]
            reserve = get_variable(
                container,
                PostContingencyActivePowerReserveDeploymentVariable,
                device_type,
            )
            outaged = get(outaged_generators[uuid], device_type, Set{String}())
            for name in names
                name in outaged && continue
                JuMP.add_to_expression!(balance, reserve[name, uuid, t])
            end
        end

        cons[uuid, t] = JuMP.@constraint(jump_model, balance == 0.0)
    end
    return
end

# TODO Why does each area listen to every outage? but not every bus?
function _constrain_post_contingency_balance!(
    container::OptimizationContainer,
    sys::PSY.System,
    contributing_devices::_OUTAGE_MAP,
    ::_OUTAGE_MAP,
    ::NetworkModel{AreaBalanceNetworkModel},
)
    uuids = sort!(collect(keys(contributing_devices)))
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)

    # Area name => (sign, interchange name); flow leaving an area counts against it.
    interchanges = Dict{String, Vector{Tuple{Float64, String}}}()
    has_deviation = has_container_key(
        container,
        PostContingencyAreaInterchangeFlowDeviationVariable,
        PSY.AreaInterchange,
    )
    if has_deviation
        deviation = get_variable(
            container,
            PostContingencyAreaInterchangeFlowDeviationVariable,
            PSY.AreaInterchange,
        )
        modeled = Set{String}(axes(deviation, 1))
        for interchange in PSY.get_components(PSY.AreaInterchange, sys)
            name = PSY.get_name(interchange)
            name in modeled || continue
            from_area = PSY.get_name(PSY.get_from_area(interchange))
            to_area = PSY.get_name(PSY.get_to_area(interchange))
            push!(get!(Vector{Tuple{Float64, String}}, interchanges, from_area), (-1.0, name))
            push!(get!(Vector{Tuple{Float64, String}}, interchanges, to_area), (1.0, name))
        end
    end
    deployment =
        get_expression(container, PostContingencyAreaActivePowerDeployment, PSY.Area)

    area_names = PSY.get_name.(PSY.get_components(PSY.Area, sys))
    cons = add_constraints_container!(
        container,
        PostContingencyGenerationBalanceConstraint,
        PSY.Area,
        area_names,
        uuids,
        time_steps,
    )
    for area_name in area_names, uuid in uuids, t in time_steps
        balance = JuMP.AffExpr(0.0)
        if haskey(deployment.data, (area_name, uuid, t))
            JuMP.add_to_expression!(balance, deployment[area_name, uuid, t])
        end
        for (sign, interchange_name) in get(interchanges, area_name, ())
            JuMP.add_to_expression!(balance, sign, deviation[interchange_name, uuid, t])
        end
        cons[area_name, uuid, t] = JuMP.@constraint(jump_model, balance == 0.0)
    end
    return
end

function _constrain_post_contingency_generation!(
    container::OptimizationContainer,
    sys::PSY.System,
    outaged_generators::_OUTAGE_MAP,
    contributing_devices::_OUTAGE_MAP,
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for (uuid, per_type) in contributing_devices
        for (device_type, names) in per_type
            cons = lazy_container_addition!(
                container,
                PostContingencyActivePowerGenerationLimitsConstraint,
                device_type,
                String[],
                Int[],
                Int[];
                sparse = true,
            )
            power = get_variable(container, ActivePowerVariable, device_type)
            reserve = get_variable(
                container,
                PostContingencyActivePowerReserveDeploymentVariable,
                device_type,
            )
            outaged = get(outaged_generators[uuid], device_type, Set{String}())
            for name in names
                name in outaged && continue
                limit = PSY.get_max_active_power(
                    PSY.get_component(device_type, sys, name),
                    PSY.SU,
                )
                for t in time_steps
                    cons[name, uuid, t] = JuMP.@constraint(
                        jump_model,
                        power[name, t] + reserve[name, uuid, t] <= limit
                    )
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


_post_contingency_flow_expression(::NetworkModel{<:AbstractPTDFNetworkModel}) =
    PostContingencyBranchFlow
_post_contingency_flow_expression(::NetworkModel{AreaBalanceNetworkModel}) =
    PostContingencyAreaInterchangeFlow

function _post_contingency_flow_limits(
    ::PSY.System,
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
    ::Type{T},
    entry_name::String,
) where {T <: PSY.ACTransmission}
    catalog = get_branch_catalog(network_model)
    arc = PNM.get_name_to_arc_map(catalog, T)[entry_name]
    return _emergency_flow_limits(PNM.get_reduction_entry(catalog, arc))
end

function _post_contingency_flow_limits(
    sys::PSY.System,
    ::NetworkModel{AreaBalanceNetworkModel},
    ::Type{PSY.AreaInterchange},
    name::String,
)
    limits = PSY.get_flow_limits(PSY.get_component(PSY.AreaInterchange, sys, name), PSY.SU)
    return (min = -limits.to_from, max = limits.from_to)
end

# TODO Why do we support area interchanges here but not on N-1?
# TODO refactor with add_constraints!(PostContingencyFlowRate, ACTransmission) from N-1?
# TODO I think we don't need to check for shared sources because we're creating at the create_services level
# TODO: slacks?
function _constrain_post_contingency_flow!(
    container::OptimizationContainer,
    sys::PSY.System,
    monitored_components::_OUTAGE_MAP,
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    jump_model = get_jump_model(container)
    expression_type = _post_contingency_flow_expression(network_model)
    component_types = Set{DataType}()
    for per_type in values(monitored_components)
        union!(component_types, keys(per_type))
    end
    for component_type in component_types
        has_container_key(container, expression_type, component_type, _G1_META) ||
            continue
        flow = get_expression(container, expression_type, component_type, _G1_META)
        cons_lb = add_constraints_container!(
            container,
            PostContingencyFlowRateConstraint,
            component_type,
            String[],
            Int[],
            Int[];
            sparse = true,
            meta = "$(_G1_META)_lb",
        )
        cons_ub = add_constraints_container!(
            container,
            PostContingencyFlowRateConstraint,
            component_type,
            String[],
            Int[],
            Int[];
            sparse = true,
            meta = "$(_G1_META)_ub",
        )
        limits = Dict{String, NamedTuple{(:min, :max), Tuple{Float64, Float64}}}()
        for (name, uuid, t) in keys(flow.data)
            lims = get!(limits, name) do
                _post_contingency_flow_limits(sys, network_model, component_type, name)
            end
            cons_ub[name, uuid, t] =
                JuMP.@constraint(jump_model, flow[name, uuid, t] <= lims.max)
            cons_lb[name, uuid, t] =
                JuMP.@constraint(jump_model, flow[name, uuid, t] >= lims.min)
        end
    end
    return
end

_constrain_post_contingency_flow!(
    ::OptimizationContainer,
    ::PSY.System,
    ::_OUTAGE_MAP,
    ::NetworkModel,
) = nothing
