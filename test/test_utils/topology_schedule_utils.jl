function _attach_forecast_schedule!(sys, outage, name, pattern)
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
        outage,
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
    schedule = PSY.SwitchingSchedule(; status_schedule = "tie_status")
    PSY.add_supplemental_attribute!(sys, switch, schedule)
    _attach_forecast_schedule!(sys, schedule, "tie_status", pattern)
    return sys, switch
end

_c_sys5_uc() = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_forecasts = true)

# A `PlannedOutage` on `component` whose forecast windows all follow `pattern(h)`, where
# `h` counts the window's steps from 1; 1.0 means out.
function _schedule_outage!(sys, component, name, pattern)
    outage = PSY.PlannedOutage(; outage_schedule = name)
    PSY.add_supplemental_attribute!(sys, component, outage)
    _attach_forecast_schedule!(sys, outage, name, pattern)
    return outage
end

_sorted(T, sys) = sort!(collect(PSY.get_components(T, sys)); by = PSY.get_name)

# A copy of `sys` with `names` of type `T` unavailable: the reference for one step.
function _system_without(builder, T, names)
    sys = builder()
    for n in names
        PSY.set_available!(PSY.get_component(T, sys, n), false)
    end
    return sys
end

# Affine expressions are compared up to round-off: the sparse factorization backend is not
# bit-reproducible across independent builds.
function _affexpr_approx_equal(actual, expected; atol = 1e-8)
    isapprox(JuMP.constant(actual), JuMP.constant(expected); atol = atol) || return false
    keys_all = union(keys(actual.terms), keys(expected.terms))
    return all(
        isapprox(get(actual.terms, k, 0.0), get(expected.terms, k, 0.0); atol = atol) for
        k in keys_all
    )
end

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

# `items` (pairs of component type and name) out at `steps`, nothing out at the other steps.
_out_by_step(n, steps, items) =
    [
        t in steps ? collect(Tuple{DataType, String}, items) : Tuple{DataType, String}[]
        for
        t in 1:n
    ]

_n_steps(model) = length(IOM.get_time_steps(IOM.get_optimization_container(model)))

const _FLOW_BRANCH_TYPES =
    (PSY.Line, PSY.TwoWindingTransformer, PSY.DiscreteControlledACBranch)

# Every `PTDFBranchFlow[name, t]` at `steps` equals Σ PTDF_ref[arc, bus]·balance[bus, t] -
# shift_ref, with PTDF_ref = `reference_matrix(make_reference(key_by_step[t]))`; steps sharing
# a key share it.
function _check_flows_against_references(
    model,
    key_by_step,
    make_reference;
    reference_matrix = PNM.PTDF,
    steps = eachindex(key_by_step),
)
    container = IOM.get_optimization_container(model)
    nm = IOM.get_network_model(IOM.get_template(model))
    catalog = POM.get_branch_catalog(nm)
    nodal = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
    references = Dict{Any, PNM.PTDF}()
    for t in steps
        key = key_by_step[t]
        ref = get!(() -> reference_matrix(make_reference(key)), references, key)
        ref_nr = PNM.get_network_reduction_data(ref)
        for T in _FLOW_BRANCH_TYPES
            IOM.has_container_key(container, POM.PTDFBranchFlow, T) || continue
            flows = IOM.get_expression(container, POM.PTDFBranchFlow, T)
            for (name, arc) in PNM.get_name_to_arc_map(catalog, T)
                expected = JuMP.AffExpr(0.0)
                # A reference built without a branch can file an equivalent left on its arc
                # (a Ward equivalent) in the opposite orientation; its flow then flips sign.
                ref_arc, sign = arc, 1.0
                if !haskey(PNM.get_arc_lookup(ref), arc)
                    ref_arc, sign = (arc[2], arc[1]), -1.0
                end
                if haskey(PNM.get_arc_lookup(ref), ref_arc)
                    for bus in PNM.get_bus_axis(ref)
                        coef = sign * ref[ref_arc, bus]
                        abs(coef) > POM.PTDF_ZERO_TOL || continue
                        JuMP.add_to_expression!(expected, coef, nodal[bus, t])
                    end
                    JuMP.add_to_expression!(
                        expected,
                        -sign * PNM.arc_dc_shift_injection(ref_nr, ref_arc),
                    )
                end
                @test _affexpr_approx_equal(flows[name, t], expected; atol = 1e-6)
            end
        end
    end
    return
end

