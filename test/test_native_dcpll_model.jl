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

@testset "native DCPLL supports StaticBranch use_slacks" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(DCPLLNetworkModel))
    set_device_model!(template, DeviceModel(Line, StaticBranch; use_slacks = true))
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)

    # Slack variables exist and the rating is enforced as a slacked constraint pair,
    # not as hard variable bounds (a hard bound would make the slack meaningless).
    slack_ub = IOM.get_variable(container, FlowActivePowerSlackUpperBound, Line)
    slack_lb = IOM.get_variable(container, FlowActivePowerSlackLowerBound, Line)
    pft = IOM.get_variable(container, FlowActivePowerFromToVariable, Line)
    t1 = first(IOM.get_time_steps(container))
    lname = first(axes(pft)[1])
    @test lname in axes(slack_ub)[1]
    @test lname in axes(slack_lb)[1]
    @test !JuMP.has_upper_bound(pft[lname, t1])
    constraints = IOM.get_constraints(container)
    for meta in ("ft_ub", "ft_lb", "tf_ub", "tf_lb")
        @test haskey(constraints, IOM.ConstraintKey(FlowRateConstraint, Line, meta))
    end

    # With ample ratings the slacks are driven to zero at the optimum.
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    res = IOM.OptimizationProblemOutputs(model)
    slack_vals = read_variable(
        res, "FlowActivePowerSlackUpperBound__Line"; table_format = TableFormat.WIDE,
    )
    @test all(all(abs.(slack_vals[!, c]) .<= 1e-4) for c in names(slack_vals)[2:end])
end
