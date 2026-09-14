#################################################################################
# Event fallbacks
#
# Every constructor calls add_event_arguments! and add_event_constraints!
# unconditionally. The real methods live in src/event_models/; these fallbacks
# catch device models with no event support, and only pass when no events are
# attached.
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
