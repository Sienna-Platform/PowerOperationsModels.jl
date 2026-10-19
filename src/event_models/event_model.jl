"""
    EventKey(::Type{T}, ::Type{U})

Key identifying an event of contingency type `T` applied to devices of concrete type `U`.
Used as the key of the `DeviceModel.events` dict. Errors if `U` is abstract.
"""
struct EventKey{T <: PSY.Contingency, U <: PSY.Component} <:
       IOM.AbstractEventKey
    meta::String
end

function EventKey(
    ::Type{T},
    ::Type{U},
) where {T <: PSY.Contingency, U <: PSY.Component}
    if isabstracttype(U)
        error("Type $U can't be abstract")
    end
    return EventKey{T, U}("")
end

IOM.get_entry_type(
    ::EventKey{T, U},
) where {T <: PSY.Contingency, U <: PSY.Component} = T
IOM.get_component_type(
    ::EventKey{T, U},
) where {T <: PSY.Contingency, U <: PSY.Component} = U

"""
Abstract type for the condition that triggers an event. POM stores conditions as data;
evaluating them requires a simulation runtime and happens outside this package.
"""
abstract type AbstractEventCondition end

"""
    ContinuousCondition()

Event condition that is triggered at all timesteps.
"""
struct ContinuousCondition <: AbstractEventCondition end

"""
    PresetTimeCondition(time_stamps::Vector{Dates.DateTime})

Event condition that is triggered at pre-determined times.
"""
struct PresetTimeCondition <: AbstractEventCondition
    time_stamps::Vector{Dates.DateTime}
end

"""
Return the time stamps at which `c` is triggered.
"""
get_time_stamps(c::PresetTimeCondition) = c.time_stamps

"""
    VariableTarget(variable_type, device_type, device_name)

One device's optimization variable: what a state-dependent condition reads, and what a
runtime is asked to resolve for it.
"""
struct VariableTarget
    variable_type::VariableType
    device_type::Type{<:PSY.Device}
    device_name::String
end

get_variable_type(t::VariableTarget) = t.variable_type
get_device_type(t::VariableTarget) = t.device_type
get_device_name(t::VariableTarget) = t.device_name

"""
    StateVariableValueCondition(variable_type, device_type, device_name, value)

Event condition triggered when the monitored variable equals `value` (p.u.).
"""
struct StateVariableValueCondition <: AbstractEventCondition
    target::VariableTarget
    value::Float64
end

function StateVariableValueCondition(
    variable_type::VariableType,
    device_type::Type{<:PSY.Device},
    device_name::String,
    value::Real,
)
    return StateVariableValueCondition(
        VariableTarget(variable_type, device_type, device_name),
        value,
    )
end

get_target(c::StateVariableValueCondition) = c.target
get_variable_type(c::StateVariableValueCondition) = get_variable_type(c.target)
get_device_type(c::StateVariableValueCondition) = get_device_type(c.target)
get_device_name(c::StateVariableValueCondition) = get_device_name(c.target)
# Qualified: `get_value` is IOM's generic (`get_value(::InitialCondition)`); a bare
# definition here would silently create a separate local `get_value` in POM's namespace
# (since it was only ever `using`'d, not `import`ed) and shadow IOM's method for every
# other unqualified `get_value(ic)` call across the package (storage, hybrid, thermal
# generation, AGC initial-condition consumers).
IOM.get_value(c::StateVariableValueCondition) = c.value

"""
    DiscreteEventCondition(condition_function::Function)

Event condition driven by a user-defined function evaluated by the simulation runtime.
"""
struct DiscreteEventCondition <: AbstractEventCondition
    condition_function::Function
end

get_condition_function(c::DiscreteEventCondition) = c.condition_function

"""
    EventModel(contingency_type, condition; timeseries_mapping, attributes)

Container binding a `PSY.Contingency` supplemental-attribute type to a trigger condition
and time-series mapping. Attach to a template with
`set_event_model!(template, event_model)`.

Outage events are applied by a simulation with an emulation model. The simulation fills
`attribute_device_map` (outage attribute id → device type → device names) from the
emulator's system with [`discover_event_attribute_device_map`](@ref) before any model is
built; each model's build then distributes the event to the matching `DeviceModel`s.
Events take their outages from the emulator's system only: outage attributes in a decision
model's own system do not affect events (they may serve other formulations, such as
security-constrained ones).
"""
mutable struct EventModel{D <: PSY.Contingency, B <: AbstractEventCondition} <:
               IOM.AbstractEventModel
    condition::B
    timeseries_mapping::Dict{Symbol, Union{String, Nothing}}
    attribute_device_map::Dict{Int, Dict{DataType, Set{String}}}
    attributes::Dict{String, Any}

    function EventModel(
        contingency_type::Type{D},
        condition::B;
        timeseries_mapping = get_empty_timeseries_mapping(contingency_type),
        attributes = Dict{String, Any}(),
    ) where {D <: PSY.Contingency, B <: AbstractEventCondition}
        new{D, B}(
            condition,
            timeseries_mapping,
            Dict{Int, Dict{DataType, Set{String}}}(),
            attributes,
        )
    end
end

"""
Reserved time-series mapping keys for a contingency type. `:outage_status` is required
for `PSY.FixedForcedOutage`.
"""
# Event models support the unplanned forced-outage types only.
function get_empty_timeseries_mapping(::Type{T}) where {T <: PSY.Contingency}
    error(
        "$T is not an event contingency type. Event models support \
         PSY.FixedForcedOutage and PSY.GeometricDistributionForcedOutage.",
    )
end

function get_empty_timeseries_mapping(::Type{PSY.FixedForcedOutage})
    return Dict{Symbol, Union{String, Nothing}}(:outage_status => nothing)
end

function get_empty_timeseries_mapping(::Type{PSY.GeometricDistributionForcedOutage})
    return Dict{Symbol, Union{String, Nothing}}(
        :mean_time_to_recovery => nothing,
        :outage_transition_probability => nothing,
    )
end

"""
Return the `PSY.Contingency` subtype that `e` models.
"""
get_event_type(
    ::EventModel{D, B},
) where {D <: PSY.Contingency, B <: AbstractEventCondition} = D

"""
Return the trigger condition attached to `e`.
"""
get_event_condition(
    e::EventModel{D, B},
) where {D <: PSY.Contingency, B <: AbstractEventCondition} = e.condition

"""
Return `e`'s outage attribute id → device type → device names map. A simulation fills it
from the emulator's system (see [`discover_event_attribute_device_map`](@ref)); every
model the event model is attached to reads the same map.
"""
get_attribute_device_map(e::EventModel) = e.attribute_device_map

# The outaged devices come from the event model's map, which describes the emulator's
# system. A model applies the event only to the outaged devices it has; a model with none
# of them gets no event parameters or constraints for that device type.
function _for_each_event_devices(f::Function, devices, device_model::DeviceModel)
    for (key, event_model) in get_events(device_model)
        device_type = get_component_type(key)
        names = Set{String}()
        for per_type in values(get_attribute_device_map(event_model))
            if haskey(per_type, device_type)
                union!(names, per_type[device_type])
            end
        end
        devices_with_attributes = [d for d in devices if PSY.get_name(d) in names]
        isempty(devices_with_attributes) && continue
        f(devices_with_attributes, event_model)
    end
    return
end
