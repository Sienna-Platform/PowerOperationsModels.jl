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
is off when the attribute is absent. The zonal load adds to the load devices that the
template models on the member buses.
"""
const LOAD_ZONE_DISTRIBUTION_ATTRIBUTE = "load_zone_distribution"

"""
Name of the `LoadZone` series that carries the zonal load. The series holds a fraction of
`PSY.get_peak_active_power` of the zone.
"""
const LOAD_ZONE_LOAD_TS_NAME = "max_active_power"

# `DeviceModel` attribute that carries the factor bus labels of each zone, read once per
# build and shared by the parameter axes and the factor reader.
const FACTOR_LABELS_ATTRIBUTE = "factor_labels"

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

"""
The build reads the distribution factors as fixed coefficients. Without `rebuild_model`, a
recurrent solve keeps the factors of the first step, so they go stale. The template checks
switch `rebuild_model` on; this guard catches a build path that skips them.
"""
assert_numeric_distribution_factors(container::OptimizationContainer) =
    _require_numeric_params(container, "Load zone distribution")

# Only available members receive a share: the nodal balance has no row for a bus out of
# service.
get_member_buses(sys::PSY.System, zone::PSY.LoadZone) =
    [b for b in PSY.get_buses(sys, zone) if PSY.get_available(b)]

_factor_axes_message(component) =
    "The $(DISTRIBUTION_FACTOR_TS_NAME) series of $(summary(component)) must be one " *
    "[time step, bus] matrix with value_axes = [IS.TimeSeriesAxis(\"bus\", bus numbers)]."

function _factor_series_rows(
    container::OptimizationContainer,
    component::PSY.Component,
    ts_type::Type{<:IS.TimeSeriesData},
)
    return list_model_series_metadata(
        container, component, ts_type, DISTRIBUTION_FACTOR_TS_NAME,
    )
end

"""
Whether `component` owns a `distribution_factor` series of type `ts_type`.
"""
has_distribution_factors(
    container::OptimizationContainer,
    component::PSY.Component,
    ts_type::Type{<:IS.TimeSeriesData},
) = !isempty(_factor_series_rows(container, component, ts_type))

"""
Bus-number labels of the `distribution_factor` series that `component` owns, read from its
metadata without loading data. Call it only when [`has_distribution_factors`](@ref) is
`true`. Errors for a second series, a layout other than one `"bus"` axis of bus numbers, or
another resolution.
"""
function _factor_series_labels(
    container::OptimizationContainer,
    component::PSY.Component,
    rows,
)
    if length(rows) != 1
        throw(
            ArgumentError(
                "$(summary(component)) carries $(length(rows)) " *
                "$(DISTRIBUTION_FACTOR_TS_NAME) series; keep one [time step, bus] matrix.",
            ),
        )
    end
    md = only(rows)
    return _check_series_layout(
        IS.get_value_axes(md), ["bus"], Int64, _factor_axes_message(component),
    )
end

_factor_series_labels(container::OptimizationContainer, component::PSY.Component) =
    _factor_series_labels(
        container,
        component,
        _factor_series_rows(container, component, get_default_time_series_type(container)),
    )

# Bus by number, built once per argument-stage call: factor labels resolve through it, so
# membership and availability never scan the system per zone.
_buses_by_number(sys::PSY.System) =
    Dict(PSY.get_number(b) => b for b in PSY.get_components(PSY.ACBus, sys))

function _member_test(zone::PSY.LoadZone)
    id = IS.get_id(zone)
    return bus -> _in_zone(PSY.get_load_zone(bus), id)
end
_in_zone(::Nothing, ::Int) = false
_in_zone(zone::PSY.LoadZone, id::Int) = IS.get_id(zone) == id

# Available member buses of every zone, by zone id, from one pass over `buses`.
function _members_by_zone(buses::Dict{Int, PSY.ACBus})
    members = Dict{Int, Vector{PSY.ACBus}}()
    for bus in values(buses)
        if PSY.get_available(bus)
            _add_member!(members, PSY.get_load_zone(bus), bus)
        end
    end
    for list in values(members)
        sort!(list; by = PSY.get_number)
    end
    return members
end

_add_member!(::Dict{Int, Vector{PSY.ACBus}}, ::Nothing, ::PSY.ACBus) = nothing
function _add_member!(
    members::Dict{Int, Vector{PSY.ACBus}},
    zone::PSY.LoadZone,
    bus::PSY.ACBus,
)
    push!(get!(Vector{PSY.ACBus}, members, IS.get_id(zone)), bus)
    return
end

_zone_members(members::Dict{Int, Vector{PSY.ACBus}}, zone::PSY.LoadZone) =
    get(members, IS.get_id(zone), PSY.ACBus[])

"""
`_factor_series_labels`, also checking that every label is a member bus of `zone`;
`buses` maps bus numbers to buses (`_buses_by_number`).
"""
function _factor_bus_labels(
    container::OptimizationContainer,
    zone::PSY.LoadZone,
    buses::Dict{Int, PSY.ACBus},
    rows,
)
    labels = _factor_series_labels(container, zone, rows)
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
    return Vector{Int}(labels)
end

_factor_bus_labels(
    container::OptimizationContainer,
    zone::PSY.LoadZone,
    buses::Dict{Int, PSY.ACBus},
) = _factor_bus_labels(
    container,
    zone,
    buses,
    _factor_series_rows(container, zone, get_default_time_series_type(container)),
)

# The extra parameter axis between zone and time: positions 1:n, n the most buses any
# zone's series labels. Shorter zones are padded with zeros; position j is the j-th label of
# that zone's own series.
function calc_additional_axes(
    ::OptimizationContainer,
    ::Type{DistributionFactorParameter},
    zones::Vector{PSY.LoadZone},
    model::DeviceModel{PSY.LoadZone, LoadZoneDistribution},
)
    labels = get_attribute(model, FACTOR_LABELS_ATTRIBUTE)::Dict{String, Vector{Int}}
    return (1:maximum(z -> length(labels[PSY.get_name(z)]), zones),)
end

"""
Read the distribution factors of `zone` from its `DistributionFactorParameter` row into a
numeric `(bus number, time step)` array. The bus labels come from the series metadata and
are the member buses that carry factors. The factors of all members must sum to one at
every time step. A nonzero share on an unavailable member is an error, because dropping it
would change the zonal total. A column for a bus that is not a member is an error. Each
share enters the balance rows of its own bus, as a device on that bus would.
"""
function get_distribution_factors(
    container::OptimizationContainer,
    sys::PSY.System,
    zone::PSY.LoadZone,
)
    if !has_distribution_factors(container, zone, get_default_time_series_type(container))
        return _error_no_factors(zone)
    end
    buses = _buses_by_number(sys)
    return _distribution_factors(
        container, zone, buses, _factor_bus_labels(container, zone, buses),
    )
end

# The reader behind `get_distribution_factors`, with `buses` (`_buses_by_number`) shared by
# every zone of one construct call and the zone's `labels` (`_factor_bus_labels`).
function _distribution_factors(
    container::OptimizationContainer,
    zone::PSY.LoadZone,
    buses::Dict{Int, PSY.ACBus},
    labels::Vector{Int},
)
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
    shares = IOM.get_lhs_parameter_values(container, key, name)::Matrix{Float64}
    _check_factor_sums(shares, name)
    time_steps = get_time_steps(container)
    live = Int[]
    for (j, bus_no) in enumerate(labels)
        if PSY.get_available(buses[bus_no])
            push!(live, j)
        elseif any(!iszero, view(shares, j, time_steps))
            error(
                "Load zone $(name) has a nonzero $(DISTRIBUTION_FACTOR_TS_NAME) share " *
                "on unavailable bus $(bus_no). Move the share to an available member bus.",
            )
        end
    end
    if isempty(live)
        return _error_no_factors(zone)
    end
    return JuMP.Containers.DenseAxisArray(
        shares[live, time_steps], labels[live], time_steps,
    )
end

const DISTRIBUTION_FACTOR_SUM_TOLERANCE = 1e-4

# Factors that do not sum to one would drop or add load only under networks that read them.
function _check_factor_sums(shares::Matrix{Float64}, name::String)
    for t in axes(shares, 2)
        total = sum(view(shares, :, t))
        if !isapprox(total, 1.0; atol = DISTRIBUTION_FACTOR_SUM_TOLERANCE)
            error(
                "Load zone $(name): the $(DISTRIBUTION_FACTOR_TS_NAME) values sum to " *
                "$(total) at time step $(t); they must sum to 1.",
            )
        end
    end
    return
end

# A LoadZone with a load but no usable factor column is a data defect. The zone cannot
# silently vanish from the model, so error and name the fix.
function _error_no_factors(zone::PSY.LoadZone)
    error(
        "Load zone $(PSY.get_name(zone)) has no $(DISTRIBUTION_FACTOR_TS_NAME) column for " *
        "an available member bus. Attach one [time step, bus] matrix series to the zone " *
        "with value_axes = [IS.TimeSeriesAxis(\"bus\", bus numbers)].",
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

# Zones that carry the zonal load series as `ts_type`, from one catalog query with the
# model's resolution and interval, as `add_parameters!` reads them. The template checks
# reject a series of another type. A series at another resolution or interval is an error,
# so this filter skips only zones with no load.
function _loaded_zones(
    container::OptimizationContainer,
    sys::PSY.System,
    network_model::NetworkModel,
    ts_type::Type{<:IS.TimeSeriesData},
)
    zones = collect(
        PSY.get_components(
            PSY.LoadZone, sys; subsystem_name = get_subsystem(network_model),
        ),
    )
    settings = get_settings(container)
    resolution = get_resolution(settings)
    interval = get_interval(settings)
    hashes = IS.get_time_series_hashes(
        zones,
        ts_type,
        LOAD_ZONE_LOAD_TS_NAME;
        resolution = _to_is_resolution(resolution),
        interval = _to_is_interval(interval),
    )
    loaded = PSY.LoadZone[]
    for zone in zones
        if haskey(hashes, IS.get_id(zone))
            push!(loaded, zone)
        elseif PSY.has_time_series(zone, ts_type, LOAD_ZONE_LOAD_TS_NAME)
            throw(
                IS.ConflictingInputsError(
                    "$(summary(zone)): the $(LOAD_ZONE_LOAD_TS_NAME) series does not " *
                    "match resolution=$(resolution) interval=$(interval).",
                ),
            )
        end
    end
    return loaded
end

# A zone whose available members share one balance row takes its total there, with no
# factors: one member on a nodal network, one area under AreaBalance, and every zone under
# CopperPlate, which has one system row per subnetwork.
_needs_factors(::NetworkModel, members::Vector{PSY.ACBus}) = length(members) > 1
_needs_factors(::NetworkModel{CopperPlateNetworkModel}, ::Vector{PSY.ACBus}) = false
_needs_factors(::NetworkModel{AreaBalanceNetworkModel}, members::Vector{PSY.ACBus}) =
    !allequal(PSY.get_area(b) for b in members)

function _add_load_zone_load!(
    container::OptimizationContainer,
    sys::PSY.System,
    network_model::NetworkModel,
    ::NoReactivePower,
)
    ts_type = get_default_time_series_type(container)
    zones = _loaded_zones(container, sys, network_model, ts_type)
    if isempty(zones)
        return
    end
    buses = _buses_by_number(sys)
    members = _members_by_zone(buses)
    labels = Dict{String, Vector{Int}}()
    for zone in zones
        if _needs_factors(network_model, _zone_members(members, zone))
            rows = _factor_series_rows(container, zone, ts_type)
            if !isempty(rows)
                labels[PSY.get_name(zone)] =
                    _factor_bus_labels(container, zone, buses, rows)
            end
        end
    end
    owners = [z for z in zones if haskey(labels, PSY.get_name(z))]
    model = DeviceModel(
        PSY.LoadZone,
        LoadZoneDistribution;
        attributes = Dict{String, Any}(FACTOR_LABELS_ATTRIBUTE => labels),
    )
    if !isempty(owners)
        assert_numeric_distribution_factors(container)
        add_parameters!(container, DistributionFactorParameter, owners, model)
    end
    add_parameters!(container, ActivePowerTimeSeriesParameter, zones, model)
    load = get_parameter(container, ActivePowerTimeSeriesParameter, PSY.LoadZone)
    multiplier = get_multiplier_array(load)
    for zone in zones
        name = PSY.get_name(zone)
        _write_zone_load!(
            container, network_model, zone, buses, _zone_members(members, zone), labels,
            get_parameter_column_refs(load, name), multiplier, name,
        )
    end
    return
end

function _error_no_members(name::String)
    error("Load zone $(name) has no available member bus.")
end

# The balance rows a zone's load on `bus` enters. A degree-two reduction removes a bus
# without mapping it to a retained bus, so a bus with no row is an error here rather than a
# KeyError in the lookup. A build from a `SystemNetworkSource` keeps these buses; a prebuilt
# source may not.
function _zone_bus_balance_targets(
    container::OptimizationContainer,
    network_model::NetworkModel,
    bus::PSY.ACBus,
    name::String,
)
    _check_zone_bus_retained(network_model, bus, name)
    return _bus_balance_targets(container, ActivePowerBalance, network_model, bus)
end

function _check_zone_bus_retained(network_model::NetworkModel, bus::PSY.ACBus, name::String)
    reduction = get_network_reduction(network_model)
    bus_no = PSY.get_number(bus)
    haskey(
        PNM.get_bus_reduction_map(reduction),
        PNM.get_mapped_bus_number(reduction, bus_no),
    ) &&
        return
    throw(
        IS.ConflictingInputsError(
            "Load zone $(name) puts load on bus $(bus_no), a distribution-factor bus or " *
            "the zone's sole member, but the network reduction removed that bus without " *
            "mapping it to a retained bus. Keep the bus out of the reduction: pass it in " *
            "`irreducible_buses` when building a prebuilt matrix, or use a " *
            "`SystemNetworkSource`.",
        ),
    )
end

# CopperPlate and AreaBalance write to system and area rows, which no reduction removes.
_check_zone_bus_retained(
    ::NetworkModel{<:Union{CopperPlateNetworkModel, AreaBalanceNetworkModel}},
    ::PSY.ACBus,
    ::String,
) = nothing

# The zonal total, unsplit, into the balance rows of `bus`.
function _write_zone_total!(
    container::OptimizationContainer,
    network_model::NetworkModel,
    bus::PSY.ACBus,
    refs,
    multiplier,
    name::String,
)
    targets = _zone_bus_balance_targets(container, network_model, bus, name)
    _apply_ts_terms_to_targets!(
        targets, refs, multiplier, name, get_time_steps(container),
    )
    return
end

# CopperPlate: the zonal total goes into the system row of the zone's reference bus.
function _write_zone_load!(
    container::OptimizationContainer,
    network_model::NetworkModel{CopperPlateNetworkModel},
    ::PSY.LoadZone,
    ::Dict{Int, PSY.ACBus},
    members::Vector{PSY.ACBus},
    ::Dict{String, Vector{Int}},
    refs,
    multiplier,
    name::String,
)
    if isempty(members)
        return _error_no_members(name)
    end
    reference_buses = sort!(unique([get_reference_bus(network_model, b) for b in members]))
    if length(reference_buses) > 1
        error(
            "Load zone $(name) spans the subnetworks with reference buses " *
            "$(reference_buses). CopperPlate writes the zonal total to one system row; " *
            "use a network formulation that distributes the load with factors.",
        )
    end
    _write_zone_total!(container, network_model, first(members), refs, multiplier, name)
    return
end

# A zone whose members share one balance row writes its total there; any other zone splits
# its load with factors.
function _write_zone_load!(
    container::OptimizationContainer,
    network_model::NetworkModel,
    zone::PSY.LoadZone,
    buses::Dict{Int, PSY.ACBus},
    members::Vector{PSY.ACBus},
    labels::Dict{String, Vector{Int}},
    refs,
    multiplier,
    name::String,
)
    if isempty(members)
        return _error_no_members(name)
    end
    if _needs_factors(network_model, members)
        _write_factor_load!(container, network_model, zone, buses, labels, refs, multiplier)
    else
        _write_zone_total!(
            container, network_model, first(members), refs, multiplier, name,
        )
    end
    return
end

function _write_factor_load!(
    container::OptimizationContainer,
    network_model::NetworkModel,
    zone::PSY.LoadZone,
    buses::Dict{Int, PSY.ACBus},
    labels::Dict{String, Vector{Int}},
    refs,
    multiplier,
)
    name = PSY.get_name(zone)
    if !haskey(labels, name)
        return _error_no_factors(zone)
    end
    factors = _distribution_factors(container, zone, buses, labels[name])
    _distribute_zone_load!(container, network_model, buses, factors, refs, multiplier, name)
    return
end

# Function barrier: Julia compiles the time loop for the concrete `targets` type.
function _apply_factor_terms!(
    targets::Tuple,
    refs,
    shares::AbstractVector{Float64},
    zone_load::Vector{Float64},
    time_steps,
)
    for t in time_steps
        _apply_term_to_targets!(targets, refs[t], shares[t] * zone_load[t], t)
    end
    return
end

# Each share resolves the balance rows of its own bus, as a device on that bus does: under a
# reduction, the nodal row is the retained bus and the area row is the bus's own area.
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
    zone_load = Float64[multiplier[name, t] for t in time_steps]
    for (i, bus_no) in enumerate(axes(factors, 1))
        targets = _zone_bus_balance_targets(container, network_model, buses[bus_no], name)
        _apply_factor_terms!(targets, refs, view(factors.data, i, :), zone_load, time_steps)
    end
    return
end

#################################################################################
# Template checks
#################################################################################

# The zone parameters come from the network model, not from a template model, so the
# template checks visit them here. A zone series stored only as another time series type
# would drop the zone from the model with no message.
function _check_load_zone_time_series_types(
    network_model::NetworkModel,
    sys::PSY.System,
    ts_type::Type{<:IS.TimeSeriesData},
)
    if !has_load_zone_distribution(network_model)
        return
    end
    for zone in PSY.get_components(
        PSY.LoadZone, sys; subsystem_name = get_subsystem(network_model),
    )
        for ts_name in (LOAD_ZONE_LOAD_TS_NAME, DISTRIBUTION_FACTOR_TS_NAME)
            PSY.has_time_series(zone, ts_type, ts_name) && continue
            if PSY.has_time_series(zone, ts_name)
                throw(
                    IS.ConflictingInputsError(
                        "$(summary(zone)) carries a $(ts_name) time series, but not as " *
                        "$(ts_type), which is what this model reads. Attach the series " *
                        "before calling transform_single_time_series!, or add it " *
                        "directly as $(ts_type).",
                    ),
                )
            end
        end
    end
    return
end

# The first zone that gets a `DistributionFactorParameter` row, a left-hand-side parameter,
# paired with that type; `nothing` when no zone gets one.
function _first_load_zone_lhs_component(
    container::OptimizationContainer,
    network_model::NetworkModel,
    sys::PSY.System,
)
    if !has_load_zone_distribution(network_model)
        return nothing
    end
    ts_type = get_default_time_series_type(container)
    members = _members_by_zone(_buses_by_number(sys))
    for zone in _loaded_zones(container, sys, network_model, ts_type)
        if _needs_factors(network_model, _zone_members(members, zone)) &&
           has_distribution_factors(container, zone, ts_type)
            return (zone, DistributionFactorParameter)
        end
    end
    return nothing
end
