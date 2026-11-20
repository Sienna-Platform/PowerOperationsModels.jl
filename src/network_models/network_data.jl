#=
The network artifacts one build derives from its source. One container type per
formulation family, so "does this build have a contingency matrix" is answered by
dispatch instead of an isnothing check, and a family cannot accidentally read a
matrix it never derived.

The reduction is the matrix's own object, reached through this build's branch catalog, and
POM never mutates it. `get_reduction` resolves through `branch_catalog`, so the reduction a
consumer reads is by construction the one its index describes.

`branch_catalog` is this build's *filtered* catalog: the template's branch filters restrict
which branches get flow variables, which is an optimization concern rather than a property of
the reduction. The matrix carries the complete catalog, reachable with
`PNM.get_branch_catalog(matrix)` -- that is what a consumer wanting every branch (a power flow,
which solves the whole network regardless of what the optimization monitors) should read.
=#

"""Ybus-only families: no factorization, no sensitivity matrices."""
struct YbusNetworkData <: IOM.AbstractNetworkData
    ybus::PNM.Ybus
    branch_catalog::PNM.BranchCatalog
end

# The no-contingency constructors omit the argument, storing this singleton in
# `contingency_matrix`. It is the type parameter, not the field's presence, that
# `has_contingency_matrix` dispatches on. A named sentinel rather than `nothing` because
# `nothing` already means "not instantiated yet" on IOM's `network_data` field.
struct NoContingencyMatrix end

# Scheduled topologies are resolved on the contingency matrix when the model has one, so
# both share one factorization and its row caches.
_check_shared_factorization(::Any, ::NoTopologySchedule) = nothing
_check_shared_factorization(::NoContingencyMatrix, ::TopologySchedule) = nothing
function _check_shared_factorization(contingency_matrix, topology::TopologySchedule)
    contingency_matrix === get_topology_matrix(topology) && return
    throw(
        ArgumentError(
            "The topology matrix must be the contingency matrix, so that both share one \
             factorization.",
        ),
    )
end

"""DCP: a Ybus, plus a MODF derived from that same Ybus when the template is security constrained."""
struct DCPNetworkData{M, T <: AbstractTopologySchedule} <: IOM.AbstractNetworkData
    ybus::PNM.Ybus
    contingency_matrix::M
    branch_catalog::PNM.BranchCatalog
    topology::T
    function DCPNetworkData(
        ybus::PNM.Ybus,
        contingency_matrix::M,
        catalog::PNM.BranchCatalog,
        topology::T,
    ) where {M, T <: AbstractTopologySchedule}
        _check_shared_factorization(contingency_matrix, topology)
        return new{M, T}(ybus, contingency_matrix, catalog, topology)
    end
end

"""PTDF families: a PTDF, plus an optional MODF, both wrapping one factorization core."""
struct PTDFNetworkData{P, M, T <: AbstractTopologySchedule} <: IOM.AbstractNetworkData
    matrix::P
    contingency_matrix::M
    branch_catalog::PNM.BranchCatalog
    topology::T
    function PTDFNetworkData(
        matrix::P,
        contingency_matrix::M,
        catalog::PNM.BranchCatalog,
        topology::T,
    ) where {P, M, T <: AbstractTopologySchedule}
        _check_shared_factorization(contingency_matrix, topology)
        return new{P, M, T}(matrix, contingency_matrix, catalog, topology)
    end
end

DCPNetworkData(ybus::PNM.Ybus, catalog::PNM.BranchCatalog) =
    DCPNetworkData(ybus, NoContingencyMatrix(), catalog, NoTopologySchedule())
DCPNetworkData(
    ybus::PNM.Ybus,
    catalog::PNM.BranchCatalog,
    topology::AbstractTopologySchedule,
) = DCPNetworkData(ybus, NoContingencyMatrix(), catalog, topology)
DCPNetworkData(ybus::PNM.Ybus, contingency_matrix, catalog::PNM.BranchCatalog) =
    DCPNetworkData(ybus, contingency_matrix, catalog, NoTopologySchedule())

PTDFNetworkData(matrix, catalog::PNM.BranchCatalog) =
    PTDFNetworkData(matrix, NoContingencyMatrix(), catalog, NoTopologySchedule())
PTDFNetworkData(
    matrix,
    catalog::PNM.BranchCatalog,
    topology::AbstractTopologySchedule,
) = PTDFNetworkData(matrix, NoContingencyMatrix(), catalog, topology)
PTDFNetworkData(matrix, contingency_matrix, catalog::PNM.BranchCatalog) =
    PTDFNetworkData(matrix, contingency_matrix, catalog, NoTopologySchedule())

get_branch_catalog(nd::YbusNetworkData) = nd.branch_catalog
get_branch_catalog(nd::DCPNetworkData) = nd.branch_catalog
get_branch_catalog(nd::PTDFNetworkData) = nd.branch_catalog

# By construction the reduction a consumer reads is the one its own catalog indexes.
get_reduction(nd::IOM.AbstractNetworkData) =
    PNM.get_network_reduction_data(get_branch_catalog(nd))

