_started_variables(model) = [
    v for
    v in JuMP.all_variables(IOM.get_jump_model(IOM.get_optimization_container(model)))
    if JuMP.start_value(v) !== nothing
]

function _build_for_warm_start(template, sys, optimizer, warm_start)
    model = DecisionModel(template, sys; optimizer = optimizer, warm_start = warm_start)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

function _phase_controlled_case()
    fixture = _controlled_sys14(
        P_FLOW_CONTROL;
        circuit_index = MESHED_TRANSFORMER_INDEX,
    )
    template = _controlled_template(DCPNetworkModel, PSY.TwoWindingTransformer)
    return template, fixture.sys, HiGHS_optimizer
end

function _nodal_case(network_formulation)
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(network_formulation))
    return template, sys, ipopt_optimizer
end

function _regulated_voltage_case()
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    facts = PSY.FACTSControlDevice(;
        name = "facts_warm_start",
        available = true,
        bus = PSY.get_component(PSY.ACBus, sys, "nodeA"),
        control_mode = nothing,
        voltage_setpoint = 1.0,
        max_shunt_current = 100.0,
        input_basis = CU,
    )
    PSY.add_component!(sys, facts)
    template = get_thermal_dispatch_template_network(NetworkModel(ACRNetworkModel))
    set_device_model!(template, PSY.FACTSControlDevice, ShuntSusceptanceDispatch)
    return template, sys, ipopt_optimizer
end

const WARM_START_MUST_RUN_UNIT = "Alta"

function _unit_commitment_case()
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    must_run = PSY.get_component(PSY.ThermalStandard, sys, WARM_START_MUST_RUN_UNIT)
    PSY.set_commitment_mode!(must_run, PSY.CommitmentModes.MUST_RUN)
    return get_thermal_standard_uc_template(), sys, HiGHS_optimizer
end

# Each case pairs a fixture with the variables whose start values come from POM's own
# builders rather than IOM's device/service builders.
const WARM_START_CASES = (
    "thermal unit commitment" => (
        _unit_commitment_case,
        [(OnVariable, PSY.ThermalStandard)],
    ),
    "DCP phase control" => (
        _phase_controlled_case,
        [(PhaseShifterAngle, PSY.TwoWindingTransformer)],
    ),
    "ACP" => (
        () -> _nodal_case(ACPNetworkModel),
        [(VoltageMagnitude, PSY.ACBus)],
    ),
    "ACR regulated voltage" => (
        _regulated_voltage_case,
        [
            (VoltageReal, PSY.ACBus),
            (VoltageImaginary, PSY.ACBus),
            (RegulatedVoltageMagnitude, PSY.FACTSControlDevice),
        ],
    ),
    "LPAC" => (
        () -> _nodal_case(LPACCNetworkModel),
        [(VoltageDeviation, PSY.ACBus), (CosineApproximation, PSY.Line)],
    ),
)

@testset "warm_start = false sets no start values ($name)" for (name, (case, _)) in
                                                               WARM_START_CASES
    model = _build_for_warm_start(case()..., false)
    @test isempty(_started_variables(model))
end

@testset "warm_start = true sets start values ($name)" for (name, (case, keys)) in
                                                           WARM_START_CASES
    model = _build_for_warm_start(case()..., true)
    container = IOM.get_optimization_container(model)
    for (V, C) in keys
        vars = IOM.get_variables(container)
        matching = [
            v for (k, v) in vars if IOM.get_entry_type(k) === V &&
            IOM.get_component_type(k) === C
        ]
        @test !isempty(matching)
        @test all(
            JuMP.start_value(x) !== nothing for arr in matching for x in arr.data
            if x isa JuMP.VariableRef
        )
    end
end

@testset "must-run units carry no commitment variables" begin
    model = _build_for_warm_start(_unit_commitment_case()..., true)
    container = IOM.get_optimization_container(model)
    for V in (OnVariable, StartVariable, StopVariable)
        names = axes(IOM.get_variable(container, V, PSY.ThermalStandard))[1]
        @test WARM_START_MUST_RUN_UNIT ∉ names
        @test !isempty(names)
    end
end
