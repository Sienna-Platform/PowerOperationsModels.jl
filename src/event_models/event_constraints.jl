#################################################################################
# Event outage constraints (ModelConstructStage). Overrides the no-op stub in
# core/feedforward_interface.jl for the supported injector families.
#################################################################################

# What the active-power outage bound applies to: the range expression when the
# formulation routes power through one, else the variable itself.
_active_power_outage_lhs(::DeviceModel{<:Union{PSY.ThermalGen, PSY.HydroGen}}) =
    ActivePowerRangeExpressionUB
_active_power_outage_lhs(::DeviceModel{<:PSY.ElectricLoad}) = ActivePowerVariable
function _active_power_outage_lhs(device_model::DeviceModel{<:PSY.RenewableGen})
    if has_service_model(device_model)
        return ActivePowerRangeExpressionUB
    end
    return ActivePowerVariable
end

function _add_active_power_outage_constraint!(
    container::OptimizationContainer,
    devices_with_attributes::Vector{U},
    device_model::DeviceModel,
    ::Type{W},
) where {U <: PSY.StaticInjection, W}
    add_parameterized_upper_bound_range_constraints(
        container,
        ActivePowerOutageConstraint,
        _active_power_outage_lhs(device_model),
        AvailableStatusParameter,
        devices_with_attributes,
        device_model,
        W,
    )
    return
end

function add_event_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{W},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
    W <: AbstractActivePowerModel,
} where {U <: Union{PSY.ThermalGen, PSY.HydroGen}}
    _for_each_event_devices(devices, device_model) do devices_with_attributes, _
        _add_active_power_outage_constraint!(
            container,
            devices_with_attributes,
            device_model,
            W,
        )
    end
    return
end

function add_event_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{W},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
    W <: AbstractReactivePowerNetworkModel,
} where {U <: Union{PSY.ThermalGen, PSY.HydroGen}}
    _for_each_event_devices(devices, device_model) do devices_with_attributes, _
        _add_active_power_outage_constraint!(
            container,
            devices_with_attributes,
            device_model,
            W,
        )
        add_reactive_power_contingency_constraint(
            container,
            ReactivePowerOutageConstraint,
            ReactivePowerVariable,
            AvailableStatusParameter,
            devices_with_attributes,
            device_model,
            W,
        )
    end
    return
end

function add_event_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{W},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
    W <: AbstractActivePowerModel,
} where {U <: PSY.RenewableGen}
    _for_each_event_devices(devices, device_model) do devices_with_attributes, _
        _add_active_power_outage_constraint!(
            container,
            devices_with_attributes,
            device_model,
            W,
        )
    end
    return
end

function add_event_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{W},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
    W <: AbstractReactivePowerNetworkModel,
} where {U <: PSY.RenewableGen}
    _for_each_event_devices(devices, device_model) do devices_with_attributes, _
        _add_active_power_outage_constraint!(
            container,
            devices_with_attributes,
            device_model,
            W,
        )
        add_reactive_power_contingency_constraint(
            container,
            ReactivePowerOutageConstraint,
            ReactivePowerVariable,
            AvailableStatusParameter,
            devices_with_attributes,
            device_model,
            W,
        )
    end
    return
end

function add_event_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{W},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
    W <: AbstractActivePowerModel,
} where {U <: PSY.ElectricLoad}
    _for_each_event_devices(devices, device_model) do devices_with_attributes, _
        _add_active_power_outage_constraint!(
            container,
            devices_with_attributes,
            device_model,
            W,
        )
    end
    return
end

function add_event_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{W},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
    W <: AbstractReactivePowerNetworkModel,
} where {U <: PSY.ElectricLoad}
    _for_each_event_devices(devices, device_model) do devices_with_attributes, _
        _add_active_power_outage_constraint!(
            container,
            devices_with_attributes,
            device_model,
            W,
        )
        add_reactive_power_contingency_constraint(
            container,
            ReactivePowerOutageConstraint,
            ReactivePowerVariable,
            AvailableStatusParameter,
            devices_with_attributes,
            device_model,
            W,
        )
    end
    return
end

#################################################################################
# Quadratic reactive-power outage constraint: q^2 <= ub * status
#################################################################################

function add_reactive_power_contingency_constraint(
    container::OptimizationContainer,
    ::Type{ReactivePowerOutageConstraint},
    ::Type{ReactivePowerVariable},
    ::Type{AvailableStatusParameter},
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
    ::Type{X},
) where {
    V <: PSY.Component,
    W <: AbstractDeviceFormulation,
    X <: AbstractReactivePowerNetworkModel,
}
    array_reactive = get_variable(container, ReactivePowerVariable, V)
    _add_reactive_power_contingency_constraint_impl!(
        container,
        ReactivePowerOutageConstraint,
        array_reactive,
        AvailableStatusParameter(),
        devices,
        model,
    )
    return
end

function _add_reactive_power_contingency_constraint_impl!(
    container::OptimizationContainer,
    ::Type{ReactivePowerOutageConstraint},
    array_reactive,
    param::AvailableStatusParameter,
    devices::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    model::DeviceModel{V, W},
) where {
    V <: PSY.Component,
    W <: AbstractDeviceFormulation,
}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    constraint_container = add_constraints_container!(
        container,
        ReactivePowerOutageConstraint,
        V,
        names,
        time_steps;
        meta = "ub",
    )
    param_array = get_parameter_array(container, param, V)
    jump_model = get_jump_model(container)
    for device in devices
        name = PSY.get_name(device)
        ub = _get_reactive_power_upper_bound(device)
        for t in time_steps
            constraint_container[name, t] = JuMP.@constraint(
                jump_model,
                (array_reactive[name, t])^2 <= (ub * param_array[name, t])
            )
        end
    end
    return
