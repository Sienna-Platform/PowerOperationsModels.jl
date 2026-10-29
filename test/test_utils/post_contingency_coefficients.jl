# Coefficient dump and comparison for `PostContingencyBranchFlow` entries.
#
#   dump_post_contingency_coefficients(model, path; sample = 2000, seed = 1)
#   compare_post_contingency_coefficients(path_a, path_b; atol = 1e-9)
#
# A dump is JSON: the sparsification cutoff of the model's network matrix and a
# reproducible sample of records `(outage_id, outage, branch, branch_type, t, constant, terms)`.
# `terms` maps a variable name to its coefficient in the entry's flow expression.
# Records are matched across dumps by `(outage, branch_type, branch, t)`, where `outage`
# names the outage's components, so two builds of the same system match although their
# outage ids differ.

import InfrastructureOptimizationModels as IOM
import JSON
import JuMP
import PowerNetworkMatrices as PNM
import PowerOperationsModels as POM
import PowerSystems as PSY
import CRC32c

# The cutoff under which the network matrix drops a row entry: relative to the row's
# largest magnitude, or absolute.
function _dump_cutoff(model)
    return _matrix_cutoff(
        IOM.get_network_matrix(IOM.get_network_model(IOM.get_template(model))),
    )
end

_matrix_cutoff(m::PNM.VirtualPTDF) = _cutoff_record(PNM.get_core(m).tol)
_matrix_cutoff(m::PNM.PTDF) = _cutoff_record(m.tol)
_matrix_cutoff(m) = error("no sparsification cutoff is known for a $(typeof(m))")

_cutoff_record(c::PNM.RelativeCutoff) = Dict("kind" => "relative", "value" => c.fraction)
_cutoff_record(c::PNM.AbsoluteCutoff) = Dict("kind" => "absolute", "value" => c.value)
_cutoff_record(tol::Float64) = Dict("kind" => "absolute", "value" => tol)

# The `sample` keys with the smallest CRC32C of `seed|key`: the choice depends on each key
# alone, so adding or dropping one candidate changes at most one chosen key.
function _sample_keys(keys, sample::Int, seed::Int)
    ranked = sort!(collect(keys); by = k -> (CRC32c.crc32c("$seed|$k"), k))
    return sort!(ranked[1:min(sample, length(ranked))])
end

"""
The magnitude under which a term missing on one side of a comparison is a cutoff effect:
`α · max|terms|` for a relative cutoff, the fixed value for an absolute one.

The network matrix drops an entry below `α · max|row|` of its PTDF row. The dump holds the
flow expression's terms, which carry the row's entries at buses with an injection variable
only, so `max|terms| ≤ max|row|` and the threshold is conservative: a term between
`α · max|terms|` and `α · max|row|` that the cutoff drops on one side is reported as a
failure, not a crossing.
"""
function cutoff_threshold(cutoff, terms)
    value = Float64(cutoff["value"])
    cutoff["kind"] == "relative" || return value
    return value * maximum(abs, values(terms); init = 0.0)
end

# A type's label is module-qualified whatever module calls the dump, so dumps taken from a
# script and from a test sandbox match.
_type_label(T::Type) = "$(parentmodule(T)).$(nameof(T))"

# `outage_id` is the IS id of the outage, as the post-contingency containers key it.
function _outage_label(sys, outage_id)
    attribute = PSY.get_supplemental_attribute(sys, parse(Int, outage_id))
    components = PSY.get_associated_components(sys, attribute)
    return join(
        sort!(["$(_type_label(typeof(c)))/$(PSY.get_name(c))" for c in components]),
        "+",
    )
end

function _post_contingency_entries(model)
    container = IOM.get_optimization_container(model)
    sys = IOM.get_system(model)
    labels = Dict{String, String}()
    entries = NamedTuple[]
    for (key, array) in IOM.get_expressions(container)
        IOM.get_entry_type(key) === POM.PostContingencyBranchFlow || continue
        branch_type = _type_label(IOM.get_component_type(key))
        for ((outage_id, branch, t), expression) in array.data
            label = get!(() -> _outage_label(sys, outage_id), labels, outage_id)
            push!(
                entries,
                (; outage_id, outage = label, branch = string(branch), branch_type, t,
                    expression),
            )
        end
    end
    return sort!(entries; by = e -> (e.outage, e.branch_type, e.branch, e.t))
