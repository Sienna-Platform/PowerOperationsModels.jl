function _warn_unresolved(::Type{U}, unresolved::Vector{String}) where {U}
    @warn "Output axis $U is label-only: labels do not resolve to components" unresolved
    return
end

# A name is unique across the concrete types under `U`; a duplicate would make the id ambiguous.
function _component_ids_by_name(sys::PSY.System, ::Type{U}) where {U <: PSY.Component}
    ids = Dict{String, Int}()
    for c in PSY.get_components(U, sys)
        name = PSY.get_name(c)
        if haskey(ids, name)
            error(
                "Duplicate component name \"$name\" under $U in the system (type $(typeof(c)))",
            )
        end
        ids[name] = IS.get_id(c)
    end
    return ids
end

"""
Resolve the labels of one axis to component ids and names. All or none: if any label does
not resolve, return no ids and the labels, so the axis is label-only, and warn.
"""
function IOM.resolve_component_axis(
    sys::PSY.System,
    ::Type{U},
    labels::Vector{String},
) where {U <: PSY.Component}
    ids = _component_ids_by_name(sys, U)
    unresolved = filter(label -> !haskey(ids, label), labels)
    if !isempty(unresolved)
        _warn_unresolved(U, unresolved)
        return (Int[], labels)
    end
    return (Int[ids[label] for label in labels], labels)
end

# Bus labels are bus numbers or bus names; the names label the axis.
function IOM.resolve_component_axis(
    sys::PSY.System,
    ::Type{U},
    labels::Vector{String},
) where {U <: PSY.Bus}
    by_number = Dict{String, PSY.Bus}()
    by_name = Dict{String, PSY.Bus}()
    for bus in PSY.get_components(U, sys)
        number = string(PSY.get_number(bus))
        name = PSY.get_name(bus)
        if haskey(by_number, number)
            error(
                "Duplicate bus number $number under $U in the system (type $(typeof(bus)))",
            )
        end
        if haskey(by_name, name)
            error(
                "Duplicate bus name \"$name\" under $U in the system (type $(typeof(bus)))",
            )
        end
        by_number[number] = bus
        by_name[name] = bus
    end
    for (key, bus) in by_number
        if haskey(by_name, key) && by_name[key] !== bus
            error(
                "Bus label \"$key\" is the number of bus \"$(PSY.get_name(bus))\" and the name of another bus",
            )
        end
    end
    unresolved =
        filter(label -> !haskey(by_number, label) && !haskey(by_name, label), labels)
    if !isempty(unresolved)
        _warn_unresolved(U, unresolved)
        return (Int[], labels)
    end
    resolved = PSY.Bus[]
    for label in labels
        if haskey(by_number, label)
            push!(resolved, by_number[label])
        else
            push!(resolved, by_name[label])
        end
    end
    return (Int[IS.get_id(b) for b in resolved], String[PSY.get_name(b) for b in resolved])
end

# Service and System level axes are not components of the axis type: label-only axis.
function IOM.resolve_component_axis(
    ::PSY.System,
    ::Type{<:Union{PSY.Service, PSY.System}},
    labels::Vector{String},
)
    return (Int[], labels)
end

function producer_info()
    return IS.ProducerInfo(
        "PowerOperationsModels",
        string(pkgversion(PowerOperationsModels)),
        string(VERSION),
    )
end
