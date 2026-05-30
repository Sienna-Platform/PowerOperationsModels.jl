# Bilinear-approximation configuration for `HydroTurbineMILPBilinearDispatch`.
#
# These POM-owned types let a user select the bilinear approximation scheme (and
# its inner quadratic method) for the turbined-flow × head product *by type*,
# through the single `"bilinear_config"` `DeviceModel` attribute — without
# depending on `InfrastructureOptimizationModels` (IOM). The accuracy of each
# scheme is driven by a `tolerance`; the discretization depth is derived per
# device at constraint-build time from the tolerance and the device's flow / head
# ranges (see `_iom_config`), so the user never sets a manual depth / segment
# count.
#
# `_iom_config` translates these descriptors into the corresponding IOM config
# value used by `IOM._add_bilinear_approx!`. The approximation math itself lives
# entirely in IOM; this file is only the tolerance → IOM-config bridge.

############################ Inner quadratic methods #######################################

"""
Abstract supertype for the inner quadratic-approximation method used by the
[`Bin2Config`](@ref) and [`HybSConfig`](@ref) bilinear schemes (those schemes
approximate `f × h` via squared terms like `(f+h)²`, which each need a quadratic
PWL method). The marker types carry no data: the discretization depth is derived
from the bilinear config's `tolerance` per device.
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
an inner quad. POM always builds it with `epigraph_depth = 0` so the inner
result stays one-sided-over (required by the tolerance derivation). Distinct
from the top-level [`NMDTConfig`](@ref) bilinear scheme.
"""
struct NMDTQuad <: AbstractQuadApproxMethod end

"""
DNMDT (Double NMDT) quadratic approximation used as an inner quad. Built with
`epigraph_depth = 0` (see [`NMDTQuad`](@ref)). Distinct from the top-level
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

"""
Abstract supertype for the bilinear-approximation scheme selected through the
`"bilinear_config"` attribute of a [`HydroTurbineMILPBilinearDispatch`](@ref)
`DeviceModel`.
"""
abstract type AbstractBilinearApproxConfig end

"""
Bin2 bilinear approximation (default scheme). Linearizes `f × h` via the identity
`f·h = ½((f+h)² − f² − h²)`, approximating each square with the inner quadratic
method `quad`.

# Fields
- `tolerance::Float64` (default `1e-2`): maximum approximation gap. The
  discretization depth is derived per device from this tolerance and the
  device's flow / head ranges via `IOM.tolerance_depth` (no manual depth knob).
- `quad::`[`Bin2Quad`](@ref) (default [`SolverSOS2`](@ref)`()`): inner quadratic
  method. [`Epigraph`](@ref) is intentionally not assignable.
- `add_mccormick::Bool` (default `true`): add reformulated McCormick cuts.
"""
Base.@kwdef struct Bin2Config <: AbstractBilinearApproxConfig
    tolerance::Float64 = 1e-2
    quad::Bin2Quad = SolverSOS2()
    add_mccormick::Bool = true
end

"""
HybS (Hybrid Separable) bilinear approximation. Sandwiches `f·h` between a Bin2
lower bound and a Bin3 upper bound, using the inner quadratic method `quad` for
the shared `f²`, `h²` terms and an internal epigraph approximation (sized from
the same `tolerance`) for the cross terms.

# Fields
- `tolerance::Float64` (default `1e-2`): maximum approximation gap. Both the
  inner-quad depth and the cross-term epigraph depth are derived per device from
  this tolerance via `IOM.tolerance_depth` / `IOM.tolerance_epigraph_depth`.
- `quad::`[`HybSQuad`](@ref) (default [`SolverSOS2`](@ref)`()`): inner quadratic
  method. Only the SOS2 variants and [`Sawtooth`](@ref) are assignable.
- `add_mccormick::Bool` (default `false`): add standard McCormick envelope cuts.
"""
Base.@kwdef struct HybSConfig <: AbstractBilinearApproxConfig
    tolerance::Float64 = 1e-2
    quad::HybSQuad = SolverSOS2()
    add_mccormick::Bool = false
end

"""
NMDT (Normalized Multiparametric Disaggregation) bilinear approximation
(discretizes `f` only). Worst-case relaxation gap `Δf·Δh·2^{-L-2}`.

