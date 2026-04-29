#! format: off
get_variable_binary(::Type{ActivePowerVariable}, ::Type{PSY.InterconnectingConverter}, ::Type{<:AbstractConverterFormulation}) = false
get_variable_warm_start_value(::Type{ActivePowerVariable}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_active_power(d)
get_variable_lower_bound(::Type{ActivePowerVariable}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_active_power_limits(d).min
get_variable_upper_bound(::Type{ActivePowerVariable}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_active_power_limits(d).max
get_variable_multiplier(::Type{<:VariableType}, ::Type{PSY.InterconnectingConverter}, ::Type{<:AbstractConverterFormulation}) = 1.0


function _get_flow_bounds(d::PSY.TModelHVDCLine)
    check_hvdc_line_limits_consistency(d)
    from_min = PSY.get_active_power_limits_from(d).min
    to_min = PSY.get_active_power_limits_to(d).min
    from_max = PSY.get_active_power_limits_from(d).max
    to_max = PSY.get_active_power_limits_to(d).max

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
get_variable_warm_start_value(::Type{FlowActivePowerVariable}, d::PSY.TModelHVDCLine, ::Type{<:AbstractBranchFormulation}) = PSY.get_active_power_flow(d)
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
    ::OperationModel,
    model::DeviceModel{PSY.InterconnectingConverter, <:AbstractConverterFormulation},
)
    return model
end

function get_initial_conditions_device_model(
    ::OperationModel,
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
get_variable_binary(::Type{ConverterPositiveCurrent}, ::Type{PSY.InterconnectingConverter}, ::Type{<:AbstractConverterFormulation}) = false
get_variable_binary(::Type{ConverterNegativeCurrent}, ::Type{PSY.InterconnectingConverter}, ::Type{<:AbstractConverterFormulation}) = false
get_variable_binary(::Type{ConverterCurrentDirection}, ::Type{PSY.InterconnectingConverter}, ::Type{<:AbstractConverterFormulation}) = true

### Warm Start ###
get_variable_warm_start_value(::Type{ConverterCurrent}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_dc_current(d)

### Lower Bounds ###
get_variable_lower_bound(::Type{ConverterCurrent}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = -PSY.get_max_dc_current(d)
get_variable_lower_bound(::Type{ConverterPositiveCurrent}, d::PSY.InterconnectingConverter,::Type{<:AbstractConverterFormulation}) = 0.0
get_variable_lower_bound(::Type{ConverterNegativeCurrent}, d::PSY.InterconnectingConverter,::Type{<:AbstractConverterFormulation}) = 0.0

### Upper Bounds ###
get_variable_upper_bound(::Type{ConverterCurrent}, d::PSY.InterconnectingConverter, ::Type{<:AbstractConverterFormulation}) = PSY.get_max_dc_current(d)
get_variable_upper_bound(::Type{ConverterPositiveCurrent}, d::PSY.InterconnectingConverter,::Type{<:AbstractConverterFormulation}) = PSY.get_max_dc_current(d)
get_variable_upper_bound(::Type{ConverterNegativeCurrent}, d::PSY.InterconnectingConverter,::Type{<:AbstractConverterFormulation}) = PSY.get_max_dc_current(d)


function get_default_attributes(
    ::Type{PSY.InterconnectingConverter},
    ::Type{Bin2QuadraticLossConverter},
)
    return Dict{String, Any}(
        "use_linear_loss" => true
    )
end

function get_default_attributes(
    ::Type{PSY.InterconnectingConverter},
    ::Type{QuadraticLossConverter},
)
    return Dict{String, Any}(
        "use_linear_loss" => false,
    )
end

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

# Builds, per converter, an AffExpr container of the DC-bus voltage variable indexed
# by converter name. IOM bilinear/quadratic approximations consume an x_var indexed by
# component name; DCVoltage is stored per DC bus, so we wrap it for compatibility.
function _voltage_expr_per_converter(
    container::OptimizationContainer,
    devices,
    ipc_names::Vector{String},
    time_steps,
)
    v_var = get_variable(container, DCVoltage, PSY.DCBus)
    v_expr = JuMP.Containers.DenseAxisArray{JuMP.AffExpr}(undef, ipc_names, time_steps)
    for d in devices
        name = PSY.get_name(d)
        dc_bus_name = PSY.get_name(PSY.get_dc_bus(d))
        for t in time_steps
            ae = JuMP.AffExpr(0.0)
            add_proportional_to_jump_expression!(ae, v_var[dc_bus_name, t], 1.0)
            v_expr[name, t] = ae
        end
    end
    return v_expr
end

function _converter_vi_bounds(devices)
    n = length(devices)
    v_bounds = Vector{IOM.MinMax}(undef, n)
    i_bounds = Vector{IOM.MinMax}(undef, n)
    for (k, d) in enumerate(devices)
        v_min, v_max = PSY.get_voltage_limits(PSY.get_dc_bus(d))
        i_max = PSY.get_max_dc_current(d)
        v_bounds[k] = IOM.MinMax((min = v_min, max = v_max))
        i_bounds[k] = IOM.MinMax((min = -i_max, max = i_max))
    end
    return v_bounds, i_bounds
end

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
    _add_converter_loss_constraint!(
        container, devices, model;
        use_linear_loss = get_attribute(model, "use_linear_loss"),
    )
    return
end

function _add_converter_loss_constraint!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{U},
    model::DeviceModel{U, V};
    use_linear_loss::Bool,
) where {
    U <: PSY.InterconnectingConverter,
    V <: AbstractQuadraticLossConverter,
}
    time_steps = get_time_steps(container)
    P_ac_var = get_variable(container, ActivePowerVariable, U)
    vi_expr = get_expression(container, IOM.BilinearProductExpression, U, "vi")
    i_sq_expr = get_expression(container, IOM.QuadraticExpression, U, "i_sq")
    if use_linear_loss
        i_pos_var = get_variable(container, ConverterPositiveCurrent, U)
        i_neg_var = get_variable(container, ConverterNegativeCurrent, U)
    end

    ipc_names = [PSY.get_name(d) for d in devices]
    loss_const = add_constraints_container!(
        container, ConverterLossConstraint, U, ipc_names, time_steps,
    )

    jump_model = get_jump_model(container)
    for device in devices
        name = PSY.get_name(device)
        loss_function = PSY.get_loss_function(device)
        if isa(loss_function, PSY.QuadraticCurve)
            a = PSY.get_quadratic_term(loss_function)
            b = PSY.get_proportional_term(loss_function)
            c = PSY.get_constant_term(loss_function)
        else
            a = 0.0
            b = PSY.get_proportional_term(loss_function)
            c = PSY.get_constant_term(loss_function)
        end
        for t in time_steps
            loss = a * i_sq_expr[name, t] + c
            if use_linear_loss
                loss += b * (i_pos_var[name, t] + i_neg_var[name, t])
            end
            loss_const[name, t] = JuMP.@constraint(
                jump_model,
                P_ac_var[name, t] == vi_expr[name, t] - loss
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, V},
    ::NetworkModel{<:AbstractPowerModel},
) where {
    T <: CurrentAbsoluteValueConstraint,
    U <: PSY.InterconnectingConverter,
    V <: AbstractQuadraticLossConverter,
}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    jump_model = get_jump_model(container)
    i_var = get_variable(container, ConverterCurrent, U)
    i_pos_var = get_variable(container, ConverterPositiveCurrent, U)
    i_neg_var = get_variable(container, ConverterNegativeCurrent, U)
    i_dir_var = get_variable(container, ConverterCurrentDirection, U)

    abs_val_const = add_constraints_container!(
        container, CurrentAbsoluteValueConstraint, U, names, time_steps,
    )
    pos_ub_const = add_constraints_container!(
        container, CurrentAbsoluteValueConstraint, U, names, time_steps;
        meta = "pos_ub",
    )
    neg_ub_const = add_constraints_container!(
        container, CurrentAbsoluteValueConstraint, U, names, time_steps;
        meta = "neg_ub",
    )

    for d in devices
        name = PSY.get_name(d)
        i_max = PSY.get_max_dc_current(d)
        for t in time_steps
            abs_val_const[name, t] = JuMP.@constraint(
                jump_model,
                i_var[name, t] == i_pos_var[name, t] - i_neg_var[name, t]
            )
            pos_ub_const[name, t] = JuMP.@constraint(
                jump_model,
                i_pos_var[name, t] <= i_max * i_dir_var[name, t]
            )
            neg_ub_const[name, t] = JuMP.@constraint(
                jump_model,
                i_neg_var[name, t] <= i_max * (1 - i_dir_var[name, t])
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
