"""
How a network model's topology varies over the time steps, fixed when the network model
is instantiated: `NoTopologySchedule` or `TopologySchedule`.
"""
abstract type AbstractTopologySchedule end

"""Every time step is the base network: the template schedules no AC branch."""
struct NoTopologySchedule <: AbstractTopologySchedule end

"""
Scheduled topology: the low-rank matrix built once per model on the base factorization,
and the step sequence each build derives from the branch statuses. The sequence is empty
from the start of a build until the build sets it.
"""
mutable struct TopologySchedule{M <: PNM.VirtualMODF} <: AbstractTopologySchedule
    const matrix::M
    sequence::Union{Nothing, PNM.TopologySequence{M}}
end

TopologySchedule(matrix::PNM.VirtualMODF) = TopologySchedule(matrix, nothing)

# What the per-step helpers dispatch on: the sequence under a schedule, the singleton
# without one.
const StepTopology = Union{NoTopologySchedule, PNM.TopologySequence}
