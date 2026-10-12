#! format: off

"""
`MarketLoadBid`'s reserve range constraint reuses `PowerLoadDispatch`'s [0, max_active_power]
bound (electric_loads.jl), applied to the parameter-anchored range expressions instead of the
energy variable -- see the formulation docstring in `core/formulations.jl`.
"""
get_min_max_limits(
    d::PSY.ControllableLoad,
    ::Type{ActivePowerVariableLimitsConstraint},
    ::Type{MarketLoadBid},
) = (min = 0.0, max = PSY.get_max_active_power(d, u"SU"))

#! format: on

"""
`MarketLoadBid` bounds its reserve awards: `_seed_reserve_ranges_on_limits!` gives each
direction its own constant baseline, and the model stage constrains both range expressions
within `[0, max_active_power]`. Up-reserve sheds load from a `max_active_power` baseline
(`LB = pmax - Σ r_up >= 0`); down-reserve adds load from a zero baseline
(`UB = 0 + Σ r_down <= pmax`). Each direction sells the capability at most once across its
services, which is what the load-family `false` default guards against.
"""
supports_reserve_provision(::Type{MarketLoadBid}) = true

_reserve_direction(::PSY.Reserve{PSY.ReserveUp}) = :up
_reserve_direction(::PSY.Reserve{PSY.ReserveDown}) = :down
_reserve_direction(::PSY.Service) = nothing

"""
The two directions of a `MarketLoadBid` load's reserve range have different baselines
(`max_active_power` for up, zero for down) and no row links them, so a device serving both
could sell its whole capability twice. Reject a device with reserve services in both
directions loudly, naming the device and the services; an AS-only offer is one product, so
it never has both.
"""
function _validate_single_reserve_direction!(d::PSY.ControllableLoad)
    by_direction = Dict{Symbol, Vector{String}}()
    for service in PSY.get_services(d)
        dir = _reserve_direction(service)
        isnothing(dir) && continue
        push!(get!(by_direction, dir, String[]), PSY.get_name(service))
    end
    length(by_direction) < 2 && return
    error(
        "MarketLoadBid device $(PSY.get_name(d)) contributes to ReserveUp services " *
        "$(join(by_direction[:up], ", ")) and ReserveDown services " *
        "$(join(by_direction[:down], ", ")): its up- and down-reserve ranges have separate " *
        "baselines with no linking constraint, so it could sell its capability twice -- " *
        "split the offers across devices, or model it under a different load formulation.",
    )
end

"""
Seed a `MarketLoadBid` load's reserve ranges on constant baselines rather than its zero-fixed
energy variable: the LB on `max_active_power` (up-reserve sheds load from full consumption)
and the UB on zero (down-reserve adds load from none). The energy variable never enters
either range, so the awards put nothing on the settlement or physical balance.
"""
function _seed_reserve_ranges_on_limits!(
    container::OptimizationContainer,
    devices::Vector{L},
    model::DeviceModel{L, MarketLoadBid},
) where {L <: PSY.ControllableLoad}
    time_steps = get_time_steps(container)
    for T in (ActivePowerRangeExpressionLB, ActivePowerRangeExpressionUB)
        has_container_key(container, T, L) || add_expressions!(container, T, devices, model)
    end
    lb = get_expression(container, ActivePowerRangeExpressionLB, L)
    for d in devices
        name = PSY.get_name(d)
        pmax = PSY.get_max_active_power(d, u"SU")
        for t in time_steps
            add_proportional_to_jump_expression!(lb[name, t], pmax, 1.0)
        end
    end
    return
end

"""
Argument stage for `MarketLoadBid`: creates `ActivePowerVariable` (bounds `[0, max_active_power]`
from the generic `PSY.ElectricLoad` getters), fixes it to zero every period for a costless
market bid (`_is_costless_offer`), adds every device's energy variable to the single system-wide
`SettlementBalance` row at `-1.0` (a decremental contributor, coefficient added regardless of
priced/costless so the fixed-zero coefficient is exactly-once and provably zero-valued), builds
the priced devices' decremental `MarketBidCost` PWL parameters, and seeds the reserve range
expressions on their per-direction baselines. Never touches a physical `ActivePowerBalance` row -- the component's
physical forecast is carried by a separate `StaticPowerLoad`-formulated twin `DeviceModel` in
`template.devices`.
"""
function construct_market_component!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{L, MarketLoadBid},
    ::IOM.MarketModel,
    ::NetworkModel{<:AbstractNetworkModel},
) where {L <: PSY.ControllableLoad}
    devices = collect(get_available_components(model, sys))
    add_cost_expressions!(container, devices, model)
    time_steps = get_time_steps(container)
    settlement_expr = get_expression(container, IOM.SettlementBalance, PSY.System)

    add_variables!(container, ActivePowerVariable, devices, MarketLoadBid)
    p = get_variable(container, ActivePowerVariable, L)

    priced_devices = L[]
    for d in devices
        _validate_single_reserve_direction!(d)
        name = PSY.get_name(d)
        _add_settlement_terms!(settlement_expr, p, name, -1.0, time_steps)
        if _is_costless_offer(PSY.get_operation_cost(d))
            for t in time_steps
                JuMP.fix(p[name, t], 0.0; force = true)
            end
        else
            push!(priced_devices, d)
        end
    end

    if !isempty(priced_devices)
        process_market_bid_parameters!(container, priced_devices, model, false, true)
    end

    _seed_reserve_ranges_on_limits!(container, devices, model)
    return
end

"""
Model stage for `MarketLoadBid`: bounds the reserve range expressions within
`[0, max_active_power]` (`get_min_max_limits`, above) and prices priced devices' energy
variable through the standard decremental `MarketBidCost` path (`add_variable_cost!`);
costless devices contribute no objective terms (their variable is fixed to zero).
"""
function construct_market_component!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{L, MarketLoadBid},
    ::IOM.MarketModel,
    ::NetworkModel{N},
) where {L <: PSY.ControllableLoad, N <: AbstractNetworkModel}
    devices = collect(get_available_components(model, sys))

    add_range_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionLB,
        devices,
        model,
        N,
    )
    add_range_constraints!(
        container,
        ActivePowerVariableLimitsConstraint,
        ActivePowerRangeExpressionUB,
        devices,
        model,
        N,
    )

    priced_devices = [d for d in devices if !_is_costless_offer(PSY.get_operation_cost(d))]
    if !isempty(priced_devices)
        add_variable_cost!(container, ActivePowerVariable, priced_devices, MarketLoadBid)
    end
    return
end
