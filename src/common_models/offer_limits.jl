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
Off when absent.
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

# The rows read offer data once, at build.
function _require_rebuild_model(container::OptimizationContainer, key::String)
    if IOM.get_param_eltype(container) !== Float64
        error(
            "The \"$(key)\" device model attribute reads offer data at build; recurrent " *
            "solves need rebuild_model = true.",
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
        _add_offer_limit_containers!(container, model)
    end
    return
end

function _add_offer_limit_containers!(
    container::OptimizationContainer,
    model::DeviceModel{D},
) where {D <: PSY.Component}
    if _attribute_on(model, LINKED_RESERVE_OFFERS_KEY)
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
        _require_rebuild_model(container, LINKED_RESERVE_OFFERS_KEY)
        add_linked_reserve_offer_constraints!(container, sys, model)
        _reassign_dual!(container, sys, LinkedReserveOfferConstraint, model)
    else
        _warn_ignored_offer_links(container, sys, model)
    end
    if _attribute_on(model, ENERGY_OFFER_CAP_KEY)
        _require_rebuild_model(container, ENERGY_OFFER_CAP_KEY)
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

# One window `[time step, value dims...]` of `owner`'s series and its value axes. Reads the
# forecast object: a window of rank 3 or more has no TimeArray form (`get_window` throws).
function _read_offer_window(container::OptimizationContainer, owner, name::String)
    forecast = IS.get_time_series(
        IS.Deterministic,
        owner,
        name;
        start_time = get_initial_time(container),
        len = length(get_time_steps(container)),
        count = 1,
    )
    if IS.get_resolution(forecast) != get_resolution(container)
        throw(
            IS.ConflictingInputsError(
                "$(PSY.get_name(owner)): series $(name) has resolution " *
                "$(IS.get_resolution(forecast)); the model runs at " *
                "$(get_resolution(container)).",
            ),
        )
    end
    return only(values(IS.get_data(forecast))), IS.get_value_axes(forecast)
end

_links_message(d) =
    "The $(RESERVE_OFFER_LINKS_TS_NAME) series of $(PSY.get_name(d)) must hold Int64 " *
    "[time step, block, product] values with value_axes = [IS.TimeSeriesAxis(\"block\", " *
    "1:n), IS.TimeSeriesAxis(\"product\", service names)]."

_product_labels(::Nothing, d) = throw(ArgumentError(_links_message(d)))
function _product_labels(value_axes::Vector{IS.TimeSeriesAxis}, d)
    if length(value_axes) != 2 || value_axes[1].name != "block" ||
       value_axes[2].name != "product"
        throw(ArgumentError(_links_message(d)))
    end
    return _string_labels(value_axes[2].labels, d)
end
_string_labels(labels::Vector{String}, _) = labels
_string_labels(::Vector{Int64}, d) = throw(ArgumentError(_links_message(d)))

_int_links(window::Array{Int64, 3}, _) = window
_int_links(::AbstractArray, d) = throw(ArgumentError(_links_message(d)))

_offered_services(cost::Union{PSY.MarketBidCost, PSY.MarketBidTimeSeriesCost}) =
    PSY.get_ancillary_service_offers(cost)
_offered_services(::PSY.OperationalCost) = PSY.Service[]

# Services by product label, resolved by name among the services `d` offers into, so the
# column order need not follow `ancillary_service_offers`.
function _linked_services(d::PSY.Component, value_axes)
    offered =
        Dict(PSY.get_name(s) => s for s in _offered_services(PSY.get_operation_cost(d)))
    services = PSY.Service[]
    for label in _product_labels(value_axes, d)
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

# Step widths of `d`'s curve for `service`, per time step, or `nothing` when the model
# prices no offer of `d` into it (no service model, or `d` does not contribute).
function _modeled_offer_widths(container, blk, d::D, service) where {D <: PSY.Component}
    first_key =
        (PSY.get_name(service), PSY.get_name(d), 1, first(get_time_steps(container)))
    haskey(blk.data, first_key) || return nothing
    return [diff(bp) for (bp, _) in _reserve_offer_curves(container, D, d, service)]
end

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
    for d in get_available_components(model, sys)
        IS.has_time_series(d, IS.Deterministic, RESERVE_OFFER_LINKS_TS_NAME) || continue
        _add_linked_offer_rows!(container, rows, blk, d)
    end
    return
end

function _add_linked_offer_rows!(container, rows, blk, d::D) where {D <: PSY.Component}
    name = PSY.get_name(d)
    window, value_axes = _read_offer_window(container, d, RESERVE_OFFER_LINKS_TS_NAME)
    links = _int_links(window, d)
    services = _linked_services(d, value_axes)
    widths = [_modeled_offer_widths(container, blk, d, s) for s in services]
    jump_model = get_jump_model(container)
    for t in get_time_steps(container), b in axes(links, 2)
        terms = JuMP.VariableRef[]
        width = Inf
        for (p, service) in enumerate(services)
            k = links[t, b, p]
            (k == 0 || widths[p] === nothing) && continue
            steps = widths[p][t]
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
    jump_model = get_jump_model(container)
    for d in get_available_components(model, sys)
        _has_market_bid_cost(d) || continue
        name = PSY.get_name(d)
        pmax = PSY.get_active_power_limits(d, u"SU").max
        for t in get_time_steps(container)
            breakpoints, _ = IOM._get_pwl_data(IOM.IncrementalOffer(), container, d, t)
            top = last(breakpoints)
            (top <= first(breakpoints) || top >= pmax) && continue
            rows[(name, t)] = JuMP.@constraint(
                jump_model,
                range_ub[name, t] + _energy_offer_floor(container, F, d, t) <= top,
            )
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

# Energy is the range expression's variable, plus pmin for compact formulations, whose
# expression holds only the power above minimum.
_energy_offer_floor(
    ::OptimizationContainer,
    ::Type{<:AbstractThermalFormulation},
    ::PSY.ThermalGen,
    ::Int,
) = 0.0

function _energy_offer_floor(
    container::OptimizationContainer,
    ::Type{<:AbstractCompactUnitCommitment},
    d::D,
    t::Int,
) where {D <: PSY.ThermalGen}
    pmin = PSY.get_active_power_limits(d, u"SU").min
    if _is_must_run(d)
        return pmin
    end
    return pmin * get_variable(container, OnVariable, D)[PSY.get_name(d), t]
end

_energy_offer_floor(
    ::OptimizationContainer,
    ::Type{ThermalCompactDispatch},
    ::PSY.ThermalGen,
    ::Int,
) = throw(
    ArgumentError("\"$(ENERGY_OFFER_CAP_KEY)\" does not support ThermalCompactDispatch."),
)
