@testset "round_to_zero_or_one! snaps and drops coefficients" begin
    m = JuMP.Model()
    JuMP.@variable(m, x[1:5])
    expr = JuMP.AffExpr(3.5)
    for (v, c) in zip(x, [1e-12, 1 + 5e-10, -(1 + 5e-10), 0.25, -1e-12])
        JuMP.add_to_expression!(expr, c, v)
    end
    POM.round_to_zero_or_one!(expr)
    @test !haskey(expr.terms, x[1])
    @test !haskey(expr.terms, x[5])
    @test expr.terms[x[2]] === 1.0
    @test expr.terms[x[3]] === -1.0
    @test expr.terms[x[4]] === 0.25
    @test length(expr.terms) == 3
    @test JuMP.constant(expr) == 3.5
end

@testset "PTDF flow rows carry no residue coefficients" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(PTDFNetworkModel)
    model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    flow = IOM.get_expression(container, POM.PTDFBranchFlow, PSY.Line)
    coefficients = [abs(c) for e in flow.data for (c, _) in JuMP.linear_terms(e)]
    @test !isempty(coefficients)
    @test all(c -> c > POM.EXPRESSION_ROUNDING_TOL, coefficients)
end
