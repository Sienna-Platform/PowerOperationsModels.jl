function get_default_time_series_names(
    ::Type{PSY.ConstantReserveGroup{T}},
    ::Type{GroupReserve}) where {T <: PSY.ReserveDirection}
    return Dict{String, Any}()
end

function get_default_attributes(
    ::Type{PSY.ConstantReserveGroup{T}},
    ::Type{GroupReserve}) where {T <: PSY.ReserveDirection}
    return Dict{String, Any}()
end

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
        variable = get_variable(container, ActivePowerReserveVariable, typeof(service))
        # Merged container is keyed `(service_name, device_name, time)`; confirm this
        # contributing service actually has entries rather than just that the container
        # for the type exists.
        any(k -> k[1] == service_name, keys(variable.data)) || error(
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
    model::ServiceModel{SR, GroupReserve},
) where {SR <: PSY.ConstantReserveGroup}
    time_steps = get_time_steps(container)
    service_name = PSY.get_name(service)
    # Merged 2D sparse group-requirement container keyed `(group_name, time)`.
    constraint = lazy_container_addition!(container, RequirementConstraint, SR,
        [service_name],
        time_steps;
        sparse = true,
    )
    # Each contributing reserve's provision comes from its type's merged
    # `(service_name, device_name, time)` container; sum the contributing service's slice.
    contributing = [
        (r, PSY.get_name(r),
            get_variable(container, ActivePowerReserveVariable, typeof(r)))
        for r in contributing_services
    ]

    requirement = _get_requirement(service)
    for t in time_steps
        resource_expression = JuMP.GenericAffExpr{Float64, JuMP.VariableRef}()
        for (r, r_name, reserve_variable) in contributing
            for (key, var) in reserve_variable.data
                key[1] == r_name && key[3] == t || continue
                JuMP.add_to_expression!(resource_expression, var)
            end
        end
        constraint[(service_name, t)] =
            JuMP.@constraint(container.JuMPmodel, resource_expression >= requirement)
    end

    return
end
