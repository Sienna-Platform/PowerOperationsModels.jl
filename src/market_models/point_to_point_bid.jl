#! format: off
get_variable_binary(::Type{ClearedTransferVariable}, ::Type{PSY.PointToPointBid}, ::Type{SpreadBid}) = false
get_variable_lower_bound(::Type{ClearedTransferVariable}, ::PSY.PointToPointBid, ::Type{SpreadBid}) = 0.0
# `max_active_power` is a plain natural-units MW field (not a convertible field), so the
# bound divides explicitly by the system base power, as `VirtualBidDispatch` does.
get_variable_upper_bound(::Type{ClearedTransferVariable}, d::PSY.PointToPointBid, ::Type{SpreadBid}) =
    PSY.get_max_active_power(d) / PSY.get_base_power(d, PSY.NU)

# Generic `= 1.0` PWL-parameter fallbacks for market components (not Device)
get_multiplier_value(::Type{<:AbstractPiecewiseLinearSlopeParameter}, ::PSY.PointToPointBid, ::Type{SpreadBid}) = 1.0
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::PSY.PointToPointBid, ::Type{SpreadBid}) = 1.0
#! format: on

"""
A spread bid prices a single award, so the offer direction is a pure function of the
formulation and the one-argument trait suffices. The curve sits on the incremental side,
which is PSY's contract for `spread_bid`, but it is a willingness to pay rather than an
offer to supply: the bid must clear while the cleared `to`-minus-`from` spread is at or
below its bid price, which is the marginal condition of a **benefit** term `- p * q`.
[`IncrementalBidOffer`](@ref) is that pairing — the incremental side with a negative
objective sign.
"""
IOM._vom_offer_direction(::Type{SpreadBid}) = IncrementalBidOffer()

"""
Route the spread bid's objective term through [`IncrementalBidOffer`](@ref) rather than the
generic incremental path, so the bid price enters the minimized objective as a benefit.
Mirrors the load and storage specializations in `market_bid_overrides.jl`, which pass their
own direction the same way. No demand-side guard is needed here: `_validate_spread_bid!`
has already rejected a decremental curve in the argument stage.
"""
function IOM.add_variable_cost_to_objective!(
    container::OptimizationContainer,
    ::Type{T},
    component::PSY.PointToPointBid,
    cost_function::PSY.OfferCurveCost,
    ::Type{SpreadBid},
) where {T <: VariableType}
    @debug "Spread Bid" _group = LOG_GROUP_COST_FUNCTIONS PSY.get_name(component)
    IOM.add_pwl_term_delta!(
        IncrementalBidOffer(),
        container,
        component,
        cost_function,
        T,
        SpreadBid,
    )
    return
end

# Curvity is validated per parameter type, and the incremental breakpoint parameter defaults
# to the convexity an incremental *offer* needs. A spread bid is priced with the opposite
# sign, so its curve must be concave (non-increasing bid prices) for the delta PWL
# relaxation to be exact.
IOM.validate_occ_component(
    ::Type{<:IncrementalPiecewiseLinearBreakpointParameter},
    device::PSY.PointToPointBid,
) = IOM.validate_occ_breakpoints_slopes(device, IncrementalBidOffer())

"""
Reject a `spread_bid` that cannot mean what a spread bid means.

FIXED/VARIABLE block-bid clearing is not modelled: a spread bid's whole model is one
divisible quantity per period, so a block style would be priced here as if divisible.

A willingness-to-pay on the `to`-minus-`from` spread lives on the incremental side (PSY
documents `spread_bid` as "incremental side only", and see `_vom_offer_direction` for why
that is the economically correct side). A curve authored on the decremental side would
otherwise leave the bid looking unpriced, so it is rejected rather than silently held at
zero. Both mirror `VirtualBidDispatch`'s `_validate_block_bid_vom!` idiom.
"""
function _validate_spread_bid!(container::OptimizationContainer, bid::PSY.PointToPointBid)
    cost = IOM.get_operation_cost(bid)
    name = PSY.get_name(bid)
    style = _curve_style(cost)
    if style != PSY.CurveStyles.CURVE
        error(
            "PointToPointBid $(name) has spread_bid curve_style $(style). Only CURVE is " *
            "supported: a spread bid clears as one divisible quantity per period, so " *
            "FIXED/VARIABLE block clearing has no meaning for it.",
        )
    end
    if IOM.is_nontrivial_offer(container, bid, get_input_offer_curves(cost))
        error(
            "PointToPointBid $(name) has a decremental spread_bid curve. A spread bid's " *
            "willingness-to-pay belongs on the incremental side; a decremental curve is " *
            "never priced and would leave the bid clearing free.",
        )
    end
    return
end

"""
Is the bid's incremental curve priced over the model horizon? False for the
`MarketBidCost(nothing)` placeholder and for a stored-but-inert time series — including the
common case of a block bid whose priced hours all fall outside a partial-day horizon.
"""
_spread_bid_is_priced(container::OptimizationContainer, bid::PSY.PointToPointBid) =
    IOM.is_nontrivial_offer(
        container,
        bid,
        get_output_offer_curves(IOM.get_operation_cost(bid)),
    )

