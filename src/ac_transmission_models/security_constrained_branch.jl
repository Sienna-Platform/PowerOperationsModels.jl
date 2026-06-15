# MODF security-constrained branch formulation
# (`SecurityConstrainedStaticBranch`). Ported from PowerSimulations.jl
# `ac_transmission_security_constrained_models.jl` (PR #1579) and adapted to
# PS6 units (`PSY.SU`). The MODF-derived post-contingency flow expression is
# per-unit on the system base, so every emergency-rating RHS is per-unit too:
# PNM aggregators (`get_equivalent_emergency_rating`) are already system-base
# (NO `PSY.SU`); raw-device getters use `PSY.get_rating_b(d, PSY.SU)` (system
# per-unit) with fallback to `PSY.get_rating(d, PSY.SU)`.

# -----------------------------------------------------
# ------ RATING FUNCTIONS FOR EMERGENCY RATINGS -------
# -----------------------------------------------------
"""
Emergency Min and max limits for Abstract Branch Formulation and Post-Contingency conditions.
Covers both `PNM.BranchesParallel` (homogeneous) and `PNM.MixedBranchesParallel`
groups; PNM's `get_equivalent_emergency_rating` aggregates the per-circuit
emergency ratings as a sum-of-max, matching the max-flow capacity of the group.
The PNM aggregator is system-base (per-unit), so it is NOT passed `PSY.SU`.
"""
function get_emergency_min_max_limits(
    double_circuit::PNM.AbstractBranchesParallel,
    ::Type{<:PostContingencyConstraintType},
    ::Type{<:AbstractBranchFormulation},
)
    equivalent_rating = PNM.get_equivalent_emergency_rating(double_circuit)
    return (min = -1 * equivalent_rating, max = equivalent_rating)
end

"""
Min and max limits for Abstract Branch Formulation and Post-Contingency conditions
"""
function get_emergency_min_max_limits(
    transformer_entry::PNM.ThreeWindingTransformerWinding,
    ::Type{<:PostContingencyConstraintType},
    ::Type{<:AbstractBranchFormulation},
)
    equivalent_rating = PNM.get_equivalent_emergency_rating(transformer_entry)
    return (min = -1 * equivalent_rating, max = equivalent_rating)
end

"""
Min and max limits for Abstract Branch Formulation and Post-Contingency conditions
"""
function get_emergency_min_max_limits(
    series_chain::PNM.BranchesSeries,
    ::Type{<:PostContingencyConstraintType},
    ::Type{<:AbstractBranchFormulation},
)
    equivalent_rating = PNM.get_equivalent_emergency_rating(series_chain)
    return (min = -1 * equivalent_rating, max = equivalent_rating)
end

"""
Min and max limits for Abstract Branch Formulation and Post-Contingency conditions.
Raw `PSY.ACTransmission` device: the emergency rating is sourced from
`PNM.get_equivalent_emergency_rating` (system per-unit), which returns `rating_b`
and falls back to the normal-operation `rating` when `rating_b` is undefined —
matching the three reduction-entry methods above and keeping the rating fallback
in a single place. PNM emits an `@debug` note when the fallback is used.
"""
function get_emergency_min_max_limits(
    device::PSY.ACTransmission,
    ::Type{<:PostContingencyConstraintType},
    ::Type{<:AbstractBranchFormulation},
)
    equivalent_rating = PNM.get_equivalent_emergency_rating(device)
    return (min = -1 * equivalent_rating, max = equivalent_rating)
end

"""
Min and max limits for Abstract Branch Formulation and Post-Contingency conditions
"""
function get_emergency_min_max_limits(
    entry::PSY.PhaseShiftingTransformer,
    ::Type{PhaseAngleControlLimit},
    ::Type{PhaseAngleControl},
)
    return get_min_max_limits(entry, PhaseAngleControlLimit, PhaseAngleControl)
end

