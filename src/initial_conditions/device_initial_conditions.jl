#################################################################################
# Device-specific initial condition value methods
# These extend the generic get_initial_conditions_value from IOM
#################################################################################

# InitialTimeDurationOff for thermal devices (Float64 version)
function get_initial_conditions_value(
    ::Vector{Union{InitialCondition{U, Float64}, InitialCondition{U, Nothing}}},
    component::W,
    ::U,
    ::V,
    container::OptimizationContainer,
) where {
    V <: AbstractThermalFormulation,
    W <: PSY.Component,
} where {U <: InitialTimeDurationOff}
    ic_data = get_initial_conditions_data(container)
    var_type = initial_condition_variable(U(), component, V())
    if !has_initial_condition_value(ic_data, var_type, W)
        val = initial_condition_default(U(), component, V(), container)
    else
        var = get_initial_condition_value(ic_data, var_type, W)[PSY.get_name(component), 1]
        val = _time_at_status_steps(
            component,
            container,
            !is_online(component) && !(var > ABSOLUTE_TOLERANCE),
        )
    end
    @debug "Device $(PSY.get_name(component)) initialized $U as $val" _group =
        LOG_GROUP_BUILD_INITIAL_CONDITIONS
    return InitialCondition{U, Float64}(component, val)
end

# InitialTimeDurationOff for thermal generators (JuMP.VariableRef version)
function get_initial_conditions_value(
    ::Vector{Union{InitialCondition{U, JuMP.VariableRef}, InitialCondition{U, Nothing}}},
    component::W,
    ::U,
    ::V,
    container::OptimizationContainer,
) where {
    V <: AbstractThermalFormulation,
    W <: PSY.ThermalGen,
} where {U <: InitialTimeDurationOff}
    ic_data = get_initial_conditions_data(container)
    var_type = initial_condition_variable(U(), component, V())
    if !has_initial_condition_value(ic_data, var_type, W)
        val = initial_condition_default(U(), component, V(), container)
    else
        var = get_initial_condition_value(ic_data, var_type, W)[PSY.get_name(component), 1]
        val = _time_at_status_steps(
            component,
            container,
            !is_online(component) && !(var > ABSOLUTE_TOLERANCE),
        )
    end
    @debug "Device $(PSY.get_name(component)) initialized $U as $val" _group =
        LOG_GROUP_BUILD_INITIAL_CONDITIONS
    return InitialCondition{U, JuMP.VariableRef}(
        component,
        add_jump_parameter(get_jump_model(container), val),
    )
end

# InitialTimeDurationOn for thermal generators (Float64 version)
function get_initial_conditions_value(
    ::Vector{Union{InitialCondition{U, Float64}, InitialCondition{U, Nothing}}},
    component::W,
    ::U,
    ::V,
    container::OptimizationContainer,
) where {
    V <: AbstractThermalFormulation,
    W <: PSY.ThermalGen,
} where {U <: InitialTimeDurationOn}
    ic_data = get_initial_conditions_data(container)
    var_type = initial_condition_variable(U(), component, V())
    has_ic = has_initial_condition_value(ic_data, var_type, W)
    if !has_ic
        val = initial_condition_default(U(), component, V(), container)
    else
        var = get_initial_condition_value(ic_data, var_type, W)[PSY.get_name(component), 1]
        val = _time_at_status_steps(
            component,
            container,
            is_online(component) && (var > ABSOLUTE_TOLERANCE),
        )
    end
    @debug "Device $(PSY.get_name(component)) initialized $U as $val" _group =
        LOG_GROUP_BUILD_INITIAL_CONDITIONS
    return InitialCondition{U, Float64}(component, val)
end

