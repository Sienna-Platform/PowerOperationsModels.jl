"""
Auxiliary Variable for Thermal Generation Models to keep track of time elapsed on
"""
struct TimeDurationOn <: AuxVariableType end

"""
Auxiliary Variable for Thermal Generation Models to keep track of time elapsed off
"""
struct TimeDurationOff <: AuxVariableType end

"""
Auxiliary Variable for Thermal Generation Models that solve for power above min
"""
struct PowerOutput <: AuxVariableType end

"""
Auxiliary Variable of DC Current Variables for DC Lines formulations
Docs abbreviation: ``p_l^{loss}``
"""
struct DCLineLosses <: AuxVariableType end

"""
Auxiliary Variables that are calculated using a `PowerFlowEvaluationModel`
"""
abstract type PowerFlowAuxVariableType <: AuxVariableType end

"""
Auxiliary Variable for the bus angle outputs from power flow evaluation
"""
struct PowerFlowVoltageAngle <: PowerFlowAuxVariableType end

"""
Auxiliary Variable for the bus voltage magnitude outputs from power flow evaluation
"""
struct PowerFlowVoltageMagnitude <: PowerFlowAuxVariableType end

"""
Auxiliary Variable for line power flow outputs from power flow evaluation
"""
abstract type BranchFlowAuxVariableType <: PowerFlowAuxVariableType end

"""
Auxiliary Variable for the line reactive flow in the from -> to direction from power flow evaluation
"""
struct PowerFlowBranchReactivePowerFromTo <: BranchFlowAuxVariableType end

"""
Auxiliary Variable for the line reactive flow in the to -> from direction from power flow evaluation
"""
struct PowerFlowBranchReactivePowerToFrom <: BranchFlowAuxVariableType end

"""
Auxiliary Variable for the line active flow in the from -> to direction from power flow evaluation
"""
struct PowerFlowBranchActivePowerFromTo <: BranchFlowAuxVariableType end

"""
Auxiliary Variable for the line active flow in the to -> from direction from power flow evaluation
"""
struct PowerFlowBranchActivePowerToFrom <: BranchFlowAuxVariableType end

"""
Auxiliary Variable for the loss factors from AC power flow evaluation that are calculated using the Jacobian matrix
"""
struct PowerFlowLossFactors <: PowerFlowAuxVariableType end

"""
Auxiliary Variable for the voltage stability factors from AC power flow evaluation that are calculated using the Jacobian matrix
"""
struct PowerFlowVoltageStabilityFactors <: PowerFlowAuxVariableType end

# should this be a subtype of BranchFlowAuxVariableType? It's line-related but has no flow direction.
"""
Auxiliary Variable for the active power loss on a line from AC power flow evaluation.
"""
struct PowerFlowBranchActivePowerLoss <: PowerFlowAuxVariableType end

# TODO reactive loss?

convert_output_to_natural_units(::Type{PowerOutput}) = true
convert_output_to_natural_units(
    ::Type{
        <:Union{
            PowerFlowBranchReactivePowerFromTo, PowerFlowBranchReactivePowerToFrom,
            PowerFlowBranchActivePowerFromTo, PowerFlowBranchActivePowerToFrom,
            PowerFlowBranchActivePowerLoss,
        },
    },
) = true

"""
Every `PowerFlowAuxVariableType` indexed by components of type `C` (branch or bus). Which of
these a given evaluator provides is decided by `_pf_provides_aux_var` in `PowerFlowsExt`.

A tuple, not a `Vector`, so callers' `map` keeps each `Type{T}` concrete. A new
`PowerFlowAuxVariableType` goes here and gets `_pf_provides_aux_var` methods;
`test_power_flow_in_the_loop.jl` fails if one is missing.
"""
function pf_aux_var_types end

pf_aux_var_types(::Type{PSY.ACBranch}) = (
    PowerFlowBranchReactivePowerFromTo,
    PowerFlowBranchReactivePowerToFrom,
    PowerFlowBranchActivePowerFromTo,
    PowerFlowBranchActivePowerToFrom,
    PowerFlowBranchActivePowerLoss,
)

pf_aux_var_types(::Type{PSY.ACBus}) = (
    PowerFlowVoltageAngle,
    PowerFlowVoltageMagnitude,
    PowerFlowLossFactors,
    PowerFlowVoltageStabilityFactors,
)

"Whether the auxiliary variable is calculated using a `PowerFlowEvaluationModel`"
# Default is_from_evaluator(::Type{<:AuxVariableType}) = false is in IOM interfaces.jl
is_from_evaluator(::Type{<:PowerFlowAuxVariableType}) = true

"""
Whether a load meets the conditions for an adjusted bid at a time step: `1.0` when some
base-case or post-contingency branch limit has a shadow price of at least
[`BID_ADJUSTMENT_CAP_FRACTION`](@ref) of its slack penalty and the load's directed shift
factor to that limit is below [`BID_ADJUSTMENT_SHIFT_FACTOR_THRESHOLD`](@ref); `0.0`
otherwise. The directed shift factor is the injection shift factor in the limit's binding
direction, so a negative value means the load's consumption pushes the flow further into
that limit. Computed after the solve for loads modeled with
[`StaticPowerLoadBidAdjustment`](@ref).
"""
struct BidAdjustmentArmed <: AuxVariableType end
