"""
Distribution factors multiply cleared-quantity variables, so they must reach JuMP as
numbers. `IOM.get_param_eltype` returns `JuMP.VariableRef` for recurrent solves with
`rebuild_model` off, so guard at build time rather than surface a solver error mid-simulation.
"""
function assert_numeric_distribution_factors(container::OptimizationContainer)
    if IOM.get_param_eltype(container) !== Float64
        error(
            "Nodal distribution requires rebuild_model = true. With recurrent solves " *
            "and rebuild_model off, the factors would be JuMP parameters and " *
            "df * cleared_q would be nonlinear.",
        )
    end
    return
end

# Membership differs by location type: dispatch, never branch on the type. Only available
# members receive a share: the nodal balance has no row for a bus out of service.
get_member_buses(::PSY.System, bus::PSY.ACBus) = [bus]
get_member_buses(sys::PSY.System, zone::PSY.LoadZone) =
    [b for b in PSY.get_buses(sys, zone) if PSY.get_available(b)]
get_member_buses(::PSY.System, hub::PSY.TradingHub) =
    [b for b in PSY.get_buses(hub) if PSY.get_available(b)]

function _check_window_resolution(container::OptimizationContainer, md, owner)
    if IS.get_resolution(md) != get_resolution(container)
        throw(
            IS.ConflictingInputsError(
                "$(summary(owner)): series $(IS.get_name(md)) has resolution " *
                "$(IS.get_resolution(md)); the model runs at $(get_resolution(container)).",
            ),
        )
    end
    return
end

_factor_axes_message(location) =
    "The $(DISTRIBUTION_FACTOR_TS_NAME) series of $(summary(location)) must be one " *
    "[time step, bus] matrix with value_axes = [IS.TimeSeriesAxis(\"bus\", bus numbers)]."

_bus_labels(::Nothing, location) = throw(ArgumentError(_factor_axes_message(location)))
function _bus_labels(value_axes::Vector{IS.TimeSeriesAxis}, location)
    if length(value_axes) != 1 || only(value_axes).name != "bus"
        throw(ArgumentError(_factor_axes_message(location)))
    end
    return _int_labels(only(value_axes).labels, location)
end
_int_labels(labels::Vector{Int64}, _) = labels
_int_labels(::Vector{String}, location) =
    throw(ArgumentError(_factor_axes_message(location)))

"""
Bus-number labels of the `distribution_factor` series `location` owns, read from its metadata
without loading data, or `nothing` when it owns none. Errors for a second series, a layout
other than one `"bus"` axis of bus numbers, or another resolution.
"""
function _factor_series_labels(container::OptimizationContainer, location::PSY.Component)
    metadata = IS.list_time_series_metadata(
        location;
        time_series_type = IS.Deterministic,
        name = DISTRIBUTION_FACTOR_TS_NAME,
    )
    isempty(metadata) && return nothing
    if length(metadata) > 1
        throw(
            ArgumentError(
                "$(summary(location)) carries $(length(metadata)) " *
                "$(DISTRIBUTION_FACTOR_TS_NAME) series; keep one [time step, bus] matrix.",
            ),
        )
    end
    md = only(metadata)
    _check_window_resolution(container, md, location)
    return _bus_labels(IS.get_value_axes(md), location)
end

# Bus by number, built once per argument-stage call: factor labels resolve through it, so
# membership and availability never scan the system per location.
_buses_by_number(sys::PSY.System) =
    Dict(PSY.get_number(b) => b for b in PSY.get_components(PSY.ACBus, sys))

function _member_test(zone::PSY.LoadZone)
    id = IS.get_id(zone)
    return bus -> _zone_id(PSY.get_load_zone(bus)) == id
end
_zone_id(::Nothing) = nothing
_zone_id(zone::PSY.LoadZone) = IS.get_id(zone)
function _member_test(hub::PSY.TradingHub)
    members = Set(PSY.get_number(b) for b in PSY.get_buses(hub))
    return bus -> PSY.get_number(bus) in members
end

