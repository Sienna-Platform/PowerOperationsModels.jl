#! format: off

"""
`PSY.VirtualParticipant`'s `max_supply`/`max_demand` are plain natural-units MW fields
(no `PSY.SU`/`PSY.NU` unit-system argument — not a convertible field), while POM models
in system per-unit. Bounds divide explicitly by the system base power:
`PSY.get_base_power(d, PSY.NU)` falls back to the attached system's base power for a
component with no dedicated device `base_power` field, which is the case here.
"""
get_variable_upper_bound(::Type{ActivePowerOutVariable}, d::PSY.VirtualParticipant, ::Type{VirtualBidDispatch}) =
    PSY.get_max_supply(d) / PSY.get_base_power(d, PSY.NU)
get_variable_lower_bound(::Type{ActivePowerOutVariable}, ::PSY.VirtualParticipant, ::Type{VirtualBidDispatch}) = 0.0
get_variable_upper_bound(::Type{ActivePowerInVariable}, d::PSY.VirtualParticipant, ::Type{VirtualBidDispatch}) =
    PSY.get_max_demand(d) / PSY.get_base_power(d, PSY.NU)
get_variable_lower_bound(::Type{ActivePowerInVariable}, ::PSY.VirtualParticipant, ::Type{VirtualBidDispatch}) = 0.0

get_variable_binary(::Type{ActivePowerOutVariable}, ::Type{<:PSY.VirtualParticipant}, ::Type{VirtualBidDispatch}) = false
get_variable_binary(::Type{ActivePowerInVariable}, ::Type{<:PSY.VirtualParticipant}, ::Type{VirtualBidDispatch}) = false

# FIXED-style block-bid commitment (z): binary, unbounded beyond {0,1}.
get_variable_binary(::Type{BlockBidCommitmentVariable}, ::Type{<:PSY.VirtualParticipant}, ::Type{VirtualBidDispatch}) = true

# Generic `= 1.0` PWL-parameter fallbacks for market components (not Device)
get_multiplier_value(::Type{<:AbstractPiecewiseLinearSlopeParameter}, ::PSY.VirtualParticipant, ::Type{VirtualBidDispatch}) = 1.0
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::PSY.VirtualParticipant, ::Type{VirtualBidDispatch}) = 1.0

#! format: on

"""
Per-variable VOM offer direction for `VirtualBidDispatch`: unlike single-variable
formulations (`IOM._vom_offer_direction(::Type{<:AbstractDeviceFormulation})`), a
`VirtualParticipant` has two independent cost-bearing variables on the SAME formulation, so
the formulation alone cannot tell which curve's VOM applies. `ActivePowerOutVariable` (the
supply/incremental award) reads its VOM off the incremental curve; `ActivePowerInVariable`
(the demand/decremental award) reads its VOM off the decremental curve.
"""
IOM._vom_offer_direction(::Type{ActivePowerOutVariable}, ::Type{VirtualBidDispatch}) =
    IOM.IncrementalOffer()
IOM._vom_offer_direction(::Type{ActivePowerInVariable}, ::Type{VirtualBidDispatch}) =
    IOM.DecrementalOffer()

"""
A FIXED bid is priced from its curve's total value on the commitment binary
(`_add_block_bid_objective_terms!`), a path that never reads VOM; VARIABLE bids go through
`add_variable_cost!`, which does. A nonzero VOM on a FIXED bid would vanish from the
objective, so it is rejected loudly (mirrors the `ImportExportCost` "VOM cost must be zero"
idiom in `_validate_occ_subtype`).
"""
function _validate_block_bid_vom!(d::PSY.VirtualParticipant, style::PSY.CurveStyles)
    style == PSY.CurveStyles.FIXED || return
    cost = PSY.get_operation_cost(d)
    for curve in (get_output_offer_curves(cost), get_input_offer_curves(cost))
        vom = IS.get_proportional_term(IS.get_vom_cost(curve))
        if !iszero(vom)
            error(
                "VirtualParticipant $(PSY.get_name(d)) has curve_style $(style) with a " *
                "nonzero VOM cost ($vom) on an offer curve. VOM is not supported for " *
                "FIXED block bids (it would silently drop from the objective); " *
                "set the offer curve's vom_cost to zero.",
            )
        end
    end
    return
end

