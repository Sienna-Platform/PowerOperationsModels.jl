#################################################################################
# Compact linear cost: the offset `slope * Pmin_t * u_t`
# The compact power is `Pmin_t * u_t + dp_t`. The generic IOM method prices `slope * dp_t`.
# These methods add `slope * Pmin_t * u_t` to the same cost expression. The time series
# fuel path already prices `FuelConsumptionExpression`, which has this term.
#################################################################################

# The on status at each step: the unit's own `OnVariable` under a commitment formulation,
# otherwise the `OnStatusParameter` scaled by the injector status when a feedforward provides
# it, and the injector status for a must-run unit or without the parameter.
function _compact_on_status(
    container::OptimizationContainer,
    d::PSY.ThermalGen,
    ::Type{F},
) where {F <: Union{AbstractCompactUnitCommitment, ThermalCompactDispatch}}
    return [
        IOM.get_on_status(container, F, d, t; commitment_first = true) for
        t in get_time_steps(container)
    ]
end

function _add_min_power_proportional_cost!(
    container::OptimizationContainer,
    d::V,
    ::Type{U},
    cost_term::Float64,
    power_units::IS.AbstractUnitSystem,
    multiplier::Float64,
    ::Type{E},
) where {V <: PSY.ThermalGen, U <: AbstractDeviceFormulation, E <: ExpressionType}
    iszero(cost_term) && return
    cost_per_unit = get_proportional_cost_per_system_unit(
        cost_term,
        power_units,
        get_model_base_power(container),
        PSY.get_base_power(d, u"NU"),
    )
    dt = Dates.value(get_resolution(container)) / MILLISECONDS_IN_HOUR
    rate = cost_per_unit * multiplier * dt
    name = PSY.get_name(d)
    pmin = min_active_power_values(container, d)
    status = _compact_on_status(container, d, U)
    for t in get_time_steps(container)
        iszero(pmin[t]) && continue
        IOM.add_cost_term_invariant!(
            container, status[t], rate * pmin[t], E, V, name, t)
    end
    return
end

# The offset term is linear in the status. A quadratic term would need `(Pmin_t u_t + dp_t)^2`.
function _check_compact_quadratic_term(name::String, data::IS.LinearFunctionData)
    return
end

function _check_compact_quadratic_term(name::String, data::IS.QuadraticFunctionData)
    if abs(IS.get_quadratic_term(data)) >= eps()
        throw(
            IS.ConflictingInputsError(
                "Quadratic Cost Curves are not compatible with Compact formulations: \
                $name has a nonzero quadratic term.",
            ),
        )
    end
    return
end

# The generic IOM method prices `slope * dp_t`. The methods below add the offset term.
function _add_generic_variable_cost!(
    container::OptimizationContainer,
    ::Type{T},
    component::IS.InfrastructureSystemsComponent,
    cost_function,
    ::Type{U},
) where {T <: PowerAboveMinimumVariable, U <: AbstractDeviceFormulation}
    invoke(
        add_variable_cost_to_objective!,
        Tuple{
            OptimizationContainer,
            Type{T},
            IS.InfrastructureSystemsComponent,
            typeof(cost_function),
            Type{U},
        },
        container, T, component, cost_function, U,
    )
    return
end

function _add_compact_cost_curve!(
    container::OptimizationContainer,
    ::Type{T},
    component::V,
    cost_function::PSY.CostCurve,
    ::Type{U},
) where {
    T <: PowerAboveMinimumVariable,
    V <: PSY.ThermalGen,
    U <: AbstractDeviceFormulation,
}
    data = IS.get_function_data(IS.get_value_curve(cost_function))
    _check_compact_quadratic_term(PSY.get_name(component), data)
    _add_generic_variable_cost!(container, T, component, cost_function, U)
    _add_min_power_proportional_cost!(
        container,
        component,
        U,
        IS.get_proportional_term(data),
        IS.get_power_units(cost_function),
        objective_function_multiplier(T, U),
        FuelCostExpression,
    )
    return
end

