"""
Initial condition for volume in reservoir in [`PowerSystems.HydroReservoir`](@extref) formulations
"""
struct InitialReservoirVolume <: InitialConditionType end

######################### Initial Conditions Definitions#####################################
"""
Initial condition for the active power of a device. Reads `ActivePowerVariable`.
"""
struct DevicePower <: InitialConditionType end
"""
Initial condition for the active power of a device above its minimum. Reads `PowerAboveMinimumVariable`.
"""
struct DeviceAboveMinPower <: InitialConditionType end
"""
Initial condition for the on/off status of a device. Reads `OnVariable`.
"""
struct DeviceStatus <: InitialConditionType end
"""
Initial condition for the time a device has been on. The model build reads `OnVariable`.
The simulation update reads `TimeDurationOn`.
"""
struct InitialTimeDurationOn <: InitialConditionType end
"""
Initial condition for the time a device has been off. The model build reads `OnVariable`.
The simulation update reads `TimeDurationOff`.
"""
struct InitialTimeDurationOff <: InitialConditionType end
"""
Initial condition for the energy level of a storage device, a hybrid system, or a hydro
reservoir. Reads `EnergyVariable`.
"""
struct InitialEnergyLevel <: InitialConditionType end
"""
Initial condition for the area control error of a `PowerSystems.AGC` service. The AGC
service constructor adds it, but the AGC model file is not included in the module at this time.
It has no entry in `_ic_variable_type`.
"""
struct AreaControlError <: InitialConditionType end

# Decide whether to run the initial conditions reconciliation algorithm based on the presence of any of these
requires_reconciliation(::Type{<:InitialConditionType}) = false

requires_reconciliation(::Type{InitialTimeDurationOn}) = true
requires_reconciliation(::Type{InitialTimeDurationOff}) = true
requires_reconciliation(::Type{DeviceStatus}) = true
requires_reconciliation(::Type{DevicePower}) = true # to capture a case when device is off in HA but producing power in ED
requires_reconciliation(::Type{DeviceAboveMinPower}) = true # ramping limits may make power differences in thermal compact devices between models infeasible
requires_reconciliation(::Type{InitialEnergyLevel}) = true # large differences in initial storage levels could lead to infeasibilities
# Not requiring reconciliation for AreaControlError
