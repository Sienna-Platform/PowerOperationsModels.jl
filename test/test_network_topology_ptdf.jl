_flows(model, T) = IOM.get_expression(_container(model), POM.PTDFBranchFlow, T)
_flow_values(model, T) = JuMP.value.(_flows(model, T))

@testset "PTDF flows follow the topology at each step" begin
    builder = _c_sys5_uc
    sys = builder()
    line = first(_sorted(PSY.Line, sys))
    _schedule_outage!(sys, line, _maintenance)
    model = _ptdf_model(sys)
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, PSY.get_name(line))])
    _check_flows_against_rebuild(model, builder, out)
end

# c_sys5_uc split into two areas: buses 1-2 and buses 3-5.
function _c_sys5_uc_two_areas()
    sys = _c_sys5_uc()
    areas = [PSY.Area("Area_1", 0.0, 0.0, 0.0), PSY.Area("Area_2", 0.0, 0.0, 0.0)]
    foreach(a -> PSY.add_component!(sys, a), areas)
    for bus in PSY.get_components(PSY.ACBus, sys)
        PSY.set_area!(bus, areas[1 + (PSY.get_number(bus) > 2)])
    end
    return sys
end

@testset "AreaPTDF flows follow the topology at each step" begin
    builder = _c_sys5_uc_two_areas
    sys = builder()
    line = first(_sorted(PSY.Line, sys))
    _schedule_outage!(sys, line, _maintenance)
    model = _ptdf_model(sys; network = AreaPTDFNetworkModel)
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, PSY.get_name(line))])
    _check_flows_against_rebuild(model, builder, out)
end

@testset "An out arc carries no flow and keeps its rating rows" begin
    sys = _c_sys5_uc()
    line = first(_sorted(PSY.Line, sys))
    name = PSY.get_name(line)
    _schedule_outage!(sys, line, _maintenance)
    model = _ptdf_model(sys)
    flows = _flows(model, PSY.Line)
    lb = _rate_constraint(model, PSY.Line, "lb")
    ub = _rate_constraint(model, PSY.Line, "ub")
    for t in 1:_n_steps(model)
        if t in _OUT_STEPS
            @test isempty(flows[name, t].terms)
            @test JuMP.constant(flows[name, t]) == 0.0
        else
            @test !isempty(flows[name, t].terms)
        end
        @test JuMP.is_valid(IOM.get_jump_model(_container(model)), lb[name, t])
        @test JuMP.is_valid(IOM.get_jump_model(_container(model)), ub[name, t])
    end
end

@testset "Dispatch matches per-step rebuilds" begin
    builder = _c_sys5_uc
    sys = builder()
    line = first(_sorted(PSY.Line, sys))
    name = PSY.get_name(line)
    _schedule_outage!(sys, line, _maintenance)
    model = _ptdf_model(sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    dispatch = _dispatch_values(model)
    flow = _flow_values(model, PSY.Line)
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, name)])
    for key in unique(out)
        ref = _ptdf_model(_system_without(builder, PSY.Line, last.(key)))
        @test solve!(ref) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        ref_dispatch = _dispatch_values(ref)
        ref_flow = _flow_values(ref, PSY.Line)
        for t in findall(==(key), out)
            @test all(
                isapprox(dispatch[g, t], ref_dispatch[g, t]; atol = 1e-5) for
                g in axes(ref_dispatch, 1)
            )
            @test all(
                isapprox(flow[l, t], ref_flow[l, t]; atol = 1e-5) for l in axes(ref_flow, 1)
            )
            isempty(key) || @test isapprox(flow[name, t], 0.0; atol = 1e-9)
        end
    end
end

