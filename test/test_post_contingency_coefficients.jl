@testset "flow expressions are sized by the terms of the nodal expressions" begin
    m = JuMP.Model()
    x = JuMP.@variable(m, [1:3])
    nodal = JuMP.AffExpr[
        JuMP.AffExpr(0.0, x[1] => 1.0) JuMP.AffExpr(0.0)
        JuMP.AffExpr(1.0, x[1] => 1.0, x[2] => 2.0, x[3] => 3.0) JuMP.AffExpr(0.0, x[2] => 1.0)
    ]
    counts = POM._nodal_term_counts(nodal)
    @test counts == [1 0; 3 1]
    @test POM._term_hint(counts, [1, 2], 1) == 4
    @test POM._term_hint(counts, [1, 2], 2) == 1
    @test POM._term_hint(counts, [2], 1) == 3
    @test POM._term_hint(counts, Int[], 1) == 0
end

@testset "rating rows keep the function and set of the macro form" begin
    m = JuMP.Model()
    x = JuMP.@variable(m, [1:2])
    s = JuMP.@variable(m)
    expr = JuMP.AffExpr(0.75, x[1] => 2.0, x[2] => -3.0)
    original = copy(expr)

    ub = POM._add_rating_row!(m, expr, nothing, -1.0, MOI.LessThan{Float64}, 4.5)
    lb = POM._add_rating_row!(m, expr, nothing, 1.0, MOI.GreaterThan{Float64}, -4.5)
    ub_slack = POM._add_rating_row!(m, expr, s, -1.0, MOI.LessThan{Float64}, 4.5)
    lb_slack = POM._add_rating_row!(m, expr, s, 1.0, MOI.GreaterThan{Float64}, -4.5)
    @test JuMP.isequal_canonical(expr, original)

    reference = JuMP.Model()
    y = JuMP.@variable(reference, [1:2])
    t = JuMP.@variable(reference)
    ref_expr = JuMP.AffExpr(0.75, y[1] => 2.0, y[2] => -3.0)
    ref_ub = JuMP.@constraint(reference, ref_expr - 0.0 <= 4.5)
    ref_lb = JuMP.@constraint(reference, ref_expr + 0.0 >= -4.5)
    ref_ub_slack = JuMP.@constraint(reference, ref_expr - t <= 4.5)
    ref_lb_slack = JuMP.@constraint(reference, ref_expr + t >= -4.5)
    for (con, ref) in
        ((ub, ref_ub), (lb, ref_lb), (ub_slack, ref_ub_slack), (lb_slack, ref_lb_slack))
        a = JuMP.constraint_object(con)
        b = JuMP.constraint_object(ref)
        @test JuMP.moi_set(a) == JuMP.moi_set(b)
        fa = JuMP.jump_function(a)
        fb = JuMP.jump_function(b)
        for (u, v) in ((x[1], y[1]), (x[2], y[2]), (s, t))
            @test JuMP.coefficient(fa, u) == JuMP.coefficient(fb, v)
        end
        @test JuMP.constant(fa) == JuMP.constant(fb)
        @test length(JuMP.linear_terms(fa)) == length(JuMP.linear_terms(fb))
    end
end

