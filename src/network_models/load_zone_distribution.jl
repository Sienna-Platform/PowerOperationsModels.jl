#################################################################################
# Load-zone load distribution
#
# A `LoadZone` can own a zonal load series. When the `NetworkModel` attribute
# `LOAD_ZONE_DISTRIBUTION_ATTRIBUTE` is `true`, the network model distributes that load
# onto the member buses of the zone with the zone's distribution factors.
#################################################################################

"""
`NetworkModel` attribute that enables the distribution of zonal load. Set it with
`NetworkModel(T; attributes = Dict("load_zone_distribution" => true))`. The distribution
is off when the attribute is absent.
"""
const LOAD_ZONE_DISTRIBUTION_ATTRIBUTE = "load_zone_distribution"

"""
Name of the `LoadZone` series that carries the zonal load. The series holds a fraction of
`PSY.get_peak_active_power` of the zone.
"""
const LOAD_ZONE_LOAD_TS_NAME = "max_active_power"

# Internal formulation. It keys the multipliers and the series names of the parameters that
# the network constructor creates for a `LoadZone`. No template uses it.
struct LoadZoneDistribution <: AbstractDeviceFormulation end

function get_default_time_series_names(::Type{PSY.LoadZone}, ::Type{LoadZoneDistribution})
    return Dict{Type{<:TimeSeriesParameter}, String}(
        ActivePowerTimeSeriesParameter => LOAD_ZONE_LOAD_TS_NAME,
        DistributionFactorParameter => DISTRIBUTION_FACTOR_TS_NAME,
    )
end

function get_default_attributes(::Type{PSY.LoadZone}, ::Type{LoadZoneDistribution})
    return Dict{String, Any}()
end

# The multiplier carries the sign: the zonal load is a withdrawal.
get_multiplier_value(
    ::Type{ActivePowerTimeSeriesParameter},
    zone::PSY.LoadZone,
    ::Type{LoadZoneDistribution},
) = -PSY.get_peak_active_power(zone, u"SU")

# Factors are fractions of the zonal load, so they take no capacity multiplier.
get_multiplier_value(
    ::Type{DistributionFactorParameter},
    ::PSY.LoadZone,
    ::Type{LoadZoneDistribution},
) = 1.0

function has_load_zone_distribution(network_model::NetworkModel)
    value = get(get_attributes(network_model), LOAD_ZONE_DISTRIBUTION_ATTRIBUTE, false)
    return _attribute_flag(value)
end

_attribute_flag(value::Bool) = value
_attribute_flag(value) = throw(
    ArgumentError(
        "The \"$(LOAD_ZONE_DISTRIBUTION_ATTRIBUTE)\" attribute must be a Bool, got " *
        "$(repr(value)).",
    ),
)

# The model of the zones' parameters. The network model creates them, so no template
# holds it.
load_zone_model(::NetworkModel) = DeviceModel(PSY.LoadZone, LoadZoneDistribution)

# A LoadZone has no availability flag: every zone of the model's subsystem.
IOM.get_available_components(
    model::DeviceModel{PSY.LoadZone, LoadZoneDistribution},
    sys::PSY.System,
) = PSY.get_components(PSY.LoadZone, sys; subsystem_name = get_subsystem(model))

# A series layout is the ordered axis names plus the label type of the last axis; any other
# layout, or no value axes at all, fails with `msg`. Returns the last axis' labels.
_check_series_layout(::Nothing, names, ::Type, msg::String) = throw(ArgumentError(msg))
function _check_series_layout(
    value_axes::Vector{IS.TimeSeriesAxis},
    names,
    ::Type{L},
    msg::String,
) where {L}
    if [axis.name for axis in value_axes] != names ||
       eltype(last(value_axes).labels) != L
        throw(ArgumentError(msg))
    end
    return last(value_axes).labels
end

