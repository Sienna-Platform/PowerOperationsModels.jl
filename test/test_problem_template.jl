# This file is WIP while the interface for templates is finalized
@testset "Manual Operations Template" begin
    template = ProblemTemplate(CopperPlatePowerModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template, Line, StaticBranchUnbounded)
    @test !isempty(template.devices)
    @test !isempty(template.branches)
    @test isempty(template.services)
end

@testset "Operations Template Overwrite" begin
    template = ProblemTemplate(CopperPlatePowerModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    @test_logs (:warn, "Overwriting ThermalStandard existing model") set_device_model!(
        template,
        DeviceModel(ThermalStandard, ThermalBasicUnitCommitment),
    )
    @test IOM.get_formulation(template.devices[:ThermalStandard]) ==
          ThermalBasicUnitCommitment
end

# Note: "Provided Templates Tests" from PSI omitted because template_unit_commitment()
# and template_economic_dispatch() haven't been moved out of PSI yet.