@testset "Partial parallel outage: flows and ratings from the in-service members" begin
    ratings = (1.0, 0.8, 0.5)
    builder = () -> _c_sys5_uc_with_parallel_line(ratings)
    for method in ("single_element_contingency", "sum_of_max", "impedance_averaged")
        sys = builder()
        _schedule_outage!(
            sys,
            PSY.get_component(PSY.Line, sys, "1_copy2"),
            _maintenance,
        )
        line_model = DeviceModel(
            PSY.Line,
            StaticBranch;
            attributes = Dict{String, Any}(POM.PARALLEL_BRANCH_MAX_RATING_KEY => method),
        )
        model = _ptdf_model(sys; template = _template_with_line_model(line_model))
        out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, "1_copy2")])
        _check_flows_against_rebuild(model, builder, out)

        device_model = IOM.get_model(IOM.get_template(model), PSY.Line)
        group = POM._representative_branch(_network_model(model), PSY.Line, "1")
        remaining = PNM.BranchesParallel([
            PSY.get_component(PSY.Line, sys, "1"),
            PSY.get_component(PSY.Line, sys, "1_copy1"),
        ])
        in_service = POM._parallel_branches_rating(device_model, remaining)
        full = POM._parallel_branches_rating(device_model, group.branch)
        @test !isapprox(in_service, full)
        ub = _rate_constraint(model, PSY.Line, "ub")
        flows = _flows(model, PSY.Line)
        lb = _rate_constraint(model, PSY.Line, "lb")
        for t in 1:_n_steps(model)
            expected = ifelse(t in _OUT_STEPS, in_service, full)
            flow = flows[group.name, t]
            @test isapprox(_rating_of(ub[group.name, t], flow), expected; atol = 1e-9)
            @test isapprox(_rating_of(lb[group.name, t], flow), -expected; atol = 1e-9)
        end
    end
end

@testset "Partial parallel outage: a lone remaining member uses its own rating" begin
    builder = () -> _c_sys5_uc_with_parallel_line((1.0, 0.8))
    for method in ("single_element_contingency", "sum_of_max", "impedance_averaged")
        sys = builder()
        _schedule_outage!(
            sys,
            PSY.get_component(PSY.Line, sys, "1_copy1"),
            _maintenance,
        )
        line_model = DeviceModel(
            PSY.Line,
            StaticBranch;
            attributes = Dict{String, Any}(POM.PARALLEL_BRANCH_MAX_RATING_KEY => method),
        )
        model = _ptdf_model(sys; template = _template_with_line_model(line_model))
        out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, "1_copy1")])
        _check_flows_against_rebuild(model, builder, out)
        group = POM._representative_branch(_network_model(model), PSY.Line, "1")
        own = PSY.get_rating(PSY.get_component(PSY.Line, sys, "1"), u"SU")
        ub = _rate_constraint(model, PSY.Line, "ub")
        flows = _flows(model, PSY.Line)
        for t in _OUT_STEPS
            @test isapprox(
                _rating_of(ub[group.name, t], flows[group.name, t]),
                own;
                atol = 1e-9,
            )
        end
    end
end

# Only line "1" carries the series, as its own rating. Its fraction of that rating applies
# to the rating of whichever entry is in service.
@testset "Partial parallel outage with a branch rating time series" begin
    fraction(h) = 0.9 + 0.001 * h
    for ratings in ((1.0, 0.8, 0.5), (1.0, 0.8))
        sys = _c_sys5_uc_with_parallel_line(ratings)
        members = [PSY.get_component(PSY.Line, sys, "1")]
        for k in 1:(length(ratings) - 1)
            push!(members, PSY.get_component(PSY.Line, sys, "1_copy$k"))
        end
        _attach_rating_series!(
            sys,
            first(members),
            "branch_rating",
            fraction,
            first(ratings),
        )
        _schedule_outage!(sys, last(members), _maintenance)
        line_model = DeviceModel(
            PSY.Line,
            StaticBranch;
            time_series_names = Dict(BranchRatingTimeSeriesParameter => "branch_rating"),
        )
        model = _ptdf_model(sys; template = _template_with_line_model(line_model))
        group = POM._representative_branch(_network_model(model), PSY.Line, "1")
        in_service = members[1:(end - 1)]
        subset = if length(in_service) == 1
            only(in_service)
        else
            PNM.BranchesParallel(in_service)
        end
        partial = _static_series_rating(subset)
        full = _static_series_rating(group.branch)
        @test !isapprox(partial, full)
        ub = _rate_constraint(model, PSY.Line, "ub")
        flows = _flows(model, PSY.Line)
        for t in 1:_n_steps(model)
            expected = fraction(t) * ifelse(t in _OUT_STEPS, partial, full)
            @test isapprox(
                _rating_of(ub[group.name, t], flows[group.name, t]),
                expected;
                rtol = 1e-9,
            )
        end
    end
end

