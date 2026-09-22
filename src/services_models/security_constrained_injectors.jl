const _PER_TYPE = Dict{DataType, Set{String}}
const _OUTAGE_MAP = Dict{Int, _PER_TYPE}
# (device type, service type) => (service name, device name, outage uuid)
const _DEPLOYMENT_ENTRIES = Vector{Tuple{String, String, Int}}
const _DEPLOYMENT_MAP = Dict{Tuple{DataType, DataType}, _DEPLOYMENT_ENTRIES}

const _G1_META = "G1"

_validate_reserve_formulation(::ServiceModel) = false
_validate_reserve_formulation(
    ::ServiceModel{
        <:PSY.Reserve{PSY.ReserveUp},
        <:AbstractSecurityConstrainedReservesFormulation,
    },
) = true
_validate_reserve_formulation(
    ::ServiceModel{<:PSY.AbstractReserve, <:AbstractSecurityConstrainedReservesFormulation},
) = throw(
    IS.ConflictingInputsError(
        "Security-constrained formulations currently only support Reserve{ReserveUp}.",
    ),
)

_valid_component_type(::PSY.ACTransmission, ::NetworkModel{<:AbstractPTDFNetworkModel}) =
    true
_valid_component_type(::PSY.AreaInterchange, ::NetworkModel{AreaBalanceNetworkModel}) = true
_valid_component_type(::PSY.Component, ::NetworkModel) = false

"""
Per outage attached to a security-constrained reserve: the deployments of the devices
contributing to each reserve responding to it, the outaged generators, and the available,
modeled monitored components.

Deployments are grouped by `(device type, service type)`, the key of their containers. An
outaged generator cannot deploy reserve against its own outage, so it has no deployment entry.
"""
function _security_constrained_outages(
    sys::PSY.System,
    services_template::ServicesModelContainer,
    network_model::NetworkModel,
)
    deployments = _DEPLOYMENT_MAP()
    outaged_generators, monitored_components = _OUTAGE_MAP(), _OUTAGE_MAP()
    for model in values(services_template)
        _validate_reserve_formulation(model) || continue
        service_type = get_component_type(model)
        for (reserve_name, per_type) in get_contributing_devices_map(model)
            service = PSY.get_component(service_type, sys, reserve_name)
            for outage in PSY.get_supplemental_attributes(PSY.Outage, service)
                uuid = IS.get_id(outage)
                if !haskey(outaged_generators, uuid)
                    outaged_generators[uuid] =
                        _outaged_generators(sys, outage)
                    monitored_components[uuid] =
                        _monitored_components(sys, outage, network_model)
                end
                outaged = outaged_generators[uuid]
                for (device_type, devices) in per_type
                    skip = get(Set{String}, outaged, device_type)
                    entries = get!(
                        _DEPLOYMENT_ENTRIES,
                        deployments,
                        (device_type, typeof(service)),
                    )
                    for device in devices
                        name = PSY.get_name(device)
                        name in skip || push!(entries, (reserve_name, name, uuid))
                    end
                end
            end
        end
    end
    filter!(p -> !isempty(p.second), deployments)
    return deployments, outaged_generators, monitored_components
end

function _outaged_generators(sys::PSY.System, outage::PSY.Outage)
    outaged = _PER_TYPE()
    for generator in PSY.get_associated_components(
        sys,
        outage;
        component_type = PSY.Generator,
    )
        push!(get!(Set{String}, outaged, typeof(generator)), PSY.get_name(generator))
    end
    return outaged
end

function _monitored_components(
    sys::PSY.System,
    outage::PSY.Outage,
    network_model::NetworkModel,
)
    monitored = _PER_TYPE()
    for component_uuid in PSY.get_monitored_components(outage)
        component = IS.get_component(sys, component_uuid)
        _valid_component_type(component, network_model) || continue
        PSY.get_available(component) || continue
        typeof(component) in network_model.modeled_branch_types || continue
        push!(get!(Set{String}, monitored, typeof(component)), PSY.get_name(component))
    end
    return monitored
end

# Component type => (outage uuid, names), so each type's container is created once.
function _by_component_type(outage_map::_OUTAGE_MAP)
    grouped = Dict{DataType, Vector{Tuple{Int, Set{String}}}}()
    for (uuid, per_type) in outage_map, (component_type, names) in per_type
        push!(get!(Vector{Tuple{Int, Set{String}}}, grouped, component_type), (uuid, names))
    end
    return grouped