"""
`_factor_series_labels`, also checking that every label is a member bus of `location`;
`buses` maps bus numbers to buses (`_buses_by_number`).
"""
function _factor_bus_labels(
    container::OptimizationContainer,
    location::PSY.Component,
    buses::Dict{Int, PSY.ACBus},
)
    labels = _factor_series_labels(container, location)
    labels === nothing && return nothing
    is_member = _member_test(location)
    for bus_no in labels
        bus = get(buses, bus_no, nothing)
        if bus === nothing || !is_member(bus)
            throw(
                ArgumentError(
                    "$(summary(location)) has a $(DISTRIBUTION_FACTOR_TS_NAME) column " *
                    "for bus $(bus_no), which is not a member.",
                ),
            )
        end
    end
    return labels
end

_get_time_series_name(::Type{DistributionFactorParameter}, ::PSY.Component, ::DeviceModel) =
    DISTRIBUTION_FACTOR_TS_NAME

function calc_additional_axes(
    container::OptimizationContainer,
    ::Type{DistributionFactorParameter},
    locations::Vector{D},
    ::DeviceModel{D, NodalRedistribution},
) where {D <: Union{PSY.LoadZone, PSY.TradingHub}}
    return (1:maximum(l -> length(_factor_series_labels(container, l)), locations),)
end

# Locations that own a series get a parameter row; a hub without one is uniform and a zone
# without one errors, both in the reader. Returns the bus lookup and each location's
# validated labels (`nothing` without a series) for the reader of the same call.
function _add_distribution_factor_parameters!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::DeviceModel{T, NodalRedistribution},
    locations::Vector{T},
) where {T <: Union{PSY.LoadZone, PSY.TradingHub}}
    buses = _buses_by_number(sys)
    labels = Dict(
        PSY.get_name(l) => _factor_bus_labels(container, l, buses) for l in locations
    )
    owners = T[l for l in locations if labels[PSY.get_name(l)] !== nothing]
    if !isempty(owners)
        add_parameters!(container, DistributionFactorParameter, owners, model)
    end
    return (buses = buses, labels = labels)
end

_add_distribution_factor_parameters!(
    ::OptimizationContainer,
    ::PSY.System,
    ::DeviceModel,
    ::Vector,
) = nothing

function _zero_factors(
    container::OptimizationContainer,
    buses::Vector{PSY.ACBus},
    network_model::NetworkModel,
)
    reduction = get_network_reduction(network_model)
    bus_numbers = sort!(unique([PNM.get_mapped_bus_number(reduction, b) for b in buses]))
    time_steps = get_time_steps(container)
    factors = JuMP.Containers.DenseAxisArray(
        zeros(length(bus_numbers), length(time_steps)), bus_numbers, time_steps,
    )
    return reduction, factors
end

"""
Read the distribution factors of `location` from its `DistributionFactorParameter` row into a
numeric `(retained bus number, time step)` array; the bus labels come from the series
metadata and are the buses that carry factors (factor quality, such as summing to one, is an
ingestion concern). An unavailable member's column is dropped, and a column on a bus
eliminated by the network reduction adds into its retained bus. A column for a bus that is
not a member is an error.
"""
function get_distribution_factors(
    container::OptimizationContainer,
    sys::PSY.System,
    location::Union{PSY.LoadZone, PSY.TradingHub},
    network_model::NetworkModel,
)
    buses = _buses_by_number(sys)
    labels = _factor_bus_labels(container, location, buses)
    return _distribution_factors(container, sys, location, network_model, labels, buses)
end

