function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{CopperPlatePowerModel},
    ::PowerOperationsProblemTemplate,
)
    if get_use_slacks(model)
        add_variables!(container, SystemBalanceSlackUp, sys, model)
        add_variables!(container, SystemBalanceSlackDown, sys, model)
        add_to_expression!(container, ActivePowerBalance, SystemBalanceSlackUp, sys, model)
        add_to_expression!(
            container,
            ActivePowerBalance,
            SystemBalanceSlackDown,
            sys,
            model,
        )
        add_to_objective_function!(container, sys, model)
    end

    add_constraints!(container, CopperPlateBalanceConstraint, sys, model)

    add_constraint_dual!(container, sys, model)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{AreaBalancePowerModel},
    ::PowerOperationsProblemTemplate,
)
    if get_use_slacks(model)
        add_variables!(container, SystemBalanceSlackUp, sys, model)
        add_variables!(container, SystemBalanceSlackDown, sys, model)
        add_to_expression!(container, ActivePowerBalance, SystemBalanceSlackUp, sys, model)
        add_to_expression!(
            container,
            ActivePowerBalance,
            SystemBalanceSlackDown,
            sys,
            model,
        )
        add_to_objective_function!(container, sys, model)
    end

    add_constraints!(container, CopperPlateBalanceConstraint, sys, model)
    add_constraint_dual!(container, sys, model)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{<:AbstractPTDFModel},
    ::PowerOperationsProblemTemplate,
)
    if get_use_slacks(model)
        add_variables!(container, SystemBalanceSlackUp, sys, model)
        add_variables!(container, SystemBalanceSlackDown, sys, model)
        add_to_expression!(container, ActivePowerBalance, SystemBalanceSlackUp, sys, model)
        add_to_expression!(
            container,
            ActivePowerBalance,
            SystemBalanceSlackDown,
            sys,
            model,
        )
        add_to_objective_function!(container, sys, model)
    end
    add_constraints!(container, CopperPlateBalanceConstraint, sys, model)
    add_constraint_dual!(container, sys, model)
    return
end

# Shared skeleton for the native voltage-angle network formulations (DCP and ACP).
# Both add the VoltageAngle variable, the reference-bus pin, the active nodal
# balance, optional system-balance slacks, and the constraint dual. ACP additionally
# carries voltage magnitude and the reactive side, enabled via `reactive = true`:
# the VoltageMagnitude variable, the reactive nodal balance, and the reactive
# slack-expression wiring. Keeping this as a keyword-parameterized helper (not a
# new dispatch) avoids introducing method ambiguities.
function _construct_voltage_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{<:Union{DCPPowerModel, ACPPowerModel}};
    reactive::Bool,
)
    add_variables!(container, VoltageAngle, sys, model)
    if reactive
        add_variables!(container, VoltageMagnitude, sys, model)
    end
    # Slacks must be wired into the balance expressions BEFORE the nodal balance
    # constraints snapshot them; otherwise the in-place add_to_expression! mutation
    # never reaches the already-built MOI constraints and use_slacks is a no-op
    # (matches the CopperPlate/PTDF ordering above).
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
    model::NetworkModel{DCPPowerModel},
    template::PowerOperationsProblemTemplate,
)
    _construct_voltage_network!(container, sys, model; reactive = false)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{ACPPowerModel},
    template::PowerOperationsProblemTemplate,
)
    _construct_voltage_network!(container, sys, model; reactive = true)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{T},
    template::PowerOperationsProblemTemplate;
) where {T <: AbstractActivePowerModel}
    if T in UNSUPPORTED_POWERMODELS
        throw(
            ArgumentError(
                "$(T) formulation is not currently supported in InfrastructureOptimizationModels",
            ),
        )
    end

    if get_use_slacks(model)
        add_variables!(container, SystemBalanceSlackUp, sys, model)
        add_variables!(container, SystemBalanceSlackDown, sys, model)
        add_to_expression!(container, ActivePowerBalance, SystemBalanceSlackUp, sys, model)
        add_to_expression!(
            container,
            ActivePowerBalance,
            SystemBalanceSlackDown,
            sys,
            model,
        )
        add_to_objective_function!(container, sys, model)
    end

    @debug "Building the $T network with instantiate_nip_expr_model method" _group =
        LOG_GROUP_NETWORK_CONSTRUCTION
    powermodels_network!(container, T, sys, template, instantiate_nip_expr_model)
    add_pm_variable_refs!(container, T, sys, model)
    add_pm_constraint_refs!(container, T, sys)

    add_constraint_dual!(container, sys, model)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{T},
    template::PowerOperationsProblemTemplate;
) where {T <: AbstractPowerModel}
    if T in UNSUPPORTED_POWERMODELS
        throw(
            ArgumentError(
                "$(T) formulation is not currently supported in InfrastructureOptimizationModels",
            ),
        )
    end

    if get_use_slacks(model)
        add_variables!(container, SystemBalanceSlackUp, sys, model)
        add_variables!(container, SystemBalanceSlackDown, sys, model)
        add_to_expression!(container, ActivePowerBalance, SystemBalanceSlackUp, sys, model)
        add_to_expression!(
            container,
            ActivePowerBalance,
            SystemBalanceSlackDown,
            sys,
            model,
        )
        add_to_expression!(
            container,
            ReactivePowerBalance,
            SystemBalanceSlackUp,
            sys,
            model,
        )
        add_to_expression!(
            container,
            ReactivePowerBalance,
            SystemBalanceSlackDown,
            sys,
            model,
        )
        add_to_objective_function!(container, sys, model)
    end

    @debug "Building the $T network with instantiate_nip_expr_model method" _group =
        LOG_GROUP_NETWORK_CONSTRUCTION
    powermodels_network!(container, T, sys, template, instantiate_nip_expr_model)
    add_pm_variable_refs!(container, T, sys, model)
    add_pm_constraint_refs!(container, T, sys)

    add_constraint_dual!(container, sys, model)
    return
