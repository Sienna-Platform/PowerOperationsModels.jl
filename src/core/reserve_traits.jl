# Marker singleton trait types used to parametrize hybrid/storage reserve variable,
# expression, and constraint families. These eliminate the need for paired sibling
# singletons across the codebase: a single parametric struct is used instead of
# every (Charge/Discharge) and (Unscaled/Deployed) sibling pair.

"""
Trait axis selecting how a reserve contribution is scaled into an aggregation:
[`UnscaledReserve`](@ref) (raw multiplier) or [`DeployedReserve`](@ref) (scaled by
`deployed_fraction`).
"""
abstract type ReserveScale end
"Reserve aggregation that uses the raw multiplier (1.0). Was Total / Assignment."
struct UnscaledReserve <: ReserveScale end
"Reserve aggregation that scales the multiplier by deployed_fraction. Was Served / Deployment."
struct DeployedReserve <: ReserveScale end

"""
Trait axis selecting which side of a storage device or hybrid PCC a reserve variable acts
on: [`DischargeSide`](@ref) (outflow) or [`ChargeSide`](@ref) (inflow).
"""
abstract type ReserveSide end
"Discharge / outflow side of a storage or hybrid PCC. Was Out (PCC) / Discharge (storage)."
struct DischargeSide <: ReserveSide end
"Charge / inflow side of a storage or hybrid PCC. Was In (PCC) / Charge (storage)."
struct ChargeSide <: ReserveSide end
