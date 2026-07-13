# Headroom-proportional slack participation factors.
# Ported from PowerSimulations.jl branch lk/headroom-slack
# (src/network_models/power_flow_evaluation.jl lines 578-751). Defines
# _accumulate_headroom! (4 dispatch overloads incl. ambiguity fix) and
# _update_headroom_participation_factors!.

# ParameterKey → FixedOutput formulation; dispatch is externally determined,
# should not participate in slack.
_accumulate_headroom!(
    ::PFS.PowerFlowData,
    ::OptimizationContainer,
    ::PSY.System,
    ::OptimizationContainerKey{<:ISOPT.ParameterType, <:PSY.Component},
    ::Dict{String, Int},
    ::Int,
    ::Matrix{PSY.ACBusTypes},
    ::Vector{Dict{Tuple{DataType, String}, Float64}},
) = nothing

# Storage uses split In/Out active power variables; its headroom contribution comes
# from `_accumulate_in_out_headroom!` below. These skips guard against any (currently
# unused) `:active_power` mapping for Storage that would otherwise double-count.
_accumulate_headroom!(
    ::PFS.PowerFlowData,
    ::OptimizationContainer,
    ::PSY.System,
    ::OptimizationContainerKey{<:ISOPT.OptimizationKeyType, <:PSY.Storage},
    ::Dict{String, Int},
    ::Int,
    ::Matrix{PSY.ACBusTypes},
    ::Vector{Dict{Tuple{DataType, String}, Float64}},
) = nothing

# Required to fix dispatch ambiguity between the two no-op overloads above
# at the intersection (ParameterType keys + Storage components).
_accumulate_headroom!(
    ::PFS.PowerFlowData,
    ::OptimizationContainer,
    ::PSY.System,
    ::OptimizationContainerKey{<:ISOPT.ParameterType, <:PSY.Storage},
    ::Dict{String, Int64},
    ::Int,
    ::Matrix{PSY.ACBusTypes},
    ::Vector{Dict{Tuple{DataType, String}, Float64}},
) = nothing

"""
Accumulate headroom for a single OptimizationContainerKey into `pf_data` and
`computed_gspf`. The `where {U}` parameter makes the component type a compile-time
constant, so `PSY.get_component(U, ...)`, `has_container_key(..., U)`, and the
`(U, device_name)` Dict key all dispatch concretely. Note that `result` and
`ts_param_values` remain abstractly typed because `OptimizationContainer.variables`
and `.parameters` have abstract value types in their dict signatures — the inner
indexing into them still goes through dynamic dispatch.
"""
function _accumulate_headroom!(
    pf_data::PFS.PowerFlowData,
    container::OptimizationContainer,
    sys::PSY.System,
    key::OptimizationContainerKey{<:ISOPT.OptimizationKeyType, U},
    component_map::Dict{String, Int},
    n_time_steps::Int,
    bus_types::Matrix{PSY.ACBusTypes},
    computed_gspf::Vector{Dict{Tuple{DataType, String}, Float64}},
) where {U <: PSY.Component}
    result = lookup_value(container, key)

    # Time-varying active power limits (e.g. renewable availability profiles).
    # Precompute the axis as a Set so the per-(device, t) membership test is O(1).
    ts_param_values, ts_axis =
        if has_container_key(container, POM.ActivePowerTimeSeriesParameter, U)
            vals = lookup_value(
                container,
                ParameterKey(POM.ActivePowerTimeSeriesParameter, U),
            )
            (vals, Set{String}(axes(vals, 1)))
        else
            (nothing, nothing)
        end

    for (device_name, bus_ix) in component_map
        comp = PSY.get_component(U, sys, device_name)
        PFS.contributes_active_power(comp) || continue
        PFS.active_power_contribution_type(comp) ==
        PFS.PowerContributionType.INJECTION || continue

        # limits.max is already in SYSTEM_BASE because units are set at init
        p_max_static = PFS.get_active_power_limits_for_power_flow(comp).max
        has_ts = ts_axis !== nothing && device_name ∈ ts_axis

        for t in 1:n_time_steps
            bus_types[bus_ix, t] ∈ (PSY.ACBusTypes.REF, PSY.ACBusTypes.PV) || continue
            p_setpoint = jump_value(result[device_name, t])
            p_max_t = if has_ts
                min(p_max_static, jump_value(ts_param_values[device_name, t]))
            else
                p_max_static
            end
            headroom = p_max_t - p_setpoint
            headroom <= 0.0 && continue

            computed_gspf[t][(U, device_name)] = headroom
            pf_data.bus_active_power_range[bus_ix, t] += headroom
        end
    end
    return