end

_deployment_variable(
    container::OptimizationContainer,
    ::Type{D},
    ::Type{S},
) where {D <: PSY.Component, S <: PSY.AbstractReserve} = get_variable(
    container,
    PostContingencyActivePowerReserveDeploymentVariable,
    IOM.ComponentPairKey{D, S},
)

function _create_post_contingency_reserve_variables!(
    container::OptimizationContainer,
    deployments::_DEPLOYMENT_MAP,
)
    for ((device_type, service_type), entries) in deployments
        _create_post_contingency_reserve_variables!(
            container,
            device_type,
            service_type,
            entries,
        )
    end
    return
end

function _create_post_contingency_reserve_variables!(
    container::OptimizationContainer,
    ::Type{D},
    ::Type{S},
    entries::_DEPLOYMENT_ENTRIES,
) where {D <: PSY.Component, S <: PSY.AbstractReserve}
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    var = add_variable_container!(
        container,
        PostContingencyActivePowerReserveDeploymentVariable,
        IOM.ComponentPairKey{D, S},
        String[],
        String[],
        Int[],
        time_steps;
        sparse = true,
    )
    for (reserve_name, name, uuid) in entries, t in time_steps
        var[reserve_name, name, uuid, t] = JuMP.@variable(
            jump_model,
            base_name = "PostContingencyActivePowerReserveDeploymentVariable_$(D)_$(S)_{$(reserve_name), $(name), $(uuid), $(t)}",
            lower_bound = 0.0,
        )
    end
    return
end

