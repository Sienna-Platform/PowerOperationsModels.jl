# Marker singleton trait types used to parametrize hybrid/storage reserve variable,
# expression, and constraint families. These eliminate the need for paired sibling
# singletons across the codebase: a single parametric struct is used instead of
# every (Charge/Discharge) and (Unscaled/Deployed) sibling pair.

"""
Trait axis selecting how a reserve contribution is scaled into an aggregation:
[`UnscaledReserve`](@ref) (raw multiplier) or [`DeployedReserve`](@ref) (scaled by
`deployed_fraction`).
"""
abstract type ReserveScale end
"Reserve aggregation that uses the raw multiplier (1.0)."
struct UnscaledReserve <: ReserveScale end
"Reserve aggregation that scales the multiplier by `deployed_fraction`."
struct DeployedReserve <: ReserveScale end

"""
Trait axis selecting which side of a storage device or hybrid PCC a reserve variable acts
on: [`DischargeSide`](@ref) (outflow) or [`ChargeSide`](@ref) (inflow).
"""
abstract type ReserveSide end
"Discharge / outflow side of a storage or hybrid PCC."
struct DischargeSide <: ReserveSide end
"Charge / inflow side of a storage or hybrid PCC."
struct ChargeSide <: ReserveSide end

# ── Reserve-type predicate helpers ────────────────────────────────────────────────────
# The reserve tree distinguishes reserves by state (direction parameter, demand curve,
# attached series) rather than by struct type; these centralize that branch logic in one
# dispatch-based place (no `isa`).

"""
Direction of a reserve. `OfflineReserve` (non-spinning) has no direction type parameter and is
upward-only in every US market, so it maps to `PSY.ReserveUp`.
"""
_reserve_direction(::PSY.Reserve{T}) where {T <: PSY.ReserveDirection} = T
_reserve_direction(::PSY.OfflineReserve) = PSY.ReserveUp

"""
Upward reserve products a device can supply: up-direction reserves plus `OfflineReserve`
(non-spinning is upward-only). Excludes `GroupReserve` - devices serve a group's members,
never the group itself.
"""
const UP_RESERVE = Union{PSY.Reserve{PSY.ReserveUp}, PSY.OfflineReserve}

"Whether a reserve is non-spinning: `OfflineReserve` vs everything else under `AbstractReserve`."
_is_offline(::PSY.OfflineReserve) = true
_is_offline(::PSY.AbstractReserve) = false

"""
Whether a reserve's `requirement` is scaled by an attached requirement time series.

Resolves the series name from the `ServiceModel`'s `time_series_names` (a user can override the
name there), and deliberately does not pin the series' concrete `TimeSeriesData` type
(`Deterministic` in recurrent solves, `SingleTimeSeries` otherwise). Returns `false` when the
model declares no requirement series name (the formulation carries no requirement parameter).
"""
function _has_ts_requirement(model::ServiceModel, s::PSY.AbstractReserve)
    ts_names = get_time_series_names(model)
    haskey(ts_names, RequirementTimeSeriesParameter) || return false
    return PSY.has_time_series(s, ts_names[RequirementTimeSeriesParameter])
end

"""
The `ServiceModel` in `device_model` that covers `service`, or `nothing` when the device model
registers no model for that service's type.

Mirrors the type match the hydro served-reserve wiring already performs: a `ServiceModel`'s
component type can be partially applied (`OnlineReserve{ReserveUp}`, a `UnionAll`), so the
comparison is `typeof(service) <: get_component_type(service_model)`.
"""
function _service_model_for(device_model::DeviceModel, service::PSY.Service)
    for service_model in get_services(device_model)
        typeof(service) <: get_component_type(service_model) && return service_model
    end
    return nothing
end

"""
The deployed-fraction parameter key covering `service` through `device_model`'s registered
service models, or `nothing` when the reserve's fraction is its fixed scalar: no service model
covers it, or it carries no deployed-fraction profile.
"""
function _deployed_fraction_key(
    container::OptimizationContainer,
    device_model::DeviceModel,
    service::PSY.AbstractReserve,
)
    service_model = _service_model_for(device_model, service)
    isnothing(service_model) && return nothing
    SR = get_component_type(service_model)
    has_container_key(container, DeployedFractionParameter, SR) || return nothing
    key = IOM.ParameterKey(DeployedFractionParameter, SR)
    has_lhs_parameter_component(container, key, PSY.get_name(service)) || return nothing
    return key
