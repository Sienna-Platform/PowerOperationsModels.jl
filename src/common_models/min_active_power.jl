#################################################################################
# Per-step minimum active power
#################################################################################

"""
Whether `d` has a row in the container of the minimum power parameter `P`.
"""
function has_min_active_power_series(
    container::OptimizationContainer,
    ::Type{P},
    d::V,
)::Bool where {P <: AbstractMinActivePowerParameter, V <: PSY.Component}
    has_container_key(container, P, V) || return false
    return has_lhs_parameter_component(container, IOM.ParameterKey(P, V), PSY.get_name(d))
end

function _per_step_minimum(
    container::OptimizationContainer,
    ::Type{P},
    d::V,
    static_min::Float64,
)::Vector{Float64} where {P <: AbstractMinActivePowerParameter, V <: PSY.Component}
    has_container_key(container, P, V) ||
        return fill(static_min, length(get_time_steps(container)))
    param_container = get_parameter(container, P, V)
    name = PSY.get_name(d)
    haskey(get_attributes(param_container).component_name_to_ts_uuid, name) ||
        return fill(static_min, length(get_time_steps(container)))
    values = get_parameter_column_refs(param_container, name)
    return values.data .* get_multiplier_array(param_container)[name, :].data
end

"""
Minimum active power of `d` at each time step. The value comes from the
[`MinActivePowerTimeSeriesParameter`](@ref) series when `d` has one. Otherwise it is the
static minimum of `d`.
"""
function min_active_power_values(
    container::OptimizationContainer,
    d::PSY.Component,
)::Vector{Float64}
    return _per_step_minimum(
        container,
        MinActivePowerTimeSeriesParameter,
        d,
        PSY.get_active_power_limits(d, u"SU").min,
    )
end

"""
Minimum pump input power of `d` at each time step. The value comes from the
[`MinActivePowerInTimeSeriesParameter`](@ref) series when `d` has one. Otherwise it is the
static pump minimum of `d`.
"""
function min_active_power_in_values(
    container::OptimizationContainer,
    d::PSY.Component,
)::Vector{Float64}
    return _per_step_minimum(
        container,
        MinActivePowerInTimeSeriesParameter,
        d,
        PSY.get_active_power_limits_pump(d, u"SU").min,
    )
end

_static_maximum(::Type{MinActivePowerTimeSeriesParameter}, d::PSY.Component) =
    PSY.get_max_active_power(d, u"SU")
_static_maximum(::Type{MinActivePowerInTimeSeriesParameter}, d::PSY.Component) =
    PSY.get_active_power_limits_pump(d, u"SU").max

# The series upper bound at step `t`, when the device model maps one for `d`.
function _check_below_upper_series(
    ::Type{MinActivePowerTimeSeriesParameter},
    container::OptimizationContainer,
    model::DeviceModel,
    d::V,
    values::Vector{Float64},
) where {V <: PSY.Component}
    haskey(get_time_series_names(model), ActivePowerTimeSeriesParameter) || return
    has_container_key(container, ActivePowerTimeSeriesParameter, V) || return
    param_container = get_parameter(container, ActivePowerTimeSeriesParameter, V)
    name = PSY.get_name(d)
    haskey(get_attributes(param_container).component_name_to_ts_uuid, name) || return
    upper = IOM.jump_fixed_value.(get_parameter_column_refs(param_container, name))
    multiplier = get_multiplier_array(param_container)[name, :]
    for t in eachindex(values)
        upper_t = upper[t] * multiplier[t]
        if !isfinite(upper_t)
            error(
                "MinActivePowerTimeSeriesParameter for $(PSY.get_name(d)) at step $t: \
                the maximum active power series value is $(upper_t).",
            )
        end
        if values[t] > upper_t + 1e-9
            error(
                "MinActivePowerTimeSeriesParameter for $(PSY.get_name(d)) at step $t: \
                minimum $(values[t]) is above the maximum active power series value \
                $(upper_t).",
            )
        end
    end
    return
end