end

_get_reactive_power_upper_bound(device::PSY.StaticInjection) = begin
    limits = PSY.get_reactive_power_limits(device, PSY.SU)
    max(limits.max^2, limits.min^2)
end

_get_reactive_power_upper_bound(device::PSY.ElectricLoad) =
    PSY.get_max_reactive_power(device, PSY.SU)^2

#################################################################################
# Hydro (ported from HydroPowerSimulations src/contingency_model.jl)
#################################################################################

function add_event_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{W},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
    W <: AbstractActivePowerModel,
} where {U <: PSY.HydroPumpTurbine}
    _for_each_event_devices(devices, device_model) do devices_with_attributes, _
        add_pump_turbine_active_power_contingency_constraints!(
            container,
            devices_with_attributes,
            device_model,
        )
    end
    return
end

function add_event_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{W},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
    W <: AbstractReactivePowerNetworkModel,
} where {U <: PSY.HydroPumpTurbine}
    _for_each_event_devices(devices, device_model) do devices_with_attributes, _
        add_pump_turbine_active_power_contingency_constraints!(
            container,
            devices_with_attributes,
            device_model,
        )
        add_reactive_power_contingency_constraint(
            container,
            ReactivePowerOutageConstraint,
            ReactivePowerVariable,
            AvailableStatusParameter,
            devices_with_attributes,
            device_model,
            W,
        )
    end
    return
end

function add_pump_turbine_active_power_contingency_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
} where {U <: PSY.HydroPumpTurbine}
    names = PSY.get_name.(devices)
    time_steps = get_time_steps(container)
    array_active_power = get_variable(container, ActivePowerVariable, U)
    array_active_power_pump = get_variable(container, ActivePowerPumpVariable, U)
    constraint_active_power = add_constraints_container!(
        container,
        ActivePowerOutageConstraint,
        U,
        names,
        time_steps,
    )
    constraint_active_power_pump = add_constraints_container!(
        container,
        ActivePowerPumpOutageConstraint,
        U,
        names,
        time_steps,
    )
    param_array = get_parameter_array(container, AvailableStatusParameter(), U)
    jump_model = get_jump_model(container)
    for device in devices
        name = PSY.get_name(device)
        ub_active_power = PSY.get_active_power_limits(device, PSY.SU).max
        ub_active_power_pump = PSY.get_active_power_limits_pump(device, PSY.SU).max
        for t in time_steps
            constraint_active_power[name, t] = JuMP.@constraint(
                jump_model,
                array_active_power[name, t] <= ub_active_power * param_array[name, t]
            )
            constraint_active_power_pump[name, t] = JuMP.@constraint(
                jump_model,
                array_active_power_pump[name, t] <=
                ub_active_power_pump * param_array[name, t]
            )
        end
    end
    return
end

#################################################################################
# Storage (ported from StorageSystemsSimulations src/contingency_model.jl)
#################################################################################

function add_event_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{W},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
    W <: AbstractActivePowerModel,
} where {U <: PSY.EnergyReservoirStorage}
    _for_each_event_devices(devices, device_model) do devices_with_attributes, _
        add_input_output_active_power_contingency_constraints!(
            container,
            devices_with_attributes,
            device_model,
        )
    end
    return
end

function add_event_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
    network_model::NetworkModel{W},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
    W <: AbstractReactivePowerNetworkModel,
} where {U <: PSY.EnergyReservoirStorage}
    _for_each_event_devices(devices, device_model) do devices_with_attributes, _
        add_input_output_active_power_contingency_constraints!(
            container,
            devices_with_attributes,
            device_model,
        )
        add_reactive_power_contingency_constraint(
            container,
            ReactivePowerOutageConstraint,
            ReactivePowerVariable,
            AvailableStatusParameter,
            devices_with_attributes,
            device_model,
            W,
        )
    end
    return
end

function add_input_output_active_power_contingency_constraints!(
    container::OptimizationContainer,
    devices::T,
    device_model::DeviceModel{U, V},
) where {
    T <: Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    V <: AbstractDeviceFormulation,
} where {U <: PSY.EnergyReservoirStorage}
    names = PSY.get_name.(devices)
    time_steps = get_time_steps(container)
    array_in = get_variable(container, ActivePowerInVariable, U)
    array_out = get_variable(container, ActivePowerOutVariable, U)
    constraint_input = add_constraints_container!(
        container,
        ActivePowerOutageConstraint,
        U,
        names,
        time_steps;
        meta = "input",
    )
    constraint_output = add_constraints_container!(
        container,
        ActivePowerOutageConstraint,
        U,
        names,
        time_steps;
        meta = "output",
    )
    param_array = get_parameter_array(container, AvailableStatusParameter(), U)
    jump_model = get_jump_model(container)
    for device in devices
        name = PSY.get_name(device)
        ub_input = PSY.get_input_active_power_limits(device, PSY.SU).max
        ub_output = PSY.get_output_active_power_limits(device, PSY.SU).max
        for t in time_steps
            constraint_input[name, t] = JuMP.@constraint(
                jump_model,
                array_in[name, t] <= ub_input * param_array[name, t]
            )
            constraint_output[name, t] = JuMP.@constraint(
                jump_model,
                array_out[name, t] <= ub_output * param_array[name, t]
            )
        end
    end
    return
end
