_btheta(model, T) = IOM.get_expression(_container(model), POM.BThetaBranchFlow, T)

function _check_dcp_against_rebuild(model, builder, out_by_step; template = _dcp_template)
    _check_dcp_solution_against_rebuild(
        model,
        sys -> _dcp_model(sys; template = template()),
        builder,
        out_by_step,
    )
    return
end

@testset "DCP solution follows the topology at each step" begin
    builder = _c_sys5_uc
    sys = builder()
    name = PSY.get_name(first(_sorted(PSY.Line, sys)))
    _schedule_outage!(sys, PSY.get_component(PSY.Line, sys, name), "maint", _maintenance)
    model = _dcp_model(sys)
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, name)])
    _check_dcp_against_rebuild(model, builder, out)
end

@testset "An out arc's B-θ flow is the zero expression" begin
    sys = _c_sys5_uc()
    name = PSY.get_name(first(_sorted(PSY.Line, sys)))
    _schedule_outage!(sys, PSY.get_component(PSY.Line, sys, name), "maint", _maintenance)
    model = _dcp_model(sys)
    flows = _btheta(model, PSY.Line)
    for t in 1:_n_steps(model)
        if t in _OUT_STEPS
            @test isempty(flows[name, t].terms)
            @test JuMP.constant(flows[name, t]) == 0.0
        else
            @test !isempty(flows[name, t].terms)
        end
    end
end

# Ratings loose enough that every rating method leaves c_sys5_uc feasible, so the solved
# rebuild comparison is meaningful.
@testset "DCP partial parallel outage: flows and ratings from the in-service members" begin
    ratings = (3.0, 2.4, 1.5)
    builder = () -> _c_sys5_uc_with_parallel_line(ratings)
    for method in ("single_element_contingency", "sum_of_max", "impedance_averaged")
        sys = builder()
        _schedule_outage!(
            sys,
            PSY.get_component(PSY.Line, sys, "1_copy2"),
            "maint",
            _maintenance,
        )
        line_model = DeviceModel(
            PSY.Line,
            StaticBranch;
            attributes = Dict{String, Any}(POM.PARALLEL_BRANCH_MAX_RATING_KEY => method),
        )
        template = () -> _template_with_line_model(line_model; network = DCPNetworkModel)
        model = _dcp_model(sys; template = template())
        out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, "1_copy2")])
        _check_dcp_against_rebuild(model, builder, out; template = template)

        device_model = IOM.get_model(IOM.get_template(model), PSY.Line)
        group = POM._representative_branch(_network_model(model), PSY.Line, "1")
        remaining = PNM.BranchesParallel([
            PSY.get_component(PSY.Line, sys, "1"),
            PSY.get_component(PSY.Line, sys, "1_copy1"),
        ])
        in_service = POM._parallel_branches_rating(device_model, remaining)
        full = POM._parallel_branches_rating(device_model, group.branch)
        @test !isapprox(in_service, full)
        flows = _btheta(model, PSY.Line)
        ub = _rate_constraint(model, PSY.Line, "ub")
        lb = _rate_constraint(model, PSY.Line, "lb")
        for t in 1:_n_steps(model)
            expected = t in _OUT_STEPS ? in_service : full
            flow = flows[group.name, t]
            @test isapprox(_rating_of(ub[group.name, t], flow), expected; atol = 1e-9)
            @test isapprox(_rating_of(lb[group.name, t], flow), -expected; atol = 1e-9)
        end
    end
end

# Summed, the three circuits never bind; "1_copy2" out leaves 2.2, below the ~2.4-2.6 the arc
# carries at the out steps without a limit, so only the in-service rating yields the rebuild.
const _BINDING_PARALLEL_RATINGS = (1.1, 1.1, 3.0)
_sum_of_max_line_model(formulation) = DeviceModel(
    PSY.Line,
    formulation;
    attributes = Dict{String, Any}(POM.PARALLEL_BRANCH_MAX_RATING_KEY => "sum_of_max"),
)

@testset "DCP partial parallel outage: a binding in-service rating matches the rebuild" begin
    builder = () -> _c_sys5_uc_with_parallel_line(_BINDING_PARALLEL_RATINGS)
    sys = builder()
    _schedule_outage!(
        sys,
        PSY.get_component(PSY.Line, sys, "1_copy2"),
        "maint",
        _maintenance,
    )
    template =
        () -> _template_with_line_model(
            _sum_of_max_line_model(StaticBranch);
            network = DCPNetworkModel,
        )
    model = _dcp_model(sys; template = template())
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, "1_copy2")])
    _check_dcp_against_rebuild(model, builder, out; template = template)
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    flows = JuMP.value.(_btheta(model, PSY.Line))
    for t in _OUT_STEPS
        @test isapprox(abs(flows[group.name, t]), 2.2; atol = 1e-6)
    end
