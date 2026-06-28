const _TEMPLATE_VALIDATION_EXCLUSIONS = [PSY.Arc, PSY.Area, PSY.ACBus, PSY.LoadZone]

# Reconcile the model's resolution setting against the resolutions present in the
# system's time series: set it when unset and a single resolution exists, and error on
# ambiguous (multiple-resolution) or unavailable resolutions. Shared by the DecisionModel
# and EmulationModel `validate_time_series!` methods.
function _reconcile_resolution!(settings, sys)
    available_resolutions = IOM.get_time_series_resolutions(sys)
    if get_resolution(settings) == IOM.UNSET_RESOLUTION &&
       length(available_resolutions) != 1
        throw(
            IS.ConflictingInputsError(
                "Data contains multiple resolutions, the resolution keyword argument must be added to the Model. Time Series Resolutions: $(available_resolutions)",
            ),
        )
    elseif get_resolution(settings) != IOM.UNSET_RESOLUTION &&
           length(available_resolutions) > 1
        if get_resolution(settings) ∉ available_resolutions
            throw(
                IS.ConflictingInputsError(
                    "Resolution $(get_resolution(settings)) is not available in the system data. Time Series Resolutions: $(available_resolutions)",
                ),
            )
        end
    else
        IOM.set_resolution!(settings, first(available_resolutions))
    end
    return
end

function validate_template_impl!(model::IOM.AbstractOptimizationModel)
    template = get_template(model)
    settings = get_settings(model)
    if isempty(template)
        error("Template can't be empty for models $(IOM.get_problem_type(model))")
    end
    system = get_system(model)
    modeled_types = IOM.get_component_types(template)
    system_component_types = PSY.get_existing_component_types(system)
    network_model = get_network_model(template)
    valid_device_types = union(modeled_types, _TEMPLATE_VALIDATION_EXCLUSIONS)
    unmodeled_branch_types = DataType[]

    for m in setdiff(system_component_types, valid_device_types)
        @warn "The template doesn't include models for components of type $(m), consider changing the template" _group =
            IOM.LOG_GROUP_MODELS_VALIDATION
        if m <: PSY.ACTransmission
            push!(unmodeled_branch_types, m)
        end
    end

    device_keys_to_delete = Symbol[]
    for (k, device_model) in template.devices
        make_device_cache!(device_model, system, get_check_components(settings))
        if isempty(get_device_cache(device_model))
            @info "The system data doesn't include devices of type $(k), consider changing the models in the template" _group =
                IOM.LOG_GROUP_MODELS_VALIDATION
            push!(device_keys_to_delete, k)
        end
    end
    for k in device_keys_to_delete
        delete!(template.devices, k)
    end

    model_has_branch_filters = false
    branch_keys_to_delete = Symbol[]
    validate_branches =
        get_check_components(settings) &&
        branches_modeled(get_network_formulation(network_model))
    for (k, device_model) in template.branches
        make_device_cache!(device_model, system, validate_branches)
        if isempty(get_device_cache(device_model))
            @info "The system data doesn't include Branches of type $(k), consider changing the models in the template" _group =
                IOM.LOG_GROUP_MODELS_VALIDATION
            push!(branch_keys_to_delete, k)
        else
            push!(network_model.modeled_branch_types, get_component_type(device_model))
        end
        if get_attribute(device_model, "filter_function") !== nothing
            model_has_branch_filters = true
        end
    end
    for k in branch_keys_to_delete
        delete!(template.branches, k)
    end
    _check_security_constrained_three_winding_transformer!(template.branches)
    _check_security_constrained_network!(template.branches, network_model)
    _check_branch_rating_time_series_formulation!(template.branches, system)
    validate_network_model(network_model, unmodeled_branch_types, model_has_branch_filters)
    _build_device_model_outages!(template, system)
    _build_service_model_outages!(template, system)
    return
end

#################################################################################
# Security-constrained branch validation and outage population
#################################################################################

