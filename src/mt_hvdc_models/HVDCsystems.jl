#! format: off
get_variable_binary(::Type{ActivePowerVariable}, ::Type{PSY.InterconnectingConverter}, ::Type{<:AbstractConverterFormulation}) = false
get_variable_warm_start_value(::Type{ActivePowerVariable}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_active_power(d, PSY.SU)
get_variable_lower_bound(::Type{ActivePowerVariable}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_active_power_limits(d, PSY.SU).min
get_variable_upper_bound(::Type{ActivePowerVariable}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_active_power_limits(d, PSY.SU).max
get_variable_multiplier(::Type{<:VariableType}, ::Type{PSY.InterconnectingConverter}, ::Type{<:AbstractConverterFormulation}) = 1.0


function _get_flow_bounds(d::PSY.TModelHVDCLine)
    check_hvdc_line_limits_consistency(d)
    from_min = PSY.get_active_power_limits_from(d, PSY.SU).min
    to_min = PSY.get_active_power_limits_to(d, PSY.SU).min
    from_max = PSY.get_active_power_limits_from(d, PSY.SU).max
    to_max = PSY.get_active_power_limits_to(d, PSY.SU).max

    if from_min >= 0.0 && to_min >= 0.0
        min_rate = min(from_min, to_min)
    elseif from_min <= 0.0 && to_min <= 0.0
        min_rate = max(from_min, to_min)
    elseif from_min <= 0.0 && to_min >= 0.0
        min_rate = from_min
    elseif to_min <= 0.0 && from_min >= 0.0
        min_rate = to_min
    else
        @assert false
    end

    if from_max >= 0.0 && to_max >= 0.0
        max_rate = min(from_max, to_max)
    elseif from_max <= 0.0 && to_max <= 0.0
        max_rate = max(from_max, to_max)
    elseif from_max <= 0.0 && to_max >= 0.0
        max_rate = from_max
    elseif from_max >= 0.0 && to_max <= 0.0
        max_rate = to_max
    else
        @assert false
    end

    return min_rate, max_rate
end


get_variable_binary(::Type{FlowActivePowerVariable}, ::Type{PSY.TModelHVDCLine}, ::Type{<:AbstractBranchFormulation}) = false
get_variable_binary(::Type{DCLineCurrent}, ::Type{PSY.TModelHVDCLine}, ::Type{<:AbstractBranchFormulation}) = false
get_variable_warm_start_value(::Type{FlowActivePowerVariable}, d::PSY.TModelHVDCLine, ::Type{<:AbstractBranchFormulation}) = PSY.get_active_power_flow(d, PSY.SU)
get_variable_lower_bound(::Type{FlowActivePowerVariable}, d::PSY.TModelHVDCLine, ::Type{<:AbstractBranchFormulation}) = _get_flow_bounds(d)[1]
get_variable_upper_bound(::Type{FlowActivePowerVariable}, d::PSY.TModelHVDCLine, ::Type{<:AbstractBranchFormulation}) = _get_flow_bounds(d)[2]

# This is an approximation for DC lines since the actual current limit depends on the voltage, that is a variable in the optimization problem
function get_variable_lower_bound(::Type{DCLineCurrent}, d::PSY.TModelHVDCLine, ::Type{<:AbstractBranchFormulation})
    p_min_flow = _get_flow_bounds(d)[1]
    arc = PSY.get_arc(d)
    bus_from = arc.from
    bus_to = arc.to
    max_v = max(PSY.get_magnitude(bus_from), PSY.get_magnitude(bus_to))
    return p_min_flow / max_v
end
# This is an approximation for DC lines since the actual current limit depends on the voltage, that is a variable in the optimization problem
function get_variable_upper_bound(::Type{DCLineCurrent}, d::PSY.TModelHVDCLine, ::Type{<:AbstractBranchFormulation})
    p_max_flow = _get_flow_bounds(d)[2]
    arc = PSY.get_arc(d)
    bus_from = arc.from
    bus_to = arc.to
    max_v = max(PSY.get_magnitude(bus_from), PSY.get_magnitude(bus_to))
    return p_max_flow / max_v
end
get_variable_multiplier(::Type{<:VariableType}, ::Type{PSY.TModelHVDCLine}, ::Type{<:AbstractBranchFormulation}) = 1.0

requires_initialization(::AbstractConverterFormulation) = false
requires_initialization(::LosslessLine) = false

function get_initial_conditions_device_model(
    ::IOM.AbstractOptimizationModel,
    model::DeviceModel{PSY.InterconnectingConverter, <:AbstractConverterFormulation},
)
    return model
end

function get_initial_conditions_device_model(
    ::IOM.AbstractOptimizationModel,
    model::DeviceModel{PSY.TModelHVDCLine, D},
) where {D <: AbstractDCLineFormulation}
    return model
end


function get_default_time_series_names(
    ::Type{PSY.InterconnectingConverter},
    ::Type{<:AbstractConverterFormulation},
)
    return Dict{Type{<:TimeSeriesParameter}, String}()
end

function get_default_time_series_names(
    ::Type{PSY.TModelHVDCLine},
    ::Type{<:AbstractBranchFormulation},
)
    return Dict{Type{<:TimeSeriesParameter}, String}()
end

function get_default_attributes(
    ::Type{PSY.InterconnectingConverter},
    ::Type{<:AbstractConverterFormulation},
)
    return Dict{String, Any}()
end

function get_default_attributes(
    ::Type{PSY.TModelHVDCLine},
    ::Type{<:AbstractBranchFormulation},
)
    return Dict{String, Any}()
end


############################################
######## Quadratic Converter Model #########
############################################

## Binaries ###
get_variable_binary(::Type{ConverterCurrent}, ::Type{PSY.InterconnectingConverter}, ::Type{<:AbstractConverterFormulation}) = false
get_variable_binary(::Type{CurrentAbsoluteValueVariable}, ::Type{PSY.InterconnectingConverter}, ::Type{<:AbstractConverterFormulation}) = false

### Warm Start ###
get_variable_warm_start_value(::Type{ConverterCurrent}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_dc_current(d)

### Lower Bounds ###
get_variable_lower_bound(::Type{ConverterCurrent}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = -PSY.get_max_dc_current(d)
get_variable_lower_bound(::Type{CurrentAbsoluteValueVariable}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = 0.0

### Upper Bounds ###
get_variable_upper_bound(::Type{ConverterCurrent}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_max_dc_current(d)
get_variable_upper_bound(::Type{CurrentAbsoluteValueVariable}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_max_dc_current(d)

#! format: on

############################################
############## Expressions #################
############################################

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    ::DeviceModel{V, W},
    network_model::NetworkModel{X},
) where {
    T <: Union{ActivePowerBalance, DCCurrentBalance},
    U <: Union{FlowActivePowerVariable, DCLineCurrent},
    V <: PSY.TModelHVDCLine,
    W <: AbstractDCLineFormulation,
    X <: AbstractPowerModel,
}
    variable = get_variable(container, U, V)
    expression = get_expression(container, T, PSY.DCBus)
    for d in devices
        arc = PSY.get_arc(d)
        to_bus_number = PSY.get_number(PSY.get_to(arc))
        from_bus_number = PSY.get_number(PSY.get_from(arc))
        for t in get_time_steps(container)
            name = PSY.get_name(d)
            add_proportional_to_jump_expression!(
                expression[to_bus_number, t],
                variable[name, t],
                1.0,
            )
            add_proportional_to_jump_expression!(
                expression[from_bus_number, t],
                variable[name, t],
                -1.0,
            )
        end
    end
    return
end

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    device_model::DeviceModel{V, W},
    network_model::NetworkModel{X},
) where {
    T <: ActivePowerBalance,
    U <: ActivePowerVariable,
    V <: PSY.InterconnectingConverter,
    W <: AbstractConverterFormulation,
    X <: AreaPTDFPowerModel,
}
    _add_to_expression!(
        container,
        T,
        U,
        devices,
        device_model,
        network_model,
    )
    return
end

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    device_model::DeviceModel{V, W},
    network_model::NetworkModel{X},
) where {
    T <: ActivePowerBalance,
    U <: ActivePowerVariable,
    V <: PSY.InterconnectingConverter,
    W <: AbstractConverterFormulation,
    X <: AbstractPowerModel,
}
    _add_to_expression!(
        container,
        T,
        U,
        devices,
        device_model,
        network_model,
    )
    return
end

function _add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    ::DeviceModel{V, W},
    network_model::NetworkModel{X},
) where {
    T <: ActivePowerBalance,
    U <: ActivePowerVariable,
    V <: PSY.InterconnectingConverter,
    W <: AbstractConverterFormulation,
    X <: AbstractPowerModel,
}
    variable = get_variable(container, U, V)
    expression_dc = get_expression(container, T, PSY.DCBus)
    expression_ac = get_expression(container, T, PSY.ACBus)
    for d in devices, t in get_time_steps(container)
        name = PSY.get_name(d)
        bus_number_dc = PSY.get_number(PSY.get_dc_bus(d))
        bus_number_ac = PSY.get_number(PSY.get_bus(d))
        add_proportional_to_jump_expression!(
            expression_ac[bus_number_ac, t],
            variable[name, t],
            1.0,
        )
        add_proportional_to_jump_expression!(
            expression_dc[bus_number_dc, t],
            variable[name, t],
            -1.0,
        )
    end
    return
end

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    ::DeviceModel{V, W},
    network_model::NetworkModel{AreaPTDFPowerModel},
) where {
    T <: ActivePowerBalance,
    U <: ActivePowerVariable,
    V <: PSY.InterconnectingConverter,
    W <: AbstractConverterFormulation,
}
    error("AreaPTDFPowerModel doesn't support InterconnectingConverter")
    return
end

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    ::DeviceModel{V, W},
    network_model::NetworkModel{PTDFPowerModel},
) where {
    T <: ActivePowerBalance,
    U <: ActivePowerVariable,
    V <: PSY.InterconnectingConverter,
    W <: AbstractConverterFormulation,
}
    variable = get_variable(container, U, V)
    expression_dc = get_expression(container, T, PSY.DCBus)
    expression_ac = get_expression(container, T, PSY.ACBus)
    for d in devices, t in get_time_steps(container)
        name = PSY.get_name(d)
        bus_number_dc = PSY.get_number(PSY.get_dc_bus(d))
        bus_number_ac = PSY.get_number(PSY.get_bus(d))
        add_proportional_to_jump_expression!(
            expression_ac[bus_number_ac, t],
            variable[name, t],
            1.0,
        )
        add_proportional_to_jump_expression!(
            expression_dc[bus_number_dc, t],
            variable[name, t],
            -1.0,
        )
    end
    return
end

function add_to_expression!(
    ::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    ::DeviceModel{V, W},
    network_model::NetworkModel{AreaBalancePowerModel},
) where {
    T <: ActivePowerBalance,
    U <: ActivePowerVariable,
    V <: PSY.InterconnectingConverter,
    W <: AbstractConverterFormulation,
}
    return
end

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    network_model::NetworkModel{CopperPlatePowerModel},
) where {
    T <: ActivePowerBalance,
    U <: ActivePowerVariable,
    V <: PSY.InterconnectingConverter,
    W <: AbstractConverterFormulation,
}
    variable = get_variable(container, U, V)
    expression_dc = get_expression(container, T, PSY.DCBus)
    sys_expr = get_expression(container, T, PSY.System)
    for d in devices
        name = PSY.get_name(d)
        device_bus = PSY.get_bus(d)
        ref_bus = get_reference_bus(network_model, device_bus)
        bus_number_dc = PSY.get_number(PSY.get_dc_bus(d))
        for t in get_time_steps(container)
            add_proportional_to_jump_expression!(
                sys_expr[ref_bus, t],
                variable[name, t],
                get_variable_multiplier(U, V, W),
            )
            add_proportional_to_jump_expression!(
                expression_dc[bus_number_dc, t],
                variable[name, t],
                -1.0,
            )
        end
    end
    return
end

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    network_model::NetworkModel{CopperPlatePowerModel},
) where {
    T <: ActivePowerBalance,
    U <: ActivePowerVariable,
    V <: PSY.InterconnectingConverter,
    W <: AbstractQuadraticLossConverter,
}
    variable = get_variable(container, U, V)
    sys_expr = get_expression(container, T, PSY.System)
    for d in devices
        name = PSY.get_name(d)
        device_bus = PSY.get_bus(d)
        ref_bus = get_reference_bus(network_model, device_bus)
        for t in get_time_steps(container)
            add_proportional_to_jump_expression!(
                sys_expr[ref_bus, t],
                variable[name, t],
                get_variable_multiplier(U, V, W),
            )
        end
    end
    return