_check_below_upper_series(
    ::Type{MinActivePowerInTimeSeriesParameter},
    ::OptimizationContainer,
    ::DeviceModel,
    ::PSY.Component,
    ::Vector{Float64},
) = nothing

function _validate_min_active_power!(
    container::OptimizationContainer,
    ::Type{P},
    d::V,
    model::DeviceModel,
) where {P <: AbstractMinActivePowerParameter, V <: PSY.Component}
    values = get_lhs_parameter_values(container, IOM.ParameterKey(P, V), PSY.get_name(d))
    pmax = _static_maximum(P, d)
    for t in eachindex(values)
        if values[t] < 0.0
            error(
                "$(nameof(P)) for $(PSY.get_name(d)) at step $t: minimum power \
                $(values[t]) is below zero.",
            )
        end
        if values[t] > pmax + 1e-9
            error(
                "$(nameof(P)) for $(PSY.get_name(d)) at step $t: minimum power \
                $(values[t]) is above the maximum active power $pmax.",
            )
        end
    end
    _check_below_upper_series(P, container, model, d, values)
    return
end

"""
Add the minimum power parameter `P` for the devices that have its series, then validate the
values. Do nothing when no device has the series.
"""
function add_min_active_power_parameters!(
    container::OptimizationContainer,
    ::Type{P},
    devices::Vector{V},
    model::DeviceModel,
) where {P <: AbstractMinActivePowerParameter, V <: PSY.Component}
    haskey(get_time_series_names(model), P) || return
    profiled = _add_profiled_parameters!(
        container,
        P,
        devices,
        model,
        get_time_series_names(model)[P],
    )
    for d in profiled
        _validate_min_active_power!(container, P, d, model)
    end
    return
end

"""
How the power variable of a formulation relates to the minimum power. `AbsoluteBase`: the
variable is the total power, and the minimum power is a lower limit. `AboveMinimumBase`: the
variable is the power above the minimum.
"""
abstract type PowerBaseKind end
struct AbsoluteBase <: PowerBaseKind end
struct AboveMinimumBase <: PowerBaseKind end

power_base_kind(::Type{<:AbstractDeviceFormulation}) = AbsoluteBase()

function _min_max_limit_values(
    ::AbsoluteBase,
    limits,
    ::PSY.Component,
    pmin::Vector{Float64},
)
    return (min = pmin, max = fill(Float64(limits.max), length(pmin)))
end

# The static limits, when `d` has no minimum power series. Otherwise the limits that follow
# the per-step minimum.
function _limit_values_or_static(
    container::OptimizationContainer,
    ::Type{W},
    d::PSY.Component,
    limits,
) where {W <: AbstractDeviceFormulation}
    if !has_min_active_power_series(container, MinActivePowerTimeSeriesParameter, d)
        return _static_limit_values(container, limits)
    end
    return _min_max_limit_values(
        power_base_kind(W),
        limits,
        d,
        min_active_power_values(container, d),
    )
end

function _static_limit_values(container::OptimizationContainer, limits)
    n = length(get_time_steps(container))
    return (min = fill(Float64(limits.min), n), max = fill(Float64(limits.max), n))
end

# The power variable is the power above the minimum: its range is `0 <= p <= Pmax - Pmin_t`.
function _min_max_limit_values(
    ::AboveMinimumBase,
    ::Any,
    d::PSY.Component,
    pmin::Vector{Float64},
)
    pmax = Float64(PSY.get_active_power_limits(d, u"SU").max)
    return (min = zeros(length(pmin)), max = pmax .- pmin)
end

# The lower bound of the variable of a profiled device is the smallest minimum of the horizon.
function _set_lower_bound_to_smallest_minimum!(
    container::OptimizationContainer,
    devices::Vector{V},
) where {V <: PSY.Component}
    variable = get_variable(container, ActivePowerVariable, V)
    time_steps = get_time_steps(container)
    for d in devices
        has_min_active_power_series(container, MinActivePowerTimeSeriesParameter, d) ||
            continue
        lower = minimum(min_active_power_values(container, d))
        for t in time_steps
            JuMP.set_lower_bound(variable[PSY.get_name(d), t], lower)
        end
    end
    return
