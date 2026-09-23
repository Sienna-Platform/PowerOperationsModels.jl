const _PER_TYPE = Dict{DataType, Set{String}}
const _OUTAGE_MAP = Dict{Int, _PER_TYPE}

const _G1_META = "G1"

_validate_reserve_formulation(::ServiceModel) = false
_validate_reserve_formulation(
    ::ServiceModel{
        <:_SECURITY_CONSTRAINED_RESERVE,
        <:AbstractSecurityConstrainedReservesFormulation,
    },
) = true
_validate_reserve_formulation(
    ::ServiceModel{<:PSY.AbstractReserve, <:AbstractSecurityConstrainedReservesFormulation},
) = throw(
    IS.ConflictingInputsError(
        "Security-constrained formulations currently only support reserve-up services.",
    ),
)

_valid_component_type(::PSY.ACTransmission, ::NetworkModel{<:AbstractPTDFNetworkModel}) =
    true
_valid_component_type(::PSY.AreaInterchange, ::NetworkModel{AreaBalanceNetworkModel}) = true
_valid_component_type(::PSY.Component, ::NetworkModel) = false

function _outaged_generators(sys::PSY.System, outage::PSY.Outage)
    outaged = _PER_TYPE()
    for generator in
        PSY.get_associated_components(sys, outage; component_type = PSY.Generator)
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

"""
Per outage attached to a security-constrained reserve: the outaged generators, the available,
modeled monitored components, and whether its post-contingency flow limits are relaxed.

Flow constraints are shared by every reserve responding to an outage, so the service models
carrying that outage must agree on `use_slacks`.
"""
function _security_constrained_outages(
    sys::PSY.System,
    services_template::ServicesModelContainer,
    network_model::NetworkModel,
)
    outaged_generators, monitored_components = _OUTAGE_MAP(), _OUTAGE_MAP()
    use_slacks = Dict{Int, Bool}()
    for model in values(services_template)
        _validate_reserve_formulation(model) || continue
        model_slacks = get_use_slacks(model)
        for service in _services_with_contributors(model, sys)
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
                haskey(outaged_generators, uuid) && continue
                outaged_generators[uuid] = _outaged_generators(sys, outage)
                monitored_components[uuid] =
                    _monitored_components(sys, outage, network_model)
            end
        end
    end
    return outaged_generators, monitored_components, use_slacks
end

# Each service deploys its own contributors under every outage it responds to; the per-device
# sum across services is what the outage-level constraints see.
function _add_post_contingency_deployment!(
    container::OptimizationContainer,
    sys::PSY.System,
    service::R,
    model::ServiceModel{R, <:AbstractSecurityConstrainedReservesFormulation},
) where {R <: _SECURITY_CONSTRAINED_RESERVE}
    per_type = get_contributing_devices_map(model, PSY.get_name(service))
    for outage in PSY.get_supplemental_attributes(PSY.Outage, service)
        uuid = IS.get_id(outage)
        outaged = _outaged_generators(sys, outage)
        for (device_type, devices) in per_type
            _add_post_contingency_deployment!(
                container,
                service,
                devices,
                uuid,
                get(Set{String}, outaged, device_type),
            )
        end
    end
    return
end

function _add_post_contingency_deployment!(
    container::OptimizationContainer,
    service::R,
    devices::Vector{D},
    uuid::Int,
    outaged::Set{String},
) where {R <: PSY.Service, D <: PSY.Component}
    jump_model = get_jump_model(container)
    service_name = PSY.get_name(service)
    deployment = lazy_container_addition!(
        container,
        PostContingencyActivePowerReserveDeploymentVariable,
        IOM.ComponentPairKey{D, R},
        String[],
        String[],
        Int[],
        Int[];
        sparse = true,
    )
    total = lazy_container_addition!(
        container,
        PostContingencyTotalReserveDeployment,
        D,
        String[],
        Int[],
        Int[];
        sparse = true,
    )
    for d in devices
        name = PSY.get_name(d)
        name in outaged && continue
        for t in get_time_steps(container)
            var =
                deployment[service_name, name, uuid, t] = JuMP.@variable(
                    jump_model,
                    base_name = "PostContingencyActivePowerReserveDeploymentVariable_$(D)_$(R)_{$(service_name), $(name), $(uuid), $(t)}",
                    lower_bound = 0.0,
                )
            JuMP.add_to_expression!(get!(JuMP.AffExpr, total.data, (name, uuid, t)), var)
        end
    end
    return
