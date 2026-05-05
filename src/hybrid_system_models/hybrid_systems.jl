#! format: off

requires_initialization(::AbstractHybridFormulation) = false

#################################################################################
# Default time-series and attributes
#################################################################################

function get_default_time_series_names(
    ::Type{PSY.HybridSystem},
    ::Type{<:Union{FixedOutput, AbstractHybridFormulation}},
)
    return Dict{Type{<:TimeSeriesParameter}, String}(
        HybridRenewableActivePowerTimeSeriesParameter => "RenewableDispatch__max_active_power",
        HybridElectricLoadTimeSeriesParameter => "PowerLoad__max_active_power",
    )
end

function get_default_attributes(
    ::Type{PSY.HybridSystem},
    ::Type{<:Union{FixedOutput, AbstractHybridFormulation}},
)
    return Dict{String, Any}(
        "reservation" => true,
        "energy_target" => false,
    )
end

#################################################################################
# PCC variables — ActivePowerInVariable / ActivePowerOutVariable
#################################################################################

get_variable_binary(::Type{ActivePowerInVariable}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
get_variable_lower_bound(::Type{ActivePowerInVariable}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = PSY.get_input_active_power_limits(d).min
get_variable_upper_bound(::Type{ActivePowerInVariable}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = PSY.get_input_active_power_limits(d).max
get_variable_multiplier(::Type{ActivePowerInVariable}, ::Type{<:PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = -1.0

get_variable_binary(::Type{ActivePowerOutVariable}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
get_variable_lower_bound(::Type{ActivePowerOutVariable}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = PSY.get_output_active_power_limits(d).min
get_variable_upper_bound(::Type{ActivePowerOutVariable}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = PSY.get_output_active_power_limits(d).max
get_variable_multiplier(::Type{ActivePowerOutVariable}, ::Type{<:PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = 1.0

get_variable_binary(::Type{ReactivePowerVariable}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
function get_variable_lower_bound(::Type{ReactivePowerVariable}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation})
    limits = PSY.get_reactive_power_limits(d)
    return limits === nothing ? nothing : limits.min
end
function get_variable_upper_bound(::Type{ReactivePowerVariable}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation})
    limits = PSY.get_reactive_power_limits(d)
    return limits === nothing ? nothing : limits.max
end
get_variable_multiplier(::Type{ReactivePowerVariable}, ::Type{<:PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = 1.0

get_variable_binary(::Type{ReservationVariable}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = true

get_min_max_limits(d::PSY.HybridSystem, ::Type{InputActivePowerVariableLimitsConstraint}, ::Type{<:AbstractHybridFormulation}) = PSY.get_input_active_power_limits(d)
get_min_max_limits(d::PSY.HybridSystem, ::Type{OutputActivePowerVariableLimitsConstraint}, ::Type{<:AbstractHybridFormulation}) = PSY.get_output_active_power_limits(d)
get_min_max_limits(d::PSY.HybridSystem, ::Type{ReactivePowerVariableLimitsConstraint}, ::Type{<:AbstractHybridFormulation}) = PSY.get_reactive_power_limits(d)

#################################################################################
# Subcomponent power variables
#################################################################################

get_variable_binary(::Type{HybridThermalActivePower}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
get_variable_lower_bound(::Type{HybridThermalActivePower}, ::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = 0.0
get_variable_upper_bound(::Type{HybridThermalActivePower}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = PSY.get_active_power_limits(PSY.get_thermal_unit(d)).max

get_variable_binary(::Type{HybridRenewableActivePower}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
get_variable_lower_bound(::Type{HybridRenewableActivePower}, ::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = 0.0
get_variable_upper_bound(::Type{HybridRenewableActivePower}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = PSY.get_max_active_power(PSY.get_renewable_unit(d))

get_variable_binary(::Type{HybridStorageChargePower}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
get_variable_lower_bound(::Type{HybridStorageChargePower}, ::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = 0.0
get_variable_upper_bound(::Type{HybridStorageChargePower}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = PSY.get_input_active_power_limits(PSY.get_storage(d)).max

get_variable_binary(::Type{HybridStorageDischargePower}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
get_variable_lower_bound(::Type{HybridStorageDischargePower}, ::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = 0.0
get_variable_upper_bound(::Type{HybridStorageDischargePower}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = PSY.get_output_active_power_limits(PSY.get_storage(d)).max

get_variable_binary(::Type{HybridStorageReservation}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = true

# Storage energy state on the hybrid (uses POM's standard EnergyVariable, keyed by HybridSystem)
get_variable_binary(::Type{EnergyVariable}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
get_variable_lower_bound(::Type{EnergyVariable}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) =
    PSY.get_storage_level_limits(PSY.get_storage(d)).min *
    PSY.get_storage_capacity(PSY.get_storage(d)) *
    PSY.get_conversion_factor(PSY.get_storage(d))
get_variable_upper_bound(::Type{EnergyVariable}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) =
    PSY.get_storage_level_limits(PSY.get_storage(d)).max *
    PSY.get_storage_capacity(PSY.get_storage(d)) *
    PSY.get_conversion_factor(PSY.get_storage(d))
get_variable_warm_start_value(::Type{EnergyVariable}, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) =
    PSY.get_initial_storage_capacity_level(PSY.get_storage(d)) *
    PSY.get_storage_capacity(PSY.get_storage(d)) *
    PSY.get_conversion_factor(PSY.get_storage(d))

# Thermal commitment OnVariable on a hybrid (binary)
get_variable_binary(::Type{OnVariable}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = true
get_variable_lower_bound(::Type{OnVariable}, ::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = nothing
get_variable_upper_bound(::Type{OnVariable}, ::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = nothing

#################################################################################
# Reserve variables — bounds and binary flags
#################################################################################

get_variable_binary(::Type{<:HybridComponentReserveVariableType}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
get_variable_lower_bound(::Type{<:HybridComponentReserveVariableType}, ::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = 0.0

# Per-subcomponent reserve upper bounds: limited by the subcomponent's headroom × the service's max output fraction
function get_variable_upper_bound(::Type{HybridThermalReserveVariable}, r::PSY.Reserve, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation})
    return PSY.get_max_output_fraction(r) * PSY.get_active_power_limits(PSY.get_thermal_unit(d)).max
end
function get_variable_upper_bound(::Type{HybridRenewableReserveVariable}, r::PSY.Reserve, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation})
    return PSY.get_max_output_fraction(r) * PSY.get_max_active_power(PSY.get_renewable_unit(d))
end
function get_variable_upper_bound(::Type{HybridChargingReserveVariable}, r::PSY.Reserve, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation})
    return PSY.get_max_output_fraction(r) * PSY.get_input_active_power_limits(PSY.get_storage(d)).max
end
function get_variable_upper_bound(::Type{HybridDischargingReserveVariable}, r::PSY.Reserve, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation})
    return PSY.get_max_output_fraction(r) * PSY.get_output_active_power_limits(PSY.get_storage(d)).max
end

# Hybrid PCC reserve variables — limited by the hybrid's PCC limits × max_output_fraction
get_variable_binary(::Type{HybridReserveVariableOut}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
get_variable_lower_bound(::Type{HybridReserveVariableOut}, ::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = 0.0
function get_variable_upper_bound(::Type{HybridReserveVariableOut}, r::PSY.Reserve, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation})
    return PSY.get_max_output_fraction(r) * PSY.get_output_active_power_limits(d).max
end

get_variable_binary(::Type{HybridReserveVariableIn}, ::Type{PSY.HybridSystem}, ::Type{<:AbstractHybridFormulation}) = false
get_variable_lower_bound(::Type{HybridReserveVariableIn}, ::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation}) = 0.0
function get_variable_upper_bound(::Type{HybridReserveVariableIn}, r::PSY.Reserve, d::PSY.HybridSystem, ::Type{<:AbstractHybridFormulation})
    return PSY.get_max_output_fraction(r) * PSY.get_input_active_power_limits(d).max
end

# Multipliers used by reserve aggregations (Out side gets +1; In side handled via separate dispatch in add_to_expression)
get_variable_multiplier(::Type{<:HybridComponentReserveVariableType}, ::PSY.HybridSystem, ::AbstractHybridFormulationWithReserves, ::PSY.Reserve) = 1.0
get_variable_multiplier(::Type{HybridReserveVariableOut}, ::PSY.HybridSystem, ::AbstractHybridFormulationWithReserves, ::PSY.Reserve) = 1.0
get_variable_multiplier(::Type{HybridReserveVariableIn},  ::PSY.HybridSystem, ::AbstractHybridFormulationWithReserves, ::PSY.Reserve) = 1.0

# When the system-side ActivePowerReserveVariable is added by the service constructor for a HybridSystem,
# direct it into the TotalReserveOffering channel keyed by HybridSystem (mirrors POM storage line 59).
get_expression_type_for_reserve(::Type{ActivePowerReserveVariable}, ::Type{<:PSY.HybridSystem}, ::Type{<:PSY.Reserve}) = TotalReserveOffering

function get_variable_upper_bound(::Type{ActivePowerReserveVariable}, r::PSY.Reserve, d::PSY.HybridSystem, ::Type{<:AbstractReservesFormulation})
    return PSY.get_max_output_fraction(r) * (PSY.get_output_active_power_limits(d).max + PSY.get_input_active_power_limits(d).max)
end

# Disambiguate against the generic ReserveDemandCurve method in services_models/reserves.jl.
function get_variable_upper_bound(::Type{ActivePowerReserveVariable}, r::PSY.ReserveDemandCurve, d::PSY.HybridSystem, ::Type{<:AbstractReservesFormulation})
    return PSY.get_output_active_power_limits(d).max + PSY.get_input_active_power_limits(d).max
end

#################################################################################
# Time-series parameter multipliers
#################################################################################

get_multiplier_value(
    ::HybridRenewableActivePowerTimeSeriesParameter,
    d::PSY.HybridSystem,
    ::AbstractHybridFormulation,
) = PSY.get_max_active_power(PSY.get_renewable_unit(d))

get_multiplier_value(
    ::HybridElectricLoadTimeSeriesParameter,
    d::PSY.HybridSystem,
    ::AbstractHybridFormulation,
) = PSY.get_max_active_power(PSY.get_electric_load(d))

get_parameter_multiplier(::HybridRenewableActivePowerTimeSeriesParameter, ::PSY.HybridSystem, ::AbstractHybridFormulation) = 1.0
get_parameter_multiplier(::HybridElectricLoadTimeSeriesParameter,         ::PSY.HybridSystem, ::AbstractHybridFormulation) = 1.0

#################################################################################
# Initial conditions
#################################################################################

get_initial_conditions_device_model(
    ::OperationModel,
    model::DeviceModel{T, <:AbstractHybridFormulation},
) where {T <: PSY.HybridSystem} = model

initial_condition_default(
    ::InitialEnergyLevel,
    d::PSY.HybridSystem,
    ::AbstractHybridFormulation,
) =
    PSY.get_initial_storage_capacity_level(PSY.get_storage(d)) *
    PSY.get_storage_capacity(PSY.get_storage(d)) *
    PSY.get_conversion_factor(PSY.get_storage(d))

initial_condition_variable(
    ::InitialEnergyLevel,
    d::PSY.HybridSystem,
    ::AbstractHybridFormulation,
) = EnergyVariable()

function initial_conditions!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{T},
    formulation::AbstractHybridFormulation,
) where {T <: PSY.HybridSystem}
    storage_devices = [d for d in devices if PSY.get_storage(d) !== nothing]
    if !isempty(storage_devices)
        add_initial_condition!(container, storage_devices, formulation, InitialEnergyLevel())
    end
    return
end

#################################################################################
# Specialized add_variables! for the per-service reserve variables.
#
# These variables are indexed by (service_type, service_name) in addition to
# (component_name, time). Mirrors POM storage's pattern at
# energy_storage_models/storage_models.jl:409–445.
#################################################################################

function add_variables!(
    container::OptimizationContainer,
    ::Type{T},
    devices::U,
    ::Type{F},
) where {
    T <: Union{
        HybridReserveVariableOut, HybridReserveVariableIn,
        HybridThermalReserveVariable, HybridRenewableReserveVariable,
        HybridChargingReserveVariable, HybridDischargingReserveVariable,
    },
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    F <: AbstractHybridFormulation,
} where {D <: PSY.HybridSystem}
    @assert !isempty(devices)
    time_steps = get_time_steps(container)
    services = Set{PSY.Service}()
    for d in devices
        union!(services, PSY.get_services(d))
    end
    isempty(services) && return
    for service in services
        # Restrict to devices that participate in this service
        participating = [d for d in devices if service in PSY.get_services(d)]
        isempty(participating) && continue
        variable = add_variable_container!(container, T,
            D,
            PSY.get_name.(participating),
            time_steps;
            meta = "$(typeof(service))_$(PSY.get_name(service))",
        )
        for d in participating, t in time_steps
            name = PSY.get_name(d)
            variable[name, t] = JuMP.@variable(
                get_jump_model(container),
                base_name = "$(T)_$(PSY.get_name(service))_{$(name), $(t)}",
                lower_bound = 0.0,
                upper_bound = get_variable_upper_bound(T, service, d, F),
            )
        end
    end
    return
end

#################################################################################
# Objective-function multipliers (positive — we minimize cost)
#################################################################################

objective_function_multiplier(::Type{<:VariableType}, ::Type{<:AbstractHybridFormulation}) = OBJECTIVE_FUNCTION_POSITIVE

#! format: on
#################################################################################
# PCC active-power balance: ActivePowerInVariable / ActivePowerOutVariable into
# the network's ActivePowerBalance expression.
#
# These delegate to POM's existing common_models/add_to_expression.jl methods,
# which dispatch on (ExpressionType, VariableType, AbstractDeviceFormulation).
# Because AbstractHybridFormulation <: IOM.AbstractDeviceFormulation, the
# generic methods work for HybridSystem out of the box. The methods here are
# left documented but not redefined to avoid ambiguity.
#################################################################################

#################################################################################
# Hybrid total reserve aggregation:
#   HybridReserveVariableOut  → HybridTotalReserveOut{Up,Down}Expression
#   HybridReserveVariableIn   → HybridTotalReserveIn{Up,Down}Expression
#
# Each per-(hybrid, service) reserve variable is added (with multiplier) into the
# per-hybrid total reserve expression, with services filtered by ReserveUp/ReserveDown.
#################################################################################

# Up: skip ReserveDown services
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    T <: HybridTotalReserveUpExpression,
    U <: Union{HybridReserveVariableOut, HybridReserveVariableIn},
    V <: PSY.HybridSystem,
    W <: AbstractHybridFormulationWithReserves,
    X <: AbstractPowerModel,
}
    expression = get_expression(container, T, V)
    time_steps = get_time_steps(container)
    for d in devices
        name = PSY.get_name(d)
        for service in PSY.get_services(d)
            isa(service, PSY.Reserve{PSY.ReserveDown}) && continue
            variable = get_variable(container, U, V, "$(typeof(service))_$(PSY.get_name(service))")
            mult = get_variable_multiplier(U, d, W(), service)
            for t in time_steps
                add_proportional_to_jump_expression!(expression[name, t], variable[name, t], mult)
            end
        end
    end
    return
end

# Down: skip ReserveUp services
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    T <: HybridTotalReserveDownExpression,
    U <: Union{HybridReserveVariableOut, HybridReserveVariableIn},
    V <: PSY.HybridSystem,
    W <: AbstractHybridFormulationWithReserves,
    X <: AbstractPowerModel,
}
    expression = get_expression(container, T, V)
    time_steps = get_time_steps(container)
    for d in devices
        name = PSY.get_name(d)
        for service in PSY.get_services(d)
            isa(service, PSY.Reserve{PSY.ReserveUp}) && continue
            variable = get_variable(container, U, V, "$(typeof(service))_$(PSY.get_name(service))")
            mult = get_variable_multiplier(U, d, W(), service)
            for t in time_steps
                add_proportional_to_jump_expression!(expression[name, t], variable[name, t], mult)
            end
        end
    end
    return
end

#################################################################################
# Hybrid served reserve aggregation: same as Total* but multiplied by the
# service's deployed fraction, used downstream to discount the reserve in the
# energy-asset-balance accounting.
#################################################################################

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    T <: Union{HybridServedReserveOutUpExpression, HybridServedReserveInUpExpression},
    U <: Union{HybridReserveVariableOut, HybridReserveVariableIn},
    V <: PSY.HybridSystem,
    W <: AbstractHybridFormulationWithReserves,
    X <: AbstractPowerModel,
}
    expression = get_expression(container, T, V)
    time_steps = get_time_steps(container)
    for d in devices
        name = PSY.get_name(d)
        for service in PSY.get_services(d)
            isa(service, PSY.Reserve{PSY.ReserveDown}) && continue
            variable = get_variable(container, U, V, "$(typeof(service))_$(PSY.get_name(service))")
            fraction = PSY.get_deployed_fraction(service)
            mult = get_variable_multiplier(U, d, W(), service) * fraction
            for t in time_steps
                add_proportional_to_jump_expression!(expression[name, t], variable[name, t], mult)
            end
        end
    end
    return
end

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    T <: Union{HybridServedReserveOutDownExpression, HybridServedReserveInDownExpression},
    U <: Union{HybridReserveVariableOut, HybridReserveVariableIn},
    V <: PSY.HybridSystem,
    W <: AbstractHybridFormulationWithReserves,
    X <: AbstractPowerModel,
}
    expression = get_expression(container, T, V)
    time_steps = get_time_steps(container)
    for d in devices
        name = PSY.get_name(d)
        for service in PSY.get_services(d)
            isa(service, PSY.Reserve{PSY.ReserveUp}) && continue
            variable = get_variable(container, U, V, "$(typeof(service))_$(PSY.get_name(service))")
            fraction = PSY.get_deployed_fraction(service)
            mult = get_variable_multiplier(U, d, W(), service) * fraction
            for t in time_steps
                add_proportional_to_jump_expression!(expression[name, t], variable[name, t], mult)
            end
        end
    end
    return
end

#################################################################################
# Storage subcomponent reserve accumulation, keyed by PSY.HybridSystem.
# Mirrors the storage path in src/energy_storage_models/storage_constructor.jl
# lines 29–50, but the destination expressions are allocated keyed by
# HybridSystem rather than by PSY.Storage, and the source variables are the
# Hybrid{Charging,Discharging}ReserveVariable.
#################################################################################

# Discharge-side variable into Discharge expressions
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{HybridDischargingReserveVariable},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
) where {
    T <: Union{
        ReserveAssignmentBalanceUpDischarge,
        ReserveAssignmentBalanceDownDischarge,
        ReserveDeploymentBalanceUpDischarge,
        ReserveDeploymentBalanceDownDischarge,
    },
    V <: PSY.HybridSystem,
    W <: AbstractHybridFormulationWithReserves,
}
    expression = get_expression(container, T, V)
    time_steps = get_time_steps(container)
    is_up = T <: Union{ReserveAssignmentBalanceUpDischarge, ReserveDeploymentBalanceUpDischarge}
    is_deployment = T <: Union{ReserveDeploymentBalanceUpDischarge, ReserveDeploymentBalanceDownDischarge}
    for d in devices
        name = PSY.get_name(d)
        for service in PSY.get_services(d)
            if is_up && isa(service, PSY.Reserve{PSY.ReserveDown})
                continue
            elseif !is_up && isa(service, PSY.Reserve{PSY.ReserveUp})
                continue
            end
            variable = get_variable(container, HybridDischargingReserveVariable, V, "$(typeof(service))_$(PSY.get_name(service))")
            mult = get_variable_multiplier(HybridDischargingReserveVariable, d, W(), service)
            if is_deployment
                mult *= PSY.get_deployed_fraction(service)
            end
            for t in time_steps
                add_proportional_to_jump_expression!(expression[name, t], variable[name, t], mult)
            end
        end
    end
    return
end

# Charge-side variable into Charge expressions
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{HybridChargingReserveVariable},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
) where {
    T <: Union{
        ReserveAssignmentBalanceUpCharge,
        ReserveAssignmentBalanceDownCharge,
        ReserveDeploymentBalanceUpCharge,
        ReserveDeploymentBalanceDownCharge,
    },
    V <: PSY.HybridSystem,
    W <: AbstractHybridFormulationWithReserves,
}
    expression = get_expression(container, T, V)
    time_steps = get_time_steps(container)
    is_up = T <: Union{ReserveAssignmentBalanceUpCharge, ReserveDeploymentBalanceUpCharge}
    is_deployment = T <: Union{ReserveDeploymentBalanceUpCharge, ReserveDeploymentBalanceDownCharge}
    for d in devices
        name = PSY.get_name(d)
        for service in PSY.get_services(d)
            if is_up && isa(service, PSY.Reserve{PSY.ReserveDown})
                continue
            elseif !is_up && isa(service, PSY.Reserve{PSY.ReserveUp})
                continue
            end
            variable = get_variable(container, HybridChargingReserveVariable, V, "$(typeof(service))_$(PSY.get_name(service))")
            mult = get_variable_multiplier(HybridChargingReserveVariable, d, W(), service)
            if is_deployment
                mult *= PSY.get_deployed_fraction(service)
            end
            for t in time_steps
                add_proportional_to_jump_expression!(expression[name, t], variable[name, t], mult)
            end
        end
    end
    return
end

# Hybrid storage subcomponent feeds TotalReserveOffering keyed by HybridSystem.
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{TotalReserveOffering},
    ::Type{U},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
) where {
    U <: Union{HybridChargingReserveVariable, HybridDischargingReserveVariable},
    V <: PSY.HybridSystem,
    W <: AbstractHybridFormulationWithReserves,
}
    time_steps = get_time_steps(container)
    for d in devices
        name = PSY.get_name(d)
        for service in PSY.get_services(d)
            expression = get_expression(container, TotalReserveOffering, V,
                "$(typeof(service))_$(PSY.get_name(service))")
            variable = get_variable(container, U, V, "$(typeof(service))_$(PSY.get_name(service))")
            mult = get_variable_multiplier(U, d, W(), service)
            for t in time_steps
                add_proportional_to_jump_expression!(expression[name, t], variable[name, t], mult)
            end
        end
    end
    return
end

# Service-side: ActivePowerReserveVariable subtracted from per-hybrid TotalReserveOffering
# (mirrors storage_models.jl:781–808 pattern).
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::Vector{UV},
    service_model::ServiceModel{V, W},
) where {
    T <: TotalReserveOffering,
    U <: ActivePowerReserveVariable,
    UV <: PSY.HybridSystem,
    V <: PSY.Reserve,
    W <: AbstractReservesFormulation,
}
    for d in devices
        name = PSY.get_name(d)
        s_name = get_service_name(service_model)
        expression = get_expression(container, T, UV, "$(V)_$(s_name)")
        variable = get_variable(container, U, V, s_name)
        for t in get_time_steps(container)
            add_proportional_to_jump_expression!(expression[name, t], variable[name, t], -1.0)
        end
    end
    return
end
#################################################################################
# Thermal subcomponent constraints for HybridSystem.
#
# Mirrors HSS add_constraints.jl _add_thermallimit_withreserves! (lines 1477–1506)
# for the with-reserves case, and _add_thermal_on_variable_constraints! for the
# no-reserves case. Walks PSY.get_thermal_unit(d) for the thermal unit's limits.
#################################################################################

function _thermal_reserve_up_expr(container, d, t, services)
    expr = JuMP.AffExpr(0.0)
    for service in services
        isa(service, PSY.Reserve{PSY.ReserveDown}) && continue
        s_name = PSY.get_name(service)
        s_type = typeof(service)
        key = VariableKey(HybridThermalReserveVariable, typeof(d), "$(s_type)_$s_name")
        haskey(IOM.get_variables(container), key) || continue
        var = get_variable(container, HybridThermalReserveVariable, typeof(d), "$(s_type)_$s_name")
        JuMP.add_to_expression!(expr, var[PSY.get_name(d), t], 1.0)
    end
    return expr
end

function _thermal_reserve_down_expr(container, d, t, services)
    expr = JuMP.AffExpr(0.0)
    for service in services
        isa(service, PSY.Reserve{PSY.ReserveUp}) && continue
        s_name = PSY.get_name(service)
        s_type = typeof(service)
        key = VariableKey(HybridThermalReserveVariable, typeof(d), "$(s_type)_$s_name")
        haskey(IOM.get_variables(container), key) || continue
        var = get_variable(container, HybridThermalReserveVariable, typeof(d), "$(s_type)_$s_name")
        JuMP.add_to_expression!(expr, var[PSY.get_name(d), t], 1.0)
    end
    return expr
end

"""
Range constraint on the thermal subcomponent's active power, accounting for
up/down reserve allocations. Mirrors HSS `ThermalReserveLimit` (HSS
add_constraints.jl:1495–1506).
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridThermalReserveLimitConstraint},
    devices::U,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    U <: Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    W <: AbstractHybridFormulationWithReserves,
    X <: AbstractPowerModel,
} where {V <: PSY.HybridSystem}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_th = get_variable(container, HybridThermalActivePower, V)
    on_var = get_variable(container, OnVariable, V)

    con_ub = add_constraints_container!(container, HybridThermalReserveLimitConstraint, V, names, time_steps; meta = "ub")
    con_lb = add_constraints_container!(container, HybridThermalReserveLimitConstraint, V, names, time_steps; meta = "lb")

    for d in devices, t in time_steps
        name = PSY.get_name(d)
        thermal_unit = PSY.get_thermal_unit(d)
        thermal_unit === nothing && continue
        limits = PSY.get_active_power_limits(thermal_unit)
        services = PSY.get_services(d)
        r_up = _thermal_reserve_up_expr(container, d, t, services)
        r_dn = _thermal_reserve_down_expr(container, d, t, services)
        con_ub[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_th[name, t] + r_up <= limits.max * on_var[name, t]
        )
        con_lb[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_th[name, t] - r_dn >= limits.min * on_var[name, t]
        )
    end
    return
end

"""
Upper-bound link between thermal subcomponent power and its commitment status
(no-reserves case).
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridThermalOnVariableUbConstraint},
    devices::U,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    U <: Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    W <: AbstractHybridFormulation,
    X <: AbstractPowerModel,
} where {V <: PSY.HybridSystem}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_th = get_variable(container, HybridThermalActivePower, V)
    on_var = get_variable(container, OnVariable, V)
    constraint = add_constraints_container!(container, HybridThermalOnVariableUbConstraint, V, names, time_steps)
    for d in devices, t in time_steps
        name = PSY.get_name(d)
        thermal_unit = PSY.get_thermal_unit(d)
        thermal_unit === nothing && continue
        max_p = PSY.get_active_power_limits(thermal_unit).max
        constraint[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_th[name, t] <= max_p * on_var[name, t]
        )
    end
    return
end

"""
Lower-bound link between thermal subcomponent power and its commitment status
(no-reserves case).
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridThermalOnVariableLbConstraint},
    devices::U,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    U <: Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    W <: AbstractHybridFormulation,
    X <: AbstractPowerModel,
} where {V <: PSY.HybridSystem}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_th = get_variable(container, HybridThermalActivePower, V)
    on_var = get_variable(container, OnVariable, V)
    constraint = add_constraints_container!(container, HybridThermalOnVariableLbConstraint, V, names, time_steps)
    for d in devices, t in time_steps
        name = PSY.get_name(d)
        thermal_unit = PSY.get_thermal_unit(d)
        thermal_unit === nothing && continue
        min_p = PSY.get_active_power_limits(thermal_unit).min
        constraint[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_th[name, t] >= min_p * on_var[name, t]
        )
    end
    return
end
#################################################################################
# Renewable subcomponent constraints for HybridSystem.
#
# - HybridRenewableActivePowerLimitConstraint: cap renewable subcomponent power
#   at the time-series-derived available output (no-reserves and reserves cases
#   share this; the reserve-aware variant carves out reserves in the with-reserves
#   constraint).
# - HybridRenewableReserveLimitConstraint: range constraint on renewable power
#   accounting for up/down reserves.
#################################################################################

function _renewable_reserve_up_expr(container, d, t, services)
    expr = JuMP.AffExpr(0.0)
    for service in services
        isa(service, PSY.Reserve{PSY.ReserveDown}) && continue
        s_name = PSY.get_name(service)
        s_type = typeof(service)
        key = VariableKey(HybridRenewableReserveVariable, typeof(d), "$(s_type)_$s_name")
        haskey(IOM.get_variables(container), key) || continue
        var = get_variable(container, HybridRenewableReserveVariable, typeof(d), "$(s_type)_$s_name")
        JuMP.add_to_expression!(expr, var[PSY.get_name(d), t], 1.0)
    end
    return expr
end

function _renewable_reserve_down_expr(container, d, t, services)
    expr = JuMP.AffExpr(0.0)
    for service in services
        isa(service, PSY.Reserve{PSY.ReserveUp}) && continue
        s_name = PSY.get_name(service)
        s_type = typeof(service)
        key = VariableKey(HybridRenewableReserveVariable, typeof(d), "$(s_type)_$s_name")
        haskey(IOM.get_variables(container), key) || continue
        var = get_variable(container, HybridRenewableReserveVariable, typeof(d), "$(s_type)_$s_name")
        JuMP.add_to_expression!(expr, var[PSY.get_name(d), t], 1.0)
    end
    return expr
end

"""
Cap renewable subcomponent power at the time-series-derived available output
(0 ≤ p_renewable[t] ≤ multiplier · ts[t]).
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridRenewableActivePowerLimitConstraint},
    devices::U,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    U <: Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    W <: AbstractHybridFormulation,
    X <: AbstractPowerModel,
} where {V <: PSY.HybridSystem}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_re = get_variable(container, HybridRenewableActivePower, V)

    re_param_key = ParameterKey(HybridRenewableActivePowerTimeSeriesParameter, V)
    re_param_container = haskey(IOM.get_parameters(container), re_param_key) ?
        get_parameter(container, HybridRenewableActivePowerTimeSeriesParameter, V) : nothing
    re_multiplier = re_param_container === nothing ? nothing :
        get_multiplier_array(re_param_container)

    constraint = add_constraints_container!(container, HybridRenewableActivePowerLimitConstraint, V, names, time_steps)

    for d in devices, t in time_steps
        name = PSY.get_name(d)
        renewable_unit = PSY.get_renewable_unit(d)
        renewable_unit === nothing && continue
        if re_param_container !== nothing
            re_ref = get_parameter_column_refs(re_param_container, name)[t]
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                p_re[name, t] <= re_multiplier[name, t] * re_ref
            )
        else
            max_p = PSY.get_max_active_power(renewable_unit)
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                p_re[name, t] <= max_p
            )
        end
    end
    return
end

"""
Range constraint on renewable subcomponent power accounting for reserves.
Mirrors HSS `RenewableReserveLimit`.
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridRenewableReserveLimitConstraint},
    devices::U,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    U <: Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    W <: AbstractHybridFormulationWithReserves,
    X <: AbstractPowerModel,
} where {V <: PSY.HybridSystem}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_re = get_variable(container, HybridRenewableActivePower, V)

    re_param_key = ParameterKey(HybridRenewableActivePowerTimeSeriesParameter, V)
    re_param_container = haskey(IOM.get_parameters(container), re_param_key) ?
        get_parameter(container, HybridRenewableActivePowerTimeSeriesParameter, V) : nothing
    re_multiplier = re_param_container === nothing ? nothing :
        get_multiplier_array(re_param_container)

    con_ub = add_constraints_container!(container, HybridRenewableReserveLimitConstraint, V, names, time_steps; meta = "ub")
    con_lb = add_constraints_container!(container, HybridRenewableReserveLimitConstraint, V, names, time_steps; meta = "lb")

    for d in devices, t in time_steps
        name = PSY.get_name(d)
        renewable_unit = PSY.get_renewable_unit(d)
        renewable_unit === nothing && continue
        services = PSY.get_services(d)
        r_up = _renewable_reserve_up_expr(container, d, t, services)
        r_dn = _renewable_reserve_down_expr(container, d, t, services)
        if re_param_container !== nothing
            re_ref = get_parameter_column_refs(re_param_container, name)[t]
            con_ub[name, t] = JuMP.@constraint(
                get_jump_model(container),
                p_re[name, t] + r_up <= re_multiplier[name, t] * re_ref
            )
        else
            max_p = PSY.get_max_active_power(renewable_unit)
            con_ub[name, t] = JuMP.@constraint(
                get_jump_model(container),
                p_re[name, t] + r_up <= max_p
            )
        end
        con_lb[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_re[name, t] - r_dn >= 0.0
        )
    end
    return
end
#################################################################################
# Storage subcomponent constraints for HybridSystem (Option D core).
#
# Most methods re-emit POM's storage reserve constraint TYPES with new dispatches
# on V <: PSY.HybridSystem, substituting PSY.get_storage(hybrid) for hybrid at
# every PSY accessor. The constraint TYPES are reused (same names, same purpose,
# same shape); only the dispatch context changes. Hybrid-specific constraint
# types are introduced for the inner-storage status (charge/discharge mode) and
# the charge/discharge reserve power limits, since their math is subtly different
# from POM's storage versions.
#################################################################################

#! format: off

# Helper accessors
_storage_of(d::PSY.HybridSystem) = PSY.get_storage(d)

#################################################################################
# HybridStorageBalanceConstraint — energy balance with optional reserve deployment
#################################################################################

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridStorageBalanceConstraint},
    devices::U,
    model::DeviceModel{V, W},
    network_model::NetworkModel{X},
) where {
    U <: Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    W <: AbstractHybridFormulation,
    X <: AbstractPowerModel,
} where {V <: PSY.HybridSystem}
    if W <: AbstractHybridFormulationWithReserves && has_service_model(model)
        _hybrid_storage_balance_with_reserves!(container, devices, model, network_model)
    else
        _hybrid_storage_balance_no_reserves!(container, devices, model, network_model)
    end
    return
end

function _hybrid_storage_balance_no_reserves!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.HybridSystem, W <: AbstractHybridFormulation, X <: AbstractPowerModel}
    time_steps = get_time_steps(container)
    resolution = get_resolution(container)
    fraction_of_hour = Dates.value(Dates.Minute(resolution)) / MINUTES_IN_HOUR
    names = [PSY.get_name(d) for d in devices]
    initial_conditions = get_initial_condition(container, InitialEnergyLevel(), V)
    energy_var = get_variable(container, EnergyVariable, V)
    p_ch = get_variable(container, HybridStorageChargePower, V)
    p_ds = get_variable(container, HybridStorageDischargePower, V)
    constraint = add_constraints_container!(container, HybridStorageBalanceConstraint, V, names, time_steps)

    for ic in initial_conditions
        d = IOM.get_component(ic)
        storage = _storage_of(d)
        storage === nothing && continue
        eff = PSY.get_efficiency(storage)
        name = PSY.get_name(d)
        constraint[name, 1] = JuMP.@constraint(
            get_jump_model(container),
            energy_var[name, 1] == get_value(ic) +
            (p_ch[name, 1] * eff.in - p_ds[name, 1] / eff.out) * fraction_of_hour
        )
        for t in time_steps[2:end]
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                energy_var[name, t] == energy_var[name, t-1] +
                (p_ch[name, t] * eff.in - p_ds[name, t] / eff.out) * fraction_of_hour
            )
        end
    end
    return
end

function _hybrid_storage_balance_with_reserves!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.HybridSystem, W <: AbstractHybridFormulationWithReserves, X <: AbstractPowerModel}
    time_steps = get_time_steps(container)
    resolution = get_resolution(container)
    fraction_of_hour = Dates.value(Dates.Minute(resolution)) / MINUTES_IN_HOUR
    names = [PSY.get_name(d) for d in devices]
    initial_conditions = get_initial_condition(container, InitialEnergyLevel(), V)
    energy_var = get_variable(container, EnergyVariable, V)
    p_ch = get_variable(container, HybridStorageChargePower, V)
    p_ds = get_variable(container, HybridStorageDischargePower, V)
    r_up_ds = get_expression(container, ReserveDeploymentBalanceUpDischarge, V)
    r_up_ch = get_expression(container, ReserveDeploymentBalanceUpCharge, V)
    r_dn_ds = get_expression(container, ReserveDeploymentBalanceDownDischarge, V)
    r_dn_ch = get_expression(container, ReserveDeploymentBalanceDownCharge, V)
    constraint = add_constraints_container!(container, HybridStorageBalanceConstraint, V, names, time_steps)

    for ic in initial_conditions
        d = IOM.get_component(ic)
        storage = _storage_of(d)
        storage === nothing && continue
        eff = PSY.get_efficiency(storage)
        name = PSY.get_name(d)
        constraint[name, 1] = JuMP.@constraint(
            get_jump_model(container),
            energy_var[name, 1] == get_value(ic) +
            (((p_ch[name, 1] + r_dn_ch[name, 1] - r_up_ch[name, 1]) * eff.in) -
             ((p_ds[name, 1] + r_up_ds[name, 1] - r_dn_ds[name, 1]) / eff.out)) * fraction_of_hour
        )
        for t in time_steps[2:end]
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                energy_var[name, t] == energy_var[name, t-1] +
                (((p_ch[name, t] + r_dn_ch[name, t] - r_up_ch[name, t]) * eff.in) -
                 ((p_ds[name, t] + r_up_ds[name, t] - r_dn_ds[name, t]) / eff.out)) * fraction_of_hour
            )
        end
    end
    return
end

#################################################################################
# HybridStorageStatusChargeOnConstraint / HybridStorageStatusDischargeOnConstraint
# (no-reserves case — mutually exclusive charge/discharge via the inner storage
# reservation variable)
#################################################################################

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridStorageStatusChargeOnConstraint},
    devices::U,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    U <: Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    W <: AbstractHybridFormulation,
    X <: AbstractPowerModel,
} where {V <: PSY.HybridSystem}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_ch = get_variable(container, HybridStorageChargePower, V)
    ss = get_variable(container, HybridStorageReservation, V)
    constraint = add_constraints_container!(container, HybridStorageStatusChargeOnConstraint, V, names, time_steps)
    for d in devices, t in time_steps
        storage = _storage_of(d)
        storage === nothing && continue
        name = PSY.get_name(d)
        max_ch = PSY.get_input_active_power_limits(storage).max
        constraint[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_ch[name, t] <= max_ch * (1 - ss[name, t])
        )
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridStorageStatusDischargeOnConstraint},
    devices::U,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    U <: Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    W <: AbstractHybridFormulation,
    X <: AbstractPowerModel,
} where {V <: PSY.HybridSystem}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_ds = get_variable(container, HybridStorageDischargePower, V)
    ss = get_variable(container, HybridStorageReservation, V)
    constraint = add_constraints_container!(container, HybridStorageStatusDischargeOnConstraint, V, names, time_steps)
    for d in devices, t in time_steps
        storage = _storage_of(d)
        storage === nothing && continue
        name = PSY.get_name(d)
        max_ds = PSY.get_output_active_power_limits(storage).max
        constraint[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_ds[name, t] <= max_ds * ss[name, t]
        )
    end
    return
end

#################################################################################
# HybridStorageChargingReservePowerLimitConstraint
# HybridStorageDischargingReservePowerLimitConstraint
# (with-reserves case — charge/discharge headroom under reservation +
# reserve-aware bounds, mirroring HSS's ChargingReservePowerLimit/
# DischargingReservePowerLimit)
#################################################################################

function _ch_reserve_up_dn_exprs(container, V, t, name)
    r_up = get_expression(container, ReserveAssignmentBalanceUpCharge, V)
    r_dn = get_expression(container, ReserveAssignmentBalanceDownCharge, V)
    return r_up[name, t], r_dn[name, t]
end

function _ds_reserve_up_dn_exprs(container, V, t, name)
    r_up = get_expression(container, ReserveAssignmentBalanceUpDischarge, V)
    r_dn = get_expression(container, ReserveAssignmentBalanceDownDischarge, V)
    return r_up[name, t], r_dn[name, t]
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridStorageChargingReservePowerLimitConstraint},
    devices::U,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    U <: Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    W <: AbstractHybridFormulationWithReserves,
    X <: AbstractPowerModel,
} where {V <: PSY.HybridSystem}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_ch = get_variable(container, HybridStorageChargePower, V)
    ss = get_variable(container, HybridStorageReservation, V)
    con_ub = add_constraints_container!(container, HybridStorageChargingReservePowerLimitConstraint, V, names, time_steps; meta = "ub")
    con_lb = add_constraints_container!(container, HybridStorageChargingReservePowerLimitConstraint, V, names, time_steps; meta = "lb")
    for d in devices, t in time_steps
        storage = _storage_of(d)
        storage === nothing && continue
        name = PSY.get_name(d)
        max_ch = PSY.get_input_active_power_limits(storage).max
        r_up, r_dn = _ch_reserve_up_dn_exprs(container, V, t, name)
        # charge + down reserve ≤ max·(1 - ss); charge - up reserve ≥ 0
        con_ub[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_ch[name, t] + r_dn <= max_ch * (1 - ss[name, t])
        )
        con_lb[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_ch[name, t] - r_up >= 0.0
        )
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridStorageDischargingReservePowerLimitConstraint},
    devices::U,
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    U <: Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    W <: AbstractHybridFormulationWithReserves,
    X <: AbstractPowerModel,
} where {V <: PSY.HybridSystem}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_ds = get_variable(container, HybridStorageDischargePower, V)
    ss = get_variable(container, HybridStorageReservation, V)
    con_ub = add_constraints_container!(container, HybridStorageDischargingReservePowerLimitConstraint, V, names, time_steps; meta = "ub")
    con_lb = add_constraints_container!(container, HybridStorageDischargingReservePowerLimitConstraint, V, names, time_steps; meta = "lb")
    for d in devices, t in time_steps
        storage = _storage_of(d)
        storage === nothing && continue
        name = PSY.get_name(d)
        max_ds = PSY.get_output_active_power_limits(storage).max
        r_up, r_dn = _ds_reserve_up_dn_exprs(container, V, t, name)
        con_ub[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_ds[name, t] + r_up <= max_ds * ss[name, t]
        )
        con_lb[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_ds[name, t] - r_dn >= 0.0
        )
    end
    return
end

#################################################################################
# Reuse POM's ReserveCoverageConstraint{,EndOfPeriod} types with V <: HybridSystem
# dispatches. Bodies mirror storage_models.jl:1038–1108, substituting
# PSY.get_storage(d) for d at every PSY accessor.
#################################################################################

function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, HybridDispatchWithReserves},
    network_model::NetworkModel{X},
) where {
    T <: Union{ReserveCoverageConstraint, ReserveCoverageConstraintEndOfPeriod},
    V <: PSY.HybridSystem,
    X <: AbstractPowerModel,
}
    time_steps = get_time_steps(container)
    resolution = get_resolution(container)
    fraction_of_hour = Dates.value(Dates.Minute(resolution)) / MINUTES_IN_HOUR
    names = [PSY.get_name(d) for d in devices]
    initial_conditions = get_initial_condition(container, InitialEnergyLevel(), V)
    energy_var = get_variable(container, EnergyVariable, V)

    services_set = Set{PSY.Service}()
    for ic in initial_conditions
        d = IOM.get_component(ic)
        union!(services_set, PSY.get_services(d))
    end

    for service in services_set
        s_name = PSY.get_name(service)
        s_type = typeof(service)
        if service isa PSY.Reserve{PSY.ReserveUp}
            add_constraints_container!(container, T, V, names, time_steps; meta = "$(s_type)_$(s_name)_discharge")
        elseif service isa PSY.Reserve{PSY.ReserveDown}
            add_constraints_container!(container, T, V, names, time_steps; meta = "$(s_type)_$(s_name)_charge")
        end
    end

    for ic in initial_conditions
        d = IOM.get_component(ic)
        storage = _storage_of(d)
        storage === nothing && continue
        ci_name = PSY.get_name(d)
        eff_in = PSY.get_efficiency(storage).in
        inv_eff_out = 1.0 / PSY.get_efficiency(storage).out
        for service in PSY.get_services(d)
            (service isa PSY.Reserve) || continue
            sustained_time = PSY.get_sustained_time(service)
            num_periods = sustained_time / Dates.value(Dates.Second(resolution))
            sustained_param_discharge = inv_eff_out * fraction_of_hour * num_periods
            sustained_param_charge = eff_in * fraction_of_hour * num_periods
            s_name = PSY.get_name(service)
            s_type = typeof(service)
            if service isa PSY.Reserve{PSY.ReserveUp}
                reserve_var = get_variable(container, HybridDischargingReserveVariable, V, "$(s_type)_$s_name")
                con = get_constraint(container, T, V, "$(s_type)_$(s_name)_discharge")
                if time_offset(T) == -1
                    con[ci_name, 1] = JuMP.@constraint(
                        get_jump_model(container),
                        sustained_param_discharge * reserve_var[ci_name, 1] <= get_value(ic)
                    )
                    for t in time_steps[2:end]
                        con[ci_name, t] = JuMP.@constraint(
                            get_jump_model(container),
                            sustained_param_discharge * reserve_var[ci_name, t] <= energy_var[ci_name, t-1]
                        )
                    end
                else  # EndOfPeriod
                    for t in time_steps
                        con[ci_name, t] = JuMP.@constraint(
                            get_jump_model(container),
                            sustained_param_discharge * reserve_var[ci_name, t] <= energy_var[ci_name, t]
                        )
                    end
                end
            elseif service isa PSY.Reserve{PSY.ReserveDown}
                reserve_var = get_variable(container, HybridChargingReserveVariable, V, "$(s_type)_$s_name")
                con = get_constraint(container, T, V, "$(s_type)_$(s_name)_charge")
                soc_max = PSY.get_storage_level_limits(storage).max *
                          PSY.get_storage_capacity(storage) *
                          PSY.get_conversion_factor(storage)
                if time_offset(T) == -1
                    con[ci_name, 1] = JuMP.@constraint(
                        get_jump_model(container),
                        sustained_param_charge * reserve_var[ci_name, 1] <= soc_max - get_value(ic)
                    )
                    for t in time_steps[2:end]
                        con[ci_name, t] = JuMP.@constraint(
                            get_jump_model(container),
                            sustained_param_charge * reserve_var[ci_name, t] <= soc_max - energy_var[ci_name, t-1]
                        )
                    end
                else
                    for t in time_steps
                        con[ci_name, t] = JuMP.@constraint(
                            get_jump_model(container),
                            sustained_param_charge * reserve_var[ci_name, t] <= soc_max - energy_var[ci_name, t]
                        )
                    end
                end
            end
        end
    end
    return
end

#################################################################################
# StateofChargeTargetConstraint reused on hybrids with energy_target=true.
#################################################################################

function add_constraints!(
    container::OptimizationContainer,
    ::Type{StateofChargeTargetConstraint},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, HybridDispatchWithReserves},
    ::NetworkModel{X},
) where {V <: PSY.HybridSystem, X <: AbstractPowerModel}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    energy_var = get_variable(container, EnergyVariable, V)
    constraint = add_constraints_container!(container, StateofChargeTargetConstraint, V, names, [last(time_steps)])
    for d in devices
        storage = _storage_of(d)
        storage === nothing && continue
        name = PSY.get_name(d)
        target = PSY.get_storage_target(storage) *
                 PSY.get_storage_capacity(storage) *
                 PSY.get_conversion_factor(storage)
        t_end = last(time_steps)
        constraint[name, t_end] = JuMP.@constraint(
            get_jump_model(container),
            energy_var[name, t_end] >= target
        )
    end
    return
end

#! format: on
#################################################################################
# Hybrid PCC ↔ subcomponent balance and reserve plumbing.
#
# These constraints are genuinely new — they have no analogue in POM's storage,
# thermal, or renewable code. They tie:
#   - PCC active-power variables (ActivePowerOutVariable / ActivePowerInVariable)
#     to the reservation variable (mutually exclusive charge/discharge at the
#     hybrid boundary)
#   - Internal subcomponent flows (thermal + renewable + storage discharge -
#     storage charge - load) to the PCC injection
#   - Per-subcomponent reserve allocations to the hybrid-boundary reserve
#     variables, and the hybrid-boundary reserve variables to the system-level
#     ActivePowerReserveVariable
#################################################################################

"""
Force the hybrid PCC `ActivePowerOutVariable` to vanish whenever the reservation
variable signals charge mode (reservation = 0 → out = 0; reservation = 1 → out
free up to its upper bound).
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridStatusOutOnConstraint},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.HybridSystem, W <: AbstractHybridFormulation, X <: AbstractPowerModel}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_out = get_variable(container, ActivePowerOutVariable, V)
    reservation = get_variable(container, ReservationVariable, V)
    constraint = add_constraints_container!(container, HybridStatusOutOnConstraint, V, names, time_steps)

    has_reserves = W <: AbstractHybridFormulationWithReserves && has_service_model(model)
    r_up = has_reserves ? get_expression(container, HybridTotalReserveOutUpExpression, V) : nothing

    for d in devices, t in time_steps
        name = PSY.get_name(d)
        max_out = PSY.get_output_active_power_limits(d).max
        if has_reserves
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                p_out[name, t] + r_up[name, t] <= reservation[name, t] * max_out
            )
        else
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                p_out[name, t] <= reservation[name, t] * max_out
            )
        end
    end
    return
end

"""
Force the hybrid PCC `ActivePowerInVariable` to vanish whenever the reservation
variable signals discharge mode (reservation = 1 → in = 0; reservation = 0 →
in free up to its upper bound).
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridStatusInOnConstraint},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.HybridSystem, W <: AbstractHybridFormulation, X <: AbstractPowerModel}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_in = get_variable(container, ActivePowerInVariable, V)
    reservation = get_variable(container, ReservationVariable, V)
    constraint = add_constraints_container!(container, HybridStatusInOnConstraint, V, names, time_steps)

    has_reserves = W <: AbstractHybridFormulationWithReserves && has_service_model(model)
    r_dn = has_reserves ? get_expression(container, HybridTotalReserveInDownExpression, V) : nothing

    for d in devices, t in time_steps
        name = PSY.get_name(d)
        max_in = PSY.get_input_active_power_limits(d).max
        if has_reserves
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                p_in[name, t] + r_dn[name, t] <= (1 - reservation[name, t]) * max_in
            )
        else
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                p_in[name, t] <= (1 - reservation[name, t]) * max_in
            )
        end
    end
    return
end

"""
Energy asset balance: the hybrid's PCC injection equals the sum of subcomponent
injections (thermal + renewable + storage discharge - storage charge - load).
Reserves contribute through their *served* (deployed-fraction) expressions.
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridEnergyAssetBalanceConstraint},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.HybridSystem, W <: AbstractHybridFormulation, X <: AbstractPowerModel}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    p_out = get_variable(container, ActivePowerOutVariable, V)
    p_in = get_variable(container, ActivePowerInVariable, V)
    constraint = add_constraints_container!(container, HybridEnergyAssetBalanceConstraint, V, names, time_steps)

    # Optional subcomponent variables — only present when the hybrid has them
    p_th = haskey(IOM.get_variables(container), VariableKey(HybridThermalActivePower, V)) ?
        get_variable(container, HybridThermalActivePower, V) : nothing
    p_re = haskey(IOM.get_variables(container), VariableKey(HybridRenewableActivePower, V)) ?
        get_variable(container, HybridRenewableActivePower, V) : nothing
    p_ch = haskey(IOM.get_variables(container), VariableKey(HybridStorageChargePower, V)) ?
        get_variable(container, HybridStorageChargePower, V) : nothing
    p_ds = haskey(IOM.get_variables(container), VariableKey(HybridStorageDischargePower, V)) ?
        get_variable(container, HybridStorageDischargePower, V) : nothing

    load_param_container = haskey(
        IOM.get_parameters(container),
        ParameterKey(HybridElectricLoadTimeSeriesParameter, V),
    ) ? get_parameter(container, HybridElectricLoadTimeSeriesParameter, V) : nothing
    load_multiplier = load_param_container === nothing ? nothing :
        get_multiplier_array(load_param_container)

    for d in devices, t in time_steps
        name = PSY.get_name(d)
        rhs = JuMP.AffExpr(0.0)
        if p_th !== nothing && PSY.get_thermal_unit(d) !== nothing
            JuMP.add_to_expression!(rhs, p_th[name, t], 1.0)
        end
        if p_re !== nothing && PSY.get_renewable_unit(d) !== nothing
            JuMP.add_to_expression!(rhs, p_re[name, t], 1.0)
        end
        if p_ds !== nothing && PSY.get_storage(d) !== nothing
            JuMP.add_to_expression!(rhs, p_ds[name, t], 1.0)
        end
        if p_ch !== nothing && PSY.get_storage(d) !== nothing
            JuMP.add_to_expression!(rhs, p_ch[name, t], -1.0)
        end
        if load_param_container !== nothing && PSY.get_electric_load(d) !== nothing
            load_ref = get_parameter_column_refs(load_param_container, name)[t]
            JuMP.add_to_expression!(rhs, -load_multiplier[name, t], load_ref)
        end
        constraint[name, t] = JuMP.@constraint(
            get_jump_model(container),
            p_out[name, t] - p_in[name, t] == rhs
        )
    end
    return
end

"""
Couple the hybrid PCC reserve variables (Out + In, summed across subcomponents)
to the system-level `ActivePowerReserveVariable` for each service the hybrid
participates in.
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridReserveAssignmentConstraint},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.HybridSystem, W <: AbstractHybridFormulationWithReserves, X <: AbstractPowerModel}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]

    services = Set{PSY.Service}()
    for d in devices
        union!(services, PSY.get_services(d))
    end

    for service in services
        s_name = PSY.get_name(service)
        s_type = typeof(service)
        constraint = add_constraints_container!(container, HybridReserveAssignmentConstraint, V, names, time_steps;
            meta = "$(s_type)_$s_name")
        # System-level reserve variable for this service
        sys_reserve = get_variable(container, ActivePowerReserveVariable, s_type, s_name)
        # Per-hybrid reserve variables for this service
        r_out = get_variable(container, HybridReserveVariableOut, V, "$(s_type)_$s_name")
        r_in = get_variable(container, HybridReserveVariableIn, V, "$(s_type)_$s_name")
        for d in devices, t in time_steps
            name = PSY.get_name(d)
            (service in PSY.get_services(d)) || continue
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                r_out[name, t] + r_in[name, t] == sys_reserve[name, t]
            )
        end
    end
    return
end

"""
Couple the hybrid PCC reserve variables (Out + In) to the sum of per-subcomponent
reserve allocations (thermal + renewable + charging + discharging).
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HybridReserveBalanceConstraint},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.HybridSystem, W <: AbstractHybridFormulationWithReserves, X <: AbstractPowerModel}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]

    services = Set{PSY.Service}()
    for d in devices
        union!(services, PSY.get_services(d))
    end

    for service in services
        s_name = PSY.get_name(service)
        s_type = typeof(service)
        constraint = add_constraints_container!(container, HybridReserveBalanceConstraint, V, names, time_steps;
            meta = "$(s_type)_$s_name")
        r_out = get_variable(container, HybridReserveVariableOut, V, "$(s_type)_$s_name")
        r_in = get_variable(container, HybridReserveVariableIn, V, "$(s_type)_$s_name")
        for d in devices, t in time_steps
            name = PSY.get_name(d)
            (service in PSY.get_services(d)) || continue
            rhs = JuMP.AffExpr(0.0)
            for var_t in (HybridThermalReserveVariable, HybridRenewableReserveVariable,
                          HybridChargingReserveVariable, HybridDischargingReserveVariable)
                key = VariableKey(var_t, V, "$(s_type)_$s_name")
                if haskey(IOM.get_variables(container), key)
                    var = get_variable(container, key)
                    JuMP.add_to_expression!(rhs, var[name, t], 1.0)
                end
            end
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                r_out[name, t] + r_in[name, t] == rhs
            )
        end
    end
    return
end
#################################################################################
# Objective function for HybridSystem.
#
# The hybrid envelope itself carries `MarketBidCost(nothing)`. The variable
# costs come from the subcomponents:
#   - Thermal subcomponent → ThermalGenerationCost (PSY 5.x)
#   - Renewable subcomponent → RenewableGenerationCost
#   - Storage subcomponent → StorageCost
#
# We walk into each subcomponent's operation_cost, then delegate to IOM's
# add_variable_cost_to_objective! with the subcomponent's cost data and the
# hybrid-specific variable type. The variable is keyed by the hybrid's name
# (not the subcomponent's), but the cost data drives the linear/piecewise terms.
#################################################################################

function _add_hybrid_subcomponent_variable_cost!(
    container::OptimizationContainer,
    ::Type{V},
    devices,
    accessor::Function,
    ::Type{W},
) where {V <: VariableType, W <: AbstractHybridFormulation}
    for d in devices
        sub = accessor(d)
        sub === nothing && continue
        op_cost = PSY.get_operation_cost(sub)
        # Use IOM's add_variable_cost_to_objective! with the hybrid device
        # but the subcomponent's cost data. The dispatch on (V, HybridSystem, W)
        # is what variable_cost(op_cost, V, HybridSystem, W) needs to see.
        add_variable_cost_to_objective!(container, V, d, op_cost, W)
    end
    return
end

function _add_hybrid_subcomponent_proportional_cost!(
    container::OptimizationContainer,
    ::Type{V},
    devices::Vector{D},
    accessor::Function,
    ::Type{W},
) where {V <: VariableType, D <: PSY.HybridSystem, W <: AbstractHybridFormulation}
    time_steps = get_time_steps(container)
    variable = get_variable(container, V, D)
    for d in devices
        sub = accessor(d)
        sub === nothing && continue
        cost_term = PSY.get_fixed(PSY.get_operation_cost(sub))
        cost_term == 0.0 && continue
        name = PSY.get_name(d)
        for t in time_steps
            add_to_objective_invariant_expression!(
                container,
                cost_term * variable[name, t],
            )
        end
    end
    return
end

function objective_function!(
    container::OptimizationContainer,
    devices::U,
    model::DeviceModel{D, W},
    ::Type{<:AbstractPowerModel},
) where {
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    W <: AbstractHybridFormulation,
} where {D <: PSY.HybridSystem}
    devices_vec = collect(devices)
    hybrids_with_thermal   = [d for d in devices_vec if PSY.get_thermal_unit(d) !== nothing]
    hybrids_with_renewable = [d for d in devices_vec if PSY.get_renewable_unit(d) !== nothing]
    hybrids_with_storage   = [d for d in devices_vec if PSY.get_storage(d) !== nothing]

    # Thermal: variable cost on HybridThermalActivePower, fixed cost on OnVariable
    if !isempty(hybrids_with_thermal)
        _add_hybrid_subcomponent_variable_cost!(container, HybridThermalActivePower,
            hybrids_with_thermal, PSY.get_thermal_unit, W)
        _add_hybrid_subcomponent_proportional_cost!(container, OnVariable,
            hybrids_with_thermal, PSY.get_thermal_unit, W)
    end

    # Renewable: variable cost on HybridRenewableActivePower (typically a curtailment cost)
    if !isempty(hybrids_with_renewable)
        _add_hybrid_subcomponent_variable_cost!(container, HybridRenewableActivePower,
            hybrids_with_renewable, PSY.get_renewable_unit, W)
    end

    # Storage: variable costs on charge/discharge
    if !isempty(hybrids_with_storage)
        _add_hybrid_subcomponent_variable_cost!(container, HybridStorageChargePower,
            hybrids_with_storage, PSY.get_storage, W)
        _add_hybrid_subcomponent_variable_cost!(container, HybridStorageDischargePower,
            hybrids_with_storage, PSY.get_storage, W)
    end
    return
end

#################################################################################
# IOM.variable_cost dispatches — reach into subcomponent cost types
#################################################################################

# Thermal subcomponent variable cost
IOM.variable_cost(
    cost::PSY.ThermalGenerationCost,
    ::Type{HybridThermalActivePower},
    ::Type{<:PSY.HybridSystem},
    ::Type{<:AbstractHybridFormulation},
) = PSY.get_variable(cost)

# Renewable subcomponent variable cost (typically a curtailment penalty)
IOM.variable_cost(
    cost::PSY.RenewableGenerationCost,
    ::Type{HybridRenewableActivePower},
    ::Type{<:PSY.HybridSystem},
    ::Type{<:AbstractHybridFormulation},
) = PSY.get_curtailment_cost(cost)

# Storage subcomponent variable costs
IOM.variable_cost(
    cost::PSY.StorageCost,
    ::Type{HybridStorageChargePower},
    ::Type{<:PSY.HybridSystem},
    ::Type{<:AbstractHybridFormulation},
) = PSY.get_charge_variable_cost(cost)

IOM.variable_cost(
    cost::PSY.StorageCost,
    ::Type{HybridStorageDischargePower},
    ::Type{<:PSY.HybridSystem},
    ::Type{<:AbstractHybridFormulation},
) = PSY.get_discharge_variable_cost(cost)
