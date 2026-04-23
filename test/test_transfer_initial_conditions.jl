@testset "transfer_initial_conditions! UC -> ED" begin
    # Use the small 5-bus UC/ED systems
    sys_uc = PSB.build_system(PSITestSystems, "c_sys5_uc")
    sys_ed = PSB.build_system(PSITestSystems, "c_sys5_ed")

    template_uc = get_template_standard_uc_simulation()
    template_ed = get_template_nomin_ed_simulation()

    uc = DecisionModel(template_uc, sys_uc; name = "UC", optimizer = HiGHS_optimizer)
    ed = DecisionModel(template_ed, sys_ed; name = "ED", optimizer = HiGHS_optimizer)

    output_dir = mktempdir(; cleanup = true)
    @test build!(uc; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    @test solve!(uc) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    @test build!(ed; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    # Transfer ICs from solved UC to ED
    POM.transfer_initial_conditions!(ed, uc)

    # Verify ICs were actually set: read them back and check they're finite
    ed_container = IOM.get_optimization_container(ed)
    for key in keys(IOM.get_initial_conditions(ed_container))
        ics = IOM.get_initial_condition(ed_container, key)
        for ic in ics
            val = IOM.get_condition(ic)
            val === nothing && continue
            @test isfinite(val)
        end
    end

    # ED should still solve with the transferred ICs
    @test solve!(ed) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "transfer_initial_conditions! with EnergyReservoirStorage" begin
    sys_uc = PSB.build_system(PSITestSystems, "c_sys5_bat_ems")
    sys_ed = PSB.build_system(PSITestSystems, "c_sys5_bat_ems")

    template_uc = get_template_standard_uc_simulation()
    set_device_model!(
        template_uc,
        DeviceModel(
            EnergyReservoirStorage,
            StorageDispatchWithReserves;
            attributes = Dict{String, Any}(
                "reservation" => false,
                "cycling_limits" => false,
                "energy_target" => false,
                "complete_coverage" => false,
                "regularization" => true,
            ),
        ),
    )
    template_ed = get_template_nomin_ed_simulation()
    set_device_model!(
        template_ed,
        DeviceModel(
            EnergyReservoirStorage,
            StorageDispatchWithReserves;
            attributes = Dict{String, Any}(
                "reservation" => false,
                "cycling_limits" => false,
                "energy_target" => false,
                "complete_coverage" => false,
                "regularization" => true,
            ),
        ),
    )

    uc = DecisionModel(template_uc, sys_uc; name = "UC", optimizer = HiGHS_optimizer)
    ed = DecisionModel(template_ed, sys_ed; name = "ED", optimizer = HiGHS_optimizer)

    @test build!(uc; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(uc) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    @test build!(ed; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    POM.transfer_initial_conditions!(ed, uc)
    @test solve!(ed) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "transfer_initial_conditions! with HydroReservoir" begin
    sys_uc = PSB.build_system(PSITestSystems, "c_sys5_hyd")
    sys_ed = PSB.build_system(PSITestSystems, "c_sys5_hyd")

    template_uc = get_template_standard_uc_simulation()
    set_device_model!(
        template_uc,
        HydroDispatch,
        HydroDispatchRunOfRiver,
    )
    template_ed = get_template_nomin_ed_simulation()
    set_device_model!(
        template_ed,
        HydroDispatch,
        HydroDispatchRunOfRiver,
    )

    uc = DecisionModel(template_uc, sys_uc; name = "UC", optimizer = HiGHS_optimizer)
    ed = DecisionModel(template_ed, sys_ed; name = "ED", optimizer = HiGHS_optimizer)

    @test build!(uc; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(uc) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    @test build!(ed; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    POM.transfer_initial_conditions!(ed, uc)
    @test solve!(ed) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end
