# Shared helpers for quadratic / two-term converter losses
#   loss(I) = a * I^2 + b * |I| + c
# Used by multi-terminal InterconnectingConverter formulations
# (MILPQuadraticLossConverter, QuadraticLossConverter) and two-terminal
# HVDCTwoTerminalVSCNLP formulations.

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

# `_loss_seed` picks the right JuMP expression flavor for the I^2 term up
# front: QuadExpr when `i_sq_t` is the exact bilinear i*i (NLP path,
# NoQuadApproxConfig), AffExpr when it's the SOS2 PWL surrogate (MIP path).
# With `a == 0` the I^2 term drops, so we degrade to AffExpr in either case.
_loss_seed(c::Float64, ::JuMP.QuadExpr) = JuMP.QuadExpr(JuMP.AffExpr(c))
_loss_seed(c::Float64, ::JuMP.AffExpr) = JuMP.AffExpr(c)

function _quadratic_converter_loss_expr(
    a::Float64, b::Float64, c::Float64,
    i_sq_t, i_pos_t, i_neg_t;
    use_linear_loss::Bool,
)
    expr = iszero(a) ? JuMP.AffExpr(c) : _loss_seed(c, i_sq_t)
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

# Split into two stages so the variables are added in ArgumentConstructStage
# and the constraints in ModelConstructStage, matching the IOM construction
# convention. Both no-op when no device has a nonzero proportional loss term;
# the variables-stage helper additionally emits a configuration warning.
function _add_abs_value_decomposition_variables!(
    container::OptimizationContainer,
    devices,
    ::DeviceModel{D, F},
    ::NetworkModel{<:AbstractPowerModel},
) where {D <: PSY.Device, F}
    ll_devices = _devices_with_linear_loss(devices)
    if isempty(ll_devices)
        @warn "use_linear_loss is enabled but no $(D) has a nonzero proportional loss term; no linear-loss variables/constraints will be added."
        return
    end
    add_variables!(container, PositiveCurrent, ll_devices, F)
    add_variables!(container, NegativeCurrent, ll_devices, F)
    add_variables!(container, CurrentDirection, ll_devices, F)
    return
end

# I_max comes from different PSY accessors depending on the device, so we
# dispatch on the device type rather than asking the caller to thread a getter
# through. Two terminals on a VSC line share the same DC current variable, so
# we take the binding (min) rating; MT converters expose a single getter.
_linear_loss_i_max(d::PSY.TwoTerminalVSCLine) =
    min(PSY.get_max_dc_current_from(d), PSY.get_max_dc_current_to(d))
_linear_loss_i_max(d::PSY.InterconnectingConverter) = PSY.get_max_dc_current(d)

function _add_abs_value_decomposition_constraints!(
    container::OptimizationContainer,
    devices,
    ::DeviceModel{D, F},
    ::NetworkModel{<:AbstractPowerModel},
    parent_var_type::Type{<:VariableType},
) where {D <: PSY.Device, F}
    ll_devices = _devices_with_linear_loss(devices)
    isempty(ll_devices) && return

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
        i_max = _linear_loss_i_max(d)
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
