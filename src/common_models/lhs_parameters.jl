#################################################################################
# Left-hand-side parameter containers
#################################################################################

"""
Create the left-hand-side parameter containers every service model declares, before device
argument construction: devices write a service's coefficients during their own argument
stage, which runs before the service's.
"""
function construct_lhs_parameters!(
    container::OptimizationContainer,
    template::PowerOperationsProblemTemplate,
    sys::PSY.System,
)
    for service_model in values(get_service_models(template))
        _add_lhs_parameters!(container, service_model, sys)
    end
    return
end

function _add_lhs_parameters!(
    container::OptimizationContainer,
    model::ServiceModel,
    sys::PSY.System,
)
    for (P, ts_name) in get_time_series_names(model)
        P <: LeftHandSideTimeSeriesParameter || continue
        _add_profiled_parameters!(
            container,
            P,
            get_available_components(model, sys),
            model,
            ts_name,
        )
    end
    return
end

# Add the parameter `P` for the components that own the series `ts_name`. Returns them.
function _add_profiled_parameters!(
    container::OptimizationContainer,
    ::Type{P},
    components,
    model,
    ts_name::String,
) where {P <: ParameterType}
    ts_type = get_default_time_series_type(container)
    profiled = [c for c in components if PSY.has_time_series(c, ts_type, ts_name)]
    isempty(profiled) || add_parameters!(container, P, profiled, model)
    return profiled
end
