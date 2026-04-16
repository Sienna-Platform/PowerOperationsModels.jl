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

########################### ShiftablePowerLoad #####################################

get_variable_binary(::ShiftUpActivePowerVariable, ::Type{<:PSY.ElectricLoad}, ::PowerLoadShift) = false
get_variable_lower_bound(::ShiftUpActivePowerVariable, d::PSY.ElectricLoad, ::PowerLoadShift) = 0.0
get_variable_upper_bound(::ShiftUpActivePowerVariable, d::PSY.ElectricLoad, ::PowerLoadShift) = nothing # Unbounded above by default, but can be limited by time series parameters

get_variable_binary(::ShiftDownActivePowerVariable, ::Type{<:PSY.ElectricLoad}, ::PowerLoadShift) = false
get_variable_lower_bound(::ShiftDownActivePowerVariable, d::PSY.ElectricLoad, ::PowerLoadShift) = 0.0
get_variable_upper_bound(::ShiftDownActivePowerVariable, d::PSY.ElectricLoad, ::PowerLoadShift) = nothing # Unbounded above by default, but can be limited by time series parameters

variable_cost(cost::PSY.OperationalCost, ::ShiftUpActivePowerVariable, ::PSY.ElectricLoad, ::AbstractControllablePowerLoadFormulation)=PSY.get_variable(cost)
variable_cost(cost::PSY.OperationalCost, ::ShiftDownActivePowerVariable, ::PSY.ElectricLoad, ::AbstractControllablePowerLoadFormulation)=PSY.get_variable(cost)

######################################################

# To avoid ambiguity with default_interface_methods.jl:
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::PSY.ElectricLoad, ::Type{StaticPowerLoad}) = 1.0
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::PSY.ElectricLoad, ::Type{<:AbstractControllablePowerLoadFormulation}) = 1.0


########################Objective Function##################################################
proportional_cost(cost::Nothing, ::Type{OnVariable}, ::PSY.ElectricLoad, ::Type{<:AbstractControllablePowerLoadFormulation})=1.0
proportional_cost(cost::PSY.OperationalCost, ::Type{OnVariable}, ::PSY.ElectricLoad, ::Type{<:AbstractControllablePowerLoadFormulation})=PSY.get_fixed(cost)

objective_function_multiplier(::Type{<:VariableType}, ::Type{<:AbstractControllablePowerLoadFormulation})=OBJECTIVE_FUNCTION_NEGATIVE
objective_function_multiplier(::ShiftUpActivePowerVariable, ::AbstractControllablePowerLoadFormulation)=OBJECTIVE_FUNCTION_NEGATIVE
objective_function_multiplier(::ShiftDownActivePowerVariable, ::PowerLoadShift)=OBJECTIVE_FUNCTION_POSITIVE

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

function get_default_time_series_names(
    ::Type{<:PSY.ShiftablePowerLoad},
    ::Type{PowerLoadShift},
)
    return Dict{Type{<:TimeSeriesParameter}, String}(
        ActivePowerTimeSeriesParameter => "max_active_power",
        ReactivePowerTimeSeriesParameter => "max_active_power",
        ShiftUpActivePowerTimeSeriesParameter => "shift_up_max_active_power",
        ShiftDownActivePowerTimeSeriesParameter => "shift_down_max_active_power",
    )
end

####################### Expressions #########################

function add_expressions!(
    container::OptimizationContainer,
    ::Type{T},
    devices::U,
    model::DeviceModel{D, W},
) where {
    T <: RealizedShiftedLoad,
    U <: Union{Vector{D}, IS.FlattenIteratorWrapper{D}},
    W <: PowerLoadShift,
} where {D <: PSY.ShiftablePowerLoad}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    expression = add_expression_container!(container, T(), D, names, time_steps)
    shift_up = get_variable(container, ShiftUpActivePowerVariable(), D)
    shift_down = get_variable(container, ShiftDownActivePowerVariable(), D)
    param_container = get_parameter(container, ActivePowerTimeSeriesParameter(), D)
    multiplier = get_multiplier_array(param_container)
    for t in time_steps, d in devices
        name = PSY.get_name(d)
        expression[name, t] =
            get_parameter_column_refs(param_container, name)[t] * multiplier[name, t] +
            shift_up[name, t] - shift_down[name, t]
    end
    return