end

_total_deployments(container::OptimizationContainer) = [
    (get_component_type(key), expr) for
    (key, expr) in IOM.get_expressions(container) if
    IOM.get_entry_type(key) === PostContingencyTotalReserveDeployment
]

# Deployment can only draw on procured reserve. Unprocured reserves are limited by
# generation headroom alone.
function _constrain_post_contingency_reserve!(
    container::OptimizationContainer,
    service::R,
    model::ServiceModel{R, <:AbstractSecurityConstrainedReservesFormulation},
) where {R <: _SECURITY_CONSTRAINED_RESERVE}
    for device_type in keys(get_contributing_devices_map(model, PSY.get_name(service)))
        _constrain_post_contingency_reserve!(container, service, device_type)
    end
    return
end

function _constrain_post_contingency_reserve!(
    container::OptimizationContainer,
    service::R,
    ::Type{D},
) where {R <: PSY.Service, D <: PSY.Component}
    key = IOM.ComponentPairKey{D, R}
    has_container_key(
        container,
        PostContingencyActivePowerReserveDeploymentVariable,
        key,
    ) ||
        return
    jump_model = get_jump_model(container)
    service_name = PSY.get_name(service)
    deployment =
        get_variable(container, PostContingencyActivePowerReserveDeploymentVariable, key)
    award = get_variable(container, ActivePowerReserveVariable, key)
    cons = lazy_container_addition!(
        container,
        PostContingencyActivePowerReserveDeploymentVariableLimitsConstraint,
        key,
        String[],
        String[],
        Int[],
        Int[];
        sparse = true,
    )
    for ((s, name, uuid, t), r) in deployment.data
        s == service_name || continue
        cons[s, name, uuid, t] =
            JuMP.@constraint(jump_model, r <= award[service_name, name, t])
    end
    return
end

function _create_post_contingency_interchange_variables!(
    container::OptimizationContainer,
    outaged_generators::_OUTAGE_MAP,
    ::NetworkModel{AreaBalanceNetworkModel},
)
    has_container_key(container, FlowActivePowerVariable, PSY.AreaInterchange) || return
    flow = get_variable(container, FlowActivePowerVariable, PSY.AreaInterchange)
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
    for uuid in keys(outaged_generators), name in axes(flow, 1), t in time_steps
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
    ::_OUTAGE_MAP,
    ::NetworkModel,
) = nothing