end

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    network_model::NetworkModel{CopperPlatePowerModel},
) where {
    T <: DCCurrentBalance,
    U <: ConverterCurrent,
    V <: PSY.InterconnectingConverter,
    W <: AbstractQuadraticLossConverter,
}
    variable = get_variable(container, U, V)
    expression_dc = get_expression(container, T, PSY.DCBus)
    for d in devices
        name = PSY.get_name(d)
        bus_number_dc = PSY.get_number(PSY.get_dc_bus(d))
        for t in get_time_steps(container)
            add_proportional_to_jump_expression!(
                expression_dc[bus_number_dc, t],
                variable[name, t],
                -1.0,
            )
        end
    end
    return
end

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    ::DeviceModel{V, W},
    network_model::NetworkModel{X},
) where {
    T <: ActivePowerBalance,
    U <: ActivePowerVariable,
    V <: PSY.InterconnectingConverter,
    W <: AbstractConverterFormulation,
    X <: PTDFPowerModel,
}
    variable = get_variable(container, U, V)
    expression_dc = get_expression(container, T, PSY.DCBus)
    expression_ac = get_expression(container, T, PSY.ACBus)
    sys_expr = get_expression(container, T, PSY.System)
    for d in devices
        name = PSY.get_name(d)
        device_bus = PSY.get_bus(d)
        bus_number_ac = PSY.get_number(device_bus)
        ref_bus = get_reference_bus(network_model, device_bus)
        bus_number_dc = PSY.get_number(PSY.get_dc_bus(d))
        for t in get_time_steps(container)
            add_proportional_to_jump_expression!(
                sys_expr[ref_bus, t],
                variable[name, t],
                get_variable_multiplier(U, V, W),
            )
            add_proportional_to_jump_expression!(
                expression_ac[bus_number_ac, t],
                variable[name, t],
                get_variable_multiplier(U, V, W),
            )
            add_proportional_to_jump_expression!(
                expression_dc[bus_number_dc, t],
                variable[name, t],
                -1.0,
            )
        end
    end

    return
