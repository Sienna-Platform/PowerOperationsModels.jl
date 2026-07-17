@testset "native NFANetworkModel builds and solves (c_sys5)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(NFANetworkModel))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    res = IOM.OptimizationProblemOutputs(model)
    flow = read_variable(
        res, "FlowActivePowerVariable__Line"; table_format = TableFormat.WIDE,
    )
    # Transportation model: every line flow respects its rating (system base → MW).
    base = IOM.get_model_base_power(res)
    for line in PSY.get_components(PSY.Line, sys)
        rate_mw = PSY.get_rating(line, PSY.SU) * base
        col = PSY.get_name(line)
        @test col in names(flow)
        @test all(abs.(flow[!, col]) .<= rate_mw + 1e-4)
    end
end

@testset "NFA sits between CopperPlate and DCP by relaxation ordering (c_sys5)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")

    function _solve_obj(net)
        template = get_thermal_dispatch_template_network(NetworkModel(net))
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        return JuMP.objective_value(IOM.get_jump_model(model))
    end

    copper_obj = _solve_obj(CopperPlateNetworkModel)
    nfa_obj = _solve_obj(NFANetworkModel)
    dcp_obj = _solve_obj(DCPNetworkModel)

    # Relaxation ordering: looser feasible set ⇒ lower minimized cost.
    tol = 1e-4 * max(1.0, abs(dcp_obj))
    @test copper_obj <= nfa_obj + tol
    @test nfa_obj <= dcp_obj + tol
end

@testset "NFANetworkModel + StaticBranch with use_slacks wires the rating slacks" begin
    # The slack pair must genuinely relax the rating, not sit dead: the ub row is
    # `flow - slack_ub <= rating`, the lb row `flow + slack_lb >= -rating`, the
    # FlowActivePowerVariable carries no hard bound that would cap it at the rating and
    # neuter the slack, and both slacks are priced in the objective.
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(NFANetworkModel))
    set_device_model!(
        template,
        DeviceModel(PSY.Line, StaticBranch; use_slacks = true),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    flow = IOM.get_variable(container, FlowActivePowerVariable, PSY.Line)
    slack_ub = IOM.get_variable(container, FlowActivePowerSlackUpperBound, PSY.Line)
    slack_lb = IOM.get_variable(container, FlowActivePowerSlackLowerBound, PSY.Line)
    con_ub = IOM.get_constraint(container, FlowRateConstraint, PSY.Line, "ub")
    con_lb = IOM.get_constraint(container, FlowRateConstraint, PSY.Line, "lb")
    objective = JuMP.objective_function(IOM.get_jump_model(container))
    time_steps = IOM.get_time_steps(container)
    for line in PSY.get_components(PSY.Line, sys)
        name = PSY.get_name(line)
        rate = PSY.get_rating(line, PSY.SU)
        for t in time_steps
            # A hard variable bound would cap flow at the rating and make the slack dead.
            @test !JuMP.has_upper_bound(flow[name, t])
            @test !JuMP.has_lower_bound(flow[name, t])
            @test JuMP.normalized_coefficient(con_ub[name, t], flow[name, t]) == 1.0
            @test JuMP.normalized_coefficient(con_ub[name, t], slack_ub[name, t]) == -1.0
            @test JuMP.normalized_coefficient(con_ub[name, t], slack_lb[name, t]) == 0.0
            @test JuMP.normalized_rhs(con_ub[name, t]) == rate
            @test JuMP.normalized_coefficient(con_lb[name, t], flow[name, t]) == 1.0
            @test JuMP.normalized_coefficient(con_lb[name, t], slack_lb[name, t]) == 1.0
            @test JuMP.normalized_coefficient(con_lb[name, t], slack_ub[name, t]) == 0.0
            @test JuMP.normalized_rhs(con_lb[name, t]) == -rate
            @test JuMP.coefficient(objective, slack_ub[name, t]) ==
                  POM.CONSTRAINT_VIOLATION_SLACK_COST
            @test JuMP.coefficient(objective, slack_lb[name, t]) ==
                  POM.CONSTRAINT_VIOLATION_SLACK_COST
        end
    end
end
