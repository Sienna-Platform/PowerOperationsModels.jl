@testset "PTDF flow rows carry no residue coefficients" begin
    # The PTDF entries of the radial arcs to nodeC_ext2 are within the tolerance of -1. A
    # generator on that bus puts them into the flow rows.
    c_sys5_radial = PSB.build_system(PSITestSystems, "c_sys5_radial")
    PSY.set_bus!(
        PSY.get_component(PSY.ThermalStandard, c_sys5_radial, "Solitude"),
        PSY.get_component(PSY.ACBus, c_sys5_radial, "nodeC_ext2"),
    )
    template = get_thermal_dispatch_template_network(PTDFNetworkModel)
    model = DecisionModel(template, c_sys5_radial; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    flow = IOM.get_expression(container, POM.PTDFBranchFlow, PSY.Line)
    coefficients = [abs(c) for e in flow.data for (c, _) in JuMP.linear_terms(e)]
    @test !isempty(coefficients)
    @test all(c -> c > IOM.EXPRESSION_ROUNDING_TOL, coefficients)
    @test any(isone, coefficients)
    @test !any(c -> 0 < abs(c - 1) <= IOM.EXPRESSION_ROUNDING_TOL, coefficients)
end