function _any_component_has_branch_rating_ts(
    ::Type{P},
    device_model::DeviceModel,
    sys::PSY.System,
) where {P <: AbstractBranchRatingTimeSeriesParameter}
    haskey(get_time_series_names(device_model), P) || return false
    ts_name = get_time_series_names(device_model)[P]
    # Only the modeled forecast matters: operations consume a
    # Deterministic-family forecast, never a bare SingleTimeSeries. Use the
    # same `ts_type` the reduction path resolves so both pathways agree on
    # what "has the branch rating time series" means.
    ts_type = IOM.get_deterministic_time_series_type(sys)
    return any(
        c -> PSY.has_time_series(c, ts_type, ts_name),
        get_device_cache(device_model),
    )
end

# Both `BranchRatingTimeSeriesParameter` and
# `PostContingencyBranchRatingTimeSeriesParameter` are only honored by the
# `StaticBranch` (pre-contingency PTDF / native DCP / native ACP) and
# `AbstractSecurityConstrainedStaticBranch` constructors. Any other
# formulation that carries either series passes validation but never builds a
# usable parameter container, so the series would be silently ignored —
# reject it up front instead. `StaticBranchUnbounded` enforces no flow limits
# at all, so the series is simply unused there: warn rather than error.
function _check_branch_rating_time_series_formulation!(
    branch_models::IOM.BranchModelContainer,
    sys::PSY.System,
)
    for (_, device_model) in branch_models
        D = get_component_type(device_model)
        B = get_formulation(device_model)
        for P in (
            BranchRatingTimeSeriesParameter,
            PostContingencyBranchRatingTimeSeriesParameter,
        )
            _any_component_has_branch_rating_ts(P, device_model, sys) || continue
            if B <: StaticBranch || B <: AbstractSecurityConstrainedStaticBranch
                continue
            elseif B <: StaticBranchUnbounded
                @warn "$(P) is attached to $(D) components but $(B) does not \
                       enforce flow limits; the branch rating time series will \
                       be ignored for these branches." _group =
                    IOM.LOG_GROUP_MODELS_VALIDATION
                continue
            else
                throw(
                    IS.ConflictingInputsError(
                        "$(P) is only supported with the StaticBranch or \
                        AbstractSecurityConstrainedStaticBranch formulations, \
                        but branch type $(D) was configured with $(B). Remove \
                        the branch rating time series from the components or \
                        change the formulation.",
                    ),
                )
            end
        end
    end
    return
end

function _check_security_constrained_three_winding_transformer!(
    branch_models::IOM.BranchModelContainer,
)
    for (_, device_model) in branch_models
        D = get_component_type(device_model)
        B = get_formulation(device_model)
        if D <: PSY.ThreeWindingTransformer &&
           B <: AbstractSecurityConstrainedStaticBranch
            throw(
                IS.ConflictingInputsError(
                    "Security-constrained branch formulations are not implemented \
                    yet for $(D), but it was configured with $(B). Use a non \
                    security-constrained formulation (e.g. StaticBranch) for \
                    $(D), or remove it from the template.",
                ),
            )
        end
    end
    return
end

# Whether an `AbstractSecurityConstrainedStaticBranch` has a `construct_device!`
# path for this network model. PTDF and ACP build full post-contingency limits;
# NFA/CopperPlate/AreaBalance are intentional no-ops. The fallback returns
# `false` so unsupported networks fail fast at validation instead of hitting a
# `MethodError` during build.
_sc_branch_network_supported(::NetworkModel{<:AbstractPTDFModel}) = true
_sc_branch_network_supported(::NetworkModel{<:PM.AbstractACPModel}) = true
_sc_branch_network_supported(::NetworkModel{NFAPowerModel}) = true
_sc_branch_network_supported(::NetworkModel{CopperPlatePowerModel}) = true
_sc_branch_network_supported(::NetworkModel{AreaBalancePowerModel}) = true
_sc_branch_network_supported(::NetworkModel) = false

function _check_security_constrained_network!(
    branch_models::IOM.BranchModelContainer,
    network_model::NetworkModel,
)
    _sc_branch_network_supported(network_model) && return
    for (_, device_model) in branch_models
        B = get_formulation(device_model)
        if B <: AbstractSecurityConstrainedStaticBranch
            throw(
                IS.ConflictingInputsError(
                    "$(B) is not supported with network model \
                    $(get_network_formulation(network_model)). Use a PTDF \
                    (AbstractPTDFModel) or ACP network model. DCP support \
                    (angle-based post-contingency) is pending; NFA, \
                    CopperPlate and AreaBalance are inert for \
                    security-constrained branches.",
                ),
            )
        end
    end
    return