end

function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{T},
    template::PowerOperationsProblemTemplate,
) where {T <: PM.AbstractBFModel}
    if T in UNSUPPORTED_POWERMODELS
        throw(
            ArgumentError(
                "$(T) formulation is not currently supported in InfrastructureOptimizationModels",
            ),
        )
    end

    if get_use_slacks(model)
        add_variables!(container, SystemBalanceSlackUp, sys, model)
        add_variables!(container, SystemBalanceSlackDown, sys, model)
        add_to_expression!(
            container,
            ActivePowerBalance,
            SystemBalanceSlackUp,
            sys,
            model,
        )
        add_to_expression!(
            container,
            ActivePowerBalance,
            SystemBalanceSlackDown,
            sys,
            model,
        )
        add_to_expression!(
            container,
            ReactivePowerBalance,
            SystemBalanceSlackUp,
            sys,
            model,
        )
        add_to_expression!(
            container,
            ReactivePowerBalance,
            SystemBalanceSlackDown,
            sys,
            model,
        )
        add_to_objective_function!(container, sys, model)
    end

    @debug "Building the $T network with instantiate_bfp_expr_model method" _group =
        LOG_GROUP_NETWORK_CONSTRUCTION
    powermodels_network!(container, T, sys, template, instantiate_bfp_expr_model)
    add_pm_variable_refs!(container, T, sys, model)
    add_pm_constraint_refs!(container, T, sys)
    add_constraint_dual!(container, sys, model)
    return
end

#=
# AbstractIVRModel models not currently supported
function construct_network!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::NetworkModel{T},
    template::PowerOperationsProblemTemplate;
) where {T <: PM.AbstractIVRModel}
    if T in UNSUPPORTED_POWERMODELS
        throw(
            ArgumentError(
                "$(T) formulation is not currently supported in InfrastructureOptimizationModels",
            ),
        )
    end

    if get_use_slacks(model)
        add_variables!(container, SystemBalanceSlackUp, sys, T)
        add_variables!(container, SystemBalanceSlackDown, sys, T)
        add_to_expression!(
            container,
            ActivePowerBalance,
            SystemBalanceSlackUp,
            sys,
            model,
            T,
        )
        add_to_expression!(
            container,
            ActivePowerBalance,
            SystemBalanceSlackDown,
            sys,
            model,
            T,
        )
        add_to_expression!(
            container,
            ReactivePowerBalance,
            SystemBalanceSlackUp,
            sys,
            model,
            T,
        )
        add_to_expression!(
            container,
            ReactivePowerBalance,
            SystemBalanceSlackDown,
            sys,
            model,
            T,
        )
        add_to_objective_function!(container, sys, model)
    end

    @debug "Building the $T network with instantiate_vip_expr_model method" _group =
        LOG_GROUP_NETWORK_CONSTRUCTION
    #Constraints in case the model has DC Buses
    add_constraints!(container, NodalBalanceActiveConstraint, sys, model)
    powermodels_network!(container, T, sys, template, instantiate_vip_expr_model)
    add_pm_variable_refs!(container, T, sys, model)
    add_pm_constraint_refs!(container, T, sys)
    add_constraint_dual!(container, sys, model)
    return
end
=#