@testset "A rating time series stops applying while its parallel member is out" begin
    sys = _c_sys5_uc_with_parallel_line((1.0, 0.8))
    line = PSY.get_component(PSY.Line, sys, "1")
    copy = PSY.get_component(PSY.Line, sys, "1_copy1")
    _attach_rating_series!(sys, line, "branch_rating", h -> 0.5, 1.0)
    _schedule_outage!(sys, line, _maintenance)
    line_model = DeviceModel(
        PSY.Line,
        StaticBranch;
        time_series_names = Dict(BranchRatingTimeSeriesParameter => "branch_rating"),
    )
    model = _ptdf_model(sys; template = _template_with_line_model(line_model))
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    ub = _rate_constraint(model, PSY.Line, "ub")
    lb = _rate_constraint(model, PSY.Line, "lb")
    flows = _flows(model, PSY.Line)
    summed = PNM.get_sum_of_max_rating(group.branch)
    for t in 1:_n_steps(model)
        expected = ifelse(t in _OUT_STEPS, PSY.get_rating(copy, u"SU"), 0.5 * summed)
        flow = flows[group.name, t]
        @test isapprox(_rating_of(ub[group.name, t], flow), expected; rtol = 1e-9)
        @test isapprox(_rating_of(lb[group.name, t], flow), -expected; rtol = 1e-9)
    end
end

@testset "A scheduled branch without a device model still changes the topology" begin
    builder = () -> _c_sys5_uc_with_transformer(; alpha = 0.1)
    sys = builder()
    _schedule_outage!(
        sys,
        PSY.get_component(PSY.TwoWindingTransformer, sys, "T"),
        _maintenance,
    )
    template = PowerOperationsProblemTemplate(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranch)
    model = _ptdf_model(sys; template = template)
    @test !IOM.has_container_key(
        _container(model),
        POM.PTDFBranchFlow,
        PSY.TwoWindingTransformer,
    )
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.TwoWindingTransformer, "T")])
    _check_flows_against_rebuild(model, builder, out)
end

@testset "A scheduled switch closes and opens per step" begin
    closed_steps = 2:3
    pattern = h -> ifelse(h in closed_steps, 1.0, 0.0)
    sys, _ = _sys_with_scheduled_switch(pattern)
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, PSY.DiscreteControlledACBranch, StaticBranch)
    model = _ptdf_model(sys; template = template)
    key_by_step = [t in closed_steps for t in 1:_n_steps(model)]
    make_reference = function (closed)
        ref_sys, switch = _sys_with_scheduled_switch(pattern)
        if closed
            PSY.set_branch_status!(switch, PSY.DiscreteControlledBranchStatus.CLOSED)
        else
            PSY.set_available!(switch, false)
        end
        return ref_sys
    end
    _check_flows_against_references(model, key_by_step, make_reference)
end

@testset "A phase-shifting transformer scheduled out drops its shift injection" begin
    builder = () -> _c_sys5_uc_with_transformer(; alpha = 0.1)
    sys = builder()
    _schedule_outage!(
        sys,
        PSY.get_component(PSY.TwoWindingTransformer, sys, "T"),
        _maintenance,
    )
    model = _ptdf_model(sys)
    static = _ptdf_model(builder())
    n = _n_steps(model)
    _check_flows_against_rebuild(
        model,
        builder,
        _out_by_step(n, _OUT_STEPS, [(PSY.TwoWindingTransformer, "T")]),
    )
    arc =
        POM._representative_branch(
            _network_model(static),
            PSY.TwoWindingTransformer,
            "T",
        ).arc
    injection =
        PNM.arc_dc_shift_injection(IOM.get_network_reduction(_network_model(static)), arc)
    @test !iszero(injection)
    nodal = IOM.get_expression(_container(model), POM.ActivePowerBalance, PSY.ACBus)
    static_nodal = IOM.get_expression(_container(static), POM.ActivePowerBalance, PSY.ACBus)
    for t in 1:n
        dropped = ifelse(t in _OUT_STEPS, injection, 0.0)
        @test isapprox(
            JuMP.constant(nodal[arc[1], t]),
            JuMP.constant(static_nodal[arc[1], t]) - dropped;
            atol = 1e-9,
        )
        @test isapprox(
            JuMP.constant(nodal[arc[2], t]),
            JuMP.constant(static_nodal[arc[2], t]) + dropped;
            atol = 1e-9,
        )
    end
end