function _create_post_contingency_flow_slacks!(
    container::OptimizationContainer,
    monitored_components::_OUTAGE_MAP,
    use_slacks::Dict{Int, Bool},
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for (uuid, per_type) in monitored_components
        use_slacks[uuid] || continue
        for (component_type, names) in per_type
            slack_ub = lazy_container_addition!(
                container,
                PostGeneratorContingencyFlowActivePowerSlackUpperBound,
                component_type,
                String[],
                Int[],
                Int[];
                sparse = true,
            )
            slack_lb = lazy_container_addition!(
                container,
                PostGeneratorContingencyFlowActivePowerSlackLowerBound,
                component_type,
                String[],
                Int[],
                Int[];
                sparse = true,
            )
            for entry_name in _flow_entries(network_model, component_type, names),
                t in time_steps

                ub =
                    slack_ub[entry_name, uuid, t] = JuMP.@variable(
                        jump_model,
                        base_name = "PostGeneratorContingencyFlowActivePowerSlackUpperBound_$(component_type)_{$(entry_name), $(uuid), $(t)}",
                        lower_bound = 0.0,
                    )
                lb =
                    slack_lb[entry_name, uuid, t] = JuMP.@variable(
                        jump_model,
                        base_name = "PostGeneratorContingencyFlowActivePowerSlackLowerBound_$(component_type)_{$(entry_name), $(uuid), $(t)}",
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
    ::_OUTAGE_MAP,
    ::Dict{Int, Bool},
    ::NetworkModel,
) = nothing

_deployment_expression_type(::NetworkModel{<:AbstractPTDFNetworkModel}) =
    PostContingencyNodalActivePowerDeployment
_deployment_expression_type(::NetworkModel{AreaBalanceNetworkModel}) =
    PostContingencyAreaActivePowerDeployment

_deployment_component_type(::NetworkModel{<:AbstractPTDFNetworkModel}) = PSY.ACBus
_deployment_component_type(::NetworkModel{AreaBalanceNetworkModel}) = PSY.Area

_location_key(component, network_model::NetworkModel{<:AbstractPTDFNetworkModel}) = string(
    PNM.get_mapped_bus_number(get_network_reduction(network_model), PSY.get_bus(component)),
)
_location_key(component, ::NetworkModel{AreaBalanceNetworkModel}) =
    PSY.get_name(PSY.get_area(PSY.get_bus(component)))

# [contributing device reserve] minus [outaged generator power] per bus or area
function _build_post_contingency_locational_power!(
    container::OptimizationContainer,
    sys::PSY.System,
    outaged_generators::_OUTAGE_MAP,
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    totals = _total_deployments(container)
    expr = lazy_container_addition!(
        container,
        _deployment_expression_type(network_model),
        _deployment_component_type(network_model),
        String[],
        Int[],
        Int[];
        sparse = true,
    )

    for (device_type, total) in totals
        locations = Dict{String, String}()
        for ((name, uuid, t), deployed) in total.data
            key = get!(locations, name) do
                _location_key(PSY.get_component(device_type, sys, name), network_model)
            end
            JuMP.add_to_expression!(get!(JuMP.AffExpr, expr.data, (key, uuid, t)), deployed)
        end
    end

    for (uuid, per_type) in outaged_generators
        for (generator_type, names) in per_type
            power = get_variable(container, ActivePowerVariable, generator_type)
            for name in names
                key = _location_key(
                    PSY.get_component(generator_type, sys, name),
                    network_model,
                )
                for t in get_time_steps(container)
                    JuMP.add_to_expression!(
                        get!(JuMP.AffExpr, expr.data, (key, uuid, t)),
                        -1.0,
                        power[name, t],
                    )
                end
            end
        end
    end
    return
end

_build_post_contingency_locational_power!(
    ::OptimizationContainer,
    ::PSY.System,
    ::_OUTAGE_MAP,
    ::NetworkModel,
) = nothing

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
    buses = Dict{Int, Set{String}}()
    for (bus, uuid, t) in keys(nodal.data)
        push!(get!(Set{String}, buses, uuid), bus)
    end

    # Arc distribution factors per reduced entry, keyed by the nodal bus key.
    dfs = Dict{Tuple{DataType, String}, Dict{String, Float64}}()
    for (uuid, per_type) in monitored_components
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
            pre_flow = get_expression(container, PTDFBranchFlow, line_type)
            arc_map = PNM.get_name_to_arc_map(catalog, line_type)
            for entry_name in _flow_entries(network_model, line_type, names)
                df = get!(dfs, (line_type, entry_name)) do
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

function _build_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_components::_OUTAGE_MAP,
    ::NetworkModel{AreaBalanceNetworkModel},
)
    if !has_container_key(container, FlowActivePowerVariable, PSY.AreaInterchange)
        @warn "An AreaBalanceNetworkModel with security-constrained reserves needs PSY.AreaInterchange(s) and DeviceModel{PSY.AreaInterchange} for reserve deployment to cross area boundaries. Otherwise, each area must cover its own outages." _group =
            LOG_GROUP_SERVICE_CONSTUCTORS maxlog = 1
        return
    end
    has_container_key(
        container,
        PostContingencyAreaInterchangeFlowDeviationVariable,
        PSY.AreaInterchange,
    ) || return
    time_steps = get_time_steps(container)
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
    for (_, total) in _total_deployments(container)
        for ((_, uuid, t), deployed) in total.data
            JuMP.add_to_expression!(balance[uuid, t], deployed)
        end
    end
    for ((uuid, t), ex) in balance
        cons[uuid, t] = JuMP.@constraint(jump_model, ex == 0.0)
    end
    return
end

function _constrain_post_contingency_balance!(
    container::OptimizationContainer,
    sys::PSY.System,
    outaged_generators::_OUTAGE_MAP,
    ::NetworkModel{AreaBalanceNetworkModel},
)
    uuids = sort!(collect(keys(outaged_generators)))
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)

    # Area name => (sign, interchange name)
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
        modeled = Set{String}(k[1] for k in keys(deviation.data))
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
    # Every area needs a row, or deviations into an area without deployment are unconstrained.
    for area_name in area_names, uuid in uuids, t in time_steps
        balance = JuMP.AffExpr(0.0)
        JuMP.add_to_expression!(
            balance,
            get(deployment.data, (area_name, uuid, t), zero(JuMP.AffExpr)),
        )
        for (sign, interchange_name) in get(interchanges, area_name, ())
            JuMP.add_to_expression!(balance, sign, deviation[interchange_name, uuid, t])
        end
        cons[area_name, uuid, t] = JuMP.@constraint(jump_model, balance == 0.0)
    end
    return
