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

# `filter` has no method for FlattenIteratorWrapper, so use a comprehension
# that works on any iterable.
_devices_with_linear_loss(devices) = [d for d in devices if _has_linear_loss(d)]

#########################################
######## Loss expression builder ########
#########################################

# Dispatched on the JuMP type of `i_sq_t`:
#   - JuMP.QuadExpr: exact i^2 product (NoQuadApproxConfig / NLP path). When
#     `a == 0` the result has no quadratic term, so we degrade to AffExpr.
#   - JuMP.AffExpr:  PWL approximation of i^2 (SOS2QuadConfig / MIP path).
# In both cases we accumulate with `add_to_expression!` to avoid the
# intermediate JuMP expressions the previous `+` chain produced.
function _quadratic_converter_loss_expr(
    a::Float64, b::Float64, c::Float64,
    i_sq_t::JuMP.QuadExpr, i_pos_t, i_neg_t;
    use_linear_loss::Bool,
)
    if iszero(a)
        expr = JuMP.AffExpr(c)
    else
        expr = JuMP.QuadExpr(JuMP.AffExpr(c))
        JuMP.add_to_expression!(expr, a, i_sq_t)
    end
    if use_linear_loss && !iszero(b)
        JuMP.add_to_expression!(expr, b, i_pos_t)
        JuMP.add_to_expression!(expr, b, i_neg_t)
    end
    return expr
end

function _quadratic_converter_loss_expr(
    a::Float64, b::Float64, c::Float64,
    i_sq_t::JuMP.AffExpr, i_pos_t, i_neg_t;
    use_linear_loss::Bool,
)
    expr = JuMP.AffExpr(c)
    iszero(a) || JuMP.add_to_expression!(expr, a, i_sq_t)
    if use_linear_loss && !iszero(b)
        JuMP.add_to_expression!(expr, b, i_pos_t)
        JuMP.add_to_expression!(expr, b, i_neg_t)
    end
    return expr
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