# The nodal shift injections at the out steps match a model built without "T_copy1", so an
# error shared by the scheduled model's flows and balances still shows up.
@testset "A partial parallel outage of phase-shifting transformers updates the shift injection" begin
    builder = () -> _c_sys5_uc_with_transformers((0.1, 0.05))
    sys = builder()
    _schedule_outage!(
        sys,
        PSY.get_component(PSY.TwoWindingTransformer, sys, "T_copy1"),
        _maintenance,
    )
    model = _ptdf_model(sys)
    static = _ptdf_model(builder())
    reference =
        _ptdf_model(_system_without(builder, PSY.TwoWindingTransformer, ["T_copy1"]))
    arc =
        POM._representative_branch(
            _network_model(static),
            PSY.TwoWindingTransformer,
            "T",
        ).arc
    injection(m) =
        PNM.arc_dc_shift_injection(IOM.get_network_reduction(_network_model(m)), arc)
    @test !isapprox(injection(static), injection(reference))
    nodal(m) = IOM.get_expression(_container(m), POM.ActivePowerBalance, PSY.ACBus)
    for t in 1:_n_steps(model), bus in arc
        expected = if t in _OUT_STEPS
            reference
        else
            static
        end
        @test isapprox(
            JuMP.constant(nodal(model)[bus, t]),
            JuMP.constant(nodal(expected)[bus, t]);
            atol = 1e-9,
        )
    end
end

# With its ties "A" and "E" out at `_OUT_STEPS`, the pocket sits on an island without a
# reference bus, so the shifted transformer "P" carries no flow there and its shift adds no
# offset. At the other steps every flow matches the static model.
@testset "A shifted branch on an island without a reference bus carries no flow" begin
    builder = () -> _c_sys5_uc_with_pocket(; alpha = 0.1)
    model = _ptdf_model(_cut_off_pocket!(builder()))
    n = _n_steps(model)
    connected = setdiff(1:n, _OUT_STEPS)
    rep = POM._representative_branch(_network_model(model), PSY.TwoWindingTransformer, "P")
    @test !iszero(
        PNM.arc_dc_shift_injection(
            IOM.get_network_reduction(_network_model(model)),
            rep.arc,
        ),
    )
    flows = _flows(model, PSY.TwoWindingTransformer)
    for t in _OUT_STEPS
        @test isempty(JuMP.linear_terms(flows["P", t]))
        @test JuMP.constant(flows["P", t]) == 0.0
    end
    # The pocket's buses hold no injectors, so their nodal constants are the shift alone.
    injection = PNM.arc_dc_shift_injection(
        IOM.get_network_reduction(_network_model(model)),
        rep.arc,
    )
    nodal = IOM.get_expression(_container(model), POM.ActivePowerBalance, PSY.ACBus)
    for t in 1:n
        expected = ifelse(t in _OUT_STEPS, 0.0, injection)
        @test isapprox(JuMP.constant(nodal[rep.arc[1], t]), expected; atol = 1e-9)
        @test isapprox(JuMP.constant(nodal[rep.arc[2], t]), -expected; atol = 1e-9)
    end
    _check_flows_against_rebuild(
        model,
        builder,
        _out_by_step(n, Int[], Tuple{DataType, String}[]);
        steps = connected,
    )
end

# The cut-off pocket of `_c_sys5_uc_with_pocket` with bus 7 in its own area, so the shifted
# transformer "P" ties two areas.
function _two_area_pocket(; alpha)
    sys = _cut_off_pocket!(_c_sys5_uc_with_pocket(; alpha = alpha))
    areas = [PSY.Area("Area_1", 0.0, 0.0, 0.0), PSY.Area("Area_2", 0.0, 0.0, 0.0)]
    foreach(a -> PSY.add_component!(sys, a), areas)
    for bus in PSY.get_components(PSY.ACBus, sys)
        PSY.set_area!(bus, areas[1 + (PSY.get_number(bus) == 7)])
    end
    return sys
end

# The area balances do not see the shift of "P": they match those of an unshifted pocket at
# every step, connected or cut off.
@testset "A shifted branch between areas adds no shift to the area balances" begin
    area_balance(alpha) = IOM.get_expression(
        _container(
            _ptdf_model(_two_area_pocket(; alpha = alpha); network = AreaPTDFNetworkModel),
        ),
        POM.ActivePowerBalance,
        PSY.Area,
    )
    shifted = area_balance(0.1)
    unshifted = area_balance(0.0)
    for area in ("Area_1", "Area_2"), t in axes(shifted, 2)
        @test isapprox(
            JuMP.constant(shifted[area, t]),
            JuMP.constant(unshifted[area, t]);
            atol = 1e-9,
        )
    end
end

