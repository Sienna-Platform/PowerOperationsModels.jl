#! format: off
############################### Reserve Variables #########################################

get_variable_multiplier(::Type{<:VariableType}, ::Type{<:PSY.Reserve}, ::Type{<:AbstractReservesFormulation}) = NaN
############################### ActivePowerReserveVariable, Reserve #########################################
get_variable_binary(::Type{ActivePowerReserveVariable}, ::Type{<:PSY.Reserve}, ::Type{<:AbstractReservesFormulation}) = false
function get_variable_upper_bound(::Type{ActivePowerReserveVariable}, r::PSY.Reserve, d::PSY.Device, ::Type{<:AbstractReservesFormulation})
    return PSY.get_max_output_fraction(r) * PSY.get_max_active_power(d, PSY.SU)
end
get_variable_upper_bound(::Type{ActivePowerReserveVariable}, r::Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve}, d::PSY.Device, ::Type{<:AbstractReservesFormulation}) = PSY.get_max_active_power(d, PSY.SU)
get_variable_lower_bound(::Type{ActivePowerReserveVariable}, ::PSY.Reserve, ::PSY.Device, ::Type) = 0.0

############################### ActivePowerReserveVariable, ReserveNonSpinning #########################################
get_variable_binary(::Type{ActivePowerReserveVariable}, ::Type{<:PSY.ReserveNonSpinning}, ::Type{<:AbstractReservesFormulation}) = false
function get_variable_upper_bound(::Type{ActivePowerReserveVariable}, r::PSY.ReserveNonSpinning, d::PSY.Device, ::Type{<:AbstractReservesFormulation})
    return PSY.get_max_output_fraction(r) * PSY.get_max_active_power(d, PSY.SU)
end
get_variable_lower_bound(::Type{ActivePowerReserveVariable}, ::PSY.ReserveNonSpinning, ::PSY.Device, ::Type) = 0.0

############################### ServiceRequirementVariable, ReserveDemandCurve ################################

get_variable_binary(::Type{ServiceRequirementVariable}, ::Type{<:Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve}}, ::Type{<:AbstractReservesFormulation}) = false
get_variable_upper_bound(::Type{ServiceRequirementVariable}, ::Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve}, d::PSY.Component, ::Type{<:AbstractReservesFormulation}) = PSY.get_max_active_power(d, PSY.SU)
get_variable_lower_bound(::Type{ServiceRequirementVariable}, ::Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve}, ::PSY.Component, ::Type{<:AbstractReservesFormulation}) = 0.0

# `VariableReserve` stores `requirement` as a dimensionless factor that scales its
# requirement and needs an explicit unit system (PS6 made the reserve requirement
# getter units-aware for every reserve type, including VariableReserve).
_get_requirement(service) = PSY.get_requirement(service, PSY.SU)

get_multiplier_value(::Type{RequirementTimeSeriesParameter}, d::PSY.Reserve, ::Type{<:AbstractReservesFormulation}) = _get_requirement(d)
get_multiplier_value(::Type{RequirementTimeSeriesParameter}, d::PSY.ReserveNonSpinning, ::Type{<:AbstractReservesFormulation}) = _get_requirement(d)

get_parameter_multiplier(::Type{<:VariableValueParameter}, d::Type{<:PSY.AbstractReserve}, ::Type{<:AbstractReservesFormulation}) = 1.0
get_initial_parameter_value(::Type{<:VariableValueParameter}, d::Type{<:PSY.AbstractReserve}, ::Type{<:AbstractReservesFormulation}) = 0.0

objective_function_multiplier(::Type{ServiceRequirementVariable}, ::Type{StepwiseCostReserve}) = -1.0
uses_compact_power(::Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve}, ::StepwiseCostReserve)=false
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve}, ::Type{<:AbstractReservesFormulation}) = 1.0
get_multiplier_value(::Type{<:AbstractPiecewiseLinearSlopeParameter}, ::Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve}, ::Type{<:AbstractReservesFormulation}) = 1.0
# ORDC demand curves are willingness-to-pay (concave), i.e. a decremental offer.
# Routes the reserve PWL cost path through IOM's OfferDirection dispatch; making
# this incremental is a one-line change here. Mirrors `_onvar_offer_direction` /
# `_vom_offer_direction` in market_bid_overrides.jl.
_reserve_offer_direction(::Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve}) = IOM.DecrementalOffer()
#! format: on

