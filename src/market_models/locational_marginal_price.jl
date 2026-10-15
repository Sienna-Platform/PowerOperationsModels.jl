# Locational marginal prices: an aux variable on every energized bus, assembled after the
# solve from the duals of the rows a settled MW at that bus moves. See
# `LocationalMarginalPrice`.

"""
Names of the buses that get a price: every available bus whose mapped bus (after network
reductions) is a column of the PTDF, in bus-number order.
"""
function _locational_price_buses(
    sys::PSY.System,
    network_model::NetworkModel{PTDFNetworkModel},
)
    lookup = PNM.get_bus_lookup(get_network_matrix(network_model))
    reduction = get_network_reduction(network_model)
    buses = [
        b for b in PSY.get_components(PSY.get_available, PSY.ACBus, sys) if
        haskey(lookup, PNM.get_mapped_bus_number(reduction, b))
    ]
    sort!(buses; by = PSY.get_number)
    return PSY.get_name.(buses)
end

# The rows a settled MW at a bus moves, whose duals the price reads.
_prices_locationally(::ConstraintKey) = false
_prices_locationally(::ConstraintKey{SettlementBalanceConstraint, PSY.System}) = true
_prices_locationally(::ConstraintKey{CopperPlateBalanceConstraint, PSY.System}) = true
_prices_locationally(key::ConstraintKey{FlowRateConstraint, <:PSY.ACTransmission}) =
    _is_rate_meta(key.meta)
_prices_locationally(
    key::ConstraintKey{PostContingencyFlowRateConstraint, <:PSY.ACTransmission},
) = _is_rate_meta(key.meta)
_prices_locationally(key::ConstraintKey{InterfaceFlowLimit, PSY.TransmissionInterface}) =
    _is_rate_meta(key.meta)
_prices_locationally(
    ::ConstraintKey{ActivePowerFlowControlConstraint, <:PSY.ACTransmission},
) =
    true

# The bus position rows the price is checked against after it is assembled.
_checks_locational_prices(::ConstraintKey) = false
_checks_locational_prices(::ConstraintKey{ClearedPositionConstraint, PSY.ACBus}) = true

# Rows that limit a flow but that the price does not read: building them with
# `locational_prices = true` would report prices that ignore them.
_unread_flow_row(::ConstraintKey) = false
_unread_flow_row(::ConstraintKey{NetworkFlowConstraint}) = true
_unread_flow_row(::ConstraintKey{OperationalFlowLimitConstraint}) = true
_unread_flow_row(::ConstraintKey{LineFlowBoundConstraint}) = true
_unread_flow_row(key::ConstraintKey{FlowRateConstraint}) = !_is_rate_meta(key.meta)
_unread_flow_row(key::ConstraintKey{PostContingencyFlowRateConstraint}) =
    !_is_rate_meta(key.meta)
_unread_flow_row(key::ConstraintKey{InterfaceFlowLimit}) = !_is_rate_meta(key.meta)

function _check_locational_price_rows(container::OptimizationContainer)
    for key in keys(IOM.get_constraints(container))
        _unread_flow_row(key) || continue
        _is_row_less(get_constraint(container, key)) && continue
        error(
            "locational_prices = true cannot price the $(IOM.encode_key_as_string(key)) " *
            "rows; remove them or build the market model with locational_prices = false.",
        )
    end
    return
end

function _register_locational_price_duals!(container::OptimizationContainer)
    duals = get_duals(container)
    for key in collect(keys(IOM.get_constraints(container)))
        (_prices_locationally(key) || _checks_locational_prices(key)) || continue
        haskey(duals, key) && continue
        constraint = get_constraint(container, key)
        _is_row_less(constraint) && continue
        _add_mirrored_dual_container!(container, key, constraint)
    end
    return
end

"""
Runs once after every constraint is built. With `locational_prices = true` on the market
model, checks every flow-limit row is one the price reads, registers the duals it needs and
adds the `LocationalMarginalPrice` container over the energized buses.
"""
function finalize_market_construction!(
    container::OptimizationContainer,
    sys::PSY.System,
    template::PowerOperationsProblemTemplate,
)
    market_model = get_market_model(template)
    market_model === nothing && return
    IOM.get_locational_prices(market_model) || return
    network_model = get_network_model(template)
    _check_locational_price_rows(container)
    _register_locational_price_duals!(container)
    IOM.add_aux_variable_container!(
        container,
        LocationalMarginalPrice,
        PSY.ACBus,
        _locational_price_buses(sys, network_model),
        get_time_steps(container),
    )
    return
end

# ponytail: rows below this |dual| are skipped; interior-point solves leave ~1e-9 on every
# row. The skipped error is under n_rows * tol * max|SF| / base $/MWh.
const LOCATIONAL_PRICE_DUAL_TOL = 1e-6