# The pocket of `_cut_off_pocket!` with "P" phase-controlled to keep its flow within
# `quantity_limits`, built on `network`.
function _phase_controlled_pocket_model(quantity_limits; network = PTDFNetworkModel)
    sys = _cut_off_pocket!(_c_sys5_uc_with_pocket())
    circuit = PSY.get_circuit(PSY.get_component(PSY.TwoWindingTransformer, sys, "P"))
    PSY.set_control_objective!(circuit, P_FLOW_CONTROL)
    PSY.set_regulated_bus!(circuit, PSY.get_bus(sys, 7))
    _set_control_bands!(
        circuit,
        P_FLOW_CONTROL,
        quantity_limits,
        _default_control_limits(P_FLOW_CONTROL),
    )
    template = _controlled_template(network, PSY.TwoWindingTransformer)
    return _ptdf_model(sys; template = template)
end

_has_term(expression, variable) = !iszero(JuMP.coefficient(expression, variable))

# A phase-controlled "P" on the cut-off pocket drops its angle term at `_OUT_STEPS`, from its
# flow and from the pocket's nodal balances, and keeps it at the other steps.
@testset "A phase-controlled branch on an island without a reference bus carries no flow" begin
    model = _phase_controlled_pocket_model(_default_quantity_limits(P_FLOW_CONTROL))
    container = _container(model)
    angle = IOM.get_variable(container, POM.PhaseShifterAngle, PSY.TwoWindingTransformer)
    flows = _flows(model, PSY.TwoWindingTransformer)
    nodal = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
    for t in 1:_n_steps(model)
        connected = !(t in _OUT_STEPS)
        @test isempty(JuMP.linear_terms(flows["P", t])) == !connected
        @test _has_term(flows["P", t], angle["P", t]) == connected
        connected || @test JuMP.constant(flows["P", t]) == 0.0
        for bus in (6, 7)
            @test _has_term(nodal[bus, t], angle["P", t]) == connected
        end
    end
end

# A target band that excludes zero has no rows where the cut-off pocket carries no flow, so
# the model stays feasible. On DCP the radial pocket's zero nodal balances force its flow to
# zero whatever the phase angle.
@testset "A flow-control band does not apply on an island without a reference bus on $(network)" for network in
                                                                                                    (
    PTDFNetworkModel,
    DCPNetworkModel,
)
    model = _phase_controlled_pocket_model((min = 0.2, max = 0.5); network = network)
    cons = IOM.get_constraint(
        _container(model),
        POM.ActivePowerFlowControlConstraint,
        PSY.TwoWindingTransformer,
    )
    for t in 1:_n_steps(model), k in 1:2
        @test haskey(cons, ("P", k, t)) == !(t in _OUT_STEPS)
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "A schedule with everything in service matches the static model" begin
    sys = _c_sys5_uc()
    _schedule_outage!(sys, first(_sorted(PSY.Line, sys)), h -> 0.0)
    model = _ptdf_model(sys)
    static = _ptdf_model(_c_sys5_uc())
    flows = _flows(model, PSY.Line)
    static_flows = _flows(static, PSY.Line)
    @test axes(flows) == axes(static_flows)
    # Both builds add the same variables in the same order, so a variable of the static
    # model maps to the variable with the same index in the scheduled model.
    jump_model = IOM.get_jump_model(_container(model))
    @test JuMP.num_variables(jump_model) ==
          JuMP.num_variables(IOM.get_jump_model(_container(static)))
    rename(e) = JuMP.AffExpr(
        JuMP.constant(e),
        Dict(JuMP.VariableRef(jump_model, JuMP.index(v)) => c for (v, c) in e.terms)...,
    )
    for name in axes(flows, 1), t in axes(flows, 2)
        @test _affexpr_approx_equal(
            flows[name, t],
            rename(static_flows[name, t]);
            atol = 1e-8,
        )
    end
end

# c_sys5_uc's ramp limits make ThermalStandardDispatch infeasible even with every branch in
# service; half the unit's capacity per hour keeps the ramp rows in place and feasible.
function _c_sys5_uc_rampable()
    sys = _c_sys5_uc()
    for g in PSY.get_components(PSY.ThermalStandard, sys)
        ramp = PSY.get_active_power_limits(g, u"SU").max / 2 / 60
        PSY.set_ramp_limits!(g, (up = ramp * u"SU/minute", down = ramp * u"SU/minute"))
    end
    return sys
end

