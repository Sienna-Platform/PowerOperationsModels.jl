const _TEMPLATE_VALIDATION_EXCLUSIONS = [PSY.Arc, PSY.Area, PSY.ACBus, PSY.LoadZone]

# Reconcile the model's resolution setting against the resolutions present in the
# system's time series: set it when unset and a single resolution exists, and error on
# ambiguous (multiple-resolution) or unavailable resolutions. Shared by the DecisionModel
# and EmulationModel `validate_time_series!` methods.
function _reconcile_resolution!(settings, sys)
    available_resolutions = IOM.get_time_series_resolutions(sys)
    if get_resolution(settings) == IOM.UNSET_RESOLUTION &&
       length(available_resolutions) != 1
        throw(
            IS.ConflictingInputsError(
                "Data contains multiple resolutions, the resolution keyword argument must be added to the Model. Time Series Resolutions: $(available_resolutions)",
            ),
        )
    elseif get_resolution(settings) != IOM.UNSET_RESOLUTION &&
           length(available_resolutions) > 1
        if get_resolution(settings) ∉ available_resolutions
            throw(
                IS.ConflictingInputsError(
                    "Resolution $(get_resolution(settings)) is not available in the system data. Time Series Resolutions: $(available_resolutions)",
                ),
            )
        end
    else
        IOM.set_resolution!(settings, first(available_resolutions))
    end
    return
end

function validate_template_impl!(model::IOM.AbstractOptimizationModel)
    template = get_template(model)
    settings = get_settings(model)
    if isempty(template)
        error("Template can't be empty for models $(IOM.get_problem_type(model))")
    end
    system = get_system(model)
    modeled_types = IOM.get_component_types(template)
    system_component_types = PSY.get_existing_component_types(system)
    network_model = get_network_model(template)
    valid_device_types = union(modeled_types, _TEMPLATE_VALIDATION_EXCLUSIONS)
    unmodeled_branch_types = DataType[]

    for m in setdiff(system_component_types, valid_device_types)
        @warn "The template doesn't include models for components of type $(m), consider changing the template" _group =
            IOM.LOG_GROUP_MODELS_VALIDATION
        if m <: PSY.ACTransmission
            push!(unmodeled_branch_types, m)
        end
    end

    device_keys_to_delete = Symbol[]
    for (k, device_model) in template.devices
        make_device_cache!(device_model, system, get_check_components(settings))
        if isempty(get_device_cache(device_model))
            @info "The system data doesn't include devices of type $(k), consider changing the models in the template" _group =
                IOM.LOG_GROUP_MODELS_VALIDATION
            push!(device_keys_to_delete, k)
        end
    end
    for k in device_keys_to_delete
        delete!(template.devices, k)
    end

    model_has_branch_filters = false
    branch_keys_to_delete = Symbol[]
    for (k, device_model) in template.branches
        make_device_cache!(device_model, system, get_check_components(settings))
        if isempty(get_device_cache(device_model))
            @info "The system data doesn't include Branches of type $(k), consider changing the models in the template" _group =
                IOM.LOG_GROUP_MODELS_VALIDATION
            push!(branch_keys_to_delete, k)
        else
            push!(network_model.modeled_branch_types, get_component_type(device_model))
        end
        if get_attribute(device_model, "filter_function") !== nothing
            model_has_branch_filters = true
        end
    end
    for k in branch_keys_to_delete
        delete!(template.branches, k)
    end
    validate_network_model(network_model, unmodeled_branch_types, model_has_branch_filters)
    return
end
