# Build-time contingency-event helpers: parameter defaults and the EventParameter
# parameter-container path. Ported from PowerSimulations.jl `src/contingency_model/`,
# adapted to POM's type-based accessor conventions and IOM-qualified container internals.

# The EventParameter outage constraint (IOM `range_constraint.jl`) bounds dispatch by
# `get_max_active_power(device) * AvailableStatusParameter`. POM supplies the value.
get_max_active_power(d::PSY.Device) = PSY.get_max_active_power(d, PSY.SU)

#! format: off
# These values could change depending on the event modeling choices.
get_parameter_multiplier(::EventParameter, ::PSY.Device, ::EventModel) = 1.0
get_initial_parameter_value(::ActivePowerOffsetParameter, ::PSY.Device, ::EventModel) = 0.0
get_initial_parameter_value(::ReactivePowerOffsetParameter, ::PSY.Device, ::EventModel) = 0.0
get_initial_parameter_value(::AvailableStatusChangeCountdownParameter, ::PSY.Device, ::EventModel) = 0.0
get_initial_parameter_value(::AvailableStatusParameter, ::PSY.Device, ::EventModel) = 1.0
#! format: on

function _add_parameters!(
    container::OptimizationContainer,
    ::Type{T},
    devices::Vector{U},
    device_model::DeviceModel{U, W},
    event_model::EventModel{V, X},
) where {
    T <: EventParameter,
    U <: PSY.Component,
    V <: PSY.Contingency,
    W <: AbstractDeviceFormulation,
    X <: AbstractEventCondition,
}
    @debug "adding" T U V _group = IOM.LOG_GROUP_OPTIMIZATION_CONTAINER
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    # The contingency type is build-time metadata only; the optimization container keys
    # the parameter by the device type for both the `ParameterKey` and `affected_devices`.
    parameter_container = add_param_container!(container, T, U, U, names, time_steps)

    jump_model = get_jump_model(container)
    parent_mult = IOM.get_multiplier_array_data(parameter_container)
    parent_param = IOM.get_parameter_array_data(parameter_container)

    for (i, d) in enumerate(devices)
        ini_val = get_initial_parameter_value(T(), d, event_model)
        IOM._set_multiplier_at!(
            parent_mult,
            get_parameter_multiplier(T(), d, event_model),
            i,
        )
        for t in time_steps
            IOM._set_parameter_at!(parent_param, jump_model, ini_val, i, t)
        end
    end
    return
end

function add_parameters!(
    container::OptimizationContainer,
    ::Type{T},
    devices::Vector{U},
    device_model::DeviceModel{U, W},
    event_model::EventModel,
) where {T <: EventParameter, U <: PSY.Component, W <: AbstractDeviceFormulation}
    _add_parameters!(container, T, devices, device_model, event_model)
    return
end