# -----------------------------------------------------
# ------ MULTI-COMPONENT OUTAGE DEDUP HELPERS ---------
# -----------------------------------------------------
# Dispatch (not an `isa` branch) skips non-sparse shared-arc containers: only
# the post-contingency `SparseAxisArray`s are keyed by (outage_id, name, t).
_post_contingency_match(c::SparseAxisArray, target::Tuple) = haskey(c.data, target)
_post_contingency_match(::AbstractArray, ::Tuple) = false

# A container is a reusable shared post-contingency source iff it has entry type
# `T`, belongs to a component type *other* than the outaged `V` (a same-`V`
# container is the one currently being built, not a source), and is keyed by
# `target`.
function _is_shared_post_contingency_source(
    key::OptimizationContainerKey,
    c,
    target::Tuple,
    ::Type{T},
    ::Type{V},
) where {T, V <: PSY.ACTransmission}
    return get_entry_type(key) === T &&
           get_component_type(key) !== V &&
           _post_contingency_match(c, target)
end

# Names of components of type `D` monitored by at least one outage on this
# device model.
function _monitored_component_names(device_model::DeviceModel, ::Type{D}) where {D}
    names = Set{String}()
    for (_, per_type) in get_outages(device_model)
        for (mon_type, mon_names) in per_type
            mon_type <: D || continue
            union!(names, mon_names)
        end
    end
    return names
end

# True when a `PostContingencyBranchRatingTimeSeriesParameter` column exists for
# `name` under `entry_type`.
function _has_post_contingency_rate(
    container::OptimizationContainer,
    entry_type::DataType,
    name::String,
)
    has_container_key(
        container,
        PostContingencyBranchRatingTimeSeriesParameter,
        entry_type,
    ) || return false
    param_container = get_parameter(
        container,
        PostContingencyBranchRatingTimeSeriesParameter(),
        entry_type,
    )
    return name in axes(get_multiplier_array(param_container))[1]
end

# The `(parameter column refs, multiplier slice)` for `name`'s post-contingency
# rate limit. Valid only when `_has_post_contingency_rate` is true.
function _post_contingency_rate_columns(
    container::OptimizationContainer,
    entry_type::DataType,
    name::String,
)
    param_container = get_parameter(
        container,
        PostContingencyBranchRatingTimeSeriesParameter(),
        entry_type,
    )
    return get_parameter_column_refs(param_container, name),
    get_multiplier_array(param_container)[name, :]
end

# Reactivated post-contingency branch-rating time series parameter, scoped to
# the monitored components only.
function _add_post_contingency_branch_rating_parameter!(
    container::OptimizationContainer,
    device_model::DeviceModel{T},
    devices,
    network_model::NetworkModel{<:PM.AbstractPowerModel},
) where {T <: PSY.ACTransmission}
    monitored = _monitored_component_names(device_model, T)
    monitored_devices = [d for d in devices if PSY.get_name(d) in monitored]
    isempty(monitored_devices) && return
    add_branch_parameters!(
        container,
        PostContingencyBranchRatingTimeSeriesParameter,
        monitored_devices,
        device_model,
        network_model,
    )
    return
end

function _find_shared_post_contingency_expression_source(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{V},
    outage_id::String,
    name::String,
    t::Int,
) where {T <: PostContingencyExpressions, V <: PSY.ACTransmission}
    target = (outage_id, name, t)
    for (key, ec) in IOM.get_expressions(container)
        _is_shared_post_contingency_source(key, ec, target, T, V) && return ec
    end
    return
end

"""
Constraint counterpart to `_find_shared_post_contingency_expression_source`.
Returns `(lb_source, ub_source)` SparseAxisArrays in one scan; either slot is
`nothing` when no shared container of that meta exists.
"""
function _find_shared_post_contingency_constraint_sources(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{V},
    outage_id::String,
    name::String,
    t::Int,
) where {T <: PostContingencyConstraintType, V <: PSY.ACTransmission}
    target = (outage_id, name, t)
    src_lb = nothing
    src_ub = nothing
    for (key, cc) in get_constraints(container)
        _is_shared_post_contingency_source(key, cc, target, T, V) || continue
        if key.meta == "lb"
            src_lb = cc
        elseif key.meta == "ub"
            src_ub = cc
        end
        !isnothing(src_lb) && !isnothing(src_ub) && break
    end
    return src_lb, src_ub
