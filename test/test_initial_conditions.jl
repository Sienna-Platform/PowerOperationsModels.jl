@testset "reset_initial_conditions! sets each condition to its component default" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    ics = IOM.get_initial_conditions(IOM.get_optimization_container(model))
    all_ics = [ic for v in values(ics) for ic in v]
    @test !isempty(all_ics)
    for ic in all_ics
        IOM.set_ic_quantity!(ic, 12345.0)
    end
    n = reset_initial_conditions!(model)
    @test n == length(all_ics)
    for (key, v) in ics, ic in v
        component = IOM.get_component(ic)
        formulation = IOM.get_formulation(get_model(get_template(model), typeof(component)))
        expected =
            POM.initial_condition_default(
                IOM.get_entry_type(key)(),
                component,
                formulation(),
            )
        @test IOM.get_condition(ic) == expected
    end

    # A condition with a `nothing` value is neither set nor counted.
    key = first(keys(ics))
    comp = IOM.get_component(first(ics[key]))
    nothing_ic = IOM.InitialCondition{IOM.get_entry_type(key), Nothing}(comp, nothing)
    push!(ics[key], nothing_ic)
    @test reset_initial_conditions!(model) == length(all_ics)
    @test isnothing(IOM.get_condition(nothing_ic))
end

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
    ic = get_network_model(POM.get_initial_conditions_template(model))
    # Shared by reference, not rebuilt: this is what makes an IC/main network
    # divergence structurally impossible rather than something to validate.
    @test get_network_source(ic) === get_network_source(main)
    @test get_network_data(ic) === get_network_data(main)
    @test get_network_reduction(ic) === get_network_reduction(main)
    @test get_subnetworks(ic) == get_subnetworks(main)
    @test get_reduction_exceptions(ic) == get_reduction_exceptions(main)
end

@testset "IC build shares the network data and holds no evaluation data" begin
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
    ic_template = POM.build_initial_conditions_model!(model)

    main = get_network_model(get_template(model))
    ic_container = IOM.get_initial_conditions_model_container(IOM.get_internal(model))
    ic = get_network_model(ic_template)
    @test ic !== main
    @test get_network_data(ic) === get_network_data(main)
    @test isempty(get_evaluation_data(ic_container))
    @test !isempty(get_evaluations(main))
    ic_context_network_model = get_network_model(IOM.make_solve_context(ic_template))
    @test ic_context_network_model === ic
    @test ic_context_network_model !== main
end

struct GuardProbeData <: IOM.AbstractEvaluationData end

@testset "IC build refuses to copy a container that holds evaluation data" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    POM.build_pre_step!(model)
    IOM.instantiate_network_model!(model)
    IOM.add_evaluation_data!(
        get_optimization_container(model),
        GuardProbeData,
        GuardProbeData(),
    )
    @test_throws ErrorException POM.build_initial_conditions_model!(model)
    @test IOM.get_initial_conditions_model_container(IOM.get_internal(model)) === nothing
end
