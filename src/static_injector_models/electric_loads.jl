#! format: off
########################### ElectricLoad ####################################

get_variable_multiplier(::Type{<:VariableType}, ::Type{<:PSY.ElectricLoad}, ::Type{<:AbstractLoadFormulation}) = -1.0

########################### ActivePowerVariable, ElectricLoad ####################################

get_variable_binary(::Type{ActivePowerVariable}, ::Type{<:PSY.ElectricLoad}, ::Type{<:AbstractLoadFormulation}) = false
get_variable_lower_bound(::Type{ActivePowerVariable}, d::PSY.ElectricLoad, ::Type{<:AbstractLoadFormulation}) = 0.0
get_variable_upper_bound(::Type{ActivePowerVariable}, d::PSY.ElectricLoad, ::Type{<:AbstractLoadFormulation}) = PSY.get_max_active_power(d)

########################### ReactivePowerVariable, ElectricLoad ####################################

get_variable_binary(::Type{ReactivePowerVariable}, ::Type{<:PSY.ElectricLoad}, ::Type{<:AbstractLoadFormulation}) = false

get_variable_lower_bound(::Type{ReactivePowerVariable}, d::PSY.ElectricLoad, ::Type{<:AbstractLoadFormulation}) = 0.0
get_variable_upper_bound(::Type{ReactivePowerVariable}, d::PSY.ElectricLoad, ::Type{<:AbstractLoadFormulation}) = PSY.get_max_reactive_power(d)

########################### ReactivePowerVariable, ElectricLoad ####################################

get_variable_binary(::Type{OnVariable}, ::Type{<:PSY.ElectricLoad}, ::Type{<:AbstractLoadFormulation}) = true

get_multiplier_value(::Type{<:TimeSeriesParameter}, d::PSY.ElectricLoad, ::Type{StaticPowerLoad}) = -1*PSY.get_max_active_power(d)
get_multiplier_value(::Type{ReactivePowerTimeSeriesParameter}, d::PSY.ElectricLoad, ::Type{StaticPowerLoad}) = -1*PSY.get_max_reactive_power(d)
get_multiplier_value(::Type{<:TimeSeriesParameter}, d::PSY.ElectricLoad, ::Type{<:AbstractControllablePowerLoadFormulation}) = PSY.get_max_active_power(d)

# To avoid ambiguity with default_interface_methods.jl:
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::PSY.ElectricLoad, ::Type{StaticPowerLoad}) = 1.0
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::PSY.ElectricLoad, ::Type{<:AbstractControllablePowerLoadFormulation}) = 1.0


########################Objective Function##################################################
proportional_cost(cost::Nothing, ::Type{OnVariable}, ::PSY.ElectricLoad, ::Type{<:AbstractControllablePowerLoadFormulation})=1.0
proportional_cost(cost::PSY.OperationalCost, ::Type{OnVariable}, ::PSY.ElectricLoad, ::Type{<:AbstractControllablePowerLoadFormulation})=PSY.get_fixed(cost)

objective_function_multiplier(::Type{<:VariableType}, ::Type{<:AbstractControllablePowerLoadFormulation})=OBJECTIVE_FUNCTION_NEGATIVE

#! format: on

# proportional cost: connects to common implementation in IOM
# see also the definition in thermal_generation.jl
add_proportional_cost!(
    container::OptimizationContainer,
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{T},
    ::Type{PowerLoadInterruption},
) where {U <: OnVariable, T <: PSY.ControllableLoad} =
    add_proportional_cost_maybe_time_variant!(
        container,
        U,
        devices,
        PowerLoadInterruption,
    )

function get_default_time_series_names(
    ::Type{<:PSY.ElectricLoad},
    ::Type{<:Union{FixedOutput, AbstractLoadFormulation}},
)
    return Dict{Type{<:TimeSeriesParameter}, String}(
        ActivePowerTimeSeriesParameter => "max_active_power",
        ReactivePowerTimeSeriesParameter => "max_active_power",
    )
end

function get_default_attributes(
    ::Type{U},
    ::Type{V},
) where {U <: PSY.ElectricLoad, V <: Union{FixedOutput, AbstractLoadFormulation}}
    return Dict{String, Any}()
end

get_initial_conditions_device_model(
    ::OperationModel,
    ::DeviceModel{T, <:AbstractLoadFormulation},
) where {T <: PSY.ElectricLoad} = DeviceModel(T, StaticPowerLoad)

