# Opt-in device-model rows over offer data that spans services: linked reserve offer blocks
# are sold once, and energy plus upward reserve awards stay within the energy offer curve's
# top. Built in a final pass after every service model, when every block variable exists.

"""
Device model attribute. When `true`, a device's reserve offer blocks that its
`reserve_offer_links` series links across services are sold once
(`LinkedReserveOfferConstraint`). Off when absent.
"""
const LINKED_RESERVE_OFFERS_KEY = "linked_reserve_offers"

"""
Device model attribute for thermal formulations. When `true`, energy plus upward reserve
awards stay within the top of the device's energy offer curve (`EnergyOfferCapConstraint`).
A device without a market bid cost has no energy offer curve, so it gets no row. Off when
absent.
"""
const ENERGY_OFFER_CAP_KEY = "energy_offer_cap"

"""
Name of the device series that links reserve offer blocks across services. Int64 values
`[time step, block, service]`: the block's step in that service's offer curve, `0` when it is
not in it; `value_axes = [IS.TimeSeriesAxis("block", 1:n), IS.TimeSeriesAxis("product",
service names)]`. A row with fewer than two nonzero entries adds nothing, so padding is free.
"""
const RESERVE_OFFER_LINKS_TS_NAME = "reserve_offer_links"

_attribute_on(model::DeviceModel, key::String) = get_attribute(model, key) === true

_get_time_series_name(::Type{ReserveOfferLinkParameter}, ::PSY.Component, ::DeviceModel) =
    RESERVE_OFFER_LINKS_TS_NAME

# Links are step indices: the capacity multipliers some device families apply to
# time-series parameters must not scale them. The family-specific methods below are more
# specific than the families' own time-series multipliers.
get_multiplier_value(
    ::Type{ReserveOfferLinkParameter},
    ::PSY.Device,
    ::Type{<:AbstractDeviceFormulation},
) = 1.0
get_multiplier_value(
    ::Type{ReserveOfferLinkParameter},
    ::PSY.RenewableGen,
    ::Type{FixedOutput},
) = 1.0
get_multiplier_value(
    ::Type{ReserveOfferLinkParameter},
    ::PSY.RenewableGen,
    ::Type{<:AbstractRenewableFormulation},
) = 1.0
get_multiplier_value(
    ::Type{ReserveOfferLinkParameter},
    ::PSY.ElectricLoad,
    ::Type{StaticPowerLoad},
) = 1.0
get_multiplier_value(
    ::Type{ReserveOfferLinkParameter},
    ::PSY.ElectricLoad,
    ::Type{<:AbstractControllablePowerLoadFormulation},
) = 1.0
get_multiplier_value(
    ::Type{ReserveOfferLinkParameter},
    ::PSY.HydroGen,
    ::Type{<:AbstractHydroFormulation},
) = 1.0
get_multiplier_value(
    ::Type{ReserveOfferLinkParameter},
    ::PSY.HydroGen,
    ::Type{FixedOutput},
) = 1.0
get_multiplier_value(
    ::Type{ReserveOfferLinkParameter},
    ::PSY.ThermalGen,
    ::Type{FixedOutput},
) = 1.0

# Rows read links, step widths and offer curves once, at build, so without a rebuild they go
# stale. With `rebuild_model` off, time-series offer breakpoints are also `JuMP.VariableRef`,
# which the energy offer cap cannot compare.
function _require_numeric_params(container::OptimizationContainer, what::String)
    if IOM.get_param_eltype(container) !== Float64
        error("$(what) reads data at build; recurrent solves need rebuild_model = true.")
    end
    return
end

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

# Each step of a series multiplies one model time step, so the resolutions must match.
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

"""
Register the empty containers of the opt-in rows before the device model stage: IOM's device
dual hook throws for a listed constraint type that has no container yet.
"""
function add_offer_limit_containers!(
    container::OptimizationContainer,
    sys::PSY.System,
    template::PowerOperationsProblemTemplate,
)
    for model in values(get_device_models(template))
        validate_available_devices(model, sys) || continue
        _add_offer_limit_containers!(container, sys, model)
    end
    return
end

