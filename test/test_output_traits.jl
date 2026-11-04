# Source: PowerAnalytics.jl/schemas/outputs/common.json, $defs.QuantityKind.enum
const QUANTITY_KINDS = Set([
    "ActivePower",
    "ReactivePower",
    "ApparentPower",
    "ActivePowerChangeRate",
    "ElectricalEnergy",
    "FractionPerTime",
    "Voltage",
    "CurrentFlow",
    "Resistance",
    "Reactance",
    "Impedance",
    "Conductance",
    "Susceptance",
    "Angle",
    "Frequency",
    "PowerPerFrequency",
    "VoltagePerPower",
    "Length",
    "Elevation",
    "Duration",
    "OperationalDuration",
    "CalendarPeriod",
    "Dimensionless",
    "Fraction",
    "PowerFactor",
    "HeatRate",
    "StartFuelPerCapacity",
    "VolumeFlowRate",
    "HeadRate",
    "Volume",
    "Inductance",
    "Capacitance",
    "CostPerCapacity",
    "CostPerEnergy",
    "CostPerTime",
    "CO2Emissions",
    "Mass",
    "Money",
    "CostPerVolume",
    "CostPerLevel",
    "EmissionRate",
    "CostPerMass",
])

_is_dual_type(::Type{<:IS.Optimization.ConstraintType}) = true
_is_dual_type(::Type) = false

function unit_failures(::Type{T}) where {T}
    failures = String[]
    try
        unit_system = IS.Optimization.output_unit_system(T)
        if !(unit_system in (IS.SU, IS.CU, IS.NU))
            push!(failures, "$T: bad output_unit_system")
        end
        if !(IS.Optimization.quantity_kind(T) in QUANTITY_KINDS)
            push!(failures, "$T: bad quantity_kind")
        end
        if unit_system === IS.NU && isempty(IS.Optimization.natural_units(T))
            push!(failures, "$T: empty natural_units")
        end
    catch err
        push!(failures, "$T: $(sprint(showerror, err))")
    end
    return failures
end

@testset "test_every_written_key_type_declares_units" begin
    failures = String[]
    count = 0
    for A in (
        IS.Optimization.VariableType,
        IS.Optimization.AuxVariableType,
        IS.Optimization.ParameterType,
        IS.Optimization.ExpressionType,
        IS.Optimization.ConstraintType,
    )
        for T in IS.get_all_concrete_subtypes(A)
            if parentmodule(T) === POM &&
               (IOM.should_write_resulting_value(T) || _is_dual_type(T))
                count += 1
                append!(failures, unit_failures(T))
            end
        end
    end
    @test count > 100
    isempty(failures) || println(join(failures, "\n"))
    @test isempty(failures)
end

@testset "test_resolve_component_axis_by_name_and_bus_number" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    names = sort(PSY.get_name.(PSY.get_components(PSY.ThermalStandard, sys)))
    (ids, labels) = IOM.resolve_component_axis(sys, PSY.ThermalStandard, names)
    @test ids == [IS.get_id(PSY.get_component(PSY.ThermalStandard, sys, n)) for n in names]
    @test labels == names
    (bus_ids, bus_names) = IOM.resolve_component_axis(sys, PSY.ACBus, ["1", "2"])
    @test bus_ids == [IS.get_id(PSY.get_bus(sys, 1)), IS.get_id(PSY.get_bus(sys, 2))]
    @test bus_names ==
          [PSY.get_name(PSY.get_bus(sys, 1)), PSY.get_name(PSY.get_bus(sys, 2))]
    @test IOM.resolve_component_axis(sys, PSY.ThermalStandard, ["nope"]) ==
          (Int[], ["nope"])
    @test IOM.resolve_component_axis(sys, PSY.System, ["1"]) == (Int[], ["1"])
end
