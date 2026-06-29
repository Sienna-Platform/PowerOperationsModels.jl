#################################################################################
# ArgumentConstructStage — ALL network variables (voltage + balance slacks) and
# their balance-expression wiring. These run BEFORE device ModelConstructStage so
# voltage-coupled devices (e.g. ShuntSusceptanceDispatch) can reference voltage
# variables in their Model stage, and so every network variable is created in the
# argument stage like the rest of POM.
#################################################################################

# Balance slack variables + their nodal-balance wiring. Added in ArgumentConstructStage
# so the slacks are wired into the balance expressions before the Model-stage nodal
# balance constraints snapshot them — otherwise the in-place add_to_expression! mutation
# never reaches the already-built MOI constraints and use_slacks is a silent no-op.
function _add_balance_slack_variables!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel;
    reactive::Bool,
)
    if get_use_slacks(model)
        add_variables!(container, SystemBalanceSlackUp, sys, model)
        add_variables!(container, SystemBalanceSlackDown, sys, model)
        add_to_expression!(container, ActivePowerBalance, SystemBalanceSlackUp, sys, model)
        add_to_expression!(
            container, ActivePowerBalance, SystemBalanceSlackDown, sys, model,
        )
        if reactive
            add_to_expression!(
                container, ReactivePowerBalance, SystemBalanceSlackUp, sys, model,
            )
            add_to_expression!(
                container, ReactivePowerBalance, SystemBalanceSlackDown, sys, model,
            )
        end
    end
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{ACPNetworkModel},
    ::PowerOperationsProblemTemplate,
    ::ArgumentConstructStage,
)
    add_variables!(container, VoltageAngle, sys, model)
    add_variables!(container, VoltageMagnitude, sys, model)
    _add_balance_slack_variables!(container, sys, model; reactive = true)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
    ::PowerOperationsProblemTemplate,
    ::ArgumentConstructStage,
)
    add_variables!(container, VoltageReal, sys, model)
    add_variables!(container, VoltageImaginary, sys, model)
    _add_balance_slack_variables!(container, sys, model; reactive = true)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{LPACCNetworkModel},
    ::PowerOperationsProblemTemplate,
    ::ArgumentConstructStage,
)
    add_variables!(container, VoltageAngle, sys, model)
    add_variables!(container, VoltageDeviation, sys, model)
    _add_balance_slack_variables!(container, sys, model; reactive = true)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{<:Union{DCPNetworkModel, DCPLLNetworkModel}},
    ::PowerOperationsProblemTemplate,
    ::ArgumentConstructStage,
)
    add_variables!(container, VoltageAngle, sys, model)
    _add_balance_slack_variables!(container, sys, model; reactive = false)
    return
end

# Generic active-power-only Argument stage: CopperPlate, AreaBalance, PTDF, AreaPTDF,
# NFA. No voltage variables; only the (active) balance slacks.
function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{<:AbstractPowerModel},
    ::PowerOperationsProblemTemplate,
    ::ArgumentConstructStage,
)
    _add_balance_slack_variables!(container, sys, model; reactive = false)
    return
end

#################################################################################
# ModelConstructStage — slack objective, balance/reference constraints, duals.
# All network variables were already added in ArgumentConstructStage above.
#################################################################################

function _construct_copper_plate_model!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel,
)
    if get_use_slacks(model)
        add_to_objective_function!(container, sys, model)
    end
    add_constraints!(container, CopperPlateBalanceConstraint, sys, model)
    add_constraint_dual!(container, sys, model)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{CopperPlateNetworkModel},
    ::PowerOperationsProblemTemplate,
    ::ModelConstructStage,
)
    _construct_copper_plate_model!(container, sys, model)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{AreaBalanceNetworkModel},
    ::PowerOperationsProblemTemplate,
    ::ModelConstructStage,
)
    _construct_copper_plate_model!(container, sys, model)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{<:AbstractPTDFNetworkModel},
    ::PowerOperationsProblemTemplate,
    ::ModelConstructStage,
)
    _construct_copper_plate_model!(container, sys, model)
    return
end

# Shared skeleton for the native voltage-angle network formulations (DCP and ACP).
# Both add the reference-bus pin, the active nodal balance, the optional slack
# objective, and the constraint dual. ACP additionally carries the reactive nodal
# balance via `reactive = true`. Network variables (voltage + slacks) are added in
# ArgumentConstructStage; this Model-stage helper only adds objective/constraints.
function _construct_voltage_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{<:Union{DCPNetworkModel, ACPNetworkModel, DCPLLNetworkModel}};
    reactive::Bool,
)
    if get_use_slacks(model)
        add_to_objective_function!(container, sys, model)
    end
    add_constraints!(container, ReferenceBusConstraint, sys, model)
    add_constraints!(container, NodalBalanceActiveConstraint, sys, model)
    if reactive
        add_constraints!(container, NodalBalanceReactiveConstraint, sys, model)
    end
    add_constraint_dual!(container, sys, model)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{DCPNetworkModel},
    template::PowerOperationsProblemTemplate,
    ::ModelConstructStage,
)
    _construct_voltage_network!(container, sys, model; reactive = false)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{NFANetworkModel},
    template::PowerOperationsProblemTemplate,
    ::ModelConstructStage,
)
    if get_use_slacks(model)
        add_to_objective_function!(container, sys, model)
    end
    add_constraints!(container, NodalBalanceActiveConstraint, sys, model)
    add_constraint_dual!(container, sys, model)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{ACPNetworkModel},
    template::PowerOperationsProblemTemplate,
    ::ModelConstructStage,
)
    _construct_voltage_network!(container, sys, model; reactive = true)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
    template::PowerOperationsProblemTemplate,
    ::ModelConstructStage,
)
    if get_use_slacks(model)
        add_to_objective_function!(container, sys, model)
    end
    add_constraints!(container, ReferenceBusConstraint, sys, model)
    add_constraints!(container, VoltageMagnitudeConstraint, sys, model)
    add_constraints!(container, NodalBalanceActiveConstraint, sys, model)
    add_constraints!(container, NodalBalanceReactiveConstraint, sys, model)
    add_constraint_dual!(container, sys, model)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{LPACCNetworkModel},
    template::PowerOperationsProblemTemplate,
    ::ModelConstructStage,
)
    if get_use_slacks(model)
        add_to_objective_function!(container, sys, model)
    end
    add_constraints!(container, ReferenceBusConstraint, sys, model)
    add_constraints!(container, NodalBalanceActiveConstraint, sys, model)
    add_constraints!(container, NodalBalanceReactiveConstraint, sys, model)
    add_constraint_dual!(container, sys, model)
    return
end

function construct_network!(
    ::OptimizationContainer,
    ::PSY.System,
    ::NetworkModel{T},
    ::PowerOperationsProblemTemplate,
    ::ModelConstructStage,
) where {T <: AbstractPowerModel}
    error(
        "Network formulation $(T) is not supported. Supported native formulations: \
        CopperPlateNetworkModel, AreaBalanceNetworkModel, PTDFNetworkModel, AreaPTDFNetworkModel, \
        DCPNetworkModel, NFANetworkModel, DCPLLNetworkModel, ACPNetworkModel, ACRNetworkModel, \
        LPACCNetworkModel, IVRNetworkModel.",
    )
end
