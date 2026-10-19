#! format: off
get_variable_multiplier(::Type{<:VariableType}, ::Type{<:PSY.RenewableGen}, ::Type{<:AbstractRenewableFormulation}) = 1.0
get_expression_type_for_reserve(::Type{ActivePowerReserveVariable}, ::Type{<:PSY.RenewableGen}, ::Type{<:PSY.Reserve{PSY.ReserveUp}}) = ActivePowerRangeExpressionUB
get_expression_type_for_reserve(::Type{ActivePowerReserveVariable}, ::Type{<:PSY.RenewableGen}, ::Type{<:PSY.Reserve{PSY.ReserveDown}}) = ActivePowerRangeExpressionLB
# OfflineReserve (non-spin) is upward-only, so it reduces upward headroom like a ReserveUp product.
get_expression_type_for_reserve(::Type{ActivePowerReserveVariable}, ::Type{<:PSY.RenewableGen}, ::Type{<:PSY.OfflineReserve}) = ActivePowerRangeExpressionUB
########################### Parameter related set functions ################################
get_parameter_multiplier(::Type{<:VariableValueParameter}, d::PSY.RenewableGen, ::Type{<:AbstractRenewableFormulation}) = 1.0
########################### ActivePowerVariable, RenewableGen #################################

get_variable_binary(::Type{ActivePowerVariable}, ::Type{<:PSY.RenewableGen}, ::Type{<:AbstractRenewableFormulation}) = false
get_min_max_limits(d::PSY.RenewableGen, ::Type{ActivePowerVariableLimitsConstraint}, ::Type{<:AbstractRenewableFormulation}) = (min = 0.0, max = PSY.get_max_active_power(d, u"SU"))
get_variable_lower_bound(::Type{ActivePowerVariable}, d::PSY.RenewableGen, ::Type{<:AbstractRenewableFormulation}) = 0.0
get_variable_upper_bound(::Type{ActivePowerVariable}, d::PSY.RenewableGen, ::Type{<:AbstractRenewableFormulation}) = PSY.get_max_active_power(d, u"SU")

########################### ReactivePowerVariable, RenewableGen #################################

get_variable_binary(::Type{ReactivePowerVariable}, ::Type{<:PSY.RenewableGen}, ::Type{<:AbstractRenewableFormulation}) = false

get_multiplier_value(::Type{<:TimeSeriesParameter}, d::PSY.RenewableGen, ::Type{FixedOutput}) = PSY.get_max_active_power(d, u"SU")
# The default reactive series is the normalized active-power profile, so scale by
# Q/P = tan(acos(pf)). A user-mapped reactive series is rescaled in
# `_reactive_power_series_devices!`.
get_multiplier_value(::Type{ReactivePowerTimeSeriesParameter}, d::PSY.RenewableGen, ::Type{FixedOutput}) = PSY.get_max_active_power(d, u"SU") * tan(acos(PSY.get_power_factor(d)))
get_multiplier_value(::Type{<:TimeSeriesParameter}, d::PSY.RenewableGen, ::Type{<:AbstractRenewableFormulation}) = PSY.get_max_active_power(d, u"SU")

# To avoid ambiguity with default_interface_methods.jl:
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::PSY.RenewableGen, ::Type{FixedOutput}) = 1.0
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::PSY.RenewableGen, ::Type{<:AbstractRenewableFormulation}) = 1.0

########################Objective Function##################################################
objective_function_multiplier(::Type{ActivePowerVariable}, ::Type{<:AbstractRenewableDispatchFormulation})=OBJECTIVE_FUNCTION_POSITIVE
#! format: on

get_initial_conditions_device_model(
    ::IOM.AbstractOptimizationModel,
    ::DeviceModel{T, <:AbstractRenewableFormulation},
) where {T <: PSY.RenewableGen} = DeviceModel(T, RenewableFullDispatch)

get_initial_conditions_device_model(
    ::IOM.AbstractOptimizationModel,
    ::DeviceModel{T, FixedOutput},
) where {T <: PSY.RenewableGen} = DeviceModel(T, FixedOutput)

function get_min_max_limits(
    device::PSY.RenewableGen,
    ::Type{ReactivePowerVariableLimitsConstraint},
    ::Type{<:AbstractRenewableFormulation},
)
    return PSY.get_reactive_power_limits(device, u"SU")
end

function get_default_time_series_names(
    ::Type{<:PSY.RenewableGen},
    ::Type{<:Union{FixedOutput, AbstractRenewableFormulation}},
)
    return Dict{Type{<:TimeSeriesParameter}, String}(
        ActivePowerTimeSeriesParameter => "max_active_power",
        ReactivePowerTimeSeriesParameter => "max_active_power",
    )