end

"""
Fast-path precheck: returns `true` iff any container of entry type `T` exists
under a component type other than `V`.
"""
function _has_other_v_container(
    container_dict,
    ::Type{T},
    ::Type{V},
) where {T, V <: PSY.ACTransmission}
    for key in keys(container_dict)
        get_entry_type(key) === T || continue
        get_component_type(key) === V && continue
        return true
    end
    return false
end

"""
Pre-allocate a `SparseAxisArray` keyed by
`(outage_id::String, monitored_name::String, t::Int)` holding `JuMP.AffExpr`
zeros for every entry produced by `_resolve_monitored_arcs`. The pre-fill is
required so the parallel PTDF expression build below cannot race on Dict resize.
"""
function _add_post_contingency_sparse_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{V},
    resolved::Vector{
        Pair{Base.UUID, Vector{Tuple{DataType, String, Tuple{Int, Int}, String}}},
    },
    time_steps::UnitRange{Int},
) where {T <: PostContingencyExpressions, V <: PSY.ACTransmission}
    contents = Dict{Tuple{String, String, Int}, JuMP.AffExpr}()
    for (uuid, entries) in resolved
        outage_id = string(uuid)
        for (_, name, _, _) in entries, t in time_steps
            contents[(outage_id, name, t)] = zero(JuMP.AffExpr)
        end
    end
    expr_container = SparseAxisArray(contents)
    IOM._assign_container!(container.expressions, ExpressionKey(T, V), expr_container)
    return expr_container
end

"""
Register an empty `SparseAxisArray` keyed by
`(outage_id::String, monitored_name::String, t::Int)` for the given constraint
type and meta tag.
"""
function _add_post_contingency_sparse_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{V};
    meta::String,
) where {T <: ConstraintType, V <: PSY.ACTransmission}
    cons_container =
        SparseAxisArray(Dict{Tuple{String, String, Int}, JuMP.ConstraintRef}())
    IOM._assign_container!(container.constraints, ConstraintKey(T, V, meta), cons_container)
    return cons_container
end

"""
For each outage in `device_model.outages`, resolve every monitored component
(across every monitored type) to its arc in the active reduction graph — using
`component_to_reduction_name_map` as a redirect when the monitored name is an
individual component that was reduced into a representative. Duplicate arcs
within an outage are collapsed per-type. Outages sorted by UUID for
deterministic axes.

Returns `Vector{Pair{UUID, Vector{Tuple{Type, String, Tuple{Int, Int}, String}}}}`
where each inner tuple is `(monitored_type, container_name, arc, reduction_kind)`.
"""
function _resolve_monitored_arcs(
    device_model::DeviceModel,
    net_reduction_data::PNM.NetworkReductionData,
)
    name_to_arc_maps = PNM.get_name_to_arc_maps(net_reduction_data)
    component_to_reduction_maps =
        PNM.get_component_to_reduction_name_map(net_reduction_data)
    resolved =
        Pair{Base.UUID, Vector{Tuple{DataType, String, Tuple{Int, Int}, String}}}[]
    for (uuid, per_type) in get_outages(device_model)
        kept = Tuple{DataType, String, Tuple{Int, Int}, String}[]
        for (T, names) in per_type
            name_to_arc = name_to_arc_maps[T]
            component_to_reduction =
                get(component_to_reduction_maps, T, Dict{String, String}())
            seen = Set{Tuple{Int, Int}}()
            for name in sort!(collect(names))
                if haskey(name_to_arc, name)
                    container_name = name
                elseif haskey(component_to_reduction, name)
                    container_name = component_to_reduction[name]
                else
                    error(
                        "Monitored component \"$name\" (type $T) for outage $uuid is " *
                        "absent from both the network-reduction name-to-arc map and the " *
                        "component-to-reduction map. Verify the component exists in the " *
                        "system and is modeled with a security-constrained branch formulation.",
                    )
                end
                arc, reduction_kind = name_to_arc[container_name]
                arc in seen && continue
                push!(seen, arc)
                push!(kept, (T, container_name, arc, reduction_kind))
            end
        end
        push!(resolved, uuid => kept)
    end
    sort!(resolved; by = first)
    return resolved
