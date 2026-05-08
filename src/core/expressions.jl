# POM-specific expression types
# Base expression types (SystemBalanceExpressions, CostExpressions, etc.) are imported from IOM

# POM-specific abstract type for post-contingency system balance expressions
abstract type PostContingencySystemBalanceExpressions <: SystemBalanceExpressions end

# POM-specific concrete types
struct PostContingencyActivePowerBalance <: PostContingencySystemBalanceExpressions end
struct ComponentReserveUpBalanceExpression <: ExpressionType end
struct ComponentReserveDownBalanceExpression <: ExpressionType end
struct InterfaceTotalFlow <: ExpressionType end
struct PTDFBranchFlow <: ExpressionType end
struct PostContingencyNodalActivePowerDeployment <: PostContingencyExpressions end
struct RealizedShiftedLoad <: ExpressionType end

#################################################################################
# Hydro Expressions
#################################################################################

"""
Expression for [`PowerSystems.HydroGen`](@extref) that keep track
of served reserve up for energy calculations
"""
struct HydroServedReserveUpExpression <: ExpressionType end

"""
Expression for [`PowerSystems.HydroGen`](@extref) that keep track
of served reserve down for energy calculations
"""
struct HydroServedReserveDownExpression <: ExpressionType end

"""
Expression for [`PowerSystems.HydroReservoir](@extref) that keep track
of total power into a reservoir, from all the upstream turbines connected to it
"""
struct TotalHydroPowerReservoirIncoming <: ExpressionType end

"""
Expression for [`PowerSystems.HydroReservoir](@extref) that keep track
of total power out of a reservoir, from all the downstream turbines connected to it
"""
struct TotalHydroPowerReservoirOutgoing <: ExpressionType end

"""
Expression for [`PowerSystems.HydroReservoir](@extref) that keep track
of total spillage power into a reservoir, from all the upstream reservoirs connected to it
"""
struct TotalSpillagePowerReservoirIncoming <: ExpressionType end

"""
Expression for [`PowerSystems.HydroReservoir`](@extref) that keep track
of total water flow turbined into a reservoir, from all the upstream turbines connected to it
"""
struct TotalHydroFlowRateReservoirIncoming <: ExpressionType end

"""
Expression for [`PowerSystems.HydroReservoir`](@extref) that keep track
of total water turbined for a reservoir, from all the downstream turbines connected to it
"""
struct TotalHydroFlowRateReservoirOutgoing <: ExpressionType end

"""
Expression for [`PowerSystems.HydroReservoir](@extref) that keep track
of total spillage water flow rate into a reservoir, from all the upstream reservoirs connected to it
"""
struct TotalSpillageFlowRateReservoirIncoming <: ExpressionType end

"""
Expression for [`PowerSystems.HydroGen`](@extref) that keep track
of total water turbined for a turbine, coming from multiple reservoirs
"""
struct TotalHydroFlowRateTurbineOutgoing <: ExpressionType end

"""
Expression for [`PowerSystems.System`](@extref) that keep track
of the energy balance for the system in medium term planning
"""
struct EnergyBalanceExpression <: ExpressionType end

#################################################################################
# Energy Storage Expressions
#################################################################################

"""
Per-device, per-service aggregation of the reserve quantity offered by a storage device
(or the storage subcomponent of a hybrid system). One container is created per service
participated in, and the per-component reserve variables (charging + discharging) are
summed into it. Consumed by [`HybridReserveBalanceConstraint`](@ref) and used as the
right-hand side of the system-level reserve balance.
"""
struct TotalReserveOffering <: ExpressionType end

"""
Aggregation of reserve variables allocated to the *discharge* side of a storage device
or hybrid storage subcomponent. Used for power-limit and SoC-coverage constraints. The
concrete subtypes split by direction (Up/Down) and by purpose
(`ReserveAssignmentBalance*` for power-limit constraints,
`ReserveDeploymentBalance*` for SoC accounting).
"""
abstract type StorageReserveDischargeExpression <: ExpressionType end

"""
Aggregation of reserve variables allocated to the *charge* side of a storage device or
hybrid storage subcomponent. Same role and split as
[`StorageReserveDischargeExpression`](@ref) but for the charging direction.
"""
abstract type StorageReserveChargeExpression <: ExpressionType end

