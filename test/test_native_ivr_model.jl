import PowerNetworkMatrices as PNM

@testset "native IVRNetworkModel builds and solves (c_sys5)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(IVRNetworkModel))
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # --- IVR voltage-magnitude physics check ---
    # Same as ACR: rectangular voltage bounds enforce vmin² ≤ vr² + vi² ≤ vmax².
    res = IOM.OptimizationProblemOutputs(model)
    vr_sol = read_variable(res, "VoltageReal__ACBus"; table_format = TableFormat.WIDE)
    vi_sol = read_variable(res, "VoltageImaginary__ACBus"; table_format = TableFormat.WIDE)
    for bus in PSY.get_components(PSY.ACBus, sys)
        lim = PSY.get_voltage_limits(bus)
        bname = PSY.get_name(bus)
        vm2 = vr_sol[1, bname]^2 + vi_sol[1, bname]^2
        @test lim.min^2 - 1e-4 <= vm2 <= lim.max^2 + 1e-4
    end

    # --- IVR branch current bounds check ---
    # Every terminal current variable must stay within ±c_rating_a = rate_a / vmin.
    cr_fr_sol = read_variable(
        res, "BranchCurrentFromToReal__Line"; table_format = TableFormat.WIDE,
    )
    ci_fr_sol = read_variable(
        res, "BranchCurrentFromToImaginary__Line"; table_format = TableFormat.WIDE,
    )
    for line in PSY.get_components(PSY.Line, sys)
        arc = PSY.get_arc(line)
        rate_a = PSY.get_rating(line, PSY.SU)
        vmin = min(
            PSY.get_voltage_limits(PSY.get_from(arc)).min,
            PSY.get_voltage_limits(PSY.get_to(arc)).min,
        )
        c_rating = rate_a / vmin
        lname = PSY.get_name(line)
        @test abs(cr_fr_sol[1, lname]) <= c_rating + 1e-4
        @test abs(ci_fr_sol[1, lname]) <= c_rating + 1e-4
    end
end

@testset "IVRNetworkModel objective ≈ ACPNetworkModel objective (c_sys5)" begin
    # IVR and ACP are the same nonlinear AC optimal power flow (exact AC physics,
    # different variable space); on the same system they must converge to the same
    # optimal value.
    sys = PSB.build_system(PSITestSystems, "c_sys5")

    template_acp = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    model_acp = DecisionModel(template_acp, sys; optimizer = ipopt_optimizer)
    @test build!(model_acp; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_acp) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    acp_obj = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_acp))

    template_ivr = get_thermal_dispatch_template_network(NetworkModel(IVRNetworkModel))
    model_ivr = DecisionModel(template_ivr, sys; optimizer = ipopt_optimizer)
    @test build!(model_ivr; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_ivr) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    ivr_obj = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_ivr))

    @test isapprox(ivr_obj, acp_obj; rtol = 1e-3)
end

@testset "IVRNetworkModel objective ≈ ACPNetworkModel objective (c_sys14, non-unit taps)" begin
    # c_sys14 has TapTransformers with tap ratios ~0.93–0.98, exercising the /tm²
    # shunt path. IVR and ACP must converge to the same optimal value.
    sys = PSB.build_system(PSITestSystems, "c_sys14")

    template_acp = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    model_acp = DecisionModel(template_acp, sys; optimizer = ipopt_optimizer)
    @test build!(model_acp; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_acp) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    acp_obj = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_acp))

    template_ivr = get_thermal_dispatch_template_network(NetworkModel(IVRNetworkModel))
    model_ivr = DecisionModel(template_ivr, sys; optimizer = ipopt_optimizer)
    @test build!(model_ivr; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_ivr) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    ivr_obj = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_ivr))

    @test isapprox(ivr_obj, acp_obj; rtol = 1e-3)
end