end

# Create a single post-contingency relaxation slack for `(outage_id, name, t)`,
# lower-bounded at zero, and penalize it inline at build time. This runs in the
# ModelConstructStage AFTER the branch objective (`add_to_objective_function!`)
# has already executed, so the penalty is registered directly on the invariant
# objective expression here rather than deferred to `objective_function!`. The
# slack inherits the inequality's units (per-unit on the system base).
function _make_post_contingency_slack!(
    container::OptimizationContainer,
    jump_model::JuMP.Model,
    slack_container::SparseAxisArray,
    ::Type{S},
    ::Type{V},
    outage_id::String,
    name::String,
    t::Int,
) where {S <: VariableType, V <: PSY.ACTransmission}
    slack = JuMP.@variable(
        jump_model,
        lower_bound = 0.0,
        base_name = "$(S)_$(V)_{$(outage_id), $(name), $(t)}",
    )
    slack_container[outage_id, name, t] = slack
    add_to_objective_invariant_expression!(
        container,
        slack * CONSTRAINT_VIOLATION_SLACK_COST,
    )
    return slack
end

"""
Add branch post-contingency rate limit constraints for ACBranch considering MODF and Security Constraints
"""
function add_constraints!(
    container::OptimizationContainer,
    cons_type::Type{T},
    device_model::DeviceModel{V, U},
    network_model::NetworkModel{X},
) where {
    T <: PostContingencyFlowRateConstraint,
    V <: PSY.ACTransmission,
    U <: AbstractSecurityConstrainedStaticBranch,
    X <: PM.AbstractPowerModel,
}
    time_steps = get_time_steps(container)

    net_reduction_data = network_model.network_reduction
    all_branch_maps_by_type = PNM.get_all_branch_maps_by_type(net_reduction_data)

    resolved = _resolve_monitored_arcs(device_model, net_reduction_data)

    con_lb = _add_post_contingency_sparse_constraints!(container, T, V; meta = "lb")
    con_ub = _add_post_contingency_sparse_constraints!(container, T, V; meta = "ub")

    use_slacks = get_use_slacks(device_model)
    # Local relaxation-slack containers keyed by `(outage_id, name, t)`. Built
    # here (not via `add_variables!`) because the post-contingency axes are only
    # known after `_resolve_monitored_arcs`; registered after the loop iff used.
    slack_ub = SparseAxisArray(Dict{Tuple{String, String, Int}, JuMP.VariableRef}())
    slack_lb = SparseAxisArray(Dict{Tuple{String, String, Int}, JuMP.VariableRef}())

    expressions = get_expression(container, PostContingencyBranchFlow, V)
    jump_model = get_jump_model(container)

    has_other_v = _has_other_v_container(get_constraints(container), T, V)
    has_pc_rating = haskey(
        get_time_series_names(device_model),
        PostContingencyBranchRatingTimeSeriesParameter,
    )
    for (uuid, entries) in resolved
        outage_id = string(uuid)
        for (entry_type, name, arc, reduction_kind) in entries
            if has_other_v
                src_lb, src_ub = _find_shared_post_contingency_constraint_sources(
                    container, T, V, outage_id, name, first(time_steps),
                )
                if !isnothing(src_lb) && !isnothing(src_ub)
                    # Reuse the first claimer's constraint refs verbatim; its
                    # slacks were already created and penalized, so do NOT add
                    # new ones here.
                    for t in time_steps
                        con_ub[outage_id, name, t] =
                            src_ub.data[(outage_id, name, t)]
                        con_lb[outage_id, name, t] =
                            src_lb.data[(outage_id, name, t)]
                    end
                    continue
                end
            end
            reduction_entry = all_branch_maps_by_type[reduction_kind][entry_type][arc]
            if has_pc_rating && _has_post_contingency_rate(container, entry_type, name)
                param, multiplier =
                    _post_contingency_rate_columns(container, entry_type, name)
                for t in time_steps
                    sub = if use_slacks
                        _make_post_contingency_slack!(
                            container, jump_model, slack_ub,
                            PostContingencyFlowActivePowerSlackUpperBound, V,
                            outage_id, name, t,
                        )
                    else
                        0.0
                    end
                    slb = if use_slacks
                        _make_post_contingency_slack!(
                            container, jump_model, slack_lb,
                            PostContingencyFlowActivePowerSlackLowerBound, V,
                            outage_id, name, t,
                        )
                    else
                        0.0
                    end
                    con_ub[outage_id, name, t] = JuMP.@constraint(
                        jump_model,
                        expressions[outage_id, name, t] - sub <=
                        param[t] * multiplier[t],
                    )
                    con_lb[outage_id, name, t] = JuMP.@constraint(
                        jump_model,
                        expressions[outage_id, name, t] + slb >=
                        -1.0 * param[t] * multiplier[t],
                    )
                end
            else
                limits = get_emergency_min_max_limits(reduction_entry, T, U)
                for t in time_steps
                    sub = if use_slacks
                        _make_post_contingency_slack!(
                            container, jump_model, slack_ub,
                            PostContingencyFlowActivePowerSlackUpperBound, V,
                            outage_id, name, t,
                        )
                    else
                        0.0
                    end
                    slb = if use_slacks
                        _make_post_contingency_slack!(
                            container, jump_model, slack_lb,
                            PostContingencyFlowActivePowerSlackLowerBound, V,
                            outage_id, name, t,
                        )
                    else
                        0.0
                    end
                    con_ub[outage_id, name, t] = JuMP.@constraint(
                        jump_model,
                        expressions[outage_id, name, t] - sub <= limits.max,
                    )
                    con_lb[outage_id, name, t] = JuMP.@constraint(
                        jump_model,
                        expressions[outage_id, name, t] + slb >= limits.min,
                    )
                end
            end
        end
    end

    if !isempty(slack_ub.data)
        IOM._assign_container!(
            container.variables,
            VariableKey(PostContingencyFlowActivePowerSlackUpperBound, V),
            slack_ub,
        )
    end
    if !isempty(slack_lb.data)
        IOM._assign_container!(
            container.variables,
            VariableKey(PostContingencyFlowActivePowerSlackLowerBound, V),
            slack_lb,
        )
    end
    return
