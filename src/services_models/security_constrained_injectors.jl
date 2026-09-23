const _PER_TYPE = Dict{DataType, Set{String}}
const _OUTAGE_MAP = Dict{Int, _PER_TYPE}

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

_valid_component_type(::PSY.ACTransmission, ::NetworkModel{<:AbstractPTDFNetworkModel}) =
    true
_valid_component_type(::PSY.AreaInterchange, ::NetworkModel{AreaBalanceNetworkModel}) = true
_valid_component_type(::PSY.Component, ::NetworkModel) = false

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
                outages[uuid] = outage
            end
        end
    end
    return outages, use_slacks
end

"""
Reject monitored components of security-constrained reserve outages that the template does
not model, including those excluded by a branch model's `filter_function`. Post-contingency
flows are built only on modeled components, so monitored components must be a subset of the
modeled ones.
"""
function _check_security_constrained_reserve_monitors(
    template::PowerOperationsProblemTemplate,
    sys::PSY.System,
    network_model::NetworkModel,
)
    problems = String[]
    checked = Set{Int}()
    for model in values(get_service_models(template))
        _validate_reserve_formulation(model) || continue
        for service in get_available_components(model, sys),
            outage in PSY.get_supplemental_attributes(PSY.Outage, service)

            uuid = IS.get_id(outage)
            uuid in checked && continue
            push!(checked, uuid)
            for component_uuid in PSY.get_monitored_components(outage)
                component = IS.get_component(sys, component_uuid)
                _valid_component_type(component, network_model) || continue
                PSY.get_available(component) || continue
                branch_model = get_model(template, typeof(component))
                name = PSY.get_name(component)
                if isnothing(branch_model) ||
                   !any(c -> PSY.get_name(c) == name, get_device_cache(branch_model))
                    push!(
                        problems,
                        "Outage $uuid monitors $(typeof(component)) $name, which the \
                         template does not model (no branch model, or excluded by its \
                         filter_function).",
                    )
                end
            end
        end
    end
    isempty(problems) || throw(IS.ConflictingInputsError(join(problems, "\n")))
    return
end

# Outaged generators whose power the model can remove; the rest are skipped with a warning.
function _outaged_generators(
    container::OptimizationContainer,
    sys::PSY.System,
    outage::PSY.Outage,
)
    outaged = _PER_TYPE()
    for generator in
        PSY.get_associated_components(sys, outage; component_type = PSY.Generator)
        T = typeof(generator)
        name = PSY.get_name(generator)
        if has_container_key(container, ActivePowerVariable, T) &&
           name in axes(get_variable(container, ActivePowerVariable, T), 1)
            push!(get!(Set{String}, outaged, T), name)
        else
            @warn "Generator $name ($T) outaged by outage $(IS.get_id(outage)) is not \
                   modeled; it is left out of the post-contingency balance." _group =
                LOG_GROUP_SERVICE_CONSTUCTORS
        end
    end
    return outaged
end

function _monitored_components(
    sys::PSY.System,
    outages::Dict{Int, PSY.Outage},
    network_model::NetworkModel,
)
    monitored_components = _OUTAGE_MAP()
    for (uuid, outage) in outages
        monitored = _PER_TYPE()
        for component_uuid in PSY.get_monitored_components(outage)
            component = IS.get_component(sys, component_uuid)
            _valid_component_type(component, network_model) || continue
            PSY.get_available(component) || continue
            typeof(component) in network_model.modeled_branch_types || continue
            push!(get!(Set{String}, monitored, typeof(component)), PSY.get_name(component))
        end
        monitored_components[uuid] = monitored
    end
    return monitored_components
end

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

################################## Construction ###########################################

function _construct_post_contingency!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    services_template::ServicesModelContainer,
    network_model::NetworkModel,
)
    outages, use_slacks = _security_constrained_outages(sys, services_template)
    isempty(outages) && return
    _add_post_contingency_flow_slacks!(
        container,
        _monitored_components(sys, outages, network_model),
        use_slacks,
        network_model,
    )
    return
end