function _add_offer_limit_containers!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::DeviceModel{D},
) where {D <: PSY.Component}
    if _attribute_on(model, LINKED_RESERVE_OFFERS_KEY)
        _require_numeric_params(
            container, "The \"$(LINKED_RESERVE_OFFERS_KEY)\" device model attribute",
        )
        _add_offer_link_parameters!(container, sys, model)
        add_constraints_container!(
            container, LinkedReserveOfferConstraint, D, String[], Int[], Int[];
            sparse = true,
        )
    end
    if _attribute_on(model, ENERGY_OFFER_CAP_KEY)
        add_constraints_container!(
            container, EnergyOfferCapConstraint, D, String[], Int[]; sparse = true,
        )
    end
    return
end

"""
Build the opt-in offer-limit rows of every device model and assign the duals it lists. Runs
after the services model stage, where the per-step reserve offer variables are created.
"""
function add_offer_limit_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    template::PowerOperationsProblemTemplate,
)
    for model in values(get_device_models(template))
        validate_available_devices(model, sys) || continue
        _add_offer_limit_constraints!(container, sys, model)
    end
    return
end

function _add_offer_limit_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::DeviceModel{D, F},
) where {D <: PSY.Component, F <: AbstractDeviceFormulation}
    if _attribute_on(model, LINKED_RESERVE_OFFERS_KEY)
        add_linked_reserve_offer_constraints!(container, sys, model)
        _reassign_dual!(container, sys, LinkedReserveOfferConstraint, model)
    else
        _warn_ignored_offer_links(container, sys, model)
    end
    if _attribute_on(model, ENERGY_OFFER_CAP_KEY)
        _require_numeric_params(
            container, "The \"$(ENERGY_OFFER_CAP_KEY)\" device model attribute",
        )
        add_energy_offer_cap_constraints!(container, sys, model)
        _reassign_dual!(container, sys, EnergyOfferCapConstraint, model)
    end
    return
end

# The device stage built this dual over the empty registered container; rebuild it over
# the rows the pass added.
function _reassign_dual!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::Type{T},
    model::DeviceModel{D, F},
) where {T <: ConstraintType, D <: PSY.Component, F <: AbstractDeviceFormulation}
    T in IOM.get_duals(model) || return
    delete!(IOM.get_duals(container), IOM.ConstraintKey(T, D))
    IOM.assign_dual_variable!(container, T, get_available_components(model, sys), F)
    return
end

# Links on a device whose model leaves the attribute off are ignored: say so once per type.
function _warn_ignored_offer_links(
    container::OptimizationContainer,
    sys::PSY.System,
    model::DeviceModel{D},
) where {D <: PSY.Component}
    has_container_key(container, PiecewiseLinearBlockReserveOffer, D) || return
    for d in get_available_components(model, sys)
        IS.has_time_series(d, IS.Deterministic, RESERVE_OFFER_LINKS_TS_NAME) || continue
        @warn "$(D) devices carry $(RESERVE_OFFER_LINKS_TS_NAME) series (first: " *
              "$(PSY.get_name(d))), ignored without the \"$(LINKED_RESERVE_OFFERS_KEY)\" " *
              "device model attribute."
        return
    end
    return
end

_links_message(d) =
    "The $(RESERVE_OFFER_LINKS_TS_NAME) series of $(PSY.get_name(d)) must hold Int64 " *
    "[time step, block, product] values with value_axes = [IS.TimeSeriesAxis(\"block\", " *
    "1:n), IS.TimeSeriesAxis(\"product\", service names)]."

_links_metadata(d::PSY.Component) = IS.list_time_series_metadata(
    d;
    time_series_type = IS.Deterministic,
    name = RESERVE_OFFER_LINKS_TS_NAME,
)

_has_offer_links(d::PSY.Component) = !isempty(_links_metadata(d))

"""
Value axes of the `reserve_offer_links` series `d` owns, read from its metadata without
loading data. Errors for a second series, axes other than `"block"` and `"product"` (service
names), values other than Int64, or another resolution.
"""
function _links_value_axes(container::OptimizationContainer, d::PSY.Component)
    rows = _links_metadata(d)
    if length(rows) > 1
        throw(
            ArgumentError(
                "$(PSY.get_name(d)) carries $(length(rows)) " *
                "$(RESERVE_OFFER_LINKS_TS_NAME) series; keep one.",
            ),
        )
    end
    md = only(rows)
    _check_window_resolution(container, md, d)
    value_axes = IS.get_value_axes(md)
    _check_series_layout(value_axes, ["block", "product"], String, _links_message(d))
    _check_int_links(eltype(md), d)
    return value_axes