end

function _build_post_contingency_flow_expressions_for_outage(
    time_steps::UnitRange{Int},
    outage_id::String,
    modf_cols::Dict{Tuple{String, Tuple{Int64, Int64}}, Vector{Float64}},
    nodal_balance_expressions::Matrix{JuMP.AffExpr},
    entries::Vector{Tuple{DataType, String, Tuple{Int, Int}, String}},
)
    results = Vector{Tuple{String, Vector{JuMP.AffExpr}}}(undef, length(entries))
    for (i, entry) in enumerate(entries)
        (_, name, arc, _) = entry
        modf_col = modf_cols[(outage_id, arc)]
        _, expressions = _make_flow_expressions!(
            name,
            time_steps,
            modf_col,
            nodal_balance_expressions,
        )
        results[i] = (name, expressions)
    end
    return results
end

function add_post_contingency_flow_expressions!(
    container::OptimizationContainer,
    ::Type{T},
    model::DeviceModel{V, F},
    network_model::NetworkModel{N},
) where {
    T <: PostContingencyBranchFlow,
    V <: PSY.ACTransmission,
    F <: AbstractSecurityConstrainedStaticBranch,
    N <: AbstractPTDFModel,
}
    time_steps = get_time_steps(container)
    modf_matrix = get_MODF_matrix(network_model)
    registered_contingencies = PNM.get_registered_contingencies(modf_matrix)

    net_reduction_data = network_model.network_reduction
    resolved = _resolve_monitored_arcs(model, net_reduction_data)

    expression_container = _add_post_contingency_sparse_expression!(
        container, T, V, resolved, time_steps,
    )

    fresh_resolved = _copy_existing_post_contingency_expressions!(
        container, T, V, expression_container, resolved, time_steps,
    )
    isempty(fresh_resolved) && return

    nodal_balance_expressions =
        get_expression(container, ActivePowerBalance, PSY.ACBus).data

    # Serial libklu pass: concurrent libklu calls are unsafe (PNM `_LIBKLU_LOCK`).
    # Each (outage, arc) pair is solved at most once.
    modf_cols = Dict{Tuple{String, Tuple{Int64, Int64}}, Vector{Float64}}()
    for (uuid, entries) in fresh_resolved
        outage_spec = registered_contingencies[uuid]
        outage_id = string(uuid)
        for (_, _, arc, _) in entries
            key = (outage_id, arc)
            haskey(modf_cols, key) && continue
            modf_cols[key] = modf_matrix[arc, outage_spec]
        end
    end

    # Parallel JuMP `AffExpr` build (no libklu): tasks return results, the main
    # thread does the serial writes. The try/catch surfaces the inner exception.
    tasks = map(fresh_resolved) do (uuid, entries)
        outage_id = string(uuid)
        Threads.@spawn try
            _build_post_contingency_flow_expressions_for_outage(
                time_steps,
                outage_id,
                modf_cols,
                nodal_balance_expressions,
                entries,
            )
        catch e
            @error "Post-contingency flow-expression task failed" outage_id =
                outage_id exception = (e, catch_backtrace())
            rethrow()
        end
    end
    for (i, task) in enumerate(tasks)
        (uuid, _) = fresh_resolved[i]
        outage_id = string(uuid)
        for (name, expressions) in fetch(task)
            for t in time_steps
                expression_container[outage_id, name, t] = expressions[t]
            end
        end
    end
    return
