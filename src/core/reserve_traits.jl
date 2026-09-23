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
Per-time-step deployed fraction for `s`, as `deployed_fraction * profile[t]`.

Returns `fill(scalar, horizon)` when the model declares no deployed-fraction series name or the
reserve carries no such series, reproducing the constant-coefficient behavior exactly. Always
returns a `Vector{Float64}` so the multiplier seams stay type-stable.

The name is resolved from the `ServiceModel`'s `time_series_names`, so a user can override it
there, exactly as for [`RequirementTimeSeriesParameter`](@ref). Unlike `requirement` the series
backs no parameter container: the fraction multiplies a reserve award, so it is a constraint
coefficient, and a JuMP parameter in coefficient position would make the energy balance
bilinear. Repeated calls for a service shared across devices are cheap because IOM caches
resolved series.
"""
function deployed_fraction_values(
    container::OptimizationContainer,
    model::ServiceModel,
    s::PSY.AbstractReserve,
)::Vector{Float64}
    scalar = PSY.get_deployed_fraction(s)
    time_steps = get_time_steps(container)
    ts_names = get_time_series_names(model)
    haskey(ts_names, DeployedFractionTimeSeriesParameter) ||
        return fill(scalar, length(time_steps))
    ts_name = ts_names[DeployedFractionTimeSeriesParameter]
    PSY.has_time_series(s, ts_name) || return fill(scalar, length(time_steps))
    ts_type = get_default_time_series_type(container)
    if !PSY.has_time_series(s, ts_type, ts_name)
        throw(
            IS.ConflictingInputsError(
                "Reserve $(PSY.get_name(s)) carries a $(ts_name) time series, but not as \
                $(ts_type), which is what this model reads. Attach the series before calling \
                transform_single_time_series!, or add it directly as $(ts_type).",
            ),
        )
    end
    # `resolution` accompanies `interval` so an off-resolution series is rejected rather than
    # read at the wrong step length, matching the parameter path in `add_parameters.jl`.
    settings = get_settings(container)
    ts_values = IOM.get_time_series_initial_values!(
        container,
        ts_type,
        s,
        ts_name;
        interval = get_interval(settings),
        resolution = get_resolution(settings),
    )
    return scalar .* Vector{Float64}(ts_values)
end

"""
Per-time-step deployed fraction resolved through `device_model`'s registered service models.

Convenience for the device-side multiplier seams, which hold a `DeviceModel` and reach services
through `PSY.get_services(d)`. Falls back to the scalar when the device model registers no
service model covering `s`.
"""
function deployed_fraction_values(
    container::OptimizationContainer,
    device_model::DeviceModel,
    s::PSY.AbstractReserve,
)::Vector{Float64}
    service_model = _service_model_for(device_model, s)
    isnothing(service_model) && return fill(
        PSY.get_deployed_fraction(s),
        length(get_time_steps(container)),
    )
    return deployed_fraction_values(container, service_model, s)
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
names, offline_only)` per service, where `offline_only` is the `ServiceModel` attribute.
"""
function _offline_reserve_awards(
    container::OptimizationContainer,
    model::DeviceModel,
    ::Type{V},
) where {V <: PSY.Device}
    offline = Tuple{String, IOM.JuMPArray, Set{String}, Bool}[]
    for sm in get_services(model)
        _is_offline_reserve(get_component_type(sm)) || continue
        variable =
            get_variable(container, ActivePowerReserveVariable, get_component_type(sm))
        only_off = something(get_attribute(sm, "offline_only"), false)
        for (service_name, dev_map) in get_contributing_devices_map(sm)
            members = get(dev_map, V, nothing)
            isnothing(members) && continue
            push!(offline, (service_name, variable, Set(PSY.get_name.(members)), only_off))
        end
    end
    return offline
end

"""
Whether a `DeviceModel` carries an `OfflineReserve` service. Gates the
[`OfflineReserveBandConstraint`](@ref) so that models without offline reserves build
exactly the classic single semi-continuous band row.
"""
_has_offline_reserve_service(model::DeviceModel) =
    has_service_model(model) &&
    any(sm -> _is_offline_reserve(get_component_type(sm)), get_services(model))