end

# Maximum discharge active power (system-base PU) for devices that use split
# `ActivePowerInVariable` / `ActivePowerOutVariable`. PFS's
# `get_active_power_limits_for_power_flow(::Source)` returns `(min=-Inf, max=Inf)`,
# which is unusable for headroom math, so we read the device-level limits directly.
_pf_in_out_discharge_max(comp::PSY.Storage) =
    PSY.get_output_active_power_limits(comp, PSY.SU).max
_pf_in_out_discharge_max(comp::PSY.Source) =
    PSY.get_active_power_limits(comp, PSY.SU).max

"""
Accumulate headroom for devices that use split `ActivePowerInVariable` /
`ActivePowerOutVariable` (e.g. Storage `BookKeeping`, Source `ImportExportSourceModel`).

`net = p_out - p_in` is the device's signed contribution at time `t`. With net > 0 the
device is dispatching and its headroom is `p_max_out - net`; with net <= 0 the device is
charging (or idle) and contributes no upward slack.
"""
function _accumulate_in_out_headroom!(
    pf_data::PFS.PowerFlowData,
    container::OptimizationContainer,
    sys::PSY.System,
    in_inputs::Dict{OptimizationContainerKey, Dict{String, Int}},
    out_inputs::Dict{OptimizationContainerKey, Dict{String, Int}},
    n_time_steps::Int,
    bus_types::Matrix{PSY.ACBusTypes},
    computed_gspf::Vector{Dict{Tuple{DataType, String}, Float64}},
)
    for (in_key, in_cmap) in in_inputs
        out_key, out_cmap = _find_paired_out(out_inputs, get_component_type(in_key))
        _accumulate_in_out_headroom_one_type!(
            pf_data, container, sys,
            in_key, in_cmap, out_key, out_cmap,
            n_time_steps, bus_types, computed_gspf,
        )
    end
    return
end

function _find_paired_out(
    out_inputs::Dict{OptimizationContainerKey, Dict{String, Int}},
    comp_type::DataType,
)
    for (key, cmap) in out_inputs
        get_component_type(key) === comp_type && return (key, cmap)
    end
    error(
        "`:active_power_out` map missing for $comp_type — a formulation added " *
        "`ActivePowerInVariable` without a paired `ActivePowerOutVariable`.",
    )
end

# Function barrier: the parametric key types specialize `lookup_value` and `result[...]`
# indexing on the concrete component type `U`.
function _accumulate_in_out_headroom_one_type!(
    pf_data::PFS.PowerFlowData,
    container::OptimizationContainer,
    sys::PSY.System,
    in_key::OptimizationContainerKey{<:ISOPT.OptimizationKeyType, U},
    in_cmap::Dict{String, Int},
    out_key::OptimizationContainerKey{<:ISOPT.OptimizationKeyType, U},
    out_cmap::Dict{String, Int},
    n_time_steps::Int,
    bus_types::Matrix{PSY.ACBusTypes},
    computed_gspf::Vector{Dict{Tuple{DataType, String}, Float64}},
) where {U <: PSY.Component}
    result_in = lookup_value(container, in_key)
    result_out = lookup_value(container, out_key)
    for (device_name, bus_ix) in in_cmap
        comp = PSY.get_component(U, sys, device_name)
        PFS.contributes_active_power(comp) || continue
        PFS.active_power_contribution_type(comp) ==
        PFS.PowerContributionType.INJECTION || continue
        p_max_out = _pf_in_out_discharge_max(comp)
        for t in 1:n_time_steps
            bus_types[bus_ix, t] ∈ (PSY.ACBusTypes.REF, PSY.ACBusTypes.PV) || continue
            net =
                jump_value(result_out[device_name, t]) -
                jump_value(result_in[device_name, t])
            # Net <= 0 means charging or idle — per spec, no upward slack contribution.
            net < 0.0 && continue
            headroom = p_max_out - net
            headroom <= 0.0 && continue
            computed_gspf[t][(U, device_name)] = headroom
            pf_data.bus_active_power_range[bus_ix, t] += headroom
        end
    end
    return
