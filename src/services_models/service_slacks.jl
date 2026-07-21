function reserve_slacks!(
    container::OptimizationContainer,
    service::T,
) where {T <: Union{PSY.Reserve, PSY.ReserveNonSpinning}}
    time_steps = get_time_steps(container)
    service_name = PSY.get_name(service)
    # Merged 2D sparse container keyed `(service_name, time)`, shared by all services of
    # the type; lazily created and filled per service.
    variable = lazy_container_addition!(container, ReserveRequirementSlack, T,
        [service_name], time_steps; sparse = true)

    for t in time_steps
        variable[(service_name, t)] = JuMP.@variable(
            get_jump_model(container),
            base_name = "slack_{$(service_name), $(t)}",
            lower_bound = 0.0
        )
        add_to_objective_invariant_expression!(
            container,
            variable[(service_name, t)] * SERVICES_SLACK_COST,
        )
    end
    return variable
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