function get_initial_conditions_service_model(
    ::IOM.AbstractOptimizationModel,
    ::ServiceModel{T, D},
) where {T <: PSY.Reserve, D <: AbstractReservesFormulation}
    return ServiceModel(T, D)
end

function get_initial_conditions_service_model(
    ::IOM.AbstractOptimizationModel,
    ::ServiceModel{T, D},
) where {T <: PSY.VariableReserveNonSpinning, D <: AbstractReservesFormulation}
    return ServiceModel(T, D)
end

function get_default_time_series_names(
    ::Type{<:PSY.Reserve},
    ::Type{T},
) where {T <: Union{RangeReserve, RampReserve}}
    return Dict{Type{<:TimeSeriesParameter}, String}(
        RequirementTimeSeriesParameter => "requirement",
    )
end

# The returned name (`"requirement"`) is the exact `PSY` time-series name the
# requirement must be stored under on the service; the requirement is optional
# for security-constrained formulations (see `SecurityConstrainedContingencyReserve`).
function get_default_time_series_names(
    ::Type{<:PSY.Reserve},
    ::Type{<:AbstractSecurityConstrainedReservesFormulation},
)
    return Dict{Type{<:TimeSeriesParameter}, String}(
        RequirementTimeSeriesParameter => "requirement",
    )
end

function get_default_time_series_names(
    ::Type{<:PSY.ReserveNonSpinning},
    ::Type{NonSpinningReserve},
)
    return Dict{Type{<:TimeSeriesParameter}, String}(
        RequirementTimeSeriesParameter => "requirement",
    )
end

function get_default_time_series_names(
    ::Type{T},
    ::Type{<:AbstractReservesFormulation},
) where {T <: PSY.Reserve}
    return Dict{Type{<:TimeSeriesParameter}, String}()
end

function get_default_attributes(
    ::Type{<:PSY.Reserve},
    ::Type{<:AbstractReservesFormulation},
)
    return Dict{String, Any}()
end

function get_default_attributes(
    ::Type{<:PSY.ReserveNonSpinning},
    ::Type{<:AbstractReservesFormulation},
)
    return Dict{String, Any}()
end

"""
Add variables for ServiceRequirementVariable for StepWiseCostReserve
"""
function add_reserve_variables!(
    container::OptimizationContainer,
    ::Type{T},
    service::D,
    formulation,
) where {
    T <: ServiceRequirementVariable,
    D <: Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve},
}
    time_steps = get_time_steps(container)
    service_name = PSY.get_name(service)
    variable = add_variable_container!(
        container,
        T,
        D,
        [service_name],
        time_steps;
        meta = service_name,
    )

    for t in time_steps
        variable[service_name, t] = JuMP.@variable(
            get_jump_model(container),
            base_name = "$(T)_$(D)_$(service_name)_{$(service_name), $(t)}",
            lower_bound = 0.0,
        )
    end

    return
end

function _sum_reserve_variables(
    vars::AbstractArray{<:JuMP.AbstractVariableRef},
    extra::Int,
)
    acc = IOM.get_hinted_aff_expr(length(vars) + extra)
    for v in vars
        JuMP.add_to_expression!(acc, v)
    end
    return acc
end