function _distribution_factors(
    container::OptimizationContainer,
    sys::PSY.System,
    location::T,
    network_model::NetworkModel{U},
    labels::Union{Nothing, Vector{Int}},
    buses::Dict{Int, PSY.ACBus},
) where {T <: Union{PSY.LoadZone, PSY.TradingHub}, U <: AbstractNetworkModel}
    if labels === nothing
        return _fallback_factors(container, sys, location, network_model)
    end
    name = PSY.get_name(location)
    key = IOM.ParameterKey(DistributionFactorParameter, T)
    if !(
        has_container_key(container, DistributionFactorParameter, T) &&
        IOM.has_lhs_parameter_component(container, key, name)
    )
        error(
            "$(summary(location)) carries a $(DISTRIBUTION_FACTOR_TS_NAME) series but the " *
            "model holds no $(DistributionFactorParameter) row for it; model the location " *
            "with DeviceModel($(T), NodalRedistribution).",
        )
    end
    live = [(j, buses[bus_no]) for (j, bus_no) in enumerate(labels)]
    filter!(((_, bus),) -> PSY.get_available(bus), live)
    if isempty(live)
        return _fallback_factors(container, sys, location, network_model)
    end
    shares = IOM.get_lhs_parameter_values(container, key, name)::Matrix{Float64}
    reduction, factors = _zero_factors(container, last.(live), network_model)
    time_steps = get_time_steps(container)
    for (j, bus) in live
        retained = PNM.get_mapped_bus_number(reduction, bus)
        for t in time_steps
            factors[retained, t] += shares[j, t]
        end
    end
    @debug "Distribution factor sums for $(name)" [
        sum(factors[:, t]) for t in time_steps
    ] _group = LOG_GROUP_OPTIMIZATION_CONTAINER
    return factors
end

"""A nodal settlement point distributes to itself: identity, factor 1.0."""
function get_distribution_factors(
    container::OptimizationContainer,
    ::PSY.System,
    bus::PSY.ACBus,
    network_model::NetworkModel{U},
) where {U <: AbstractNetworkModel}
    reduction = get_network_reduction(network_model)
    bus_no = PNM.get_mapped_bus_number(reduction, bus)
    time_steps = get_time_steps(container)
    return JuMP.Containers.DenseAxisArray(ones(1, length(time_steps)), [bus_no], time_steps)
end

# A LoadZone with no series anywhere is a data defect the ingestion side owns, but the
# zone still cannot silently vanish from the model: error naming the fix.
function _fallback_factors(
    ::OptimizationContainer,
    ::PSY.System,
    zone::PSY.LoadZone,
    ::NetworkModel,
)
    error(
        "Load zone $(PSY.get_name(zone)) has no $(DISTRIBUTION_FACTOR_TS_NAME) column for " *
        "an available member bus. Attach one Deterministic [time step, bus] matrix to the " *
        "zone with value_axes = [IS.TimeSeriesAxis(\"bus\", bus numbers)].",
    )
end

# A hub with no series distributes uniformly across its member buses: PSY documents hub
# member buses as unweighted, so uniform is a declared default, not a silent fallback.
function _fallback_factors(
    container::OptimizationContainer,
    sys::PSY.System,
    hub::PSY.TradingHub,
    network_model::NetworkModel,
)
    buses = get_member_buses(sys, hub)
    reduction, factors = _zero_factors(container, buses, network_model)
    share = 1.0 / length(buses)
    for bus in buses
        bus_no = PNM.get_mapped_bus_number(reduction, bus)
        for t in get_time_steps(container)
            factors[bus_no, t] += share
        end
    end
    return factors
end

const SettlementLocation = Union{PSY.ACBus, PSY.LoadZone, PSY.TradingHub}

"""
Settlement locations are topology and market components with no `available` flag, so
`get_available_components` does not apply. Honors the model's subsystem and
`"filter_function"` attribute the same way.
"""
function get_settlement_locations(
    model::DeviceModel{T, NodalRedistribution},
    sys::PSY.System,
) where {T <: SettlementLocation}
    subsystem = get_subsystem(model)
    filter_function = get_attribute(model, "filter_function")
    if filter_function === nothing
        return PSY.get_components(T, sys; subsystem_name = subsystem)
    end
    return PSY.get_components(filter_function, T, sys; subsystem_name = subsystem)
end

"""
Write a signed contribution into a settlement location's cleared-position expression.
The single API market transactions use; an unhandled location type (an `Area` or `Arc`)
has no method and fails loudly.
"""
function add_cleared_position!(
    container::OptimizationContainer,
    location::T,
    variable::JuMP.VariableRef,
    multiplier::Float64,
    t::Int,
) where {T <: SettlementLocation}
    expression = get_expression(container, AggregateClearedInjection, T)
    add_proportional_to_jump_expression!(
        expression[PSY.get_name(location), t], variable, multiplier,
    )
    return