end

function get_default_attributes(
    ::Type{<:PSY.RenewableGen},
    ::Type{<:Union{FixedOutput, AbstractRenewableFormulation}},
)
    return Dict{String, Any}(RELAX_BINARIES_ATTRIBUTE => false)
end

####################################### Reactive Power constraint_infos #########################

function add_constraints!(
    container::OptimizationContainer,
    T::Type{<:ReactivePowerVariableLimitsConstraint},
    U::Type{<:ReactivePowerVariable},
    devices::Vector{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.RenewableGen, W <: AbstractDeviceFormulation, X <: AbstractNetworkModel}
    add_range_constraints!(container, T, U, devices, model, X)
    return
end

"""
Reactive Power Constraints on Renewable Gen Constant power_factor
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{<:ReactivePowerVariableLimitsConstraint},
    ::Type{<:ReactivePowerVariable},
    devices::Vector{V},
    ::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    V <: PSY.RenewableGen,
    W <: RenewableConstantPowerFactor,
    X <: AbstractNetworkModel,
}
    names = PSY.get_name.(devices)
    time_steps = get_time_steps(container)
    p_var = get_variable(container, ActivePowerVariable, V)
    q_var = get_variable(container, ReactivePowerVariable, V)
    jump_model = get_jump_model(container)
    constraint =
        add_constraints_container!(container, EqualityConstraint, V, names, time_steps)
    for t in time_steps, d in devices
        name = PSY.get_name(d)
        q_to_p = tan(acos(PSY.get_power_factor(d)))
        constraint[name, t] =
            JuMP.@constraint(jump_model, q_var[name, t] == p_var[name, t] * q_to_p)
    end
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{ActivePowerVariableLimitsConstraint},
    U::Type{<:Union{VariableType, ActivePowerRangeExpressionUB}},
    devices::Vector{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    V <: PSY.RenewableGen,
    W <: AbstractRenewableDispatchFormulation,
    X <: AbstractNetworkModel,
}
    add_parameterized_upper_bound_range_constraints(
        container,
        ActivePowerVariableTimeSeriesLimitsConstraint,
        U,
        ActivePowerTimeSeriesParameter,
        devices,
        model,
        X,
    )
    return
end

function add_constraints!(
    container::OptimizationContainer,
    T::Type{ActivePowerVariableLimitsConstraint},
    U::Type{ActivePowerRangeExpressionLB},
    devices::Vector{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {
    V <: PSY.RenewableGen,
    W <: AbstractRenewableDispatchFormulation,
    X <: AbstractNetworkModel,
}
    add_range_constraints!(
        container,
        T,
        U,
        devices,
        model,
        X,
    )
    return
end

##################################### renewable generation cost ############################
function add_to_objective_function!(
    container::OptimizationContainer,
    devices::Vector{T},
    ::DeviceModel{T, U},
    ::Type{<:AbstractNetworkModel},
) where {T <: PSY.RenewableGen, U <: AbstractRenewableDispatchFormulation}
    add_variable_cost!(container, ActivePowerVariable, devices, U)
    add_curtailment_cost!(container, ActivePowerVariable, devices, U)
    return
end

"""
A `FixedOutput` renewable reads its reactive parameter from the active-power profile by
default, holding its power factor. When `time_series_names` maps a different reactive series,
scale it by the max reactive power instead, and warn about devices that lack that series:
they get no reactive parameter, so they inject no reactive power. Returns the devices that
have a reactive parameter.
"""
function _reactive_power_series_devices!(
    container::OptimizationContainer,
    devices::Vector{V},
    model::DeviceModel{V, FixedOutput},
) where {V <: PSY.RenewableGen}
    ts_names = get_time_series_names(model)
    ts_name = ts_names[ReactivePowerTimeSeriesParameter]
    ts_name == get(ts_names, ActivePowerTimeSeriesParameter, nothing) && return devices
    multiplier =
        get_parameter_multiplier_array(container, ReactivePowerTimeSeriesParameter, V)
    names_with_series = Set(axes(multiplier)[1])
    with_series = filter(d -> PSY.get_name(d) in names_with_series, devices)
    for d in with_series
        multiplier[PSY.get_name(d), :] .= PSY.get_reactive_power_limits(d, u"SU").max
    end
    if length(with_series) < length(devices)
        missing_names = setdiff(PSY.get_name.(devices), names_with_series)
        @warn "$(nameof(V)) devices $(missing_names) lack the reactive power time series \
               $(ts_name): they inject no reactive power."
    end
    return with_series
end