# The rebuild oracle: at step `t` the reference is `builder()` with the components listed
# in `out_by_step[t]` unavailable.
function _check_flows_against_rebuild(model, builder, out_by_step; kwargs...)
    make_reference = function (out)
        sys = builder()
        for (T, n) in out
            PSY.set_available!(PSY.get_component(T, sys, n), false)
        end
        return sys
    end
    _check_flows_against_references(model, out_by_step, make_reference; kwargs...)
    return
end

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
_dispatch_values(model) =
    JuMP.value.(
        IOM.get_variable(_container(model), POM.ActivePowerVariable, PSY.ThermalStandard)
    )
_rate_constraint(model, T, meta) =
    IOM.get_constraint(
        _container(model),
        IOM.ConstraintKey(POM.FlowRateConstraint, T, meta),
    )
_network_model(model) = IOM.get_network_model(IOM.get_template(model))
# A rating row `flow <= rating` is stored as `terms <= rating - constant(flow)`.
_rating_of(con, flow) = JuMP.normalized_rhs(con) + JuMP.constant(flow)

# c_sys5_uc with its last line replaced by parallel two-winding transformers on the same arc,
# one per phase shift in `αs`: "T", then "T_copy<k>". The circuits' base power is the
# system's, so their device-base values are the line's system-base values.
function _c_sys5_uc_with_transformers(αs)
    sys = _c_sys5_uc()
    line = last(_sorted(PSY.Line, sys))
    for (k, α) in enumerate(αs)
        transformer = PSY.TwoWindingTransformer(;
            name = k == 1 ? "T" : "T_copy$(k - 1)",
            circuit = PSY.TransformerCircuit(;
                available = true,
                arc = PSY.get_arc(line),
                r = PSY.get_r(line, u"SU"),
                x = PSY.get_x(line, u"SU"),
                tap = 1.0,
                α = α,
                rating = PSY.get_rating(line, u"SU"),
                base_power = PSY.get_base_power(sys, u"NU"),
                input_basis = u"CU",
            ),
            magnetizing_shunt = 0.0 + 0.0im,
            shunt_location = PSY.TwoWindingTransformerShuntLocation.PRIMARY,
            input_basis = u"CU",
        )
        PSY.add_component!(sys, transformer)
    end
    PSY.remove_component!(sys, line)
    return sys
end

_c_sys5_uc_with_transformer(; α = 0.0) = _c_sys5_uc_with_transformers((α,))

# c_sys5_uc with `ratings` (system base) parallel circuits on line "1": the line itself keeps
# the first rating and the copies, named "1_copy<k>", take the others.
function _c_sys5_uc_with_parallel_line(ratings)
    sys = _c_sys5_uc()
    line = PSY.get_component(PSY.Line, sys, "1")
    for k in 2:length(ratings)
        copy = get_copied_line(line)
        PSY.set_name!(copy, "1_copy$(k - 1)")
        PSY.add_component!(sys, copy)
        PSY.set_rating!(copy, ratings[k] * u"SU")
    end
    PSY.set_rating!(line, ratings[1] * u"SU")
    return sys
end

function _template_with_line_model(line_model; network = PTDFNetworkModel)
    template = get_thermal_dispatch_template_network(NetworkModel(network))
    set_device_model!(template, line_model)
    return template
end

# The solved values of a DCP model: dispatch by generator, voltage angle by bus number, and
# the active flow of every reduced arc in its own frame, each as one value per time step. A
# StaticBranch flow is its `BThetaBranchFlow` expression; other formulations carry
# `FlowActivePowerVariable`.
function _dcp_solution(model)
    container = _container(model)
    sys = IOM.get_system(model)
    catalog = POM.get_branch_catalog(_network_model(model))
    dispatch_values = _dispatch_values(model)
    dispatch = Dict(g => collect(dispatch_values[g, :]) for g in axes(dispatch_values, 1))
    va = JuMP.value.(IOM.get_variable(container, POM.VoltageAngle, PSY.ACBus))
    angles = Dict(
        PSY.get_number(PSY.get_component(PSY.ACBus, sys, b)) => collect(va[b, :]) for
        b in axes(va, 1)
    )
    flows = Dict{Tuple{DataType, Tuple{Int, Int}}, Vector{Float64}}()
    for T in _FLOW_BRANCH_TYPES
        values = if IOM.has_container_key(container, POM.BThetaBranchFlow, T)
            JuMP.value.(IOM.get_expression(container, POM.BThetaBranchFlow, T))
        elseif IOM.has_container_key(container, POM.FlowActivePowerVariable, T)
            JuMP.value.(IOM.get_variable(container, POM.FlowActivePowerVariable, T))
        else
            continue
        end
        arc_map = PNM.get_name_to_arc_map(catalog, T)
        for name in axes(values, 1)
            key = (T, arc_map[name])
            @assert !haskey(flows, key) "two rows of $T share arc $(arc_map[name])"
            flows[key] = collect(values[name, :])
        end
    end
    return (dispatch = dispatch, angles = angles, flows = flows)