function _create_post_contingency_interchange_variables!(
    container::OptimizationContainer,
    monitored_components::_OUTAGE_MAP,
    ::NetworkModel{AreaBalanceNetworkModel},
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    var = add_variable_container!(
        container,
        PostContingencyAreaInterchangeFlowDeviationVariable,
        PSY.AreaInterchange,
        String[],
        Int[],
        Int[];
        sparse = true,
    )
    for (uuid, per_type) in monitored_components
        for name in get(Set{String}, per_type, PSY.AreaInterchange), t in time_steps
            var[name, uuid, t] = JuMP.@variable(
                jump_model,
                base_name = "PostContingencyAreaInterchangeFlowDeviationVariable_AreaInterchange_{$(name), $(uuid), $(t)}",
                start = 0.0,
            )
        end
    end
    return
end

_create_post_contingency_interchange_variables!(
    ::OptimizationContainer,
    ::_OUTAGE_MAP,
    ::NetworkModel,
) = nothing

# Flow constraints are shared by every reserve responding to an outage, so the service
# models carrying that outage must agree on relaxing them.
function _create_post_contingency_flow_slacks!(
    container::OptimizationContainer,
    sys::PSY.System,
    services_template::ServicesModelContainer,
    monitored_components::_OUTAGE_MAP,
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    use_slacks = Dict{Int, Bool}()
    for model in values(services_template)
        _validate_reserve_formulation(model) || continue
        service_type = get_component_type(model)
        model_slacks = get_use_slacks(model)
        for reserve_name in keys(get_contributing_devices_map(model))
            service = PSY.get_component(service_type, sys, reserve_name)
            for outage in PSY.get_supplemental_attributes(PSY.Outage, service)
                uuid = IS.get_id(outage)
                if get!(use_slacks, uuid, model_slacks) != model_slacks
                    throw(
                        IS.ConflictingInputsError(
                            "Outage $uuid is attached to security-constrained reserves \
                             with different `use_slacks` settings; set `use_slacks` \
                             consistently across their service models.",
                        ),
                    )
                end
            end
        end
    end

    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for (component_type, outages) in _by_component_type(monitored_components)
        filter!(o -> use_slacks[first(o)], outages)
        isempty(outages) && continue
        # Meta keeps these apart from the branch-side MODF slacks of the same type.
        slack_ub = add_variable_container!(
            container,
            PostContingencyFlowActivePowerSlackUpperBound,
            component_type,
            String[],
            Int[],
            time_steps;
            sparse = true,
            meta = _G1_META,
        )
        slack_lb = add_variable_container!(
            container,
            PostContingencyFlowActivePowerSlackLowerBound,
            component_type,
            String[],
            Int[],
            time_steps;
            sparse = true,
            meta = _G1_META,
        )
        for (uuid, names) in outages
            for entry_name in
                keys(_post_contingency_flow_entries(network_model, component_type, names)),
                t in time_steps

                ub = slack_ub[entry_name, uuid, t] = JuMP.@variable(
                    jump_model,
                    base_name = "PostContingencyFlowActivePowerSlackUpperBound_$(component_type)_{$(entry_name), $(uuid), $(t)}",
                    lower_bound = 0.0,
                )
                lb = slack_lb[entry_name, uuid, t] = JuMP.@variable(
                    jump_model,
                    base_name = "PostContingencyFlowActivePowerSlackLowerBound_$(component_type)_{$(entry_name), $(uuid), $(t)}",
                    lower_bound = 0.0,
                )
                add_to_objective_invariant_expression!(
                    container,
                    (ub + lb) * CONSTRAINT_VIOLATION_SLACK_COST,
                )
            end
        end
    end
    return
end

_create_post_contingency_flow_slacks!(
    ::OptimizationContainer,
    ::PSY.System,
    ::ServicesModelContainer,
    ::_OUTAGE_MAP,
    ::NetworkModel,
) = nothing

_deployment_expression_type(::NetworkModel{<:AbstractPTDFNetworkModel}) =
    PostContingencyNodalActivePowerDeployment
_deployment_expression_type(::NetworkModel{AreaBalanceNetworkModel}) =
    PostContingencyAreaActivePowerDeployment

_deployment_component_type(::NetworkModel{<:AbstractPTDFNetworkModel}) = PSY.ACBus
_deployment_component_type(::NetworkModel{AreaBalanceNetworkModel}) = PSY.Area

_location_key(component, network_model::NetworkModel{<:AbstractPTDFNetworkModel}) = string(PNM.get_mapped_bus_number(get_network_reduction(network_model), PSY.get_bus(component)))
_location_key(component, ::NetworkModel{AreaBalanceNetworkModel}) =
    PSY.get_name(PSY.get_area(PSY.get_bus(component)))

# [contributing device reserve] minus [outaged generator power] per bus or area
function _build_post_contingency_locational_power!(
    container::OptimizationContainer,
    sys::PSY.System,
    deployments::_DEPLOYMENT_MAP,
    outaged_generators::_OUTAGE_MAP,
    network_model::NetworkModel,
)
    expr = add_expression_container!(
        container,
        _deployment_expression_type(network_model),
        _deployment_component_type(network_model),
        String[],
        Int[],
        get_time_steps(container);
        sparse = true,
    )
    for ((device_type, service_type), entries) in deployments
        _add_locational_deployment!(
            expr,
            container,
            sys,
            device_type,
            service_type,
            entries,
            network_model,
        )
    end
    time_steps = get_time_steps(container)
    for (uuid, per_type) in outaged_generators
        for (generator_type, names) in per_type
            power = get_variable(container, ActivePowerVariable, generator_type)
            for name in names
                key = _location_key(
                    PSY.get_component(generator_type, sys, name),
                    network_model,
                )
                for t in time_steps
                    ex = get!(expr.data, (key, uuid, t), JuMP.AffExpr(0.0))
                    JuMP.add_to_expression!(ex, -1.0, power[name, t])
                end
            end
        end
    end
    return
end

function _add_locational_deployment!(
    expr::SparseAxisArray,
    container::OptimizationContainer,
    sys::PSY.System,
    ::Type{D},
    ::Type{S},
    entries::_DEPLOYMENT_ENTRIES,
    network_model::NetworkModel,
) where {D <: PSY.Component, S <: PSY.AbstractReserve}
    reserve = _deployment_variable(container, D, S)
    locations = Dict{String, String}()
    for (reserve_name, name, uuid) in entries
        key = get!(locations, name) do
            _location_key(PSY.get_component(D, sys, name), network_model)
        end
        for t in get_time_steps(container)
            ex = get!(expr.data, (key, uuid, t), JuMP.AffExpr(0.0))
            JuMP.add_to_expression!(ex, reserve[reserve_name, name, uuid, t])
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

    for (line_type, outages) in _by_component_type(monitored_components)
        expr = add_expression_container!(
            container,
            PostContingencyBranchFlow,
            line_type,
            String[],
            Int[],
            time_steps;
            sparse = true,
            meta = _G1_META,
        )
        pre_flow = get_expression(container, PTDFBranchFlow, line_type)
        arc_map = PNM.get_name_to_arc_map(catalog, line_type)
        # Arc distribution factors per reduced entry, keyed by the nodal bus key.
        dfs = Dict{String, Dict{String, Float64}}()
        for (uuid, names) in outages
            for entry_name in
                keys(_post_contingency_flow_entries(network_model, line_type, names))
                df = get!(dfs, entry_name) do
                    ptdf_col = ptdf[arc_map[entry_name], :]
                    Dict{String, Float64}(
                        string(bus_axis[i]) => ptdf_col[i] for
                        i in eachindex(ptdf_col) if abs(ptdf_col[i]) > PTDF_ZERO_TOL
                    )
                end
                for t in time_steps
                    ex =
                        expr[entry_name, uuid, t] = IOM.get_hinted_aff_expr(
                            length(JuMP.linear_terms(pre_flow[entry_name, t])) +
                            length(buses[uuid]),
                        )
                    JuMP.add_to_expression!(ex, pre_flow[entry_name, t])
                    for bus in buses[uuid]
                        haskey(df, bus) || continue
                        JuMP.add_to_expression!(ex, df[bus], nodal[bus, uuid, t])
                    end
                end
            end
        end
    end
    return
end

# TODO: Only monitored interchanges can take post-contingency flow, is that sensible?
function _build_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_components::_OUTAGE_MAP,
    ::NetworkModel{AreaBalanceNetworkModel},
)
    time_steps = get_time_steps(container)
    expr = add_expression_container!(
        container,
        PostContingencyAreaInterchangeFlow,
        PSY.AreaInterchange,
        String[],
        Int[],
        time_steps;
        sparse = true,
        meta = _G1_META,
    )
    flow = get_variable(container, FlowActivePowerVariable, PSY.AreaInterchange)
    deviation = get_variable(
        container,
        PostContingencyAreaInterchangeFlowDeviationVariable,
        PSY.AreaInterchange,
    )
    modeled = Set{String}(axes(flow, 1))
    for (uuid, per_type) in monitored_components
        for name in get(per_type, PSY.AreaInterchange, Set{String}())
            name in modeled || throw(
                IS.ConflictingInputsError(
                    "Monitored AreaInterchange $(name) is not modeled.",
                ),
            )
            for t in time_steps
                ex = expr[name, uuid, t]
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
    deployments::_DEPLOYMENT_MAP,
    outaged_generators::_OUTAGE_MAP,
    ::NetworkModel,
)
    uuids = collect(keys(outaged_generators))
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    cons = add_constraints_container!(
        container,
        PostContingencyGenerationBalanceConstraint,
        PSY.System,
        uuids,
        time_steps,
    )

    balance = Dict((uuid, t) => JuMP.AffExpr(0.0) for uuid in uuids, t in time_steps)
    for (uuid, per_type) in outaged_generators
        for (generator_type, names) in per_type
            power = get_variable(container, ActivePowerVariable, generator_type)
            for name in names, t in time_steps
                JuMP.add_to_expression!(balance[uuid, t], -1.0, power[name, t])
            end
        end
    end
    for ((device_type, service_type), entries) in deployments
        _add_deployment_to_balance!(balance, container, device_type, service_type, entries)
    end
    for ((uuid, t), expr) in balance
        cons[uuid, t] = JuMP.@constraint(jump_model, expr == 0.0)
    end
    return
