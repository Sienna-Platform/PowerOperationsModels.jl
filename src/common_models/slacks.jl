# Generic slack primitives dispatched on the model's `SlackUsage` trait (the former
# `use_slacks::Bool`, now a model type parameter). Dispatch happens on the trait
# singleton — obtained once per site via `get_slack_usage(model)` — so slack handling
# is selected at compile time rather than by a runtime `if get_use_slacks(...)`.

"""
The slack term to fold into a constraint (`var - slack <= max`, etc.), or `0.0` when
the model carries no slacks. The `NoSlacks` method never touches the container, so the
slack variable need not exist.
"""
slack_contribution(::NoSlacks, args...) = 0.0
slack_contribution(
    ::UseSlacks,
    container::OptimizationContainer,
    ::Type{V},
    ::Type{T},
    name,
    t,
) where {V <: VariableType, T} = get_variable(container, V, T)[name, t]

"""
The sum of a slack variable's full time row for `name`, or `0.0` when the model carries no
slacks. Use where a constraint folds in the whole-horizon slack (e.g. an energy budget).
"""
slack_row_sum(::NoSlacks, args...) = 0.0
slack_row_sum(
    ::UseSlacks,
    container::OptimizationContainer,
    ::Type{V},
    ::Type{T},
    name,
) where {V <: VariableType, T} = sum(get_variable(container, V, T)[name, :])

"""
Add a slack variable, or do nothing when the model carries no slacks. Trailing
arguments forward to `add_variables!`, so this serves every (system/device) call shape.
"""
add_slack_variables!(::NoSlacks, args...) = nothing
add_slack_variables!(
    ::UseSlacks,
    container::OptimizationContainer,
    ::Type{V},
    args...,
) where {V <: VariableType} = add_variables!(container, V, args...)

"""
The slack variable container, or `nothing` when the model carries no slacks. Use when a
slack array (or `nothing`) must be handed to a helper such as
`add_slacked_range_constraints!`. The return type is concrete in each specialization, so a
downstream `isnothing` check constant-folds.
"""
maybe_slack_variable(::NoSlacks, args...) = nothing
maybe_slack_variable(
    ::UseSlacks,
    container::OptimizationContainer,
    ::Type{V},
    ::Type{T},
) where {V <: VariableType, T} = get_variable(container, V, T)

"""
Add a proportional objective cost for a slack variable, or nothing when the model carries no
slacks.
"""
add_slack_proportional_cost!(::NoSlacks, args...) = nothing
add_slack_proportional_cost!(
    ::UseSlacks,
    container::OptimizationContainer,
    ::Type{V},
    devices,
    ::Type{F},
) where {V <: VariableType, F} = add_proportional_cost!(container, V, devices, F)

"""
Reject a slack request that the formulation/network pair cannot support. The
`NoSlacks` method compiles away; the `UseSlacks` method throws at build time.
"""
_assert_no_slacks(::NoSlacks, msg::AbstractString) = nothing
_assert_no_slacks(::UseSlacks, msg::AbstractString) = throw(ArgumentError(msg))
