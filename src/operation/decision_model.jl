# Template-first constructors default the problem type to `DefaultPowerOperationProblem`.
# IOM only ships the `DecisionModel{M}` / `DecisionModel(::Type{M}, ...)` variants
# (`M` is the domain-neutral `AbstractOptimizationProblem`); the default problem
# type is a POM concept, so the defaulting constructors live here.
function DecisionModel(
    template::IOM.AbstractProblemTemplate,
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    kwargs...,
)
    return DecisionModel{DefaultPowerOperationProblem}(template, sys, jump_model; kwargs...)
end

# Generic (template-driven) problems require an AbstractProblemTemplate subtype, so the
# bare-system constructor (no template) is an error.
function DecisionModel{M}(
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    kwargs...,
) where {M <: GenericPowerOperationProblem}
    throw(
        IS.ArgumentError(
            "GenericPowerOperationProblem subtypes require a template. Use DecisionModel subtyping instead.",
        ),
    )
end

# POM implementation of IOM's `validate_template` extension point for template-driven
# problems. Shared by both wrapper types (the body is wrapper-agnostic).
function validate_template(
    model::Union{
        DecisionModel{<:GenericPowerOperationProblem},
        EmulationModel{<:GenericPowerOperationProblem},
    },
)
    validate_template_impl!(model)
    return
end

# IOM declares `validate_time_series!` as a pure extension-point stub (no methods);
# POM provides the concrete check for its template-driven problem types. It reconciles
# the model's resolution/interval/horizon settings against the forecast data in the
# system and errors when the system has no forecast data.
function validate_time_series!(model::DecisionModel{<:GenericPowerOperationProblem})
    sys = get_system(model)
    settings = get_settings(model)
    _reconcile_resolution!(settings, sys)

    model_interval = IOM.get_interval(settings)
    available_intervals = IOM.get_forecast_intervals(sys)
    if model_interval == IOM.UNSET_INTERVAL && length(available_intervals) > 1
        throw(
            IS.ConflictingInputsError(
                "The system contains multiple forecast intervals $(available_intervals). " *
                "The `interval` keyword argument must be provided to the DecisionModel constructor " *
                "to select which interval to use.",
            ),
        )
    elseif model_interval != IOM.UNSET_INTERVAL && !isempty(available_intervals)
        if model_interval ∉ available_intervals
            throw(
                IS.ConflictingInputsError(
                    "Interval $(Dates.canonicalize(model_interval)) is not available in the system data. " *
                    "Available forecast intervals: $(available_intervals)",
                ),
            )
        end
    end
    if get_horizon(settings) == IOM.UNSET_HORIZON
        IOM.set_horizon!(
            settings,
            IOM.get_forecast_horizon(sys; interval = IOM._to_is_interval(model_interval)),
        )
    end

    counts = IOM.get_time_series_counts(sys)
    if counts.forecast_count < 1
        error(
            "The system does not contain forecast data. A DecisionModel can't be built.",
        )
    end
    return
end

function _make_device_cache(
    filter_function::Function,
    devices::IS.FlattenIteratorWrapper{T},
    check_components::Bool,
    sys::PSY.System,
) where {T <: PSY.Device}
    device_cache = sizehint!(Vector{T}(), length(devices))
    for device in devices
        if PSY.get_available(device) && filter_function(device)
            check_components && PSY.check_component(sys, device)
            push!(device_cache, device)
        end
    end
    return device_cache
end

function _make_device_cache(
    ::Nothing,
    devices::IS.FlattenIteratorWrapper{T},
    check_components::Bool,
    sys::PSY.System,
) where {T <: PSY.Device}
    device_cache = sizehint!(Vector{T}(), length(devices))
    for device in devices
        if PSY.get_available(device)
            check_components && PSY.check_component(sys, device)
            push!(device_cache, device)
        end
    end
    return device_cache
end

function make_device_cache!(
    model::DeviceModel{T, <:AbstractDeviceFormulation},
    system::PSY.System,
    check_components::Bool,
) where {T <: PSY.Device}
    subsystem = get_subsystem(model)
    !PSY.has_components(system, T) && return false
    devices = PSY.get_components(T, system; subsystem_name = subsystem)
    filt_func = get_attribute(model, "filter_function")
    model.device_cache =
        _make_device_cache(filt_func, devices, check_components, system)
    return
end
