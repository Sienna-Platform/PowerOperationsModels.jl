function add_variable_cost_to_objective!(
    ::OptimizationContainer,
    ::T,
    component::PSY.Component,
    cost_function::PSY.CostCurve{IS.QuadraticCurve},
    ::U,
) where {
    T <: PowerAboveMinimumVariable,
    U <: Union{AbstractCompactUnitCommitment, ThermalCompactDispatch},
}
    throw(
        IS.ConflictingInputsError(
            "Quadratic Cost Curves are not compatible with Compact formulations",
        ),
    )
    return
end

#################################################################################
# Curtailment cost for renewable generation
# Renewables can specify a `curtailment_cost` field on their operation cost; this
# captures the dollar value of unprovided available power per timestep:
#     cost(t) = price * dt * (offer_max(t) - dispatch(t))
# Routed to `CurtailmentCostExpression` (a direct `CostExpressions` subtype, not a
# `ConstituentCostExpression`), so it is reported standalone and does NOT propagate
# into `ProductionCostExpression`.
#################################################################################

# Resolve the operating-point upper bound for a renewable at time t. Falls back to the
# device's static max_active_power when no time-series parameter has been registered.
function _renewable_offer_max(
    container::OptimizationContainer,
    component::C,
    name::String,
    t::Int,
) where {C <: PSY.RenewableGen}
    has_container_key(container, ActivePowerTimeSeriesParameter, C) ||
        return PSY.get_max_active_power(component)
    param_container = get_parameter(container, ActivePowerTimeSeriesParameter, C)
    multiplier = get_multiplier_array(param_container)
    return get_parameter_column_refs(param_container, name)[t] * multiplier[name, t]
end

# Cost-curve-shape dispatch. LinearCurve is the supported case; other shapes are
# silently skipped (PSI's PR only implemented the LinearCurve branch).
function _add_curtailment_cost!(
    container::OptimizationContainer,
    ::Type{T},
    component::C,
    cost_function::PSY.CostCurve{PSY.LinearCurve},
    ::Type{U},
) where {T <: VariableType, C <: PSY.RenewableGen, U <: AbstractDeviceFormulation}
    base_power = get_model_base_power(container)
    device_base_power = PSY.get_base_power(component)
    value_curve = PSY.get_value_curve(cost_function)
    power_units = PSY.get_power_units(cost_function)
    cost_component = PSY.get_function_data(value_curve)
    proportional_term = PSY.get_proportional_term(cost_component)
    iszero(proportional_term) && return

    proportional_term_per_unit = get_proportional_cost_per_system_unit(
        proportional_term, power_units, base_power, device_base_power,
    )
    resolution = get_resolution(container)
    dt = Dates.value(resolution) / MILLISECONDS_IN_HOUR
    name = PSY.get_name(component)
    dispatch_vars = get_variable(container, T, C)

    for t in get_time_steps(container)
        offer_max = _renewable_offer_max(container, component, name, t)
        dispatch = dispatch_vars[name, t]
        curtailment_cost = proportional_term_per_unit * dt * (offer_max - dispatch)
        add_to_expression!(
            container, CurtailmentCostExpression, curtailment_cost, component, t)
    end
    return
end

# Other cost-curve shapes don't have a defined curtailment-cost computation here;
# treat as no-op rather than erroring so renewables with PWL/other costs still build.
_add_curtailment_cost!(
    ::OptimizationContainer, ::Type{<:VariableType}, ::PSY.RenewableGen,
    ::PSY.OperationalCost, ::Type{<:AbstractDeviceFormulation}) = nothing

"""
Iterate the device set and route each renewable's `curtailment_cost` into
`CurtailmentCostExpression`. Devices whose operation cost has no `curtailment_cost`
field, or where the field is `nothing`, are skipped.
"""
function add_curtailment_cost!(
    container::OptimizationContainer,
    ::Type{T},
    devices::IS.FlattenIteratorWrapper{V},
    ::Type{U},
) where {T <: VariableType, V <: PSY.RenewableGen, U <: AbstractDeviceFormulation}
    for d in devices
        op_cost_data = PSY.get_operation_cost(d)
        hasproperty(op_cost_data, :curtailment_cost) || continue
        cost_function = PSY.get_curtailment_cost(op_cost_data)
        isnothing(cost_function) && continue
        _add_curtailment_cost!(container, T, d, cost_function, U)
    end
    return
end
