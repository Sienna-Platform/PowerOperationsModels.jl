#! format: off

requires_initialization(::AbstractReactivePowerDeviceFormulation) = false
get_variable_multiplier(::Type{<:VariableType}, ::Type{<:PSY.SynchronousCondenser}, ::Type{<:AbstractReactivePowerDeviceFormulation}) = 1.0

############## ReactivePowerVariable, SynchronousCondensers ####################
get_variable_binary(::Type{ReactivePowerVariable}, ::Type{PSY.SynchronousCondenser}, ::Type{<:AbstractReactivePowerDeviceFormulation}) = false
get_variable_warm_start_value(::Type{ReactivePowerVariable}, d::PSY.SynchronousCondenser, ::Type{<:AbstractReactivePowerDeviceFormulation}) = PSY.get_reactive_power(d)
get_variable_lower_bound(::Type{ReactivePowerVariable}, d::PSY.SynchronousCondenser, ::Type{<:AbstractReactivePowerDeviceFormulation}) = isnothing(PSY.get_reactive_power_limits(d)) ? nothing : PSY.get_reactive_power_limits(d).min
get_variable_upper_bound(::Type{ReactivePowerVariable}, d::PSY.SynchronousCondenser, ::Type{<:AbstractReactivePowerDeviceFormulation}) = isnothing(PSY.get_reactive_power_limits(d)) ? nothing : PSY.get_reactive_power_limits(d).max

#! format: on
function get_initial_conditions_device_model(
    model::OperationModel,
    ::DeviceModel{T, D},
) where {T <: PSY.SynchronousCondenser, D <: AbstractReactivePowerDeviceFormulation}
    return DeviceModel(T, SynchronousCondenserBasicDispatch)
end

function get_default_attributes(
    ::Type{U},
    ::Type{V},
) where {U <: PSY.SynchronousCondenser, V <: AbstractReactivePowerDeviceFormulation}
    return Dict{String, Any}()
end

function get_default_time_series_names(
    ::Type{<:PSY.SynchronousCondenser},
    ::Type{<:AbstractReactivePowerDeviceFormulation},
)
    return Dict{Type{<:TimeSeriesParameter}, String}()
end
