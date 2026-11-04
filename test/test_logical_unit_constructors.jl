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
    thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
    first_unit = first(PSY.get_components(PSY.ThermalStandard, thermal))
    PSY.set_commitment_mode!(first_unit, PSY.CommitmentModes.MUST_RUN)
    PSY.set_ramp_limits!(first_unit, nothing)
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    @test logical_unit_objective(logical, LogicalUnitStandardCommitment) ≈
          thermal_objective(thermal, ThermalStandardUnitCommitment) rtol = 1e-6
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
