"""
Resolve the labels of one axis to component ids and names. All or none: if any label does
not resolve, return no ids and the labels, and the axis is label-only.
"""
function IOM.resolve_component_axis(
    sys::PSY.System,
    ::Type{U},
    labels::Vector{String},
) where {U <: PSY.Component}
    ids = Dict{String, Int}(
        PSY.get_name(c) => IS.get_id(c) for c in PSY.get_components(U, sys)
    )
    if !all(label -> haskey(ids, label), labels)
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
    buses = Dict{String, PSY.Bus}()
    for bus in PSY.get_components(U, sys)
        buses[string(PSY.get_number(bus))] = bus
        buses[PSY.get_name(bus)] = bus
    end
    if !all(label -> haskey(buses, label), labels)
        return (Int[], labels)
    end
    return (
        Int[IS.get_id(buses[label]) for label in labels],
        String[PSY.get_name(buses[label]) for label in labels],
    )
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