end

# Redundant for devices bounded by `_constrain_post_contingency_reserve!`, since their awards
# already sit in the device headroom; kept unconditional so no device can deploy past pmax.
function _constrain_post_contingency_generation!(
    container::OptimizationContainer,
    sys::PSY.System,
)
    jump_model = get_jump_model(container)
    for (device_type, total) in _total_deployments(container)
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
        limits = Dict{String, Float64}()
        for ((name, uuid, t), deployed) in total.data
            limit = get!(limits, name) do
                PSY.get_max_active_power(PSY.get_component(device_type, sys, name), PSY.SU)
            end
            cons[name, uuid, t] =
                JuMP.@constraint(jump_model, power[name, t] + deployed <= limit)
        end
    end
    return
end

_post_contingency_flow_expression(::NetworkModel{<:AbstractPTDFNetworkModel}) =
    PostContingencyBranchFlow
_post_contingency_flow_expression(::NetworkModel{AreaBalanceNetworkModel}) =
    PostContingencyAreaInterchangeFlow

# Parallel circuits share one reduced entry, so each entry is constrained once.
function _flow_entries(
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
    ::Type{T},
    names::Set{String},
) where {T <: PSY.ACTransmission}
    reduction_name_map =
        PNM.get_component_to_reduction_name_map(get_branch_catalog(network_model), T)
    return Set{String}(reduction_name_map[name] for name in names)
end

_flow_entries(
    ::NetworkModel{AreaBalanceNetworkModel},
    ::Type{PSY.AreaInterchange},
    names::Set{String},
) = names

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

function _constrain_post_contingency_flow!(
    container::OptimizationContainer,
    sys::PSY.System,
    monitored_components::_OUTAGE_MAP,
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for (uuid, per_type) in monitored_components
        for (component_type, names) in per_type
            flow = get_expression(
                container,
                _post_contingency_flow_expression(network_model),
                component_type,
                _G1_META,
            )
            cons_lb = lazy_container_addition!(
                container,
                PostContingencyFlowRateConstraint,
                component_type,
                String[],
                Int[],
                Int[];
                sparse = true,
                meta = "$(_G1_META)_lb",
            )
            cons_ub = lazy_container_addition!(
                container,
                PostContingencyFlowRateConstraint,
                component_type,
                String[],
                Int[],
                Int[];
                sparse = true,
                meta = "$(_G1_META)_ub",
            )
            has_slacks = has_container_key(
                container,
                PostGeneratorContingencyFlowActivePowerSlackUpperBound,
                component_type,
            )
            if has_slacks
                slack_ub = get_variable(
                    container,
                    PostGeneratorContingencyFlowActivePowerSlackUpperBound,
                    component_type,
                )
                slack_lb = get_variable(
                    container,
                    PostGeneratorContingencyFlowActivePowerSlackLowerBound,
                    component_type,
                )
            end
            for entry_name in _flow_entries(network_model, component_type, names)
                lims = _post_contingency_flow_limits(
                    sys,
                    network_model,
                    component_type,
                    entry_name,
                )
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
