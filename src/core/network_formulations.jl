############################## Network Model Formulations ##################################
# AbstractPTDFModel must subtype AbstractDCPModel so that dispatch on
# AbstractDCPModel (e.g. _get_flow_variable_vector) catches PTDF models.
# This can't live in IS because IS doesn't know about PM.
abstract type AbstractPTDFModel <: AbstractDCPModel end

"""
Linear active power approximation using the power transfer distribution factor [PTDF](https://sienna-platform.github.io/PowerNetworkMatrices.jl/stable/tutorials/tutorial_PTDF_matrix/) matrix.
"""
struct PTDFPowerModel <: AbstractPTDFModel end

"""
Infinite capacity approximation of network flow to represent entire system with a single node.
"""
struct CopperPlatePowerModel <: AbstractActivePowerModel end

"""
Approximation to represent inter-area flow with each area represented as a single node.
"""
struct AreaBalancePowerModel <: AbstractActivePowerModel end

"""
Linear active power approximation using the power transfer distribution factor [PTDF](https://sienna-platform.github.io/PowerNetworkMatrices.jl/stable/tutorials/tutorial_PTDF_matrix/) matrix. Balancing areas as well as synchrounous regions.
"""
struct AreaPTDFPowerModel <: AbstractPTDFModel end

#################################################################################
# Network Model Capabilities
# These functions define capabilities for different network formulations
#################################################################################

# Defaults are in IOM; POM only provides overrides for specific formulations
supports_branch_filtering(::Type{<:AbstractPTDFModel}) = true

ignores_branch_filtering(::Type{CopperPlatePowerModel}) = true
ignores_branch_filtering(::Type{AreaBalancePowerModel}) = true

requires_all_branch_models(::Type{<:AbstractPTDFModel}) = false
requires_all_branch_models(::Type{CopperPlatePowerModel}) = false
requires_all_branch_models(::Type{AreaBalancePowerModel}) = false

branches_modeled(::Type{CopperPlatePowerModel}) = false
branches_modeled(::Type{AreaBalancePowerModel}) = false

# Native POM DCP — replaces the PM-bridge-routed DCPPowerModel re-export.
# Concrete-type construct_network! dispatches in network_constructor.jl
# beat the bridge's `where {T <: AbstractActivePowerModel}` fallback.
struct DCPPowerModel <: AbstractDCPModel end

# Native POM ACP — same dispatch trick as above against the bridge's
# `where {T <: AbstractPowerModel}` fallback.
struct ACPPowerModel <: AbstractACPModel end
