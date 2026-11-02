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

"""
Name of the device series that holds the offered size of each reserve offer block. Float64
values `[time step, block]` in natural units (MW), with `value_axes =
[IS.TimeSeriesAxis("block", 1:n)]` on the same blocks as the device's `reserve_offer_links`.
A linked row caps its block at this size. Without it the row takes the smallest width among
the linked steps, which is the block's size only while no curve was cut short.
"""
const RESERVE_OFFER_BLOCK_MW_TS_NAME = "reserve_offer_block_mw"

_attribute_on(model::DeviceModel, key::String) = get_attribute(model, key) === true

# A market component model of a non-Device type (e.g. a `VirtualParticipant`) has no
# available-device machinery, so the offer-limit rows cannot be built for it.
_offer_limit_candidate(::DeviceModel{<:PSY.Device}) = true
function _offer_limit_candidate(model::DeviceModel)
    for key in (LINKED_RESERVE_OFFERS_KEY, ENERGY_OFFER_CAP_KEY)
        if _attribute_on(model, key)
            error(
                "The \"$(key)\" attribute is not supported on $(get_component_type(model)): " *
                "offer-limit rows need a PSY.Device model.",
            )
        end
    end
    return false
end

_get_time_series_name(::Type{ReserveOfferLinkParameter}, ::PSY.Component, ::DeviceModel) =
    RESERVE_OFFER_LINKS_TS_NAME
_get_time_series_name(::Type{ReserveOfferBlockParameter}, ::PSY.Component, ::DeviceModel) =
    RESERVE_OFFER_BLOCK_MW_TS_NAME

# Links are step indices and block sizes are MW the rows convert themselves: the capacity
# multipliers some device families apply to time-series parameters must not scale either.
# The family-specific methods below are more specific than the families' own time-series
# multipliers.
for P in (ReserveOfferLinkParameter, ReserveOfferBlockParameter)
    @eval begin
        get_multiplier_value(
            ::Type{$P},
            ::PSY.Device,
            ::Type{<:AbstractDeviceFormulation},
        ) = 1.0
        get_multiplier_value(::Type{$P}, ::PSY.RenewableGen, ::Type{FixedOutput}) = 1.0
        get_multiplier_value(
            ::Type{$P},
            ::PSY.RenewableGen,
            ::Type{<:AbstractRenewableFormulation},
        ) = 1.0
        get_multiplier_value(::Type{$P}, ::PSY.ElectricLoad, ::Type{StaticPowerLoad}) = 1.0
        get_multiplier_value(
            ::Type{$P},
            ::PSY.ElectricLoad,
            ::Type{StaticPowerLoadBidAdjustment},
        ) = 1.0
        get_multiplier_value(
            ::Type{$P},
            ::PSY.ElectricLoad,
            ::Type{<:AbstractControllablePowerLoadFormulation},
        ) = 1.0
        get_multiplier_value(
            ::Type{$P},
            ::PSY.HydroGen,
            ::Type{<:AbstractHydroFormulation},
        ) = 1.0
        get_multiplier_value(::Type{$P}, ::PSY.HydroGen, ::Type{FixedOutput}) = 1.0
        get_multiplier_value(::Type{$P}, ::PSY.ThermalGen, ::Type{FixedOutput}) = 1.0
    end
end

# Rows and factors read their data once, at build, so parameters must be numbers: with
# `rebuild_model` off, `IOM.get_param_eltype` is `JuMP.VariableRef` and products turn nonlinear.
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