# Fields
- `tolerance::Float64` (default `1e-2`): maximum approximation gap; the depth `L`
  is derived per device from it and the flow / head ranges via
  `IOM.tolerance_depth`.
"""
Base.@kwdef struct NMDTConfig <: AbstractBilinearApproxConfig
    tolerance::Float64 = 1e-2
end

"""
DNMDT (Double NMDT) bilinear approximation (discretizes both `f` and `h`).
Worst-case relaxation gap `Δf·Δh·2^{-2L-2}`.

# Fields
- `tolerance::Float64` (default `1e-2`): maximum approximation gap; the depth `L`
  is derived per device from it and the flow / head ranges via
  `IOM.tolerance_depth`.
"""
Base.@kwdef struct DNMDTConfig <: AbstractBilinearApproxConfig
    tolerance::Float64 = 1e-2
end

"""
Pass the quadratic `f × h` term to the solver directly, with no MILP
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

"""
Build an inner `IOM.QuadraticApproxConfig` of type `Q` at the tolerance-derived
`depth`. For `NMDTQuadConfig` / `DNMDTQuadConfig` the epigraph tightening is
disabled (`epigraph_depth = 0`): the bilinear tolerance derivations only hold
when those inner quads are one-sided-over, which requires `epigraph_depth = 0`.
"""
function _build_inner_quad(Q::Type{<:IOM.QuadraticApproxConfig}, depth::Int)
    if Q === IOM.NMDTQuadConfig || Q === IOM.DNMDTQuadConfig
        return Q(; depth, epigraph_depth = 0)
    else
        return Q(; depth)
    end
end

"""
Translate a POM [`AbstractBilinearApproxConfig`](@ref) into the IOM bilinear
config consumed by `IOM._add_bilinear_approx!`, sizing the discretization from
the config's `tolerance` and the per-device flow / head domain widths
(`flow_delta`, `head_delta`).

Each IOM `tolerance_depth` / `tolerance_epigraph_depth` helper inverts its
method's worst-case-gap bound; for `bin2` / `hybs` the bilinear-level helpers
allocate the error budget across the inner quadratic, so POM never sizes the
inner quad by hand. Per-scheme inner-quad validity is enforced statically by the
`quad` field types ([`Bin2Quad`](@ref) / [`HybSQuad`](@ref)).
"""
function _iom_config end

_iom_config(::NoBilinearApprox, ::Float64, ::Float64) = IOM.NoBilinearApproxConfig()

function _iom_config(config::Bin2Config, flow_delta::Float64, head_delta::Float64)
    Q = _iom_quad_config_type(config.quad)
    depth = IOM.tolerance_depth(
        IOM.Bin2Config{Q};
        tolerance = config.tolerance,
        max_delta_x = flow_delta,
        max_delta_y = head_delta,
    )
    return IOM.Bin2Config(
        _build_inner_quad(Q, depth);
        add_mccormick = config.add_mccormick,
    )
end

function _iom_config(config::HybSConfig, flow_delta::Float64, head_delta::Float64)
    Q = _iom_quad_config_type(config.quad)
    depth = IOM.tolerance_depth(
        IOM.HybSConfig{Q};
        tolerance = config.tolerance,
        max_delta_x = flow_delta,
        max_delta_y = head_delta,
    )
    epigraph_depth = IOM.tolerance_epigraph_depth(
        IOM.HybSConfig{Q};
        tolerance = config.tolerance,
        max_delta_x = flow_delta,
        max_delta_y = head_delta,
    )
    return IOM.HybSConfig(
        _build_inner_quad(Q, depth);
        epigraph_depth,
        add_mccormick = config.add_mccormick,
    )
end

function _iom_config(config::NMDTConfig, flow_delta::Float64, head_delta::Float64)
    depth = IOM.tolerance_depth(
        IOM.NMDTBilinearConfig;
        tolerance = config.tolerance,
        max_delta_x = flow_delta,
        max_delta_y = head_delta,
    )
    return IOM.NMDTBilinearConfig(; depth)
end

function _iom_config(config::DNMDTConfig, flow_delta::Float64, head_delta::Float64)
    depth = IOM.tolerance_depth(
        IOM.DNMDTBilinearConfig;
        tolerance = config.tolerance,
        max_delta_x = flow_delta,
        max_delta_y = head_delta,
    )
    return IOM.DNMDTBilinearConfig(; depth)
end
