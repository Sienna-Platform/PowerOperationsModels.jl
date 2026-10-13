#################################################################################
# Compact linear cost: the offset `slope * Pmin_t * u_t`
# The compact power is `Pmin_t * u_t + dp_t`. The generic IOM method prices `slope * dp_t`.
# These methods add `slope * Pmin_t * u_t` to the same cost expression. The time series
# fuel path already prices `FuelConsumptionExpression`, which has this term.
#################################################################################

const _StatusColumn = Union{Vector{Float64}, Vector{JuMP.VariableRef}}

# The status values at each step, read behind a barrier so the loop sees the array type.
function _status_column(status, name::String, time_steps)
    return [status[name, t] for t in time_steps]
end

# The on status at each step: the `OnVariable`, or the constant 1 for a must-run unit.
function _compact_on_status(
    container::OptimizationContainer,
    d::V,
    ::Type{<:AbstractCompactUnitCommitment},
)::_StatusColumn where {V <: PSY.ThermalGen}
    time_steps = get_time_steps(container)
    if _is_must_run(d)
        return fill(1.0, length(time_steps))
    end
    return _status_column(
        get_variable(container, OnVariable, V),
        PSY.get_name(d),
        time_steps,
    )
end

# The on status is the `OnStatusParameter` when present. Otherwise it is the constant 1.
# The parameter array holds numbers, or variables in a model built for recurrent solves.
function _compact_on_status(
    container::OptimizationContainer,
    d::V,
    ::Type{ThermalCompactDispatch},
)::_StatusColumn where {V <: PSY.ThermalGen}
    time_steps = get_time_steps(container)
    name = PSY.get_name(d)
    if name in _on_status_names(container, V)
        return _status_column(
            get_parameter_array(container, OnStatusParameter, V),
            name,
            time_steps,
        )
    end
    return fill(1.0, length(time_steps))
end

function _add_min_power_proportional_cost!(
    container::OptimizationContainer,
    d::V,
    ::Type{U},
    cost_term::Float64,
    power_units::IS.AbstractUnitSystem,
    multiplier::Float64,
) where {V <: PSY.ThermalGen, U <: AbstractDeviceFormulation}
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
            container, status[t], rate * pmin[t], FuelCostExpression, V, name, t)
    end
    return
end

const _CompactCostCurve =
    Union{PSY.CostCurve{IS.LinearCurve}, PSY.CostCurve{IS.QuadraticCurve}}
const _CompactFuelCurve =
    Union{PSY.FuelCurve{IS.LinearCurve}, PSY.FuelCurve{IS.QuadraticCurve}}

_curve_function_data(cost_function::Union{_CompactCostCurve, _CompactFuelCurve}) =
    IS.get_function_data(IS.get_value_curve(cost_function))

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
    cost_function::_CompactCostCurve,
    ::Type{U},
) where {
    T <: PowerAboveMinimumVariable,
    V <: PSY.ThermalGen,
    U <: AbstractDeviceFormulation,
}
    data = _curve_function_data(cost_function)
    _check_compact_quadratic_term(PSY.get_name(component), data)
    _add_generic_variable_cost!(container, T, component, cost_function, U)
    _add_min_power_proportional_cost!(
        container,
        component,
        U,
        IS.get_proportional_term(data),
        IS.get_power_units(cost_function),
        objective_function_multiplier(T, U),
    )
    return
end

function _add_compact_fuel_curve!(
    container::OptimizationContainer,
    ::Type{T},
    component::V,
    cost_function::_CompactFuelCurve,
    ::Type{U},
) where {
    T <: PowerAboveMinimumVariable,
    V <: PSY.ThermalGen,
    U <: AbstractDeviceFormulation,
}
    data = _curve_function_data(cost_function)
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
        )
    end
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
        return PSY.get_max_active_power(component, u"SU")
    param_container = get_parameter(container, ActivePowerTimeSeriesParameter, C)
    multiplier = get_multiplier_array(param_container)
    # The container can exist for type `C` while this particular device has no
    # time-series entry (mixed TS / no-TS devices of the same type). Fall back to
    # the static max in that case rather than indexing into a missing row.
    name ∈ axes(multiplier, 1) ||
        return PSY.get_max_active_power(component, u"SU")
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
    device_base_power = PSY.get_base_power(component, u"NU")
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
    for t in get_time_steps(container)
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
    ::OptimizationContainer, ::Type{<:VariableType}, ::PSY.RenewableGen,
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
Iterate the device set and route each renewable's `curtailment_cost` into
`CurtailmentCostExpression`. Devices whose operation cost has no `curtailment_cost`
field, or where the field is `nothing`, are skipped.
"""
function add_curtailment_cost!(
    container::OptimizationContainer,
    ::Type{T},
    devices::Vector{V},
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