################################## Reserve Requirement Constraint ##########################
function add_constraints!(
    container::OptimizationContainer,
    T::Type{RequirementConstraint},
    service::SR,
    ::U,
    model::ServiceModel{SR, V},
) where {
    SR <: PSY.AbstractReserve,
    V <: AbstractReservesFormulation,
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
} where {D <: PSY.Component}
    parameters = built_for_recurrent_solves(container)

    time_steps = get_time_steps(container)
    service_name = PSY.get_name(service)
    # TODO: Add a method for services that handles this better
    constraint = add_constraints_container!(container, T,
        SR,
        [service_name],
        time_steps;
        meta = service_name,
    )
    reserve_variable =
        get_variable(container, ActivePowerReserveVariable, SR, service_name)
    use_slacks = get_use_slacks(model)

    ts_vector = IOM.get_time_series(
        container,
        service,
        "requirement";
        interval = get_interval(get_settings(container)),
    )

    use_slacks && (slack_vars = reserve_slacks!(container, service))
    requirement = _get_requirement(service)
    jump_model = get_jump_model(container)
    extra = use_slacks ? 1 : 0
    if built_for_recurrent_solves(container)
        param_container =
            get_parameter(container, RequirementTimeSeriesParameter, SR, service_name)
        param = get_parameter_column_refs(param_container, service_name)
        for t in time_steps
            resource_expression =
                _sum_reserve_variables(@view(reserve_variable[:, t]), extra)
            use_slacks &&
                JuMP.add_to_expression!(resource_expression, slack_vars[t])
            constraint[service_name, t] =
                JuMP.@constraint(jump_model, resource_expression >= param[t] * requirement)
        end
    else
        for t in time_steps
            resource_expression =
                _sum_reserve_variables(@view(reserve_variable[:, t]), extra)
            use_slacks &&
                JuMP.add_to_expression!(resource_expression, slack_vars[t])
            constraint[service_name, t] = JuMP.@constraint(
                jump_model,
                resource_expression >= ts_vector[t] * requirement
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    T::Type{ParticipationFractionConstraint},
    service::SR,
    contributing_devices::U,
    ::ServiceModel{SR, V},
) where {
    SR <: PSY.AbstractReserve,
    V <: AbstractReservesFormulation,
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
} where {D <: PSY.Device}
    max_participation_factor = PSY.get_max_participation_factor(service)

    if max_participation_factor >= 1.0
        return
    end

    time_steps = get_time_steps(container)
    service_name = PSY.get_name(service)
    cons = add_constraints_container!(container, T,
        SR,
        [PSY.get_name(d) for d in contributing_devices],
        time_steps;
        meta = service_name,
    )
    var_r = get_variable(container, ActivePowerReserveVariable, SR, service_name)
    jump_model = get_jump_model(container)
    requirement = _get_requirement(service)
    ts_vector = IOM.get_time_series(
        container,
        service,
        "requirement";
        interval = get_interval(get_settings(container)),
    )
    param_container =
        get_parameter(container, RequirementTimeSeriesParameter, SR, service_name)
    param = get_parameter_column_refs(param_container, service_name)
    for t in time_steps, d in contributing_devices
        name = PSY.get_name(d)
        if built_for_recurrent_solves(container)
            cons[name, t] =
                JuMP.@constraint(
                    jump_model,
                    var_r[name, t] <= (requirement * max_participation_factor) * param[t]
                )
        else
            cons[name, t] = JuMP.@constraint(
                jump_model,
                var_r[name, t] <= (requirement * max_participation_factor) * ts_vector[t]
            )
        end
    end

    return
end

function add_constraints!(
    container::OptimizationContainer,
    T::Type{RequirementConstraint},
    service::SR,
    ::U,
    model::ServiceModel{SR, V},
) where {
    SR <: PSY.ConstantReserve,
    V <: AbstractReservesFormulation,
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
} where {D <: PSY.Component}
    time_steps = get_time_steps(container)
    service_name = PSY.get_name(service)
    # TODO: The constraint addition is still not clean enough
    constraint = add_constraints_container!(container, T,
        SR,
        [service_name],
        time_steps;
        meta = service_name,
    )
    reserve_variable =
        get_variable(container, ActivePowerReserveVariable, SR, service_name)
    use_slacks = get_use_slacks(model)
    use_slacks && (slack_vars = reserve_slacks!(container, service))

    requirement = _get_requirement(service)
    jump_model = get_jump_model(container)
    extra = use_slacks ? 1 : 0
    for t in time_steps
        resource_expression =
            _sum_reserve_variables(@view(reserve_variable[:, t]), extra)
        use_slacks && JuMP.add_to_expression!(resource_expression, slack_vars[t])
        constraint[service_name, t] =
            JuMP.@constraint(jump_model, resource_expression >= requirement)
    end

    return