# Each step of a factor series multiplies one model time step, so the resolutions must match.
# Checked on the metadata before the fill, which would otherwise fail with a plain error
# that names neither the component nor the fix.
function _check_window_resolution(
    container::OptimizationContainer,
    md::IS.TimeSeriesMetadata,
    component,
)
    if IS.get_resolution(md) != get_resolution(container)
        throw(
            IS.ConflictingInputsError(
                "$(summary(component)): series $(IS.get_name(md)) has resolution " *
                "$(IS.get_resolution(md)); the model runs at $(get_resolution(container)).",
            ),
        )
    end
    return
end

_factor_axes_message(component) =
    "The $(DISTRIBUTION_FACTOR_TS_NAME) series of $(summary(component)) must be one " *
    "[time step, bus] matrix with value_axes = [IS.TimeSeriesAxis(\"bus\", bus numbers)]."

function _factor_series_rows(container::OptimizationContainer, component::PSY.Component)
    return IS.list_time_series_metadata(
        component;
        time_series_type = get_default_time_series_type(container),
        name = DISTRIBUTION_FACTOR_TS_NAME,
    )
end

"""
Whether `component` owns a `distribution_factor` series of the type the model reads.
"""
has_distribution_factors(container::OptimizationContainer, component::PSY.Component) =
    !isempty(_factor_series_rows(container, component))

"""
Bus-number labels of the `distribution_factor` series that `component` owns, read from its
metadata without loading data. Call it only when [`has_distribution_factors`](@ref) is
`true`. Errors for a second series, a layout other than one `"bus"` axis of bus numbers, or
another resolution.
"""
function _factor_series_labels(container::OptimizationContainer, component::PSY.Component)
    rows = _factor_series_rows(container, component)
    if length(rows) != 1
        throw(
            ArgumentError(
                "$(summary(component)) carries $(length(rows)) " *
                "$(DISTRIBUTION_FACTOR_TS_NAME) series; keep one [time step, bus] matrix.",
            ),
        )
    end
    md = only(rows)
    _check_window_resolution(container, md, component)
    return _check_series_layout(
        IS.get_value_axes(md), ["bus"], Int64, _factor_axes_message(component),
    )
end

# Bus by number, built once per argument-stage call: factor labels resolve through it, so
# membership and availability never scan the system per zone.
_buses_by_number(sys::PSY.System) =
    Dict(PSY.get_number(b) => b for b in PSY.get_components(PSY.ACBus, sys))

function _member_test(zone::PSY.LoadZone)
    id = IS.get_id(zone)
    return bus -> _zone_id(PSY.get_load_zone(bus)) == id
end
_zone_id(::Nothing) = nothing
_zone_id(zone::PSY.LoadZone) = IS.get_id(zone)

"""
`_factor_series_labels`, also checking that every label is a member bus of `zone`;
`buses` maps bus numbers to buses (`_buses_by_number`).
"""
function _factor_bus_labels(
    container::OptimizationContainer,
    zone::PSY.LoadZone,
    buses::Dict{Int, PSY.ACBus},
)
    labels = _factor_series_labels(container, zone)
    is_member = _member_test(zone)
    for bus_no in labels
        if !(haskey(buses, bus_no) && is_member(buses[bus_no]))
            throw(
                ArgumentError(
                    "$(summary(zone)) has a $(DISTRIBUTION_FACTOR_TS_NAME) column " *
                    "for bus $(bus_no), which is not a member.",
                ),
            )
        end
    end
    return labels
end

# The extra parameter axis between zone and time: positions 1:n, n the most buses any
# zone's series labels. Shorter zones are padded with zeros; position j is the j-th label of
# that zone's own series, read back from its metadata.
function calc_additional_axes(
    container::OptimizationContainer,
    ::Type{DistributionFactorParameter},
    zones::Vector{PSY.LoadZone},
    ::DeviceModel{PSY.LoadZone, LoadZoneDistribution},
)
    return (1:maximum(z -> length(_factor_series_labels(container, z)), zones),)
end

