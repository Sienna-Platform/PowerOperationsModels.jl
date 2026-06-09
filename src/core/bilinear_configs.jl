############################ Shared default attributes #####################################

"""
Default `DeviceModel` attributes shared by every formulation that bridges a
bilinear/quadratic term to IOM's approximation API (`HydroTurbineBilinearDispatch`,
`QuadraticLossConverter`, `HVDCTwoTerminalVSC`). This is the single source of both
the default values and the per-attribute documentation; the formulations splice
it into their `get_default_attributes` (adding only formulation-specific extras).

- `"bilinear_approximation"` (default `"none"`): the approximation scheme for the
  bilinear product. `"none"` keeps it exact (an NLP needing a nonlinear solver
  such as Ipopt); `"bin2"`, `"hybs"`, `"nmdt"`, `"dnmdt"` are tolerance-driven
  linearizations (mixed-integer linear).
- `"bilinear_quadratic_method"` (default `"solver_sos2"`): the inner quadratic PWL
  method used by the `"bin2"` and `"hybs"` schemes. Supported: `"solver_sos2"`,
  `"manual_sos2"`, `"sawtooth"`; `"bin2"` also accepts `"nmdt"` and `"dnmdt"`.
- `"bilinear_relative_tolerance"` (default `0.05`): approximation gap as a
  fraction of the product magnitude — the default sizing knob.
- `"bilinear_absolute_tolerance"` (default `nothing`): approximation gap in
  absolute (product) units.

Exactly one of the two tolerances must be set (see [`_resolve_tolerance`](@ref));
the set value must be finite and `> 0`.
"""
const BILINEAR_APPROX_DEFAULT_ATTRIBUTES = Dict{String, Any}(
    "bilinear_approximation" => "none",
    "bilinear_quadratic_method" => "solver_sos2",
    "bilinear_relative_tolerance" => 0.05,
    "bilinear_absolute_tolerance" => nothing,
)

############################ Validation helpers ############################################

function _validate_tolerance(tolerance::Float64)
    (isfinite(tolerance) && tolerance > 0) || throw(
        ArgumentError(
            "bilinear approximation `tolerance` must be finite and > 0, got $tolerance",
        ),
    )
    return tolerance
end

"""
Characteristic magnitude of a variable over its per-device `bounds`
(`max|x|` across all devices). Used to turn a relative tolerance into an
absolute one — see [`_resolve_tolerance`](@ref).
"""
_max_abs(bounds) = maximum(max(abs(b.min), abs(b.max)) for b in bounds)

"""
Resolve the absolute bilinear/quadratic approximation tolerance from the
`absolute` and `relative` attribute values. A relative tolerance is scaled to
absolute by the characteristic product/term magnitude `scale`
(`τ_abs = relative · scale`). Exactly one of `absolute`/`relative` must be set
(the other `nothing`); it is an error for both or neither to be set. The
resolved tolerance must be finite and `> 0`.
"""
function _resolve_tolerance(absolute, relative, scale::Float64)
    abs_set = !isnothing(absolute)
    rel_set = !isnothing(relative)
    (abs_set || rel_set) || throw(
        ArgumentError(
            "exactly one of `bilinear_absolute_tolerance` or " *
            "`bilinear_relative_tolerance` must be set (both are unset)",
        ),
    )
    (abs_set && rel_set) && throw(
        ArgumentError(
            "exactly one of `bilinear_absolute_tolerance` or " *
            "`bilinear_relative_tolerance` must be set (both are set)",
        ),
    )
    tol = abs_set ? Float64(absolute) : Float64(relative) * scale
    return _validate_tolerance(tol)
end

function _quad_config_type(method::String)
    if method == "solver_sos2"
        return IOM.SolverSOS2QuadConfig
    elseif method == "manual_sos2"
        return IOM.ManualSOS2QuadConfig
    elseif method == "sawtooth"
        return IOM.SawtoothQuadConfig
    elseif method == "nmdt"
        return IOM.NMDTQuadConfig
    elseif method == "dnmdt"
        return IOM.DNMDTQuadConfig
    else
        error(
            "Unsupported bilinear quadratic method \"$(method)\". " *
            "Supported: \"solver_sos2\", \"manual_sos2\", \"sawtooth\", " *
            "\"nmdt\", \"dnmdt\".",
        )
    end
