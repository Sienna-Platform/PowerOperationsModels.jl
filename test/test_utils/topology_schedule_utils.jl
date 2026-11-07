function _attach_forecast_schedule!(sys, owner, name, pattern)
    initial_times = collect(PSY.get_forecast_initial_times(sys))
    horizon = PSY.get_forecast_horizon(sys)
    resolution = first(PSY.get_time_series_resolutions(sys))
    steps = Int(horizon ÷ resolution)
    data = SortedDict{Dates.DateTime, Vector{Float64}}()
    for t0 in initial_times
        data[t0] = [Float64(pattern(h)) for h in 1:steps]
    end
    PSY.add_time_series!(
        sys,
        owner,
        PSY.Deterministic(; name = name, data = data, resolution = resolution),
    )
    return
end

# A switch "tie" parallel to the first line, scheduled `pattern(h)` (1.0 means closed).
function _sys_with_scheduled_switch(pattern = h -> 1.0)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_forecasts = true)
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    switch = PSY.DiscreteControlledACBranch(nothing)
    switch.name = "tie"
    switch.arc = PSY.get_arc(line)
    switch.x = 0.05
    switch.available = true
    switch.branch_status = PSY.DiscreteControlledBranchStatus.OPEN
    PSY.add_component!(sys, switch)
    _attach_forecast_schedule!(sys, switch, PNM.BRANCH_STATUS_SCHEDULE, pattern)
    return sys, switch
end

_c_sys5_uc() = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_forecasts = true)

# An availability schedule on `component` whose forecast windows are out where `pattern(h)`
# is 1.0, where `h` counts the window's steps from 1.
function _schedule_outage!(sys, component, pattern)
    _attach_forecast_schedule!(
        sys,
        component,
        PNM.AVAILABLE_SCHEDULE,
        h -> 1.0 - pattern(h),
    )
    return
end

_sorted(T, sys) = sort!(collect(PSY.get_components(T, sys)); by = PSY.get_name)

function _ptdf_model(
    sys;
    network = PTDFNetworkModel,
    template = get_thermal_dispatch_template_network(NetworkModel(network)),
)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

_n_steps(model) = length(IOM.get_time_steps(IOM.get_optimization_container(model)))

# A `_schedule_outage!` pattern that is out at `steps`.
_out_at(steps) = h -> h in steps ? 1.0 : 0.0

function _built_model(template, sys; kwargs...)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, kwargs...)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

function _read_build_log(model)
    return read(joinpath(IOM.get_output_dir(model), IOM.PROBLEM_LOG_FILENAME), String)
end

function _build_for_log(model)
    return build!(
        model;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.AboveMaxLevel,
    )
end

_fixed_at_zero(v::JuMP.VariableRef) = JuMP.is_fixed(v) && JuMP.fix_value(v) == 0.0

# Rebuild `model` in place, as a simulation step with `rebuild_model = true` does.
function _rebuild!(model, sys)
    container = IOM.get_optimization_container(model)
    IOM.set_rebuild_model!(IOM.get_settings(container), true)
    IOM.reset_optimization_model!(container)
    POM.build_problem!(container, IOM.get_template(model), sys)
    return container
end

const _OUT_STEPS = 3:5
_maintenance(h) = h in _OUT_STEPS ? 1.0 : 0.0

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