end

function _add_deployment_to_balance!(
    balance::Dict{Tuple{Int, Int}, JuMP.AffExpr},
    container::OptimizationContainer,
    ::Type{D},
    ::Type{S},
    entries::_DEPLOYMENT_ENTRIES,
) where {D <: PSY.Component, S <: PSY.AbstractReserve}
    reserve = _deployment_variable(container, D, S)
    for (reserve_name, name, uuid) in entries, t in get_time_steps(container)
        JuMP.add_to_expression!(balance[uuid, t], reserve[reserve_name, name, uuid, t])
    end
    return
end

function _constrain_post_contingency_balance!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::_DEPLOYMENT_MAP,
    outaged_generators::_OUTAGE_MAP,
    ::NetworkModel{AreaBalanceNetworkModel},
)
    uuids = sort!(collect(keys(outaged_generators)))
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)

    # area name => (sign, interchange name)
    interchanges = Dict{String, Vector{Tuple{Float64, String}}}()
    if has_container_key(
        container,
        PostContingencyAreaInterchangeFlowDeviationVariable,
        PSY.AreaInterchange,
    )
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
            push!(
                get!(Vector{Tuple{Float64, String}}, interchanges, from_area),
                (-1.0, name),
            )
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
    for (area_name, uuid, t) in keys(deployment.data)
        balance = JuMP.AffExpr(0.0)
        JuMP.add_to_expression!(balance, deployment[area_name, uuid, t])
        for (sign, interchange_name) in get(interchanges, area_name, ())
            JuMP.add_to_expression!(balance, sign, deviation[interchange_name, uuid, t])
        end
        cons[area_name, uuid, t] = JuMP.@constraint(jump_model, balance == 0.0)
    end
    return