end

@testset "DCP StaticBranchBounds partial parallel outage bounds the flow by the in-service rating" begin
    builder = () -> _c_sys5_uc_with_parallel_line(_BINDING_PARALLEL_RATINGS)
    sys = builder()
    _schedule_outage!(
        sys,
        PSY.get_component(PSY.Line, sys, "1_copy2"),
        "maint",
        _maintenance,
    )
    template =
        () -> _template_with_line_model(
            _sum_of_max_line_model(StaticBranchBounds);
            network = DCPNetworkModel,
        )
    model = _dcp_model(sys; template = template())
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    p = IOM.get_variable(_container(model), POM.FlowActivePowerVariable, PSY.Line)
    full = sum(_BINDING_PARALLEL_RATINGS)
    in_service = sum(_BINDING_PARALLEL_RATINGS[1:2])
    for t in 1:_n_steps(model)
        expected = t in _OUT_STEPS ? in_service : full
        @test isapprox(JuMP.upper_bound(p[group.name, t]), expected; atol = 1e-9)
        @test isapprox(JuMP.lower_bound(p[group.name, t]), -expected; atol = 1e-9)
    end
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, "1_copy2")])
    _check_dcp_against_rebuild(model, builder, out; template = template)
end

function _with_angle_limit!(sys, name, limit)
    PSY.set_angle_limits!(
        PSY.get_component(PSY.Line, sys, name),
        (min = -limit, max = limit),
    )
    return sys
end

_angle_row_coefficients(con, va, from_name, to_name, t) = (
    JuMP.normalized_coefficient(con, va[from_name, t]),
    JuMP.normalized_coefficient(con, va[to_name, t]),
)

_angle_row_bounds(con) = JuMP.constraint_object(con).set

function _arc_bus_names(sys, name)
    arc = PSY.get_arc(PSY.get_component(PSY.Line, sys, name))
    return PSY.get_name(PSY.get_from(arc)), PSY.get_name(PSY.get_to(arc))
end

@testset "An out line's angle limit stops binding its endpoints" begin
    # Line "1" carries at most 0.092 rad in service and 0.18 rad of angle difference opens
    # across it when it is out, so a 0.12 rad limit binds only if it outlives the outage.
    builder = () -> _with_angle_limit!(_c_sys5_uc(), "1", 0.12)
    sys = builder()
    _schedule_outage!(sys, PSY.get_component(PSY.Line, sys, "1"), "maint", _maintenance)
    model = _dcp_model(sys)
    container = _container(model)
    va = IOM.get_variable(container, POM.VoltageAngle, PSY.ACBus)
    cons = IOM.get_constraint(container, POM.AngleDifferenceConstraint, PSY.Line)
    from_name, to_name = _arc_bus_names(sys, "1")
    for t in 1:_n_steps(model)
        coefficients = _angle_row_coefficients(cons["1", t], va, from_name, to_name, t)
        if t in _OUT_STEPS
            @test coefficients == (0.0, 0.0)
        else
            @test coefficients == (1.0, -1.0)
            @test _angle_row_bounds(cons["1", t]) == MOI.Interval(-0.12, 0.12)
        end
    end
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, "1")])
    _check_dcp_against_rebuild(model, builder, out)
    va_values = JuMP.value.(va)
    for t in _OUT_STEPS
        @test abs(va_values[from_name, t] - va_values[to_name, t]) > 0.12
    end
end

