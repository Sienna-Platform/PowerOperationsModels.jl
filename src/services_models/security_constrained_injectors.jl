const _G1_META = "G1"

_validate_reserve_formulation(::ServiceModel) = false
_validate_reserve_formulation(
    ::ServiceModel{<:_RESERVE_UP, <:AbstractSecurityConstrainedReservesFormulation},
) = true
_validate_reserve_formulation(
    ::ServiceModel{<:PSY.AbstractReserve, <:AbstractSecurityConstrainedReservesFormulation},
) = throw(
    IS.ConflictingInputsError(
        "Security-constrained formulations currently only support reserve-up services.",
    ),
)

_valid_monitored_component(
    ::PSY.ACTransmission,
    ::NetworkModel{<:AbstractPTDFNetworkModel},
) =
    true
_valid_monitored_component(::PSY.AreaInterchange, ::NetworkModel{AreaBalanceNetworkModel}) =
    true
_valid_monitored_component(::PSY.Component, ::NetworkModel) = false

"""
Outages attached to security-constrained reserves, by UUID, and whether each one's
post-contingency flow limits are relaxed.

Flow constraints are shared by every reserve responding to an outage, so the service models
carrying that outage must agree on `use_slacks`.
"""
function _security_constrained_outages(
    sys::PSY.System,
    services_template::ServicesModelContainer,
)
    outages = Dict{Int, PSY.Outage}()
    use_slacks = Dict{Int, Bool}()
    for model in values(services_template)
        _validate_reserve_formulation(model) || continue
        model_slacks = get_use_slacks(model)
        for service in _services_with_contributors(model, sys)
            for outage in PSY.get_supplemental_attributes(PSY.Outage, service)
                outage_id = IS.get_id(outage)
                if get!(use_slacks, outage_id, model_slacks) != model_slacks
                    throw(
                        IS.ConflictingInputsError(
                            "Outage $outage_id is attached to security-constrained reserves \
                             with different `use_slacks` settings; set `use_slacks` \
                             consistently across their service models.",
                        ),
                    )
                end
                outages[outage_id] = outage
            end
        end
    end
    return outages, use_slacks
end

function _outaged_generators(
    sys::PSY.System,
    outages::Dict{Int, PSY.Outage},
    container::OptimizationContainer,
)
    outaged_generators = Dict{Int, Dict{DataType, Set{String}}}()
    for (outage_id, outage) in outages
        outaged = Dict{DataType, Set{String}}()
        for generator in
            PSY.get_associated_components(sys, outage; component_type = PSY.Generator)
            T = typeof(generator)
            name = PSY.get_name(generator)
            if has_container_key(container, ActivePowerVariable, T) &&
               name in axes(get_variable(container, ActivePowerVariable, T), 1)
                push!(get!(Set{String}, outaged, T), name)
            else
                @warn "Generator $name ($T) outaged by outage $outage_id is not modeled; it is left out of the post-contingency balance." _group =
                    LOG_GROUP_SERVICE_CONSTUCTORS
            end
        end
        outaged_generators[outage_id] = outaged
    end
    return outaged_generators
end

_monitored_is_modeled(
    container::OptimizationContainer,
    T::Type{<:PSY.ACTransmission},
    name::String,
    ::NetworkModel{<:AbstractPTDFNetworkModel},
) =
    has_container_key(container, PTDFBranchFlow, T) &&
    name in axes(get_expression(container, PTDFBranchFlow, T), 1)
_monitored_is_modeled(
    container::OptimizationContainer,
    T::Type{PSY.AreaInterchange},
    name::String,
    ::NetworkModel{AreaBalanceNetworkModel},
) =
    has_container_key(container, FlowActivePowerVariable, T) &&
    name in axes(get_variable(container, FlowActivePowerVariable, T), 1)