end

"""
Pre-pass for the multi-component outage dedup: copy already-built entries into
`expression_container` and return the residual `resolved` shape that still needs
fresh computation. Returns `resolved` unchanged when no other-V container exists.
"""
function _copy_existing_post_contingency_expressions!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{V},
    expression_container::SparseAxisArray,
    resolved::Vector{
        Pair{Base.UUID, Vector{Tuple{DataType, String, Tuple{Int, Int}, String}}},
    },
    time_steps::UnitRange{Int},
) where {T <: PostContingencyExpressions, V <: PSY.ACTransmission}
    _has_other_v_container(IOM.get_expressions(container), T, V) || return resolved

    fresh =
        Pair{Base.UUID, Vector{Tuple{DataType, String, Tuple{Int, Int}, String}}}[]
    for (uuid, entries) in resolved
        outage_id = string(uuid)
        unresolved = Tuple{DataType, String, Tuple{Int, Int}, String}[]
        for entry in entries
            (_, name, _, _) = entry
            src_ec = _find_shared_post_contingency_expression_source(
                container, T, V, outage_id, name, first(time_steps),
            )
            if isnothing(src_ec)
                push!(unresolved, entry)
            else
                for t in time_steps
                    expression_container[outage_id, name, t] =
                        src_ec.data[(outage_id, name, t)]
                end
            end
        end
        isempty(unresolved) || push!(fresh, uuid => unresolved)
    end
    return fresh
end

