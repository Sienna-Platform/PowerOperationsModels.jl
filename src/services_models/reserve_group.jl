function get_default_time_series_names(
    ::Type{PSY.GroupReserve{T}},
    ::Type{GroupRangeReserve}) where {T <: PSY.ReserveDirection}
    return Dict{String, Any}()
end

function get_default_attributes(
    ::Type{PSY.GroupReserve{T}},
    ::Type{GroupRangeReserve}) where {T <: PSY.ReserveDirection}
    return Dict{String, Any}()
end

function get_default_time_series_names(
    ::Type{PSY.GroupReserve{T}},
    ::Type{GroupStepwiseCostReserve}) where {T <: PSY.ReserveDirection}
    return Dict{String, Any}()
end

function get_default_attributes(
    ::Type{PSY.GroupReserve{T}},
    ::Type{GroupStepwiseCostReserve}) where {T <: PSY.ReserveDirection}
    return Dict{String, Any}()
end

# ── Formulation-pairing guards ────────────────────────────────────────────────────────
# A `PSY.GroupReserve` aggregates other services, so only group formulations can model it,
# and group formulations can model nothing else. These fallbacks fire inside the
# `ServiceModel` constructor (which resolves the default names/attributes), so a mis-paired
# model fails at DECLARATION with an actionable message instead of a cryptic dispatch error
# (or a silent no-op) at build time. The valid direction-applied pairs above are more
# specific and win.
const _GROUP_FORMULATIONS = Union{GroupRangeReserve, GroupStepwiseCostReserve}

function _throw_group_pairing_error(D::Type, B::Type)
    throw(
        ArgumentError(
            "ServiceModel($(D), $(B)) is invalid: `PSY.GroupReserve` aggregates other \
            services and must use a group formulation (GroupRangeReserve or \
            GroupStepwiseCostReserve), and group formulations apply only to \
            `PSY.GroupReserve`.",
        ),
    )
end

get_default_time_series_names(
    ::Type{D},
    ::Type{B},
) where {D <: PSY.GroupReserve, B <: AbstractServiceFormulation} =
    _throw_group_pairing_error(D, B)

get_default_attributes(
    ::Type{D},
    ::Type{B},
) where {D <: PSY.GroupReserve, B <: AbstractServiceFormulation} =
    _throw_group_pairing_error(D, B)

# Disambiguates the guard above against the generic reserve defaults
# (`T <: AbstractReserve, B <: AbstractReservesFormulation`), which a group would
# otherwise tie with now that `GroupReserve <: AbstractReserve`.
get_default_time_series_names(
    ::Type{D},
    ::Type{B},
) where {D <: PSY.GroupReserve, B <: AbstractReservesFormulation} =
    _throw_group_pairing_error(D, B)

get_default_attributes(
    ::Type{D},
    ::Type{B},
) where {D <: PSY.GroupReserve, B <: AbstractReservesFormulation} =
    _throw_group_pairing_error(D, B)

get_default_time_series_names(
    ::Type{D},
    ::Type{B},
) where {D <: PSY.AbstractReserve, B <: _GROUP_FORMULATIONS} =
    _throw_group_pairing_error(D, B)

get_default_attributes(
    ::Type{D},
    ::Type{B},
) where {D <: PSY.AbstractReserve, B <: _GROUP_FORMULATIONS} =
    _throw_group_pairing_error(D, B)

# Disambiguates against the `OfflineReserve` "offline_only" default: the pairing still errors.
get_default_attributes(
    ::Type{PSY.OfflineReserve},
    ::Type{B},
) where {B <: _GROUP_FORMULATIONS} = _throw_group_pairing_error(PSY.OfflineReserve, B)

# Disambiguates the two guards' intersection (`GroupReserve <: AbstractReserve`) and gives
# the bare-type declaration an actionable message.
_throw_group_direction_error(D::Type, B::Type) = throw(
    ArgumentError(
        "ServiceModel($(D), $(B)) needs the reserve direction applied, \
        e.g. `ServiceModel(GroupReserve{ReserveUp}, $(B))`.",
    ),
)

get_default_time_series_names(
    ::Type{D},
    ::Type{B},
) where {D <: PSY.GroupReserve, B <: _GROUP_FORMULATIONS} =
    _throw_group_direction_error(D, B)

get_default_attributes(
    ::Type{D},
    ::Type{B},
) where {D <: PSY.GroupReserve, B <: _GROUP_FORMULATIONS} =
    _throw_group_direction_error(D, B)