end

# Redundant for devices bounded by `_constrain_post_contingency_reserve!`, since their awards
# already sit in the device headroom; kept unconditional so no device can deploy past pmax.
# A device's deployments across all the reserves responding to an outage share its headroom.
function _constrain_post_contingency_generation!(
    container::OptimizationContainer,
    sys::PSY.System,
    deployments::_DEPLOYMENT_MAP,
)
    by_device_type = Dict{DataType, Vector{Tuple{DataType, _DEPLOYMENT_ENTRIES}}}()
    for ((device_type, service_type), entries) in deployments
        push!(
            get!(Vector{Tuple{DataType, _DEPLOYMENT_ENTRIES}}, by_device_type, device_type),
            (service_type, entries),
        )
    end
    for (device_type, groups) in by_device_type
        _constrain_post_contingency_generation!(container, sys, device_type, groups)
    end
    return
end

function _constrain_post_contingency_generation!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::Type{D},
    groups::Vector{Tuple{DataType, _DEPLOYMENT_ENTRIES}},
) where {D <: PSY.Component}
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    deployed = Dict{Tuple{String, Int, Int}, JuMP.AffExpr}()
    for (service_type, entries) in groups
        _sum_device_deployment!(deployed, container, D, service_type, entries)
    end
    cons = add_constraints_container!(
        container,
        PostContingencyActivePowerGenerationLimitsConstraint,
        D,
        String[],
        Int[],
        time_steps;
        sparse = true,
    )
    power = get_variable(container, ActivePowerVariable, D)
    limits = Dict{String, Float64}()
    for ((name, uuid, t), deployment) in deployed
        limit = get!(limits, name) do
            PSY.get_max_active_power(PSY.get_component(D, sys, name), PSY.SU)
        end
        cons[name, uuid, t] =
            JuMP.@constraint(jump_model, power[name, t] + deployment <= limit)
    end
    return
end

function _sum_device_deployment!(
    deployed::Dict{Tuple{String, Int, Int}, JuMP.AffExpr},
    container::OptimizationContainer,
    ::Type{D},
    ::Type{S},
    entries::_DEPLOYMENT_ENTRIES,
) where {D <: PSY.Component, S <: PSY.AbstractReserve}
    reserve = _deployment_variable(container, D, S)
    for (reserve_name, name, uuid) in entries, t in get_time_steps(container)
        ex = get!(JuMP.AffExpr, deployed, (name, uuid, t))
        JuMP.add_to_expression!(ex, reserve[reserve_name, name, uuid, t])
    end
    return
end

# Deployment can only draw on procured reserve: bounded by the device's award in the same
# reserve. Reserves without a requirement series have no meaningful award, so their deployment
# is limited by generation headroom alone.
function _constrain_post_contingency_reserve!(
    container::OptimizationContainer,
    sys::PSY.System,
    services_template::ServicesModelContainer,
    deployments::_DEPLOYMENT_MAP,
)
    ts_services = Set{Tuple{DataType, String}}()
    for model in values(services_template)
        _validate_reserve_formulation(model) || continue
        service_type = get_component_type(model)
        for reserve_name in keys(get_contributing_devices_map(model))
            service = PSY.get_component(service_type, sys, reserve_name)
            _has_ts_requirement(model, service) &&
                push!(ts_services, (typeof(service), reserve_name))
        end
    end
    for ((device_type, service_type), entries) in deployments
        limited = filter(e -> (service_type, first(e)) in ts_services, entries)
        isempty(limited) && continue
        _constrain_post_contingency_reserve!(container, device_type, service_type, limited)
    end
    return
end

