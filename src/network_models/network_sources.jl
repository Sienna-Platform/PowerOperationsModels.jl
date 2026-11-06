#=
The declaration of which network a NetworkModel is built on. `_build_ybus` is the
single place a Ybus is constructed during network model instantiation: one Ybus per
build means one reduction, so every matrix derived from it agrees by construction.
=#

"""
Build the network from the system, applying `reductions`, honoring the build's
reduction exceptions, and sparsifying the derived sensitivity matrices at `tolerance`.
The two are independent knobs on the same construction step.

`tolerance` is the per-row sparsification cutoff handed to `PNM.VirtualFactorCore`: a
`Float64` is an absolute cutoff, a `PNM.AutoTolerance` a relative, size-adaptive one.
It reaches every matrix wrapping that core — PTDF and MODF alike. The default is PNM's
own auto rule, so POM does not second-guess it with a fixed cutoff of its own.

A zero-impedance branch reduction is always applied first. Include a
`ZeroImpedanceBranchReduction` to override its parameters; it replaces that step rather than
adding one, so its position in the vector is irrelevant. More than one errors.
"""
struct SystemNetworkSource <: IOM.AbstractNetworkSource
    reductions::Vector{PNM.NetworkReduction}
    tolerance::Union{Float64, PNM.AutoTolerance}
end

SystemNetworkSource(; tolerance = PNM.AutoTolerance()) =
    SystemNetworkSource(PNM.NetworkReduction[], tolerance)

SystemNetworkSource(
    reductions::Vector{PNM.NetworkReduction};
    tolerance = PNM.AutoTolerance(),
) = SystemNetworkSource(reductions, tolerance)

SystemNetworkSource(
    reduction::PNM.NetworkReduction,
    rest::PNM.NetworkReduction...;
    tolerance = PNM.AutoTolerance(),
) = SystemNetworkSource(
    collect(PNM.NetworkReduction, (reduction, rest...)),
    tolerance,
)

"""
Reuse a `VirtualPTDF` the caller already built, including its populated row cache.
Its own reduction becomes the build's reduction; the reduction exceptions derived
from the template are not applied, because the matrix already exists.

Only a `VirtualPTDF` is accepted: it carries the factorization core, so a MODF
sharing its reduction can be derived from it. A dense `PNM.PTDF` carries no core and
is deliberately not a valid source.
"""
struct PrebuiltMatrixSource{M <: PNM.VirtualPTDF} <: IOM.AbstractNetworkSource
    matrix::M
end

"""
Reuse a factorization core the caller already built — the cheapest reuse, since the
PTDF and MODF wrappers are derived from it without re-factorizing the ABA matrix.
"""
struct PrebuiltCoreSource{C <: PNM.VirtualFactorCore} <: IOM.AbstractNetworkSource
    core::C
end

get_matrix(source::PrebuiltMatrixSource) = source.matrix
get_core(source::PrebuiltCoreSource) = source.core

_source_reductions(source::SystemNetworkSource) = source.reductions
_source_reductions(::IOM.DefaultNetworkSource) = PNM.NetworkReduction[]
_source_reductions(source::PrebuiltMatrixSource) =
    PNM.get_applied_reductions(PNM.get_network_reduction_data(get_matrix(source)))
_source_reductions(source::PrebuiltCoreSource) =
    PNM.get_applied_reductions(PNM.get_network_reduction_data(get_core(source)))

"The buses an already-applied reduction kept: its user irreducible and schedule-pinned sets."
_source_irreducible_buses(reduction::PNM.NetworkReductionData) =
    collect(Int, PNM.get_reduction_exempt_buses(PNM.get_reductions(reduction)))

# The sparsification cutoff for a core this build factorizes itself. A prebuilt source
# carries a core whose cutoff the caller already fixed, so it falls back to PNM's auto
# rule: the value is consulted only on the paths that factorize a core of their own.
_source_tolerance(source::SystemNetworkSource) = source.tolerance
_source_tolerance(::IOM.AbstractNetworkSource) = PNM.AutoTolerance()

_is_radial_reduction(::PNM.NetworkReduction) = false
_is_radial_reduction(::PNM.RadialReduction) = true

# PNM takes the irreducible buses only as a selector, and a filter selector needs a
# `Function`. This callable struct carries the collected bus numbers back to PNM.
struct _BusNumberFilter <: Function
    numbers::Set{Int}
end

(f::_BusNumberFilter)(bus::PSY.ACBus) = PSY.get_number(bus) in f.numbers

# The selector drops an unknown bus number without a message, so check the numbers first.
function _irreducible_bus_selector(sys::PSY.System, exceptions::Vector{Int})
    numbers = Set{Int}(exceptions)
    unmatched = setdiff(numbers, PSY.get_bus_numbers(sys))
    isempty(unmatched) || throw(
        IS.ConflictingInputsError(
            "Irreducible bus numbers $(sort!(collect(unmatched))) match no ACBus in the \
            system.",
        ),
    )
    return PSY.make_selector(
        _BusNumberFilter(numbers),
        PSY.ACBus;
        name = "irreducible_buses",
    )
end

#=
The scheduled topology a formulation's base network carries: the scheduled switches closed and
the buses of scheduled branches kept out of reductions. Only formulations that resolve a
`PNM.TopologySchedule` carry it; every other formulation ignores branch schedules, so its base
network holds each switch in its data state.
=#
const _NO_SCHEDULED_TOPOLOGY = (
    closed_switches = PSY.DiscreteControlledACBranch[],
    pinned_buses = Set{Int}(),
)

_scheduled_topology(::Type{<:AbstractNetworkModel}, ::PSY.System) = _NO_SCHEDULED_TOPOLOGY
_scheduled_topology(
    ::Type{<:Union{DCPNetworkModel, AbstractPTDFNetworkModel}},
    sys::PSY.System,
) = PNM.topology_schedule_components(sys)

function _build_ybus(
    source::SystemNetworkSource,
    sys::PSY.System,
    exceptions::Vector{Int},
    schedules,
)
    return PNM.Ybus(
        sys;
        network_reductions = source.reductions,
        irreducible_buses = _irreducible_bus_selector(sys, exceptions),
        closed_switches = schedules.closed_switches,
        schedule_pinned_buses = schedules.pinned_buses,
    )
end

function _build_ybus(
    ::IOM.DefaultNetworkSource,
    sys::PSY.System,
    exceptions::Vector{Int},
    schedules,
)
    return PNM.Ybus(
        sys;
        irreducible_buses = _irreducible_bus_selector(sys, exceptions),
        closed_switches = schedules.closed_switches,
        schedule_pinned_buses = schedules.pinned_buses,
    )
end