end

function construct_market_component!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{T, NodalRedistribution},
    ::IOM.MarketModel,
    network_model::NetworkModel{<:AbstractNetworkModel},
) where {T <: SettlementLocation}
    assert_numeric_distribution_factors(container)
    locations = collect(get_settlement_locations(model, sys))
    factor_inputs = _add_distribution_factor_parameters!(container, sys, model, locations)
    names = PSY.get_name.(locations)
    time_steps = get_time_steps(container)
    add_expression_container!(container, AggregateClearedInjection, T, names, time_steps)
    variable = add_variable_container!(
        container, ClearedPositionVariable, T, names, time_steps,
    )
    jump_model = get_jump_model(container)
    for name in names, t in time_steps
        variable[name, t] = JuMP.@variable(
            jump_model,
            base_name = "$(ClearedPositionVariable)_$(T)_{$(name), $(t)}",
        )
    end
    # Argument stage: branches snapshot ActivePowerBalance into a fixed flow AffExpr, the
    # security-constrained ones during their own argument stage. A later write is lost.
    for location in locations
        distribute_cleared_position!(container, sys, location, network_model, factor_inputs)
    end
    return
end

function construct_market_component!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{T, NodalRedistribution},
    ::IOM.MarketModel,
    ::NetworkModel{<:AbstractNetworkModel},
) where {T <: SettlementLocation}
    names = PSY.get_name.(get_settlement_locations(model, sys))
    time_steps = get_time_steps(container)
    expression = get_expression(container, AggregateClearedInjection, T)
    variable = get_variable(container, ClearedPositionVariable, T)
    constraint = add_constraints_container!(
        container, ClearedPositionConstraint, T, names, time_steps,
    )
    jump_model = get_jump_model(container)
    for name in names, t in time_steps
        constraint[name, t] = JuMP.@constraint(
            jump_model, variable[name, t] == expression[name, t],
        )
    end
    return
end

"""
Fan a settlement location's cleared position out onto its member buses so a nodal network
model prices the congestion that position creates. Sign-free: every instrument wrote its
own sign into `AggregateClearedInjection`. Inline, one term per bus: no per-bus variable or
constraint. Factors are `Float64` coefficients, so the term stays linear even though the
position is a variable.
"""
function distribute_cleared_position!(
    container::OptimizationContainer,
    sys::PSY.System,
    location::T,
    network_model::NetworkModel{U},
    factor_inputs,
) where {T <: SettlementLocation, U <: AbstractNetworkModel}
    name = PSY.get_name(location)
    factors = _location_factors(container, sys, location, network_model, factor_inputs)
    position = get_variable(container, ClearedPositionVariable, T)
    nodal = get_expression(container, ActivePowerBalance, PSY.ACBus)
    for bus_no in axes(factors)[1], t in get_time_steps(container)
        add_proportional_to_jump_expression!(
            nodal[bus_no, t], position[name, t], factors[bus_no, t],
        )
    end
    return
end

# CopperPlate has no nodal expression to distribute into: the cleared position already
# sits in the system balance, so redistribution is a declared no-op, not a silently
# discovered one.
function distribute_cleared_position!(
    ::OptimizationContainer,
    ::PSY.System,
    ::T,
    ::NetworkModel{CopperPlateNetworkModel},
    _,
) where {T <: SettlementLocation}
    return
end

# `factor_inputs` is what `_add_distribution_factor_parameters!` returned in the same call.
_location_factors(container, sys, bus::PSY.ACBus, network_model, ::Nothing) =
    get_distribution_factors(container, sys, bus, network_model)
_location_factors(
    container,
    sys::PSY.System,
    location::Union{PSY.LoadZone, PSY.TradingHub},
    network_model,
    factor_inputs,
) = _distribution_factors(
    container,
    sys,
    location,
    network_model,
    factor_inputs.labels[PSY.get_name(location)],
    factor_inputs.buses,
)
