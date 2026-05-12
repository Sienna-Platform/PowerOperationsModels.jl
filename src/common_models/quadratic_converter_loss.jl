# Shared helpers for quadratic / two-term converter losses
#   loss(I) = a * I^2 + b * |I| + c
# Used by multi-terminal InterconnectingConverter formulations
# (Bin2QuadraticLossConverter, QuadraticLossConverter) and two-terminal
# HVDCTwoTerminalVSC formulations.

#########################################
######## Loss-curve introspection #######
#########################################

_get_quadratic_term(loss_fn::PSY.QuadraticCurve) = PSY.get_quadratic_term(loss_fn)
_get_quadratic_term(loss_fn) = 0.0

# Whether the formulation wants the b*|I| linear-loss term (which requires
# decomposing the current into positive/negative parts with a direction binary).
_use_linear_loss(::Type{Bin2QuadraticLossConverter}, _) = true
_use_linear_loss(::Type{QuadraticLossConverter}, model) =
    get_attribute(model, "use_linear_loss")
_use_linear_loss(::Type{HVDCTwoTerminalVSCBin2}, _) = true
_use_linear_loss(::Type{HVDCTwoTerminalVSC}, model) =
    get_attribute(model, "use_linear_loss")

# Per-device test: does this device have a nonzero linear loss term anywhere?
# Dispatched on device type because different PSY devices store loss curves on
# different fields.
_has_linear_loss(d::PSY.InterconnectingConverter) =
    !iszero(PSY.get_proportional_term(PSY.get_loss_function(d)))
_has_linear_loss(d::PSY.TwoTerminalVSCLine) =
    !iszero(PSY.get_proportional_term(PSY.get_converter_loss_from(d))) ||
    !iszero(PSY.get_proportional_term(PSY.get_converter_loss_to(d)))

function _devices_with_linear_loss(devices)
    return [d for d in devices if _has_linear_loss(d)]
end

#########################################
######## Loss expression builder ########
#########################################

# Returns the JuMP expression  a*i_sq + b*(i_pos + i_neg) + c
# for a single (device, time). The b*(i_pos+i_neg) term is included only when
# the formulation has opted into the linear-loss path AND b is nonzero for
# this specific device.
function _quadratic_converter_loss_expr(
    a, b, c, i_sq_t, i_pos_t, i_neg_t; use_linear_loss::Bool,
)
    loss = a * i_sq_t + c
    if use_linear_loss && !iszero(b)
        loss += b * (i_pos_t + i_neg_t)
    end
    return loss
end

#########################################
####### Abs-value decomposition #########
#########################################

# Adds the three variables (PositiveCurrent, NegativeCurrent, CurrentDirection)
# that decompose a signed current variable into  i = i^+ - i^-  with a binary
# direction indicator. Called from the ArgumentConstructStage.
function _add_abs_value_decomposition_variables!(
    container::OptimizationContainer,
    devices,
    ::DeviceModel{D, F},
) where {D <: PSY.Device, F}
    add_variables!(container, PositiveCurrent, devices, F)
    add_variables!(container, NegativeCurrent, devices, F)
    add_variables!(container, CurrentDirection, devices, F)
    return
end

# Adds the three constraints implementing  i = i^+ - i^-  with the big-M
# direction binary bounds. The CurrentAbsoluteValueConstraint container is
# created internally with three meta-tagged sub-containers ("", "pos_ub",
# "neg_ub"). Caller passes the parent current variable type and a function
# `d -> i_max` so device-specific bound lookups stay device-specific.
function _add_abs_value_decomposition_constraints!(
    container::OptimizationContainer,
    devices,
    ::DeviceModel{D, F},
    ::NetworkModel{<:AbstractPowerModel},
    parent_var_type::Type{<:VariableType},
    i_max_getter::Function,
) where {D <: PSY.Device, F}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    jump_model = get_jump_model(container)
    i_var = get_variable(container, parent_var_type, D)
    i_pos_var = get_variable(container, PositiveCurrent, D)
    i_neg_var = get_variable(container, NegativeCurrent, D)
    i_dir_var = get_variable(container, CurrentDirection, D)

    abs_val_const = add_constraints_container!(
        container, CurrentAbsoluteValueConstraint, D, names, time_steps,
    )
    pos_ub_const = add_constraints_container!(
        container, CurrentAbsoluteValueConstraint, D, names, time_steps;
        meta = "pos_ub",
    )
    neg_ub_const = add_constraints_container!(
        container, CurrentAbsoluteValueConstraint, D, names, time_steps;
        meta = "neg_ub",
    )

    for d in devices
        name = PSY.get_name(d)
        i_max = i_max_getter(d)
        for t in time_steps
            abs_val_const[name, t] = JuMP.@constraint(
                jump_model,
                i_var[name, t] == i_pos_var[name, t] - i_neg_var[name, t],
            )
            pos_ub_const[name, t] = JuMP.@constraint(
                jump_model,
                i_pos_var[name, t] <= i_max * i_dir_var[name, t],
            )
            neg_ub_const[name, t] = JuMP.@constraint(
                jump_model,
                i_neg_var[name, t] <= i_max * (1 - i_dir_var[name, t]),
            )
        end
    end
    return
end