@testset "A lone in-service member brings its angle limit at the out steps" begin
    # The parallel pair carries no angle row; with "1_copy1" out, "1" alone would open
    # about 0.06 rad across the arc, beyond its 0.05 rad limit.
    builder =
        () -> _with_angle_limit!(_c_sys5_uc_with_parallel_line((30.0, 30.0)), "1", 0.05)
    sys = builder()
    _schedule_outage!(
        sys,
        PSY.get_component(PSY.Line, sys, "1_copy1"),
        "maint",
        _maintenance,
    )
    model = _dcp_model(sys)
    container = _container(model)
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    va = IOM.get_variable(container, POM.VoltageAngle, PSY.ACBus)
    cons = IOM.get_constraint(container, POM.AngleDifferenceConstraint, PSY.Line)
    from_name, to_name = _arc_bus_names(sys, "1")
    for t in 1:_n_steps(model)
        con = cons[group.name, t]
        coefficients = _angle_row_coefficients(con, va, from_name, to_name, t)
        if t in _OUT_STEPS
            @test coefficients == (1.0, -1.0)
            @test _angle_row_bounds(con) == MOI.Interval(-0.05, 0.05)
        else
            @test coefficients == (0.0, 0.0)
        end
    end
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, "1_copy1")])
    _check_dcp_against_rebuild(model, builder, out)
    va_values = JuMP.value.(va)
    for t in _OUT_STEPS
        @test isapprox(va_values[from_name, t] - va_values[to_name, t], 0.05; atol = 1e-6)
    end
end

# c_sys5_uc with "1_rev", a copy of line "1" (a, b) running from a new bus "stub" to a, and a
# zero-impedance line from b to "stub". The zero-impedance reduction merges "stub" into b, so
# "1_rev" joins the parallel group of "1" on the reversed arc (b, a). Its angle window in its
# own frame is `limits`.
function _c_sys5_uc_with_antiparallel_line(limits)
    sys = _c_sys5_uc()
    line = PSY.get_component(PSY.Line, sys, "1")
    from = PSY.get_from(PSY.get_arc(line))
    to = PSY.get_to(PSY.get_arc(line))
    stub = PSY.ACBus(;
        number = 99,
        name = "stub",
        available = true,
        bustype = PSY.ACBusTypes.PQ,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = PSY.get_base_voltage(to),
        area = PSY.get_area(to),
        load_zone = PSY.get_load_zone(to),
        input_basis = u"CU",
    )
    PSY.add_component!(sys, stub)
    zero_arc = PSY.Arc(; from = to, to = stub)
    PSY.add_component!(sys, zero_arc)
    zero = get_copied_line(line)
    PSY.set_name!(zero, "zero")
    PSY.set_arc!(zero, zero_arc)
    PSY.add_component!(sys, zero)
    PSY.set_r!(zero, 0.0 * u"SU")
    PSY.set_x!(zero, 0.0 * u"SU")
    reversed_arc = PSY.Arc(; from = stub, to = from)
    PSY.add_component!(sys, reversed_arc)
    reversed = get_copied_line(line)
    PSY.set_name!(reversed, "1_rev")
    PSY.set_arc!(reversed, reversed_arc)
    PSY.set_angle_limits!(reversed, limits)
    PSY.add_component!(sys, reversed)
    return sys
end

@testset "A lone anti-parallel member's angle window applies in its own frame" begin
    # "1" alone would open about 0.06 rad from a to b. "1_rev" limits its own θb - θa to
    # [-0.05, 0.3], that is θa - θb to [-0.3, 0.05], which binds; read in the group's frame
    # the window would be [-0.05, 0.3] and leave the angle free.
    builder = () -> _c_sys5_uc_with_antiparallel_line((min = -0.05, max = 0.3))
    sys = builder()
    _schedule_outage!(sys, PSY.get_component(PSY.Line, sys, "1"), "maint", _maintenance)
    model = _dcp_model(sys)
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    a, b = _arc_bus_names(sys, "1")
    nr = IOM.get_network_reduction(_network_model(model))
    @test PNM.get_arc_tuple(PSY.get_component(PSY.Line, sys, "1_rev"), nr) ==
          reverse(group.arc)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    ref_sys = builder()
    PSY.set_available!(PSY.get_component(PSY.Line, ref_sys, "1"), false)
    ref = _dcp_model(ref_sys)
    @test solve!(ref) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    va = JuMP.value.(IOM.get_variable(_container(model), POM.VoltageAngle, PSY.ACBus))
    ref_va = JuMP.value.(IOM.get_variable(_container(ref), POM.VoltageAngle, PSY.ACBus))
    dispatch = _dispatch_values(model)
    ref_dispatch = _dispatch_values(ref)
    for t in _OUT_STEPS
        @test isapprox(va[a, t] - va[b, t], ref_va[a, t] - ref_va[b, t]; atol = 1e-6)
        @test isapprox(va[a, t] - va[b, t], 0.05; atol = 1e-6)
        for g in axes(ref_dispatch, 1)
            @test isapprox(dispatch[g, t], ref_dispatch[g, t]; atol = 1e-5)
        end
    end