# Lossy AC post-contingency flow expression. Preventive formulation:
# `PostContingencyBranchFlow[outage, name, t]` is the from-to flow variable
# itself, so the per-outage emergency-rate constraint bounds the same variable
# for every outage by the emergency rating.
function add_post_contingency_flow_expressions!(
    container::OptimizationContainer,
    ::Type{T},
    model::DeviceModel{V, F},
    network_model::NetworkModel{N},
) where {
    T <: PostContingencyBranchFlow,
    V <: PSY.ACTransmission,
    F <: AbstractSecurityConstrainedStaticBranch,
    N <: PM.AbstractACPModel,
}
    time_steps = get_time_steps(container)
    resolved = _resolve_monitored_arcs(model, network_model.network_reduction)

    expression_container =
        SparseAxisArray(Dict{Tuple{String, String, Int}, JuMP.AffExpr}())
    IOM._assign_container!(
        container.expressions, ExpressionKey(T, V), expression_container,
    )

    has_other_v = _has_other_v_container(IOM.get_expressions(container), T, V)
    flow_vars_by_type = Dict{DataType, Any}()
    for (uuid, entries) in resolved
        outage_id = string(uuid)
        for (entry_type, name, _, _) in entries
            if has_other_v
                src_ec = _find_shared_post_contingency_expression_source(
                    container, T, V, outage_id, name, first(time_steps),
                )
                if !isnothing(src_ec)
                    for t in time_steps
                        expression_container[outage_id, name, t] =
                            src_ec.data[(outage_id, name, t)]
                    end
                    continue
                end
            end
            flow_vars = get!(flow_vars_by_type, entry_type) do
                get_variable(container, FlowActivePowerFromToVariable, entry_type)
            end
            for t in time_steps
                expression_container[outage_id, name, t] =
                    1.0 * flow_vars[name, t]
            end
        end
    end
    return
end

# -----------------------------------------------------
# ------------ construct_device! METHODS --------------
# -----------------------------------------------------

# For DC Power only
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, F},
    network_model::NetworkModel{<:AbstractPTDFModel},
) where {T <: PSY.ACTransmission, F <: AbstractSecurityConstrainedStaticBranch}
    devices = get_available_components(device_model, sys)
    if get_use_slacks(device_model)
        add_variables!(
            container,
            FlowActivePowerSlackUpperBound,
            network_model,
            devices,
            F,
        )
        add_variables!(
            container,
            FlowActivePowerSlackLowerBound,
            network_model,
            devices,
            F,
        )
    end

    if haskey(get_time_series_names(device_model), BranchRatingTimeSeriesParameter)
        add_branch_parameters!(
            container,
            BranchRatingTimeSeriesParameter,
            devices,
            device_model,
            network_model,
        )
    end

    if haskey(
        get_time_series_names(device_model),
        PostContingencyBranchRatingTimeSeriesParameter,
    )
        _add_post_contingency_branch_rating_parameter!(
            container,
            device_model,
            devices,
            network_model,
        )
    end

    add_feedforward_arguments!(container, device_model, devices)

    add_expressions!(
        container,
        PTDFBranchFlow,
        devices,
        device_model,
        network_model,
    )

    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{V, F},
    network_model::NetworkModel{X},
) where {
    V <: PSY.ACTransmission,
    F <: AbstractSecurityConstrainedStaticBranch,
    X <: AbstractPTDFModel,
}
    devices = get_available_components(device_model, sys)

    add_constraints!(container, FlowRateConstraint, devices, device_model, network_model)
    add_feedforward_constraints!(container, device_model, devices)
    add_to_objective_function!(container, devices, device_model, X)

    add_post_contingency_flow_expressions!(
        container,
        PostContingencyBranchFlow,
        device_model,
        network_model,
    )

    add_constraints!(
        container,
        PostContingencyFlowRateConstraint,
        device_model,
        network_model,
    )

    # Must run after the post-contingency constraints are built so their
    # SparseAxisArray dual containers are registered alongside FlowRateConstraint.
    add_constraint_dual!(container, sys, device_model)

    return
end

