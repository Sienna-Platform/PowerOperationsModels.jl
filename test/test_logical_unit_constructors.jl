@testset "Logical unit formulation types" begin
    @test LogicalUnitBasicDispatch <: AbstractLogicalUnitDispatch
    @test LogicalUnitStandardDispatch <: AbstractLogicalUnitDispatch
    @test LogicalUnitBasicCommitment <: AbstractLogicalUnitCommitment
    @test LogicalUnitStandardCommitment <: AbstractLogicalUnitCommitment
    @test !(LogicalUnitStandardCommitment <: AbstractThermalFormulation)
    @test PSY.LogicalGenerationUnit <: PowerOperationsModels.ThermalOrLogicalUnit
end

@testset "Logical unit commitment matches its thermal twin" begin
    for (lf, tf) in (
            (LogicalUnitBasicCommitment, ThermalBasicUnitCommitment),
            (LogicalUnitStandardCommitment, ThermalStandardUnitCommitment),
        ),
        network in (CopperPlateNetworkModel, PTDFNetworkModel)

        thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
        logical = replace_thermals_with_logical_units!(
            PSB.build_system(PSITestSystems, "c_sys5_uc"),
        )
        @test isempty(PSY.get_components(PSY.ThermalStandard, logical))
        @test logical_unit_objective(logical, lf; network) ≈
              thermal_objective(thermal, tf; network) rtol = 1e-6
    end
end

@testset "Must-run and missing ramps match thermal" begin
    # Sundance is off in every hour of the plain Standard optimum, so must-run changes the cost.
    thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
    must_run = PSY.get_component(PSY.ThermalStandard, thermal, "Sundance")
    PSY.set_commitment_mode!(must_run, PSY.CommitmentModes.MUST_RUN)
    PSY.set_ramp_limits!(must_run, nothing)
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    model = solved_commitment_model(
        logical,
        PSY.LogicalGenerationUnit,
        LogicalUnitStandardCommitment,
        CopperPlateNetworkModel,
    )
    @test _objective(model) ≈ thermal_objective(thermal, ThermalStandardUnitCommitment) rtol =
        1e-6
    @test !isapprox(
        _objective(model),
        thermal_objective(
            PSB.build_system(PSITestSystems, "c_sys5_uc"),
            ThermalStandardUnitCommitment,
        );
        rtol = 1e-6,
    )

    container = IOM.get_optimization_container(model)
    for V in (OnVariable, StartVariable, StopVariable)
        names = axes(IOM.get_variable(container, V, PSY.LogicalGenerationUnit))[1]
        @test "Sundance" ∉ names
        @test issetequal(names, ["Alta", "Brighton", "Park City", "Solitude"])
    end
    power = IOM.get_variable(container, ActivePowerVariable, PSY.LogicalGenerationUnit)
    unit = PSY.get_component(PSY.LogicalGenerationUnit, logical, "Sundance")
    p_min = PSY.get_active_power_limits(unit, u"SU").min
    @test all(JuMP.lower_bound(power["Sundance", t]) == p_min for t in axes(power)[2])
end

@testset "Logical units next to thermal units" begin
    sys = replace_thermals_with_logical_units!(
        PSB.build_system(PSITestSystems, "c_sys5_uc");
        names = ("Alta", "Brighton"),
    )
    @test length(PSY.get_components(PSY.LogicalGenerationUnit, sys)) == 2
    template = get_thermal_dispatch_template_network(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template, PSY.LogicalGenerationUnit, LogicalUnitStandardCommitment)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    @test haskey(
        IOM.get_variables(container),
        IOM.VariableKey(OnVariable, PSY.ThermalStandard),
    )
    @test haskey(
        IOM.get_variables(container),
        IOM.VariableKey(OnVariable, PSY.LogicalGenerationUnit),
    )
end

@testset "A thermal formulation on logical units fails loudly" begin
    logical = replace_thermals_with_logical_units!(
        PSB.build_system(PSITestSystems, "c_sys5_uc"),
    )
    template = get_thermal_dispatch_template_network(CopperPlateNetworkModel)
    delete!(IOM.get_device_models(template), :ThermalStandard)
    set_device_model!(template, PSY.LogicalGenerationUnit, ThermalStandardUnitCommitment)
    model = DecisionModel(template, logical; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.FAILED
end

@testset "Logical unit dispatch matches its thermal twin" begin
    for (lf, tf, name) in (
            (LogicalUnitBasicDispatch, ThermalBasicDispatch, "c_sys5_uc"),
            (LogicalUnitStandardDispatch, ThermalStandardDispatch, "c_sys5"),
        ),
        network in (CopperPlateNetworkModel, PTDFNetworkModel)

        thermal = PSB.build_system(PSITestSystems, name)
        logical = replace_thermals_with_logical_units!(
            PSB.build_system(PSITestSystems, name),
        )
        t_obj = thermal_objective(thermal, tf; network)
        l_obj = logical_unit_objective(logical, lf; network)
        @test l_obj ≈ t_obj rtol = 1e-6
    end
end

@testset "Logical standard dispatch without ramp limits matches thermal" begin
    thermal = PSB.build_system(PSITestSystems, "c_sys5")
    PSY.set_ramp_limits!(PSY.get_component(PSY.ThermalStandard, thermal, "Alta"), nothing)
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    t_obj = thermal_objective(thermal, ThermalStandardDispatch)
    l_obj = logical_unit_objective(logical, LogicalUnitStandardDispatch)
    @test l_obj ≈ t_obj rtol = 1e-6
end