end

_angle_difference(solution, arc, t) =
    solution.angles[arc[1]][t] - solution.angles[arc[2]][t]

# The DCP rebuild oracle: solve `model`, and for every distinct entry of `out_by_step` solve
# `make_model` on `builder()` with those components unavailable. At each step the dispatch,
# the angle difference across every arc of `model`, and the flow of every arc agree with that
# step's rebuild; an arc missing from the rebuild carries no flow.
# The comparison of solved values assumes each LP has a unique optimum, which holds on the
# fixtures used here (generators with distinct costs, no ties). On a fixture with degenerate
# optima the two solves could return different optimal points, so compare flows and objective
# terms there instead.
function _check_dcp_solution_against_rebuild(model, make_model, builder, out_by_step)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    solution = _dcp_solution(model)
    for key in unique(out_by_step)
        ref_sys = builder()
        for (T, n) in key
            PSY.set_available!(PSY.get_component(T, ref_sys, n), false)
        end
        ref = make_model(ref_sys)
        @test solve!(ref) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        expected = _dcp_solution(ref)
        for t in findall(==(key), out_by_step)
            for (g, values) in expected.dispatch
                @test isapprox(solution.dispatch[g][t], values[t]; atol = 1e-5)
            end
            for ((T, arc), values) in solution.flows
                @test isapprox(
                    _angle_difference(solution, arc, t),
                    _angle_difference(expected, arc, t);
                    atol = 1e-5,
                )
                reference_flow =
                    get(() -> zeros(length(values)), expected.flows, (T, arc))[t]
                @test isapprox(values[t], reference_flow; atol = 1e-5)
            end
        end
    end
    return
end

_dcp_template() = get_thermal_dispatch_template_network(NetworkModel(DCPNetworkModel))
_dcp_model(sys; template = _dcp_template()) = _built_model(template, sys)

# A copy of `builder()` with every `(type, name)` in `items` unavailable.
function _system_without_items(builder, items)
    sys = builder()
    for (T, n) in items
        PSY.set_available!(PSY.get_component(T, sys, n), false)
    end
    return sys
end

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
_is_zero_expression(e::JuMP.AffExpr) =
    iszero(JuMP.constant(e)) && all(iszero, values(e.terms))
# The post-contingency relaxation slacks of `V`, empty when the model has none.
function _post_contingency_slacks(model, V)
    slacks = Set{JuMP.VariableRef}()
    for S in (
        POM.PostContingencyFlowActivePowerSlackUpperBound,
        POM.PostContingencyFlowActivePowerSlackLowerBound,
    )
        IOM.has_container_key(_container(model), S, V) || continue
        union!(slacks, values(IOM.get_variable(_container(model), S, V).data))
    end
    return slacks
end

# A rating row whose only nonzero coefficients are on relaxation slacks binds nothing.
_is_inert_row(con, slacks) = all(
    iszero(c) || v in slacks for (v, c) in JuMP.constraint_object(con).func.terms
)

"""
The steps at which the post-contingency entry `(outage_id, name)` of `V` carries a limit.
Every step has an entry in the flow container and in both rating containers; at the other
steps the flow is the zero expression and both rating rows are inert: no flow term, at most
the row's relaxation slack.
"""
function _limited_post_contingency_steps(model, V, outage_id, name)
    flows = _post_contingency_flows(model, V)
    rows = (
        _post_contingency_constraints(model, V, "ub"),
        _post_contingency_constraints(model, V, "lb"),
    )
    slacks = _post_contingency_slacks(model, V)
    limited = Int[]
    for t in 1:_n_steps(model)
        key = (outage_id, name, t)
        @test haskey(flows.data, key)
        @test all(haskey(c.data, key) for c in rows)
        if _is_zero_expression(flows.data[key])
            @test all(_is_inert_row(c.data[key], slacks) for c in rows)
        else
            push!(limited, t)
        end
    end
    return limited
