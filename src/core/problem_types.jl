#################################################################################
# Operation-problem type hierarchy
#
# IOM (#104 "Redistribute operation models") is a domain-neutral optimization
# library: it owns `DecisionModel{M}`/`EmulationModel{M}` and parameterizes them
# over the single abstract tag `IOM.AbstractOptimizationProblem`. The concrete,
# power-flavoured problem-type chain lives here in POM. POM-side methods dispatch
# on `DecisionModel{<:AbstractPowerOperationProblem}` (and its sub-tags) while IOM keeps only
# error-stub / extension-point methods on the neutral abstract.
#################################################################################

"""
Umbrella supertype for every PowerOperationsModels optimization problem. A
`DecisionModel`/`EmulationModel` parameterized over a subtype of this is a POM
operation model; dispatch on `DecisionModel{<:AbstractPowerOperationProblem}` selects the
POM-side implementations of IOM's extension points.
"""
abstract type AbstractPowerOperationProblem <: IOM.AbstractOptimizationProblem end

"""
Supertype for single-period (decision) operation problems solved by `DecisionModel`.
"""
abstract type AbstractPowerDecisionProblem <: AbstractPowerOperationProblem end

"""
Supertype for rolling-horizon (emulation) operation problems solved by `EmulationModel`.
"""
abstract type AbstractPowerEmulationProblem <: AbstractPowerOperationProblem end

"""
Decision problems whose build/validate behavior is fully driven by the
`ProblemTemplate` (the common case). `DecisionModel{<:GenericPowerDecisionProblem}`
gets the generic template-driven `build_model!`/`validate_template` methods.
"""
abstract type GenericPowerDecisionProblem <: AbstractPowerDecisionProblem end

"""
Emulation problems whose build/validate behavior is fully driven by the
`ProblemTemplate`.
"""
abstract type GenericPowerEmulationProblem <: AbstractPowerEmulationProblem end

"""
Default concrete template-driven decision problem. The `M` used when a `DecisionModel`
is built from a template without an explicit problem type.
"""
struct DefaultPowerDecisionProblem <: GenericPowerDecisionProblem end

"""
Default concrete template-driven emulation problem. The `M` used when an `EmulationModel`
is built from a template without an explicit problem type.
"""
struct DefaultPowerEmulationProblem <: GenericPowerEmulationProblem end