end

function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    device_model::DeviceModel{V, W},
    network_model::NetworkModel{CopperPlatePowerModel},
) where {
    T <: ActivePowerBalance,
    U <: RealizedShiftedLoad,
    V <: PSY.StaticInjection,
    W <: AbstractDeviceFormulation,
}
    realized_load = get_expression(container, U(), V)
    expression = get_expression(container, T(), PSY.System)
    for d in devices
        device_bus = PSY.get_bus(d)
        ref_bus = get_reference_bus(network_model, device_bus)
        name = PSY.get_name(d)
        for t in get_time_steps(container)
            JuMP.add_to_expression!(
                expression[ref_bus, t],
                -1.0, # Realized load enter negative to the balance
                realized_load[name, t],
            )
        end
    end
    return
end

"""
Electric Load implementation to add parameters to PTDF ActivePowerBalance expressions
"""
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{T},
    ::Type{U},
    devices::IS.FlattenIteratorWrapper{V},
    device_model::DeviceModel{V, W},
    network_model::NetworkModel{X},
) where {
    T <: ActivePowerBalance,
    U <: RealizedShiftedLoad,
    V <: PSY.ShiftablePowerLoad,
    W <: PowerLoadShift,
    X <: AbstractPTDFModel,
}
    realized_load = get_expression(container, U(), V)
    sys_expr = get_expression(container, T(), _system_expression_type(X))
    nodal_expr = get_expression(container, T(), PSY.ACBus)
    network_reduction = get_network_reduction(network_model)
    for d in devices
        name = PSY.get_name(d)
        device_bus = PSY.get_bus(d)
        bus_no_ = PSY.get_number(device_bus)
        bus_no = PNM.get_mapped_bus_number(network_reduction, bus_no_)
        ref_index = _ref_index(network_model, device_bus)
        for t in get_time_steps(container)
            JuMP.add_to_expression!(
                sys_expr[ref_index, t],
                -1.0, # Realized load enter negative to the balance
                realized_load[name, t],
            )
            JuMP.add_to_expression!(
                nodal_expr[bus_no, t],
                -1.0, # Realized load enter negative to the balance
                realized_load[name, t],
            )
        end
    end
    return
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

function add_constraints!(
    container::OptimizationContainer,
    T::Type{ShiftedActivePowerBalanceConstraint},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.ShiftablePowerLoad, W <: PowerLoadShift, X <: PM.AbstractPowerModel}
    time_steps = get_time_steps(container)
    constraint = add_constraints_container!(
        container,
        T(),
        V,
        PSY.get_name.(devices),
    )
    up_variable = get_variable(container, ShiftUpActivePowerVariable(), V)
    down_variable = get_variable(container, ShiftDownActivePowerVariable(), V)
    jump_model = get_jump_model(container)
    for d in devices
        name = PSY.get_name(d)
        constraint[name] =
            JuMP.@constraint(
                jump_model,
                sum(up_variable[name, t] - down_variable[name, t] for t in time_steps) ==
                0.0
            )
    end
    additional_balance_interval = get_attribute(model, "additional_balance_interval")
    if !isnothing(additional_balance_interval)
        constraint_aux = add_constraints_container!(
            container,
            T(),
            V,
            PSY.get_name.(devices);
            meta = "additional",
        )
        resolution = get_resolution(container)
        interval_length =
            Dates.Millisecond(additional_balance_interval).value ÷
            Dates.Millisecond(resolution).value
        for d in devices
            name = PSY.get_name(d)
            constraint_aux[name] = JuMP.@constraint(
                container.JuMPmodel,
                sum(
                    up_variable[name, t] - down_variable[name, t] for
                    t in 1:interval_length
                ) == 0.0
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    T::Type{RealizedShiftedLoadMinimumBoundConstraint},
    U::Type{<:ExpressionType},
    devices::IS.FlattenIteratorWrapper{V},
    ::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.ShiftablePowerLoad, W <: PowerLoadShift, X <: PM.AbstractPowerModel}
    time_steps = get_time_steps(container)
    constraint = add_constraints_container!(
        container,
        T(),
        V,
        PSY.get_name.(devices),
        time_steps,
    )
    realized_load = get_expression(container, U(), V)
    jump_model = get_jump_model(container)
    for d in devices, t in time_steps
        name = PSY.get_name(d)
        constraint[name, t] = JuMP.@constraint(jump_model, realized_load[name, t] >= 0.0)
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    T::Type{NonAnticipativityConstraint},
    devices::IS.FlattenIteratorWrapper{V},
    ::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.ShiftablePowerLoad, W <: PowerLoadShift, X <: PM.AbstractPowerModel}
    time_steps = get_time_steps(container)
    constraint = add_constraints_container!(
        container,
        T(),
        V,
        PSY.get_name.(devices),
        time_steps,
    )
    up_variable = get_variable(container, ShiftUpActivePowerVariable(), V)
    down_variable = get_variable(container, ShiftDownActivePowerVariable(), V)
    jump_model = get_jump_model(container)
    for d in devices
        name = PSY.get_name(d)
        for t in time_steps
            constraint[name, t] = JuMP.@constraint(
                jump_model,
                sum(down_variable[name, τ] - up_variable[name, τ] for τ in 1:t) >= 0.0
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{ShiftUpActivePowerVariableLimitsConstraint},
    U::Type{<:VariableType},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.ShiftablePowerLoad, W <: PowerLoadShift, X <: PM.AbstractPowerModel}
    add_parameterized_upper_bound_range_constraints(
        container,
        ShiftUpActivePowerVariableLimitsConstraint,
        U,
        ShiftUpActivePowerTimeSeriesParameter,
        devices,
        model,
        X,
    )
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{ShiftDownActivePowerVariableLimitsConstraint},
    U::Type{<:VariableType},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.ShiftablePowerLoad, W <: PowerLoadShift, X <: PM.AbstractPowerModel}
    add_parameterized_upper_bound_range_constraints(
        container,
        ShiftDownActivePowerVariableLimitsConstraint,
        U,
        ShiftDownActivePowerTimeSeriesParameter,
        devices,
        model,
        X,
    )
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

