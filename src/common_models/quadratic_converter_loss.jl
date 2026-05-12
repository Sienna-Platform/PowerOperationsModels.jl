# Shared helpers for quadratic / two-term converter losses
#   loss(I) = a * I^2 + b * |I| + c
# Used by multi-terminal InterconnectingConverter formulations
# (MIPQuadraticLossConverter, QuadraticLossConverter) and two-terminal
# HVDCTwoTerminalVSC formulations.

#########################################
######## Loss-curve introspection #######
#########################################

_get_quadratic_term(loss_fn::PSY.QuadraticCurve) = PSY.get_quadratic_term(loss_fn)
_get_quadratic_term(loss_fn) = 0.0

_has_linear_loss(d::PSY.InterconnectingConverter) =
    !iszero(PSY.get_proportional_term(PSY.get_loss_function(d)))
_has_linear_loss(d::PSY.TwoTerminalVSCLine) =
    !iszero(PSY.get_proportional_term(PSY.get_converter_loss_from(d))) ||
    !iszero(PSY.get_proportional_term(PSY.get_converter_loss_to(d)))

_devices_with_linear_loss(devices) = filter(_has_linear_loss, devices)

#########################################
######## Loss expression builder ########
#########################################

function _quadratic_converter_loss_expr(
    a::Float64, b::Float64, c::Float64,
    i_sq_t, i_pos_t, i_neg_t;
    use_linear_loss::Bool,
)
    quad = iszero(a) ? 0 : a * i_sq_t
    lin = (use_linear_loss && !iszero(b)) ? b * (i_pos_t + i_neg_t) : 0
    const_term = iszero(c) ? 0 : c
    return quad + lin + const_term
end

#########################################
####### Abs-value decomposition #########
#########################################

function _add_abs_value_decomposition!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{D, F},
    ::NetworkModel{<:AbstractPowerModel},
    parent_var_type::Type{<:VariableType},
    i_max_getter::Function,
) where {D <: PSY.Device, F}
    ll_devices = _devices_with_linear_loss(devices)
    if isempty(ll_devices)
        @warn "use_linear_loss is enabled but no $(D) has a nonzero proportional loss term; no linear-loss variables/constraints will be added."
        return
    end

    add_variables!(container, PositiveCurrent, ll_devices, F)
    add_variables!(container, NegativeCurrent, ll_devices, F)
    add_variables!(container, CurrentDirection, ll_devices, F)

    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in ll_devices]
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

    for d in ll_devices
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