end

"""
Recompute per-time-step headroom-proportional generator slack participation factors
using optimization results. Only runs if headroom proportional slack was enabled
during initialization.

For each generator at a REF or PV bus, headroom is `P_max(t) - P_setpoint(t)`, where
`P_setpoint(t)` comes from the optimization result and `P_max(t)` is the minimum of
the static device limit and any `ActivePowerTimeSeriesParameter` at time `t`. This
overwrites the PF-initialized values (which were computed once from static system
data) with time-varying factors.
"""
function _update_headroom_participation_factors!(
    pf_data::PFS.PowerFlowData,
    container::OptimizationContainer,
    sys::PSY.System,
    input_key_map::Dict{Symbol, Dict{OptimizationContainerKey, Dict{String, Int}}},
)
    PFS.get_distribute_slack_proportional_to_headroom(PFS.get_pf(pf_data)) || return
    computed_gspf =
        PFS.get_computed_gspf(pf_data)::Vector{Dict{Tuple{DataType, String}, Float64}}

    n_time_steps = length(get_time_steps(container))
    bus_types = PFS.get_bus_type(pf_data)::Matrix{PSY.ACBusTypes}
    bus_slack_pf =
        PFS.get_bus_slack_participation_factors(
            pf_data,
        )::SparseArrays.SparseMatrixCSC{Float64, Int}

    # Reset with fresh dicts per time step. PFS does not pre-allocate `computed_gspf`
    # when `distribute_slack_proportional_to_headroom=true` is set without an explicit
    # `generator_slack_participation_factors` value, so size the vector first.
    resize!(computed_gspf, n_time_steps)
    for t in 1:n_time_steps
        computed_gspf[t] = Dict{Tuple{DataType, String}, Float64}()
    end
    pf_data.bus_active_power_range .= 0.0

    # Function barrier so `_accumulate_headroom!` specializes per concrete key type
    # encountered at runtime — the outer Dict iterates abstract `OptimizationContainerKey`s.
    for (key, component_map) in input_key_map[:active_power]
        _accumulate_headroom!(
            pf_data,
            container,
            sys,
            key,
            component_map,
            n_time_steps,
            bus_types,
            computed_gspf,
        )
    end

    # Devices with split `ActivePowerInVariable` / `ActivePowerOutVariable`
    # (e.g. Storage `BookKeeping`, Source `ImportExportSourceModel`) accumulate
    # headroom from the net of out − in.
    _accumulate_in_out_headroom!(
        pf_data,
        container,
        sys,
        input_key_map[:active_power_in],
        input_key_map[:active_power_out],
        n_time_steps,
        bus_types,
        computed_gspf,
    )

    # Rebuild bus_slack_pf in one pass. Per-cell writes into the existing CSC matrix
    # would trigger O(nnz) structural inserts whenever runtime headroom appears at
    # (bus, t) pairs outside the t=1-derived sparsity pattern PFS init creates — which
    # is the common case for renewables with intermittent availability. PowerFlowData
    # is immutable, so we mutate the CSC's internal arrays in place to preserve identity.
    n_buses = size(pf_data.bus_active_power_range, 1)
    nnz_hint = count(>(0.0), pf_data.bus_active_power_range)
    I_idx = Int[]
    J_idx = Int[]
    V_val = Float64[]
    sizehint!(I_idx, nnz_hint)
    sizehint!(J_idx, nnz_hint)
    sizehint!(V_val, nnz_hint)
    for t in 1:n_time_steps, bus_ix in 1:n_buses
        R_k = pf_data.bus_active_power_range[bus_ix, t]
        R_k > 0.0 || continue
        push!(I_idx, bus_ix)
        push!(J_idx, t)
        push!(V_val, R_k)
    end
    new_sparse = SparseArrays.sparse(I_idx, J_idx, V_val, n_buses, n_time_steps)
    resize!(bus_slack_pf.nzval, length(new_sparse.nzval))
    copyto!(bus_slack_pf.nzval, new_sparse.nzval)
    resize!(bus_slack_pf.rowval, length(new_sparse.rowval))
    copyto!(bus_slack_pf.rowval, new_sparse.rowval)
    resize!(bus_slack_pf.colptr, length(new_sparse.colptr))
    copyto!(bus_slack_pf.colptr, new_sparse.colptr)
    return
end
