const UNITS_JSON_PATH = joinpath(
    get(ENV, "SIENNA_SCHEMAS_DIR", joinpath(@__DIR__, "..", "..", "SiennaSchemas")),
    "Core",
    "units.json",
)
if !isfile(UNITS_JSON_PATH)
    error(
        "SiennaSchemas units.json not found at $UNITS_JSON_PATH; " *
        "set SIENNA_SCHEMAS_DIR to a SiennaSchemas checkout",
    )
end
const UNITS_JSON = JSON.parsefile(UNITS_JSON_PATH)
const QUANTITY_KINDS = Set(String[k["name"] for k in UNITS_JSON["quantity_kinds"]])
const ALLOWED_UNITS = Set(
    Tuple{String, String}[
        (u["quantity_kind"], u["unit"]) for u in UNITS_JSON["allowed_units"]
    ],
)

function unit_failures(::Type{T}) where {T}
    failures = String[]
    try
        unit_system = IS.Optimization.output_unit_system(T)
        kind = IS.Optimization.quantity_kind(T)
        if !(unit_system in (IS.SU, IS.CU, IS.NU))
            push!(failures, "$T: bad output_unit_system")
        end
        if !(kind in QUANTITY_KINDS)
            push!(failures, "$T: bad quantity_kind")
        end
        if unit_system === IS.NU
            units = IS.Optimization.natural_units(T)
            if !((kind, units) in ALLOWED_UNITS)
                push!(failures, "$T: natural_units \"$units\" not allowed for $kind")
            end
        end
    catch err
        push!(failures, "$T: $(sprint(showerror, err))")
    end
    return failures
end

# `get_all_concrete_subtypes` skips parametric key types: instantiate them per side.
const PARAMETRIC_KEY_TYPES = [
    POM.HybridStorageSubcomponentPower{POM.DischargeSide},
    POM.HybridStorageSubcomponentPower{POM.ChargeSide},
    POM.RegularizationVariable{POM.DischargeSide},
    POM.RegularizationVariable{POM.ChargeSide},
    POM.HybridPCCReserveVariable{POM.DischargeSide},
    POM.HybridPCCReserveVariable{POM.ChargeSide},
    POM.HybridStorageSubcomponentReserveVariable{POM.DischargeSide},
    POM.HybridStorageSubcomponentReserveVariable{POM.ChargeSide},
]

# Constraints are written only as duals: only the price-bearing balance, requirement and
# flow-limit constraints declare units.
const DECLARED_DUAL_TYPES = [
    POM.CopperPlateBalanceConstraint,
    POM.NodalBalanceActiveConstraint,
    POM.RequirementConstraint,
    POM.FlowRateConstraint,
    POM.OperationalFlowLimitConstraint,
    POM.PostContingencyFlowRateConstraint,
]

@testset "test_every_written_key_type_declares_units" begin
    failures = String[]
    count = 0
    for A in (
        IS.Optimization.VariableType,
        IS.Optimization.AuxVariableType,
        IS.Optimization.ParameterType,
        IS.Optimization.ExpressionType,
    )
        for T in IS.get_all_concrete_subtypes(A)
            if parentmodule(T) === POM &&
               IOM.writes_output_dataset(T)
                count += 1
                append!(failures, unit_failures(T))
            end
        end
    end
    @test count > 100
    isempty(failures) || println(join(failures, "\n"))
    @test isempty(failures)
end

@testset "test_parametric_key_types_declare_units" begin
    for T in PARAMETRIC_KEY_TYPES
        @test isempty(unit_failures(T))
    end
end

@testset "test_dual_units_declared_for_balance_requirement_and_flow_limit_only" begin
    for T in DECLARED_DUAL_TYPES
        @test isempty(unit_failures(T))
        @test IS.Optimization.output_unit_system(T) === IS.SU
        @test IS.Optimization.quantity_kind(T) == "CostPerEnergy"
    end
    @test !isempty(unit_failures(POM.ReservePowerConstraint))
    @test_throws Exception IS.Optimization.output_unit_system(POM.ReservePowerConstraint)
    declared = Set(DECLARED_DUAL_TYPES)
    undeclared = [
        T for T in IS.get_all_concrete_subtypes(IS.Optimization.ConstraintType) if
        parentmodule(T) === POM && !(T in declared)
    ]
    @test !isempty(undeclared)
    @test all(T -> !isempty(unit_failures(T)), undeclared)
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

function _test_bus(::Type{B}, number::Int, name::String) where {B <: PSY.Bus}
    return B(;
        input_basis = u"CU",
        number = number,
        name = name,
        available = true,
        magnitude = 1.0,
        voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = 100.0,
    )
end

@testset "test_resolve_component_axis_warns_on_unresolved_labels" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    @test_logs (:warn, r"label-only") IOM.resolve_component_axis(
        sys, PSY.ThermalStandard, ["nope"],
    )
    @test_logs (:warn, r"label-only") IOM.resolve_component_axis(
        sys, PSY.ACBus, ["no_such_bus"],
    )
end

@testset "test_resolve_bus_axis_errors_on_number_name_collision" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    # "901" is the number of the first bus and the name of the second.
    bus_a = _test_bus(PSY.DCBus, 901, "dc_a")
    bus_b = _test_bus(PSY.DCBus, 902, "901")
    PSY.add_component!(sys, bus_a)
    PSY.add_component!(sys, bus_b)
    @test_throws ErrorException IOM.resolve_component_axis(sys, PSY.DCBus, ["901"])
end

@testset "test_resolve_axis_errors_on_duplicate_names_across_concrete_types" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    PSY.add_component!(sys, PSY.Area("dup_name", 0.0, 0.0, 0.0))
    PSY.add_component!(sys, PSY.LoadZone("dup_name", 0.0, 0.0))
    @test_throws ErrorException IOM.resolve_component_axis(
        sys, PSY.AggregationTopology, ["dup_name"],
    )
    # A bus name shared by an ACBus and a DCBus under the abstract Bus type.
    name = PSY.get_name(first(PSY.get_components(PSY.ACBus, sys)))
    PSY.add_component!(sys, _test_bus(PSY.DCBus, 903, name))
    @test_throws ErrorException IOM.resolve_component_axis(sys, PSY.Bus, [name])
end
