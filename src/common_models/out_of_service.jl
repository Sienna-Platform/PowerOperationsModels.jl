#=
Per-step component statuses for IOM's generic builders. The statuses of the injectors of a
type are their `InjectorStatusParameter`, those of an HVDC line its `BranchStatusParameter`.
A type without a schedule, and every AC branch type, keeps every component active: AC
branch outages enter through the network, so their flow variables stay free.
=#
function IOM.get_component_statuses(
    container::OptimizationContainer,
    ::Type{D},
) where {D <: PSY.StaticInjection}
    return _status_parameter_statuses(container, InjectorStatusParameter, D)
end

function IOM.get_component_statuses(
    container::OptimizationContainer,
    ::Type{D},
) where {D <: Union{PSY.TwoTerminalHVDC, PSY.TModelHVDCLine}}
    return _status_parameter_statuses(container, BranchStatusParameter, D)
end

function _status_parameter_statuses(
    container::OptimizationContainer,
    ::Type{P},
    ::Type{D},
) where {P <: ComponentStatusParameter, D <: PSY.Component}
    has_container_key(container, P, D) || return IOM.AllComponentsActive()
    return IOM.get_component_status_array(container, ParameterKey(P, D))
end

# The time series injections of an out device are zero: the builders scale them by its
# status, and so do their reported values, which the power flow evaluations and the stored
# outputs read.
IOM.scaled_by_component_status(
    ::Type{
        <:Union{
            ActivePowerTimeSeriesParameter,
            ReactivePowerTimeSeriesParameter,
            ActivePowerInTimeSeriesParameter,
            ActivePowerOutTimeSeriesParameter,
            ShiftUpActivePowerTimeSeriesParameter,
            ShiftDownActivePowerTimeSeriesParameter,
            HybridRenewableActivePowerTimeSeriesParameter,
            HybridElectricLoadTimeSeriesParameter,
        },
    },
) = true

# Names of the `D` devices that carry an injector schedule.
function _injector_schedule_names(
    container::OptimizationContainer,
    ::Type{D},
) where {D <: PSY.Component}
    has_container_key(container, InjectorStatusParameter, D) || return Set{String}()
    return Set{String}(axes(get_parameter_array(container, InjectorStatusParameter, D), 1))
end

# The operating variables of a device (power, commitment, reserve provision,
# post-contingency deployment) and of an HVDC line (flows, losses, converter powers) are
# fixed to zero at the steps it is out of service. State variables, start and stop
# variables and slacks stay free, so a device that goes out while running shuts down and a
# storage unit keeps its energy.
#
# Minimum up and down times, initial-condition ramp limits and shutdown ramp limits still
# apply: an outage that violates them, such as one that starts while a unit must stay on or
# that takes a unit off faster than it can ramp down, makes the model infeasible.
IOM.fixed_when_inactive(
    ::Type{
        <:Union{
            ActivePowerVariable,
            ReactivePowerVariable,
            PowerAboveMinimumVariable,
            OnVariable,
            ActivePowerInVariable,
            ActivePowerOutVariable,
            ActivePowerPumpVariable,
            HydroTurbineFlowRateVariable,
            ActivePowerReserveVariable,
            AncillaryServiceVariableCharge,
            AncillaryServiceVariableDischarge,
            ShiftUpActivePowerVariable,
            ShiftDownActivePowerVariable,
            FlowActivePowerVariable,
            FlowActivePowerFromToVariable,
            FlowActivePowerToFromVariable,
            FlowReactivePowerFromToVariable,
            FlowReactivePowerToFromVariable,
            HVDCLosses,
            HVDCActivePowerReceivedFromVariable,
            HVDCActivePowerReceivedToVariable,
            HVDCRectifierActivePowerVariable,
            HVDCInverterActivePowerVariable,
            HVDCRectifierReactivePowerVariable,
            HVDCInverterReactivePowerVariable,
            HVDCReactivePowerFromVariable,
            HVDCReactivePowerToVariable,
            DCLineCurrent,
            DCLineCurrentFlowVariable,
            PostContingencyDeploymentVariable,
        },
    },
) = true

# Post-contingency deployments are indexed (service, device, outage, t).
IOM.component_axis(::Type{PostContingencyDeploymentVariable}, ::SparseAxisArray) = 2

# The statuses that scale a row bounding the variable of `key`: those of its component when
# the variable is fixed to zero while the component is out, every component active otherwise.
function _fixed_variable_statuses(
    container::OptimizationContainer,
    ::IOM.VariableKey{U, C},
) where {U <: VariableType, C}
    IOM.fixed_when_inactive(U) || return IOM.AllComponentsActive()
    return get_component_statuses(container, IOM.component_axis_type(C))
end