@testset "Ramp-constrained dispatch with a line out solves and follows the topology" begin
    builder = _c_sys5_uc_rampable
    sys = builder()
    line = first(_sorted(PSY.Line, sys))
    _schedule_outage!(sys, line, _maintenance)
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalStandardDispatch)
    model = _ptdf_model(sys; template = template)
    @test IOM.has_container_key(
        _container(model),
        POM.RampConstraint,
        PSY.ThermalStandard,
        "up",
    )
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, PSY.get_name(line))])
    _check_flows_against_rebuild(model, builder, out)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test JuMP.termination_status(IOM.get_jump_model(_container(model))) == JuMP.OPTIMAL
end

_c_sys14() = PSB.build_system(PSITestSystems, "c_sys14")
_ward_source(study) = SystemNetworkSource(PNM.NetworkReduction[WardReduction(study)])
_ward_ptdf(study) =
    sys -> PNM.PTDF(sys; network_reductions = PNM.NetworkReduction[WardReduction(study)])

function _component_on_arc(T, sys, arc)
    return only(
        c for c in PSY.get_components(T, sys) if (
            PSY.get_number(PSY.get_from(PSY.get_arc(c))),
            PSY.get_number(PSY.get_to(PSY.get_arc(c))),
        ) == arc
    )
end

@testset "A branch out of an arc that carries a Ward equivalent leaves the equivalent" begin
    # Buses 4 and 5 bound the study area and are joined by a line, so the Ward equivalent of
    # the external network lands on the line's own arc.
    study = [1, 2, 3, 4, 5]
    arc = (4, 5)
    sys = _c_sys14()
    name = PSY.get_name(_component_on_arc(PSY.Line, sys, arc))
    _schedule_outage!(sys, PSY.get_component(PSY.Line, sys, name), _maintenance)
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; network_source = _ward_source(study)),
    )
    model = _ptdf_model(sys; template = template)
    nm = _network_model(model)
    ward = PNM.get_added_arc_impedance_map(IOM.get_network_reduction(nm))[arc]
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, name)])
    _check_flows_against_rebuild(model, _c_sys14, out; reference_matrix = _ward_ptdf(study))
    flows = _flows(model, PSY.Line)
    ub = _rate_constraint(model, PSY.Line, "ub")
    own = PSY.get_rating(PSY.get_component(PSY.Line, sys, name), u"SU")
    for t in 1:_n_steps(model)
        @test !isempty(flows[name, t].terms)
        expected = ifelse(t in _OUT_STEPS, PNM.get_equivalent_rating(ward), own)
        @test isapprox(_rating_of(ub[name, t], flows[name, t]), expected; rtol = 1e-12)
    end
end

@testset "A phase-controlled transformer out of a Ward-shared arc drops its angle" begin
    # With bus 9 in the study area, the Ward equivalent lands on Trans1's arc (4, 9).
    study = [1, 2, 3, 4, 5, 9]
    pst = TRANSFORMER_NAMES[MESHED_TRANSFORMER_INDEX]
    builder =
        () ->
            _controlled_sys14(P_FLOW_CONTROL; circuit_index = MESHED_TRANSFORMER_INDEX).sys
    sys = builder()
    transformer = PSY.get_component(PSY.TwoWindingTransformer, sys, pst)
    _schedule_outage!(sys, transformer, _maintenance)
    template = _controlled_template(
        PTDFNetworkModel,
        PSY.TwoWindingTransformer;
        network_source = _ward_source(study),
    )
    model = _ptdf_model(sys; template = template)
    container = _container(model)
    nm = _network_model(model)
    rep = POM._representative_branch(nm, PSY.TwoWindingTransformer, pst)
    @test haskey(PNM.get_added_arc_impedance_map(IOM.get_network_reduction(nm)), rep.arc)
    ts = POM.get_topology_sequence(nm)
    angle = IOM.get_variable(container, POM.PhaseShifterAngle, PSY.TwoWindingTransformer)
    flows = _flows(model, PSY.TwoWindingTransformer)
    nodal = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
    n = _n_steps(model)
    for t in 1:n
        own = !(t in _OUT_STEPS)
        @test !PNM.is_arc_out(ts, rep.arc, t)
        @test POM._own_entry_conducts(rep, ts, t) == own
        # The Ward equivalent that conducts in the transformer's place carries no shift, so
        # the arc's constant injection is zero at the steps the angle term is dropped.
        own || @test iszero(PNM.get_arc_shift_injection(ts, rep.arc, t))
        a = angle[pst, t]
        @test haskey(flows[pst, t].terms, a) == own
        @test haskey(nodal[rep.arc[1], t].terms, a) == own
        @test haskey(nodal[rep.arc[2], t].terms, a) == own
    end
    out = _out_by_step(n, _OUT_STEPS, [(PSY.TwoWindingTransformer, pst)])
    _check_flows_against_rebuild(
        model,
        builder,
        out;
        reference_matrix = _ward_ptdf(study),
        steps = _OUT_STEPS,
    )
