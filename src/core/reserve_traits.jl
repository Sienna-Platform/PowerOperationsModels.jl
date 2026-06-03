# Marker singleton trait types used to parametrize hybrid/storage reserve variable,
# expression, and constraint families. These eliminate the need for paired sibling
# singletons across the codebase: a single parametric struct is used instead of
# every (Charge/Discharge), (Up/Down), (Unscaled/Deployed), (UB/LB) sibling pair.

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
