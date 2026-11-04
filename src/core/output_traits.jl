# Output unit traits of every key type that POM defines.
# Unit rules: design section 5.6 and 8.2; allowed natural units: SiennaSchemas/Core/units.json.

################################################################################
# Variables
################################################################################

IS.Optimization.output_unit_system(::Type{ActivePowerPumpVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{ActivePowerPumpVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ActivePowerReserveVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{ActivePowerReserveVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{AdditionalDeltaActivePowerDownVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{AdditionalDeltaActivePowerDownVariable}) =
    "ActivePower"
IS.Optimization.output_unit_system(::Type{AdditionalDeltaActivePowerUpVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{AdditionalDeltaActivePowerUpVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{AncillaryServiceVariableCharge}) = IS.SU
IS.Optimization.quantity_kind(::Type{AncillaryServiceVariableCharge}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{AncillaryServiceVariableDischarge}) = IS.SU
IS.Optimization.quantity_kind(::Type{AncillaryServiceVariableDischarge}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{AreaMismatchVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{AreaMismatchVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{<:AbstractBranchCurrentVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:AbstractBranchCurrentVariable}) = "CurrentFlow"
IS.Optimization.output_unit_system(::Type{<:MultiStartVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{<:MultiStartVariable}) = "Dimensionless"
IS.Optimization.natural_units(::Type{<:MultiStartVariable}) = "1"
IS.Optimization.output_unit_system(::Type{ConverterACCurrentFromVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{ConverterACCurrentFromVariable}) = "CurrentFlow"
IS.Optimization.output_unit_system(::Type{ConverterACCurrentToVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{ConverterACCurrentToVariable}) = "CurrentFlow"
IS.Optimization.output_unit_system(::Type{ConverterACCurrentVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{ConverterACCurrentVariable}) = "CurrentFlow"
IS.Optimization.output_unit_system(::Type{ConverterCurrent}) = IS.SU
IS.Optimization.quantity_kind(::Type{ConverterCurrent}) = "CurrentFlow"
IS.Optimization.output_unit_system(::Type{CosineApproximation}) = IS.NU
IS.Optimization.quantity_kind(::Type{CosineApproximation}) = "Dimensionless"
IS.Optimization.natural_units(::Type{CosineApproximation}) = "1"
IS.Optimization.output_unit_system(::Type{CurrentAbsoluteValueVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{CurrentAbsoluteValueVariable}) = "CurrentFlow"
IS.Optimization.output_unit_system(::Type{DCLineCurrent}) = IS.SU
IS.Optimization.quantity_kind(::Type{DCLineCurrent}) = "CurrentFlow"
IS.Optimization.output_unit_system(::Type{DCLineCurrentFlowVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{DCLineCurrentFlowVariable}) = "CurrentFlow"
IS.Optimization.output_unit_system(::Type{DeltaActivePowerDownVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{DeltaActivePowerDownVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{DeltaActivePowerUpVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{DeltaActivePowerUpVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{EnergyVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{EnergyVariable}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{<:AbstractACActivePowerFlow}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:AbstractACActivePowerFlow}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{<:AbstractACReactivePowerFlow}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:AbstractACReactivePowerFlow}) = "ReactivePower"
IS.Optimization.output_unit_system(::Type{HVDCActivePowerReceivedFromVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCActivePowerReceivedFromVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HVDCActivePowerReceivedToVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCActivePowerReceivedToVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HVDCFlowDirectionVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCFlowDirectionVariable}) = "Dimensionless"
IS.Optimization.natural_units(::Type{HVDCFlowDirectionVariable}) = "1"
IS.Optimization.output_unit_system(::Type{HVDCFromDCVoltage}) = IS.CU
IS.Optimization.quantity_kind(::Type{HVDCFromDCVoltage}) = "Voltage"
IS.Optimization.output_unit_system(::Type{HVDCInverterACCurrentVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCInverterACCurrentVariable}) = "CurrentFlow"
IS.Optimization.output_unit_system(::Type{HVDCInverterActivePowerVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCInverterActivePowerVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HVDCInverterDCVoltageVariable}) = IS.CU
IS.Optimization.quantity_kind(::Type{HVDCInverterDCVoltageVariable}) = "Voltage"
IS.Optimization.output_unit_system(::Type{HVDCInverterExtinctionAngleVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCInverterExtinctionAngleVariable}) = "Angle"
IS.Optimization.natural_units(::Type{HVDCInverterExtinctionAngleVariable}) = "rad"
IS.Optimization.output_unit_system(::Type{HVDCInverterOverlapAngleVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCInverterOverlapAngleVariable}) = "Angle"
IS.Optimization.natural_units(::Type{HVDCInverterOverlapAngleVariable}) = "rad"
IS.Optimization.output_unit_system(::Type{HVDCInverterPowerFactorAngleVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCInverterPowerFactorAngleVariable}) = "Angle"
IS.Optimization.natural_units(::Type{HVDCInverterPowerFactorAngleVariable}) = "rad"
IS.Optimization.output_unit_system(::Type{HVDCInverterReactivePowerVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCInverterReactivePowerVariable}) = "ReactivePower"
IS.Optimization.output_unit_system(::Type{HVDCInverterTapSettingVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCInverterTapSettingVariable}) = "Fraction"
IS.Optimization.natural_units(::Type{HVDCInverterTapSettingVariable}) = "1"
IS.Optimization.output_unit_system(::Type{HVDCLosses}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCLosses}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HVDCPiecewiseBinaryLossVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCPiecewiseBinaryLossVariable}) = "Dimensionless"
IS.Optimization.natural_units(::Type{HVDCPiecewiseBinaryLossVariable}) = "1"
IS.Optimization.output_unit_system(::Type{HVDCPiecewiseLossVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCPiecewiseLossVariable}) = "Fraction"
IS.Optimization.natural_units(::Type{HVDCPiecewiseLossVariable}) = "1"
IS.Optimization.output_unit_system(::Type{HVDCReactivePowerFromVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCReactivePowerFromVariable}) = "ReactivePower"
IS.Optimization.output_unit_system(::Type{HVDCReactivePowerToVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCReactivePowerToVariable}) = "ReactivePower"
IS.Optimization.output_unit_system(::Type{HVDCRectifierACCurrentVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCRectifierACCurrentVariable}) = "CurrentFlow"
IS.Optimization.output_unit_system(::Type{HVDCRectifierActivePowerVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCRectifierActivePowerVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HVDCRectifierDCVoltageVariable}) = IS.CU
IS.Optimization.quantity_kind(::Type{HVDCRectifierDCVoltageVariable}) = "Voltage"
IS.Optimization.output_unit_system(::Type{HVDCRectifierDelayAngleVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCRectifierDelayAngleVariable}) = "Angle"
IS.Optimization.natural_units(::Type{HVDCRectifierDelayAngleVariable}) = "rad"
IS.Optimization.output_unit_system(::Type{HVDCRectifierOverlapAngleVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCRectifierOverlapAngleVariable}) = "Angle"
IS.Optimization.natural_units(::Type{HVDCRectifierOverlapAngleVariable}) = "rad"
IS.Optimization.output_unit_system(::Type{HVDCRectifierPowerFactorAngleVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCRectifierPowerFactorAngleVariable}) = "Angle"
IS.Optimization.natural_units(::Type{HVDCRectifierPowerFactorAngleVariable}) = "rad"
IS.Optimization.output_unit_system(::Type{HVDCRectifierReactivePowerVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HVDCRectifierReactivePowerVariable}) = "ReactivePower"
IS.Optimization.output_unit_system(::Type{HVDCRectifierTapSettingVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HVDCRectifierTapSettingVariable}) = "Fraction"
IS.Optimization.natural_units(::Type{HVDCRectifierTapSettingVariable}) = "1"
IS.Optimization.output_unit_system(::Type{HVDCToDCVoltage}) = IS.CU
IS.Optimization.quantity_kind(::Type{HVDCToDCVoltage}) = "Voltage"
IS.Optimization.output_unit_system(::Type{HybridEnergyShortageVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HybridEnergyShortageVariable}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{HybridEnergySurplusVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HybridEnergySurplusVariable}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{<:HybridPCCReserveVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:HybridPCCReserveVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HybridRenewableActivePower}) = IS.SU
IS.Optimization.quantity_kind(::Type{HybridRenewableActivePower}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{<:AbstractHybridReserveVariableType}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:AbstractHybridReserveVariableType}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HybridStorageReservation}) = IS.NU
IS.Optimization.quantity_kind(::Type{HybridStorageReservation}) = "Dimensionless"
IS.Optimization.natural_units(::Type{HybridStorageReservation}) = "1"
IS.Optimization.output_unit_system(::Type{<:HybridStorageSubcomponentPower}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:HybridStorageSubcomponentPower}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{<:HybridStorageSubcomponentReserveVariable}) =
    IS.SU
IS.Optimization.quantity_kind(::Type{<:HybridStorageSubcomponentReserveVariable}) =
    "ActivePower"
IS.Optimization.output_unit_system(::Type{HybridThermalActivePower}) = IS.SU
IS.Optimization.quantity_kind(::Type{HybridThermalActivePower}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HydroBalanceShortageVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HydroBalanceShortageVariable}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{HydroBalanceSurplusVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HydroBalanceSurplusVariable}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{HydroEnergyShortageVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HydroEnergyShortageVariable}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{HydroEnergySurplusVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{HydroEnergySurplusVariable}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{HydroReservoirHeadVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HydroReservoirHeadVariable}) = "Elevation"
IS.Optimization.natural_units(::Type{HydroReservoirHeadVariable}) = "m"
IS.Optimization.output_unit_system(::Type{HydroReservoirVolumeVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HydroReservoirVolumeVariable}) = "Volume"
IS.Optimization.natural_units(::Type{HydroReservoirVolumeVariable}) = "m3"
IS.Optimization.output_unit_system(::Type{HydroTurbineFlowRateVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HydroTurbineFlowRateVariable}) = "VolumeFlowRate"
IS.Optimization.natural_units(::Type{HydroTurbineFlowRateVariable}) = "m3/s"
IS.Optimization.output_unit_system(::Type{HydroWaterShortageVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HydroWaterShortageVariable}) = "Volume"
IS.Optimization.natural_units(::Type{HydroWaterShortageVariable}) = "m3"
IS.Optimization.output_unit_system(::Type{HydroWaterSurplusVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{HydroWaterSurplusVariable}) = "Volume"
IS.Optimization.natural_units(::Type{HydroWaterSurplusVariable}) = "m3"
IS.Optimization.output_unit_system(::Type{InterfaceFlowSlackDown}) = IS.SU
IS.Optimization.quantity_kind(::Type{InterfaceFlowSlackDown}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{InterfaceFlowSlackUp}) = IS.SU
IS.Optimization.quantity_kind(::Type{InterfaceFlowSlackUp}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{LiftVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{LiftVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{LowerBoundFeedForwardSlack}) = IS.SU
IS.Optimization.quantity_kind(::Type{LowerBoundFeedForwardSlack}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{PhaseShifterAngle}) = IS.NU
IS.Optimization.quantity_kind(::Type{PhaseShifterAngle}) = "Angle"
IS.Optimization.natural_units(::Type{PhaseShifterAngle}) = "rad"
IS.Optimization.output_unit_system(::Type{PiecewiseLinearBlockReserveOffer}) = IS.SU
IS.Optimization.quantity_kind(::Type{PiecewiseLinearBlockReserveOffer}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{PostContingencyDeploymentVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{PostContingencyDeploymentVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{PostContingencyDeviationVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{PostContingencyDeviationVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{PostContingencyFlowActivePowerSlackLowerBound}) =
    IS.SU
IS.Optimization.quantity_kind(::Type{PostContingencyFlowActivePowerSlackLowerBound}) =
    "ActivePower"
IS.Optimization.output_unit_system(::Type{PostContingencyFlowActivePowerSlackUpperBound}) =
    IS.SU
IS.Optimization.quantity_kind(::Type{PostContingencyFlowActivePowerSlackUpperBound}) =
    "ActivePower"
IS.Optimization.output_unit_system(::Type{PostGeneratorContingencyFlowSlackLowerBound}) =
    IS.SU
IS.Optimization.quantity_kind(::Type{PostGeneratorContingencyFlowSlackLowerBound}) =
    "ActivePower"
IS.Optimization.output_unit_system(::Type{PostGeneratorContingencyFlowSlackUpperBound}) =
    IS.SU
IS.Optimization.quantity_kind(::Type{PostGeneratorContingencyFlowSlackUpperBound}) =
    "ActivePower"
IS.Optimization.output_unit_system(::Type{ReactivePowerVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{ReactivePowerVariable}) = "ReactivePower"
IS.Optimization.output_unit_system(::Type{<:RegularizationVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:RegularizationVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{RegulatedVoltageMagnitude}) = IS.CU
IS.Optimization.quantity_kind(::Type{RegulatedVoltageMagnitude}) = "Voltage"
IS.Optimization.output_unit_system(::Type{ReserveRequirementSlack}) = IS.SU
IS.Optimization.quantity_kind(::Type{ReserveRequirementSlack}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ServiceRequirementVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{ServiceRequirementVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ShiftDownActivePowerVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{ShiftDownActivePowerVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ShiftUpActivePowerVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{ShiftUpActivePowerVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ShuntSusceptanceVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{ShuntSusceptanceVariable}) = "Susceptance"
IS.Optimization.output_unit_system(::Type{SmoothACE}) = IS.SU
IS.Optimization.quantity_kind(::Type{SmoothACE}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{SteadyStateFrequencyDeviation}) = IS.NU
IS.Optimization.quantity_kind(::Type{SteadyStateFrequencyDeviation}) = "Frequency"
IS.Optimization.natural_units(::Type{SteadyStateFrequencyDeviation}) = "Hz"
IS.Optimization.output_unit_system(::Type{StorageChargeCyclingSlackVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{StorageChargeCyclingSlackVariable}) =
    "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{StorageDischargeCyclingSlackVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{StorageDischargeCyclingSlackVariable}) =
    "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{StorageEnergyShortageVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{StorageEnergyShortageVariable}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{StorageEnergySurplusVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{StorageEnergySurplusVariable}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{<:StorageRegularizationVariable}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:StorageRegularizationVariable}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{SystemBalanceSlackDown}) = IS.SU
IS.Optimization.quantity_kind(::Type{SystemBalanceSlackDown}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{SystemBalanceSlackUp}) = IS.SU
IS.Optimization.quantity_kind(::Type{SystemBalanceSlackUp}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{TapRatioVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{TapRatioVariable}) = "Fraction"
IS.Optimization.natural_units(::Type{TapRatioVariable}) = "1"
IS.Optimization.output_unit_system(::Type{UpperBoundFeedForwardSlack}) = IS.SU
IS.Optimization.quantity_kind(::Type{UpperBoundFeedForwardSlack}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{VoltageAngle}) = IS.NU
IS.Optimization.quantity_kind(::Type{VoltageAngle}) = "Angle"
IS.Optimization.natural_units(::Type{VoltageAngle}) = "rad"
IS.Optimization.output_unit_system(::Type{VoltageDeviation}) = IS.CU
IS.Optimization.quantity_kind(::Type{VoltageDeviation}) = "Voltage"
IS.Optimization.output_unit_system(::Type{VoltageImaginary}) = IS.CU
IS.Optimization.quantity_kind(::Type{VoltageImaginary}) = "Voltage"
IS.Optimization.output_unit_system(::Type{VoltageMagnitude}) = IS.CU
IS.Optimization.quantity_kind(::Type{VoltageMagnitude}) = "Voltage"
IS.Optimization.output_unit_system(::Type{VoltageReal}) = IS.CU
IS.Optimization.quantity_kind(::Type{VoltageReal}) = "Voltage"
IS.Optimization.output_unit_system(::Type{WaterSpillageVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{WaterSpillageVariable}) = "VolumeFlowRate"
IS.Optimization.natural_units(::Type{WaterSpillageVariable}) = "m3/s"

################################################################################
# Auxiliary variables
################################################################################

IS.Optimization.output_unit_system(::Type{DCLineLosses}) = IS.SU
IS.Optimization.quantity_kind(::Type{DCLineLosses}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HydroEnergyOutput}) = IS.SU
IS.Optimization.quantity_kind(::Type{HydroEnergyOutput}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{PowerFlowBranchActivePowerFromTo}) = IS.SU
IS.Optimization.quantity_kind(::Type{PowerFlowBranchActivePowerFromTo}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{PowerFlowBranchActivePowerLoss}) = IS.SU
IS.Optimization.quantity_kind(::Type{PowerFlowBranchActivePowerLoss}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{PowerFlowBranchActivePowerToFrom}) = IS.SU
IS.Optimization.quantity_kind(::Type{PowerFlowBranchActivePowerToFrom}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{PowerFlowBranchReactivePowerFromTo}) = IS.SU
IS.Optimization.quantity_kind(::Type{PowerFlowBranchReactivePowerFromTo}) = "ReactivePower"
IS.Optimization.output_unit_system(::Type{PowerFlowBranchReactivePowerToFrom}) = IS.SU
IS.Optimization.quantity_kind(::Type{PowerFlowBranchReactivePowerToFrom}) = "ReactivePower"
IS.Optimization.output_unit_system(::Type{PowerFlowLossFactors}) = IS.NU
IS.Optimization.quantity_kind(::Type{PowerFlowLossFactors}) = "Fraction"
IS.Optimization.natural_units(::Type{PowerFlowLossFactors}) = "1"
IS.Optimization.output_unit_system(::Type{PowerFlowVoltageAngle}) = IS.NU
IS.Optimization.quantity_kind(::Type{PowerFlowVoltageAngle}) = "Angle"
IS.Optimization.natural_units(::Type{PowerFlowVoltageAngle}) = "rad"
IS.Optimization.output_unit_system(::Type{PowerFlowVoltageMagnitude}) = IS.CU
IS.Optimization.quantity_kind(::Type{PowerFlowVoltageMagnitude}) = "Voltage"
IS.Optimization.output_unit_system(::Type{PowerFlowVoltageStabilityFactors}) = IS.NU
IS.Optimization.quantity_kind(::Type{PowerFlowVoltageStabilityFactors}) = "Fraction"
IS.Optimization.natural_units(::Type{PowerFlowVoltageStabilityFactors}) = "1"
IS.Optimization.output_unit_system(::Type{PowerOutput}) = IS.SU
IS.Optimization.quantity_kind(::Type{PowerOutput}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{StorageEnergyOutput}) = IS.SU
IS.Optimization.quantity_kind(::Type{StorageEnergyOutput}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{TimeDurationOff}) = IS.NU
IS.Optimization.quantity_kind(::Type{TimeDurationOff}) = "Dimensionless"
IS.Optimization.natural_units(::Type{TimeDurationOff}) = "1"
IS.Optimization.output_unit_system(::Type{TimeDurationOn}) = IS.NU
IS.Optimization.quantity_kind(::Type{TimeDurationOn}) = "Dimensionless"
IS.Optimization.natural_units(::Type{TimeDurationOn}) = "1"

################################################################################
# Parameters
################################################################################

IS.Optimization.output_unit_system(::Type{ActivePowerInTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ActivePowerInTimeSeriesParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ActivePowerOffsetParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ActivePowerOffsetParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ActivePowerOutTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ActivePowerOutTimeSeriesParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ActivePowerTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ActivePowerTimeSeriesParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{AvailableStatusChangeCountdownParameter}) = IS.NU
IS.Optimization.quantity_kind(::Type{AvailableStatusChangeCountdownParameter}) =
    "Dimensionless"
IS.Optimization.natural_units(::Type{AvailableStatusChangeCountdownParameter}) = "1"
IS.Optimization.output_unit_system(::Type{AvailableStatusParameter}) = IS.NU
IS.Optimization.quantity_kind(::Type{AvailableStatusParameter}) = "Dimensionless"
IS.Optimization.natural_units(::Type{AvailableStatusParameter}) = "1"
IS.Optimization.output_unit_system(::Type{<:AbstractBranchRatingTimeSeriesParameter}) =
    IS.SU
IS.Optimization.quantity_kind(::Type{<:AbstractBranchRatingTimeSeriesParameter}) =
    "ActivePower"
IS.Optimization.output_unit_system(::Type{CostFunctionParameter}) = IS.NU
IS.Optimization.quantity_kind(::Type{CostFunctionParameter}) = "Money"
IS.Optimization.natural_units(::Type{CostFunctionParameter}) = "USD"
IS.Optimization.output_unit_system(::Type{DeployedFractionParameter}) = IS.NU
IS.Optimization.quantity_kind(::Type{DeployedFractionParameter}) = "Fraction"
IS.Optimization.natural_units(::Type{DeployedFractionParameter}) = "1"
IS.Optimization.output_unit_system(::Type{EnergyBudgetTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{EnergyBudgetTimeSeriesParameter}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{EnergyCapacityTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{EnergyCapacityTimeSeriesParameter}) =
    "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{EnergyLimitParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{EnergyLimitParameter}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{EnergyTargetParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{EnergyTargetParameter}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{EnergyTargetTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{EnergyTargetTimeSeriesParameter}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{FromToFlowLimitParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{FromToFlowLimitParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HybridElectricLoadTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{HybridElectricLoadTimeSeriesParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HybridRenewableActivePowerTimeSeriesParameter}) =
    IS.SU
IS.Optimization.quantity_kind(::Type{HybridRenewableActivePowerTimeSeriesParameter}) =
    "ActivePower"
IS.Optimization.output_unit_system(::Type{HydroUsageLimitParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{HydroUsageLimitParameter}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{InflowTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{InflowTimeSeriesParameter}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{LevelTargetParameter}) = IS.NU
IS.Optimization.quantity_kind(::Type{LevelTargetParameter}) = "Volume"
IS.Optimization.natural_units(::Type{LevelTargetParameter}) = "m3"
IS.Optimization.output_unit_system(::Type{LowerBoundValueParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{LowerBoundValueParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{MaxInterfaceFlowLimitParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{MaxInterfaceFlowLimitParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{<:AbstractMinActivePowerParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:AbstractMinActivePowerParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{MinInterfaceFlowLimitParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{MinInterfaceFlowLimitParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{OutflowTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{OutflowTimeSeriesParameter}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{ReactivePowerOffsetParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ReactivePowerOffsetParameter}) = "ReactivePower"
IS.Optimization.output_unit_system(::Type{ReactivePowerTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ReactivePowerTimeSeriesParameter}) = "ReactivePower"
IS.Optimization.output_unit_system(::Type{RequirementTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{RequirementTimeSeriesParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ReservoirLimitParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ReservoirLimitParameter}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{ReservoirTargetParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ReservoirTargetParameter}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{ShiftDownActivePowerTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ShiftDownActivePowerTimeSeriesParameter}) =
    "ActivePower"
IS.Optimization.output_unit_system(::Type{ShiftUpActivePowerTimeSeriesParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ShiftUpActivePowerTimeSeriesParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ToFromFlowLimitParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{ToFromFlowLimitParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{UpperBoundValueParameter}) = IS.SU
IS.Optimization.quantity_kind(::Type{UpperBoundValueParameter}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{WaterBudgetTimeSeriesParameter}) = IS.NU
IS.Optimization.quantity_kind(::Type{WaterBudgetTimeSeriesParameter}) = "VolumeFlowRate"
IS.Optimization.natural_units(::Type{WaterBudgetTimeSeriesParameter}) = "m3/s"
IS.Optimization.output_unit_system(::Type{WaterLevelBudgetParameter}) = IS.NU
IS.Optimization.quantity_kind(::Type{WaterLevelBudgetParameter}) = "Volume"
IS.Optimization.natural_units(::Type{WaterLevelBudgetParameter}) = "m3"
IS.Optimization.output_unit_system(::Type{WaterTargetTimeSeriesParameter}) = IS.NU
IS.Optimization.quantity_kind(::Type{WaterTargetTimeSeriesParameter}) = "Volume"
IS.Optimization.natural_units(::Type{WaterTargetTimeSeriesParameter}) = "m3"

################################################################################
# Expressions
################################################################################

IS.Optimization.output_unit_system(::Type{BThetaBranchFlow}) = IS.SU
IS.Optimization.quantity_kind(::Type{BThetaBranchFlow}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ComponentReserveDownBalanceExpression}) = IS.SU
IS.Optimization.quantity_kind(::Type{ComponentReserveDownBalanceExpression}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{ComponentReserveUpBalanceExpression}) = IS.SU
IS.Optimization.quantity_kind(::Type{ComponentReserveUpBalanceExpression}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{EnergyBalanceExpression}) = IS.SU
IS.Optimization.quantity_kind(::Type{EnergyBalanceExpression}) = "ElectricalEnergy"
IS.Optimization.output_unit_system(::Type{<:HybridPCCReserveExpression}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:HybridPCCReserveExpression}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HydroServedReserveDownExpression}) = IS.SU
IS.Optimization.quantity_kind(::Type{HydroServedReserveDownExpression}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{HydroServedReserveUpExpression}) = IS.SU
IS.Optimization.quantity_kind(::Type{HydroServedReserveUpExpression}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{InterfaceTotalFlow}) = IS.SU
IS.Optimization.quantity_kind(::Type{InterfaceTotalFlow}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{PTDFBranchFlow}) = IS.SU
IS.Optimization.quantity_kind(::Type{PTDFBranchFlow}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{PostContingencyLocationalDeployment}) = IS.SU
IS.Optimization.quantity_kind(::Type{PostContingencyLocationalDeployment}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{PostContingencyTotalDeployment}) = IS.SU
IS.Optimization.quantity_kind(::Type{PostContingencyTotalDeployment}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{RealizedShiftedLoad}) = IS.SU
IS.Optimization.quantity_kind(::Type{RealizedShiftedLoad}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{<:StorageReserveBalanceExpression}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:StorageReserveBalanceExpression}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{TotalHydroFlowRateReservoirIncoming}) = IS.NU
IS.Optimization.quantity_kind(::Type{TotalHydroFlowRateReservoirIncoming}) =
    "VolumeFlowRate"
IS.Optimization.natural_units(::Type{TotalHydroFlowRateReservoirIncoming}) = "m3/s"
IS.Optimization.output_unit_system(::Type{TotalHydroFlowRateReservoirOutgoing}) = IS.NU
IS.Optimization.quantity_kind(::Type{TotalHydroFlowRateReservoirOutgoing}) =
    "VolumeFlowRate"
IS.Optimization.natural_units(::Type{TotalHydroFlowRateReservoirOutgoing}) = "m3/s"
IS.Optimization.output_unit_system(::Type{TotalHydroFlowRateTurbineOutgoing}) = IS.NU
IS.Optimization.quantity_kind(::Type{TotalHydroFlowRateTurbineOutgoing}) = "VolumeFlowRate"
IS.Optimization.natural_units(::Type{TotalHydroFlowRateTurbineOutgoing}) = "m3/s"
IS.Optimization.output_unit_system(::Type{TotalHydroPowerReservoirIncoming}) = IS.SU
IS.Optimization.quantity_kind(::Type{TotalHydroPowerReservoirIncoming}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{TotalHydroPowerReservoirOutgoing}) = IS.SU
IS.Optimization.quantity_kind(::Type{TotalHydroPowerReservoirOutgoing}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{TotalReserveOffering}) = IS.SU
IS.Optimization.quantity_kind(::Type{TotalReserveOffering}) = "ActivePower"
IS.Optimization.output_unit_system(::Type{TotalSpillageFlowRateReservoirIncoming}) = IS.NU
IS.Optimization.quantity_kind(::Type{TotalSpillageFlowRateReservoirIncoming}) =
    "VolumeFlowRate"
IS.Optimization.natural_units(::Type{TotalSpillageFlowRateReservoirIncoming}) = "m3/s"
IS.Optimization.output_unit_system(::Type{TotalSpillagePowerReservoirIncoming}) = IS.SU
IS.Optimization.quantity_kind(::Type{TotalSpillagePowerReservoirIncoming}) = "ActivePower"

################################################################################
# Constraints (duals)
################################################################################

IS.Optimization.output_unit_system(::Type{<:ConstraintType}) = IS.SU
IS.Optimization.quantity_kind(::Type{<:ConstraintType}) = "CostPerEnergy"
