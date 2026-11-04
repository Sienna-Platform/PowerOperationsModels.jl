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
    @test all(c -> c > IOM.EXPRESSION_ROUNDING_TOL, coefficients)
end