"""Converts a dual (objective per per-unit power per time step) to \$/MWh."""
_price_scale(base_power::Float64, resolution::Dates.Period) =
    1.0 / (base_power * Dates.value(Dates.Millisecond(resolution)) / MILLISECONDS_IN_HOUR)

# Rows the price does not read contribute nothing; a read row in an unexpected container
# fails rather than dropping out of the price.
function _add_price_terms!(::Matrix{Float64}, ctx, key::ConstraintKey, dual)
    _prices_locationally(key) || return
    error(
        "LocationalMarginalPrice reads the $(IOM.encode_key_as_string(key)) rows but not " *
        "a dual container of type $(typeof(dual)).",
    )
end

function _add_price_terms!(
    marginal::Matrix{Float64},
    ctx,
    ::ConstraintKey{SettlementBalanceConstraint, PSY.System},
    dual::DenseAxisArray,
)
    row = only(axes(dual)[1])
    for t in axes(dual)[2]
        @views marginal[:, t] .+= dual[row, t]
    end
    return
end

function _add_price_terms!(
    marginal::Matrix{Float64},
    ctx,
    ::ConstraintKey{CopperPlateBalanceConstraint, PSY.System},
    dual::DenseAxisArray,
)
    for (reference, members) in IOM.get_subnetworks(ctx.network_model)
        columns = [ctx.lookup[b] for b in members if haskey(ctx.lookup, b)]
        for t in axes(dual)[2]
            @views marginal[columns, t] .+= dual[reference, t]
        end
    end
    return
end

function _add_price_terms!(
    marginal::Matrix{Float64},
    ctx,
    key::ConstraintKey{FlowRateConstraint, V},
    dual::DenseAxisArray,
) where {V <: PSY.ACTransmission}
    _prices_locationally(key) || return
    names, time_steps = axes(dual)
    for name in names, t in time_steps
        value = dual[name, t]
        abs(value) < LOCATIONAL_PRICE_DUAL_TOL && continue
        shift_factors = get!(ctx.shift_factors, (V, name)) do
            convert(Vector{Float64}, _base_case_shift_factors(ctx.ptdf, ctx.catalog, V, name))
        end
        @views marginal[:, t] .+= value .* shift_factors
    end
    return
end

function _fill_bus_prices!(
    prices::DenseAxisArray,
    marginal::Matrix{Float64},
    scale::Float64,
    system::PSY.System,
    reduction,
    lookup,
)
    buses = Dict(PSY.get_name(b) => b for b in PSY.get_components(PSY.ACBus, system))
    for name in axes(prices)[1]
        column = _bus_column(lookup, reduction, buses[name])
        for t in axes(prices)[2]
            prices[name, t] = marginal[column, t] * scale
        end
    end
    return
end

# The function barrier: the network model reads are not type stable, so the row loops run
# in `_add_price_terms!` methods that specialize on the key and dual container types.
function calculate_aux_variable_value!(
    container::OptimizationContainer,
    key::AuxVarKey{LocationalMarginalPrice, PSY.ACBus},
    system::PSY.System,
    context::PowerSolveContext,
)
    prices = get_aux_variable(container, key)
    network_model = get_network_model(context)
    ptdf = get_network_matrix(network_model)
    lookup = PNM.get_bus_lookup(ptdf)
    ctx = (
        network_model = network_model,
        ptdf = ptdf,
        catalog = get_branch_catalog(network_model),
        lookup = lookup,
        system = system,
        service_models = get_service_models(context),
        shift_factors = Dict{Any, Vector{Float64}}(),
        # An outage of several branch types shares its rows across their keys.
        post_contingency_rows = Set{Tuple{String, String, Int, String}}(),
    )
    marginal = zeros(length(lookup), length(get_time_steps(container)))
    for (dual_key, dual) in get_duals(container)
        _add_price_terms!(marginal, ctx, dual_key, dual)
    end
    scale = _price_scale(PSY.get_base_power(system), get_resolution(container))
    _fill_bus_prices!(
        prices, marginal, scale, system, get_network_reduction(network_model), lookup,
    )
    _check_against_position_duals(prices, container, scale)
    return
end

