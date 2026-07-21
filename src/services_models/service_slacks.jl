function add_reserve_slacks!(
    container::OptimizationContainer,
    ::Type{T},
    service_names::Vector{String},
) where {T <: Union{PSY.Reserve, PSY.ReserveNonSpinning}}
    time_steps = get_time_steps(container)
    # Dense 2D container keyed `[service_name, time]`, built once per service type over all
    # the type's services (`use_slacks` is per type). Lower bound 0, penalty in objective.
    variable = add_variable_container!(container, ReserveRequirementSlack, T,
        service_names, time_steps)

    jump_model = get_jump_model(container)
    for name in service_names, t in time_steps
        variable[name, t] = JuMP.@variable(
            jump_model,
            base_name = "slack_{$(name), $(t)}",
            lower_bound = 0.0
        )
        add_to_objective_invariant_expression!(
            container,
            variable[name, t] * SERVICES_SLACK_COST,
        )
    end
    return
end

function transmission_interface_slacks!(
    container::OptimizationContainer,
    service::T,
) where {T <: PSY.TransmissionInterface}
    time_steps = get_time_steps(container)
    name = PSY.get_name(service)

    for variable_type in [InterfaceFlowSlackUp, InterfaceFlowSlackDown]
        variable = add_variable_container!(
            container,
            variable_type,
            T,
            [name],
            time_steps;
            meta = name,
        )
        penalty = PSY.get_violation_penalty(service)
        for t in time_steps
            variable[name, t] = JuMP.@variable(
                get_jump_model(container),
                base_name = "$(T)_$(variable_type)_{$(name), $(t)}",
            )
            JuMP.set_lower_bound(variable[name, t], 0.0)

            add_to_objective_invariant_expression!(
                container,
                variable[name, t] * penalty,
            )
        end
    end

    return
end