end

@testset "PTDF StaticBranchBounds partial parallel outage bounds the flow by the in-service rating" begin
    ratings = (1.1, 1.1, 3.0)
    builder = () -> _c_sys5_uc_with_parallel_line(ratings)
    sys = builder()
    _schedule_outage!(
        sys,
        PSY.get_component(PSY.Line, sys, "1_copy2"),
        _maintenance,
    )
    line_model = DeviceModel(
        PSY.Line,
        StaticBranchBounds;
        attributes = Dict{String, Any}(POM.PARALLEL_BRANCH_MAX_RATING_KEY => "sum_of_max"),
    )
    model = _ptdf_model(sys; template = _template_with_line_model(line_model))
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    p = IOM.get_variable(_container(model), POM.FlowActivePowerVariable, PSY.Line)
    for t in 1:_n_steps(model)
        expected = ifelse(t in _OUT_STEPS, sum(ratings[1:2]), sum(ratings))
        @test isapprox(JuMP.upper_bound(p[group.name, t]), expected; atol = 1e-9)
        @test isapprox(JuMP.lower_bound(p[group.name, t]), -expected; atol = 1e-9)
    end
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, "1_copy2")])
    _check_flows_against_rebuild(model, builder, out)
end

# Operational limits of a parallel group combine the members in service at each step: with
# "1_copy1" out, the arc takes the limit of "1" alone, on the `OperationalFlowLimitConstraint`
# rows of StaticBranch and on the flow bounds of StaticBranchBounds.
@testset "Partial parallel outage: operational limits from the in-service members" begin
    set_limit!(line, ft_mw, tf_mw) = PSY.set_operational_flow_limit!(
        line,
        (from_to = (min = 0.0 * u"MW", max = ft_mw * u"MW"),
            to_from = (min = 0.0 * u"MW", max = tf_mw * u"MW")),
    )
    sys = _c_sys5_uc_with_parallel_line((1.0, 0.8))
    set_limit!(PSY.get_component(PSY.Line, sys, "1"), 60.0, 70.0)
    set_limit!(PSY.get_component(PSY.Line, sys, "1_copy1"), 30.0, 20.0)
    _schedule_outage!(
        sys,
        PSY.get_component(PSY.Line, sys, "1_copy1"),
        _maintenance,
    )
    expected_at(t) = ifelse(t in _OUT_STEPS, (ft = 0.6, tf = 0.7), (ft = 0.9, tf = 0.9))
    attributes = Dict{String, Any}(POM.PARALLEL_BRANCH_MAX_RATING_KEY => "sum_of_max")
    template(formulation) = _template_with_line_model(
        DeviceModel(PSY.Line, formulation; attributes = attributes),
    )

    model = _ptdf_model(sys; template = template(StaticBranch))
    container = _container(model)
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    flows = _flows(model, PSY.Line)
    ft = IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "ft")
    tf = IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "tf")
    for t in 1:_n_steps(model)
        flow = flows[group.name, t]
        # `flow <= ft` and `-flow <= tf`, with the flow's constant on the right side.
        @test isapprox(
            JuMP.normalized_rhs(ft[group.name, t]) + JuMP.constant(flow),
            expected_at(t).ft;
            atol = 1e-9,
        )
        @test isapprox(
            JuMP.normalized_rhs(tf[group.name, t]) - JuMP.constant(flow),
            expected_at(t).tf;
            atol = 1e-9,
        )
    end

    model = _ptdf_model(sys; template = template(StaticBranchBounds))
    flow_variable =
        IOM.get_variable(_container(model), POM.FlowActivePowerVariable, PSY.Line)
    for t in 1:_n_steps(model)
        v = flow_variable[group.name, t]
        @test isapprox(JuMP.upper_bound(v), expected_at(t).ft; atol = 1e-9)
        @test isapprox(JuMP.lower_bound(v), -expected_at(t).tf; atol = 1e-9)
    end
end

