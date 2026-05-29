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
`ProblemTemplate` (the common case). `DecisionModel{<:DefaultPowerDecisionProblem}`
gets the generic template-driven `build_model!`/`validate_template` methods.
"""
abstract type DefaultPowerDecisionProblem <: AbstractPowerDecisionProblem end

"""
Emulation problems whose build/validate behavior is fully driven by the
`ProblemTemplate`.
"""
abstract type DefaultPowerEmulationProblem <: AbstractPowerEmulationProblem end

"""
Generic template-driven decision problem. Default `M` when a `DecisionModel` is
built from a template without an explicit problem type.
"""
struct GenericPowerDecisionProblem <: DefaultPowerDecisionProblem end

"""
Generic template-driven emulation problem. Default `M` when an `EmulationModel`
is built from a template without an explicit problem type.
"""
struct GenericPowerEmulationProblem <: DefaultPowerEmulationProblem end