"""
Validate `VirtualParticipant` `MarketBidCost`s and add the incremental/decremental PWL
parameters (slope/breakpoint, static or time-series-backed). Mirrors
`process_import_export_parameters!` for `Source`; startup/shutdown/cost-at-min are not
processed here since virtual bids carry no commitment. Runs for every device regardless
of `curve_style`: FIXED bids read their quantity and value off the same PWL parameters.
"""
function process_virtual_bid_parameters!(
    container::OptimizationContainer,
    devices_in,
    model::DeviceModel,
)
    devices = [d for d in devices_in if _has_market_bid_cost(d)]

    for d in devices
        _validate_block_bid_vom!(d, PSY.get_curve_style(PSY.get_operation_cost(d)))
    end

    for param in (
        IncrementalPiecewiseLinearSlopeParameter,
        IncrementalPiecewiseLinearBreakpointParameter,
        DecrementalPiecewiseLinearSlopeParameter,
        DecrementalPiecewiseLinearBreakpointParameter,
    )
        _process_occ_parameters_helper(param, container, model, devices)
    end
    return
end

#################################################################################
# Curve-style partition
#
# Every device gets a fresh ActivePowerOutVariable/InVariable per period; that award is
# what settles and what the location writes carry. VARIABLE devices price it through the
# per-period PWL path. FIXED devices add a per-period BlockBidCommitmentVariable (z) tied
# to the award by BlockBidQuantityConstraint (p = Q z) and priced on z. MULTI_STEP devices
# of either style link consecutive periods with identical offers (BlockBidLinkConstraint).
#################################################################################

"""
Split market components into the FIXED-style block bids (which get a
`BlockBidCommitmentVariable` and quantity rows) and the divisible VARIABLE bids (which get
the PWL cost path). Both construct stages need the same split.
"""
function _partition_by_curve_style(devices)
    fixed = eltype(devices)[]
    divisible = eltype(devices)[]
    for d in devices
        style = PSY.get_curve_style(PSY.get_operation_cost(d))
        if style == PSY.CurveStyles.FIXED
            push!(fixed, d)
        else
            push!(divisible, d)
        end
    end
    return fixed, divisible
end

_is_multistep(d::PSY.VirtualParticipant) =
    PSY.get_curve_multistep(PSY.get_operation_cost(d)) == PSY.CurveMultiStep.MULTI_STEP

_bid_settlement_sign(::IOM.IncrementalOffer) = 1.0
_bid_settlement_sign(::IOM.DecrementalOffer) = -1.0
_bid_direction_meta(::IOM.IncrementalOffer) = "Out"
_bid_direction_meta(::IOM.DecrementalOffer) = "In"
_bid_award_variable_type(::IOM.IncrementalOffer) = ActivePowerOutVariable
_bid_award_variable_type(::IOM.DecrementalOffer) = ActivePowerInVariable

_get_block_bid_variable(container::OptimizationContainer, dir::IOM.OfferDirection) =
    get_variable(
        container,
        BlockBidCommitmentVariable,
        PSY.VirtualParticipant,
        _bid_direction_meta(dir),
    )

_get_award_variable(container::OptimizationContainer, dir::IOM.OfferDirection) =
    get_variable(container, _bid_award_variable_type(dir), PSY.VirtualParticipant)

#################################################################################
# Offer curves period by period
#
# Two paths read an offer curve at each period through `IOM._get_pwl_data`, which resolves a
# static curve from the cost object and a time-series curve from the padded parameter
# arrays, both in system per-unit. A FIXED bid takes its quantity and value from it: `p = Q z`,
# the `z` objective term, and `z` fixed to zero where nothing is offered. A MULTI_STEP bid of
# either style takes its block boundaries from it: a block ends where consecutive periods
# stop carrying the same curve. The VARIABLE single-step path does not read it; its PWL
# delta terms read the parameters themselves.
#
# The parameter containers pad every curve to the widest segment count in the model, so a
# one-step curve comes back with zero-width segments appended. Real segments are the
# positive-width ones; the quantity is the top breakpoint either way.
#################################################################################

"`(breakpoints, slopes)` of `d`'s `dir` curve at period `t`, in per-unit; empty when that side has no curve."
function _curve_at(
    dir::IOM.OfferDirection,
    container::OptimizationContainer,
    d::IS.InfrastructureSystemsComponent,
    t::Int,
)
    IOM.is_nontrivial_offer(get_offer_curves(dir, d)) || return (Float64[], Float64[])
    breakpoints, slopes = IOM._get_pwl_data(dir, container, d, t)
    return (breakpoints, slopes)