end

_check_int_links(::Type{Int64}, _) = nothing
_check_int_links(::Type, d) = throw(ArgumentError(_links_message(d)))

# Links are flattened onto one positional axis, not a (device, block, product, time) container:
# the 3-D fill setters, parameter writer and input recast have no 4-D methods, and every
# solve writes the outputs bundle through them.
function calc_additional_axes(
    container::OptimizationContainer,
    ::Type{ReserveOfferLinkParameter},
    devices::Vector{D},
    ::DeviceModel{D, W},
) where {D <: PSY.Component, W <: AbstractDeviceFormulation}
    lengths = (IOM.get_value_length(_links_value_axes(container, d)) for d in devices)
    return (1:maximum(lengths),)
end

function _add_offer_link_parameters!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::DeviceModel{D},
) where {D <: PSY.Component}
    owners = D[
        d for d in get_available_components(model, sys) if _has_offer_links(d)
    ]
    isempty(owners) && return
    add_parameters!(container, ReserveOfferLinkParameter, owners, model)
    return
end

_offered_services(cost::Union{PSY.MarketBidCost, PSY.MarketBidTimeSeriesCost}) =
    PSY.get_ancillary_service_offers(cost)
_offered_services(::PSY.OperationalCost) = PSY.Service[]

# The services `d` offers into, by name. Service bids are series named after the service, so
# two offered services with one name cannot carry separate curves.
function _offered_services_by_name(d::PSY.Component)
    offered = Dict{String, PSY.Service}()
    for s in _offered_services(PSY.get_operation_cost(d))
        name = PSY.get_name(s)
        if haskey(offered, name)
            throw(
                IS.ConflictingInputsError(
                    "$(PSY.get_name(d)) offers into two services named $(name) " *
                    "($(nameof(typeof(offered[name]))) and $(nameof(typeof(s)))); service " *
                    "bids are read by service name, so offered service names must be unique.",
                ),
            )
        end
        offered[name] = s
    end
    return offered
end

# Services by product label, resolved by name among the services `d` offers into, so the
# column order need not follow `ancillary_service_offers`.
function _linked_services(d::PSY.Component, value_axes::Vector{IS.TimeSeriesAxis})
    offered = _offered_services_by_name(d)
    services = PSY.Service[]
    labels =
        _check_series_layout(value_axes, ["block", "product"], String, _links_message(d))
    for label in labels
        if !haskey(offered, label)
            throw(
                IS.ConflictingInputsError(
                    "$(PSY.get_name(d)) links offer blocks into $(label), which is not " *
                    "among its ancillary_service_offers.",
                ),
            )
        end
        push!(services, offered[label])
    end
    return services
end

# Whether the model prices an offer of `d` into `service`: it has a service model and `d`
# contributes to it.
function _offer_modeled(
    container::OptimizationContainer,
    blk::JuMP.Containers.SparseAxisArray,
    d::PSY.Component,
    service::PSY.Service,
)
    first_key =
        (PSY.get_name(service), PSY.get_name(d), 1, first(get_time_steps(container)))
    return haskey(blk.data, first_key)
end

# Step widths of `d`'s offer curve for `service`, per time step.
_offer_widths(
    container::OptimizationContainer,
    d::D,
    service::PSY.Service,
) where {D <: PSY.Component} =
    [diff(bp) for (bp, _) in _reserve_offer_curves(container, D, d, service)]

"""
Rows of `LinkedReserveOfferConstraint` for the devices of `model` that carry a
`reserve_offer_links` series. A block linked into two or more modeled services caps the sum
of its steps at the smallest of their widths; widths agree unless a curve was cut short.
"""
function add_linked_reserve_offer_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::DeviceModel{D},
) where {D <: PSY.Component}
    rows = lazy_container_addition!(
        container, LinkedReserveOfferConstraint, D, String[], Int[], Int[];
        sparse = true,
    )
    has_container_key(container, PiecewiseLinearBlockReserveOffer, D) || return
    blk = get_variable(container, PiecewiseLinearBlockReserveOffer, D)
    has_container_key(container, ReserveOfferLinkParameter, D) || return
    key = IOM.ParameterKey(ReserveOfferLinkParameter, D)
    for d in get_available_components(model, sys)
        IOM.has_lhs_parameter_component(container, key, PSY.get_name(d)) || continue
        _add_linked_offer_rows!(container, rows, blk, key, d)
    end
    return
