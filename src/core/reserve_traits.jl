# Marker singleton trait types used to parametrize hybrid/storage reserve variable,
# expression, and constraint families. These remove the need for paired sibling
# singletons across the codebase: a single parametric struct + const aliases replaces
# every (Charge/Discharge), (Up/Down), (Unscaled/Deployed), (UB/LB) sibling pair.

abstract type ReserveDirection end
struct Up <: ReserveDirection end
struct Down <: ReserveDirection end

abstract type ReserveScale end
"Reserve aggregation that uses the raw multiplier (1.0). Was Total / Assignment."
struct UnscaledReserve <: ReserveScale end
"Reserve aggregation that scales the multiplier by deployed_fraction. Was Served / Deployment."
struct DeployedReserve <: ReserveScale end

abstract type ReserveSide end
"Discharge / outflow side of a storage or hybrid PCC. Was Out (PCC) / Discharge (storage)."
struct DischargeSide <: ReserveSide end
"Charge / inflow side of a storage or hybrid PCC. Was In (PCC) / Charge (storage)."
struct ChargeSide <: ReserveSide end

# Constraint UB/LB axis: reuse IOM's `BoundDirection` / `UpperBound` / `LowerBound`
# (defined in InfrastructureOptimizationModels/common_models/constraint_helpers.jl).
# A local alias keeps the abstract name discoverable through POM exports.
const ConstraintBound = InfrastructureOptimizationModels.BoundDirection