function _monitored_components(
    sys::PSY.System,
    outages::Dict{Int, PSY.Outage},
    container::OptimizationContainer,
    network_model::NetworkModel,
)
    monitored_components = Dict{Int, Dict{DataType, Set{String}}}()
    for (outage_id, outage) in outages
        monitored = Dict{DataType, Set{String}}()
        for component_uuid in PSY.get_monitored_components(outage)
            component = IS.get_component(sys, component_uuid)
            _valid_monitored_component(component, network_model) || continue
            T = typeof(component)
            name = PSY.get_name(component)
            if _monitored_is_modeled(container, T, name, network_model)
                push!(get!(Set{String}, monitored, T), name)
            else
                @warn "Monitored component $name ($T) on outage $outage_id is not modeled; its post-contingency flow will not be limited." _group =
                    LOG_GROUP_SERVICE_CONSTUCTORS
            end
        end
        monitored_components[outage_id] = monitored
    end
    return monitored_components
end

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

################################## Construction ###########################################

# Every outage gets a balance row per network region. Modeled interchanges carry a deviation
# variable per outage, balanced across areas; monitored interchanges and monitored branches
# additionally get post-contingency flow limits.
function _construct_post_contingency!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    services_template::ServicesModelContainer,
    network_model::NetworkModel,
)
    outages, use_slacks = _security_constrained_outages(sys, services_template)
    isempty(outages) && return
    outaged_generators = _outaged_generators(sys, outages, container)
    monitored_components = _monitored_components(sys, outages, container, network_model)
    outage_ids = sort!(collect(keys(outages)))
    # Branch and interchange flows are created by the branch constructors, which run after the
    # services argument stage, so the variables that depend on them are added here.
    _add_post_contingency_deviation_variables!(container, outage_ids, network_model)
    _add_post_contingency_flow_slacks!(
        container,
        monitored_components,
        use_slacks,
        network_model,
    )
    _add_post_contingency_locational_deployment!(
        container,
        sys,
        outaged_generators,
        network_model,
    )
    _add_post_contingency_flow!(container, monitored_components, network_model)
    _add_post_contingency_balance_constraints!(
        container,
        sys,
        outaged_generators,
        outage_ids,
        network_model,
    )
    _add_post_contingency_generation_constraints!(container, sys)
    _add_post_contingency_flow_constraints!(
        container,
        sys,
        monitored_components,
        use_slacks,
        network_model,
    )
    _add_post_contingency_slack_costs!(container, monitored_components)
    return
end

################################## Deployment #############################################

# Each service deploys its own contributors under every outage it responds to, except the
# contributors that outage takes offline; the per-device sum across services is what the
# outage-level constraints see.
function _add_post_contingency_deployment!(
    container::OptimizationContainer,
    sys::PSY.System,
    service::R,
    devices::Vector{D},
) where {R <: PSY.Service, D <: PSY.Component}
    jump_model = get_jump_model(container)
    service_name = PSY.get_name(service)
    # Lazy: every service of type `R` that `D` contributes to shares this container.
    deployment = lazy_container_addition!(
        container,
        PostContingencyDeploymentVariable,
        IOM.ComponentPairKey{D, R},
        String[],
        String[],
        Int[],
        Int[];
        sparse = true,
    )
    # Lazy: shared by every service `D` contributes to. Keyed `(device name, outage, time)`.
    total = lazy_container_addition!(
        container,
        PostContingencyTotalDeployment,
        D,
        String[],
        Int[],
        Int[];
        sparse = true,
    )
    for outage in PSY.get_supplemental_attributes(PSY.Outage, service)
        outage_id = IS.get_id(outage)
        outaged = Set{String}(
            PSY.get_name(c) for
            c in PSY.get_associated_components(sys, outage; component_type = D)
        )
        for d in devices
            name = PSY.get_name(d)
            name in outaged && continue
            for t in get_time_steps(container)
                var =
                    deployment[service_name, name, outage_id, t] = JuMP.@variable(
                        jump_model,
                        base_name = "PostContingencyDeploymentVariable_$(D)_$(R)_{$(service_name), $(name), $(outage_id), $(t)}",
                        lower_bound = 0.0,
                    )
                JuMP.add_to_expression!(
                    get!(JuMP.AffExpr, total.data, (name, outage_id, t)),
                    var,
                )
            end
        end
    end
    return
end

