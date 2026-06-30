# Template-first constructor defaults the problem type to `DefaultPowerOperationProblem`
# (mirrors the DecisionModel defaulting constructor; see decision_model.jl).
function EmulationModel(
    template::IOM.AbstractProblemTemplate,
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    kwargs...,
)
    return EmulationModel{DefaultPowerOperationProblem}(
        template,
        sys,
        jump_model;
        kwargs...,
    )
end

# POM-side implementation of IOM's `validate_time_series!` extension point for
# emulation problems. Emulation models solve a single step, so horizon == resolution.
function validate_time_series!(model::EmulationModel{<:GenericPowerOperationProblem})
    sys = get_system(model)
    settings = get_settings(model)
    _reconcile_resolution!(settings, sys)

    if get_horizon(settings) == IOM.UNSET_HORIZON
        # Emulation Models only solve one "step" so Horizon and Resolution must match
        IOM.set_horizon!(settings, get_resolution(settings))
    end

    counts = IOM.get_time_series_counts(sys)
    if counts.static_time_series_count < 1
        error(
            "The system does not contain Static Time Series data. A EmulationModel can't be built.",
        )
    end
    return
end
