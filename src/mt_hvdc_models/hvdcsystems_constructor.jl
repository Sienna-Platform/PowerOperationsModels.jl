function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{PSY.InterconnectingConverter, LosslessConverter},
    network_model::NetworkModel{<:AbstractActivePowerModel},
)
    devices = get_available_components(
        model,
        sys,
    )
    add_variables!(container, ActivePowerVariable, devices, LosslessConverter)
    add_to_expression!(
        container,
        ActivePowerBalance,
        ActivePowerVariable,
        devices,
        model,
        network_model,
    )
    add_feedforward_arguments!(container, model, devices)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{PSY.InterconnectingConverter, LosslessConverter},
    network_model::NetworkModel{<:AbstractActivePowerModel},
)
    devices = get_available_components(
        model,
        sys,
    )
    add_feedforward_constraints!(container, model, devices)
    add_to_objective_function!(
        container,
        devices,
        model,
        get_network_formulation(network_model),
    )
    add_constraint_dual!(container, sys, model)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{PSY.InterconnectingConverter, T},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {T <: AbstractQuadraticLossConverter}
    devices = get_available_components(model, sys)
    add_variables!(container, ActivePowerVariable, devices, T)
    add_variables!(container, ConverterCurrent, devices, T)
    if get_attribute(model, "use_linear_loss")
        add_variables!(container, ConverterPositiveCurrent, devices, T)
        add_variables!(container, ConverterNegativeCurrent, devices, T)
        add_variables!(container, ConverterCurrentDirection, devices, T)
    end

    add_to_expression!(
        container, ActivePowerBalance, ActivePowerVariable,
        devices, model, network_model,
    )
    add_to_expression!(
        container, DCCurrentBalance, ConverterCurrent,
        devices, model, network_model,
    )
    add_feedforward_arguments!(container, model, devices)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{PSY.InterconnectingConverter, Bin2QuadraticLossConverter},
    network_model::NetworkModel{<:AbstractActivePowerModel},
)
    devices = get_available_components(model, sys)
    time_steps = get_time_steps(container)
    ipc_names = [PSY.get_name(d) for d in devices]
    v_bounds, i_bounds = _converter_vi_bounds(devices)
    v_expr = _voltage_expr_per_converter(container, devices, ipc_names, time_steps)
    i_var = get_variable(container, ConverterCurrent, PSY.InterconnectingConverter)

    v_sq_expr = IOM._add_quadratic_approx!(
        IOM.ManualSOS2QuadConfig(IOM.DEFAULT_INTERPOLATION_LENGTH),
        container, PSY.InterconnectingConverter,
        ipc_names, time_steps,
        v_expr, v_bounds,
        "v_sq",
    )
    i_sq_expr = IOM._add_quadratic_approx!(
        IOM.ManualSOS2QuadConfig(IOM.DEFAULT_INTERPOLATION_LENGTH),
        container, PSY.InterconnectingConverter,
        ipc_names, time_steps,
        i_var, i_bounds,
        "i_sq",
    )
    IOM._add_bilinear_approx!(
        IOM.Bin2Config(IOM.ManualSOS2QuadConfig(IOM.DEFAULT_INTERPOLATION_LENGTH)),
        container, PSY.InterconnectingConverter,
        ipc_names, time_steps,
        v_sq_expr, i_sq_expr,
        v_expr, i_var,
        v_bounds, i_bounds,
        "vi",
    )

    add_constraints!(container, ConverterLossConstraint, devices, model, network_model)
    add_constraints!(
        container,
        CurrentAbsoluteValueConstraint,
        devices,
        model,
        network_model,
    )

    add_feedforward_constraints!(container, model, devices)
    add_to_objective_function!(
        container, devices, model, get_network_formulation(network_model),
    )
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{PSY.InterconnectingConverter, QuadraticLossConverter},
    network_model::NetworkModel{<:AbstractActivePowerModel},
)
    devices = get_available_components(model, sys)
    time_steps = get_time_steps(container)
    ipc_names = [PSY.get_name(d) for d in devices]
    v_bounds, i_bounds = _converter_vi_bounds(devices)
    v_expr = _voltage_expr_per_converter(container, devices, ipc_names, time_steps)
    i_var = get_variable(container, ConverterCurrent, PSY.InterconnectingConverter)

    IOM._add_quadratic_approx!(
        IOM.NoQuadApproxConfig(),
        container, PSY.InterconnectingConverter,
        ipc_names, time_steps,
        i_var, i_bounds,
        "i_sq",
    )
    IOM._add_bilinear_approx!(
        IOM.NoBilinearApproxConfig(),
        container, PSY.InterconnectingConverter,
        ipc_names, time_steps,
        v_expr, i_var,
        v_bounds, i_bounds,
        "vi",
    )

    add_constraints!(container, ConverterLossConstraint, devices, model, network_model)
    if get_attribute(model, "use_linear_loss")
        add_constraints!(
            container,
            CurrentAbsoluteValueConstraint,
            devices,
            model,
            network_model,
        )
    end

    add_feedforward_constraints!(container, model, devices)
    add_to_objective_function!(
        container, devices, model, get_network_formulation(network_model),
    )
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{PSY.TModelHVDCLine, LosslessLine},
    network_model::NetworkModel{<:AbstractActivePowerModel},
)
    devices = get_available_components(
        model,
        sys,
    )
    add_variables!(container, FlowActivePowerVariable, devices, LosslessLine)
    add_to_expression!(
        container,
        ActivePowerBalance,
        FlowActivePowerVariable,
        devices,
        model,
        network_model,
    )
    add_feedforward_arguments!(container, model, devices)
    return
end

function construct_device!(
    ::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{PSY.TModelHVDCLine, LosslessLine},
    ::NetworkModel{<:AbstractActivePowerModel},
)
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::DeviceModel{PSY.TModelHVDCLine, DCLossyLine},
    network_model::NetworkModel{<:AbstractActivePowerModel},
)
    devices = get_available_components(
        model,
        sys,
    )

    add_variables!(container, DCLineCurrent, devices, DCLossyLine)
    add_to_expression!(
        container,
        DCCurrentBalance,
        DCLineCurrent,
        devices,
        model,
        network_model,
    )
    add_feedforward_arguments!(container, model, devices)
    return
end

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{PSY.TModelHVDCLine, DCLossyLine},
    network_model::NetworkModel{<:AbstractActivePowerModel},
)
    devices = get_available_components(
        model,
        sys,
    )
    add_constraints!(
        container,
        DCLineCurrentConstraint,
        devices,
        model,
        network_model,
    )
end
