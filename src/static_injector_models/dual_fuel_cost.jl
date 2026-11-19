#################################################################################
# Blended DualFuelCurve: one set of piecewise variables on the union of both curves'
# breakpoints, and one fuel expression per fuel, each times its weight and price.
# A stacked curve is built by the SharedHRSGHeatBalance plant model.
#################################################################################

# A line has no breakpoints of its own, so it takes the output limits.
_blend_breakpoints(::PSY.LinearCurve, limits) = [limits.min, limits.max]
_blend_breakpoints(
    curve::Union{PSY.PiecewisePointCurve, PSY.PiecewiseIncrementalCurve,
        PSY.PiecewiseAverageCurve},
    _,
) = IS.get_x_coords(IS.get_function_data(curve))

_input_output(curve::IS.InputOutputCurve) = curve
_input_output(curve::IS.ValueCurve) = IS.InputOutputCurve(curve)

"""
The points of a blended `DualFuelCurve`, in the curve's own units: `x` is the sorted union
of both curves' breakpoints inside the output limits, with the ends of the range both curves
cover, and `first` and `second` are each fuel's use at `x`.
"""
function blended_fuel_points(
    cost::PSY.DualFuelCurve,
    limits::NamedTuple{(:min, :max), NTuple{2, Float64}},
)
    first_curve = _input_output(PSY.get_first_fuel_curve(cost))
    second_curve = _input_output(PSY.get_second_fuel_curve(cost))
    x1 = _blend_breakpoints(PSY.get_first_fuel_curve(cost), limits)
    x2 = _blend_breakpoints(PSY.get_second_fuel_curve(cost), limits)
    # Validation makes both curves cover the limits up to rounding, so neither curve is
    # evaluated outside its own points.
    lo = max(limits.min, first(x1), first(x2))
    hi = min(limits.max, last(x1), last(x2))
    x = sort!(vcat(lo, hi, filter(v -> lo < v < hi, vcat(x1, x2))))
    # Curves and limits that agree up to rounding share a breakpoint.
    x = x[[i == 1 || !isapprox(x[i], x[i - 1]) for i in eachindex(x)]]
    return (; x, first = first_curve.(x), second = second_curve.(x))
end

# ThermalDispatchNoMin runs from zero. Both curves start there along their first segments,
# so its piecewise method adds no point that only the first fuel would see.
_blend_points_for(_, points, ::Type{<:AbstractDeviceFormulation}) = points

function _blend_points_for(name::String, points, ::Type{ThermalDispatchNoMin})
    x = points.x
    iszero(first(x)) && return points
    # A line through zero extends to rounding noise, which counts as zero.
    function at_zero(y)
        value = y[1] - (y[2] - y[1]) / (x[2] - x[1]) * x[1]
        return isapprox(value, 0.0; atol = sqrt(eps()) * abs(y[1])) ? 0.0 : value
    end
    first_zero, second_zero = at_zero(points.first), at_zero(points.second)
    (first_zero < 0.0 || second_zero < 0.0) && throw(
        ArgumentError(
            "$(name) has a blended DualFuelCurve that ThermalDispatchNoMin extends to " *
            "zero output with negative fuel use: $(first_zero) for the first fuel and " *
            "$(second_zero) for the second.",
        ),
    )
    return (; x = vcat(0.0, x), first = vcat(first_zero, points.first),
        second = vcat(second_zero, points.second))
end

_point_fuel_curve(x::Vector{Float64}, y::Vector{Float64}, fuel_units) =
    PSY.FuelCurve(PSY.PiecewisePointCurve(collect(zip(x, y))), fuel_units, 0.0)

function add_variable_cost_to_objective!(
    container::OptimizationContainer,
    ::Type{T},
    component::V,
    cost::PSY.DualFuelCurve,
    ::Type{U},
) where {T <: VariableType, V <: PSY.ThermalGen, U <: AbstractDeviceFormulation}
    PSY.is_blended(cost) || return
    name = PSY.get_name(component)
    natural = IS.convert_power_units(component, cost, u"NU")
    points = _blend_points_for(
        name,
        blended_fuel_points(natural, PSY.get_active_power_limits(component, u"NU")),
        U,
    )
    # The lambda builders skip a curve that is zero everywhere, which would leave the blend
    # with no piecewise variables.
    all(iszero, points.first) && throw(
        ArgumentError(
            "$(name) has a blended DualFuelCurve whose first fuel use is zero at every " *
            "point $(points.x) MW, so no piecewise variables are built for the blend.",
        ),
    )
    fuel_units = IS.get_fuel_units(cost)
    # The temporary curves carry no price: each fuel is priced below with its weight.
    first_curve = _point_fuel_curve(points.x, points.first, fuel_units)
    first_fuel = IOM.add_pwl_term_lambda!(container, component, first_curve, T, U)
    second_curve = _point_fuel_curve(points.x, points.second, fuel_units)
    _add_blend_fuel_terms!(
        container,
        component,
        first_fuel,
        second_curve,
        PSY.get_second_fuel_share(cost),
        fuel_price_source(container, cost, FirstFuel(), V, U, name),
        fuel_price_source(container, cost, SecondFuel(), V, U, name),
        T,
        U,
    )
    return
