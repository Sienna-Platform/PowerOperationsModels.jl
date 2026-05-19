# Shared helpers for quadratic / two-term converter losses
#   loss(I) = a * I^2 + b * |I| + c
# Used by multi-terminal InterconnectingConverter formulations
# (QuadraticLossConverterMILP, QuadraticLossConverterNLP) and two-terminal
# TwoTerminalVSCLine formulations (HVDCTwoTerminalVSCLP, HVDCTwoTerminalVSCNLP).
#
# `|I|` is represented by an LP surrogate: a single non-negative variable
# `CurrentAbsoluteValueVariable` bounded below by both `i` and `-i`. The
# optimum pins it to `|i|` because the loss term `b · abs_i` is being
# minimized via the generation-cost objective; no binary or complementarity
# constraint is required.

#########################################
######## Loss-curve introspection #######
#########################################

_get_quadratic_term(loss_fn::PSY.QuadraticCurve) = PSY.get_quadratic_term(loss_fn)
_get_quadratic_term(loss_fn) = 0.0

#########################################
######## Loss expression builder ########
#########################################

"""
    _quadratic_converter_loss_expr(a, b, c, i_sq_t, abs_i_t)

Build the per-timestep converter loss expression `a·I² + b·|I| + c`.

The `iszero(a)` / `iszero(b)` guards skip the corresponding
`add_to_expression!` call when the coefficient is exactly zero — this
avoids dragging a `0·I²` or `0·|I|` term into the JuMP expression, which
would otherwise allocate and force the wrong expression type (e.g., a
`QuadExpr` with a zero quadratic part on the MILP path).
"""
function _quadratic_converter_loss_expr(
    a::Float64, b::Float64, c::Float64,
    i_sq_t::JuMP.AffExpr,
    abs_i_t::JuMP.VariableRef,
)
    expr = JuMP.AffExpr(c)
    iszero(a) || JuMP.add_to_expression!(expr, a, i_sq_t)
    iszero(b) || JuMP.add_to_expression!(expr, b, abs_i_t)
    return expr
end

function _quadratic_converter_loss_expr(
    a::Float64, b::Float64, c::Float64,
    i_sq_t::JuMP.QuadExpr,
    abs_i_t::JuMP.VariableRef,
)
    expr = JuMP.QuadExpr(JuMP.AffExpr(c))
    iszero(a) || JuMP.add_to_expression!(expr, a, i_sq_t)
    iszero(b) || JuMP.add_to_expression!(expr, b, abs_i_t)
    return expr
end

#########################################
######## Absolute-value surrogate #######
#########################################

function _add_abs_value_constraints!(
    container::OptimizationContainer,
    devices,
    ::DeviceModel{D, F},
    ::NetworkModel{<:AbstractPowerModel},
    parent_var_type::Type{<:VariableType},
) where {D <: PSY.Device, F}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    jump_model = get_jump_model(container)
    i_var = get_variable(container, parent_var_type, D)
    abs_i_var = get_variable(container, CurrentAbsoluteValueVariable, D)

    lower_const = add_constraints_container!(
        container, CurrentAbsoluteValueConstraint, D, names, time_steps;
        meta = "ge_pos",
    )
    upper_const = add_constraints_container!(
        container, CurrentAbsoluteValueConstraint, D, names, time_steps;
        meta = "ge_neg",
    )

    for d in devices
        name = PSY.get_name(d)
        for t in time_steps
            lower_const[name, t] = JuMP.@constraint(
                jump_model, abs_i_var[name, t] >= i_var[name, t],
            )
            upper_const[name, t] = JuMP.@constraint(
                jump_model, abs_i_var[name, t] >= -i_var[name, t],
            )
        end
    end
    return
end
