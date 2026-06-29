@testset "native DCPLLNetworkModel builds and solves (c_sys5)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(DCPLLNetworkModel))
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    res = IOM.OptimizationProblemOutputs(model)
    base = IOM.get_model_base_power(res)
    # Directional flows exist and respect the line rating (system base → MW).
    pft = read_variable(
        res, "FlowActivePowerFromToVariable__Line"; table_format = TableFormat.WIDE,
    )
    for line in PSY.get_components(PSY.Line, sys)
        name = PSY.get_name(line)
        @test name in names(pft)
        rate_mw = PSY.get_rating(line, PSY.SU) * base
        @test all(abs.(pft[!, name]) .<= rate_mw + 1e-4)
    end
end

@testset "DCPLL costs no less than lossless DCP (c_sys5)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")

    function _solve_obj(net, opt)
        template = get_thermal_dispatch_template_network(NetworkModel(net))
        model = DecisionModel(template, sys; optimizer = opt)
        @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        return JuMP.objective_value(IOM.get_jump_model(model))
    end

    dcp_obj = _solve_obj(DCPNetworkModel, HiGHS_optimizer)
    dcpll_obj = _solve_obj(DCPLLNetworkModel, ipopt_optimizer)
    # Losses can only add cost; allow a small solver tolerance.
    @test dcpll_obj >= dcp_obj - 1e-3 * max(1.0, abs(dcp_obj))
end
