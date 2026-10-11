@testset "IC network model shares the main model's derived network" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(
        NetworkModel(
            POM.DCPNetworkModel;
            network_source = SystemNetworkSource(PNM.RadialReduction()),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    main = get_network_model(get_template(model))
    ic = get_network_model(POM.get_initial_conditions_template(model, 2))
    # Shared by reference, not rebuilt: this is what makes an IC/main network
    # divergence structurally impossible rather than something to validate.
    @test get_network_source(ic) === get_network_source(main)
    @test get_network_data(ic) === get_network_data(main)
    @test get_network_reduction(ic) === get_network_reduction(main)
    @test get_subnetworks(ic) == get_subnetworks(main)
    @test get_reduction_exceptions(ic) == get_reduction_exceptions(main)
end

@testset "IC container holds the IC template's network model" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(
        NetworkModel(
            PTDFNetworkModel;
            evaluations = power_flow_evaluations(ACPowerFlow()),
        ),
    )
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    # `build!` releases the IC container, so run the build steps up to the IC build.
    POM.build_pre_step!(model)
    IOM.instantiate_network_model!(model)
    POM.build_initial_conditions!(model)

    main = get_network_model(get_template(model))
    ic_container = IOM.get_initial_conditions_model_container(IOM.get_internal(model))
    ic = IOM.get_network_model(ic_container)
    @test IOM.get_network_model(get_optimization_container(model)) === main
    @test ic !== main
    @test get_network_data(ic) === get_network_data(main)
    @test isempty(IOM.get_evaluations(ic_container))
    @test !isempty(IOM.get_evaluations(main))
end
