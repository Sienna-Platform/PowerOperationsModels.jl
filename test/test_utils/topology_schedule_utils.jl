_sorted(T, sys) = sort!(collect(PSY.get_components(T, sys)); by = PSY.get_name)

function _built_model(template, sys; kwargs...)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, kwargs...)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

_container(model) = IOM.get_optimization_container(model)

# A contingency on `components` monitoring `monitored`; returns its outage id as the
# post-contingency containers key it.
function _add_contingency!(sys, components, monitored)
    outage = PSY.FixedForcedOutage(; outage_status = 1.0, monitored_components = monitored)
    for component in components
        PSY.add_supplemental_attribute!(sys, component, outage)
    end
    return string(IS.get_id(outage))
end

# A thermal dispatch template on `network` with a `SecurityConstrainedStaticBranch` model for
# every type in `sc_types`.
function _sc_template(; network = PTDFNetworkModel, sc_types = (PSY.Line,))
    template = get_thermal_dispatch_template_network(NetworkModel(network))
    for T in sc_types
        Logging.with_logger(Logging.NullLogger()) do
            set_device_model!(template, T, SecurityConstrainedStaticBranch)
        end
    end
    return template
end

_post_contingency_flows(model, V) =
    IOM.get_expression(_container(model), POM.PostContingencyBranchFlow, V)
_post_contingency_constraints(model, V, meta) =
    IOM.get_constraint(
        _container(model),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, V, meta),
    )
