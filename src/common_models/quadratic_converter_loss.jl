# Shared helpers for quadratic / two-term converter losses
#   loss(I) = a * I^2 + b * |I| + c
# Used by the multi-terminal InterconnectingConverter formulation
# (QuadraticLossConverter) and the two-terminal TwoTerminalVSCLine formulation
# (HVDCTwoTerminalVSC). Both default to the exact (NLP) case and opt into MILP
# approximations via the `"bilinear_approximation"` attribute.
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

In MILP formulations the i_sq_t is still an AffExpr.

The `iszero` guards avoid adding 0s to the JuMP expression which might slightly hurt the solver.
"""
function _quadratic_converter_loss_expr(
    a::Float64, b::Float64, c::Float64,
    i_sq_t::JuMP.AffExpr,
    abs_i_t::JuMP.VariableRef,
)
    expr = JuMP.AffExpr(c)
    iszero(a) || add_proportional_to_jump_expression!(expr, i_sq_t, a)
    iszero(b) || add_proportional_to_jump_expression!(expr, abs_i_t, b)
    return expr
end

function _quadratic_converter_loss_expr(
    a::Float64, b::Float64, c::Float64,
    i_sq_t::JuMP.QuadExpr,
    abs_i_t::JuMP.VariableRef,
)
    expr = JuMP.QuadExpr(JuMP.AffExpr(c))
    iszero(a) || add_proportional_to_jump_expression!(expr, i_sq_t, a)
    iszero(b) || add_proportional_to_jump_expression!(expr, abs_i_t, b)
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

# Worst-case domain width across devices, used to size the tolerance-driven
# discretizations. Errors if the width is non-finite (missing/infinite limits).
function _max_delta(bounds)
    delta = maximum(b.max - b.min for b in bounds)
    isfinite(delta) || error(
        "Converter bilinear approximation requires finite variable bounds to " *
        "size the discretization, but got a non-finite domain width ($(delta)). " *
        "Check the device voltage/current limits.",
    )
    return delta
end

# Build (quad_cfg, bilin_cfg) for a converter-loss formulation.
function _build_converter_configs(
    ::Type{F},
    model::DeviceModel,
    v_bounds,
    i_bounds,
) where {F <: Union{QuadraticLossConverter, HVDCTwoTerminalVSC}}
    method = get_attribute(model, "bilinear_approximation")
    quad_method = get_attribute(model, "bilinear_quadratic_method")
    abs_tol = get_attribute(model, "bilinear_absolute_tolerance")
    rel_tol = get_attribute(model, "bilinear_relative_tolerance")
    method == "none" &&
        return (IOM.NoQuadApproxConfig(), IOM.NoBilinearApproxConfig())
    v_delta, i_delta = _max_delta(v_bounds), _max_delta(i_bounds)
    # Bilinear v·i sized against the product magnitude max|v|·max|i|.
    tol_prod = _resolve_tolerance(abs_tol, rel_tol, _max_abs(v_bounds) * _max_abs(i_bounds))
    bilin_cfg = _build_bilinear_config(method, quad_method, tol_prod, v_delta, i_delta)
    quad_cfg = _converter_quad_config(bilin_cfg, quad_method, abs_tol, rel_tol, i_bounds)
    return (quad_cfg, bilin_cfg)
end

# Quad config for the standalone loss `I²`. For bin2/hybs the bilinear's inner
# quad is reused — the bin2/hybs tolerance bound assumes the squares share that
# inner quad (see bilinear_approximations/bin2.jl). For nmdt/dnmdt the bilinear
# uses a discretization and never builds `I²`, so the loss `I²` is sized on its
# own from the quad method and tolerance over the `I` domain (scaled by the `I²`
# magnitude max|i|² when the tolerance is relative).
_converter_quad_config(
    bilin_cfg::Union{IOM.Bin2Config, IOM.HybSConfig},
    ::String,
    _abs_tol,
    _rel_tol,
    _i_bounds,
) = bilin_cfg.quad_config

function _converter_quad_config(
    ::Union{IOM.NMDTBilinearConfig, IOM.DNMDTBilinearConfig},
    quad_method::String,
    abs_tol,
    rel_tol,
    i_bounds,
)
    Q = _quad_config_type(quad_method)
    tol_sq = _resolve_tolerance(abs_tol, rel_tol, _max_abs(i_bounds)^2)
    depth = IOM.tolerance_depth(Q; tolerance = tol_sq, max_delta = _max_delta(i_bounds))
    return Q(; depth = depth)
end

# Add the bilinear `x·y` approximation, reusing the precomputed `ysq` (= the
# loss `i_sq`) for the squares-based schemes and building `xsq` internally; the
# discretization-based schemes ignore `ysq`/`quad_cfg` and take the raw form
# (so no `xsq` is created — no model bloat).
function _add_converter_bilinear!(
    bilin_cfg::Union{IOM.Bin2Config, IOM.HybSConfig, IOM.NoBilinearApproxConfig},
    quad_cfg,
    container::OptimizationContainer,
    ::Type{C},
    names,
    time_steps,
    x_var,
    y_var,
    ysq,
    x_bounds,
    y_bounds,
    meta::String,
) where {C <: IS.InfrastructureSystemsComponent}
    xsq = IOM._add_quadratic_approx!(
        quad_cfg, container, C, names, time_steps,
        x_var, x_bounds, meta * "_xsq",
    )
    return IOM._add_bilinear_approx!(
        bilin_cfg, container, C, names, time_steps,
        xsq, ysq, x_var, y_var, x_bounds, y_bounds, meta,
    )
end

function _add_converter_bilinear!(
    bilin_cfg::Union{IOM.NMDTBilinearConfig, IOM.DNMDTBilinearConfig},
    quad_cfg,
    container::OptimizationContainer,
    ::Type{C},
    names,
    time_steps,
    x_var,
    y_var,
    ysq,
    x_bounds,
    y_bounds,
    meta::String,
) where {C <: IS.InfrastructureSystemsComponent}
    return IOM._add_bilinear_approx!(
        bilin_cfg, container, C, names, time_steps,
        x_var, y_var, x_bounds, y_bounds, meta,
    )
end
