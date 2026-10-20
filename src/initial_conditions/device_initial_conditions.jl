#################################################################################
# Device-specific initial condition value methods
# These extend the generic get_initial_conditions_value from IOM
#################################################################################

# Whether the unit is in the status that the duration counts, given its initial on-status.
_in_status(::InitialTimeDurationOn, d::PSY.ThermalGen, on) =
    is_online(d) && on > ABSOLUTE_TOLERANCE
_in_status(::InitialTimeDurationOff, d::PSY.ThermalGen, on) =
    !is_online(d) && !(on > ABSOLUTE_TOLERANCE)

# InitialTimeDurationOn/Off for thermal generators. Without initial-condition data the
# on-status is the device's own, so the duration is its `time_at_status` when that status
# matches.
function get_initial_conditions_value(
    ini_conds::InitialConditionVector{U},
    component::W,
    ::U,
    ::V,
    container::OptimizationContainer,
) where {
    U <: Union{InitialTimeDurationOn, InitialTimeDurationOff},
    V <: AbstractThermalFormulation,
    W <: PSY.ThermalGen,
}
    ic_data = get_initial_conditions_data(container)
    var_type = initial_condition_variable(U(), component, V())
    if has_initial_condition_value(ic_data, var_type, W)
        on = get_initial_condition_value(ic_data, var_type, W)[PSY.get_name(component), 1]
    else
        on = Float64(is_online(component))
    end
    val = _time_at_status_steps(component, container, _in_status(U(), component, on))
    @debug "Device $(PSY.get_name(component)) initialized $U as $val" _group =
        LOG_GROUP_BUILD_INITIAL_CONDITIONS
    return _ic_value(ini_conds, component, container, val)
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