# InitialTimeDurationOn for thermal generators (JuMP.VariableRef version)
function get_initial_conditions_value(
    ::Vector{Union{InitialCondition{U, JuMP.VariableRef}, InitialCondition{U, Nothing}}},
    component::W,
    ::U,
    ::V,
    container::OptimizationContainer,
) where {
    V <: AbstractThermalFormulation,
    W <: PSY.ThermalGen,
} where {U <: InitialTimeDurationOn}
    ic_data = get_initial_conditions_data(container)
    var_type = initial_condition_variable(U(), component, V())
    has_ic = has_initial_condition_value(ic_data, var_type, W)
    if !has_ic
        val = initial_condition_default(U(), component, V(), container)
    else
        var = get_initial_condition_value(ic_data, var_type, W)[PSY.get_name(component), 1]
        val = _time_at_status_steps(
            component,
            container,
            is_online(component) && (var > ABSOLUTE_TOLERANCE),
        )
    end
    @debug "Device $(PSY.get_name(component)) initialized $U as $val" _group =
        LOG_GROUP_BUILD_INITIAL_CONDITIONS
    return InitialCondition{U, JuMP.VariableRef}(
        component,
        add_jump_parameter(get_jump_model(container), val),
    )
end

#################################################################################
# Device-specific add_initial_condition! methods
#################################################################################

# Thermal generators with must_run handling
function add_initial_condition!(
    container::OptimizationContainer,
    components::Vector{T},
    ::U,
    ::D,
) where {
    T <: PSY.ThermalGen,
    U <: AbstractThermalFormulation,
    D <: Union{InitialTimeDurationOff, InitialTimeDurationOn, DeviceStatus},
}
    if get_rebuild_model(get_settings(container)) && has_container_key(container, D, T)
        return
    end

    ini_cond_vector = add_initial_condition_container!(container, D(), T, components)
    for (ix, component) in enumerate(components)
        if _is_must_run(component)
            ini_cond_vector[ix] = InitialCondition{D, Nothing}(component, nothing)
        else
            ini_cond_vector[ix] =
                get_initial_conditions_value(
                    ini_cond_vector,
                    component,
                    D(),
                    U(),
                    container,
                )
        end
    end
    return
end

"""
Set the initial energy of each `PSY.EnergyReservoirStorage` in a built `DecisionModel`.

`energy` maps a storage name to the stored energy in MWh. The function clamps each value to the
storage level limits. A storage that is not in `energy`, or has a non-finite value, keeps its
initial condition. A name in `energy` that is not a storage in the model is ignored.

A parameter initial condition (a model built for recurrent solves) takes the new value. A constant
initial condition accepts only a value equal to the current one. Otherwise the function throws an error.
Return the number of initial conditions set or accepted.
"""
function set_initial_storage_energy!(
    model::DecisionModel,
    energy::AbstractDict{String, <:Real},
)
    container = get_optimization_container(model)
    if !has_container_key(container, InitialEnergyLevel, PSY.EnergyReservoirStorage)
        return 0
    end
    n = 0
    for ic in get_initial_condition(
        container,
        InitialEnergyLevel(),
        PSY.EnergyReservoirStorage,
    )
        storage = IOM.get_component(ic)
        mwh = get(energy, PSY.get_name(storage), NaN)
        if isfinite(mwh)
            n += _set_storage_energy!(ic, _storage_energy_target(storage, mwh))
        end
    end
    return n
end

# Same conversion as `initial_condition_default(::InitialEnergyLevel, ::PSY.Storage, ...)`.
function _storage_energy_target(storage::PSY.EnergyReservoirStorage, mwh::Real)
    capacity = PSY.get_storage_capacity(storage, u"NU")
    limits = PSY.get_storage_level_limits(storage)
    level = clamp(mwh / capacity, limits.min, limits.max)
    return level * PSY.get_storage_capacity(storage, u"SU") *
           PSY.get_conversion_factor(storage)
end

function _set_storage_energy!(
    ic::InitialCondition{InitialEnergyLevel, JuMP.VariableRef},
    target::Float64,
)
    set_ic_quantity!(ic, target)
    return 1
end

function _set_storage_energy!(
    ic::InitialCondition{InitialEnergyLevel, Float64},
    target::Float64,
)
    if !isapprox(IOM.get_condition(ic), target; atol = 1e-9)
        error(
            "Cannot set the initial energy of storage $(PSY.get_name(IOM.get_component(ic))): " *
            "the initial energy is a constant of the built model. " *
            "Build the model for recurrent solves to change it.",
        )
    end
    return 1
end

function _set_storage_energy!(
    ::InitialCondition{InitialEnergyLevel, Nothing},
    ::Float64,
)
    return 0
end