end

const _BIN2_QUAD_METHODS = ("solver_sos2", "manual_sos2", "sawtooth", "nmdt", "dnmdt")
const _HYBS_QUAD_METHODS = ("solver_sos2", "manual_sos2", "sawtooth")

function _validate_quad_method(method::String, scheme::String, supported)
    method in supported || error(
        "Unsupported bilinear quadratic method \"$(method)\" for bilinear " *
        "approximation \"$(scheme)\". Supported: " *
        join(("\"$(m)\"" for m in supported), ", ") * ".",
    )
    return method
end

############################ Translation to IOM configs ####################################

"""
Build the IOM bilinear config consumed by `IOM._add_bilinear_approx!` from
string attribute values, sizing the discretization from `tolerance` and the
per-device domain widths (`delta_x`, `delta_y`).

`method` selects the bilinear approximation scheme: `"bin2"`, `"hybs"`,
`"nmdt"`, `"dnmdt"`, or `"none"`. `quad_method` selects the inner quadratic
PWL method used by the `"bin2"` and `"hybs"` schemes (`"solver_sos2"`,
`"manual_sos2"`, `"sawtooth"`, and — for `"bin2"` only — `"nmdt"`, `"dnmdt"`);
it is ignored by the other schemes.

Each IOM `tolerance_depth` / `tolerance_epigraph_depth` helper inverts its
method's worst-case-gap bound and allocates the error budget across the inner
quadratic, so POM never sizes the inner quad by hand — it just builds the inner
quad at the returned `depth` (with the IOM-default `epigraph_depth`).

Errors when `method` or `quad_method` is unrecognized, when `quad_method` is
invalid for the selected scheme, or when `tolerance` is non-finite or ≤ 0.
"""
function _build_bilinear_config(
    method::String,
    quad_method::String,
    tolerance::Float64,
    delta_x::Float64,
    delta_y::Float64,
)
    method == "none" && return IOM.NoBilinearApproxConfig()
    _validate_tolerance(tolerance)
    if method == "bin2"
        _validate_quad_method(quad_method, method, _BIN2_QUAD_METHODS)
        Q = _quad_config_type(quad_method)
        depth = IOM.tolerance_depth(
            IOM.Bin2Config{Q};
            tolerance = tolerance,
            max_delta_x = delta_x,
            max_delta_y = delta_y,
        )
        return IOM.Bin2Config(Q(; depth))
    elseif method == "hybs"
        _validate_quad_method(quad_method, method, _HYBS_QUAD_METHODS)
        Q = _quad_config_type(quad_method)
        depth = IOM.tolerance_depth(
            IOM.HybSConfig{Q};
            tolerance = tolerance,
            max_delta_x = delta_x,
            max_delta_y = delta_y,
        )
        epigraph_depth = IOM.tolerance_epigraph_depth(
            IOM.HybSConfig{Q};
            tolerance = tolerance,
            max_delta_x = delta_x,
            max_delta_y = delta_y,
        )
        return IOM.HybSConfig(Q(; depth); epigraph_depth)
    elseif method == "nmdt"
        depth = IOM.tolerance_depth(
            IOM.NMDTBilinearConfig;
            tolerance = tolerance,
            max_delta_x = delta_x,
            max_delta_y = delta_y,
        )
        return IOM.NMDTBilinearConfig(; depth)
    elseif method == "dnmdt"
        depth = IOM.tolerance_depth(
            IOM.DNMDTBilinearConfig;
            tolerance = tolerance,
            max_delta_x = delta_x,
            max_delta_y = delta_y,
        )
        return IOM.DNMDTBilinearConfig(; depth)
    else
        error(
            "Unsupported bilinear approximation \"$(method)\". " *
            "Supported: \"bin2\", \"hybs\", \"nmdt\", \"dnmdt\", \"none\".",
        )
    end
end