# Deployment can only draw on procured reserve. Unprocured reserves are limited by generation
# headroom alone.
function add_constraints!(
    container::OptimizationContainer,
    ::Type{PostContingencyDeploymentConstraint},
    service::R,
    devices::Vector{D},
    ::ServiceModel{R, <:AbstractSecurityConstrainedReservesFormulation},
) where {R <: _RESERVE_UP, D <: PSY.Component}
    key = IOM.ComponentPairKey{D, R}
    jump_model = get_jump_model(container)
    service_name = PSY.get_name(service)
    deployment = get_variable(container, PostContingencyDeploymentVariable, key)
    award = _reserve_variable(container, D, R)
    cons = lazy_container_addition!(
        container,
        PostContingencyDeploymentConstraint,
        key,
        String[],
        String[],
        Int[],
        Int[];
        sparse = true,
    )
    outage_ids =
        [IS.get_id(o) for o in PSY.get_supplemental_attributes(PSY.Outage, service)]
    for d in devices, outage_id in outage_ids, t in get_time_steps(container)
        name = PSY.get_name(d)
        # Devices the outage takes offline have no deployment.
        r = get(deployment.data, (service_name, name, outage_id, t), nothing)
        isnothing(r) && continue
        cons[service_name, name, outage_id, t] =
            JuMP.@constraint(jump_model, r <= award[service_name, name, t])
    end
    return
end

# Device types are only known from the container keys: services register a total-deployment
# container per contributing device type.
_total_deployments(container::OptimizationContainer) = [
    (get_component_type(key), expr) for
    (key, expr) in IOM.get_expressions(container) if
    IOM.get_entry_type(key) === PostContingencyTotalDeployment
]

################################## Variables ##############################################

function _add_post_contingency_deviation_variables!(
    container::OptimizationContainer,
    outage_ids::Vector{Int},
    ::NetworkModel{AreaBalanceNetworkModel},
)
    if !has_container_key(container, FlowActivePowerVariable, PSY.AreaInterchange)
        @warn "An AreaBalanceNetworkModel with security-constrained reserves needs modeled PSY.AreaInterchanges for reserve deployment to cross area boundaries. Otherwise, each area must cover its own outages." _group =
            LOG_GROUP_SERVICE_CONSTUCTORS
        return
    end
    flow = get_variable(container, FlowActivePowerVariable, PSY.AreaInterchange)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    names = axes(flow, 1)
    var = add_variable_container!(
        container,
        PostContingencyDeviationVariable,
        PSY.AreaInterchange,
        names,
        outage_ids,
        time_steps,
    )
    for name in names, outage_id in outage_ids, t in time_steps
        var[name, outage_id, t] = JuMP.@variable(
            jump_model,
            base_name = "PostContingencyDeviationVariable_AreaInterchange_{$(name), $(outage_id), $(t)}",
        )
    end
    return
end

_add_post_contingency_deviation_variables!(
    ::OptimizationContainer,
    ::Vector{Int},
    ::NetworkModel,
) = nothing