"""
Read the distribution factors of `zone` from its `DistributionFactorParameter` row into a
numeric `(member bus number, time step)` array. The bus labels come from the series
metadata and are the buses that carry factors. Factor quality, such as summing to one, is an
ingestion concern. An unavailable member's column is dropped with a warning, and the
available members' factors are scaled per time step to keep the zone total. A column for a
bus that is not a member is an error. Each share enters the balance rows of its own bus, as
a device on that bus would.
"""
function get_distribution_factors(
    container::OptimizationContainer,
    sys::PSY.System,
    zone::PSY.LoadZone,
)
    return _distribution_factors(container, zone, _buses_by_number(sys))
end

# The reader behind `get_distribution_factors`, with `buses` (`_buses_by_number`) shared by
# every zone of one construct call.
function _distribution_factors(
    container::OptimizationContainer,
    zone::PSY.LoadZone,
    buses::Dict{Int, PSY.ACBus},
)
    if !has_distribution_factors(container, zone)
        return _error_no_factors(zone)
    end
    labels = _factor_bus_labels(container, zone, buses)
    name = PSY.get_name(zone)
    key = IOM.ParameterKey(DistributionFactorParameter, PSY.LoadZone)
    if !(
        has_container_key(container, DistributionFactorParameter, PSY.LoadZone) &&
        IOM.has_lhs_parameter_component(container, key, name)
    )
        error(
            "$(summary(zone)) carries a $(DISTRIBUTION_FACTOR_TS_NAME) series but the " *
            "model holds no $(DistributionFactorParameter) row for it. Enable the " *
            "\"$(LOAD_ZONE_DISTRIBUTION_ATTRIBUTE)\" attribute of the NetworkModel.",
        )
    end
    live = Tuple{Int, PSY.ACBus}[]
    for (j, bus_no) in enumerate(labels)
        bus = buses[bus_no]
        if PSY.get_available(bus)
            push!(live, (j, bus))
        else
            @warn "Load zone $(name): member bus $(PSY.get_name(bus)) is unavailable; the " *
                  "factors of the available members are scaled to keep the zone total." _group =
                LOG_GROUP_OPTIMIZATION_CONTAINER
        end
    end
    if isempty(live)
        return _error_no_factors(zone)
    end
    shares = IOM.get_lhs_parameter_values(container, key, name)::Matrix{Float64}
    time_steps = get_time_steps(container)
    factors = JuMP.Containers.DenseAxisArray(
        zeros(length(live), length(time_steps)),
        [PSY.get_number(bus) for (_, bus) in live],
        time_steps,
    )
    for t in time_steps
        scale =
            length(live) == length(labels) ? 1.0 : _available_scale(shares, live, t, name)
        for (j, bus) in live
            factors[PSY.get_number(bus), t] = scale * shares[j, t]
        end
    end
    return factors
end

# Scales the available members' factors at `t` so they add up to the factors of all members.
function _available_scale(shares::Matrix{Float64}, live, t::Int, name::String)
    total = sum(view(shares, :, t))
    available = sum(shares[j, t] for (j, _) in live)
    if iszero(available)
        iszero(total) && return 0.0
        error(
            "Load zone $(name): at time step $(t) the whole zone load is on unavailable " *
            "member buses.",
        )
    end
    return total / available
end

# A LoadZone with a load but no usable factor column is a data defect. The zone cannot
# silently vanish from the model, so error and name the fix.
function _error_no_factors(zone::PSY.LoadZone)
    error(
        "Load zone $(PSY.get_name(zone)) has no $(DISTRIBUTION_FACTOR_TS_NAME) column for " *
        "an available member bus. Attach one [time step, bus] matrix to the zone, of the " *
        "time series type the model reads, with value_axes = [IS.TimeSeriesAxis(\"bus\", bus numbers)].",
    )
end

#################################################################################
# Network constructor hook
#################################################################################

"""
Distribute the zonal load of every `LoadZone` onto its member buses when the network model
enables it. Call it in the network `ArgumentConstructStage`: the branch flows copy the
nodal balance in their `ModelConstructStage`, so a later write is lost.
"""
function add_load_zone_load!(
    container::OptimizationContainer,
    sys::PSY.System,
    network_model::NetworkModel{T},
) where {T <: AbstractNetworkModel}
    if has_load_zone_distribution(network_model)
        _add_load_zone_load!(
            container, sys, network_model, reactive_power_support(T),
        )
    end
    return
