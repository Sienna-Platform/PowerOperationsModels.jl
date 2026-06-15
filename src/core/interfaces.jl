#################################################################################
# Fallback / stub definitions for functions that are defined and called
# entirely within POM (no call sites in IOM).
#################################################################################

_to_string(::Type{IOM.ArgumentConstructStage}) = "ArgumentConstructStage"
_to_string(::Type{IOM.ModelConstructStage}) = "ModelConstructStage"

"""
Fallback: `construct_device!` for `ArgumentConstructStage` and `ModelConstructStage`.
"""
function construct_device!(
    ::IOM.OptimizationContainer,
    ::IS.ComponentContainer,
    ::M,
    model::IOM.DeviceModel{D, F},
    network_model::IOM.NetworkModel{S},
) where {
    M <: IOM.ConstructStage,
    D <: IS.InfrastructureSystemsComponent,
    F <: IOM.AbstractDeviceFormulation,
    S,
}
    error(
        "construct_device! not implemented for device type $D with formulation $F " *
        "at $(_to_string(M)). Implement this method to add variables and expressions.",
    )
end

function construct_service!(
    ::IOM.OptimizationContainer,
    ::IS.ComponentContainer,
    ::IOM.ConstructStage,
    model::IOM.ServiceModel{S, F},
    devices_template::Dict{Symbol, IOM.DeviceModel},
    incompatible_device_types::Set{<:DataType},
    network_model::IOM.NetworkModel{N},
) where {S <: PSY.Service, F <: IOM.AbstractServiceFormulation, N}
    error(
        "construct_service! not implemented for service type $S with formulation $F.",
    )
end

"""
Add objective function contributions for devices.
"""
function add_to_objective_function!(
    ::IOM.OptimizationContainer,
    ::Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    ::IOM.DeviceModel{U, F},
    ::Type{S},
) where {
    U <: IS.InfrastructureSystemsComponent,
    F <: IOM.AbstractDeviceFormulation,
    S <: PM.AbstractPowerModel,
}
    error(
        "add_to_objective_function! not implemented for device type $U with formulation $F and power model $S.",
    )
    return
end

"""
Add constraints to the optimization container.
"""
function add_constraints!(
    ::IOM.OptimizationContainer,
    ::Type{T},
    devices::Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    model::IOM.DeviceModel{U, F},
    network_model::IOM.NetworkModel{S},
) where {
    T <: IS.Optimization.ConstraintType,
    U <: IS.InfrastructureSystemsComponent,
    F <: IOM.AbstractDeviceFormulation,
    S,
}
    error(
        "add_constraints! not implemented for constraint type $T, " *
        "device type $U with formulation $F.",
    )
end

"""
Get the multiplier for a variable type when adding to an expression.
Default implementation returns 1.0.
"""
get_variable_multiplier(
    ::Type{<:IS.Optimization.VariableType},
    ::Type{<:IS.InfrastructureSystemsComponent},
    ::Type{<:IOM.AbstractDeviceFormulation},
) = 1.0

"""
Get the multiplier for an expression type based on parameter type.
"""
function get_expression_multiplier(
    ::Type{P},
    ::Type{T},
    ::D,
    ::Type{F},
) where {
    P <: IS.Optimization.ParameterType,
    T <: IS.Optimization.ExpressionType,
    D <: IS.InfrastructureSystemsComponent,
    F <: IOM.AbstractDeviceFormulation,
}
    error(
        "get_expression_multiplier not implemented for parameter $P, expression $T, " *
        "device $D, formulation $F.",
    )
end

"""
Get multiplier value for a time series parameter.
"""
function get_multiplier_value(
    ::Type{T},
    ::U,
    ::Type{F},
) where {
    T <: IOM.TimeSeriesParameter,
    U <: IS.InfrastructureSystemsComponent,
    F <: IOM.AbstractDeviceFormulation,
}
    return 1.0
end

"""
Get the multiplier value for a parameter type.
"""
function get_multiplier_value(
    ::Type{P},
    ::D,
    ::Type{F},
) where {
    P <: IS.Optimization.ParameterType,
    D <: IS.InfrastructureSystemsComponent,
    F <: IOM.AbstractDeviceFormulation,
}
    error(
        "get_multiplier_value not implemented for parameter $P, device $D, formulation $F.",
    )
end

"""
Default fallback for `add_power_flow_data!`: a no-op when no evaluators are present.
The PowerFlows extension provides the concrete method that handles real evaluators.
If evaluators are registered without the PowerFlows extension loaded, this errors
with guidance to load it.
"""
function add_power_flow_data!(
    ::IOM.OptimizationContainer,
    network_model::IOM.NetworkModel,
    ::IS.ComponentContainer,
)
    isempty(IOM.get_evaluations(network_model)) || error(
        "PowerFlows extension not loaded; add `using PowerFlows` to enable " *
        "power flow in-the-loop.",
    )
    return
end

"""
Config-side adapter that wraps a power-flow model (e.g. a PowerFlows
`PowerFlowEvaluationModel` such as `ACPowerFlow()`) as an `IOM.AbstractEvaluator`
so it can be stored on a `NetworkModel`'s `EvaluationContainer`. IOM owns the
abstract evaluator interface but carries no PowerFlows dependency, so the concrete
adapter lives here (and is unwrapped by the PowerFlows extension's
`add_power_flow_data!`). Kept type-generic so POM core needs no PowerFlows types.
"""
struct PowerFlowEvaluator{T} <: IOM.AbstractEvaluator
    model::T
end

"Return the wrapped power-flow model from a `PowerFlowEvaluator`."
get_power_flow_model(ev::PowerFlowEvaluator) = ev.model

"""
Build an `EvaluationContainer` holding a single evaluator. Convenience for the
common single-evaluator case at call sites such as
`NetworkModel(...; evaluations = power_flow_evaluations(ACPowerFlow()))`.

The power-flow model is keyed by its own type and wrapped in a
[`PowerFlowEvaluator`](@ref) to satisfy IOM's `AbstractEvaluator` interface.
"""
function power_flow_evaluations(ev::T) where {T}
    ec = IOM.EvaluationContainer()
    IOM.add_evaluator!(ec, T, PowerFlowEvaluator(ev))
    return ec
end

"""
Get the device model to use for initialization.
"""
get_initial_conditions_device_model(
    ::IOM.AbstractOptimizationModel,
    model::IOM.DeviceModel{T, IOM.FixedOutput},
) where {T <: PSY.Device} = model

get_initial_conditions_device_model(
    ::IOM.AbstractOptimizationModel,
    ::IOM.DeviceModel{T, D},
) where {T <: PSY.Device, D <: IOM.AbstractDeviceFormulation} =
    error("`get_initial_conditions_device_model` must be implemented for $T and $D")