end

function add_to_objective_function!(
    container::OptimizationContainer,
    service::SR,
    ::ServiceModel{SR, T},
) where {SR <: PSY.AbstractReserve, T <: AbstractReservesFormulation}
    add_reserves_proportional_cost!(container, ActivePowerReserveVariable, service, T)
    return
end

function add_constraints!(
    container::OptimizationContainer,
    T::Type{RequirementConstraint},
    service::SR,
    ::U,
    ::ServiceModel{SR, StepwiseCostReserve},
) where {
    SR <: Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve},
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
} where {D <: PSY.Component}
    time_steps = get_time_steps(container)
    service_name = PSY.get_name(service)
    constraint = add_constraints_container!(container, T,
        SR,
        [service_name],
        time_steps;
        meta = service_name,
    )
    reserve_variable =
        get_variable(container, ActivePowerReserveVariable, SR, service_name)
    requirement_variable =
        get_variable(container, ServiceRequirementVariable, SR, service_name)
    jump_model = get_jump_model(container)
    for t in time_steps
        constraint[service_name, t] = JuMP.@constraint(
            jump_model,
            sum(@view reserve_variable[:, t]) >= requirement_variable[service_name, t]
        )
    end

    return
end

_get_ramp_limits(::PSY.Component) = nothing
_get_ramp_limits(d::PSY.ThermalGen) = PSY.get_ramp_limits(d, PSY.SU)
_get_ramp_limits(d::PSY.HydroGen) = PSY.get_ramp_limits(d, PSY.SU)

function _get_ramp_constraint_contributing_devices(
    service::PSY.Reserve,
    contributing_devices::Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
) where {D <: PSY.Component}
    time_frame = PSY.get_time_frame(service)
    filtered_device = Vector{D}()
    for d in contributing_devices
        ramp_limits = _get_ramp_limits(d)
        if ramp_limits !== nothing
            p_lims = PSY.get_active_power_limits(d, PSY.SU)
            max_rate = abs(p_lims.min - p_lims.max) / time_frame
            if (ramp_limits.up >= max_rate) & (ramp_limits.down >= max_rate)
                @debug "Generator $(name) has a nonbinding ramp limits. Constraints Skipped"
                continue
            else
                push!(filtered_device, d)
            end
        end
    end
    return filtered_device
end