end

"""
Set the variable bounds that depend on the per-step minimum power. Acts only on devices
that have a minimum power series.
"""
function set_min_power_variable_bounds!(
    container::OptimizationContainer,
    devices::Vector{V},
    ::DeviceModel{V, W},
) where {V <: PSY.Component, W <: AbstractDeviceFormulation}
    _set_min_power_variable_bounds!(power_base_kind(W), container, devices, W)
    return
end

function _set_min_power_variable_bounds!(
    ::AbsoluteBase,
    container::OptimizationContainer,
    devices::Vector{V},
    ::Type{W},
) where {V <: PSY.Component, W <: AbstractDeviceFormulation}
    has_container_key(container, MinActivePowerTimeSeriesParameter, V) || return
    _set_lower_bound_to_smallest_minimum!(container, filter(_is_must_run, devices))
    return
end

# The variable is the power above the minimum. Its bound uses the smallest minimum of the
# horizon. Its warm start uses the minimum of the first step.
function _set_min_power_variable_bounds!(
    ::AboveMinimumBase,
    container::OptimizationContainer,
    devices::Vector{V},
    ::Type{W},
) where {V <: PSY.ThermalGen, W <: AbstractDeviceFormulation}
    has_container_key(container, MinActivePowerTimeSeriesParameter, V) || return
    variable = get_variable(container, PowerAboveMinimumVariable, V)
    time_steps = get_time_steps(container)
    for d in devices
        has_min_active_power_series(container, MinActivePowerTimeSeriesParameter, d) ||
            continue
        name = PSY.get_name(d)
        pmin = min_active_power_values(container, d)
        upper = PSY.get_active_power_limits(d, u"SU").max - minimum(pmin)
        start = max(0.0, PSY.get_active_power(d, u"SU") - first(pmin))
        for t in time_steps
            JuMP.set_upper_bound(variable[name, t], upper)
            IOM.set_start_value!(container, variable[name, t], start)
        end
    end
    return
end

# Coefficient of the on-status parameter in a range expression, at each time step.
function _static_on_status_multipliers(
    container::OptimizationContainer,
    ::Type{T},
    d::PSY.Component,
    ::Type{W},
) where {T <: ExpressionType, W <: AbstractDeviceFormulation}
    return fill(
        Float64(get_expression_multiplier(OnStatusParameter, T, d, W)),
        length(get_time_steps(container)),
    )
end

function _on_status_multipliers(
    container::OptimizationContainer,
    ::Type{T},
    d::PSY.Component,
    ::Type{W},
) where {T <: ExpressionType, W <: AbstractDeviceFormulation}
    return _static_on_status_multipliers(container, T, d, W)
end

function _on_status_multipliers(
    container::OptimizationContainer,
    ::Type{ActivePowerRangeExpressionLB},
    d::PSY.ThermalGen,
    ::Type{W},
) where {W <: AbstractThermalFormulation}
    return _on_status_lb_multipliers(power_base_kind(W), container, d, W)
end

# ThermalDispatchNoMin ignores the minimum power: its multiplier stays static.
function _on_status_multipliers(
    container::OptimizationContainer,
    ::Type{ActivePowerRangeExpressionLB},
    d::PSY.ThermalGen,
    ::Type{ThermalDispatchNoMin},
)
    return _static_on_status_multipliers(
        container,
        ActivePowerRangeExpressionLB,
        d,
        ThermalDispatchNoMin,
    )
end

# The balance term is the minimum power of the compact formulations, at each time step.
function _on_status_multipliers(
    container::OptimizationContainer,
    ::Type{ActivePowerBalance},
    d::PSY.ThermalGen,
    ::Type{W},
) where {W <: AbstractThermalFormulation}
    return _on_status_balance_multipliers(power_base_kind(W), container, d, W)
end

# The range upper bound of the compact formulations is `Pmax - Pmin_t`.
function _on_status_multipliers(
    container::OptimizationContainer,
    ::Type{ActivePowerRangeExpressionUB},
    d::PSY.ThermalGen,
    ::Type{W},
) where {W <: Union{AbstractCompactUnitCommitment, ThermalCompactDispatch}}
    return PSY.get_active_power_limits(d, u"SU").max .-
           min_active_power_values(container, d)
