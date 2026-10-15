get_multiplier_value(
    ::Type{<:TimeSeriesParameter},
    d::PSY.ElectricLoad,
    ::Type{StaticPowerLoadBidAdjustment},
) = -1 * PSY.get_max_active_power(d, u"SU")

_check_bid_adjustment_load_type(::Type{<:PSY.ElectricLoad}) = nothing
_check_bid_adjustment_load_type(::Type{L}) where {L <: PSY.MotorLoad} = error(
    "StaticPowerLoadBidAdjustment does not support $(L); model it with StaticPowerLoad.",
)

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{L, StaticPowerLoadBidAdjustment},
    network_model::NetworkModel{PTDFNetworkModel},
) where {L <: PSY.ElectricLoad}
    _check_bid_adjustment_load_type(L)
    devices = get_device_cache(model)
    if haskey(get_time_series_names(model), ActivePowerTimeSeriesParameter)
        add_parameters!(container, ActivePowerTimeSeriesParameter, devices, model)
    end
    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerTimeSeriesParameter,
        devices,
        model,
        network_model,
    )
    add_variables!(container, BidAdjustmentArmed, devices, StaticPowerLoadBidAdjustment)
    add_event_arguments!(container, devices, model, network_model)
    return
end

function construct_device!(
    ::OptimizationContainer,
    ::PSY.System,
    ::ArgumentConstructStage,
    ::DeviceModel{<:PSY.ElectricLoad, StaticPowerLoadBidAdjustment},
    ::NetworkModel{N},
) where {N <: AbstractNetworkModel}
    error(
        "StaticPowerLoadBidAdjustment computes BidAdjustmentArmed from PTDF shift factors " *
        "and supports only PTDFNetworkModel; the template uses $(N).",
    )
end

construct_device!(
    ::OptimizationContainer,
    ::PSY.System,
    ::ModelConstructStage,
    ::DeviceModel{<:PSY.ElectricLoad, StaticPowerLoadBidAdjustment},
    ::NetworkModel{PTDFNetworkModel},
) = nothing

_counts_for_bid_adjustment(::ConstraintKey) = false
_counts_for_bid_adjustment(
    key::ConstraintKey{FlowRateConstraint, <:PSY.ACTransmission},
) = _is_rate_meta(key.meta)
_counts_for_bid_adjustment(
    key::ConstraintKey{PostContingencyFlowRateConstraint, <:PSY.ACTransmission},
) = _is_rate_meta(key.meta)

function _binding_sign(meta::String)
    if meta == "ub"
        return 1.0
    elseif meta == "lb"
        return -1.0
    end
    error(
        "BidAdjustmentArmed reads only \"ub\" and \"lb\" branch-limit rows; got meta " *
        "\"$(meta)\".",
    )
end

# The slack that relaxes each row: `flow - slack_ub <= max` and `flow + slack_lb >= min`.
function _paired_slack(::Type{FlowRateConstraint}, meta::String)
    if _binding_sign(meta) > 0.0
        return FlowActivePowerSlackUpperBound
    end
    return FlowActivePowerSlackLowerBound
end

function _paired_slack(::Type{PostContingencyFlowRateConstraint}, meta::String)
    if _binding_sign(meta) > 0.0
        return PostContingencyFlowActivePowerSlackUpperBound
    end
    return PostContingencyFlowActivePowerSlackLowerBound
end

function _check_paired_slack(
    container::OptimizationContainer,
    key::ConstraintKey{T, V},
) where {T <: ConstraintType, V <: PSY.ACTransmission}
    S = _paired_slack(T, key.meta)
    has_container_key(container, S, V) && return
    error(
        "StaticPowerLoadBidAdjustment caps each $(T) row at its $(S) slack penalty, but " *
        "the $(V) model has no slacks. Set `use_slacks = true` on the $(V) DeviceModel.",
    )
end