end

"""
Populate `device_model.outages` for every security-constrained (SC) branch
device model in the template, in a single pass over the system's outage
supplemental attributes. `DeviceModel{D, SC}` claims an outage iff `D` is among
the types of the outaged (attached) components. The inner dict carries the
per-modeled-type breakdown of monitored component names.

Selection semantics:
- If `m.outages` is non-empty when this runs, the user explicitly listed UUIDs
  via the constructor kwarg. Restrict to those UUIDs only; warn for any
  user-listed UUID that produced no `D`-type entry.
- If `m.outages` is empty, auto-discover. Honor `"include_planned_outages"` on
  `m`'s attributes (default `false`) — `PlannedOutage`s are skipped on the
  auto-discover path unless the attribute is `true`.

The monitored set is exactly what each outage lists in its
`monitored_components`; an outage with empty `monitored_components` is treated
as "monitor nothing" (a warning is emitted). A monitored component whose type
is not a modeled `PSY.ACTransmission` branch type is reported once per type and
skipped.
"""
function _build_device_model_outages!(
    template::IOM.AbstractProblemTemplate,
    sys::PSY.System,
)
    sc_models = _sc_branch_models(template)
    isempty(sc_models) && return

    modeled_types = Set{DataType}(get_component_types(template))
    selection = _take_outage_selection!(sc_models)
    uncovered_types = Dict{DataType, Set{Base.UUID}}()

    for outage in PSY.get_supplemental_attributes(PSY.Outage, sys)
        outage_uuid = IS.get_uuid(outage)
        if isempty(PSY.get_monitored_components(outage))
            @warn "Outage $(outage_uuid) ($(typeof(outage))) has empty \
                   monitored_components; no post-contingency variables or \
                   constraints will be created for this outage." _group =
                IOM.LOG_GROUP_MODELS_VALIDATION
            continue
        end

        per_type, uncovered =
            _monitored_components_by_modeled_type(outage, outage_uuid, sys, modeled_types)
        for comp_type in uncovered
            push!(get!(uncovered_types, comp_type, Set{Base.UUID}()), outage_uuid)
        end
        isempty(per_type) && continue

        attached_types = _attached_component_types(outage, sys)
        covered = _assign_outage_to_sc_models!(
            sc_models,
            selection,
            outage,
            outage_uuid,
            per_type,
            attached_types,
        )
        if !covered
            @warn "Outage $(outage_uuid) is attached to component(s) of \
                   type $(collect(attached_types)), but no DeviceModel with \
                   an AbstractSecurityConstrainedStaticBranch formulation \
                   covers those types; it will not contribute any \
                   post-contingency constraints." _group =
                IOM.LOG_GROUP_MODELS_VALIDATION
        end
    end

    _warn_uncovered_monitored_types(uncovered_types)
    _warn_unmatched_user_outages(sc_models, selection)
    return
end

# SC branch device models in the template.
function _sc_branch_models(template::IOM.AbstractProblemTemplate)
    return IOM.DeviceModelForBranches[
        m for m in values(get_branch_models(template)) if
        get_formulation(m) <: AbstractSecurityConstrainedStaticBranch
    ]
end