end

function _on_status_balance_multipliers(
    ::AboveMinimumBase,
    container::OptimizationContainer,
    d::PSY.ThermalGen,
    ::Type{W},
) where {W <: AbstractThermalFormulation}
    return min_active_power_values(container, d)
end

function _on_status_balance_multipliers(
    ::AbsoluteBase,
    container::OptimizationContainer,
    d::PSY.ThermalGen,
    ::Type{W},
) where {W <: AbstractThermalFormulation}
    return _static_on_status_multipliers(container, ActivePowerBalance, d, W)
end

function _on_status_lb_multipliers(
    ::AbsoluteBase,
    container::OptimizationContainer,
    d::PSY.ThermalGen,
    ::Type{W},
) where {W <: AbstractThermalFormulation}
    return min_active_power_values(container, d)
end

function _on_status_lb_multipliers(
    ::AboveMinimumBase,
    container::OptimizationContainer,
    d::PSY.ThermalGen,
    ::Type{W},
) where {W <: AbstractThermalFormulation}
    return _static_on_status_multipliers(container, ActivePowerRangeExpressionLB, d, W)
end

# Names of the devices that have a row in the `OnStatusParameter`.
function _on_status_names(
    container::OptimizationContainer,
    ::Type{V},
) where {V <: PSY.Component}
    has_container_key(container, OnStatusParameter, V) || return Set{String}()
    return Set{String}(axes(IOM.get_parameter_array(container, OnStatusParameter, V), 1))
end

function _add_to_row_coefficient!(row::JuMP.ConstraintRef, var::JuMP.VariableRef, value)
    JuMP.set_normalized_coefficient(row, var, JuMP.normalized_coefficient(row, var) + value)
    return
end

# A status that is a number is a constant: its term moves to the right side.
function _add_to_row_coefficient!(row::JuMP.ConstraintRef, status::Number, value)
    JuMP.set_normalized_rhs(row, JuMP.normalized_rhs(row) - value * status)
    return
end

# The steps `t` where the minimum power changes, with the change `Pmin_t - Pmin_{t-1}`.
function _level_change_steps(pmin::Vector{Float64})
    return [
        (t, pmin[t] - pmin[t - 1]) for t in 2:length(pmin) if !iszero(pmin[t] - pmin[t - 1])
    ]
end

"""
Add the change of the minimum power to the compact ramp rows. The compact rows are on the
power above the minimum. The change of total power has the extra term
`(Pmin_t - Pmin_{t-1}) * (u_t - start_t)`. Acts only on devices that have a minimum power
series and a ramp row. The first step has no term.
"""
function add_min_power_level_change_to_ramps!(
    container::OptimizationContainer,
    ::Type{T},
    devices::Vector{V},
    ::DeviceModel{V, W},
) where {T <: RampConstraint, V <: PSY.ThermalGen, W <: AbstractThermalFormulation}
    has_container_key(container, MinActivePowerTimeSeriesParameter, V) || return
    up = IOM.get_constraint(container, IOM.ConstraintKey(T, V, "up"))
    dn = IOM.get_constraint(container, IOM.ConstraintKey(T, V, "dn"))
    ramp_names = Set(axes(up, 1))
    profiled = [
        d for d in devices if PSY.get_name(d) in ramp_names &&
        has_min_active_power_series(container, MinActivePowerTimeSeriesParameter, d)
    ]
    _add_level_change_to_ramps!(container, up, dn, profiled, W)
    return
end