# Assignment-balance variants: enter the storage charge/discharge power-limit constraints.
struct ReserveAssignmentBalanceUpDischarge <: StorageReserveDischargeExpression end
struct ReserveAssignmentBalanceUpCharge <: StorageReserveChargeExpression end
struct ReserveAssignmentBalanceDownDischarge <: StorageReserveDischargeExpression end
struct ReserveAssignmentBalanceDownCharge <: StorageReserveChargeExpression end

# Deployment-balance variants: enter the SoC coverage constraints (track served fraction).
struct ReserveDeploymentBalanceUpDischarge <: StorageReserveDischargeExpression end
struct ReserveDeploymentBalanceUpCharge <: StorageReserveChargeExpression end
struct ReserveDeploymentBalanceDownDischarge <: StorageReserveDischargeExpression end
struct ReserveDeploymentBalanceDownCharge <: StorageReserveChargeExpression end

#################################################################################
# Hybrid System Expressions
#################################################################################

"""
Hybrid-boundary aggregation of reserve quantities offered through the discharge (out) and
charge (in) sides of a `PSY.HybridSystem`. These expressions accumulate the per-subcomponent
reserve variables into the hybrid-system PCC reserve.
"""
abstract type HybridTotalReserveExpression <: ExpressionType end
abstract type HybridTotalReserveUpExpression <: HybridTotalReserveExpression end
abstract type HybridTotalReserveDownExpression <: HybridTotalReserveExpression end

struct HybridTotalReserveOutUpExpression <: HybridTotalReserveUpExpression end
struct HybridTotalReserveOutDownExpression <: HybridTotalReserveDownExpression end
struct HybridTotalReserveInUpExpression <: HybridTotalReserveUpExpression end
struct HybridTotalReserveInDownExpression <: HybridTotalReserveDownExpression end

"""
Served (deployed-fraction) variants of the hybrid total reserve expressions, used by the
energy-asset-balance accounting to discount the deployed portion of held reserve.
"""
abstract type HybridServedReserveExpression <: ExpressionType end

struct HybridServedReserveOutUpExpression <: HybridServedReserveExpression end
struct HybridServedReserveOutDownExpression <: HybridServedReserveExpression end
struct HybridServedReserveInUpExpression <: HybridServedReserveExpression end
struct HybridServedReserveInDownExpression <: HybridServedReserveExpression end

"""
Hybrid thermal subcomponent active power with the per-service reserve allocations
folded in, so that IOM's `add_semicontinuous_range_constraints!` emits
`p_th + Σ r_up ≤ max·on` (UB) and `p_th − Σ r_dn ≥ min·on` (LB) over a
HybridSystem-keyed device.
"""
struct HybridThermalActivePowerWithReserveUB <: RangeConstraintUBExpressions end
struct HybridThermalActivePowerWithReserveLB <: RangeConstraintLBExpressions end

# Method extensions for output writing
should_write_resulting_value(::Type{InterfaceTotalFlow}) = true
should_write_resulting_value(::Type{PTDFBranchFlow}) = true
should_write_resulting_value(::Type{RealizedShiftedLoad}) = true

should_write_resulting_value(::Type{HydroServedReserveUpExpression}) = true
should_write_resulting_value(::Type{HydroServedReserveDownExpression}) = true
should_write_resulting_value(::Type{TotalHydroFlowRateReservoirOutgoing}) = true
should_write_resulting_value(::Type{TotalHydroFlowRateTurbineOutgoing}) = true

should_write_resulting_value(::Type{StorageReserveDischargeExpression}) = true
should_write_resulting_value(::Type{StorageReserveChargeExpression}) = true

should_write_resulting_value(::Type{<:HybridServedReserveExpression}) = true

# Method extensions for unit conversion
convert_output_to_natural_units(::Type{InterfaceTotalFlow}) = true
convert_output_to_natural_units(::Type{PostContingencyBranchFlow}) = true
convert_output_to_natural_units(::Type{PostContingencyActivePowerGeneration}) = true
convert_output_to_natural_units(::Type{PTDFBranchFlow}) = true
convert_output_to_natural_units(::Type{RealizedShiftedLoad}) = true
