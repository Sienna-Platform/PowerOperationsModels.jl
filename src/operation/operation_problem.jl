"""
Abstract supertype for any power-system operations problem. Any concrete POM
problem subtypes this directly or via one of the execution-shape narrowings
below. Methods dispatched on `<:AbstractPowerOperationProblem` apply to any
power-flavored model regardless of decision-vs-emulation execution shape.
"""
abstract type AbstractPowerOperationProblem <: IOM.AbstractOptimizationProblem end

"""
Abstract supertype for power-ops problems run as a single-horizon optimization
(wrapped in `IOM.DecisionModel`).
"""
abstract type AbstractPowerDecisionProblem <: AbstractPowerOperationProblem end

"""
Abstract supertype for power-ops problems run as a rolling single-period
emulator (wrapped in `IOM.EmulationModel`).
"""
abstract type AbstractPowerEmulationProblem <: AbstractPowerOperationProblem end

"""
Abstract supertype for power-ops decision problems that use POM's default
build/solve formulations. Custom decision problems that supply their own
build/solve logic should subtype `AbstractPowerDecisionProblem` directly.
"""
abstract type DefaultPowerDecisionProblem <: AbstractPowerDecisionProblem end

"""
Abstract supertype for power-ops emulation problems that use POM's default
build/solve formulations. Custom emulation problems that supply their own
build/solve logic should subtype `AbstractPowerEmulationProblem` directly.
"""
abstract type DefaultPowerEmulationProblem <: AbstractPowerEmulationProblem end

"""
Default concrete tag for a generic POM decision problem. This is what
`DecisionModel(template, sys; ...)` produces when no specific problem type is
named.
"""
struct GenericPowerDecisionProblem <: DefaultPowerDecisionProblem end

"""
Default concrete tag for a generic POM emulation problem. This is what
`EmulationModel(template, sys; ...)` produces when no specific problem type is
named.
"""
struct GenericPowerEmulationProblem <: DefaultPowerEmulationProblem end
