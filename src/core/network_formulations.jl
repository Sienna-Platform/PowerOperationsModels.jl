############################## Network Model Formulations ##################################
# AbstractPTDFNetworkModel must subtype AbstractDCPNetworkModel so that dispatch on
# AbstractDCPNetworkModel (e.g. _get_flow_variable_vector) catches PTDF models.
# This can't live in IS because IS is domain-agnostic and doesn't know about power-system networks.
abstract type AbstractPTDFNetworkModel <: AbstractDCPNetworkModel end

"""
Linear active power approximation using the power transfer distribution factor [PTDF](https://sienna-platform.github.io/PowerNetworkMatrices.jl/stable/tutorials/tutorial_PTDF_matrix/) matrix.
"""
struct PTDFNetworkModel <: AbstractPTDFNetworkModel end

"""
Infinite capacity approximation of network flow to represent entire system with a single node.
"""
struct CopperPlateNetworkModel <: AbstractActivePowerModel end

"""
Approximation to represent inter-area flow with each area represented as a single node.
"""
struct AreaBalanceNetworkModel <: AbstractActivePowerModel end

"""
Linear active power approximation using the power transfer distribution factor [PTDF](https://sienna-platform.github.io/PowerNetworkMatrices.jl/stable/tutorials/tutorial_PTDF_matrix/) matrix. Balancing areas as well as synchrounous regions.
"""
struct AreaPTDFNetworkModel <: AbstractPTDFNetworkModel end

#################################################################################
# Network Model Capabilities
# These functions define capabilities for different network formulations
#################################################################################

# Defaults are in IOM; POM only provides overrides for specific formulations
supports_branch_filtering(::Type{<:AbstractPTDFNetworkModel}) = true

ignores_branch_filtering(::Type{CopperPlateNetworkModel}) = true
ignores_branch_filtering(::Type{AreaBalanceNetworkModel}) = true

requires_all_branch_models(::Type{<:AbstractPTDFNetworkModel}) = false
requires_all_branch_models(::Type{CopperPlateNetworkModel}) = false
requires_all_branch_models(::Type{AreaBalanceNetworkModel}) = false

branches_modeled(::Type{CopperPlateNetworkModel}) = false
branches_modeled(::Type{AreaBalanceNetworkModel}) = false

# AC network models allocate a ReactivePowerBalance expression; active-power-only models do not
# (see common_models/make_system_expressions.jl). Used to drop reactive-only device models.
network_has_reactive_power(::Type{<:AbstractPowerModel}) = true
network_has_reactive_power(::Type{<:AbstractActivePowerModel}) = false

# Native POM DCP — concrete construct_network! in network_constructor.jl.
# IS doesn't know about power-system network formulations; POM owns all dispatch.
struct DCPNetworkModel <: AbstractDCPNetworkModel end

# Native POM ACP — concrete construct_network! in network_constructor.jl.
struct ACPNetworkModel <: AbstractACPModel end

# Native POM NFA (network-flow / transportation approximation). No voltage angle
# variables, no reference bus, no Ohm's law — only rating-bounded branch flows and
# nodal active-power balance. Concrete-type construct_network! beats the bridge
# fallback, same as DCP/ACP.
struct NFANetworkModel <: AbstractNFANetworkModel end

branches_modeled(::Type{NFANetworkModel}) = true
requires_all_branch_models(::Type{NFANetworkModel}) = true

# Native POM DCPLL (DC power flow with quadratic line losses). Same angle/balance structure
# as DCP, but branch flow is modeled with two directional active variables coupled by a
# quadratic loss constraint, making the problem a convex QCP (Ipopt).
struct DCPLLNetworkModel <: AbstractDCPLLNetworkModel end

branches_modeled(::Type{DCPLLNetworkModel}) = true
requires_all_branch_models(::Type{DCPLLNetworkModel}) = false

abstract type AbstractACRNetworkModel <: AbstractPowerModel end

"""
Full AC power flow in rectangular voltage coordinates (vr, vi). Physics-equivalent to
ACPNetworkModel; on the same system both solve the identical nonlinear program and therefore
reach the same optimal objective value.
"""
struct ACRNetworkModel <: AbstractACRNetworkModel end

abstract type AbstractLPACCNetworkModel <: AbstractPowerModel end

