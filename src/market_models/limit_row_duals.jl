# Helpers shared by the post-solve readers of branch-limit duals (`BidAdjustmentArmed`,
# `LocationalMarginalPrice`).

_is_rate_meta(meta::String) = meta == "ub" || meta == "lb"

_is_row_less(constraint::DenseAxisArray) = isempty(constraint)
_is_row_less(constraint::SparseAxisArray) = isempty(constraint.data)

function _add_mirrored_dual_container!(
    container::OptimizationContainer,
    key::ConstraintKey{T, V},
    constraint::DenseAxisArray,
) where {T <: ConstraintType, V <: IS.InfrastructureSystemsType}
    add_dual_container!(container, T, V, axes(constraint)...; meta = key.meta)
    return
end

function _add_mirrored_dual_container!(
    container::OptimizationContainer,
    key::ConstraintKey{T, V},
    constraint::SparseAxisArray,
) where {T <: ConstraintType, V <: IS.InfrastructureSystemsType}
    # Empty axes fix the key type `Tuple{String, String, Int}`; the keys are then copied
    # from the constraint so the dual mirrors it exactly.
    dual = add_dual_container!(
        container, T, V, String[], String[], get_time_steps(container);
        sparse = true, meta = key.meta,
    )
    for k in keys(constraint.data)
        dual.data[k] = 0.0
    end
    return
end

# PTDF column of `bus`; a bus a reduction folded away uses the bus that absorbed it.
_bus_column(lookup, reduction, bus::PSY.ACBus) =
    lookup[PNM.get_mapped_bus_number(reduction, bus)]

# Shift factors over the PTDF bus columns of base-case branch `name` of `branch_type`.
_base_case_shift_factors(ptdf, catalog, branch_type::DataType, name::String) =
    ptdf[PNM.get_name_to_arc_map(catalog, branch_type)[name], :]

# Shift factors of monitored branch `name` under registered contingency `outage`.
_post_contingency_shift_factors(modf, contingencies, arcs, outage::Int, name::String) =
    modf[arcs[name], contingencies[outage]]

function _check_same_bus_order(modf, ptdf, reader::String)
    PNM.get_bus_lookup(modf) == PNM.get_bus_lookup(ptdf) && return
    error(
        "The contingency matrix and the PTDF order buses differently; $(reader) indexes " *
        "both with one column map.",
    )
end

# Post-contingency rows key monitored branches by name only, while branch names are unique
# only per type; a needed name must resolve to one arc across the modeled types.
function _monitored_arcs_by_name(
    catalog,
    modeled_branch_types::Vector{DataType},
    names,
)
    name_to_arc_maps = [PNM.get_name_to_arc_map(catalog, T) for T in modeled_branch_types]
    arcs = Dict{String, Tuple{Int, Int}}()
    for name in names
        for name_to_arc in name_to_arc_maps
            haskey(name_to_arc, name) || continue
            arc = name_to_arc[name]
            existing = get(arcs, name, arc)
            if existing != arc
                error(
                    "Branch name \"$(name)\" maps to arcs $(existing) and $(arc); a " *
                    "post-contingency row cannot tell which one it monitors.",
                )
            end
            arcs[name] = arc
        end
        if !haskey(arcs, name)
            error(
                "A post-contingency row monitors branch \"$(name)\", which maps to no " *
                "arc of the modeled branch types $(modeled_branch_types).",
            )
        end
    end
    return arcs
end
