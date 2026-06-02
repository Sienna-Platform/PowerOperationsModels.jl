# Bilinear-approximation configuration.
#
# These POM-owned types let a caller select the bilinear approximation scheme (and
# its inner quadratic method) for a bilinear `x × y` product *by type* — without
# depending on `InfrastructureOptimizationModels` (IOM). The accuracy of each
# scheme is driven by a `tolerance`; the discretization depth is derived from the
# tolerance and the two variables' ranges at constraint-build time (see
# `_iom_config`), so the caller never sets a manual depth / segment count.
#
# `_iom_config` translates these descriptors into the corresponding IOM config
# value used by `IOM._add_bilinear_approx!`. The approximation math itself lives
# entirely in IOM; this file is only the tolerance → IOM-config bridge.

############################ Inner quadratic methods #######################################

"""
Abstract supertype for the inner quadratic-approximation method used by the
[`Bin2Config`](@ref) and [`HybSConfig`](@ref) bilinear schemes (those schemes
approximate `x × y` via squared terms like `(x+y)²`, which each need a quadratic
PWL method). The marker types carry no data: the discretization depth is derived
from the bilinear config's `tolerance`.
"""
abstract type AbstractQuadApproxMethod end

"""
Solver-handled SOS2 piecewise-linear quadratic approximation (default inner
method). Worst-case gap `Δ²/(4·d²)`, so depth scales with `Δ/(2·√tolerance)`.
"""
struct SolverSOS2 <: AbstractQuadApproxMethod end

"""
Manually-formulated SOS2 piecewise-linear quadratic approximation. Same error
bound as [`SolverSOS2`](@ref); does not rely on solver SOS2 support.
"""
struct ManualSOS2 <: AbstractQuadApproxMethod end

"""
Sawtooth (binary-logarithmic) quadratic approximation. Worst-case gap
`Δ²·2^{-2L-2}`.
"""
struct Sawtooth <: AbstractQuadApproxMethod end

"""
Epigraph (one-sided-under) quadratic approximation. Valid only as an internal
cross-term method; it is *not* a permitted inner quad for [`Bin2Config`](@ref)
or [`HybSConfig`](@ref) (the tolerance derivation requires a one-sided-over
inner quad), and is therefore excluded from their `quad` field types.
"""
struct Epigraph <: AbstractQuadApproxMethod end

"""
NMDT (Normalized Multiparametric Disaggregation) quadratic approximation used as
an inner quad for [`Bin2Config`](@ref). Built at the IOM default `epigraph_depth`;
`IOM.tolerance_depth(Bin2Config{NMDTQuadConfig})` accounts for its two-sidedness.
Distinct from the top-level [`NMDTConfig`](@ref) bilinear scheme.
"""
struct NMDTQuad <: AbstractQuadApproxMethod end

"""
DNMDT (Double NMDT) quadratic approximation used as an inner quad for
[`Bin2Config`](@ref) (see [`NMDTQuad`](@ref)). Distinct from the top-level
[`DNMDTConfig`](@ref) bilinear scheme.
"""
struct DNMDTQuad <: AbstractQuadApproxMethod end

"""
Inner quadratic methods valid for [`Bin2Config`](@ref): everything except
[`Epigraph`](@ref), which is one-sided-under and breaks the Bin2 tolerance
derivation.
"""
const Bin2Quad = Union{SolverSOS2, ManualSOS2, Sawtooth, NMDTQuad, DNMDTQuad}

"""
Inner quadratic methods valid for [`HybSConfig`](@ref): only the SOS2 variants
and [`Sawtooth`](@ref). The HybS sandwich requires a one-sided-over inner quad
with no epigraph tightening, which rules out the NMDT/DNMDT inner quads as well
as [`Epigraph`](@ref).
"""
const HybSQuad = Union{SolverSOS2, ManualSOS2, Sawtooth}

############################ Bilinear approximation configs ################################

# Reject tolerances that would produce invalid discretization sizing downstream
# in `IOM.tolerance_depth` (e.g. domain errors on a non-positive or non-finite gap).
function _validate_tolerance(tolerance::Float64)
    (isfinite(tolerance) && tolerance > 0) || throw(
        ArgumentError(
            "bilinear approximation `tolerance` must be finite and > 0, got $tolerance",
        ),
    )
    return tolerance
end

"""
Abstract supertype for the bilinear-approximation scheme selected by the caller
(e.g. through a `DeviceModel` attribute) to linearize a bilinear `x × y` product.
"""
abstract type AbstractBilinearApproxConfig end

"""
Bin2 bilinear approximation (default scheme). Linearizes `x × y` via the identity
`x·y = ½((x+y)² − x² − y²)`, approximating each square with the inner quadratic
method `quad`.

# Fields
- `tolerance::Float64` (default `1e-2`): maximum approximation gap. The
  discretization depth is derived from this tolerance and the two variables'
  ranges via `IOM.tolerance_depth` (no manual depth knob).
- `quad::`[`Bin2Quad`](@ref) (default [`SolverSOS2`](@ref)`()`): inner quadratic
  method. [`Epigraph`](@ref) is intentionally not assignable.
"""
Base.@kwdef struct Bin2Config <: AbstractBilinearApproxConfig
    tolerance::Float64 = 1e-2
    quad::Bin2Quad = SolverSOS2()
    Bin2Config(tolerance, quad) = new(_validate_tolerance(tolerance), quad)
end