function finalize_device_construction!(
    container::OptimizationContainer,
    ::PSY.System,
    ::DeviceModel{<:PSY.ElectricLoad, StaticPowerLoadBidAdjustment},
    ::NetworkModel{PTDFNetworkModel},
)
    duals = get_duals(container)
    for key in collect(keys(IOM.get_constraints(container)))
        _counts_for_bid_adjustment(key) || continue
        constraint = get_constraint(container, key)
        _is_row_less(constraint) && continue
        _check_paired_slack(container, key)
        haskey(duals, key) && continue
        _add_mirrored_dual_container!(container, key, constraint)
    end
    return
end

"""
A base-case branch limit of `branch_type` whose shadow price reached its cap fraction,
oriented by `sign` (`1.0` for the `"ub"` row, `-1.0` for `"lb"`).
"""
struct BaseCaseArmingRow
    branch_type::DataType
    name::String
    sign::Float64
end

"""
A post-contingency limit on monitored branch `name` under the registered contingency
`outage` whose shadow price reached its cap fraction, oriented like
`BaseCaseArmingRow`.
"""
struct PostContingencyArmingRow
    outage::Int
    name::String
    sign::Float64
end

function _at_cap(
    dual_value::Float64,
    objective,
    slack::JuMP.VariableRef,
    key::ConstraintKey,
)
    penalty = JuMP.coefficient(objective, slack)
    if penalty <= 0.0
        error(
            "The $(IOM.encode_key_as_string(key)) row relaxed by $(JuMP.name(slack)) has " *
            "objective coefficient $(penalty); BidAdjustmentArmed needs a positive slack " *
            "penalty as the row's shadow-price cap.",
        )
    end
    return abs(dual_value) >= BID_ADJUSTMENT_CAP_FRACTION * penalty
end

function _collect_rows_at_cap!(
    _,
    _,
    ::OptimizationContainer,
    _,
    key::ConstraintKey,
    dual,
)
    _counts_for_bid_adjustment(key) || return
    error(
        "BidAdjustmentArmed counts the $(IOM.encode_key_as_string(key)) row but cannot " *
        "read its dual container of type $(typeof(dual)).",
    )
end

function _collect_rows_at_cap!(
    base_rows::Dict{BaseCaseArmingRow, Set{Int}},
    _,
    container::OptimizationContainer,
    objective,
    key::ConstraintKey{FlowRateConstraint, V},
    dual::DenseAxisArray,
) where {V <: PSY.ACTransmission}
    # A row-less container whose dual the template requested has no slack to pair.
    (_counts_for_bid_adjustment(key) && !isempty(dual)) || return
    sign = _binding_sign(key.meta)
    slack = get_variable(container, _paired_slack(FlowRateConstraint, key.meta), V)
    _scan_base_rows!(base_rows, dual, slack, objective, key, sign, V)
    return
end

# Function barrier: `slack` comes from an abstractly typed container.
function _scan_base_rows!(base_rows, dual, slack, objective, key, sign, ::Type{V}) where {V}
    names, time_steps = axes(dual)
    for name in names, t in time_steps
        _at_cap(dual[name, t], objective, slack[name, t], key) || continue
        push!(get!(Set{Int}, base_rows, BaseCaseArmingRow(V, name, sign)), t)
    end
    return
end

function _collect_rows_at_cap!(
    _,
    contingency_rows::Dict{PostContingencyArmingRow, Set{Int}},
    container::OptimizationContainer,
    objective,
    key::ConstraintKey{PostContingencyFlowRateConstraint, V},
    dual::SparseAxisArray,
) where {V <: PSY.ACTransmission}
    (_counts_for_bid_adjustment(key) && !isempty(dual.data)) || return
    sign = _binding_sign(key.meta)
    slack = get_variable(
        container, _paired_slack(PostContingencyFlowRateConstraint, key.meta), V,
    )
    _scan_contingency_rows!(contingency_rows, dual, slack, objective, key, sign)
    return
end

# Function barrier: `slack` comes from an abstractly typed container.
function _scan_contingency_rows!(contingency_rows, dual, slack, objective, key, sign)
    for ((outage_id, name, t), value) in dual.data
        _at_cap(value, objective, slack[outage_id, name, t], key) || continue
        # Security-constrained models of different branch types share these rows; the
        # row identity omits `V` so a shared row is computed once.
        row = PostContingencyArmingRow(parse(Int, outage_id), name, sign)
        push!(get!(Set{Int}, contingency_rows, row), t)
    end
    return
