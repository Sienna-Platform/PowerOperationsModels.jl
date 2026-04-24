###############################################################################
# Tests for core type definitions, interface fallbacks, and helper methods
###############################################################################

@testset "Network formulation capabilities" begin
    # supports_branch_filtering
    @test POM.supports_branch_filtering(PTDFPowerModel) == true
    @test POM.supports_branch_filtering(POM.SecurityConstrainedPTDFPowerModel) == true

    # ignores_branch_filtering
    @test POM.ignores_branch_filtering(CopperPlatePowerModel) == true
    @test POM.ignores_branch_filtering(AreaBalancePowerModel) == true

    # requires_all_branch_models
    @test POM.requires_all_branch_models(PTDFPowerModel) == false
    @test POM.requires_all_branch_models(CopperPlatePowerModel) == false
    @test POM.requires_all_branch_models(AreaBalancePowerModel) == false
end

@testset "Expression type methods" begin
    # should_write_resulting_value
    @test IOM.should_write_resulting_value(POM.InterfaceTotalFlow) == true
    @test IOM.should_write_resulting_value(POM.PTDFBranchFlow) == true
    @test IOM.should_write_resulting_value(POM.HydroServedReserveUpExpression) == true
    @test IOM.should_write_resulting_value(POM.HydroServedReserveDownExpression) == true
    @test IOM.should_write_resulting_value(POM.TotalHydroFlowRateReservoirOutgoing) == true
    @test IOM.should_write_resulting_value(POM.TotalHydroFlowRateTurbineOutgoing) == true

    # convert_output_to_natural_units
    @test IOM.convert_output_to_natural_units(POM.InterfaceTotalFlow) == true
    @test IOM.convert_output_to_natural_units(POM.PTDFBranchFlow) == true
end

@testset "Auxiliary variable type methods" begin
    # convert_output_to_natural_units
    @test IOM.convert_output_to_natural_units(POM.PowerOutput) == true
    @test IOM.convert_output_to_natural_units(POM.PowerFlowBranchActivePowerFromTo) == true
    @test IOM.convert_output_to_natural_units(POM.PowerFlowBranchActivePowerToFrom) == true
    @test IOM.convert_output_to_natural_units(POM.PowerFlowBranchReactivePowerFromTo) ==
          true
    @test IOM.convert_output_to_natural_units(POM.PowerFlowBranchReactivePowerToFrom) ==
          true
    @test IOM.convert_output_to_natural_units(POM.PowerFlowBranchActivePowerLoss) == true

    # is_from_power_flow
    @test IOM.is_from_power_flow(POM.PowerFlowVoltageAngle) == true
    @test IOM.is_from_power_flow(POM.PowerFlowVoltageMagnitude) == true
    @test IOM.is_from_power_flow(POM.PowerFlowBranchActivePowerFromTo) == true
    @test IOM.is_from_power_flow(POM.PowerFlowLossFactors) == true
    @test IOM.is_from_power_flow(POM.PowerFlowVoltageStabilityFactors) == true
    @test IOM.is_from_power_flow(POM.TimeDurationOn) == false
    @test IOM.is_from_power_flow(POM.PowerOutput) == false
end

@testset "Parameter type methods" begin
    # convert_output_to_natural_units for parameters
    @test IOM.convert_output_to_natural_units(POM.ActivePowerTimeSeriesParameter) == true
    @test IOM.convert_output_to_natural_units(POM.ReactivePowerTimeSeriesParameter) == true
    @test IOM.convert_output_to_natural_units(POM.RequirementTimeSeriesParameter) == true
    @test IOM.convert_output_to_natural_units(POM.DynamicBranchRatingTimeSeriesParameter) ==
          true
    @test IOM.convert_output_to_natural_units(
        POM.PostContingencyDynamicBranchRatingTimeSeriesParameter,
    ) == true
    @test IOM.convert_output_to_natural_units(POM.UpperBoundValueParameter) == true
    @test IOM.convert_output_to_natural_units(POM.LowerBoundValueParameter) == true
    @test IOM.convert_output_to_natural_units(POM.EnergyLimitParameter) == true
    @test IOM.convert_output_to_natural_units(POM.EnergyTargetParameter) == true
    @test IOM.convert_output_to_natural_units(POM.ReservoirLimitParameter) == true
    @test IOM.convert_output_to_natural_units(POM.ReservoirTargetParameter) == true
    @test IOM.convert_output_to_natural_units(POM.EnergyTargetTimeSeriesParameter) == true
    @test IOM.convert_output_to_natural_units(POM.EnergyBudgetTimeSeriesParameter) == true
    @test IOM.convert_output_to_natural_units(POM.InflowTimeSeriesParameter) == false
    @test IOM.convert_output_to_natural_units(POM.OutflowTimeSeriesParameter) == false

    # should_write_resulting_value for parameters
    @test IOM.should_write_resulting_value(POM.AvailableStatusParameter) == true
    @test IOM.should_write_resulting_value(POM.ActivePowerOffsetParameter) == true
    @test IOM.should_write_resulting_value(POM.ReactivePowerOffsetParameter) == true
    @test IOM.should_write_resulting_value(POM.AvailableStatusChangeCountdownParameter) ==
          true
end

@testset "Default interface methods" begin
    # get_multiplier_value defaults for OCC parameters
    gen = first(
        PSY.get_components(PSY.ThermalStandard, PSB.build_system(PSITestSystems, "c_sys5")),
    )
    @test POM.get_multiplier_value(
        IOM.StartupCostParameter,
        gen,
        POM.ThermalStandardDispatch,
    ) == 1.0
    @test POM.get_multiplier_value(
        IOM.ShutdownCostParameter,
        gen,
        POM.ThermalStandardDispatch,
    ) == 1.0

    # get_default_on_variable / get_default_on_parameter
    @test POM.get_default_on_variable(gen) isa POM.OnVariable
    @test POM.get_default_on_parameter(gen) isa IOM.OnStatusParameter
end