function add_constraints!(
    container::OptimizationContainer,
    T::Type{RampConstraint},
    service::SR,
    contributing_devices::Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    ::ServiceModel{SR, V},
) where {
    SR <: PSY.Reserve{PSY.ReserveUp},
    V <: AbstractReservesFormulation,
    D <: PSY.Component,
}
    ramp_devices = _get_ramp_constraint_contributing_devices(service, contributing_devices)
    service_name = PSY.get_name(service)
    if !isempty(ramp_devices)
        jump_model = get_jump_model(container)
        time_steps = get_time_steps(container)
        time_frame = PSY.get_time_frame(service)
        variable = get_variable(container, ActivePowerReserveVariable, SR, service_name)
        device_name_set = [PSY.get_name(d) for d in ramp_devices]
        con_up = add_constraints_container!(container, T,
            SR,
            device_name_set,
            time_steps;
            meta = service_name,
        )
        for d in ramp_devices, t in time_steps
            name = PSY.get_name(d)
            ramp_limits = PSY.get_ramp_limits(d, PSY.SU)
            con_up[name, t] = JuMP.@constraint(
                jump_model,
                variable[name, t] <= ramp_limits.up * time_frame
            )
        end
    else
        @warn "Data doesn't contain contributing devices with ramp limits for service $service_name, consider adjusting your formulation"
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    T::Type{RampConstraint},
    service::SR,
    contributing_devices::Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    ::ServiceModel{SR, V},
) where {
    SR <: PSY.Reserve{PSY.ReserveDown},
    V <: AbstractReservesFormulation,
    D <: PSY.Component,
}
    ramp_devices = _get_ramp_constraint_contributing_devices(service, contributing_devices)
    service_name = PSY.get_name(service)
    if !isempty(ramp_devices)
        jump_model = get_jump_model(container)
        time_steps = get_time_steps(container)
        time_frame = PSY.get_time_frame(service)
        variable = get_variable(container, ActivePowerReserveVariable, SR, service_name)
        device_name_set = [PSY.get_name(d) for d in ramp_devices]
        con_down = add_constraints_container!(container, T,
            SR,
            device_name_set,
            time_steps;
            meta = service_name,
        )
        for d in ramp_devices, t in time_steps
            name = PSY.get_name(d)
            ramp_limits = PSY.get_ramp_limits(d, PSY.SU)
            con_down[name, t] = JuMP.@constraint(
                jump_model,
                variable[name, t] <= ramp_limits.down * time_frame
            )
        end
    else
        @warn "Data doesn't contain contributing devices with ramp limits for service $service_name, consider adjusting your formulation"
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    T::Type{ReservePowerConstraint},
    service::SR,
    contributing_devices::U,
    ::ServiceModel{SR, V},
) where {
    SR <: PSY.VariableReserveNonSpinning,
    V <: AbstractReservesFormulation,
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
} where {D <: PSY.Component}
    time_steps = get_time_steps(container)
    resolution = get_resolution(container)
    if resolution > Dates.Minute(1)
        minutes_per_period = Dates.value(Dates.Minute(resolution))
    else
        @warn("Not all formulations support under 1-minute resolutions. Exercise caution.")
        minutes_per_period = Dates.value(Dates.Second(resolution)) / 60
    end
    service_name = PSY.get_name(service)
    cons = add_constraints_container!(container, T,
        SR,
        [PSY.get_name(d) for d in contributing_devices],
        time_steps;
        meta = service_name,
    )
    var_r = get_variable(container, ActivePowerReserveVariable, SR, service_name)
    reserve_response_time = PSY.get_time_frame(service)
    jump_model = get_jump_model(container)
    for d in contributing_devices
        # `contributing_devices` is flattened across every device type the
        # service applies to, so `typeof(d)` is runtime-only and this
        # `get_variable` dispatches dynamically. Hand the resulting `varstatus`
        # to a function barrier so the `t` loop runs fully specialized instead
        # of paying a dynamic dispatch on every iteration.
        component_type = typeof(d)
        name = PSY.get_name(d)
        varstatus = get_variable(container, OnVariable, component_type)
        startup_time = PSY.get_time_limits(d).up
        ramp_limits = _get_ramp_limits(d)
        if reserve_response_time > startup_time
            reserve_limit =
                PSY.get_active_power_limits(d, PSY.SU).min +
                (reserve_response_time - startup_time) * minutes_per_period * ramp_limits.up
        else
            reserve_limit = 0.0
        end
        _add_reserve_power_constraint_over_time!(
            cons, jump_model, var_r, varstatus, name, reserve_limit, time_steps,
        )
    end
    return
end

function _add_reserve_power_constraint_over_time!(
    cons,
    jump_model,
    var_r,
    varstatus,
    name::String,
    reserve_limit,
    time_steps,
)
    for t in time_steps
        cons[name, t] = JuMP.@constraint(
            jump_model,
            var_r[name, t] <= (1 - varstatus[name, t]) * reserve_limit
        )
    end
    return
end

function add_to_objective_function!(
    container::OptimizationContainer,
    service::S,
    ::ServiceModel{S, SR},
) where {
    S <: Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve},
    SR <: StepwiseCostReserve,
}
    add_reserves_variable_cost!(container, ServiceRequirementVariable, service, SR)
    return