end

"Quantity `d` offers in direction `dir` at period `t`, in per-unit; 0 when that side has no curve."
function _offer_quantity(
    dir::IOM.OfferDirection,
    container::OptimizationContainer,
    d::IS.InfrastructureSystemsComponent,
    t::Int,
)
    breakpoints, _ = _curve_at(dir, container, d, t)
    isempty(breakpoints) && return 0.0
    return Float64(maximum(breakpoints))
end

"Whether `d` offers a positive quantity in direction `dir` at some period."
_offers_quantity(
    dir::IOM.OfferDirection,
    container::OptimizationContainer,
    d::IS.InfrastructureSystemsComponent,
    time_steps,
) = any(t -> _offer_quantity(dir, container, d, t) > 0.0, time_steps)

"Number of positive-width segments in a padded breakpoint vector."
_real_segments(breakpoints) =
    count(i -> breakpoints[i + 1] > breakpoints[i] + 1e-9, 1:(length(breakpoints) - 1))

"""
Value of clearing a whole curve for one hour: `Σ slope_k × width_k` over its segments. For a
FIXED bid this is `price × quantity`, but the vectors come padded to the model's widest curve
(IOM repeats the last breakpoint, so the extra segments have zero width), and the sum stays
correct whatever the padding holds; a direct `slopes[1] × width_1` would rely on the real
segment being stored first.
"""
function _pwl_curve_total(breakpoints, slopes)::Float64
    total = 0.0
    for i in eachindex(slopes)
        total += slopes[i] * (breakpoints[i + 1] - breakpoints[i])
    end
    return total
end

"""
The FIXED devices that offer in direction `dir`: the names carrying a
`BlockBidCommitmentVariable` on that side. The argument stage creates that container only
for the FIXED devices with a positive quantity in the direction, so the model stage reads
the set off it instead of deriving it again; empty when no FIXED device offers there.
"""
function _block_bid_names(container::OptimizationContainer, dir::IOM.OfferDirection)
    key_present = IOM.has_container_key(
        container, BlockBidCommitmentVariable, PSY.VirtualParticipant,
        _bid_direction_meta(dir),
    )
    key_present || return String[]
    return collect(String, axes(_get_block_bid_variable(container, dir))[1])
end

function _new_bid_jump_var!(
    container::OptimizationContainer,
    ::Type{T},
    d::PSY.VirtualParticipant,
    t::Int,
) where {T <: VariableType}
    name = PSY.get_name(d)
    binary = get_variable_binary(T, PSY.VirtualParticipant, VirtualBidDispatch)
    var = JuMP.@variable(
        get_jump_model(container),
        base_name = "$(T)_$(PSY.VirtualParticipant)_{$(name), $(t)}",
        binary = binary,
    )
    ub = get_variable_upper_bound(T, d, VirtualBidDispatch)
    ub !== nothing && JuMP.set_upper_bound(var, ub)
    lb = get_variable_lower_bound(T, d, VirtualBidDispatch)
    lb !== nothing && !binary && JuMP.set_lower_bound(var, lb)
    if get_warm_start(get_settings(container))
        init = get_variable_warm_start_value(T, d, VirtualBidDispatch)
        init !== nothing && JuMP.set_start_value(var, init)
    end
    return var
end

function _populate_per_period_bid_variable!(
    container::OptimizationContainer,
    variable,
    ::Type{T},
    d::PSY.VirtualParticipant,
    time_steps,
) where {T <: VariableType}
    name = PSY.get_name(d)
    for t in time_steps
        variable[name, t] = _new_bid_jump_var!(container, T, d, t)
    end
    return
end

"""
A FIXED bid is one (quantity, price) point per period: every period that offers a
quantity must have exactly one positive-width segment. Static curves are checked by PSY at
construction; time-series curves only resolve here.
"""
function _validate_block_bid_segments!(
    dir::IOM.OfferDirection,
    container::OptimizationContainer,
    d::PSY.VirtualParticipant,
    time_steps,
)
    for t in time_steps
        breakpoints, _ = _curve_at(dir, container, d, t)
        (isempty(breakpoints) || maximum(breakpoints) <= 0.0) && continue
        segments = _real_segments(breakpoints)
        segments == 1 || error(
            "VirtualParticipant $(PSY.get_name(d)) has curve_style FIXED but its " *
            "$(_bid_direction_meta(dir)) offer curve at period $(t) has $(segments) " *
            "segments; a FIXED bid is a single segment per period.",
        )
    end
    return