end

_variable_label(v::JuMP.VariableRef) =
    isempty(JuMP.name(v)) ? "x$(JuMP.index(v).value)" : JuMP.name(v)

_entry_key(e) = (e.outage, e.branch_type, e.branch, e.t)

function _entry_record(e)
    terms = Dict{String, Float64}()
    for (v, c) in e.expression.terms
        terms[_variable_label(v)] = c
    end
    return Dict(
        "outage_id" => e.outage_id,
        "outage" => e.outage,
        "branch" => e.branch,
        "branch_type" => e.branch_type,
        "t" => e.t,
        "constant" => JuMP.constant(e.expression),
        "terms" => terms,
    )
end

"""
    dump_post_contingency_coefficients(model, path; sample = 2000, seed = 1)

Write a reproducible sample of the model's `PostContingencyBranchFlow` entries as JSON.
The sample is the `sample` entries whose `(outage, branch_type, branch, t)` identity has the
smallest CRC32C with `seed`, so it depends on each identity alone.
"""
function dump_post_contingency_coefficients(model, path; sample::Int = 2000, seed::Int = 1)
    entries = _post_contingency_entries(model)
    by_key = Dict(_entry_key(e) => e for e in entries)
    chosen = _sample_keys(Base.keys(by_key), sample, seed)
    dump = Dict(
        "cutoff" => _dump_cutoff(model),
        "n_entries" => length(entries),
        "records" => [_entry_record(by_key[k]) for k in chosen],
    )
    open(path, "w") do io
        JSON.print(io, dump)
    end
    return path
end

_record_key(r) = (r["outage"], r["branch_type"], r["branch"], r["t"])

"""
    compare_post_contingency_coefficients(path_a, path_b; atol = 1e-9)
        -> (max_diff, cutoff_crossings, failures)

`max_diff` is the largest coefficient difference over terms present on both sides.
A term present on one side only is a cutoff crossing when its magnitude is below
`cutoff_threshold` of its row and a failure otherwise.
A record present in one dump only, or a common term differing by more than `atol`, is a failure.
`failures` holds named tuples describing each.
"""
function compare_post_contingency_coefficients(path_a, path_b; atol = 1e-9)
    a = JSON.parsefile(path_a)
    b = JSON.parsefile(path_b)
    records_a = Dict(_record_key(r) => r for r in a["records"])
    records_b = Dict(_record_key(r) => r for r in b["records"])
    max_diff = 0.0
    cutoff_crossings = 0
    failures = NamedTuple[]
    for key in sort!(collect(union(keys(records_a), keys(records_b))))
        ra = get(records_a, key, nothing)
        rb = get(records_b, key, nothing)
        if isnothing(ra) || isnothing(rb)
            push!(
                failures,
                (; key, term = nothing, a = ra, b = rb, reason = :missing_record),
            )
            continue
        end
        constant_diff = abs(ra["constant"] - rb["constant"])
        max_diff = max(max_diff, constant_diff)
        constant_diff > atol && push!(
            failures,
            (; key, term = "constant", a = ra["constant"], b = rb["constant"],
                reason = :difference),
        )
        terms_a, terms_b = ra["terms"], rb["terms"]
        for term in sort!(collect(union(keys(terms_a), keys(terms_b))))
            ca = get(terms_a, term, nothing)
            cb = get(terms_b, term, nothing)
            if !isnothing(ca) && !isnothing(cb)
                diff = abs(ca - cb)
                max_diff = max(max_diff, diff)
                diff > atol &&
                    push!(failures, (; key, term, a = ca, b = cb, reason = :difference))
            else
                present, cutoff, terms =
                    isnothing(cb) ?
                    (ca, a["cutoff"], terms_a) :
                    (cb, b["cutoff"], terms_b)
                if abs(present) < cutoff_threshold(cutoff, terms)
                    cutoff_crossings += 1
                else
                    push!(failures, (; key, term, a = ca, b = cb, reason = :one_sided))
                end
            end
        end
    end
    return (; max_diff, cutoff_crossings, failures)
end