end

# originally was add_variable_cost!, but I don't see other call sites besides the above.
function add_reserves_variable_cost!(
    container::OptimizationContainer,
    ::Type{U},
    service::T,
    ::Type{V},
) where {
    T <: Union{PSY.ReserveDemandCurve, PSY.ReserveDemandTimeSeriesCurve},
    U <: VariableType,
    V <: StepwiseCostReserve,
}
    _add_reserves_variable_cost_to_objective!(container, U, service, V)
    return
end

function _add_reserves_variable_cost_to_objective!(
    container::OptimizationContainer,
    ::Type{T},
    component::PSY.Reserve,
    ::Type{U},
) where {T <: VariableType, U <: StepwiseCostReserve}
    component_name = PSY.get_name(component)
    @debug "PWL Variable Cost" _group = LOG_GROUP_COST_FUNCTIONS component_name
    # If array is full of tuples with zeros return 0.0
    time_steps = get_time_steps(container)
    # FIXME clashes with name of a function...ick.
    variable_cost = PSY.get_variable(component)
    if variable_cost isa Nothing
        error("ORDC curve $(component_name) does not have cost data.")
    elseif !(variable_cost isa PSY.CostCurve)
        error(
            "ORDC curve $(component_name) has cost data of type $(typeof(variable_cost)), \
            but a `PSY.CostCurve` is required for the StepwiseCostReserve formulation.",
        )
    end

    # A time-series-backed cost varies across simulation steps and is read from
    # per-timestep parameter arrays, which are only populated for
    # `ReserveDemandTimeSeriesCurve` (see `process_stepwise_cost_reserve_parameters!`).
    # Reject a time-series-backed cost on any other reserve type up front, rather
    # than failing later with a missing-parameter error.
    is_t_variant = is_time_variant(variable_cost)
    if is_t_variant && !(component isa PSY.ReserveDemandTimeSeriesCurve)
        error(
            "ORDC curve $(component_name) of type $(typeof(component)) has a \
            time-series-backed cost; a `PSY.ReserveDemandTimeSeriesCurve` is required \
            for time-varying ORDC cost.",
        )
    end

    pwl_cost_expressions =
        add_pwl_term_delta!(container, component, variable_cost, T, U)
    for t in time_steps
        add_to_expression!(
            container,
            ProductionCostExpression,
            pwl_cost_expressions[t],
            component,
            t,
        )
        if is_t_variant
            IOM.add_to_objective_variant_expression!(container, pwl_cost_expressions[t])
        else
            add_to_objective_invariant_expression!(container, pwl_cost_expressions[t])
        end
    end
    return
end

"""
Add the decremental piecewise slope/breakpoint cost parameters for a time-varying
ORDC (`ReserveDemandTimeSeriesCurve`) service.
"""
function process_stepwise_cost_reserve_parameters!(
    container::OptimizationContainer,
    model::ServiceModel,
    service::D,
) where {D <: PSY.ReserveDemandTimeSeriesCurve}
    dir = _reserve_offer_direction(service)
    for param in (IOM._breakpoint_param(dir), IOM._slope_param(dir))
        add_parameters!(container, param, service, model)
    end
    return
end

function add_reserves_proportional_cost!(
    container::OptimizationContainer,
    ::Type{U},
    service::T,
    ::Type{V},
) where {
    T <: Union{PSY.Reserve, PSY.ReserveNonSpinning},
    U <: ActivePowerReserveVariable,
    V <: AbstractReservesFormulation,
}
    base_p = get_model_base_power(container)
    reserve_variable = get_variable(container, U, T, PSY.get_name(service))
    for index in Iterators.product(axes(reserve_variable)...)
        add_to_objective_invariant_expression!(
            container,
            # possibly decouple
            DEFAULT_RESERVE_COST / base_p * reserve_variable[index...],
        )
    end
    return
end