# Every outage gets a balance row per network region. Modeled interchanges carry a deviation
# variable per outage, balanced across areas; monitored interchanges (a subset of the modeled
# ones) and monitored branches additionally get post-contingency flow limits.
function _construct_post_contingency!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    services_template::ServicesModelContainer,
    network_model::NetworkModel,
)
    outages, use_slacks = _security_constrained_outages(sys, services_template)
    isempty(outages) && return
    outaged_generators = _OUTAGE_MAP(
        uuid => _outaged_generators(container, sys, outage) for (uuid, outage) in outages
    )
    monitored_components = _monitored_components(sys, outages, network_model)
    uuids = sort!(collect(keys(outages)))
    # AreaInterchange flow variables are created by the branch constructors, which run after the
    # services argument stage.
    _add_post_contingency_deviation_variables!(container, uuids, network_model)
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
        uuids,
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
        uuid = IS.get_id(outage)
        outaged = Set{String}(
            PSY.get_name(c) for
            c in PSY.get_associated_components(sys, outage; component_type = D)
        )
        for d in devices
            name = PSY.get_name(d)
            name in outaged && continue
            for t in get_time_steps(container)
                var =
                    deployment[service_name, name, uuid, t] = JuMP.@variable(
                        jump_model,
                        base_name = "PostContingencyDeploymentVariable_$(D)_$(R)_{$(service_name), $(name), $(uuid), $(t)}",
                        lower_bound = 0.0,
                    )
                JuMP.add_to_expression!(
                    get!(JuMP.AffExpr, total.data, (name, uuid, t)),
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
    uuids = [IS.get_id(o) for o in PSY.get_supplemental_attributes(PSY.Outage, service)]
    for d in devices, uuid in uuids, t in get_time_steps(container)
        name = PSY.get_name(d)
        # Devices the outage takes offline have no deployment.
        r = get(deployment.data, (service_name, name, uuid, t), nothing)
        isnothing(r) && continue
        cons[service_name, name, uuid, t] =
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
    uuids::Vector{Int},
    ::NetworkModel{AreaBalanceNetworkModel},
)
    if !has_container_key(container, FlowActivePowerVariable, PSY.AreaInterchange)
        @warn "An AreaBalanceNetworkModel with security-constrained reserves needs PSY.AreaInterchange(s) and DeviceModel{PSY.AreaInterchange} for reserve deployment to cross area boundaries. Otherwise, each area must cover its own outages." _group =
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
        uuids,
        time_steps,
    )
    for name in names, uuid in uuids, t in time_steps
        var[name, uuid, t] = JuMP.@variable(
            jump_model,
            base_name = "PostContingencyDeviationVariable_AreaInterchange_{$(name), $(uuid), $(t)}",
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
    monitored_components::_OUTAGE_MAP,
    use_slacks::Dict{Int, Bool},
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for (uuid, per_type) in monitored_components
        use_slacks[uuid] || continue
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

                slack_ub[entry_name, uuid, t] = JuMP.@variable(
                    jump_model,
                    base_name = "PostGeneratorContingencyFlowSlackUpperBound_$(component_type)_{$(entry_name), $(uuid), $(t)}",
                    lower_bound = 0.0,
                )
                slack_lb[entry_name, uuid, t] = JuMP.@variable(
                    jump_model,
                    base_name = "PostGeneratorContingencyFlowSlackLowerBound_$(component_type)_{$(entry_name), $(uuid), $(t)}",
                    lower_bound = 0.0,
                )
            end
        end
    end
    return
end

_add_post_contingency_flow_slacks!(
    ::OptimizationContainer,
    ::_OUTAGE_MAP,
    ::Dict{Int, Bool},
    ::NetworkModel,
) = nothing

################################## Expressions ############################################

# Keyed `(bus number or area name, outage, time)`, sparse since an outage only touches the
# locations of its deployments and outaged generators.
_add_locational_deployment_container!(
    container::OptimizationContainer,
    ::NetworkModel{<:AbstractPTDFNetworkModel},
) = add_expression_container!(
    container,
    PostContingencyNodalDeployment,
    PSY.ACBus,
    String[],
    Int[],
    Int[];
    sparse = true,
)
_add_locational_deployment_container!(
    container::OptimizationContainer,
    ::NetworkModel{AreaBalanceNetworkModel},
) = add_expression_container!(
    container,
    PostContingencyAreaDeployment,
    PSY.Area,
    String[],
    Int[],
    Int[];
    sparse = true,
)

_location_key(component, network_model::NetworkModel{<:AbstractPTDFNetworkModel}) = string(
    PNM.get_mapped_bus_number(get_network_reduction(network_model), PSY.get_bus(component)),
)
_location_key(component, ::NetworkModel{AreaBalanceNetworkModel}) =
    PSY.get_name(PSY.get_area(PSY.get_bus(component)))

# [contributing device deployment] minus [outaged generator power] per bus or area
function _add_post_contingency_locational_deployment!(
    container::OptimizationContainer,
    sys::PSY.System,
    outaged_generators::_OUTAGE_MAP,
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    expr = _add_locational_deployment_container!(container, network_model)

    for (device_type, total) in _total_deployments(container)
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

_add_post_contingency_locational_deployment!(
    ::OptimizationContainer,
    ::PSY.System,
    ::_OUTAGE_MAP,
    ::NetworkModel,
) = nothing

# Monitored names resolve to their reduction entry, the row the pre-contingency
# `PTDFBranchFlow` and the post-contingency expression are keyed by.
function _add_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_components::_OUTAGE_MAP,
    network_model::NetworkModel{<:AbstractPTDFNetworkModel},
)
    time_steps = get_time_steps(container)
    catalog = get_branch_catalog(network_model)
    ptdf = get_network_matrix(network_model)
    bus_axis = PNM.get_bus_axis(ptdf)

    nodal = get_expression(container, PostContingencyNodalDeployment, PSY.ACBus)
    buses = Dict{Int, Set{String}}()
    for (bus, uuid, t) in keys(nodal.data)
        push!(get!(Set{String}, buses, uuid), bus)
    end

    # Per reduced entry, its PTDF row keyed by the nodal bus key, dropping entries below
    # PTDF_ZERO_TOL.
    nonzero_factors = Dict{Tuple{DataType, String}, Dict{String, Float64}}()
    for (uuid, per_type) in monitored_components
        outage_buses = get(buses, uuid, Set{String}())
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
                        expr[entry_name, uuid, t] = IOM.get_hinted_aff_expr(
                            length(JuMP.linear_terms(pre_flow[entry_name, t])) +
                            length(outage_buses),
                        )
                    JuMP.add_to_expression!(ex, pre_flow[entry_name, t])
                    for bus in outage_buses
                        haskey(factors, bus) || continue
                        JuMP.add_to_expression!(ex, factors[bus], nodal[bus, uuid, t])
                    end
                end
            end
        end
    end
    return
end

function _add_post_contingency_flow!(
    container::OptimizationContainer,
    monitored_components::_OUTAGE_MAP,
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
        PostContingencyInterchangeFlow,
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
    for (uuid, per_type) in monitored_components
        for name in get(per_type, PSY.AreaInterchange, Set{String}()), t in time_steps
            ex = expr[name, uuid, t] = JuMP.AffExpr(0.0)
            JuMP.add_to_expression!(ex, flow[name, t])
            JuMP.add_to_expression!(ex, deviation[name, uuid, t])
        end
    end
    return
end

_add_post_contingency_flow!(::OptimizationContainer, ::_OUTAGE_MAP, ::NetworkModel) =
    nothing

################################## Constraints ############################################

function _add_post_contingency_balance_constraints!(
    container::OptimizationContainer,
    ::PSY.System,
    outaged_generators::_OUTAGE_MAP,
    uuids::Vector{Int},
    ::NetworkModel,
)
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    cons = add_constraints_container!(
        container,
        PostContingencyBalanceConstraint,
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

function _add_post_contingency_balance_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::_OUTAGE_MAP,
    uuids::Vector{Int},
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
    deployment = get_expression(container, PostContingencyAreaDeployment, PSY.Area)

    area_names = PSY.get_name.(PSY.get_components(PSY.Area, sys))
    cons = add_constraints_container!(
        container,
        PostContingencyBalanceConstraint,
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
    PostContingencyInterchangeFlow

function _add_post_contingency_flow_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    monitored_components::_OUTAGE_MAP,
    use_slacks::Dict{Int, Bool},
    network_model::NetworkModel{<:Union{AbstractPTDFNetworkModel, AreaBalanceNetworkModel}},
)
    jump_model = get_jump_model(container)
    time_steps = get_time_steps(container)
    for (uuid, per_type) in monitored_components
        slacked = use_slacks[uuid]
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
                    f = flow[entry_name, uuid, t]
                    if slacked
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

_add_post_contingency_flow_constraints!(
    ::OptimizationContainer,
    ::PSY.System,
    ::_OUTAGE_MAP,
    ::Dict{Int, Bool},
    ::NetworkModel,
) = nothing

function _add_post_contingency_slack_costs!(
    container::OptimizationContainer,
    monitored_components::_OUTAGE_MAP,
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