end

_type_label(T::DataType) =
    if isempty(T.parameters)
        string(nameof(T))
    else
        join((string(nameof(T)), (_type_label(p) for p in T.parameters)...), "_")
    end
_type_label(T) = string(T)

"""
Meta string of the product containers holding `service`'s deployed `U` awards. Built from
`nameof` so it is the same in every module context.
"""
_deployed_product_meta(::Type{U}, service::PSY.Service) where {U <: VariableType} =
    "$(_type_label(U))_$(_service_container_meta(service))"

"""
How one reserve's awards enter an aggregation expression. Resolved once per device and service
by [`reserve_award_scaling`](@ref), then applied across the horizon by
[`add_reserve_awards!`](@ref).
"""
abstract type ReserveAwardScaling end

"Awards enter at their base multiplier."
struct UnscaledAward <: ReserveAwardScaling end

"Awards enter scaled by a fixed fraction: a reserve without a deployed-fraction profile."
struct FixedDeployedAward <: ReserveAwardScaling
    fraction::Float64
end

"""
Awards enter through product variables whose defining rows carry the deployed fraction and
are refreshed in place between solves: a reserve with a deployed-fraction profile.
"""
struct ProfiledDeployedAward{
    K <: IOM.ParameterKey,
    P <: AbstractArray,
    C <: AbstractArray,
} <:
       ReserveAwardScaling
    key::K
    service_name::String
    products::P
    constraints::C
    row::Int
    base_name::String
end

reserve_award_scaling(
    ::Type{UnscaledReserve},
    ::OptimizationContainer,
    ::DeviceModel,
    ::AbstractVector,
    ::PSY.Service,
    ::Type{<:VariableType},
    ::String,
) = UnscaledAward()

function reserve_award_scaling(
    ::Type{DeployedReserve},
    container::OptimizationContainer,
    device_model::DeviceModel{V},
    devices::AbstractVector{V},
    service::PSY.AbstractReserve,
    ::Type{U},
    device_name::String,
) where {V <: PSY.Component, U <: VariableType}
    key = _deployed_fraction_key(container, device_model, service)
    isnothing(key) && return FixedDeployedAward(PSY.get_deployed_fraction(service))
    meta = _deployed_product_meta(U, service)
    if !has_container_key(container, ParameterizedProductVariable, V, meta)
        names = [PSY.get_name(d) for d in devices if service in PSY.get_services(d)]
        time_steps = get_time_steps(container)
        add_variable_container!(
            container, ParameterizedProductVariable, V, names, time_steps; meta = meta)
        add_constraints_container!(
            container, ParameterizedProductConstraint, V, names, time_steps; meta = meta)
    end
    products = get_variable(container, ParameterizedProductVariable, V, meta)
    return ProfiledDeployedAward(
        key,
        PSY.get_name(service),
        products,
        get_constraint(container, ParameterizedProductConstraint, V, meta),
        products.lookup[1][device_name],
        "ParameterizedProductVariable_$(V)_{$(meta), $(device_name)",
    )
end

"Add `base * awards[t]` to `expression[device_name, t]` for every time step."
function add_reserve_awards!(
    expression::AbstractArray,
    ::UnscaledAward,
    container::OptimizationContainer,
    device_name::String,
    awards::Vector{JuMP.VariableRef},
    base::Float64,
)
    for t in get_time_steps(container)
        add_proportional_to_jump_expression!(expression[device_name, t], awards[t], base)
    end
    return
end

"Add `base * fraction * awards[t]` to `expression[device_name, t]` for every time step."
function add_reserve_awards!(
    expression::AbstractArray,
    scaling::FixedDeployedAward,
    container::OptimizationContainer,
    device_name::String,
    awards::Vector{JuMP.VariableRef},
    base::Float64,
)
    for t in get_time_steps(container)
        add_proportional_to_jump_expression!(
            expression[device_name, t], awards[t], base * scaling.fraction)
    end
    return
end