end

@testset "A lone anti-parallel member's operational limits apply in its own frame" begin
    set_limit!(line, ft_mw, tf_mw) = PSY.set_operational_flow_limit!(
        line,
        (from_to = (min = 0.0 * u"MW", max = ft_mw * u"MW"),
            to_from = (min = 0.0 * u"MW", max = tf_mw * u"MW")),
    )
    function builder(; out)
        sys = _c_sys5_uc_with_antiparallel_line((min = -1.0, max = 1.0))
        line = PSY.get_component(PSY.Line, sys, "1")
        set_limit!(line, 60.0, 70.0)
        # "1_rev" runs from b to a: its own from-to limit bounds the flow from b to a.
        set_limit!(PSY.get_component(PSY.Line, sys, "1_rev"), 30.0, 10.0)
        out && _schedule_outage!(sys, line, "maint", _maintenance)
        return sys
    end
    attributes = Dict{String, Any}(POM.PARALLEL_BRANCH_MAX_RATING_KEY => "sum_of_max")
    template =
        () -> _template_with_line_model(
            DeviceModel(PSY.Line, StaticBranch; attributes = attributes);
            network = DCPNetworkModel,
        )
    rows(model) = (
        ft = IOM.get_constraint(
            _container(model), POM.OperationalFlowLimitConstraint, PSY.Line, "ft"),
        tf = IOM.get_constraint(
            _container(model), POM.OperationalFlowLimitConstraint, PSY.Line, "tf"),
    )
    sys = builder(; out = true)
    model = _dcp_model(sys; template = template())
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    nr = IOM.get_network_reduction(_network_model(model))
    @test PNM.get_arc_tuple(PSY.get_component(PSY.Line, sys, "1_rev"), nr) ==
          reverse(group.arc)
    static = _dcp_model(builder(; out = false); template = template())
    scheduled_rows = rows(model)
    static_rows = rows(static)
    for t in 1:_n_steps(model)
        ft = JuMP.normalized_rhs(scheduled_rows.ft[group.name, t])
        tf = JuMP.normalized_rhs(scheduled_rows.tf[group.name, t])
        if t in _OUT_STEPS
            # In the group's frame (a, b), "1_rev" allows 10 MW from a to b and 30 MW back.
            @test isapprox(ft, 0.1; atol = 1e-9)
            @test isapprox(tf, 0.3; atol = 1e-9)
        else
            @test ft == JuMP.normalized_rhs(static_rows.ft[group.name, t])
            @test tf == JuMP.normalized_rhs(static_rows.tf[group.name, t])
        end
    end
end

@testset "DCP partial parallel outage: a lone remaining member uses its own rating" begin
    builder = () -> _c_sys5_uc_with_parallel_line((3.0, 2.4))
    sys = builder()
    _schedule_outage!(
        sys,
        PSY.get_component(PSY.Line, sys, "1_copy1"),
        "maint",
        _maintenance,
    )
    model = _dcp_model(sys)
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, "1_copy1")])
    _check_dcp_against_rebuild(model, builder, out)
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    own = PSY.get_rating(PSY.get_component(PSY.Line, sys, "1"), u"SU")
    ub = _rate_constraint(model, PSY.Line, "ub")
    flows = _btheta(model, PSY.Line)
    for t in _OUT_STEPS
        @test isapprox(
            _rating_of(ub[group.name, t], flows[group.name, t]),
            own;
            atol = 1e-9,
        )
    end
end

@testset "DCP partial parallel outage with a branch rating time series" begin
    factor(h) = 0.9 + 0.001 * h
    sys = _c_sys5_uc_with_parallel_line((1.0, 0.8, 0.5))
    members = [
        PSY.get_component(PSY.Line, sys, n) for n in ("1", "1_copy1", "1_copy2")
    ]
    for member in members
        _attach_forecast_schedule!(sys, member, "branch_rating", factor)
    end
    _schedule_outage!(sys, last(members), "maint", _maintenance)
    line_model = DeviceModel(
        PSY.Line,
        StaticBranch;
        time_series_names = Dict(BranchRatingTimeSeriesParameter => "branch_rating"),
    )
    model = _dcp_model(
        sys;
        template = _template_with_line_model(line_model; network = DCPNetworkModel),
    )
    device_model = IOM.get_model(IOM.get_template(model), PSY.Line)
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    multiplier = POM._resolve_branch_multiplier(
        BranchRatingTimeSeriesParameter,
        PNM.BranchesParallel(members[1:2]),
        StaticBranch,
        device_model,
    )
    stored = POM._resolve_branch_multiplier(
        BranchRatingTimeSeriesParameter,
        group.branch,
        StaticBranch,
        device_model,
    )
    @test !isapprox(multiplier, stored)
    ub = _rate_constraint(model, PSY.Line, "ub")
    flows = _btheta(model, PSY.Line)
    for t in 1:_n_steps(model)
        expected = factor(t) * (t in _OUT_STEPS ? multiplier : stored)
        @test isapprox(
            _rating_of(ub[group.name, t], flows[group.name, t]),
            expected;
            rtol = 1e-9,
        )
    end