end

# Each arc's DC shift injection in the network of `ptdf`, by arc tuple.
function _shift_injections(ptdf)
    nr = PNM.get_network_reduction_data(ptdf)
    return Dict(
        arc => PNM.arc_dc_shift_injection(nr, arc) for arc in PNM.get_arc_axis(ptdf)
    )
end

"""
The union-rebuild reference for a post-contingency flow on a PTDF network: the flow of
`arc` at step `t` on `builder()` with `step_out` and `ctg_out` unavailable, as an expression
in `model`'s nodal balance at `t`.

The balance at `t` holds the shift injections of the step network (`builder()` with
`step_out` unavailable), so each arc's change from the step network to the post-contingency
network enters through the reference row, and the monitored arc's own offset is the
post-contingency one. An arc absent from the post-contingency network carries no flow.
"""
function _ptdf_post_contingency_reference(model, builder, arc, t, step_out, ctg_out)
    nodal = IOM.get_expression(_container(model), POM.ActivePowerBalance, PSY.ACBus)
    ref = PNM.PTDF(_system_without_items(builder, vcat(step_out, ctg_out)))
    expected = JuMP.AffExpr(0.0)
    haskey(PNM.get_arc_lookup(ref), arc) || return expected
    for bus in PNM.get_bus_axis(ref)
        coef = ref[arc, bus]
        abs(coef) > POM.PTDF_ZERO_TOL || continue
        JuMP.add_to_expression!(expected, coef, nodal[bus, t])
    end
    post = _shift_injections(ref)
    step = _shift_injections(PNM.PTDF(_system_without_items(builder, step_out)))
    for a in union(keys(post), keys(step))
        change = get(post, a, 0.0) - get(step, a, 0.0)
        iszero(change) && continue
        JuMP.add_to_expression!(expected, change * (ref[arc, a[1]] - ref[arc, a[2]]))
    end
    JuMP.add_to_expression!(expected, -post[arc])
    return expected
end

"""
The union-rebuild reference for a post-contingency flow on a DCP network: the post-contingency
PTDF row of `arc` (`builder()` with `step_out` and `ctg_out` unavailable) times nodal
injections recovered by KCL over the raw PSY arcs of every `FlowActivePowerVariable` of
`types`, independently of the production balance-filtering path.
"""
function _dcp_post_contingency_reference(model, builder, arc, t, step_out, ctg_out; types)
    container = _container(model)
    injections = Dict{Int, JuMP.AffExpr}()
    for T in types
        flows = IOM.get_variable(container, POM.FlowActivePowerVariable, T)
        for component in PSY.get_components(T, IOM.get_system(model))
            name = PSY.get_name(component)
            name in axes(flows, 1) || continue
            component_arc = PSY.get_arc(component)
            from_no = PSY.get_number(PSY.get_from(component_arc))
            to_no = PSY.get_number(PSY.get_to(component_arc))
            JuMP.add_to_expression!(
                get!(JuMP.AffExpr, injections, from_no), 1.0, flows[name, t],
            )
            JuMP.add_to_expression!(
                get!(JuMP.AffExpr, injections, to_no), -1.0, flows[name, t],
            )
        end
    end
    ref = PNM.PTDF(_system_without_items(builder, vcat(step_out, ctg_out)))
    expected = JuMP.AffExpr(0.0)
    haskey(PNM.get_arc_lookup(ref), arc) || return expected
    for bus in PNM.get_bus_axis(ref)
        coef = ref[arc, bus]
        abs(coef) > POM.PTDF_ZERO_TOL || continue
        JuMP.add_to_expression!(expected, coef, get(injections, bus, JuMP.AffExpr(0.0)))
    end
    return expected
end

# The c_sys5 security-constrained model with contingencies on lines "1", "2", "3" and line "3"
# scheduled out at `_OUT_STEPS`.
function _c_sys5_scheduled_security_constrained_model()
    sys = PSB.build_system(PSITestSystems, "c_sys5"; add_forecasts = true)
    for n in ("1", "2", "3")
        _add_contingency!(
            sys,
            [PSY.get_component(PSY.Line, sys, n)],
            _sorted(PSY.Line, sys),
        )
    end
    _schedule_outage!(sys, PSY.get_component(PSY.Line, sys, "3"), "maint", _maintenance)
    return _built_model(_sc_template(), sys)
end
