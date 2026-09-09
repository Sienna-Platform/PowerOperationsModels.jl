#################################################################################
# No-op stubs for event functions
#
# The contingency/event infrastructure lives in PowerSimulations.jl and has not yet
# been moved into POM. These stubs allow constructor code (which calls
# add_event_arguments!, etc.) to compile and run correctly when no events are
# configured. Once the event code is migrated, these stubs should be replaced by
# the real implementations.
#################################################################################

# Both event fallbacks must stay no-ops for the empty-events case (every constructor
# calls them unconditionally), but a device model that carries events and lands on a
# fallback would build a silently wrong model, so that case errors.
function _assert_events_implemented(device_model::DeviceModel, fallback::Symbol)
    isempty(get_events(device_model)) && return
    error(
        "DeviceModel{$(get_component_type(device_model)), \
         $(get_formulation(device_model))} has event models attached but no \
         $fallback implementation, so its outages would not be modeled. Remove the \
         event model or implement event support for this device model.",
    )
end

# ---- Event arguments (ArgumentConstructStage) ----

function add_event_arguments!(
    ::OptimizationContainer,
    ::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    device_model::DeviceModel,
    ::NetworkModel,
) where {V <: PSY.Component}
    _assert_events_implemented(device_model, :add_event_arguments!)
    return
end

# ---- Event constraints (ModelConstructStage) ----

function add_event_constraints!(
    ::OptimizationContainer,
    ::Union{Vector{V}, IS.FlattenIteratorWrapper{V}},
    device_model::DeviceModel,
    ::NetworkModel,
) where {V <: PSY.Component}
    _assert_events_implemented(device_model, :add_event_constraints!)
    return
end