end

############################################
############## Constraints #################
############################################

############## HVDC Lines ##################
function add_constraints!(
    container::OptimizationContainer,
    ::Type{DCLineCurrentConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, U},
    network_model::NetworkModel{V},
) where {T <: PSY.TModelHVDCLine, U <: DCLossyLine, V <: AbstractPowerModel}
    variable = get_variable(container, DCLineCurrent, T)
    dc_voltage = get_variable(container, DCVoltage, PSY.DCBus)
    time_steps = get_time_steps(container)
    constraints = add_constraints_container!(container, DCLineCurrentConstraint,
        T,
        PSY.get_name.(devices),
        time_steps,
    )

    for d in devices
        arc = PSY.get_arc(d)
        from_bus_name = PSY.get_name(arc.from)
        to_bus_name = PSY.get_name(arc.to)
        name = PSY.get_name(d)
        r = PSY.get_r(d)
        if iszero(r)
            for t in time_steps
                constraints[name, t] = JuMP.@constraint(
                    get_jump_model(container),
                    dc_voltage[from_bus_name, t] == dc_voltage[to_bus_name, t]
                )
            end
        else
            for t in get_time_steps(container)
                constraints[name, t] = JuMP.@constraint(
                    get_jump_model(container),
                    variable[name, t] ==
                    (dc_voltage[from_bus_name, t] - dc_voltage[to_bus_name, t]) / r
                )
            end
        end
    end
    return