@testset "rating rows with a parameterized bound keep the parameter term" begin
    m = JuMP.Model()
    x = JuMP.@variable(m, [1:2])
    s = JuMP.@variable(m)
    p = JuMP.@variable(m)
    JuMP.fix(p, 0.9)
    expr = JuMP.AffExpr(0.75, x[1] => 2.0, x[2] => -3.0)
    original = copy(expr)
    bound = 0.5 * p * 5.0

    ub = POM._add_rating_row!(m, expr, nothing, -1.0, MOI.LessThan{Float64}, bound)
    lb = POM._add_rating_row!(m, expr, nothing, 1.0, MOI.GreaterThan{Float64}, -1.0 * bound)
    ub_slack = POM._add_rating_row!(m, expr, s, -1.0, MOI.LessThan{Float64}, bound)
    lb_slack =
        POM._add_rating_row!(m, expr, s, 1.0, MOI.GreaterThan{Float64}, -1.0 * bound)
    @test JuMP.isequal_canonical(expr, original)

    reference = JuMP.Model()
    y = JuMP.@variable(reference, [1:2])
    t = JuMP.@variable(reference)
    q = JuMP.@variable(reference)
    ref_expr = JuMP.AffExpr(0.75, y[1] => 2.0, y[2] => -3.0)
    ref_ub = JuMP.@constraint(reference, ref_expr <= 2.5 * q)
    ref_lb = JuMP.@constraint(reference, ref_expr >= -2.5 * q)
    ref_ub_slack = JuMP.@constraint(reference, ref_expr - t <= 2.5 * q)
    ref_lb_slack = JuMP.@constraint(reference, ref_expr + t >= -2.5 * q)
    for (con, ref) in
        ((ub, ref_ub), (lb, ref_lb), (ub_slack, ref_ub_slack), (lb_slack, ref_lb_slack))
        a = JuMP.constraint_object(con)
        b = JuMP.constraint_object(ref)
        @test JuMP.moi_set(a) == JuMP.moi_set(b)
        fa = JuMP.jump_function(a)
        fb = JuMP.jump_function(b)
        for (u, v) in ((x[1], y[1]), (x[2], y[2]), (s, t), (p, q))
            @test JuMP.coefficient(fa, u) == JuMP.coefficient(fb, v)
        end
        @test JuMP.constant(fa) == JuMP.constant(fb)
        @test length(JuMP.linear_terms(fa)) == length(JuMP.linear_terms(fb))
    end
end

@testset "post-contingency rating rows equal the flow expression" begin
    for use_slacks in (false, true)
        sys = PSB.build_system(PSITestSystems, "c_sys5"; add_forecasts = true)
        for n in ("1", "2", "3")
            _add_contingency!(
                sys,
                [PSY.get_component(PSY.Line, sys, n)],
                _sorted(PSY.Line, sys),
            )
        end
        template = _sc_template()
        Logging.with_logger(Logging.NullLogger()) do
            set_device_model!(
                template,
                DeviceModel(
                    PSY.Line,
                    SecurityConstrainedStaticBranch;
                    use_slacks = use_slacks,
                ),
            )
        end
        model = _built_model(template, sys)
        flows = _post_contingency_flows(model, PSY.Line)
        con_ub = _post_contingency_constraints(model, PSY.Line, "ub")
        con_lb = _post_contingency_constraints(model, PSY.Line, "lb")
        container = _container(model)
        slack_ub, slack_lb = if use_slacks
            (
                IOM.get_variable(
                    container,
                    POM.PostContingencyFlowActivePowerSlackUpperBound,
                    PSY.Line,
                ),
                IOM.get_variable(
                    container,
                    POM.PostContingencyFlowActivePowerSlackLowerBound,
                    PSY.Line,
                ),
            )
        else
            (nothing, nothing)
        end
        checked = 0
        for k in keys(flows.data)
            expr = flows[k...]
            ub = JuMP.constraint_object(con_ub[k...])
            lb = JuMP.constraint_object(con_lb[k...])
            expected_ub = expr - JuMP.constant(expr)
            expected_lb = expr - JuMP.constant(expr)
            if use_slacks
                JuMP.add_to_expression!(expected_ub, -1.0, slack_ub[k...])
                JuMP.add_to_expression!(expected_lb, 1.0, slack_lb[k...])
            end
            @test JuMP.isequal_canonical(JuMP.jump_function(ub), expected_ub)
            @test JuMP.isequal_canonical(JuMP.jump_function(lb), expected_lb)
            ub_set = JuMP.moi_set(ub)
            lb_set = JuMP.moi_set(lb)
            @test ub_set isa MOI.LessThan
            @test lb_set isa MOI.GreaterThan
            @test MOI.constant(ub_set) + JuMP.constant(expr) >=
                  MOI.constant(lb_set) + JuMP.constant(expr)
            checked += 1
        end
        @test checked > 0
    end
end
