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

# The network's per-step topology: the low-rank matrix built once per model on the base
# factorization, and the schedule built from the statuses at each build together with the
# post-contingency network of each registered contingency at every step.
mutable struct TopologyState
    matrix::Union{Nothing, PNM.VirtualMODF}
    schedule::Union{Nothing, PNM.TopologySchedule}
    post_contingency::_PostContingencyModifications
end

TopologyState() = TopologyState(nothing, nothing, _PostContingencyModifications())
TopologyState(matrix::PNM.VirtualMODF) =
    TopologyState(matrix, nothing, _PostContingencyModifications())

"""DCP: a Ybus, plus a MODF derived from that same Ybus when the template is security constrained."""
struct DCPNetworkData{M} <: IOM.AbstractNetworkData
    ybus::PNM.Ybus
    contingency_matrix::M
    branch_catalog::PNM.BranchCatalog
    topology::TopologyState
end

"""PTDF families: a PTDF, plus an optional MODF, both wrapping one factorization core."""
struct PTDFNetworkData{P, M} <: IOM.AbstractNetworkData
    matrix::P
    contingency_matrix::M
    branch_catalog::PNM.BranchCatalog
    topology::TopologyState
end

# The no-contingency constructors omit the argument, storing this singleton in
# `contingency_matrix`. It is the type parameter, not the field's presence, that
# `has_contingency_matrix` dispatches on. A named sentinel rather than `nothing` because
# `nothing` already means "not instantiated yet" on IOM's `network_data` field.
struct NoContingencyMatrix end

DCPNetworkData(ybus::PNM.Ybus, catalog::PNM.BranchCatalog) =
    DCPNetworkData(ybus, NoContingencyMatrix(), catalog, TopologyState())
DCPNetworkData(ybus::PNM.Ybus, catalog::PNM.BranchCatalog, topology::TopologyState) =
    DCPNetworkData(ybus, NoContingencyMatrix(), catalog, topology)
DCPNetworkData(ybus::PNM.Ybus, contingency_matrix, catalog::PNM.BranchCatalog) =
    DCPNetworkData(ybus, contingency_matrix, catalog, TopologyState())

PTDFNetworkData(matrix, catalog::PNM.BranchCatalog) =
    PTDFNetworkData(matrix, NoContingencyMatrix(), catalog, TopologyState())
PTDFNetworkData(matrix, catalog::PNM.BranchCatalog, topology::TopologyState) =
    PTDFNetworkData(matrix, NoContingencyMatrix(), catalog, topology)
PTDFNetworkData(matrix, contingency_matrix, catalog::PNM.BranchCatalog) =
    PTDFNetworkData(matrix, contingency_matrix, catalog, TopologyState())

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

get_topology_state(nd::Union{PTDFNetworkData, DCPNetworkData}) = nd.topology
get_topology_state(::IOM.AbstractNetworkData) = nothing

get_topology_matrix(m::NetworkModel) =
    _topology_matrix(get_topology_state(get_network_data(m)))
_topology_matrix(::Nothing) = nothing
_topology_matrix(s::TopologyState) = s.matrix

get_topology_schedule(m::NetworkModel) =
    _topology_schedule(get_topology_state(get_network_data(m)))
_topology_schedule(::Nothing) = nothing
_topology_schedule(s::TopologyState) = s.schedule

"""
The post-contingency network of each registered contingency at every step of the topology
schedule, by outage id: `nothing` at a step where every component of the contingency is
already out.
"""
get_post_contingency_modifications(m::NetworkModel) =
    get_topology_state(get_network_data(m)).post_contingency

function set_topology_schedule!(
    m::NetworkModel,
    schedule::PNM.TopologySchedule,
    post_contingency::_PostContingencyModifications,
)
    _set_topology_schedule!(
        get_topology_state(get_network_data(m)),
        m,
        schedule,
        post_contingency,
    )
    return
end

function _set_topology_schedule!(
    state::TopologyState,
    ::NetworkModel,
    schedule::PNM.TopologySchedule,
    post_contingency::_PostContingencyModifications,
)
    state.schedule = schedule
    state.post_contingency = post_contingency
    return
end

_set_topology_schedule!(::Nothing, m::NetworkModel, ::PNM.TopologySchedule, _) = error(
    "$(nameof(get_network_formulation(m))) holds no network topology, so it cannot store \
     a topology schedule. Only DCP and PTDF network models follow scheduled topology.",
)

"""
    release_contingency_caches!(network_model::NetworkModel)

Free the post-contingency PTDF rows and Woodbury factors that `network_model`'s contingency
and topology matrices cached while the model's constraints were built. The contingency
registrations stay, so a later query recomputes the rows it asks for.

Under a topology schedule the cache holds one set of factors per step topology and
contingency, each as wide as the arcs the step and the contingency take out together, and it
stays resident through the solve unless released. Call this after `build!` on a model that is
built once. A model rebuilt at each step of a simulation reuses the caches of recurring
topologies, so leave them in place there.
"""
function release_contingency_caches!(network_model::NetworkModel)
    data = get_network_data(network_model)
    isnothing(data) && return
    has_contingency_matrix(data) &&
        _release_caches!(get_network_data_contingency_matrix(data))
    _release_caches!(get_topology_matrix(network_model))
    return
end

_release_caches!(matrix::PNM.VirtualMODF) = PNM.clear_caches!(matrix)
_release_caches!(::Any) = nothing