end

"""
Creates the `BlockBidCommitmentVariable` (z) for every FIXED-style device and direction it
offers in, one per period, fixed to zero at periods with no quantity. Needs the PWL
parameters processed first.
"""
function _add_block_bid_commitment_variables!(
    container::OptimizationContainer,
    devices,
)
    isempty(devices) && return
    time_steps = get_time_steps(container)
    for dir in (IOM.IncrementalOffer(), IOM.DecrementalOffer())
        offering = [d for d in devices if _offers_quantity(dir, container, d, time_steps)]
        isempty(offering) && continue
        variable = add_variable_container!(
            container, BlockBidCommitmentVariable, PSY.VirtualParticipant,
            _bid_direction_meta(dir), PSY.get_name.(offering), time_steps,
        )
        for d in offering
            _validate_block_bid_segments!(dir, container, d, time_steps)
            name = PSY.get_name(d)
            for t in time_steps
                z = _new_bid_jump_var!(container, BlockBidCommitmentVariable, d, t)
                variable[name, t] = z
                _offer_quantity(dir, container, d, t) > 0.0 ||
                    JuMP.fix(z, 0.0; force = true)
            end
        end
    end
    return
end

"""
`p[d, t] - Q[d, t] z[d, t] == 0` for every FIXED device, direction with an offer, and
period. Where nothing is offered `Q = 0` and `z` is fixed, so the row pins the award to 0.
"""
function _add_block_bid_quantity_rows!(container::OptimizationContainer, devices)
    isempty(devices) && return
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    by_name = Dict(PSY.get_name(d) => d for d in devices)
    for dir in (IOM.IncrementalOffer(), IOM.DecrementalOffer())
        names = _block_bid_names(container, dir)
        isempty(names) && continue
        rows = add_constraints_container!(
            container, BlockBidQuantityConstraint, PSY.VirtualParticipant, names,
            time_steps;
            meta = _bid_direction_meta(dir),
        )
        p = _get_award_variable(container, dir)
        z = _get_block_bid_variable(container, dir)
        for name in names, t in time_steps
            quantity = _offer_quantity(dir, container, by_name[name], t)
            rows[name, t] = JuMP.@constraint(
                jump_model, p[name, t] - quantity * z[name, t] == 0,
            )
        end
    end
    return
end

# Function barrier: `z` is read from an abstractly-typed variable container, so the term is
# built and routed here against the concrete `JuMP.VariableRef`.
function _add_block_bid_cost_term!(
    container::OptimizationContainer,
    z,
    name::String,
    coefficient::Float64,
    t::Int,
    is_variant::Bool,
)
    cost_expr = coefficient * z
    add_cost_to_expression!(
        container,
        ProductionCostExpression,
        cost_expr,
        PSY.VirtualParticipant,
        name,
        t,
    )
    if is_variant
        IOM.add_to_objective_variant_expression!(container, cost_expr)
    else
        IOM.add_to_objective_invariant_expression!(container, cost_expr)
    end
    return
end

"""
FIXED-style objective terms: the block's per-period value (`_pwl_curve_total` of that
period's curve) multiplied by the period's commitment variable `z` and `dt`. `z` is the only
priced decision, so no PWL delta variables are built for these devices; VOM is rejected by
[`_validate_block_bid_vom!`](@ref) rather than dropped.
"""
function _add_block_bid_objective_terms!(
    container::OptimizationContainer,
    devices,
)
    isempty(devices) && return
    time_steps = get_time_steps(container)
    dt = Dates.value(get_resolution(container)) / MILLISECONDS_IN_HOUR
    by_name = Dict(PSY.get_name(d) => d for d in devices)
    for dir in (IOM.IncrementalOffer(), IOM.DecrementalOffer())
        names = _block_bid_names(container, dir)
        isempty(names) && continue
        z = _get_block_bid_variable(container, dir)
        sign = IOM._objective_sign(dir)
        for name in names
            d = by_name[name]
            is_variant = IOM.is_time_variant(get_offer_curves(dir, d))
            for t in time_steps
                block_value = _pwl_curve_total(_curve_at(dir, container, d, t)...)
                iszero(block_value) && continue
                _add_block_bid_cost_term!(
                    container,
                    z[name, t],
                    name,
                    sign * block_value * dt,
                    t,
                    is_variant,
                )
            end
        end
    end
    return