function _add_post_contingency_flow_slacks!(
    container::OptimizationContainer,
    monitored_components::Dict{Int, Dict{DataType, Set{String}}},
    use_slacks::Dict{Int, Bool},
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for (outage_id, per_type) in monitored_components
        use_slacks[outage_id] || continue
        for (component_type, names) in per_type
            # Lazy: slack containers are per component type and shared across outages.
            # Keyed `(flow entry, outage, time)`, sparse since outages monitor different entries.
            slack_ub = lazy_container_addition!(
                container,
                PostGeneratorContingencyFlowSlackUpperBound,
                component_type,
                String[],
                Int[],
                Int[];
                sparse = true,
            )
            slack_lb = lazy_container_addition!(
                container,
                PostGeneratorContingencyFlowSlackLowerBound,
                component_type,
                String[],
                Int[],
                Int[];
                sparse = true,
            )
            for entry_name in _flow_entries(network_model, component_type, names),
                t in time_steps

                slack_ub[entry_name, outage_id, t] = JuMP.@variable(
                    jump_model,
                    base_name = "PostGeneratorContingencyFlowSlackUpperBound_$(component_type)_{$(entry_name), $(outage_id), $(t)}",
                    lower_bound = 0.0,
                )
                slack_lb[entry_name, outage_id, t] = JuMP.@variable(
                    jump_model,
                    base_name = "PostGeneratorContingencyFlowSlackLowerBound_$(component_type)_{$(entry_name), $(outage_id), $(t)}",
                    lower_bound = 0.0,
                )
            end
        end
    end
    return
end

_add_post_contingency_flow_slacks!(
    ::OptimizationContainer,
    ::Dict{Int, Dict{DataType, Set{String}}},
    ::Dict{Int, Bool},
    ::NetworkModel,
) = nothing

################################## Expressions ############################################

_location_type(::NetworkModel{<:AbstractPTDFNetworkModel}) = PSY.ACBus
_location_type(::NetworkModel{AreaBalanceNetworkModel}) = PSY.Area

_location_key(component, network_model::NetworkModel{<:AbstractPTDFNetworkModel}) = string(
    PNM.get_mapped_bus_number(get_network_reduction(network_model), PSY.get_bus(component)),
)
_location_key(component, ::NetworkModel{AreaBalanceNetworkModel}) =
    PSY.get_name(PSY.get_area(PSY.get_bus(component)))

# [contributing device deployment] minus [outaged generator power] per bus or area
function _add_post_contingency_locational_deployment!(
    container::OptimizationContainer,
    sys::PSY.System,
    outaged_generators::Dict{Int, Dict{DataType, Set{String}}},
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    # Keyed `(bus number or area name, outage, time)`, sparse since an outage only touches the
    # locations of its deployments and outaged generators.
    expr = add_expression_container!(
        container,
        PostContingencyLocationalDeployment,
        _location_type(network_model),
        String[],
        Int[],
        Int[];
        sparse = true,
    )

    for (device_type, total) in _total_deployments(container)
        locations = Dict{String, String}()
        for ((name, outage_id, t), deployed) in total.data
            key = get!(locations, name) do
                _location_key(PSY.get_component(device_type, sys, name), network_model)
            end
            JuMP.add_to_expression!(
                get!(JuMP.AffExpr, expr.data, (key, outage_id, t)),
                deployed,
            )
        end
    end

    for (outage_id, per_type) in outaged_generators
        for (generator_type, names) in per_type
            power = get_variable(container, ActivePowerVariable, generator_type)
            for name in names
                key = _location_key(
                    PSY.get_component(generator_type, sys, name),
                    network_model,
                )
                for t in get_time_steps(container)
                    JuMP.add_to_expression!(
                        get!(JuMP.AffExpr, expr.data, (key, outage_id, t)),
                        -1.0,
                        power[name, t],
                    )
                end
            end
        end
    end
    return
end

_add_post_contingency_locational_deployment!(
    ::OptimizationContainer,
    ::PSY.System,
    ::Dict{Int, Dict{DataType, Set{String}}},
    ::NetworkModel,
) = nothing

# Monitored names resolve to their reduction entry, the row the pre-contingency
# `PTDFBranchFlow` and the post-contingency expression are keyed by.
function _add_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_components::Dict{Int, Dict{DataType, Set{String}}},
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
)
    time_steps = get_time_steps(container)
    catalog = get_branch_catalog(network_model)
    ptdf = get_network_matrix(network_model)
    bus_axis = PNM.get_bus_axis(ptdf)

    nodal = get_expression(container, PostContingencyLocationalDeployment, PSY.ACBus)
    buses = Dict{Int, Set{String}}()
    for (bus, outage_id, t) in keys(nodal.data)
        push!(get!(Set{String}, buses, outage_id), bus)
    end

    # Per reduced entry, its PTDF row keyed by the nodal bus key, dropping entries below
    # PTDF_ZERO_TOL.
    nonzero_factors = Dict{Tuple{DataType, String}, Dict{String, Float64}}()
    for (outage_id, per_type) in monitored_components
        outage_buses = get(buses, outage_id, Set{String}())
        for (line_type, names) in per_type
            # Keyed `(flow entry, outage, time)`, sparse since outages monitor different entries.
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
                factors = get!(nonzero_factors, (line_type, entry_name)) do
                    ptdf_col = ptdf[arc_map[entry_name], :]
                    Dict{String, Float64}(
                        string(bus_axis[i]) => ptdf_col[i] for
                        i in eachindex(ptdf_col) if abs(ptdf_col[i]) > PTDF_ZERO_TOL
                    )
                end
                for t in time_steps
                    ex =
                        expr[entry_name, outage_id, t] = IOM.get_hinted_aff_expr(
                            length(JuMP.linear_terms(pre_flow[entry_name, t])) +
                            length(outage_buses),
                        )
                    JuMP.add_to_expression!(ex, pre_flow[entry_name, t])
                    for bus in outage_buses
                        haskey(factors, bus) || continue
                        JuMP.add_to_expression!(ex, factors[bus], nodal[bus, outage_id, t])
                    end
                end
            end
        end
    end
    return
end

function _add_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_components::Dict{Int, Dict{DataType, Set{String}}},
    ::NetworkModel{AreaBalanceNetworkModel},
)
    has_container_key(
        container,
        PostContingencyDeviationVariable,
        PSY.AreaInterchange,
    ) || return
    time_steps = get_time_steps(container)
    # Keyed `(interchange, outage, time)`, sparse since outages monitor different interchanges.
    expr = add_expression_container!(
        container,
        PostContingencyBranchFlow,
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
        PostContingencyDeviationVariable,
        PSY.AreaInterchange,
    )
    for (outage_id, per_type) in monitored_components
        for name in get(per_type, PSY.AreaInterchange, Set{String}()), t in time_steps
            ex = expr[name, outage_id, t] = JuMP.AffExpr(0.0)
            JuMP.add_to_expression!(ex, flow[name, t])
            JuMP.add_to_expression!(ex, deviation[name, outage_id, t])
        end
    end
    return