function _add_compact_fuel_curve!(
    container::OptimizationContainer,
    ::Type{T},
    component::V,
    cost_function::PSY.FuelCurve,
    ::Type{U},
) where {
    T <: PowerAboveMinimumVariable,
    V <: PSY.ThermalGen,
    U <: AbstractDeviceFormulation,
}
    data = IS.get_function_data(IS.get_value_curve(cost_function))
    _check_compact_quadratic_term(PSY.get_name(component), data)
    _add_generic_variable_cost!(container, T, component, cost_function, U)
    # A time series fuel cost is priced by `FuelConsumptionExpression`: no offset term here.
    if !IS.is_time_series_backed(cost_function)
        _add_min_power_proportional_cost!(
            container,
            component,
            U,
            IS.get_proportional_term(data),
            IS.get_power_units(cost_function),
            IS.get_fuel_cost(cost_function),
            FuelCostExpression,
        )
    end
    return
end

# The generic IOM method prices `vom * dp_t`. This method adds the VOM cost of `Pmin_t * u_t`.
function IOM.add_vom_cost_to_objective!(
    container::OptimizationContainer,
    ::Type{T},
    component::V,
    op_cost::PSY.ThermalGenerationCost,
    ::Type{U},
) where {
    T <: PowerAboveMinimumVariable,
    V <: PSY.ThermalGen,
    U <: Union{AbstractCompactUnitCommitment, ThermalCompactDispatch},
}
    variable_cost_data = IOM.variable_cost(op_cost, T, V, U)
    power_units = IS.get_power_units(variable_cost_data)
    vom_term = IS.get_proportional_term(IS.get_vom_cost(variable_cost_data))
    IOM.add_proportional_cost_invariant!(
        container, T, component, vom_term, power_units, 1.0, VOMCostExpression)
    _add_min_power_proportional_cost!(
        container, component, U, vom_term, power_units, 1.0, VOMCostExpression)
    return
end

function add_variable_cost_to_objective!(
    container::OptimizationContainer,
    ::Type{T},
    component::V,
    cost_function::PSY.CostCurve{IS.LinearCurve},
    ::Type{U},
) where {
    T <: PowerAboveMinimumVariable,
    V <: PSY.ThermalGen,
    U <: Union{AbstractCompactUnitCommitment, ThermalCompactDispatch},
}
    _add_compact_cost_curve!(container, T, component, cost_function, U)
    return
end

function add_variable_cost_to_objective!(
    container::OptimizationContainer,
    ::Type{T},
    component::V,
    cost_function::PSY.CostCurve{IS.QuadraticCurve},
    ::Type{U},
) where {
    T <: PowerAboveMinimumVariable,
    V <: PSY.ThermalGen,
    U <: Union{AbstractCompactUnitCommitment, ThermalCompactDispatch},
}
    _add_compact_cost_curve!(container, T, component, cost_function, U)
    return
end

function add_variable_cost_to_objective!(
    container::OptimizationContainer,
    ::Type{T},
    component::V,
    cost_function::PSY.FuelCurve{IS.LinearCurve},
    ::Type{U},
) where {
    T <: PowerAboveMinimumVariable,
    V <: PSY.ThermalGen,
    U <: Union{AbstractCompactUnitCommitment, ThermalCompactDispatch},
}
    _add_compact_fuel_curve!(container, T, component, cost_function, U)
    return
end

function add_variable_cost_to_objective!(
    container::OptimizationContainer,
    ::Type{T},
    component::V,
    cost_function::PSY.FuelCurve{IS.QuadraticCurve},
    ::Type{U},
) where {
    T <: PowerAboveMinimumVariable,
    V <: PSY.ThermalGen,
    U <: Union{AbstractCompactUnitCommitment, ThermalCompactDispatch},
}
    _add_compact_fuel_curve!(container, T, component, cost_function, U)
    return
end

#################################################################################
# Curtailment cost for renewable generation
# Renewables, and the renewable unit of a HybridSystem, can specify a `curtailment_cost`
# field on their operation cost. It is the dollar value of available power that is not
# dispatched in each time step:
#     cost(t) = price * dt * (offer_max(t) - dispatch(t))
# Routed to `CurtailmentCostExpression` (a direct `CostExpressions` subtype, not a
# `ConstituentCostExpression`), so it is reported standalone and does NOT propagate
# into `ProductionCostExpression`.
#################################################################################