end

function _add_load_zone_load!(
    ::OptimizationContainer,
    ::PSY.System,
    ::NetworkModel{T},
    ::HasReactivePower,
) where {T <: AbstractNetworkModel}
    error(
        "The \"$(LOAD_ZONE_DISTRIBUTION_ATTRIBUTE)\" attribute does not support the " *
        "$(T) network formulation: it distributes active power only.",
    )
end

function _add_load_zone_load!(
    container::OptimizationContainer,
    sys::PSY.System,
    network_model::NetworkModel,
    ::NoReactivePower,
)
    ts_type = get_default_time_series_type(container)
    zones = [
        z for z in PSY.get_components(
            PSY.LoadZone, sys; subsystem_name = get_subsystem(network_model),
        ) if PSY.has_time_series(z, ts_type, LOAD_ZONE_LOAD_TS_NAME)
    ]
    if isempty(zones)
        return
    end
    model = load_zone_model(network_model)
    buses = _buses_by_number(sys)
    members = _available_members(buses)
    # A zone whose members share one balance row takes its total there; any other zone
    # spreads its load with factors, and the reader errors for one without them.
    rows = Dict(
        PSY.get_name(z) => _single_balance_row(container, network_model, z, members)
        for
        z in zones
    )
    owners = [
        z for z in zones if
        rows[PSY.get_name(z)] === nothing && has_distribution_factors(container, z)
    ]
    if !isempty(owners)
        add_parameters!(container, DistributionFactorParameter, owners, model)
    end
    add_parameters!(container, ActivePowerTimeSeriesParameter, zones, model)
    load = get_parameter(container, ActivePowerTimeSeriesParameter, PSY.LoadZone)
    multiplier = get_multiplier_array(load)
    time_steps = get_time_steps(container)
    for zone in zones
        name = PSY.get_name(zone)
        refs = get_parameter_column_refs(load, name)
        targets = rows[name]
        if targets === nothing
            factors = _distribution_factors(container, zone, buses)
            _distribute_zone_load!(
                container, network_model, buses, factors, refs, multiplier, name,
            )
        else
            _apply_ts_terms_to_targets!(targets, refs, multiplier, name, time_steps)
        end
    end
    return
end

# Available buses by the id of their load zone: the nodal balance has no row for a bus out
# of service.
function _available_members(buses::Dict{Int, PSY.ACBus})
    members = Dict{Int, Vector{PSY.ACBus}}()
    for bus in values(buses)
        zone = PSY.get_load_zone(bus)
        if zone !== nothing && PSY.get_available(bus)
            push!(get!(members, IS.get_id(zone), PSY.ACBus[]), bus)
        end
    end
    return members
end

# The balance targets that every available member of `zone` shares, or `nothing` when the
# members span several rows.
function _single_balance_row(
    container::OptimizationContainer,
    network_model::NetworkModel,
    zone::PSY.LoadZone,
    members::Dict{Int, Vector{PSY.ACBus}},
)
    zone_buses = get(members, IS.get_id(zone), PSY.ACBus[])
    if isempty(zone_buses)
        error("Load zone $(PSY.get_name(zone)) has no available member bus.")
    end
    targets(bus) = _bus_balance_targets(container, ActivePowerBalance, network_model, bus)
    row = targets(first(zone_buses))
    return all(b -> targets(b) === row, zone_buses) ? row : nothing
end

# Function barrier: `refs` and `multiplier` come from abstractly typed containers.
function _distribute_zone_load!(
    container::OptimizationContainer,
    network_model::NetworkModel,
    buses::Dict{Int, PSY.ACBus},
    factors,
    refs,
    multiplier,
    name::String,
)
    time_steps = get_time_steps(container)
    for bus_no in axes(factors)[1]
        targets = _bus_balance_targets(
            container, ActivePowerBalance, network_model, buses[bus_no],
        )
        for t in time_steps
            _apply_term_to_targets!(
                targets, refs[t], factors[bus_no, t] * multiplier[name, t], t,
            )
        end
    end
    return
end