"""
Register the empty containers of the opt-in rows before the device model stage: IOM's device
dual hook throws for a listed constraint type that has no container yet.
"""
function add_offer_limit_containers!(
    container::OptimizationContainer,
    sys::PSY.System,
    template::PowerOperationsProblemTemplate,
)
    for model in values(get_service_device_models(template))
        _offer_limit_candidate(model) || continue
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
Build the opt-in offer-limit rows of every device and market component model and assign the duals it lists. Runs
after the services model stage, where the per-step reserve offer variables are created.
"""
function add_offer_limit_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    template::PowerOperationsProblemTemplate,
)
    for model in values(get_service_device_models(template))
        _offer_limit_candidate(model) || continue
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

_block_mw_message(d) =
    "The $(RESERVE_OFFER_BLOCK_MW_TS_NAME) series of $(PSY.get_name(d)) must hold Float64 " *
    "[time step, block] MW with value_axes = [IS.TimeSeriesAxis(\"block\", 1:n)], on the " *
    "blocks of its $(RESERVE_OFFER_LINKS_TS_NAME) series."

# The metadata of the one `name` series `d` owns at the model's resolution, or `nothing`.
function _offer_series_metadata(container::OptimizationContainer, d::PSY.Component, name)
    rows = IS.list_time_series_metadata(d; time_series_type = IS.Deterministic, name = name)
    isempty(rows) && return nothing
    if length(rows) > 1
        throw(
            ArgumentError(
                "$(PSY.get_name(d)) carries $(length(rows)) $(name) series; keep one.",
            ),
        )
    end
    md = only(rows)
    _check_window_resolution(container, md, d)
    return md
end

"""
Value axes of the `reserve_offer_links` series `d` owns, read from its metadata without
loading data, or `nothing` when it owns none. Errors for a second series, axes other than
`"block"` and `"product"` (service names), values other than Int64, or another resolution.
"""
function _links_value_axes(container::OptimizationContainer, d::PSY.Component)
    md = _offer_series_metadata(container, d, RESERVE_OFFER_LINKS_TS_NAME)
    md === nothing && return nothing
    value_axes = IS.get_value_axes(md)
    _check_series_layout(value_axes, ["block", "product"], String, _links_message(d))
    _check_value_type(eltype(md), Int64, _links_message(d))
    return value_axes
end

"""
Value axes of the `reserve_offer_block_mw` series `d` owns, or `nothing` when it owns none.
Errors for a second series, another resolution, values other than Float64, or a block axis
other than that of `d`'s `reserve_offer_links` series (`links_axes`).
"""
function _block_mw_value_axes(
    container::OptimizationContainer,
    d::PSY.Component,
    links_axes::Vector{IS.TimeSeriesAxis},
)
    md = _offer_series_metadata(container, d, RESERVE_OFFER_BLOCK_MW_TS_NAME)
    md === nothing && return nothing
    value_axes = IS.get_value_axes(md)
    blocks = _check_series_layout(value_axes, ["block"], Int, _block_mw_message(d))
    _check_value_type(eltype(md), Float64, _block_mw_message(d))
    blocks == first(links_axes).labels || throw(ArgumentError(_block_mw_message(d)))
    return value_axes
end

_check_value_type(found::Type, expected::Type, msg::String) =
    found === expected ? nothing : throw(ArgumentError(msg))

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

function calc_additional_axes(
    container::OptimizationContainer,
    ::Type{ReserveOfferBlockParameter},
    devices::Vector{D},
    ::DeviceModel{D, W},
) where {D <: PSY.Component, W <: AbstractDeviceFormulation}
    lengths = (
        IOM.get_value_length(
            _block_mw_value_axes(container, d, _links_value_axes(container, d)),
        ) for d in devices
    )
    return (1:maximum(lengths),)
end

# Devices with links get `ReserveOfferLinkParameter`; those of them that also state their
# block sizes get `ReserveOfferBlockParameter`.
function _add_offer_link_parameters!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::DeviceModel{D},
) where {D <: PSY.Component}
    owners = D[]
    sized = D[]
    for d in get_available_components(model, sys)
        links_axes = _links_value_axes(container, d)
        if links_axes === nothing
            _offer_series_metadata(container, d, RESERVE_OFFER_BLOCK_MW_TS_NAME) === nothing ||
                throw(ArgumentError(_block_mw_message(d)))
            continue
        end
        push!(owners, d)
        _block_mw_value_axes(container, d, links_axes) === nothing || push!(sized, d)
    end
    isempty(owners) && return
    add_parameters!(container, ReserveOfferLinkParameter, owners, model)
    isempty(sized) || add_parameters!(container, ReserveOfferBlockParameter, sized, model)
    return
end

_offered_services(cost::Union{PSY.MarketBidCost, PSY.MarketBidTimeSeriesCost}) =
    PSY.get_ancillary_service_offers(cost)
_offered_services(::PSY.OperationalCost) = PSY.Service[]

# Services by product label, resolved by name among the services `d` offers into, so the
# column order need not follow `ancillary_service_offers`.
function _linked_services(d::PSY.Component, value_axes::Vector{IS.TimeSeriesAxis})
    offered =
        Dict(PSY.get_name(s) => s for s in _offered_services(PSY.get_operation_cost(d)))
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
of its steps at the block's size from the device's `reserve_offer_block_mw` series. A device
without one caps it at the smallest of the linked step widths, which is the block's size only
while no curve was cut short: a curve cut at one service's limit would otherwise cap the
block's awards in every service at that limit.
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
        _add_linked_offer_rows!(container, rows, blk, key, d, _block_sizes(container, d))
    end
    return
end

# `[block, time step]` sizes in system units from `d`'s `ReserveOfferBlockParameter` row, or
# `nothing` when it states none.
function _block_sizes(container::OptimizationContainer, d::D) where {D <: PSY.Component}
    has_container_key(container, ReserveOfferBlockParameter, D) || return nothing
    key = IOM.ParameterKey(ReserveOfferBlockParameter, D)
    name = PSY.get_name(d)
    IOM.has_lhs_parameter_component(container, key, name) || return nothing
    value_axes = _block_mw_value_axes(container, d, _links_value_axes(container, d))
    mw = IOM.get_lhs_parameter_values(container, key, name, value_axes)::Matrix{Float64}
    return mw ./ get_model_base_power(container)
end

function _add_linked_offer_rows!(
    container::OptimizationContainer,
    rows::JuMP.Containers.SparseAxisArray,
    blk::JuMP.Containers.SparseAxisArray,
    key::IOM.ParameterKey{ReserveOfferLinkParameter, D},
    d::D,
    sizes::Union{Nothing, Matrix{Float64}},
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
        cap = sizes === nothing ? width : sizes[b, t]
        rows[(name, b, t)] = JuMP.@constraint(jump_model, sum(terms) <= cap)
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
    on = _energy_offer_on(container, F, D)
    _add_energy_offer_cap_rows!(
        rows, container, F, get_available_components(model, sys), range_ub, on,
    )
    return
end

# Function barrier: `range_ub` and `on` come from abstractly typed containers.
function _add_energy_offer_cap_rows!(
    rows,
    container::OptimizationContainer,
    ::Type{F},
    devices,
    range_ub,
    on,
) where {F <: AbstractThermalFormulation}
    jump_model = get_jump_model(container)
    for d in devices
        _has_market_bid_cost(d) || continue
        name = PSY.get_name(d)
        pmax = PSY.get_active_power_limits(d, u"SU").max
        for t in get_time_steps(container)
            breakpoints, _ = IOM._get_pwl_data(IOM.IncrementalOffer(), container, d, t)
            top = last(breakpoints)
            (top <= first(breakpoints) || top >= pmax) && continue
            rows[(name, t)] = JuMP.@constraint(
                jump_model,
                range_ub[name, t] + _energy_offer_floor(on, F, d, t) <= top,
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

struct NoOnVariable end

_energy_offer_on(::OptimizationContainer, ::Type{<:AbstractThermalFormulation}, ::Type) =
    NoOnVariable()
_energy_offer_on(
    container::OptimizationContainer,
    ::Type{<:AbstractCompactUnitCommitment},
    ::Type{D},
) where {D <: PSY.ThermalGen} = get_variable(container, OnVariable, D)

# Energy is the range expression's variable, plus pmin for compact formulations, whose
# expression holds only the power above minimum.
_energy_offer_floor(
    ::NoOnVariable,
    ::Type{<:AbstractThermalFormulation},
    ::PSY.ThermalGen,
    ::Int,
) = 0.0

function _energy_offer_floor(
    on::AbstractArray,
    ::Type{<:AbstractCompactUnitCommitment},
    d::PSY.ThermalGen,
    t::Int,
)
    pmin = PSY.get_active_power_limits(d, u"SU").min
    if _is_must_run(d)
        return pmin
    end
    return pmin * on[PSY.get_name(d), t]
end

_energy_offer_floor(
    ::NoOnVariable,
    ::Type{ThermalCompactDispatch},
    ::PSY.ThermalGen,
    ::Int,
) = throw(
    ArgumentError("\"$(ENERGY_OFFER_CAP_KEY)\" does not support ThermalCompactDispatch."),
)