"""
HybS (Hybrid Separable) bilinear approximation. Sandwiches `x·y` between a Bin2
lower bound and a Bin3 upper bound, using the inner quadratic method `quad` for
the shared `x²`, `y²` terms and an internal epigraph approximation (sized from
the same `tolerance`) for the cross terms.

# Fields
- `tolerance::Float64` (default `1e-2`): maximum approximation gap. Both the
  inner-quad depth and the cross-term epigraph depth are derived from this
  tolerance via `IOM.tolerance_depth` / `IOM.tolerance_epigraph_depth`.
- `quad::`[`HybSQuad`](@ref) (default [`SolverSOS2`](@ref)`()`): inner quadratic
  method. Only the SOS2 variants and [`Sawtooth`](@ref) are assignable.
"""
Base.@kwdef struct HybSConfig <: AbstractBilinearApproxConfig
    tolerance::Float64 = 1e-2
    quad::HybSQuad = SolverSOS2()
    HybSConfig(tolerance, quad) = new(_validate_tolerance(tolerance), quad)
end

"""
NMDT (Normalized Multiparametric Disaggregation) bilinear approximation
(discretizes `x` only). Worst-case relaxation gap `Δx·Δy·2^{-L-2}`.

# Fields
- `tolerance::Float64` (default `1e-2`): maximum approximation gap; the depth `L`
  is derived from it and the two variables' ranges via `IOM.tolerance_depth`.
"""
Base.@kwdef struct NMDTConfig <: AbstractBilinearApproxConfig
    tolerance::Float64 = 1e-2
    NMDTConfig(tolerance) = new(_validate_tolerance(tolerance))
end

"""
DNMDT (Double NMDT) bilinear approximation (discretizes both `x` and `y`).
Worst-case relaxation gap `Δx·Δy·2^{-2L-2}`.

# Fields
- `tolerance::Float64` (default `1e-2`): maximum approximation gap; the depth `L`
  is derived from it and the two variables' ranges via `IOM.tolerance_depth`.
"""
Base.@kwdef struct DNMDTConfig <: AbstractBilinearApproxConfig
    tolerance::Float64 = 1e-2
    DNMDTConfig(tolerance) = new(_validate_tolerance(tolerance))
end

"""
Pass the quadratic `x × y` term to the solver directly, with no MILP
linearization. Use this with a nonlinear-capable solver; the resulting model is
not a MILP.
"""
struct NoBilinearApprox <: AbstractBilinearApproxConfig end

############################ Translation to IOM configs ####################################

# Map a POM inner-quad marker to the corresponding IOM quadratic-approx config TYPE.
_iom_quad_config_type(::SolverSOS2) = IOM.SolverSOS2QuadConfig
_iom_quad_config_type(::ManualSOS2) = IOM.ManualSOS2QuadConfig
_iom_quad_config_type(::Sawtooth) = IOM.SawtoothQuadConfig
_iom_quad_config_type(::Epigraph) = IOM.EpigraphQuadConfig
_iom_quad_config_type(::NMDTQuad) = IOM.NMDTQuadConfig
_iom_quad_config_type(::DNMDTQuad) = IOM.DNMDTQuadConfig

# TODO: McCormick cuts (`add_mccormick`) are dropped for now — we always defer to
# the IOM config's own default. Decide when they should be enabled and surface
# that through the `tolerance_depth` helper (so it stays a tolerance-driven
# decision) rather than re-exposing a raw knob here.

"""
Translate a POM [`AbstractBilinearApproxConfig`](@ref) into the IOM bilinear
config consumed by `IOM._add_bilinear_approx!`, sizing the discretization from
the config's `tolerance` and the per-device domain widths (`delta_x`, `delta_y`).

Each IOM `tolerance_depth` / `tolerance_epigraph_depth` helper inverts its
method's worst-case-gap bound and allocates the error budget across the inner
quadratic, so POM never sizes the inner quad by hand — it just builds the inner
quad at the returned `depth` (with the IOM-default `epigraph_depth`). Per-scheme
inner-quad validity is enforced statically by the `quad` field types
([`Bin2Quad`](@ref) / [`HybSQuad`](@ref)).
"""
function _iom_config end

_iom_config(::NoBilinearApprox, ::Float64, ::Float64) = IOM.NoBilinearApproxConfig()

function _iom_config(config::Bin2Config, delta_x::Float64, delta_y::Float64)
    Q = _iom_quad_config_type(config.quad)
    depth = IOM.tolerance_depth(
        IOM.Bin2Config{Q};
        tolerance = config.tolerance,
        max_delta_x = delta_x,
        max_delta_y = delta_y,
    )
    return IOM.Bin2Config(Q(; depth))
end

function _iom_config(config::HybSConfig, delta_x::Float64, delta_y::Float64)
    Q = _iom_quad_config_type(config.quad)
    depth = IOM.tolerance_depth(
        IOM.HybSConfig{Q};
        tolerance = config.tolerance,
        max_delta_x = delta_x,
        max_delta_y = delta_y,
    )
    epigraph_depth = IOM.tolerance_epigraph_depth(
        IOM.HybSConfig{Q};
        tolerance = config.tolerance,
        max_delta_x = delta_x,
        max_delta_y = delta_y,
    )
    return IOM.HybSConfig(Q(; depth); epigraph_depth)
end

function _iom_config(config::NMDTConfig, delta_x::Float64, delta_y::Float64)
    depth = IOM.tolerance_depth(
        IOM.NMDTBilinearConfig;
        tolerance = config.tolerance,
        max_delta_x = delta_x,
        max_delta_y = delta_y,
    )
    return IOM.NMDTBilinearConfig(; depth)
end

function _iom_config(config::DNMDTConfig, delta_x::Float64, delta_y::Float64)
    depth = IOM.tolerance_depth(
        IOM.DNMDTBilinearConfig;
        tolerance = config.tolerance,
        max_delta_x = delta_x,
        max_delta_y = delta_y,
    )
    return IOM.DNMDTBilinearConfig(; depth)
end