end

_add_post_contingency_flow!(
    ::OptimizationContainer,
    ::Dict{Int, Dict{DataType, Set{String}}},
    ::NetworkModel,
) =
    nothing

################################## Constraints ############################################

function _add_post_contingency_balance_constraints!(
    container::OptimizationContainer,
    ::PSY.System,
    outaged_generators::Dict{Int, Dict{DataType, Set{String}}},
    outage_ids::Vector{Int},
    ::NetworkModel,
)
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    cons = add_constraints_container!(
        container,
        PostContingencyBalanceConstraint,
        PSY.System,
        outage_ids,
        time_steps,
    )

    balance = Dict(
        (outage_id, t) => JuMP.AffExpr(0.0) for outage_id in outage_ids, t in time_steps
    )
    for (outage_id, per_type) in outaged_generators
        for (generator_type, names) in per_type
            power = get_variable(container, ActivePowerVariable, generator_type)
            for name in names, t in time_steps
                JuMP.add_to_expression!(balance[outage_id, t], -1.0, power[name, t])
            end
        end
    end
    for (_, total) in _total_deployments(container)
        for ((_, outage_id, t), deployed) in total.data
            JuMP.add_to_expression!(balance[outage_id, t], deployed)
        end
    end
    for ((outage_id, t), ex) in balance
        cons[outage_id, t] = JuMP.@constraint(jump_model, ex == 0.0)
    end
    return
end

function _add_post_contingency_balance_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::Dict{Int, Dict{DataType, Set{String}}},
    outage_ids::Vector{Int},
    ::NetworkModel{AreaBalanceNetworkModel},
)
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)

    # Area name => (sign, interchange name). Without an AreaInterchange model there are no
    # deviations, so each area covers its own outages.
    interchanges = Dict{String, Vector{Tuple{Float64, String}}}()
    if has_container_key(
        container,
        PostContingencyDeviationVariable,
        PSY.AreaInterchange,
    )
        deviation = get_variable(
            container,
            PostContingencyDeviationVariable,
            PSY.AreaInterchange,
        )
        for name in axes(deviation, 1)
            interchange = PSY.get_component(PSY.AreaInterchange, sys, name)
            from_area = PSY.get_name(PSY.get_from_area(interchange))
            to_area = PSY.get_name(PSY.get_to_area(interchange))
            push!(
                get!(Vector{Tuple{Float64, String}}, interchanges, from_area),
                (-1.0, name),
            )
            push!(get!(Vector{Tuple{Float64, String}}, interchanges, to_area), (1.0, name))
        end
    end
    deployment = get_expression(container, PostContingencyLocationalDeployment, PSY.Area)

    area_names = PSY.get_name.(PSY.get_components(PSY.Area, sys))
    cons = add_constraints_container!(
        container,
        PostContingencyBalanceConstraint,
        PSY.Area,
        area_names,
        outage_ids,
        time_steps,
    )
    # Every area needs a row, or deviations into an area without deployment are unconstrained.
    for area_name in area_names, outage_id in outage_ids, t in time_steps
        balance = JuMP.AffExpr(0.0)
        JuMP.add_to_expression!(
            balance,
            get(deployment.data, (area_name, outage_id, t), zero(JuMP.AffExpr)),
        )
        for (sign, interchange_name) in get(interchanges, area_name, ())
            JuMP.add_to_expression!(
                balance,
                sign,
                deviation[interchange_name, outage_id, t],
            )
        end
        cons[area_name, outage_id, t] = JuMP.@constraint(jump_model, balance == 0.0)
    end
    return