"""
Add `base * y[t]` to `expression[device_name, t]`, where `y[t] = deployed_fraction(t) * awards[t]`
is a product variable bound by IOM. A product already created for this award (one award can
feed several expressions) is reused, so each award is bound once.
"""
function add_reserve_awards!(
    expression::AbstractArray,
    scaling::ProfiledDeployedAward,
    container::OptimizationContainer,
    device_name::String,
    awards::Vector{JuMP.VariableRef},
    base::Float64,
)
    products = scaling.products.data
    constraints = scaling.constraints.data
    row = scaling.row
    jump_model = get_jump_model(container)
    for t in get_time_steps(container)
        if !isassigned(products, row, t)
            product = JuMP.@variable(jump_model, base_name = "$(scaling.base_name), $(t)}")
            products[row, t] = product
            constraints[row, t] = IOM.add_parameterized_product_constraint!(
                container, scaling.key, scaling.service_name, t, product, awards[t])
        end
        add_proportional_to_jump_expression!(
            expression[device_name, t],
            products[row, t],
            base,
        )
    end
    return
end

# ── ORDC (operating-reserve-demand-curve) predicates ─────────────────────────────────
# A demand curve lives on a reserve's `variable` field ("is this an ORDC" is
# `PSY.has_demand_curve`), so "static vs time-varying" is a runtime inspection of the curve
# (union-splits cleanly over the two `variable` members; reserves are few and read at build,
# so the cost is negligible).

"Whether a reserve's or group's ORDC curve is time-varying. Dispatches on the value-curve type (no `isa`)."
_ordc_is_ts(s::PSY.AbstractReserve) =
    _value_curve_is_ts(PSY.get_value_curve(PSY.get_variable(s)))
_value_curve_is_ts(::PSY.TimeSeriesPiecewiseIncrementalCurve) = true
_value_curve_is_ts(::PSY.PiecewiseIncrementalCurve) = false

"""
Meta string identifying one service inside the device-side reserve containers
(ancillary-service variables, `TotalReserveOffering` expressions, coverage constraints).
Always derive it from the service INSTANCE: a `ServiceModel`'s type parameter can be
partially applied (`OnlineReserve{ReserveUp}`, a `UnionAll`) while the containers are
written with the fully concrete instance type, and the two spellings do not match.
"""
_service_container_meta(service::PSY.Service) =
    "$(typeof(service))_$(PSY.get_name(service))"

"""
Whether a reserve type is an offline (non-spinning) product. Trait form of the
`OfflineReserve` check used by the offline-capability machinery.
"""
_is_offline_reserve(::Type{<:PSY.AbstractReserve}) = false
_is_offline_reserve(::Type{<:PSY.OfflineReserve}) = true

"""
Whether a device formulation folds offline-reserve awards into the commitment-gated range
expression (`ActivePowerRangeExpressionUB`). Defaults to `true` (the award consumes gated
headroom, so an OFF unit cannot supply). Commitment formulations that provide offline
capability through [`OfflineReserveBandConstraint`](@ref) return `false`.
"""
offline_reserve_in_range_ub(::Type{<:AbstractDeviceFormulation}) = true

"""
Whether a device formulation can provide reserve. Qualifying requires making the device's
output a decision and putting that decision in the objective: the range expression ties the
award to the dispatch, and objective participation is what prices the capacity.

The load family defaults to `false` and opts in per formulation in `electric_loads.jl`;
generation and storage keep the permissive default.
"""
supports_reserve_provision(::Type{<:AbstractDeviceFormulation}) = true
# `StaticPowerLoad` has neither variables nor cost expressions. `PowerLoadShift`'s headroom
# is shift capability carrying an energy-recovery balance, which the range expression
# cannot express.
supports_reserve_provision(::Type{<:AbstractLoadFormulation}) = false

"""
Offline services on `model` that devices of type `V` contribute to, for the
[`OfflineReserveBandConstraint`](@ref) builders: `(service name, award variable, member
names, offline_only, exclude_shutdown_step)` per service; the flags are `ServiceModel`
attributes.
"""
function _offline_reserve_awards(
    container::OptimizationContainer,
    model::DeviceModel,
    ::Type{V},
) where {V <: PSY.Device}
    offline = Tuple{String, IOM.JuMPArray, Set{String}, Bool, Bool}[]
    for sm in get_services(model)
        S = get_component_type(sm)
        _is_offline_reserve(S) || continue
        only_off = something(get_attribute(sm, "offline_only"), false)
        no_shut = something(get_attribute(sm, "exclude_shutdown_step"), false)
        for (service_name, dev_map) in get_contributing_devices_map(sm)
            members = get(dev_map, V, nothing)
            isnothing(members) && continue
            variable = _reserve_variable(container, V, S)
            push!(
                offline,
                (service_name, variable, Set(PSY.get_name.(members)), only_off, no_shut),
            )
        end
    end
    return offline
