import PowerNetworkMatrices as PNM

@testset "native ACRNetworkModel builds and solves (c_sys5)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(ACRNetworkModel))
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # --- ACR voltage-magnitude physics check ---
    # The rectangular voltage-magnitude bounds constraint enforces
    # vmin^2 <= vr^2 + vi^2 <= vmax^2 for every bus.
    res = IOM.OptimizationProblemOutputs(model)
    vr_sol = read_variable(res, "VoltageReal__ACBus"; table_format = TableFormat.WIDE)
    vi_sol = read_variable(res, "VoltageImaginary__ACBus"; table_format = TableFormat.WIDE)
    for bus in PSY.get_components(PSY.ACBus, sys)
        lim = PSY.get_voltage_limits(bus)
        bname = PSY.get_name(bus)
        vm2 = vr_sol[1, bname]^2 + vi_sol[1, bname]^2
        @test lim.min^2 - 1e-4 <= vm2 <= lim.max^2 + 1e-4
    end
end

@testset "ACRNetworkModel objective ≈ ACPNetworkModel objective (c_sys5)" begin
    # ACR and ACP are the same nonlinear AC power-flow program in different voltage
    # coordinate systems; on the same system they must converge to the same optimal value.
    sys = PSB.build_system(PSITestSystems, "c_sys5")

    template_acp = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    model_acp = DecisionModel(template_acp, sys; optimizer = ipopt_optimizer)
    @test build!(model_acp; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_acp) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    acp_obj = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_acp))

    template_acr = get_thermal_dispatch_template_network(NetworkModel(ACRNetworkModel))
    model_acr = DecisionModel(template_acr, sys; optimizer = ipopt_optimizer)
    @test build!(model_acr; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_acr) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    acr_obj = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_acr))

    @test isapprox(acr_obj, acp_obj; rtol = 1e-3)
end

@testset "ACRNetworkModel AngleDifferenceConstraint: tight limits ACR≈ACP and cost ≥ unconstrained" begin
    # With the default c_sys5 limits (±0.7 rad) the angle constraint is inactive, so we
    # tighten to ±0.2 rad to force it active. The ACR rectangular cross-product form
    #   tan(angmin)·vvr ≤ vvi ≤ tan(angmax)·vvr
    # must agree with the ACP polar form
    #   angmin ≤ va_fr − va_to ≤ angmax
    # to within solver tolerance.
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    for line in PSY.get_components(PSY.Line, sys)
        PSY.set_angle_limits!(line, (min = -0.2, max = 0.2))
    end

    template_acp = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    model_acp = DecisionModel(template_acp, sys; optimizer = ipopt_optimizer)
    @test build!(model_acp; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_acp) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    acp_obj_tight = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_acp))

    template_acr = get_thermal_dispatch_template_network(NetworkModel(ACRNetworkModel))
    model_acr = DecisionModel(template_acr, sys; optimizer = ipopt_optimizer)
    @test build!(model_acr; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_acr) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    acr_obj_tight = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_acr))

    # ACR and ACP must reach the same constrained optimum.
    @test isapprox(acr_obj_tight, acp_obj_tight; rtol = 1e-3)

    # The constraint can only raise (or equal) the unconstrained cost; run one more ACR
    # solve with the original loose limits to confirm the tight-limit objective is higher.
    sys_loose = PSB.build_system(PSITestSystems, "c_sys5")
    template_acr_loose =
        get_thermal_dispatch_template_network(NetworkModel(ACRNetworkModel))
    model_acr_loose =
        DecisionModel(template_acr_loose, sys_loose; optimizer = ipopt_optimizer)
    @test build!(model_acr_loose; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_acr_loose) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    acr_obj_loose = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_acr_loose))

    @test acr_obj_tight >= acr_obj_loose - 1e-3
end