end

function _add_linked_offer_rows!(
    container::OptimizationContainer,
    rows::JuMP.Containers.SparseAxisArray,
    blk::JuMP.Containers.SparseAxisArray,
    key::IOM.ParameterKey{ReserveOfferLinkParameter, D},
    d::D,
) where {D <: PSY.Component}
    name = PSY.get_name(d)
    value_axes = _links_value_axes(container, d)
    links =
        IOM.get_lhs_parameter_values(container, key, name, value_axes)::Array{Float64, 3}
    # Product columns of the modeled services, with their step widths.
    modeled = [
        (p, service, _offer_widths(container, d, service)) for
        (p, service) in enumerate(_linked_services(d, value_axes)) if
        _offer_modeled(container, blk, d, service)
    ]
    jump_model = get_jump_model(container)
    for t in get_time_steps(container), b in axes(links, 1)
        terms = JuMP.VariableRef[]
        width = Inf
        for (p, service, widths) in modeled
            k = Int(links[b, p, t])
            k == 0 && continue
            steps = widths[t]
            if !(1 <= k <= length(steps))
                throw(
                    IS.ConflictingInputsError(
                        "$(name): block $(b) at step $(t) links to step $(k) of " *
                        "$(PSY.get_name(service)), whose offer curve has " *
                        "$(length(steps)) steps.",
                    ),
                )
            end
            push!(terms, blk[(PSY.get_name(service), name, k, t)])
            width = min(width, steps[k])
        end
        length(terms) < 2 && continue
        rows[(name, b, t)] = JuMP.@constraint(jump_model, sum(terms) <= width)
    end
    return
end

"""
Rows of `EnergyOfferCapConstraint`: energy plus upward reserve awards at most the top of the
energy offer curve. A step whose curve spans no MW offers no energy and gets no row; a top
at or above ``P^\\text{max}`` is already enforced by the range rows.
"""
function add_energy_offer_cap_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::DeviceModel{D, F},
) where {D <: PSY.ThermalGen, F <: AbstractThermalFormulation}
    rows = lazy_container_addition!(
        container, EnergyOfferCapConstraint, D, String[], Int[]; sparse = true,
    )
    range_ub = get_expression(container, ActivePowerRangeExpressionUB, D)
    _add_energy_offer_cap_rows!(
        rows, container, F, get_available_components(model, sys), range_ub,
    )
    return
end

# Function barrier: `range_ub` comes from an abstractly typed container. Energy is the range
# expression's variable plus `_min_power_series`, since compact formulations hold only the
# power above minimum.
function _add_energy_offer_cap_rows!(
    rows,
    container::OptimizationContainer,
    ::Type{F},
    devices,
    range_ub,
) where {F <: AbstractThermalFormulation}
    jump_model = get_jump_model(container)
    for d in devices
        _has_market_bid_cost(d) || continue
        name = PSY.get_name(d)
        pmax = PSY.get_active_power_limits(d, u"SU").max
        min_power = _min_power_series(container, F, d)
        for t in get_time_steps(container)
            breakpoints, _ = IOM._get_pwl_data(IOM.IncrementalOffer(), container, d, t)
            top = last(breakpoints)
            (top <= first(breakpoints) || top >= pmax) && continue
            rows[(name, t)] =
                JuMP.@constraint(jump_model, range_ub[name, t] + min_power[t] <= top)
        end
    end
    return
end

function add_energy_offer_cap_constraints!(
    ::OptimizationContainer,
    ::PSY.System,
    ::DeviceModel{D, F},
) where {D <: PSY.Component, F <: AbstractDeviceFormulation}
    throw(
        ArgumentError(
            "\"$(ENERGY_OFFER_CAP_KEY)\" is for thermal formulations; $(D) under $(F) " *
            "has no energy offer cap.",
        ),
    )
end
