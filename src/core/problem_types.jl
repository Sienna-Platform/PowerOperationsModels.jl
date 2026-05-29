#################################################################################
# Operation-problem type hierarchy
#
# IOM (#104 "Redistribute operation models") is a domain-neutral optimization
# library: it owns `DecisionModel{M}`/`EmulationModel{M}` and parameterizes them
# over the single abstract tag `IOM.AbstractOptimizationProblem`. The concrete,
# power-flavoured problem-type chain lives here in POM. POM-side methods dispatch
# on `DecisionModel{<:PowerOperationModel}` (and its sub-tags) while IOM keeps only
# error-stub / extension-point methods on the neutral abstract.
#################################################################################

"""
Umbrella supertype for every PowerOperationsModels optimization problem. A
`DecisionModel`/`EmulationModel` parameterized over a subtype of this is a POM
operation model; dispatch on `DecisionModel{<:PowerOperationModel}` selects the
POM-side implementations of IOM's extension points.
"""
abstract type PowerOperationModel <: IOM.AbstractOptimizationProblem end

"""
Supertype for single-period (decision) operation problems solved by `DecisionModel`.
"""
abstract type DecisionProblem <: PowerOperationModel end

"""
Supertype for rolling-horizon (emulation) operation problems solved by `EmulationModel`.
"""
abstract type EmulationProblem <: PowerOperationModel end

"""
Decision problems whose build/validate behavior is fully driven by the
`ProblemTemplate` (the common case). `DecisionModel{<:DefaultDecisionProblem}`
gets the generic template-driven `build_model!`/`validate_template` methods.
"""
abstract type DefaultDecisionProblem <: DecisionProblem end

"""
Emulation problems whose build/validate behavior is fully driven by the
`ProblemTemplate`.
"""
abstract type DefaultEmulationProblem <: EmulationProblem end

"""
Generic template-driven decision problem. Default `M` when a `DecisionModel` is
built from a template without an explicit problem type.
"""
struct GenericOpProblem <: DefaultDecisionProblem end

"""
Generic template-driven emulation problem. Default `M` when an `EmulationModel`
is built from a template without an explicit problem type.
"""
struct GenericEmulationProblem <: DefaultEmulationProblem end
