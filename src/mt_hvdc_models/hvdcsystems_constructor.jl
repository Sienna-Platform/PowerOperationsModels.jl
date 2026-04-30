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
    if _use_linear_loss(T, model)
        ll_devices = _devices_with_linear_loss(devices)
        if isempty(ll_devices)
            @warn "use_linear_loss is enabled but every InterconnectingConverter has a zero proportional loss term; no linear-loss variables/constraints will be added."
        else
            add_variables!(container, ConverterPositiveCurrent, ll_devices, T)
            add_variables!(container, ConverterNegativeCurrent, ll_devices, T)
            add_variables!(container, ConverterCurrentDirection, ll_devices, T)
        end
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

 function _voltage_expr_per_converter(
     container::OptimizationContainer,
     devices,
     ipc_names::Vector{String},
     time_steps,
 )
     v_var = get_variable(container, DCVoltage, PSY.DCBus)
     bus_names = [PSY.get_name(PSY.get_dc_bus(d)) for d in devices]
     return JuMP.Containers.DenseAxisArray(
         [v_var[b, t] for b in bus_names, t in time_steps],
         ipc_names, time_steps,
     )
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

_quad_config(::Type{Bin2QuadraticLossConverter}) = IOM.SolverSOS2QuadConfig(DEFAULT_INTERPOLATION_LENGTH)
_quad_config(::Type{QuadraticLossConverter}) = IOM.NoQuadApproxConfig()
_bilinear_config(::Type{Bin2QuadraticLossConverter}) = IOM.Bin2Config(IOM.SolverSOS2QuadConfig(DEFAULT_INTERPOLATION_LENGTH))
_bilinear_config(::Type{QuadraticLossConverter}) = IOM.NoBilinearApproxConfig()

function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::DeviceModel{PSY.InterconnectingConverter, T},
    network_model::NetworkModel{<:AbstractActivePowerModel},
) where {T <: AbstractQuadraticLossConverter}
    devices = get_available_components(model, sys)
    time_steps = get_time_steps(container)
    ipc_names = [PSY.get_name(d) for d in devices]
    v_bounds, i_bounds = _converter_vi_bounds(devices)
    v_expr = _voltage_expr_per_converter(container, devices, ipc_names, time_steps)
    i_var = get_variable(container, ConverterCurrent, PSY.InterconnectingConverter)

    quad_cfg, bilin_cfg = _quad_config(T), _bilinear_config(T)
    v_sq_expr = IOM._add_quadratic_approx!(
        quad_cfg,
        container, PSY.InterconnectingConverter,
        ipc_names, time_steps,
        v_expr, v_bounds,
        "v_sq",
    )
    i_sq_expr = IOM._add_quadratic_approx!(
        quad_cfg,
        container, PSY.InterconnectingConverter,
        ipc_names, time_steps,
        i_var, i_bounds,
        "i_sq",
    )
    IOM._add_bilinear_approx!(
        bilin_cfg,
        container, PSY.InterconnectingConverter,
        ipc_names, time_steps,
        v_sq_expr, i_sq_expr,
        v_expr, i_var,
        v_bounds, i_bounds,
        "vi",
    )

    add_constraints!(container, ConverterLossConstraint, devices, model, network_model)
    if _use_linear_loss(T, model)
        ll_devices = _devices_with_linear_loss(devices)
        if !isempty(ll_devices)
            add_constraints!(
                container,
                CurrentAbsoluteValueConstraint,
                ll_devices,
                model,
                network_model,
            )
        end
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