############################### Reserve Variables` #########################################
"""
This function checks if the variables for reserves were created
"""
function check_activeservice_variables(
    container::OptimizationContainer,
    contributing_services::Vector{T},
) where {T <: PSY.Service}
    for service in contributing_services
        service_name = PSY.get_name(service)
        # Containers are keyed `(service_name, device_name, time)` and shared by the whole
        # service type, so check for this service's own entries, not just that one exists.
        has_entries = any(
            variable -> any(k -> k[1] == service_name, keys(variable.data)),
            _reserve_variables(container, typeof(service)),
        )
        has_entries || error(
            "The contributing service $service_name has no ActivePowerReserveVariable \
             entries; it must be modeled before the group reserve that references it.",
        )
    end
    return
end

################################## Reserve Requirement Constraint ##########################
"""
This function creates the requirement constraint that will be attained by the appropriate services
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{RequirementConstraint},
    service::SR,
    contributing_services::Vector{<:PSY.Service},
    model::ServiceModel{SR, GroupRangeReserve},
) where {SR <: PSY.GroupReserve}
    time_steps = get_time_steps(container)
    service_name = PSY.get_name(service)
    # Dense container keyed `[group_name, time]`, built per type; fill this group's row.
    constraint = get_constraint(container, RequirementConstraint, SR)
    requirement = _get_requirement(service)

    # Bucket every contributing reserve's provision by time step in a single pass. The
    # constraint sums across all of them, so no per-service key is needed.
    member_vars = _group_member_variables(container, contributing_services, time_steps)
    jump_model = get_jump_model(container)

    for t in time_steps
        vars = member_vars[t]
        resource_expression = IOM.get_hinted_aff_expr(length(vars))
        for var in vars
            JuMP.add_to_expression!(resource_expression, var)
        end
        constraint[service_name, t] =
            JuMP.@constraint(jump_model, resource_expression >= requirement)
    end

    return
end

################################ Group Stepwise (elastic) clearing ##########################
"""
Clearing constraint for [`GroupStepwiseCostReserve`](@ref): the summed member awards cover the
group's `ServiceRequirementVariable` (the demand bought along the group's curve). Its dual is
the group clearing price.
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{RequirementConstraint},
    service::SR,
    contributing_services::Vector{<:PSY.Service},
    model::ServiceModel{SR, GroupStepwiseCostReserve},
) where {SR <: PSY.GroupReserve}
    time_steps = get_time_steps(container)
    service_name = PSY.get_name(service)
    constraint = get_constraint(container, RequirementConstraint, SR)
    requirement_variable = get_variable(container, ServiceRequirementVariable, SR)

    member_vars = _group_member_variables(container, contributing_services, time_steps)
    jump_model = get_jump_model(container)

    for t in time_steps
        vars = member_vars[t]
        resource_expression = IOM.get_hinted_aff_expr(length(vars))
        for var in vars
            JuMP.add_to_expression!(resource_expression, var)
        end
        constraint[service_name, t] = JuMP.@constraint(
            jump_model,
            resource_expression >= requirement_variable[service_name, t]
        )
    end

    return
end

# Collect the group's contributing reserve variables into one bucket per time step, so the
# constraint loop above indexes straight in rather than re-scanning per `(group, t)`. Services
# of the same type share their `(service_name, device_name, time)` containers, so each service
# type is scanned once.
function _group_member_variables(
    container::OptimizationContainer,
    contributing_services::Vector{<:PSY.Service},
    time_steps::UnitRange{Int},
)
    member_names = Set(PSY.get_name(r) for r in contributing_services)
    index = [JuMP.VariableRef[] for _ in time_steps]
    scanned = Set{DataType}()
    for r in contributing_services
        rtype = typeof(r)
        rtype in scanned && continue
        push!(scanned, rtype)
        for reserve_variable in _reserve_variables(container, rtype)
            for (key, var) in reserve_variable.data
                key[1] in member_names || continue
                push!(index[key[3]], var)
            end
        end
    end
    return index
end

# Award containers of every contributing device type for service type `SR`. Groups only know
# their member services, not the members' contributing device types. Keys store the service
# type with its unit parameter stripped, so match on that form.
function _reserve_variables(
    container::OptimizationContainer,
    ::Type{SR},
) where {SR <: PSY.Service}
    S = IOM.canonical_component_type(SR)
    return [
        variable for (key, variable) in IOM.get_variables(container) if
        IOM.get_entry_type(key) === ActivePowerReserveVariable &&
        get_component_type(key) <: IOM.ComponentPairKey{<:PSY.Component, S}
    ]
end