"""
Hold an unpriced bid's transfer at zero for the whole horizon.

An unpriced bid gets no objective term and therefore no piecewise delta variables, so
nothing but the `max_active_power` envelope would bound its `ClearedTransferVariable`: it
would move its full peak MW from source to sink, in every hour, at zero cost. Zeroing the
upper bound is the same bound a priced bid already gets in its own inert hours, where the
piecewise constraint holds it to the curve's top breakpoint of zero.

One summary warning rather than one per bid: on a partial-day run the unpriced bids number
in the thousands, and a per-bid line is not read.
"""
function _zero_unpriced_transfers!(
    container::OptimizationContainer,
    bids::Vector{PSY.PointToPointBid},
)
    isempty(bids) && return
    variable = get_variable(container, ClearedTransferVariable, PSY.PointToPointBid)
    for bid in bids, t in get_time_steps(container)
        JuMP.set_upper_bound(variable[PSY.get_name(bid), t], 0.0)
    end
    shown = PSY.get_name.(bids[1:min(end, 5)])
    @warn "No incremental spread_bid curve over the model horizon for " *
          "$(length(bids)) PointToPointBid(s), $(sum(PSY.get_max_active_power, bids)) MW " *
          "of envelope in total. They carry no willingness-to-pay, so their cleared " *
          "transfer is held at zero rather than clearing free: " *
          "$(join(shown, ", "))$(length(bids) > length(shown) ? ", ..." : "")."
    return
end

"""
Validate the spread bids and add the incremental PWL parameters (slope/breakpoint) that a
time-series-backed `spread_bid` prices against. Mirrors `process_virtual_bid_parameters!`;
only the incremental side is processed, since PSY stores a spread bid's willingness-to-pay
curve on the incremental side only, and there are no startup/shutdown/cost-at-min fields to
process for a bid that carries no commitment.
"""
function process_spread_bid_parameters!(
    container::OptimizationContainer,
    bids,
    model::DeviceModel,
)
    for param in (
        IncrementalPiecewiseLinearSlopeParameter,
        IncrementalPiecewiseLinearBreakpointParameter,
    )
        _process_occ_parameters_helper(param, container, model, bids)
    end
    return
end

"""
Argument stage for `SpreadBid`: a point-to-point spread bid is one cleared quantity at two
locations with opposite signs, a withdrawal at `from` and an injection at `to`. The two
`add_cleared_position!` writes are the whole model of the instrument. Because they cancel
and each location's factor set is what distributes them, the bid contributes nothing net
system-wide and moves the solution only through the nodal pattern, which is what an
up-to-congestion bid is. It is excluded from `SettlementBalance` outright: its two settlement
terms would cancel exactly, so writing them would add non-zero entries for no effect. A
terminal type without a `NodalRedistribution` component model in the template fails loudly
on the missing `AggregateClearedInjection` container.

The stage also adds the incremental PWL parameters a time-series-backed `spread_bid` is
priced against in the model stage.
"""
function construct_market_component!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{PSY.PointToPointBid, SpreadBid},
    ::IOM.MarketModel,
    ::NetworkModel{<:AbstractNetworkModel},
)
    bids = collect(get_available_components(model, sys))
    names = PSY.get_name.(bids)
    time_steps = get_time_steps(container)
    add_cost_expressions!(container, bids, model)
    variable = add_variable_container!(
        container, ClearedTransferVariable, PSY.PointToPointBid, names, time_steps,
    )
    jump_model = get_jump_model(container)
    for bid in bids
        _validate_spread_bid!(container, bid)
        name = PSY.get_name(bid)
        for t in time_steps
            variable[name, t] = JuMP.@variable(
                jump_model,
                base_name = "$(ClearedTransferVariable)_$(PSY.PointToPointBid)_{$(name), $(t)}",
                lower_bound =
                    get_variable_lower_bound(ClearedTransferVariable, bid, SpreadBid),
                upper_bound =
                    get_variable_upper_bound(ClearedTransferVariable, bid, SpreadBid),
            )
            add_cleared_position!(container, PSY.get_from(bid), variable[name, t], -1.0, t)
            add_cleared_position!(container, PSY.get_to(bid), variable[name, t], 1.0, t)
        end
    end
    process_spread_bid_parameters!(container, bids, model)
    return
end

"""
Model stage for `SpreadBid`: the willingness-to-pay curve on the `to`-minus-`from` spread
(`PSY.get_spread_bid`, reached through `IOM.get_operation_cost`) becomes the bid's objective
term through the incremental PWL path, signed as a benefit ([`IncrementalBidOffer`](@ref)),
so the bid clears up to the quantity where its bid price meets the cleared spread.

A bid whose curve is inert over the whole horizon has no objective term and so no piecewise
bound; `_zero_unpriced_transfers!` holds it at zero instead of letting it clear its full
envelope free.

Two independent quantities bound the award and the tighter one binds: the
`max_active_power` envelope, which bounds the variable directly, and the offer curve's own
top breakpoint, which bounds it through the PWL delta constraint. Authoring them to
different values is legitimate (the curve is the offer), so they are not validated against
each other as `VirtualBidDispatch`'s block bids are.

No other constraints: everything else about the instrument is its two signed position
writes from the argument stage.
"""
function construct_market_component!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{PSY.PointToPointBid, SpreadBid},
    ::IOM.MarketModel,
    ::NetworkModel{<:AbstractNetworkModel},
)
    priced = PSY.PointToPointBid[]
    unpriced = PSY.PointToPointBid[]
    for bid in get_available_components(model, sys)
        push!(_spread_bid_is_priced(container, bid) ? priced : unpriced, bid)
    end
    _zero_unpriced_transfers!(container, unpriced)
    isempty(priced) && return
    wrapped = IS.FlattenIteratorWrapper(PSY.PointToPointBid, [priced])
    add_variable_cost!(container, ClearedTransferVariable, wrapped, SpreadBid)
    return
end