end

#################################################################################
# Multi-step blocks
#################################################################################

"Whether two padded PWL curves are the same offer (same breakpoints and slopes)."
_same_offer(breakpoints_a, slopes_a, breakpoints_b, slopes_b) =
    length(breakpoints_a) == length(breakpoints_b) &&
    isapprox(breakpoints_a, breakpoints_b; rtol = 1e-9, atol = 1e-12) &&
    isapprox(slopes_a, slopes_b; rtol = 1e-9, atol = 1e-9)

"""
    _block_runs(dir, container, d, time_steps) -> Vector{UnitRange{Int}}

The blocks of a MULTI_STEP component in direction `dir`, as ranges of periods: a period with
an offered quantity belongs to a block, and consecutive such periods stay in one block while
their curves are identical. A change of curve or a period with no quantity ends the block.
Adjacent blocks with the same curve cannot be told apart and count as one. A time-invariant
curve is one block over the whole window (or none), with no per-period comparison.
"""
function _block_runs(
    dir::IOM.OfferDirection,
    container::OptimizationContainer,
    d::IS.InfrastructureSystemsComponent,
    time_steps,
)
    runs = UnitRange{Int}[]
    curve = get_offer_curves(dir, d)
    IOM.is_nontrivial_offer(curve) || return runs
    if !IOM.is_time_variant(curve)
        offers = _offer_quantity(dir, container, d, first(time_steps)) > 0.0
        offers && push!(runs, first(time_steps):last(time_steps))
        return runs
    end
    start = 0
    previous = (Float64[], Float64[])
    for t in time_steps
        current = _curve_at(dir, container, d, t)
        if maximum(current[1]) <= 0.0
            start == 0 || push!(runs, start:(t - 1))
            start = 0
            continue
        end
        continues = start != 0 && _same_offer(current..., previous...)
        if !continues
            start == 0 || push!(runs, start:(t - 1))
            start = t
        end
        previous = current
    end
    start == 0 || push!(runs, start:last(time_steps))
    return runs
end

"""
Link rows for every MULTI_STEP device: `p[d, t] - p[d, t + 1] == 0` between consecutive
periods of each block longer than one period, per direction with an offer. The same row
serves FIXED and VARIABLE devices; for a FIXED block it is `z[t] = z[t + 1]` through the
quantity row, since a block has one quantity.
"""
function _add_block_bid_link_rows!(container::OptimizationContainer, devices)
    linked = [d for d in devices if _is_multistep(d)]
    isempty(linked) && return
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    for dir in (IOM.IncrementalOffer(), IOM.DecrementalOffer())
        blocks = Tuple{String, Vector{UnitRange{Int}}}[]
        for d in linked
            runs = _block_runs(dir, container, d, time_steps)
            long = UnitRange{Int}[r for r in runs if length(r) > 1]
            isempty(long) || push!(blocks, (PSY.get_name(d), long))
        end
        isempty(blocks) && continue
        names = String[name for (name, _) in blocks]
        rows = add_constraints_container!(
            container, BlockBidLinkConstraint, PSY.VirtualParticipant, names,
            time_steps;
            sparse = true, meta = _bid_direction_meta(dir),
        )
        p = _get_award_variable(container, dir)
        for (name, runs) in blocks, run in runs, t in first(run):(last(run) - 1)
            rows[name, t] = JuMP.@constraint(jump_model, p[name, t] - p[name, t + 1] == 0)
        end
    end
    return
end