end

"""
Available maximum of `d` in each time step for the offline band: `mult[name, t] * ts_t` from
its `ActivePowerTimeSeriesParameter`, or `q_limit` (static `pmax`) in every step when `model`
maps no such series or `d` has none.
"""
function _offline_hourly_limit(
    container::OptimizationContainer,
    model::DeviceModel{V},
    d::V,
    q_limit::Float64,
) where {V <: PSY.Device}
    time_steps = get_time_steps(container)
    fallback = fill(q_limit, length(time_steps))
    ts_names = get_time_series_names(model)
    haskey(ts_names, ActivePowerTimeSeriesParameter) || return fallback
    ts_type = get_default_time_series_type(container)
    IS.has_time_series(d, ts_type, ts_names[ActivePowerTimeSeriesParameter]) ||
        return fallback
    param_container = get_parameter(container, ActivePowerTimeSeriesParameter, V)
    mult = get_multiplier_array(param_container)
    name = PSY.get_name(d)
    param_col = get_parameter_column_refs(param_container, name)
    return [mult[name, t] * param_col[t] for t in time_steps]
end

"""
Commitment of each `V` device before the first time step, from its `DeviceStatus` initial
condition: the initialization solve's step-1 commitment when the model initializes,
`is_online(d)` otherwise. Must-run thermal devices carry no value and are left out.
"""
function _initial_status(
    container::OptimizationContainer,
    ::Type{V},
) where {V <: PSY.Device}
    status = Dict{String, Union{Float64, JuMP.VariableRef}}()
    for ic in get_initial_condition(container, DeviceStatus(), V)
        value = get_value(ic)
        isnothing(value) && continue
        status[IOM.get_component_name(ic)] = value
    end
    return status
end

"""
[`OfflineReserveShutdownConstraint`](@ref) rows of device `name`: the offline awards in
`awards` (`(service name, award variable)` pairs) are `0` in the step it goes off,
`sum(awards) <= q_limit * (1 - u_{t-1} + u_t)` with `u_0 = status0`. The right-hand side is
`0` when the unit goes off, `q_limit` while its status holds and `2 * q_limit` when it starts.
"""
function _add_offline_shutdown_rows!(
    rows,
    jump_model::JuMP.Model,
    name::String,
    q_limit::Float64,
    awards,
    varbin,
    status0,
    time_steps,
)
    t1 = first(time_steps)
    rows[(name, t1)] = JuMP.@constraint(
        jump_model,
        sum(v[(sname, name, t1)] for (sname, v) in awards) <=
        q_limit * (1 - status0 + varbin[name, t1])
    )
    for t in time_steps[2:end]
        rows[(name, t)] = JuMP.@constraint(
            jump_model,
            sum(v[(sname, name, t)] for (sname, v) in awards) <=
            q_limit * (1 - varbin[name, t - 1] + varbin[name, t])
        )
    end
    return
end

"""
Whether a `DeviceModel` carries an `OfflineReserve` service. Gates the
[`OfflineReserveBandConstraint`](@ref) so that models without offline reserves build
exactly the classic single semi-continuous band row.
"""
_has_offline_reserve_service(model::DeviceModel) =
    has_service_model(model) &&
    any(sm -> _is_offline_reserve(get_component_type(sm)), get_services(model))

"""
Whether an `OfflineReserve` service on `model` sets `"exclude_shutdown_step"`. Gates the
hydro `DeviceStatus` initial condition that [`OfflineReserveShutdownConstraint`](@ref)
reads, so models without the rule keep their initial-condition set.
"""
_excludes_shutdown_step(model::DeviceModel) = any(
    sm ->
        _is_offline_reserve(get_component_type(sm)) &&
            something(get_attribute(sm, "exclude_shutdown_step"), false),
    get_services(model),
)
