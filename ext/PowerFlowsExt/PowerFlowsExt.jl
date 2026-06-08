module PowerFlowsExt

import PowerOperationsModels as POM
import InfrastructureOptimizationModels as IOM
import InfrastructureSystems as IS
import InfrastructureSystems.Optimization as ISOPT
import PowerSystems as PSY
import PowerNetworkMatrices as PNM
import PowerFlows as PFS
import JuMP
import SparseArrays
import TimerOutputs

using InfrastructureOptimizationModels:
    OptimizationContainer,
    OptimizationContainerKey,
    VariableKey,
    ParameterKey,
    AuxVarKey,
    AuxVariableType,
    EvaluationContainer,
    add_aux_variable_container!,
    add_evaluator!,
    add_evaluation_data!,
    get_evaluations,
    get_evaluators,
    get_evaluation_data,
    get_inner_data,
    lookup_value,
    has_container_key,
    get_time_steps,
    get_entry_type,
    get_component_type,
    get_component_name,
    get_component_names,
    get_attributes,
    get_aux_variable,
    get_aux_variables,
    get_parameter,
    get_parameters,
    get_variables,
    jump_value

"""
Mutable struct to hold power flow evaluation data.
Concrete implementation of `IOM.AbstractEvaluationData`.
"""
mutable struct PowerFlowEvaluationData{T <: PFS.PowerFlowContainer} <:
               IOM.AbstractEvaluationData
    power_flow_data::T
    """
    Records which keys are read as input to the power flow and how the data are mapped.
    The `Symbol` is a category of data: `:active_power`, `:reactive_power`, etc. The
    `OptimizationContainerKey` is a source of that data in the `OptimizationContainer`. For
    `PowerFlowData`, leaf values are `Dict{String, Int64}` mapping component name to matrix
    index of bus; for `SystemPowerFlowContainer`, leaf values are
    `Dict{Union{String, Int64}, Union{String, Int64}}` mapping component name/bus number to
    component name/bus number.
    """
    input_key_map::Dict{Symbol, <:Dict{<:OptimizationContainerKey, <:Any}}
    is_solved::Bool
end

check_network_reduction(::PFS.SystemPowerFlowContainer) = nothing

function check_network_reduction(pfd::PFS.PowerFlowData)
    nrd = PFS.get_network_reduction_data(pfd)
    if !isempty(PNM.get_reductions(nrd))
        throw(
            IS.NotImplementedError(
                "Power flow in-the-loop on reduced networks isn't supported. Network " *
                "reductions of types $(PNM.get_reductions(nrd)) present.",
            ),
        )
    end
    return
end

function PowerFlowEvaluationData(
    power_flow_data::T,
) where {T <: PFS.PowerFlowContainer}
    check_network_reduction(power_flow_data)
    return PowerFlowEvaluationData{T}(
        power_flow_data,
        Dict{Symbol, Dict{OptimizationContainerKey, Any}}(),
        false,
    )
end

IOM.get_inner_data(ped::PowerFlowEvaluationData) = ped.power_flow_data
IOM.reset!(ped::PowerFlowEvaluationData) = (ped.is_solved = false; return)
IOM.is_solved(ped::PowerFlowEvaluationData) = ped.is_solved
get_input_key_map(ped::PowerFlowEvaluationData) = ped.input_key_map

include("pf_input_mapping.jl")
include("pf_data_update.jl")
include("pf_headroom.jl")
include("pf_solve_and_aux.jl")

end # module
