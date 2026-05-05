#################################################################################
# Expression container creation
# These create expression containers for devices and services
#################################################################################

function _ref_index(network_model::NetworkModel{<:AbstractPowerModel}, bus::PSY.ACBus)
    return get_reference_bus(network_model, bus)
end

function _ref_index(::NetworkModel{AreaPTDFPowerModel}, device_bus::PSY.ACBus)
    return PSY.get_name(PSY.get_area(device_bus))
end

_get_variable_if_exists(::PSY.MarketBidCost) = nothing
_get_variable_if_exists(cost::PSY.OperationalCost) = PSY.get_variable(cost)

# Predicates for fuel-curve detection. Dispatch over the value returned by
# `_get_variable_if_exists` so callers can avoid `isa` checks.
_is_fuel_curve(::Nothing) = false
_is_fuel_curve(::PSY.CostCurve) = false
_is_fuel_curve(::PSY.FuelCurve) = true

# Predicates for value-curve shape. Used to decide whether a FuelConsumptionExpression
# container needs JuMP.QuadExpr storage (vs the cheaper GAE).
_value_curve_is_quadratic(::PSY.LinearCurve) = false
_value_curve_is_quadratic(::PSY.QuadraticCurve) = true
_value_curve_is_quadratic(::PSY.PiecewisePointCurve) = false
_value_curve_is_quadratic(::PSY.IncrementalCurve) = false
_value_curve_is_quadratic(::PSY.AverageRateCurve) = false

function get_reference_bus(
    model::NetworkModel{T},
    b::PSY.ACBus,
)::Int where {T <: AbstractPowerModel}
    if isempty(model.bus_area_map)
        return first(keys(model.subnetworks))
    else
        return model.bus_area_map[b]
    end
end

"""
Generic implementation to add expression containers for devices.
"""
function add_expressions!(
    container::OptimizationContainer,
    ::Type{T},
    devices::U,
    model::DeviceModel{D, W},
) where {
    T <: ExpressionType,
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    W <: AbstractDeviceFormulation,
} where {D <: PSY.Component}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    add_expression_container!(container, T, D, names, time_steps)
    return
end

"""
Specialized implementation for FuelConsumptionExpression that checks for fuel curves.
"""
function add_expressions!(
    container::OptimizationContainer,
    ::Type{T},
    devices::U,
    model::DeviceModel{D, W},
) where {
    T <: FuelConsumptionExpression,
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    W <: AbstractDeviceFormulation,
} where {D <: PSY.Component}
    time_steps = get_time_steps(container)
    names = String[]
    found_quad_fuel_functions = false
    for d in devices
        fuel_curve = _get_variable_if_exists(PSY.get_operation_cost(d))
        _is_fuel_curve(fuel_curve) || continue
        push!(names, PSY.get_name(d))
        if !found_quad_fuel_functions
            found_quad_fuel_functions =
                _value_curve_is_quadratic(PSY.get_value_curve(fuel_curve))
        end
    end

    if !isempty(names)
        expr_type = found_quad_fuel_functions ? JuMP.QuadExpr : GAE
        add_expression_container!(container, T,
            D,
            names,
            time_steps;
            expr_type = expr_type,
        )
    end
    return
end

#################################################################################
# Cost expression bundles
# add_cost_expressions! sets up the full cost-expression containers for a given
# device type/formulation in one call. ThermalGen and RenewableGen overrides add
# their constituent cost expressions; the default falls back to ProductionCostExpression.
#################################################################################

"""
Default cost-expression setup: register only `ProductionCostExpression`.
"""
function add_cost_expressions!(
    container::OptimizationContainer,
    devices::U,
    model::DeviceModel{D, W},
) where {
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    W <: AbstractDeviceFormulation,
} where {D <: PSY.Component}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    add_expression_container!(container, ProductionCostExpression, D, names, time_steps)
    return
end

"""
Thermal generators get the full constituent decomposition. Constituent expressions
auto-propagate into `ProductionCostExpression` (see IOM `_propagate_to_production_cost!`),
so we register the aggregate as well as the parts. `FuelConsumptionExpression` is added
only when at least one device has a `FuelCurve`, mirroring the existing FuelConsumption
specialization.
"""
function add_cost_expressions!(
    container::OptimizationContainer,
    devices::U,
    model::DeviceModel{D, W},
) where {
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    W <: AbstractThermalFormulation,
} where {D <: PSY.ThermalGen}
    time_steps = get_time_steps(container)
    n = length(devices)
    all_names = Vector{String}(undef, n)
    fuel_names = sizehint!(String[], n)
    has_quad_fuel = false
    for (i, d) in enumerate(devices)
        name = PSY.get_name(d)
        all_names[i] = name
        fuel_curve = _get_variable_if_exists(PSY.get_operation_cost(d))
        _is_fuel_curve(fuel_curve) || continue
        push!(fuel_names, name)
        if !has_quad_fuel
            has_quad_fuel = _value_curve_is_quadratic(PSY.get_value_curve(fuel_curve))
        end
    end
    if !isempty(fuel_names)
        expr_type = has_quad_fuel ? JuMP.QuadExpr : GAE
        add_expression_container!(
            container, FuelConsumptionExpression, D, fuel_names, time_steps;
            expr_type = expr_type,
        )
    end
    add_expression_container!(container, ProductionCostExpression, D, all_names, time_steps)
    add_expression_container!(container, FuelCostExpression, D, all_names, time_steps)
    add_expression_container!(container, StartUpCostExpression, D, all_names, time_steps)
    add_expression_container!(container, ShutDownCostExpression, D, all_names, time_steps)
    add_expression_container!(container, FixedCostExpression, D, all_names, time_steps)
    add_expression_container!(container, VOMCostExpression, D, all_names, time_steps)
    return
end

"""
Renewable dispatch formulations track production cost, fixed cost, VOM cost, and
curtailment cost. `CurtailmentCostExpression` is a direct `CostExpressions` subtype
(not a `ConstituentCostExpression`), so it does not propagate into
`ProductionCostExpression` — curtailment is reported standalone.
"""
function add_cost_expressions!(
    container::OptimizationContainer,
    devices::U,
    model::DeviceModel{D, W},
) where {
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    W <: AbstractRenewableDispatchFormulation,
} where {D <: PSY.RenewableGen}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    add_expression_container!(container, ProductionCostExpression, D, names, time_steps)
    add_expression_container!(container, FixedCostExpression, D, names, time_steps)
    add_expression_container!(container, CurtailmentCostExpression, D, names, time_steps)
    add_expression_container!(container, VOMCostExpression, D, names, time_steps)
    return
end

"""
Generic implementation for service models with reserves.
"""
function add_expressions!(
    container::OptimizationContainer,
    ::Type{T},
    devices::U,
    model::ServiceModel{V, W},
) where {
    T <: ExpressionType,
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    V <: PSY.Reserve,
    W <: AbstractReservesFormulation,
} where {D <: PSY.Component}
    time_steps = get_time_steps(container)
    @assert length(devices) == 1
    add_expression_container!(container, T,
        D,
        PSY.get_name.(devices),
        time_steps;
        meta = get_service_name(model),
    )
    return
end
