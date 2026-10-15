#################################################################################
# IC type -> variable/aux-variable type mapping (dispatch-based)
#################################################################################

_ic_variable_type(::Type{DevicePower}) = ActivePowerVariable()
_ic_variable_type(::Type{DeviceStatus}) = OnVariable()
_ic_variable_type(::Type{DeviceAboveMinPower}) = PowerAboveMinimumVariable()
_ic_variable_type(::Type{InitialTimeDurationOn}) = TimeDurationOn()
_ic_variable_type(::Type{InitialTimeDurationOff}) = TimeDurationOff()
_ic_variable_type(::Type{InitialEnergyLevel}) = EnergyVariable()
_ic_variable_type(::Type{InitialReservoirVolume}) = HydroReservoirVolumeVariable()

#################################################################################
# Generic update from EmulationModelStore
#################################################################################

function update_initial_conditions!(
    ics::Vector{<:InitialCondition{T}},
    store::EmulationModelStore,
    ::Dates.Millisecond,
) where {T <: InitialConditionType}
    var_type = _ic_variable_type(T)
    for ic in ics
        var_val = get_value(store, var_type, get_component_type(ic))
        set_ic_quantity!(ic, get_last_recorded_value(var_val)[get_component_name(ic)])
    end
    return
end

#################################################################################
# Generic update from a solved OptimizationContainer
#################################################################################

function update_initial_conditions!(
    ics::Vector{<:InitialCondition{T}},
    source::OptimizationContainer,
) where {T <: InitialConditionType}
    var_type = _ic_variable_type(T)
    t_last = last(get_time_steps(source))
    for ic in ics
        var = lookup_value(source, typeof(var_type), get_component_type(ic))
        set_ic_quantity!(ic, var[get_component_name(ic), t_last])
    end
    return
end

"""
Transfer initial conditions from a solved source model to a target model.

Reads the last-timestep variable values from the source and sets them as
initial conditions on the target. Uses the IC-type-to-variable-type mapping
to determine which variable to read for each IC.

PSI handles this same thing by adding another layer of abstractions, using `SimulationState`
and reading/writing to `ModelStore`. But it's useful to be able to do the same thing
here in POM without those abstractions, for testing purposes.

!!! warning
    This is a naive transfer: it copies last-timestep variable values directly as ICs,
    without consideration of different time resolutions between source and target,
    pre-existing IC values on the target, or uptime/downtime duration scaling.
"""
function transfer_initial_conditions!(
    target::IOM.AbstractOptimizationModel,
    source::IOM.AbstractOptimizationModel,
)
    source_container = get_optimization_container(source)
    target_container = get_optimization_container(target)
    for key in keys(get_initial_conditions(target_container))
        ics = get_initial_condition(target_container, key)
        update_initial_conditions!(ics, source_container)
    end
    return
end

"""
Give each initial condition of the model the value a fresh build reads from its component.
For example, use it to start a step from the data of the components instead of the carried state.
Return the number of initial conditions set. An initial condition with a `nothing` value is not set.
The new values take effect only for conditions that are parameters, that is, in a model built for recurrent solves.
In a model built without recurrent solves, the function changes the stored value and the built problem keeps the old value.
"""
function reset_initial_conditions!(model::DecisionModel)
    container = get_optimization_container(model)
    template = get_template(model)
    n = 0
    for (key, ics) in get_initial_conditions(container)
        T = IOM.get_entry_type(key)
        for ic in ics
            n += _reset_initial_condition!(ic, T, template, container)
        end
    end
    return n
end

function _reset_initial_condition!(
    ::IOM.InitialCondition{U, Nothing},
    ::Type{T},
    template::PowerOperationsProblemTemplate,
    ::OptimizationContainer,
) where {U <: IOM.InitialConditionType, T}
    return 0
end

function _reset_initial_condition!(
    ic::IOM.InitialCondition,
    ::Type{T},
    template::PowerOperationsProblemTemplate,
    container::OptimizationContainer,
) where {T}
    component = IOM.get_component(ic)
    formulation = IOM.get_formulation(get_model(template, typeof(component)))
    set_ic_quantity!(
        ic,
        initial_condition_default(T(), component, formulation(), container),
    )
    return 1
end