# Ybus-only and DCP families have no sensitivity matrix, so the Ybus is the meaningful
# answer for get_network_matrix. Kept so the public IOM getter doesn't throw for these
# families; no caller reaches it today — the only get_network_matrix read sites
# (AC_branches.jl, transformer_models.jl) are NetworkModel{<:AbstractPTDFNetworkModel}.
get_matrix(nd::YbusNetworkData) = nd.ybus
get_matrix(nd::DCPNetworkData) = nd.ybus
get_matrix(nd::PTDFNetworkData) = nd.matrix

has_contingency_matrix(::IOM.AbstractNetworkData) = false
has_contingency_matrix(::DCPNetworkData{NoContingencyMatrix}) = false
has_contingency_matrix(::DCPNetworkData) = true
has_contingency_matrix(::PTDFNetworkData{P, NoContingencyMatrix}) where {P} = false
has_contingency_matrix(::PTDFNetworkData) = true

# Named distinctly from IOM's `get_contingency_matrix(m::NetworkModel)` (exported and
# brought into this module's scope via `using InfrastructureOptimizationModels`):
# reusing that name here would silently define a POM-local method table that shadows
# the NetworkModel method for every unqualified call in this package.
get_network_data_contingency_matrix(::DCPNetworkData{NoContingencyMatrix}) = error(
    "DCPNetworkData has no contingency matrix. Check `has_contingency_matrix` before \
    calling this getter.",
)
get_network_data_contingency_matrix(nd::DCPNetworkData) = nd.contingency_matrix
get_network_data_contingency_matrix(
    ::PTDFNetworkData{P, NoContingencyMatrix},
) where {P} = error(
    "PTDFNetworkData has no contingency matrix. Check `has_contingency_matrix` before \
    calling this getter.",
)
get_network_data_contingency_matrix(nd::PTDFNetworkData) = nd.contingency_matrix

# The consumer-facing getters keep their IOM names and forward into the derived
# container, so the PTDF and MODF read sites in the device models are unchanged.
IOM.get_network_matrix(m::NetworkModel) = get_matrix(get_network_data(m))
IOM.get_contingency_matrix(m::NetworkModel) =
    get_network_data_contingency_matrix(get_network_data(m))
IOM.get_network_reduction(m::NetworkModel) = get_reduction(get_network_data(m))
get_branch_catalog(m::NetworkModel) = get_branch_catalog(get_network_data(m))

get_topology(nd::Union{PTDFNetworkData, DCPNetworkData}) = nd.topology
get_topology(::IOM.AbstractNetworkData) = NoTopologySchedule()
get_topology(m::NetworkModel) = get_topology(get_network_data(m))

has_topology_schedule(::NoTopologySchedule) = false
has_topology_schedule(::TopologySchedule) = true
has_topology_schedule(x::Union{IOM.AbstractNetworkData, NetworkModel}) =
    has_topology_schedule(get_topology(x))

_no_topology_schedule(what::String) = error(
    "The network model has no topology schedule, so it has no $what. Check \
     `has_topology_schedule` before calling this getter.",
)

get_topology_matrix(t::TopologySchedule) = t.matrix
get_topology_matrix(::NoTopologySchedule) = _no_topology_schedule("topology matrix")
get_topology_matrix(x::Union{IOM.AbstractNetworkData, NetworkModel}) =
    get_topology_matrix(get_topology(x))

get_topology_sequence(t::TopologySchedule) = _assigned_sequence(t.sequence)
get_topology_sequence(::NoTopologySchedule) = _no_topology_schedule("topology sequence")
get_topology_sequence(x::Union{IOM.AbstractNetworkData, NetworkModel}) =
    get_topology_sequence(get_topology(x))

_assigned_sequence(ts::PNM.TopologySequence) = ts
_assigned_sequence(::Nothing) = error(
    "The topology sequence has not been set: the model's build sets it from the branch \
     statuses.",
)

"""
The topology the per-step helpers dispatch on: the topology sequence under a schedule, and
`NoTopologySchedule()` without one.
"""
get_step_topology(m::NetworkModel) = _step_topology(get_topology(m))
_step_topology(t::NoTopologySchedule) = t
_step_topology(t::TopologySchedule) = get_topology_sequence(t)

function set_topology_sequence!(t::TopologySchedule, sequence::PNM.TopologySequence)
    t.sequence = sequence
    return
end

set_topology_sequence!(::NoTopologySchedule, ::PNM.TopologySequence) = error(
    "The network model has no topology schedule, so it cannot store a topology sequence.",
)

set_topology_sequence!(nd::IOM.AbstractNetworkData, sequence::PNM.TopologySequence) =
    set_topology_sequence!(get_topology(nd), sequence)

function set_topology_sequence!(m::NetworkModel, sequence::PNM.TopologySequence)
    has_topology_schedule(m) || error(
        "$(nameof(get_network_formulation(m))) holds no network topology schedule, so it \
         cannot store a topology sequence.",
    )
    set_topology_sequence!(get_topology(m), sequence)
    return
end

function reset_topology_sequence!(t::TopologySchedule)
    t.sequence = nothing
    return
end

reset_topology_sequence!(::NoTopologySchedule) = nothing
reset_topology_sequence!(x::Union{IOM.AbstractNetworkData, NetworkModel}) =
    reset_topology_sequence!(get_topology(x))