"""
A virtual settles at a point OR at trading hubs (PSY enforces mutual exclusion); a virtual
with neither has no nodal footprint and writes nowhere. Under a nodal network model the
location must carry a `NodalRedistribution` component model, or the write fails loudly on
the missing `AggregateClearedInjection` container: the template asked to clear a located
virtual without modeling its location. Under `CopperPlateNetworkModel` location is moot and
the write is a declared no-op (see the method below). Location writes are additive to the
settlement-row writes: `AggregateClearedInjection` never feeds `SettlementBalance`, so
nothing is counted twice. Each hub receives the participant's full award: the current bid
plumbing carries one award per participant, not one per hub, so a participant settling at
several hubs is rejected until a per-hub split exists rather than silently over-injecting.
"""
function _add_virtual_location_writes!(
    container::OptimizationContainer,
    d::PSY.VirtualParticipant,
    p_out::JuMP.VariableRef,
    p_in::JuMP.VariableRef,
    t::Int,
    ::NetworkModel{<:AbstractNetworkModel},
)
    point = PSY.get_settlement_point(d)
    if point !== nothing
        add_cleared_position!(container, point, p_out, 1.0, t)
        add_cleared_position!(container, point, p_in, -1.0, t)
        return
    end
    hubs = PSY.get_trading_hubs(d)
    if length(hubs) > 1
        error(
            "VirtualParticipant $(PSY.get_name(d)) settles at $(length(hubs)) trading hubs, " *
            "but its award is a single quantity with no per-hub split; nodal distribution " *
            "supports one trading hub per participant.",
        )
    end
    for hub in hubs
        add_cleared_position!(container, hub, p_out, 1.0, t)
        add_cleared_position!(container, hub, p_in, -1.0, t)
    end
    return
end

function _add_virtual_location_writes!(
    ::OptimizationContainer,
    ::PSY.VirtualParticipant,
    ::JuMP.VariableRef,
    ::JuMP.VariableRef,
    ::Int,
    ::NetworkModel{CopperPlateNetworkModel},
)
    return
end
"""
Argument stage for `VirtualBidDispatch`: populates the MBC PWL parameters, creates a
per-period `ActivePowerOutVariable`/`ActivePowerInVariable` for every device and adds them
to the single system-wide `SettlementBalance` row (+out, -in) and to the settlement
location's `AggregateClearedInjection` (`_add_virtual_location_writes!`), then the
per-period `BlockBidCommitmentVariable` of the FIXED devices. Never touches a physical
`ActivePowerBalance` row directly: the location model distributes the position.
"""
function construct_market_component!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{PSY.VirtualParticipant, VirtualBidDispatch},
    ::IOM.MarketModel,
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    devices = get_available_components(model, sys)
    add_cost_expressions!(container, devices, model)
    process_virtual_bid_parameters!(container, devices, model)
    fixed_devices, _ = _partition_by_curve_style(devices)

    time_steps = get_time_steps(container)
    settlement_expr = get_expression(container, IOM.SettlementBalance, PSY.System)

    names = PSY.get_name.(devices)
    p_out = add_variable_container!(
        container, ActivePowerOutVariable, PSY.VirtualParticipant, names, time_steps,
    )
    p_in = add_variable_container!(
        container, ActivePowerInVariable, PSY.VirtualParticipant, names, time_steps,
    )
    for d in devices
        name = PSY.get_name(d)
        _populate_per_period_bid_variable!(
            container,
            p_out,
            ActivePowerOutVariable,
            d,
            time_steps,
        )
        _populate_per_period_bid_variable!(
            container,
            p_in,
            ActivePowerInVariable,
            d,
            time_steps,
        )
        _add_settlement_terms!(settlement_expr, p_out, name, 1.0, time_steps)
        _add_settlement_terms!(settlement_expr, p_in, name, -1.0, time_steps)
        for t in time_steps
            _add_virtual_location_writes!(
                container, d, p_out[name, t], p_in[name, t], t, network_model,
            )
        end
    end

    _add_block_bid_commitment_variables!(container, fixed_devices)
    return
end

"""
Model stage for `VirtualBidDispatch`: the PWL delta objective for VARIABLE devices
(`add_variable_cost!`), the quantity rows and `z`-priced objective for FIXED devices, and
the link rows of MULTI_STEP devices. No range or budget constraints — bounds are set
directly on the variables at creation.
"""
function construct_market_component!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{PSY.VirtualParticipant, VirtualBidDispatch},
    ::IOM.MarketModel,
    ::NetworkModel{<:AbstractNetworkModel},
)
    devices = get_available_components(model, sys)
    fixed_devices, divisible_devices = _partition_by_curve_style(devices)

    if !isempty(divisible_devices)
        wrapped = IS.FlattenIteratorWrapper(PSY.VirtualParticipant, [divisible_devices])
        add_variable_cost!(container, ActivePowerOutVariable, wrapped, VirtualBidDispatch)
        add_variable_cost!(container, ActivePowerInVariable, wrapped, VirtualBidDispatch)
    end
    _add_block_bid_quantity_rows!(container, fixed_devices)
    _add_block_bid_objective_terms!(container, fixed_devices)
    _add_block_bid_link_rows!(container, devices)
    return
end