end

function _rows_at_cap(container::OptimizationContainer)
    objective = JuMP.objective_function(get_jump_model(container))
    base_rows = Dict{BaseCaseArmingRow, Set{Int}}()
    contingency_rows = Dict{PostContingencyArmingRow, Set{Int}}()
    for (key, dual) in get_duals(container)
        _collect_rows_at_cap!(base_rows, contingency_rows, container, objective, key, dual)
    end
    return base_rows, contingency_rows
end

# Matrix column of each load's bus; a load on a reduced bus uses its retained bus.
function _load_columns(
    ptdf,
    reduction,
    ::Type{L},
    names,
    system::PSY.System,
) where {L <: PSY.ElectricLoad}
    lookup = PNM.get_bus_lookup(ptdf)
    columns = Dict{String, Int}()
    for name in names
        load = PSY.get_component(L, system, name)
        columns[name] = _bus_column(lookup, reduction, PSY.get_bus(load))
    end
    return columns
end

function _arm_loads!(
    armed::DenseAxisArray,
    columns::Dict{String, Int},
    sign::Float64,
    shift_factors::AbstractVector{Float64},
    time_steps::Set{Int},
)
    for (name, column) in columns
        sign * shift_factors[column] < BID_ADJUSTMENT_SHIFT_FACTOR_THRESHOLD || continue
        for t in time_steps
            armed[name, t] = 1.0
        end
    end
    return
end

function _arm_base_case_loads!(
    armed::DenseAxisArray,
    columns::Dict{String, Int},
    ptdf,
    catalog,
    base_rows::Dict{BaseCaseArmingRow, Set{Int}},
)
    for (row, time_steps) in base_rows
        shift_factors = _base_case_shift_factors(ptdf, catalog, row.branch_type, row.name)
        _arm_loads!(armed, columns, row.sign, shift_factors, time_steps)
    end
    return
end

# The function barrier: the network model reads are not type stable, so the row loops
# run in helpers that specialize on the concrete matrix types.
function calculate_aux_variable_value!(
    container::OptimizationContainer,
    key::AuxVarKey{BidAdjustmentArmed, L},
    system::PSY.System,
    context::PowerSolveContext,
) where {L <: PSY.ElectricLoad}
    armed = get_aux_variable(container, key)
    fill!(armed, 0.0)
    base_rows, contingency_rows = _rows_at_cap(container)
    isempty(base_rows) && isempty(contingency_rows) && return
    network_model = get_network_model(context)
    ptdf = get_network_matrix(network_model)
    catalog = get_branch_catalog(network_model)
    reduction = get_network_reduction(network_model)
    columns = _load_columns(ptdf, reduction, L, axes(armed)[1], system)
    _arm_base_case_loads!(armed, columns, ptdf, catalog, base_rows)
    if !isempty(contingency_rows)
        _arm_post_contingency_loads!(
            armed,
            columns,
            ptdf,
            get_contingency_matrix(network_model),
            catalog,
            IOM.get_modeled_branch_types(network_model),
            contingency_rows,
        )
    end
    return
end

function _arm_post_contingency_loads!(
    armed::DenseAxisArray,
    columns::Dict{String, Int},
    ptdf,
    modf,
    catalog,
    modeled_branch_types::Vector{DataType},
    contingency_rows::Dict{PostContingencyArmingRow, Set{Int}},
)
    _check_same_bus_order(modf, ptdf, "BidAdjustmentArmed")
    contingencies = PNM.get_registered_contingencies(modf)
    arcs = _monitored_arcs_by_name(
        catalog, modeled_branch_types,
        unique(row.name for row in keys(contingency_rows)),
    )
    # The "ub" and "lb" rows of one monitored branch and outage share a shift-factor vector.
    shift_factors = Dict{Tuple{Int, String}, Vector{Float64}}()
    for (row, time_steps) in contingency_rows
        vector = get!(shift_factors, (row.outage, row.name)) do
            _post_contingency_shift_factors(modf, contingencies, arcs, row.outage, row.name)
        end
        _arm_loads!(armed, columns, row.sign, vector, time_steps)
    end
    return
end