# Both ramp rows get the level change `delta * (u_t - start_t)` on the left side. Up row:
# `dp_t - dp_{t-1} + delta (u_t - start_t) <= ...`. Down row: the same term with the other sign.
function _add_level_change_to_ramps!(
    container::OptimizationContainer,
    up,
    dn,
    devices::Vector{V},
    ::Type{<:AbstractCompactUnitCommitment},
) where {V <: PSY.ThermalGen}
    isempty(devices) && return
    on = IOM.get_variable(container, OnVariable, V)
    start = IOM.get_variable(container, StartVariable, V)
    for d in devices
        name = PSY.get_name(d)
        steps = _level_change_steps(min_active_power_values(container, d))
        if _is_must_run(d)
            _add_constant_level_change!(up, dn, name, steps)
        else
            for (t, delta) in steps
                _add_to_row_coefficient!(up[name, t], on[name, t], delta)
                _add_to_row_coefficient!(up[name, t], start[name, t], -delta)
                _add_to_row_coefficient!(dn[name, t], on[name, t], -delta)
                _add_to_row_coefficient!(dn[name, t], start[name, t], delta)
            end
        end
    end
    return
end

# The status is 1 in every step: the term is the constant `delta`.
function _add_constant_level_change!(up, dn, name::String, steps)
    for (t, delta) in steps
        _add_to_row_coefficient!(up[name, t], 1.0, delta)
        _add_to_row_coefficient!(dn[name, t], 1.0, -delta)
    end
    return
end

# The dispatch ramp rows have no start variable. The status is the `OnStatusParameter`, when
# a feedforward provides it. The rows are linear in the parameter variables, because the
# simulation writes the status values after the build. Without the parameter, or for a
# must-run unit, the status is 1.
function _add_level_change_to_ramps!(
    container::OptimizationContainer,
    up,
    dn,
    devices::Vector{V},
    ::Type{ThermalCompactDispatch},
) where {V <: PSY.ThermalGen}
    status_names = _on_status_names(container, V)
    for d in devices
        name = PSY.get_name(d)
        steps = _level_change_steps(min_active_power_values(container, d))
        if name in status_names
            status = IOM.get_parameter_array(container, OnStatusParameter, V)
            _add_status_level_change!(up, dn, name, steps, status)
        else
            _add_constant_level_change!(up, dn, name, steps)
        end
    end
    return
end

# The exact left side term of a ramp row is `q * s_t * s_{t-1}`, with `q = +delta` in the up
# row and `q = -delta` in the down row. It is a product of two parameters. A `<=` row needs
# an affine term that is never above the exact one. A `>=` row needs one that is never
# below it. Both are exact at `s_t = s_{t-1} = 1` and use binary `s`:
#   lower bound: q > 0: q (s_t + s_{t-1} - 1)     q < 0: q s_t
#   upper bound: q > 0: q s_t                     q < 0: q (s_t + s_{t-1} - 1)
# The relaxation never cuts off a dispatch that the exact row allows.
_relaxed_product_form(::JuMP.MOI.LessThan, q::Float64) = _lower_product_form(q)

function _relaxed_product_form(::JuMP.MOI.GreaterThan, q::Float64)
    a, b, c = _lower_product_form(-q)
    return (-a, -b, -c)
end

# Coefficients on `s_t` and `s_{t-1}`, and the constant, of the affine lower bound of `q s s'`.
function _lower_product_form(q::Float64)
    if q > 0.0
        return (q, q, -q)
    end
    return (q, 0.0, 0.0)
end

function _add_relaxed_product!(row::JuMP.ConstraintRef, q::Float64, s, sp)
    coef_s, coef_sp, constant =
        _relaxed_product_form(JuMP.constraint_object(row).set, q)
    _add_to_row_coefficient!(row, s, coef_s)
    iszero(coef_sp) || _add_to_row_coefficient!(row, sp, coef_sp)
    iszero(constant) || JuMP.set_normalized_rhs(row, JuMP.normalized_rhs(row) - constant)
    return
end

function _add_status_level_change!(up, dn, name::String, steps, status)
    for (t, delta) in steps
        s = status[name, t]
        sp = status[name, t - 1]
        _add_relaxed_product!(up[name, t], delta, s, sp)
        _add_relaxed_product!(dn[name, t], -delta, s, sp)
    end
    return
end

IOM.get_min_active_power_values(
    container::OptimizationContainer,
    d::Union{PSY.ThermalGen, PSY.HydroGen},
) = min_active_power_values(container, d)