end

# Redundant for devices bounded by `PostContingencyDeploymentConstraint`, since their awards
# already sit in the device headroom; kept unconditional so no device can deploy past pmax.
function _add_post_contingency_generation_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
)
    jump_model = get_jump_model(container)
    for (device_type, total) in _total_deployments(container)
        cons = add_constraints_container!(
            container,
            PostContingencyGenerationConstraint,
            device_type,
            String[],
            Int[],
            Int[];
            sparse = true,
        )
        power = get_variable(container, ActivePowerVariable, device_type)
        limits = Dict{String, Float64}()
        for ((name, outage_id, t), deployed) in total.data
            limit = get!(limits, name) do
                PSY.get_max_active_power(PSY.get_component(device_type, sys, name), PSY.SU)
            end
            cons[name, outage_id, t] =
                JuMP.@constraint(jump_model, power[name, t] + deployed <= limit)
        end
    end
    return
end

function _add_post_contingency_flow_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    monitored_components::Dict{Int, Dict{DataType, Set{String}}},
    use_slacks::Dict{Int, Bool},
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for (outage_id, per_type) in monitored_components
        slacked = use_slacks[outage_id]
        for (component_type, names) in per_type
            flow = get_expression(
                container,
                PostContingencyBranchFlow,
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
            if slacked
                slack_ub = get_variable(
                    container,
                    PostGeneratorContingencyFlowSlackUpperBound,
                    component_type,
                )
                slack_lb = get_variable(
                    container,
                    PostGeneratorContingencyFlowSlackLowerBound,
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
                    f = flow[entry_name, outage_id, t]
                    if slacked
                        cons_ub[entry_name, outage_id, t] = JuMP.@constraint(
                            jump_model,
                            f - slack_ub[entry_name, outage_id, t] <= lims.max
                        )
                        cons_lb[entry_name, outage_id, t] = JuMP.@constraint(
                            jump_model,
                            f + slack_lb[entry_name, outage_id, t] >= lims.min
                        )
                    else
                        cons_ub[entry_name, outage_id, t] =
                            JuMP.@constraint(jump_model, f <= lims.max)
                        cons_lb[entry_name, outage_id, t] =
                            JuMP.@constraint(jump_model, f >= lims.min)
                    end
                end
            end
        end
    end
    return
end

_add_post_contingency_flow_constraints!(
    ::OptimizationContainer,
    ::PSY.System,
    ::Dict{Int, Dict{DataType, Set{String}}},
    ::Dict{Int, Bool},
    ::NetworkModel,
) = nothing

function _add_post_contingency_slack_costs!(
    container::OptimizationContainer,
    monitored_components::Dict{Int, Dict{DataType, Set{String}}},
)
    component_types = Set{DataType}()
    for per_type in values(monitored_components)
        union!(component_types, keys(per_type))
    end
    for component_type in component_types,
        slack_type in (
            PostGeneratorContingencyFlowSlackUpperBound,
            PostGeneratorContingencyFlowSlackLowerBound,
        )

        has_container_key(container, slack_type, component_type) || continue
        for slack in values(get_variable(container, slack_type, component_type).data)
            add_to_objective_invariant_expression!(
                container,
                slack * CONSTRAINT_VIOLATION_SLACK_COST,
            )
        end
    end
    return
end