"""
Linear-programming AC, cold-start (LPAC) convex approximation of the full AC power flow.
Models voltage-magnitude deviation `phi = |V| - 1` (per bus), the bus-pair cosine variable
`cs` (per branch) with a convex cosine relaxation, and the LPAC-linearized branch power
flows. Tractable (convex QCP) and approximate — faster than full AC while modeling reactive
power.
"""
struct LPACCNetworkModel <: AbstractLPACCNetworkModel end

abstract type AbstractIVRNetworkModel <: AbstractPowerModel end

"""
Full AC power flow in current-voltage rectangular (IVR) coordinates. Uses branch current
variables (terminal and series) with a linear Ohm's law and bilinear branch power that is
wired into `ActivePowerBalance`/`ReactivePowerBalance`. Exact AC (same optimum as
`ACPNetworkModel` and `ACRNetworkModel`); advantage is that the Ohm's law is linear in the
decision variables, which can improve solver performance on some instances.

Devices inject P/Q unchanged (same as ACP/ACR); only the branch representation differs.
`construct_network!` is shared with `ACRNetworkModel` via Union dispatch in `network_constructor.jl`.
"""
struct IVRNetworkModel <: AbstractIVRNetworkModel end

#################################################################################
# Network-formulation capability traits (Holy traits)
#
# The network capabilities below cut across the inheritance tree: "models reactive
# power" {ACP,ACR,LPACC,IVR} and "has a voltage angle variable" {DCP,ACP,DCPLL,LPACC}
# overlap on {ACP,LPACC} but neither nests in the other, and `AbstractACPModel` is
# IS-owned (ACP's parent cannot be changed here). Single inheritance cannot express
# overlapping capability sets, so each capability is its own orthogonal trait axis.
# `construct_*`/`add_*!` methods dispatch on the trait instead of hand-enumerated
# Unions; the per-formulation membership lives here in one table.
#################################################################################

# --- How the active nodal power balance is indexed ---
abstract type NodalActiveBalanceStyle end
# Per-retained-bus balance indexed by bus name (the native nodal formulations).
struct NamedBusActiveBalance <: NodalActiveBalanceStyle end
# Injection-/area-aggregated balance (PTDF, CopperPlate, AreaBalance, AreaPTDF).
struct AggregatedActiveBalance <: NodalActiveBalanceStyle end

nodal_active_balance_style(::Type{<:AbstractPowerModel}) = AggregatedActiveBalance()
nodal_active_balance_style(::Type{DCPNetworkModel}) = NamedBusActiveBalance()
nodal_active_balance_style(::Type{NFANetworkModel}) = NamedBusActiveBalance()
nodal_active_balance_style(::Type{DCPLLNetworkModel}) = NamedBusActiveBalance()
nodal_active_balance_style(::Type{ACPNetworkModel}) = NamedBusActiveBalance()
nodal_active_balance_style(::Type{ACRNetworkModel}) = NamedBusActiveBalance()
nodal_active_balance_style(::Type{LPACCNetworkModel}) = NamedBusActiveBalance()
nodal_active_balance_style(::Type{IVRNetworkModel}) = NamedBusActiveBalance()

# --- Whether the network carries a reactive power balance ---
abstract type ReactivePowerSupport end
struct HasReactivePower <: ReactivePowerSupport end
struct NoReactivePower <: ReactivePowerSupport end

# Trait form of `network_has_reactive_power` (kept as a predicate for the `if`-based
# validation call sites; this is for dispatch). Same partition: AbstractPowerModel
# has it, AbstractActivePowerModel does not.
reactive_power_support(::Type{<:AbstractPowerModel}) = HasReactivePower()
reactive_power_support(::Type{<:AbstractActivePowerModel}) = NoReactivePower()

# --- Whether the network carries a bus VoltageAngle variable ---
abstract type VoltageForm end
# DCP/ACP/DCPLL/LPACC put a VoltageAngle on every bus; ACR/IVR use rectangular
# voltage and NFA/aggregated have none. Only this angle-vs-not split is dispatched
# on today (the VoltageAngle adder); finer distinctions can be added if a method
# ever needs them.
struct AngleBasedVoltage <: VoltageForm end
struct NonAngleVoltage <: VoltageForm end

voltage_form(::Type{<:AbstractPowerModel}) = NonAngleVoltage()
voltage_form(::Type{DCPNetworkModel}) = AngleBasedVoltage()
voltage_form(::Type{DCPLLNetworkModel}) = AngleBasedVoltage()
voltage_form(::Type{ACPNetworkModel}) = AngleBasedVoltage()
voltage_form(::Type{LPACCNetworkModel}) = AngleBasedVoltage()