_curtailment_unit(d::PSY.RenewableGen) = d
_curtailment_unit(d::PSY.HybridSystem) = PSY.get_renewable_unit(d)
_availability_parameter(::Type{<:PSY.RenewableGen}) = ActivePowerTimeSeriesParameter
_availability_parameter(::Type{<:PSY.HybridSystem}) =
    HybridRenewableActivePowerTimeSeriesParameter

# Resolve the operating-point upper bound for a renewable at time t. Falls back to the
# static max_active_power when no time-series parameter has been registered.
function _renewable_offer_max(
    container::OptimizationContainer,
    component::C,
    name::String,
    t::Int,
) where {C <: Union{PSY.RenewableGen, PSY.HybridSystem}}
    unit = _curtailment_unit(component)
    P = _availability_parameter(C)
    has_container_key(container, P, C) ||
        return PSY.get_max_active_power(unit, u"SU")
    param_container = get_parameter(container, P, C)
    multiplier = get_multiplier_array(param_container)
    # The container can exist for type `C` while this particular device has no
    # time-series entry (mixed TS / no-TS devices of the same type). Fall back to
    # the static max in that case rather than indexing into a missing row.
    name ∈ axes(multiplier, 1) ||
        return PSY.get_max_active_power(unit, u"SU")
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
) where {
    T <: VariableType,
    C <: Union{PSY.RenewableGen, PSY.HybridSystem},
    U <: AbstractDeviceFormulation,
}
    base_power = get_model_base_power(container)
    device_base_power = PSY.get_base_power(_curtailment_unit(component), u"NU")
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

    rate = proportional_term_per_unit * dt
    status = get_component_statuses(container, C)
    for t in get_time_steps(container)
        # An out unit offers nothing, so it has nothing to curtail.
        get_component_status(status, name, t) == 0.0 && continue
        offer_max = _renewable_offer_max(container, component, name, t)
        dispatch = dispatch_vars[name, t]
        IOM.add_cost_term_invariant!(
            container, offer_max - dispatch, rate,
            CurtailmentCostExpression, C, name, t,
        )
    end
    return
end

# Other cost-curve shapes don't have a defined curtailment-cost computation here;
# treat as no-op rather than erroring so renewables with PWL/other costs still build.
_add_curtailment_cost!(
    ::OptimizationContainer, ::Type{<:VariableType},
    ::Union{PSY.RenewableGen, PSY.HybridSystem},
    ::PSY.OperationalCost, ::Type{<:AbstractDeviceFormulation}) = nothing

#################################################################################
# Unit-commitment OnVariable proportional cost
#################################################################################

# Covers thermal + hydro UC OnVariable costs: route through the time-variant-capable
# path so MarketBidCost/MarketBidTimeSeriesCost dispatch to the generic OnVariable
# methods in common_models/market_bid_overrides.jl, while static *GenerationCost types
# resolve to the 6-arg `proportional_cost` methods in the device files.
# ControllableLoad/PowerLoadInterruption has its own forwarder in
# static_injector_models/electric_loads.jl.
add_proportional_cost!(
    container::OptimizationContainer,
    ::Type{U},
    devices::Vector{T},
    ::Type{V},
) where {
    U <: OnVariable,
    T <: Union{PSY.ThermalGen, PSY.HydroGen},
    V <: Union{AbstractThermalFormulation, AbstractHydroFormulation},
} = add_proportional_cost_maybe_time_variant!(container, U, devices, V)

"""
Iterate the device set and route the `curtailment_cost` of each renewable, or of each
hybrid renewable unit, into `CurtailmentCostExpression`. Devices whose operation cost has no `curtailment_cost`
field, or where the field is `nothing`, are skipped.
"""
function add_curtailment_cost!(
    container::OptimizationContainer,
    ::Type{T},
    devices::Vector{V},
    ::Type{U},
) where {
    T <: VariableType,
    V <: Union{PSY.RenewableGen, PSY.HybridSystem},
    U <: AbstractDeviceFormulation,
}
    for d in devices
        op_cost_data = PSY.get_operation_cost(_curtailment_unit(d))
        hasproperty(op_cost_data, :curtailment_cost) || continue
        cost_function = PSY.get_curtailment_cost(op_cost_data)
        isnothing(cost_function) && continue
        _add_curtailment_cost!(container, T, d, cost_function, U)
    end
    return
end