function _constrain_post_contingency_reserve!(
    container::OptimizationContainer,
    ::Type{D},
    ::Type{S},
    entries::_DEPLOYMENT_ENTRIES,
) where {D <: PSY.Component, S <: PSY.AbstractReserve}
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    cons = add_constraints_container!(
        container,
        PostContingencyActivePowerReserveDeploymentVariableLimitsConstraint,
        IOM.ComponentPairKey{D, S},
        String[],
        String[],
        Int[],
        time_steps;
        sparse = true,
    )
    deployment = _deployment_variable(container, D, S)
    award = _reserve_variable(container, D, S)
    for (reserve_name, name, uuid) in entries, t in time_steps
        cons[reserve_name, name, uuid, t] = JuMP.@constraint(
            jump_model,
            deployment[reserve_name, name, uuid, t] <= award[reserve_name, name, t]
        )
    end
    return
end

_post_contingency_flow_expression(::NetworkModel{<:AbstractPTDFNetworkModel}) =
    PostContingencyBranchFlow
_post_contingency_flow_expression(::NetworkModel{AreaBalanceNetworkModel}) =
    PostContingencyAreaInterchangeFlow

# Post-contingency flow key => a representative monitored component name. Parallel
# circuits share one reduced entry, so each entry is constrained once.
function _post_contingency_flow_entries(
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
    ::Type{T},
    names::Set{String},
) where {T <: PSY.ACTransmission}
    reduction_name_map =
        PNM.get_component_to_reduction_name_map(get_branch_catalog(network_model), T)
    entries = Dict{String, String}()
    for name in names
        get!(entries, reduction_name_map[name], name)
    end
    return entries
end

_post_contingency_flow_entries(
    ::NetworkModel{AreaBalanceNetworkModel},
    ::Type{PSY.AreaInterchange},
    names::Set{String},
) = Dict{String, String}(name => name for name in names)

function _post_contingency_flow_limits(
    ::PSY.System,
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
    ::Type{T},
    name::String,
) where {T <: PSY.ACTransmission}
    catalog = get_branch_catalog(network_model)
    entry_name = PNM.get_component_to_reduction_name_map(catalog, T)[name]
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

function _constrain_post_contingency_flow!(
    container::OptimizationContainer,
    sys::PSY.System,
    monitored_components::_OUTAGE_MAP,
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for (component_type, outages) in _by_component_type(monitored_components)
        flow = get_expression(
            container,
            _post_contingency_flow_expression(network_model),
            component_type,
            _G1_META,
        )
        cons_lb = add_constraints_container!(
            container,
            PostContingencyFlowRateConstraint,
            component_type,
            String[],
            Int[],
            time_steps;
            sparse = true,
            meta = "$(_G1_META)_lb",
        )
        cons_ub = add_constraints_container!(
            container,
            PostContingencyFlowRateConstraint,
            component_type,
            String[],
            Int[],
            time_steps;
            sparse = true,
            meta = "$(_G1_META)_ub",
        )
        has_slacks = has_container_key(
            container,
            PostContingencyFlowActivePowerSlackUpperBound,
            component_type,
            _G1_META,
        )
        if has_slacks
            slack_ub = get_variable(
                container,
                PostContingencyFlowActivePowerSlackUpperBound,
                component_type,
                _G1_META,
            )
            slack_lb = get_variable(
                container,
                PostContingencyFlowActivePowerSlackLowerBound,
                component_type,
                _G1_META,
            )
        end
        for (uuid, names) in outages
            for (entry_name, name) in _post_contingency_flow_entries(network_model, component_type, names)
                lims = _post_contingency_flow_limits(sys, network_model, component_type, name)
                for t in time_steps
                    f = flow[entry_name, uuid, t]
                    if has_slacks && haskey(slack_ub.data, (entry_name, uuid, t))
                        cons_ub[entry_name, uuid, t] = JuMP.@constraint(
                            jump_model,
                            f - slack_ub[entry_name, uuid, t] <= lims.max
                        )
                        cons_lb[entry_name, uuid, t] = JuMP.@constraint(
                            jump_model,
                            f + slack_lb[entry_name, uuid, t] >= lims.min
                        )
                    else
                        cons_ub[entry_name, uuid, t] =
                            JuMP.@constraint(jump_model, f <= lims.max)
                        cons_lb[entry_name, uuid, t] =
                            JuMP.@constraint(jump_model, f >= lims.min)
                    end
                end
            end
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