"""
Populate `service_model.outages` for every security-constrained (SC) reserve
`ServiceModel` in the template, in a single pass over each SC service model.

The user opts a service into responding to a given contingency by attaching
the outage supplemental attribute to the `PSY.Service` instance directly
(`add_supplemental_attribute!(sys, service, outage)`). That attachment is the
sole selection mechanism: a service claims exactly the outages attached to it,
regardless of whether the outaged component is among the service's contributing
devices.

`PlannedOutage`s attached to the service are still gated by the
`"include_planned_outages"` attribute on the SC `ServiceModel` (default
`false`); other `Outage` subtypes are always claimed.
"""
function _build_service_model_outages!(
    template::IOM.AbstractProblemTemplate,
    sys::PSY.System,
)
    sc_service_models = _sc_reserve_service_models(template)
    template_sc_service_keys = Set{Tuple{DataType, String}}(
        (get_component_type(m), get_service_name(m)) for m in sc_service_models
    )
    # Run the orphan-attachment check unconditionally so users still get
    # feedback when they attached outages to a service whose SC `ServiceModel`
    # was never registered.
    _warn_outages_attached_to_unmodeled_services(sys, template_sc_service_keys)

    isempty(sc_service_models) && return

    modeled_types = Set{DataType}(get_component_types(template))
    uncovered_types = Dict{DataType, Set{Base.UUID}}()

    for m in sc_service_models
        empty!(get_outages(m))
        D = get_component_type(m)
        service_name = get_service_name(m)
        service = PSY.get_component(D, sys, service_name)
        if service === nothing
            @warn "ServiceModel{$D, $(get_formulation(m))} (service_name=\
                   $(service_name)) is in the template but no matching service \
                   exists in the system; it will not contribute any \
                   post-contingency constraints." _group =
                IOM.LOG_GROUP_MODELS_VALIDATION
            continue
        end

        for outage in PSY.get_supplemental_attributes(PSY.Outage, service)
            outage_uuid = IS.get_uuid(outage)
            if isempty(PSY.get_monitored_components(outage))
                @warn "Outage $(outage_uuid) ($(typeof(outage))) attached to \
                       service $(service_name) has empty monitored_components; \
                       no post-contingency variables or constraints will be \
                       created for this outage." _group =
                    IOM.LOG_GROUP_MODELS_VALIDATION
                continue
            end
            _service_skips_outage(outage, m) && continue

            per_type, uncovered = _monitored_components_by_modeled_type(
                outage, outage_uuid, sys, modeled_types,
            )
            for comp_type in uncovered
                push!(get!(uncovered_types, comp_type, Set{Base.UUID}()), outage_uuid)
            end
            isempty(per_type) && continue
            get_outages(m)[outage_uuid] = per_type
        end
    end

    _warn_uncovered_monitored_types(uncovered_types)
    return
end

# SC reserve service models in the template.
function _sc_reserve_service_models(template::IOM.AbstractProblemTemplate)
    return ServiceModel[
        m for m in values(get_service_models(template)) if
        get_formulation(m) <: AbstractSecurityConstrainedReservesFormulation
    ]
end

_service_skips_outage(::PSY.Outage, ::ServiceModel) = false
_service_skips_outage(::PSY.PlannedOutage, m::ServiceModel) =
    get_attribute(m, "include_planned_outages") !== true

function _warn_outages_attached_to_unmodeled_services(
    sys::PSY.System,
    template_sc_service_keys::Set{Tuple{DataType, String}},
)
    for service in PSY.get_components(PSY.Service, sys)
        attached_outages = PSY.get_supplemental_attributes(PSY.Outage, service)
        isempty(attached_outages) && continue
        key = (typeof(service), PSY.get_name(service))
        key in template_sc_service_keys && continue
        for outage in attached_outages
            @warn "Outage $(IS.get_uuid(outage)) is attached to service \
                   $(PSY.get_name(service)) ($(typeof(service))) but the \
                   template does not include a security-constrained \
                   ServiceModel for it; the outage will not contribute any \
                   post-contingency reserve constraints." _group =
                IOM.LOG_GROUP_MODELS_VALIDATION
        end
    end
    return
end

# Per SC-model component type, the user's explicit outage-UUID allow-list from
# the constructor kwarg: a non-empty set restricts auto-discovery to those
# UUIDs; an empty set means auto-discover all. Clears `m.outages` so the main
# pass can repopulate it; the cleared UUIDs survive in the returned map.
function _take_outage_selection!(sc_models::Vector{<:IOM.DeviceModelForBranches})
    selection = Dict{Symbol, Set{Base.UUID}}()
    for m in sc_models
        selection[nameof(get_component_type(m))] = Set{Base.UUID}(keys(get_outages(m)))
        empty!(get_outages(m))
    end
    return selection
end