end

############## Converters ##################

function add_constraints!(
    container::OptimizationContainer,
    ::Type{ConverterLossConstraint},
    devices::IS.FlattenIteratorWrapper{U},
    model::DeviceModel{U, V},
    ::NetworkModel{X},
) where {
    U <: PSY.InterconnectingConverter,
    V <: AbstractQuadraticLossConverter,
    X <: AbstractActivePowerModel,
}
    time_steps = get_time_steps(container)
    P_ac_var = get_variable(container, ActivePowerVariable, U)
    vi_expr = get_expression(container, IOM.BilinearProductExpression, U, "vi")
    i_sq_expr = get_expression(container, IOM.QuadraticExpression, U, "i_sq")
    abs_i_var = get_variable(container, CurrentAbsoluteValueVariable, U)

    ipc_names = [PSY.get_name(d) for d in devices]
    loss_const = add_constraints_container!(
        container, ConverterLossConstraint, U, ipc_names, time_steps,
    )

    jump_model = get_jump_model(container)
    for device in devices
        name = PSY.get_name(device)
        loss_function = PSY.get_loss_function(device)
        a = _get_quadratic_term(loss_function)
        b = PSY.get_proportional_term(loss_function)
        c = PSY.get_constant_term(loss_function)
        for t in time_steps
            loss = _quadratic_converter_loss_expr(
                a, b, c, i_sq_expr[name, t], abs_i_var[name, t],
            )
            loss_const[name, t] = JuMP.@constraint(
                jump_model,
                P_ac_var[name, t] == vi_expr[name, t] - loss,
            )
        end
    end
    return
end

############################################
########### Objective Function #############
############################################

function add_to_objective_function!(
    ::OptimizationContainer,
    ::IS.FlattenIteratorWrapper{PSY.InterconnectingConverter},
    ::DeviceModel{PSY.InterconnectingConverter, D},
    ::Type{<:AbstractPowerModel},
) where {D <: AbstractConverterFormulation}
    return
end