# Line "1" has a zero-rated parallel copy: the arc is bounded by the line's rating while
# both conduct, but the copy alone would pin the arc to zero flow while the line is out.
@testset "A zero-rated circuit left alone on its arc by an outage is rejected" begin
    function system(; out)
        sys = _c_sys5_uc_with_parallel_line((2.0, 0.0))
        line = PSY.get_component(PSY.Line, sys, "1")
        out && _schedule_outage!(sys, line, _maintenance)
        return sys
    end
    template() = _template_with_line_model(DeviceModel(Line, StaticBranch))
    in_service =
        DecisionModel(template(), system(; out = false); optimizer = HiGHS_optimizer)
    @test _build_for_log(in_service) == IOM.ModelBuildStatus.BUILT
    model = DecisionModel(template(), system(; out = true); optimizer = HiGHS_optimizer)
    @test _build_for_log(model) == IOM.ModelBuildStatus.FAILED
    log_text = _read_build_log(model)
    @test occursin("1_copy1", log_text)
    @test occursin("zero rating", log_text)
end

@testset "A zero-rated circuit left alone on its arc is rejected as a variable bound" begin
    function system(; out)
        sys = _c_sys5_uc_with_parallel_line((2.0, 0.0))
        line = PSY.get_component(PSY.Line, sys, "1")
        out && _schedule_outage!(sys, line, _maintenance)
        return sys
    end
    template() = _template_with_line_model(DeviceModel(Line, StaticBranchBounds))
    in_service =
        DecisionModel(template(), system(; out = false); optimizer = HiGHS_optimizer)
    @test _build_for_log(in_service) == IOM.ModelBuildStatus.BUILT
    model = DecisionModel(template(), system(; out = true); optimizer = HiGHS_optimizer)
    @test _build_for_log(model) == IOM.ModelBuildStatus.FAILED
    log_text = _read_build_log(model)
    @test occursin("1_copy1", log_text)
    @test occursin("zero rating", log_text)
end

# Line "1" carries the rating series; while it is out, its zero-rated copy alone rates the
# arc with its static rating.
@testset "A zero-rated circuit left alone by the rating-series carrier is rejected" begin
    function system(; out)
        sys = _c_sys5_uc_with_parallel_line((2.0, 0.0))
        line = PSY.get_component(PSY.Line, sys, "1")
        _attach_rating_series!(sys, line, "branch_rating", h -> 0.5, 2.0)
        out && _schedule_outage!(sys, line, _maintenance)
        return sys
    end
    template() = _template_with_line_model(
        DeviceModel(
            PSY.Line,
            StaticBranch;
            time_series_names = Dict(BranchRatingTimeSeriesParameter => "branch_rating"),
        ),
    )
    in_service =
        DecisionModel(template(), system(; out = false); optimizer = HiGHS_optimizer)
    @test _build_for_log(in_service) == IOM.ModelBuildStatus.BUILT
    model = DecisionModel(template(), system(; out = true); optimizer = HiGHS_optimizer)
    @test _build_for_log(model) == IOM.ModelBuildStatus.FAILED
    log_text = _read_build_log(model)
    @test occursin("1_copy1", log_text)
    @test occursin("zero rating", log_text)
end

# A target band with a positive minimum cannot hold on a transformer that carries no flow.
@testset "A flow-control band stops applying while its transformer is out on $(network)" for network in
                                                                                             (
    PTDFNetworkModel,
    DCPNetworkModel,
)
    pst = TRANSFORMER_NAMES[MESHED_TRANSFORMER_INDEX]
    function system(; out)
        sys =
            _controlled_sys14(
                P_FLOW_CONTROL;
                circuit_index = MESHED_TRANSFORMER_INDEX,
                quantity_limits = (min = 0.1, max = 0.2),
            ).sys
        transformer = PSY.get_component(PSY.TwoWindingTransformer, sys, pst)
        out && _schedule_outage!(sys, transformer, _maintenance)
        return sys
    end
    template() = _controlled_template(network, PSY.TwoWindingTransformer)
    in_service = _ptdf_model(system(; out = false); template = template())
    @test solve!(in_service) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    model = _ptdf_model(system(; out = true); template = template())
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    cons = IOM.get_constraint(
        _container(model),
        POM.ActivePowerFlowControlConstraint,
        PSY.TwoWindingTransformer,
    )
    for t in 1:_n_steps(model), k in 1:2
        @test haskey(cons, (pst, k, t)) == !(t in _OUT_STEPS)
    end
    # Every constraint container of the model must iterate without undefined entries.
    @test !isempty(IOM.get_all_constraint_index(model))
end