is_time_variant_term(
    ::OptimizationContainer,
    ::PSY.LoadCost,
    ::Type{OnVariable},
    ::PSY.ControllableLoad,
    ::Type{<:AbstractLoadFormulation},
    ::Int,
) = false

is_time_variant_term(
    ::OptimizationContainer,
    cost::PSY.MarketBidCost,
    ::Type{OnVariable},
    ::PSY.ControllableLoad,
    ::Type{PowerLoadInterruption},
    ::Int,
) =
    is_time_variant(PSY.get_decremental_initial_input(cost))

function proportional_cost(
    container::OptimizationContainer,
    cost::PSY.MarketBidCost,
    ::Type{OnVariable},
    comp::T,
    ::Type{PowerLoadInterruption},
    t::Int,
) where {T <: PSY.ControllableLoad}
    if is_time_variant(PSY.get_decremental_initial_input(cost))
        name = get_name(comp)
        param_arr = get_parameter_array(container, DecrementalCostAtMinParameter, T)
        param_mult =
            get_parameter_multiplier_array(container, DecrementalCostAtMinParameter, T)
        return param_arr[name, t] * param_mult[name, t]
    else
        return PSY.get_initial_input(
            PSY.get_decremental_offer_curves(PSY.get_operation_cost(comp)),
        )
    end
end

########## PowerLoadShift Formulation Costs ###############

function objective_function!(
    container::OptimizationContainer,
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, U},
    ::Type{<:PM.AbstractPowerModel},
) where {T <: PSY.ShiftablePowerLoad, U <: PowerLoadShift}
    add_variable_cost!(container, ShiftUpActivePowerVariable(), devices, U())
    add_variable_cost!(container, ShiftDownActivePowerVariable(), devices, U())
    return
end

### Special Method to skip VOM cost on ShiftUpActivePowerVariable ###
function add_variable_cost!(
    container::OptimizationContainer,
    ::U,
    devices::IS.FlattenIteratorWrapper{T},
    ::V,
) where {T <: PSY.ShiftablePowerLoad, U <: ShiftUpActivePowerVariable, V <: PowerLoadShift}
    for d in devices
        op_cost_data = PSY.get_operation_cost(d)
        _add_variable_cost_to_objective!(container, U(), d, op_cost_data, V())
    end
    return
end