function get_default_time_series_names(
    ::Type{<:PSY.MotorLoad},
    ::Type{<:Union{FixedOutput, AbstractLoadFormulation}},
)
    return Dict{Type{<:TimeSeriesParameter}, String}()
end

####################################### Reactive Power Constraints #########################
"""
Reactive Power Constraints on Controllable Loads Assume Constant power_factor
"""
function add_constraints!(
    container::OptimizationContainer,
    T::Type{<:ReactivePowerVariableLimitsConstraint},
    U::Type{<:ReactivePowerVariable},
    devices::IS.FlattenIteratorWrapper{V},
    ::DeviceModel{V, W},
    network_model::NetworkModel{X},
) where {
    V <: PSY.ElectricLoad,
    W <: AbstractControllablePowerLoadFormulation,
    X <: AbstractPowerModel,
}
    time_steps = get_time_steps(container)
    constraint = add_constraints_container!(container, T,
        V,
        PSY.get_name.(devices),
        time_steps,
    )
    jump_model = get_jump_model(container)
    for t in time_steps, d in devices
        name = PSY.get_name(d)
        pf = sin(atan((PSY.get_max_reactive_power(d) / PSY.get_max_active_power(d))))
        reactive = get_variable(container, U, V)[name, t]
        real = get_variable(container, ActivePowerVariable, V)[name, t]
        constraint[name, t] = JuMP.@constraint(jump_model, reactive == real * pf)
    end
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{ActivePowerVariableLimitsConstraint},
    U::Type{<:VariableType},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.ControllableLoad, W <: PowerLoadDispatch, X <: AbstractPowerModel}
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
    U::Type{<:VariableType},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.ControllableLoad, W <: PowerLoadInterruption, X <: AbstractPowerModel}
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
    U::Type{OnVariable},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.ControllableLoad, W <: PowerLoadInterruption, X <: AbstractPowerModel}
    time_steps = get_time_steps(container)
    constraint = add_constraints_container!(container, T,
        V,
        PSY.get_name.(devices),
        time_steps;
        meta = "binary",
    )
    on_variable = get_variable(container, U, V)
    power = get_variable(container, ActivePowerVariable, V)
    jump_model = get_jump_model(container)
    for t in time_steps, d in devices
        name = PSY.get_name(d)
        pmax = PSY.get_max_active_power(d)
        constraint[name, t] =
            JuMP.@constraint(jump_model, power[name, t] <= on_variable[name, t] * pmax)
    end
    return
end

############################## FormulationControllable Load Cost ###########################
function add_to_objective_function!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, U},
    ::Type{<:AbstractPowerModel},
) where {T <: PSY.ControllableLoad, U <: PowerLoadDispatch}
    add_variable_cost!(container, ActivePowerVariable, devices, U)
    return
end

function add_to_objective_function!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, U},
    ::Type{<:AbstractPowerModel},
) where {T <: PSY.ControllableLoad, U <: PowerLoadInterruption}
    add_variable_cost!(container, ActivePowerVariable, devices, U)
    add_proportional_cost!(container, OnVariable, devices, U)
    return
end

# code repetition: basically copy-paste from thermal_generation.jl, just change types
# and incremental to decremental.
function proportional_cost(
    container::OptimizationContainer,
    cost::PSY.LoadCost,
    S::Type{OnVariable},
    T::PSY.ControllableLoad,
    U::Type{PowerLoadInterruption},
    t::Int,
)
    return onvar_cost(container, cost, S, T, U, t) +
           PSY.get_constant_term(PSY.get_vom_cost(PSY.get_variable(cost))) +
           PSY.get_fixed(cost)
end

function onvar_cost(
    container::OptimizationContainer,
    cost::PSY.LoadCost,
    ::Type{OnVariable},
    d::PSY.ControllableLoad,
    ::Type{PowerLoadInterruption},
    t::Int,
)
    return _onvar_cost(container, PSY.get_variable(cost), d, t)
end

# LoadCost has no FuelCurve-backed `_onvar_cost` path; the OnVariable proportional
# term's rate (vom_constant + fixed + onvar_cost) is always static here.
IOM.is_time_variant_proportional(::PSY.LoadCost) = false

# MarketBidCost (static + time-series) proportional_cost/is_time_variant_proportional are generic —
# see common_models/market_bid_overrides.jl.