# PTDF needs a PTDFBranchFlow expression here; the lossy AC path doesn't —
# its post-contingency expression is the FromTo flow variable directly.
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, F},
    network_model::NetworkModel{<:PM.AbstractACPModel},
) where {T <: PSY.ACTransmission, F <: AbstractSecurityConstrainedStaticBranch}
    devices = get_available_components(device_model, sys)

    # The ACP post-contingency expression builder reads
    # `FlowActivePowerFromToVariable` for the monitored branches. The native ACP
    # `StaticBranch` ArgumentConstructStage is what normally creates the four
    # directional flow variables and wires them to the nodal balance; the SC
    # formulation must do the same so the monitored branches carry their AC flow
    # variables (and contribute to the network balance) in addition to the
    # post-contingency machinery.
    add_variables!(container, FlowActivePowerFromToVariable, devices, F)
    add_variables!(container, FlowActivePowerToFromVariable, devices, F)
    add_variables!(container, FlowReactivePowerFromToVariable, devices, F)
    add_variables!(container, FlowReactivePowerToFromVariable, devices, F)

    if get_use_slacks(device_model)
        add_variables!(
            container,
            FlowActivePowerSlackUpperBound,
            devices,
            F,
        )
        add_variables!(
            container,
            FlowActivePowerSlackLowerBound,
            devices,
            F,
        )
    end

    add_to_expression!(
        container, ActivePowerBalance, FlowActivePowerFromToVariable,
        devices, device_model, network_model,
    )
    add_to_expression!(
        container, ActivePowerBalance, FlowActivePowerToFromVariable,
        devices, device_model, network_model,
    )
    add_to_expression!(
        container, ReactivePowerBalance, FlowReactivePowerFromToVariable,
        devices, device_model, network_model,
    )
    add_to_expression!(
        container, ReactivePowerBalance, FlowReactivePowerToFromVariable,
        devices, device_model, network_model,
    )

    if haskey(get_time_series_names(device_model), BranchRatingTimeSeriesParameter)
        add_branch_parameters!(
            container,
            BranchRatingTimeSeriesParameter,
            devices,
            device_model,
            network_model,
        )
    end

    if haskey(
        get_time_series_names(device_model),
        PostContingencyBranchRatingTimeSeriesParameter,
    )
        _add_post_contingency_branch_rating_parameter!(
            container,
            device_model,
            devices,
            network_model,
        )
    end

    add_feedforward_arguments!(container, device_model, devices)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{V, F},
    network_model::NetworkModel{X},
) where {
    V <: PSY.ACTransmission,
    F <: AbstractSecurityConstrainedStaticBranch,
    X <: PM.AbstractACPModel,
}
    devices = get_available_components(device_model, sys)

    add_constraints!(
        container, FlowRateConstraintFromTo, devices, device_model, network_model,
    )
    add_constraints!(
        container, FlowRateConstraintToFrom, devices, device_model, network_model,
    )
    add_feedforward_constraints!(container, device_model, devices)
    add_to_objective_function!(container, devices, device_model, X)

    add_post_contingency_flow_expressions!(
        container,
        PostContingencyBranchFlow,
        device_model,
        network_model,
    )

    add_constraints!(
        container,
        PostContingencyFlowRateConstraint,
        device_model,
        network_model,
    )

    add_constraint_dual!(container, sys, device_model)

    return
end

# `SecurityConstrainedStaticBranch` is intentionally inert under network models
# that carry no branch-flow representation: NFA, CopperPlate and AreaBalance
# build nothing rather than erroring (mirrors the StaticBranch no-ops). Defined
# on concrete network types to avoid ambiguity with the PTDF/ACP methods.
function construct_device!(
    ::OptimizationContainer,
    ::PSY.System,
    ::ArgumentConstructStage,
    ::DeviceModel{T, F},
    ::Union{
        NetworkModel{NFAPowerModel},
        NetworkModel{CopperPlatePowerModel},
        NetworkModel{AreaBalancePowerModel},
    },
) where {T <: PSY.ACTransmission, F <: AbstractSecurityConstrainedStaticBranch}
    @debug "No argument construction for $F under NFA/CopperPlate/AreaBalance; \
            security-constrained branch limits are inert for these network \
            models." _group = LOG_GROUP_BRANCH_CONSTRUCTIONS
    return
end

function construct_device!(
    ::OptimizationContainer,
    ::PSY.System,
    ::ModelConstructStage,
    ::DeviceModel{T, F},
    ::Union{
        NetworkModel{NFAPowerModel},
        NetworkModel{CopperPlatePowerModel},
        NetworkModel{AreaBalancePowerModel},
    },
) where {T <: PSY.ACTransmission, F <: AbstractSecurityConstrainedStaticBranch}
    @debug "No model construction for $F under NFA/CopperPlate/AreaBalance; \
            security-constrained branch limits are inert for these network \
            models." _group = LOG_GROUP_BRANCH_CONSTRUCTIONS
    return
end