end

@testset "DCP partial outage of a parallel group holding a phase shifter" begin
    # "T" shifts by α = 0.08 and its two copies do not, so every partial outage changes the
    # group's susceptance-weighted shift.
    builder = () -> _c_sys5_uc_with_transformers((0.08, 0.0, 0.0))
    for out_name in ("T_copy2", "T")
        sys = builder()
        _schedule_outage!(
            sys,
            PSY.get_component(PSY.TwoWindingTransformer, sys, out_name),
            "maint",
            _maintenance,
        )
        model = _dcp_model(sys)
        n = _n_steps(model)
        out = _out_by_step(n, _OUT_STEPS, [(PSY.TwoWindingTransformer, out_name)])
        _check_dcp_against_rebuild(model, builder, out)

        nm = _network_model(model)
        rep = POM._representative_branch(nm, PSY.TwoWindingTransformer, "T_copy1")
        ts = POM.get_topology_schedule(nm)
        ref = _dcp_model(_system_without(builder, PSY.TwoWindingTransformer, [out_name]))
        ref_rep = POM._representative_branch(
            _network_model(ref),
            PSY.TwoWindingTransformer,
            "T_copy1",
        )
        expected_b = POM._dc_susceptance(ref_rep)
        expected_shift = POM._dc_shift(ref_rep)
        @test !isapprox(expected_shift, POM._dc_shift(rep))
        for t in _OUT_STEPS
            b, shift = POM._dc_parameters_at(
                rep,
                ts,
                PNM.get_in_service_entry(ts, rep.arc, t),
            )
            @test isapprox(b, expected_b; rtol = 1e-12)
            @test isapprox(shift, expected_shift; atol = 1e-12)
        end
    end
end

@testset "A StaticBranchBounds line out carries no flow through its flow constraint" begin
    builder = _c_sys5_uc
    sys = builder()
    name = PSY.get_name(first(_sorted(PSY.Line, sys)))
    _schedule_outage!(sys, PSY.get_component(PSY.Line, sys, name), "maint", _maintenance)
    template =
        () -> _template_with_line_model(
            DeviceModel(PSY.Line, StaticBranchBounds);
            network = DCPNetworkModel,
        )
    model = _dcp_model(sys; template = template())
    container = _container(model)
    p = IOM.get_variable(container, POM.FlowActivePowerVariable, PSY.Line)
    cons = IOM.get_constraint(container, POM.NetworkFlowConstraint, PSY.Line)
    for t in 1:_n_steps(model)
        @test !JuMP.is_fixed(p[name, t])
        func = JuMP.constraint_object(cons[name, t]).func
        if t in _OUT_STEPS
            @test func == JuMP.AffExpr(0.0, p[name, t] => 1.0)
            @test JuMP.normalized_rhs(cons[name, t]) == 0.0
        else
            @test length(func.terms) == 3
        end
    end
    out = _out_by_step(_n_steps(model), _OUT_STEPS, [(PSY.Line, name)])
    _check_dcp_against_rebuild(model, builder, out; template = template)
    for t in _OUT_STEPS
        @test isapprox(JuMP.value(p[name, t]), 0.0; atol = 1e-9)
    end
end

@testset "A DCP schedule with everything in service matches the static model" begin
    sys = _c_sys5_uc()
    _schedule_outage!(sys, first(_sorted(PSY.Line, sys)), "maint", h -> 0.0)
    model = _dcp_model(sys)
    static = _dcp_model(_c_sys5_uc())
    flows = _btheta(model, PSY.Line)
    static_flows = _btheta(static, PSY.Line)
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
        @test _affexpr_approx_equal(flows[name, t], rename(static_flows[name, t]))
    end
end
