#################################################################################
# Operation-problem type hierarchy
#
# IOM is a domain-neutral optimization library: it owns `DecisionModel{M}`/
# `EmulationModel{M}` and parameterizes them over `IOM.AbstractOptimizationProblem`.
# The decision↔emulation distinction is the wrapper's job (DecisionModel vs
# EmulationModel), so POM's power problem chain is a single linear hierarchy: the
# concrete problem type only describes domain content, not the solve strategy.
#################################################################################

"""
Umbrella supertype for every PowerOperationsModels optimization problem. A
`DecisionModel`/`EmulationModel` parameterized over a subtype of this is a POM
operation model.
"""
abstract type AbstractPowerOperationProblem <: IOM.AbstractOptimizationProblem end

"""
Operation problems whose build/validate behavior is fully driven by the
`ProblemTemplate` (the common case). The seam for a future custom-build problem is
to subtype `AbstractPowerOperationProblem` directly instead of this.
"""
abstract type GenericPowerOperationProblem <: AbstractPowerOperationProblem end

"""
Default concrete template-driven operation problem. The `M` used when a
`DecisionModel`/`EmulationModel` is built from a template without an explicit problem
type.
"""
struct DefaultPowerOperationProblem <: GenericPowerOperationProblem end
