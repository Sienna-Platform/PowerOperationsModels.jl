# Event (contingency) arguments: add event parameters during ArgumentConstructStage.
# Ported from PowerSimulations.jl `src/contingency_model/contingency_arguments.jl`,
# adapted to POM's type-based accessors. These override the no-op fallbacks in
# `core/feedforward_interface.jl` for device/formulation/network combinations that model
# contingency events; iterating `get_events(device_model)` is a no-op when none are set.

function add_event_arguments!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel,
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
} where {U <: PSY.StaticInjection}
    for (key, event_model) in get_events(device_model)
        event_type = get_entry_type(key)
        devices_with_attributes =
            [d for d in devices if PSY.has_supplemental_attributes(d, event_type)]
        isempty(devices_with_attributes) &&
            error("no devices found with a supplemental attribute for event $event_type")
        for p_type in [AvailableStatusChangeCountdownParameter, AvailableStatusParameter]
            add_parameters!(
                container,
                p_type,
                devices_with_attributes,
                device_model,
                event_model,
            )
        end
    end
    return
end

function add_event_arguments!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{<:PM.AbstractActivePowerModel},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: Union{StaticPowerLoad, PowerLoadDispatch, PowerLoadInterruption},
} where {U <: PSY.PowerLoad}
    for (key, event_model) in get_events(device_model)
        event_type = get_entry_type(key)
        devices_with_attributes =
            [d for d in devices if PSY.has_supplemental_attributes(d, event_type)]
        isempty(devices_with_attributes) &&
            error("no devices found with a supplemental attribute for event $event_type")
        for p_type in [AvailableStatusChangeCountdownParameter, AvailableStatusParameter]
            add_parameters!(
                container,
                p_type,
                devices_with_attributes,
                device_model,
                event_model,
            )
        end
        add_parameters!(
            container,
            ActivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            event_model,
        )
        add_to_expression!(
            container,
            ActivePowerBalance,
            ActivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            network_model,
        )
    end
    return
end

function add_event_arguments!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{<:PM.AbstractPowerModel},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: Union{StaticPowerLoad, PowerLoadDispatch, PowerLoadInterruption},
} where {U <: PSY.PowerLoad}
    for (key, event_model) in get_events(device_model)
        event_type = get_entry_type(key)
        devices_with_attributes =
            [d for d in devices if PSY.has_supplemental_attributes(d, event_type)]
        isempty(devices_with_attributes) &&
            error("no devices found with a supplemental attribute for event $event_type")
        for p_type in [AvailableStatusChangeCountdownParameter, AvailableStatusParameter]
            add_parameters!(
                container,
                p_type,
                devices_with_attributes,
                device_model,
                event_model,
            )
        end
        add_parameters!(
            container,
            ActivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            event_model,
        )
        add_to_expression!(
            container,
            ActivePowerBalance,
            ActivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            network_model,
        )
        add_parameters!(
            container,
            ReactivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            event_model,
        )
        add_to_expression!(
            container,
            ReactivePowerBalance,
            ReactivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            network_model,
        )
    end
    return
end

function add_event_arguments!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, FixedOutput},
    network_model::NetworkModel{<:PM.AbstractActivePowerModel},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
} where {U <: PSY.StaticInjection}
    for (key, event_model) in get_events(device_model)
        event_type = get_entry_type(key)
        devices_with_attributes =
            [d for d in devices if PSY.has_supplemental_attributes(d, event_type)]
        isempty(devices_with_attributes) &&
            error("no devices found with a supplemental attribute for event $event_type")
        for p_type in [AvailableStatusChangeCountdownParameter, AvailableStatusParameter]
            add_parameters!(
                container,
                p_type,
                devices_with_attributes,
                device_model,
                event_model,
            )
        end
        add_parameters!(
            container,
            ActivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            event_model,
        )
        add_to_expression!(
            container,
            ActivePowerBalance,
            ActivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            network_model,
        )
    end
    return
end

function add_event_arguments!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, FixedOutput},
    network_model::NetworkModel{<:PM.AbstractPowerModel},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
} where {U <: PSY.StaticInjection}
    for (key, event_model) in get_events(device_model)
        event_type = get_entry_type(key)
        devices_with_attributes =
            [d for d in devices if PSY.has_supplemental_attributes(d, event_type)]
        isempty(devices_with_attributes) &&
            error("no devices found with a supplemental attribute for event $event_type")
        for p_type in [AvailableStatusChangeCountdownParameter, AvailableStatusParameter]
            add_parameters!(
                container,
                p_type,
                devices_with_attributes,
                device_model,
                event_model,
            )
        end
        add_parameters!(
            container,
            ActivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            event_model,
        )
        add_to_expression!(
            container,
            ActivePowerBalance,
            ActivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            network_model,
        )
        add_parameters!(
            container,
            ReactivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            event_model,
        )
        add_to_expression!(
            container,
            ReactivePowerBalance,
            ReactivePowerOffsetParameter,
            devices_with_attributes,
            device_model,
            network_model,
        )
    end
    return
end

#################################################################################
# add_to_expression! for EventParameter offsets → SystemBalanceExpressions
#################################################################################

# Nodal injection (PTDF/DCP/ACP and other AbstractPowerModel network models).
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
    network_model::NetworkModel{X},
) where {
    T <: SystemBalanceExpressions,
    U <: EventParameter,
    V <: PSY.Device,
    W <: AbstractDeviceFormulation,
    X <: PM.AbstractPowerModel,
}
    param_array = get_parameter_array(container, U, V)
    multiplier = get_parameter_multiplier_array(container, U, V)
    network_reduction = get_network_reduction(network_model)
    for d in devices, t in get_time_steps(container)
        bus_no = PNM.get_mapped_bus_number(network_reduction, PSY.get_bus(d))
        name = PSY.get_name(d)
        add_proportional_to_jump_expression!(
            get_expression(container, T, PSY.ACBus)[bus_no, t],
            param_array[name, t],
            multiplier[name, t],
        )
    end
    return
end

# CopperPlate: inject at the reference bus of the device's subnetwork.
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
    network_model::NetworkModel{CopperPlatePowerModel},
) where {
    T <: SystemBalanceExpressions,
    U <: EventParameter,
    V <: PSY.Device,
    W <: AbstractDeviceFormulation,
}
    param_array = get_parameter_array(container, U, V)
    multiplier = get_parameter_multiplier_array(container, U, V)
    expression = get_expression(container, T, PSY.System)
    for d in devices
        ref_bus = get_reference_bus(network_model, PSY.get_bus(d))
        name = PSY.get_name(d)
        for t in get_time_steps(container)
            add_proportional_to_jump_expression!(
                expression[ref_bus, t],
                param_array[name, t],
                multiplier[name, t],
            )
        end
    end
    return
end

# Area balance: inject into the device's area.
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
    network_model::NetworkModel{AreaBalancePowerModel},
) where {
    T <: SystemBalanceExpressions,
    U <: EventParameter,
    V <: PSY.Device,
    W <: AbstractDeviceFormulation,
}
    param_array = get_parameter_array(container, U, V)
    multiplier = get_parameter_multiplier_array(container, U, V)
    for d in devices, t in get_time_steps(container)
        area_name = PSY.get_name(PSY.get_area(PSY.get_bus(d)))
        name = PSY.get_name(d)
        add_proportional_to_jump_expression!(
            get_expression(container, T, PSY.Area)[area_name, t],
            param_array[name, t],
            multiplier[name, t],
        )
    end
    return
end
