@testset "Duals + solver SOS2 constraints error at build time" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_pwl_ed_nonconvex")
    template = PowerOperationsProblemTemplate(
        NetworkModel(CopperPlateNetworkModel; duals = [CopperPlateBalanceConstraint]),
    )
    set_device_model!(template, ThermalStandard, ThermalStandardDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED

    log_text = read(joinpath(output_dir, IOM.PROBLEM_LOG_FILENAME), String)
    @test occursin("solver SOS1/SOS2 constraint", log_text)
    @test occursin("CopperPlateBalanceConstraint", log_text)
end

@testset "Duals + solver SOS2 constraints non-vacuity: SOS2 is actually present without duals" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_pwl_ed_nonconvex")
    template = PowerOperationsProblemTemplate(NetworkModel(CopperPlateNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalStandardDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    jump_model = IOM.get_jump_model(IOM.get_optimization_container(model))
    sos2_constraint_count = 0
    for (F, S) in JuMP.list_of_constraint_types(jump_model)
        POM._is_solver_sos_set(S) || continue
        sos2_constraint_count += JuMP.num_constraints(jump_model, F, S)
    end
    @test sos2_constraint_count > 0
end

@testset "Duals on a binary MILP without SOS constraints still builds" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    template = PowerOperationsProblemTemplate(
        NetworkModel(CopperPlateNetworkModel; duals = [CopperPlateBalanceConstraint]),
    )
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    model = DecisionModel(
        template,
        sys;
        optimizer = HiGHS_optimizer,
        horizon = Hour(2),
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
end