# Monitored-component names grouped by their concrete (modeled) type. Returns
# `(per_type, uncovered)` where `uncovered` is the set of monitored component
# types the template does not model.
function _monitored_components_by_modeled_type(
    outage::PSY.Outage,
    outage_uuid::Base.UUID,
    sys::PSY.System,
    modeled_types::Set{DataType},
)
    per_type = Dict{DataType, Set{String}}()
    uncovered = Set{DataType}()
    for uuid in PSY.get_monitored_components(outage)
        component = IS.get_component(sys, uuid)
        if isnothing(component)
            @warn "Outage $(outage_uuid) references monitored component \
                   UUID $(uuid) that is not present in the system; \
                   skipping." _group = IOM.LOG_GROUP_MODELS_VALIDATION
            continue
        end
        comp_type = typeof(component)
        # `PSY.AreaInterchange` is admitted alongside `PSY.ACTransmission` so the
        # AreaBalance service-side builder can pick it up; anything else is routed
        # to the skip path (it would `KeyError` in the arc-resolution maps).
        admissible = (comp_type <: PSY.ACTransmission || comp_type <: PSY.AreaInterchange)
        if admissible && comp_type in modeled_types
            push!(get!(per_type, comp_type, Set{String}()), PSY.get_name(component))
        else
            push!(uncovered, comp_type)
        end
    end
    return per_type, uncovered
end

function _attached_component_types(outage::PSY.Outage, sys::PSY.System)
    return Set{DataType}(
        typeof(c) for c in PSY.get_associated_components(sys, outage)
    )
end

# Whether SC model `m` claims `outage`. `sel` is `m`'s component-type slice of
# the user's explicit outage allow-list: non-empty restricts to those UUIDs;
# empty means auto-discover (claim all, skipping `PlannedOutage`s unless the
# model opts in via the `"include_planned_outages"` attribute).
function _sc_model_claims_outage(
    m::IOM.DeviceModelForBranches,
    outage::PSY.Outage,
    outage_uuid::Base.UUID,
    sel::Set{Base.UUID},
)
    isempty(sel) || return outage_uuid in sel
    if outage isa PSY.PlannedOutage
        return get_attribute(m, "include_planned_outages") === true
    end
    return true
end

# Assign `per_type` to every SC model whose component type is among the outage's
# attached types and that claims the outage. Returns whether any SC model
# covered an attached type.
function _assign_outage_to_sc_models!(
    sc_models::Vector{<:IOM.DeviceModelForBranches},
    selection::Dict{Symbol, Set{Base.UUID}},
    outage::PSY.Outage,
    outage_uuid::Base.UUID,
    per_type::Dict{DataType, Set{String}},
    attached_types::Set{DataType},
)
    covered = false
    for m in sc_models
        D = get_component_type(m)
        D in attached_types || continue
        covered = true
        if _sc_model_claims_outage(m, outage, outage_uuid, selection[nameof(D)])
            get_outages(m)[outage_uuid] = per_type
        end
    end
    return covered
end

function _warn_uncovered_monitored_types(
    uncovered_types::Dict{DataType, Set{Base.UUID}},
)
    for (comp_type, offending) in uncovered_types
        @warn "Monitored components of type $(comp_type) appear in outages \
               $(collect(offending)) but $(comp_type) is not a modeled \
               ACTransmission branch type; their post-contingency variables \
               will be skipped." _group = IOM.LOG_GROUP_MODELS_VALIDATION
    end
    return
end

function _warn_unmatched_user_outages(
    sc_models::Vector{<:IOM.DeviceModelForBranches},
    selection::Dict{Symbol, Set{Base.UUID}},
)
    for m in sc_models
        D = get_component_type(m)
        sel = selection[nameof(D)]
        isempty(sel) && continue
        for uuid in sel
            haskey(get_outages(m), uuid) && continue
            @warn "Outage $(uuid) listed on DeviceModel{$D, \
                   $(get_formulation(m))} is not attached to a component \
                   of type $D in the system — it will not contribute any \
                   post-contingency constraints." _group =
                IOM.LOG_GROUP_MODELS_VALIDATION
        end
    end
    return
end
