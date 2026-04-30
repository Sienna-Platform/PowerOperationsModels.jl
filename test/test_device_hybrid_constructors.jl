# Tests for HybridSystem device formulations.

@testset "Test HybridSystem DispatchWithReserves DeviceModel" begin
    sys = PSB.build_system(PSB.PSITestSystems, "test_RTS_GMLC_sys")
    modify_ren_curtailment_cost!(sys)
    add_hybrid_to_chuhsi_bus!(sys)

    hybrid = first(PSY.get_components(PSY.HybridSystem, sys))

    # Attach all VariableReserves except R1/R2 spinning reserves to the hybrid,
    # mirroring HSS test_hybrid_device.jl:60–69.
    for s in PSY.get_components(PSY.VariableReserve, sys)
        s_name = PSY.get_name(s)
        contains(s_name, "Spin_Up_R1") && continue
        contains(s_name, "Spin_Up_R2") && continue
        PSY.add_service!(hybrid, s, sys)
    end

    template = POM.OperationsProblemTemplate(POM.CopperPlatePowerModel)
    POM.set_device_model!(template, PSY.ThermalStandard, POM.ThermalStandardUnitCommitment)
    POM.set_device_model!(template, PSY.RenewableDispatch, POM.RenewableFullDispatch)
    POM.set_device_model!(template, PSY.PowerLoad, POM.StaticPowerLoad)
    POM.set_device_model!(template,
        POM.DeviceModel(PSY.HybridSystem, POM.HybridDispatchWithReserves),
    )
    for service in PSY.get_components(PSY.VariableReserve, sys)
        POM.set_service_model!(template,
            POM.ServiceModel(typeof(service), POM.RangeReserve, PSY.get_name(service)),
        )
    end

    m = POM.DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    build_out = POM.build!(m; output_dir = mktempdir(; cleanup = true))
    @test build_out == IOM.ModelBuildStatus.BUILT
    solve_out = POM.solve!(m)
    @test solve_out == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    res = POM.OptimizationProblemResults(m)
    p_out = POM.read_variable(res, "ActivePowerOutVariable__HybridSystem")[!, 2]
    p_in = POM.read_variable(res, "ActivePowerInVariable__HybridSystem")[!, 2]
    @test length(p_out) == 48
    @test length(p_in) == 48
end
