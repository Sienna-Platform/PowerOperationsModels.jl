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
    ts_type = get_default_time_series_type(container)
    for (P, ts_name) in get_time_series_names(model)
        P <: LeftHandSideTimeSeriesParameter || continue
        profiled = [
            s for s in get_available_components(model, sys) if
            PSY.has_time_series(s, ts_type, ts_name)
        ]
        isempty(profiled) || add_parameters!(container, P, profiled, model)
    end
    return
end
