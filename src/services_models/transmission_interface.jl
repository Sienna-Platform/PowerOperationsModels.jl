#! format: off
get_variable_binary(::Type{<:VariableType}, ::Type{PSY.TransmissionInterface}, ::Type{MaxInterfaceFlow}) = false
get_variable_lower_bound(::Type{InterfaceFlowSlackUp}, ::PSY.TransmissionInterface, ::Type{MaxInterfaceFlow}) = 0.0
get_variable_lower_bound(::Type{InterfaceFlowSlackDown}, ::PSY.TransmissionInterface, ::Type{MaxInterfaceFlow}) = 0.0

get_variable_multiplier(::Type{InterfaceFlowSlackUp}, ::Type{PSY.TransmissionInterface}, ::Type{MaxInterfaceFlow}) = 1.0
get_variable_multiplier(::Type{InterfaceFlowSlackDown}, ::Type{PSY.TransmissionInterface}, ::Type{MaxInterfaceFlow}) = -1.0

get_multiplier_value(::Type{MinInterfaceFlowLimitParameter}, d::PSY.TransmissionInterface, ::Type{MaxInterfaceFlow}) = PSY.get_min_active_power_flow_limit(d, u"SU")
get_multiplier_value(::Type{MaxInterfaceFlowLimitParameter}, d::PSY.TransmissionInterface, ::Type{MaxInterfaceFlow}) = PSY.get_max_active_power_flow_limit(d, u"SU")

#! format: On
function get_default_time_series_names(
    ::Type{PSY.TransmissionInterface},
    ::Type{MaxInterfaceFlow},
)
    return Dict{Type{<:TimeSeriesParameter}, String}(
        MinInterfaceFlowLimitParameter => "min_active_power_flow_limit",
        MaxInterfaceFlowLimitParameter => "max_active_power_flow_limit",
    )
end

function get_default_attributes(
    ::Type{<:PSY.TransmissionInterface},
    ::Type{MaxInterfaceFlow})
    return Dict{String, Any}()
end

function get_initial_conditions_service_model(
    ::IOM.AbstractOptimizationModel,
    model::ServiceModel{T, MaxInterfaceFlow},
) where {T <: PSY.TransmissionInterface}
    return ServiceModel(T, MaxInterfaceFlow; time_series_names = get_time_series_names(model))
end

# `add_parameters!` errors on a service without the time series, so filter first.
function _add_interface_limit_parameters!(
    container::OptimizationContainer,
    ::Type{P},
    interfaces::Vector{T},
    model::ServiceModel{T, MaxInterfaceFlow},
) where {P <: TimeSeriesParameter, T <: PSY.TransmissionInterface}
    ts_names = get_time_series_names(model)
    haskey(ts_names, P) || return
    ts_type = get_default_time_series_type(container)
    with_ts = filter(d -> _has_interface_limit_series(d, ts_type, ts_names[P]), interfaces)
    isempty(with_ts) || add_parameters!(container, P, with_ts, model)
    return
end

# A limit series of another type would otherwise fall back to the static limit silently.
function _has_interface_limit_series(
    interface::PSY.TransmissionInterface,
    ts_type::Type{<:IS.TimeSeriesData},
    ts_name::String,
)
    PSY.has_time_series(interface, ts_type, ts_name) && return true
    metadata = IS.list_time_series_metadata(interface; name = ts_name)
    isempty(metadata) && return false
    found = join(unique(nameof.(IS.get_time_series_type.(metadata))), ", ")
    throw(
        IS.ConflictingInputsError(
            "TransmissionInterface $(PSY.get_name(interface)) carries a $(ts_name) time \
            series as $(found), but this model reads $(nameof(ts_type)).",
        ),
    )
end

function _has_interface_limit_parameter(
    container::OptimizationContainer,
    ::Type{P},
    ::Type{T},
    name::String,
) where {P <: TimeSeriesParameter, T <: PSY.TransmissionInterface}
    has_container_key(container, P, T) || return false
    return name in axes(get_multiplier_array(get_parameter(container, P, T)), 1)
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{InterfaceFlowLimit},
    interface::T,
    model::ServiceModel{T, MaxInterfaceFlow},
) where {T <: PSY.TransmissionInterface}
    expr = get_expression(container, InterfaceTotalFlow, T)
    interfaces, time_steps = axes(expr)
    constraint_container_ub = lazy_container_addition!(container, InterfaceFlowLimit,
        T,
        interfaces,
        time_steps;
        meta = "ub",
    )
    constraint_container_lb = lazy_container_addition!(container, InterfaceFlowLimit,
        T,
        interfaces,
        time_steps;
        meta = "lb",
    )
    int_name = PSY.get_name(interface)
    min_flow, max_flow = PSY.get_active_power_flow_limits(interface, u"SU")
    jump_model = get_jump_model(container)
    if _has_interface_limit_parameter(container, MaxInterfaceFlowLimitParameter, T, int_name)
        param_container = get_parameter(container, MaxInterfaceFlowLimitParameter, T)
        param = get_parameter_column_refs(param_container, int_name)
        mult = get_multiplier_array(param_container)
        for t in time_steps
            constraint_container_ub[int_name, t] = JuMP.@constraint(
                jump_model,
                expr[int_name, t] <= mult[int_name, t] * param[t]
            )
        end
    else
        for t in time_steps
            constraint_container_ub[int_name, t] =
                JuMP.@constraint(jump_model, expr[int_name, t] <= max_flow)
        end
    end
    if _has_interface_limit_parameter(container, MinInterfaceFlowLimitParameter, T, int_name)
        param_container = get_parameter(container, MinInterfaceFlowLimitParameter, T)
        param = get_parameter_column_refs(param_container, int_name)
        mult = get_multiplier_array(param_container)
        for t in time_steps
            constraint_container_lb[int_name, t] = JuMP.@constraint(
                jump_model,
                expr[int_name, t] >= mult[int_name, t] * param[t]
            )
        end
    else
        for t in time_steps
            constraint_container_lb[int_name, t] =
                JuMP.@constraint(jump_model, expr[int_name, t] >= min_flow)
        end
    end
    return
end

function add_to_objective_function!(
    container::OptimizationContainer,
    service::T,
    model::ServiceModel{T, U},
) where {T <: PSY.TransmissionInterface, U <: MaxInterfaceFlow}
    # At the moment the interfaces have no costs associated with them
    return
end