function _add_price_terms!(
    marginal::Matrix{Float64},
    ctx,
    key::ConstraintKey{PostContingencyFlowRateConstraint, V},
    dual::SparseAxisArray,
) where {V <: PSY.ACTransmission}
    _prices_locationally(key) || return
    rows = [(k, v) for (k, v) in dual.data if abs(v) >= LOCATIONAL_PRICE_DUAL_TOL]
    isempty(rows) && return
    modf = get_contingency_matrix(ctx.network_model)
    _check_same_bus_order(modf, ctx.ptdf, "LocationalMarginalPrice")
    contingencies = PNM.get_registered_contingencies(modf)
    arcs = _monitored_arcs_by_name(
        ctx.catalog,
        IOM.get_modeled_branch_types(ctx.network_model),
        unique(name for ((_, name, _), _) in rows),
    )
    for ((outage_id, name, t), value) in rows
        (outage_id, name, t, key.meta) in ctx.post_contingency_rows && continue
        push!(ctx.post_contingency_rows, (outage_id, name, t, key.meta))
        shift_factors = get!(ctx.shift_factors, (outage_id, name)) do
            convert(
                Vector{Float64},
                _post_contingency_shift_factors(
                    modf, contingencies, arcs, parse(Int, outage_id), name,
                ),
            )
        end
        @views marginal[:, t] .+= value .* shift_factors
    end
    return
end

# The contributing branches of interface `name`, from the ServiceModel that built its rows.
_interface_members(::ServiceModel, ::String) = nothing
_interface_members(model::ServiceModel{PSY.TransmissionInterface}, name::String) =
    get(get_contributing_devices_map(model), name, nothing)

function _interface_members(service_models::ServicesModelContainer, name::String)
    for model in values(service_models)
        members = _interface_members(model, name)
        members === nothing || return members
    end
    error("No TransmissionInterface ServiceModel lists interface \"$(name)\".")
end

function _interface_shift_factors(ctx, name::String)
    interface = PSY.get_component(PSY.TransmissionInterface, ctx.system, name)
    direction_map = PSY.get_direction_mapping(interface)
    shift_factors = zeros(length(ctx.lookup))
    for (br_type, devices) in _interface_members(ctx.service_models, name)
        for (_, arc, direction) in
            _interface_arc_directions(br_type, ctx.catalog, direction_map, devices)
            shift_factors .+= direction .* ctx.ptdf[arc, :]
        end
    end
    return shift_factors
end

function _add_price_terms!(
    marginal::Matrix{Float64},
    ctx,
    key::ConstraintKey{InterfaceFlowLimit, PSY.TransmissionInterface},
    dual::DenseAxisArray,
)
    _prices_locationally(key) || return
    names, time_steps = axes(dual)
    for name in names, t in time_steps
        value = dual[name, t]
        abs(value) < LOCATIONAL_PRICE_DUAL_TOL && continue
        shift_factors =
            get!(() -> _interface_shift_factors(ctx, name), ctx.shift_factors, name)
        @views marginal[:, t] .+= value .* shift_factors
    end
    return
end

function _add_price_terms!(
    marginal::Matrix{Float64},
    ctx,
    ::ConstraintKey{ActivePowerFlowControlConstraint, V},
    dual::DenseAxisArray,
) where {V <: PSY.ACTransmission}
    names, sides, time_steps = axes(dual)
    for name in names, side in sides, t in time_steps
        value = dual[name, side, t]
        abs(value) < LOCATIONAL_PRICE_DUAL_TOL && continue
        shift_factors = get!(ctx.shift_factors, (V, name)) do
            convert(Vector{Float64}, _base_case_shift_factors(ctx.ptdf, ctx.catalog, V, name))
        end
        @views marginal[:, t] .+= value .* shift_factors
    end
    return
end

# Largest gap, in $/MWh, between the price and the solver's own at a bus settlement location.
const LOCATIONAL_PRICE_CHECK_TOL = 1.0e-2

"""
Fail-closed check: at every bus settlement location the solver prices a settled MW at
(settlement dual - position dual) / S. A row family the price does not read shows up here.
"""
function _check_against_position_duals(
    prices::DenseAxisArray,
    container::OptimizationContainer,
    scale::Float64,
)
    duals = get_duals(container)
    position_key = ConstraintKey(ClearedPositionConstraint, PSY.ACBus)
    haskey(duals, position_key) || return
    position = duals[position_key]
    settlement = duals[ConstraintKey(SettlementBalanceConstraint, PSY.System)]
    row = only(axes(settlement)[1])
    priced = Set(axes(prices)[1])
    for name in axes(position)[1], t in axes(position)[2]
        name in priced || continue
        expected = (settlement[row, t] - position[name, t]) * scale
        abs(prices[name, t] - expected) <= LOCATIONAL_PRICE_CHECK_TOL && continue
        error(
            "LocationalMarginalPrice at bus $(name), step $(t) is $(prices[name, t]) but " *
            "the solver prices a settled MW there at $(expected): a constraint that moves " *
            "bus injections is not read. Build the market model with " *
            "locational_prices = false, or teach the price that constraint.",
        )
    end
    return
end