end

# Any other component, such as a HybridSystem pricing its thermal subcomponent's curve.
function add_variable_cost_to_objective!(
    ::OptimizationContainer,
    ::Type{T},
    component::PSY.Component,
    ::PSY.DualFuelCurve,
    ::Type{U},
) where {T <: VariableType, U <: AbstractDeviceFormulation}
    throw(
        IS.ConflictingInputsError(
            "$(PSY.get_name(component)) has a DualFuelCurve variable cost; a " *
            "DualFuelCurve is supported on thermal units only.",
        ),
    )
end

# A function barrier: the two price sources are concrete here, so the step loop is type stable.
function _add_blend_fuel_terms!(
    container::OptimizationContainer,
    component::V,
    first_fuel,
    second_curve::PSY.FuelCurve,
    share::Float64,
    first_price,
    second_price,
    ::Type{T},
    ::Type{U},
) where {V <: PSY.ThermalGen, T <: VariableType, U <: AbstractDeviceFormulation}
    name = PSY.get_name(component)
    for t in get_time_steps(container)
        second_fuel = IOM.get_pwl_cost_expression_lambda(
            container, component, t, second_curve, T, U)
        _add_fuel_terms!(container, (1.0 - share) * first_fuel[t], first_price, V, name, t)
        _add_fuel_terms!(container, share * second_fuel, second_price, V, name, t)
    end
    return
end

function _add_fuel_terms!(container, fuel, price, ::Type{V}, name, t) where {V}
    add_fuel_price_term!(container, fuel, price, V, name, t)
    add_cost_to_expression!(container, FuelConsumptionExpression, fuel, V, name, t)
    return
end

# The price parameter of each fuel and the curve's price fields.
_fuel_price(cost::PSY.DualFuelCurve, ::FirstFuel) = (FuelCostParameter,
    PSY.get_first_fuel_cost(cost), PSY.get_first_fuel_cost_time_series(cost))
_fuel_price(cost::PSY.DualFuelCurve, ::SecondFuel) = (SecondFuelCostParameter,
    PSY.get_second_fuel_cost(cost), PSY.get_second_fuel_cost_time_series(cost))

fuel_label(::FirstFuel) = "first"
fuel_label(::SecondFuel) = "second"

"""
The price of fuel `fuel` (`FirstFuel()` or `SecondFuel()`) of `name`'s `DualFuelCurve`,
resolved once per unit: the fixed price, or an instance of its `FuelCostParameter` or
`SecondFuelCostParameter`. Pass it to `add_fuel_price_term!` at each step.
"""
function fuel_price_source(
    container::OptimizationContainer,
    cost::PSY.DualFuelCurve,
    fuel::DualFuelSide,
    ::Type{V},
    ::Type{U},
    name::String,
) where {V <: PSY.ThermalGen, U <: AbstractDeviceFormulation}
    P, price, key = _fuel_price(cost, fuel)
    isnothing(key) && return price
    # The parameter skips a unit without the series; that must not price its fuel at zero.
    has_entry =
        has_container_key(container, P, V) &&
        name in axes(get_parameter_array(container, P, V), 1)
    has_entry || throw(
        IS.ConflictingInputsError(
            "$(name) has its $(fuel_label(fuel)) fuel price in a time series, but $(nameof(P)) has no " *
            "value for it: the unit has no $(get_default_time_series_type(container)) " *
            "series that the device model maps to $(nameof(P)) " *
            "(\"$(get_default_time_series_names(V, U)[P])\" by default).",
        ),
    )
    return P()
end

"""
Add `quantity` of fuel at step `t`, times its price from `fuel_price_source`, to
`FuelCostExpression` and the objective: a fixed price as an invariant term, a time series
price as a variant one.
"""
function add_fuel_price_term!(
    container::OptimizationContainer,
    quantity::JuMPOrFloat,
    price::Float64,
    ::Type{V},
    name::String,
    t::Int,
) where {V <: PSY.ThermalGen}
    IOM.add_cost_term_invariant!(container, quantity, price, FuelCostExpression, V, name, t)
    return
end

function add_fuel_price_term!(
    container::OptimizationContainer,
    quantity::JuMPOrFloat,
    ::P,
    ::Type{V},
    name::String,
    t::Int,
) where {P <: ObjectiveFunctionParameter, V <: PSY.ThermalGen}
    IOM.add_cost_term_variant!(container, quantity, P, FuelCostExpression, V, name, t)
    return
end

# Fuel at zero output is in the points of the blend.
_onvar_cost(::OptimizationContainer, ::PSY.DualFuelCurve, ::PSY.ThermalGen, ::Int) = 0.0
