_var(model, T, D) = IOM.get_variable(IOM.get_optimization_container(model), T, D)
function _sys_with_hvdc_tie_out(steps)
    sys = _c_sys5_uc()
    arc = PSY.get_arc(first(_sorted(PSY.Line, sys)))
    hvdc = PSY.TwoTerminalGenericHVDCLine(;
        name = "hvdc_tie",
        available = true,
        active_power_flow = 0.0,
        rating = 2.0,
        rating_from = 2.0,
        rating_to = 2.0,
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        arc = arc,
        loss = PSY.LossCurve(PSY.LinearCurve(0.05, 0.01), PSY.CU),
        input_basis = u"CU",
    )
    PSY.add_component!(sys, hvdc)
    _schedule_outage!(sys, hvdc, _out_at(steps))
    return sys
end

function _hvdc_template(net, formulation)
    template = get_thermal_dispatch_template_network(NetworkModel(net))
    set_device_model!(template, PSY.TwoTerminalGenericHVDCLine, formulation)
    return template
end

function _check_fixed_only_when_out(variable, name, steps)
    for t in axes(variable, 2)
        @test _fixed_at_zero(variable[name, t]) == (t in steps)
    end
    return
end

@testset "An out HVDC line has zero flow under HVDCTwoTerminalLossless on $(net)" for net in
                                                                                      (
    PTDFNetworkModel,
    DCPNetworkModel,
)
    sys = _sys_with_hvdc_tie_out(3:5)
    model = _built_model(_hvdc_template(net, HVDCTwoTerminalLossless), sys)
    flow = _var(model, FlowActivePowerVariable, PSY.TwoTerminalGenericHVDCLine)
    _check_fixed_only_when_out(flow, "hvdc_tie", 3:5)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    for t in 3:5
        @test JuMP.value(flow["hvdc_tie", t]) == 0.0
    end
end

@testset "An out HVDC line has no flow or losses under HVDCTwoTerminalDispatch" begin
    sys = _sys_with_hvdc_tie_out(3:5)
    model = _built_model(_hvdc_template(PTDFNetworkModel, HVDCTwoTerminalDispatch), sys)
    D = PSY.TwoTerminalGenericHVDCLine
    for T in (FlowActivePowerFromToVariable, FlowActivePowerToFromVariable, HVDCLosses)
        _check_fixed_only_when_out(_var(model, T, D), "hvdc_tie", 3:5)
    end
    direction = _var(model, HVDCFlowDirectionVariable, D)
    for t in axes(direction, 2)
        @test !JuMP.is_fixed(direction["hvdc_tie", t])
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "An out HVDC line has no flow under HVDCTwoTerminalPiecewiseLoss" begin
    sys = _sys_with_hvdc_tie_out(3:5)
    model =
        _built_model(_hvdc_template(PTDFNetworkModel, HVDCTwoTerminalPiecewiseLoss), sys)
    D = PSY.TwoTerminalGenericHVDCLine
    for T in (
        POM.HVDCActivePowerReceivedFromVariable,
        POM.HVDCActivePowerReceivedToVariable,
    )
        _check_fixed_only_when_out(_var(model, T, D), "hvdc_tie", 3:5)
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "An out TModelHVDCLine has zero flow under LosslessLine" begin
    sys = PSB.build_system(PSISystems, "sys10_pjm_ac_dc")
    line = first(_sorted(PSY.TModelHVDCLine, sys))
    _schedule_outage!(sys, line, _out_at(2:2))
    template = PowerOperationsProblemTemplate(NetworkModel(DCPNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, TModelHVDCLine, LosslessLine)
    set_device_model!(template, InterconnectingConverter, LosslessConverter)
    set_hvdc_network_model!(template, TransportHVDCNetworkModel)
    model = _built_model(template, sys; horizon = _SHORT_HORIZON)
    flow = _var(model, FlowActivePowerVariable, PSY.TModelHVDCLine)
    _check_fixed_only_when_out(flow, PSY.get_name(line), 2:2)
    for other in _sorted(PSY.TModelHVDCLine, sys)
        PSY.get_name(other) == PSY.get_name(line) && continue
        _check_fixed_only_when_out(flow, PSY.get_name(other), 1:0)
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test JuMP.value(flow[PSY.get_name(line), 2]) == 0.0
end

struct _StatusProbeConstraint <: POM.PowerVariableLimitsConstraint end
IOM.get_min_max_limits(
    d::PSY.ThermalStandard,
    ::Type{_StatusProbeConstraint},
    ::Type{ThermalBasicDispatch},
) = PSY.get_active_power_limits(d, u"SU")

@testset "Status-scaled power limits cover every device collection IOM accepts" begin
    sys = _c_sys5_uc()
    unit = first(_sorted(PSY.ThermalStandard, sys))
    name = PSY.get_name(unit)
    _schedule_outage!(sys, unit, _out_at(3:5))
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    model = _built_model(template, sys)
    container = IOM.get_optimization_container(model)
    device_model = DeviceModel(PSY.ThermalStandard, ThermalBasicDispatch)
    limits = PSY.get_active_power_limits(unit, u"SU")
    for (i, devices) in enumerate((
        _sorted(PSY.ThermalStandard, sys),
        PSY.get_components(PSY.ThermalStandard, sys),
    ))
        # The constraints built for the collection carry the status: an out step bounds the
        # variable at zero, and an in-service step keeps the plain limits.
        IOM.add_range_constraints!(
            container,
            _StatusProbeConstraint,
            POM.ActivePowerVariable,
            devices,
            device_model,
            CopperPlateNetworkModel,
        )
        constraints = IOM.get_constraints(container)
        key(meta) = IOM.ConstraintKey(_StatusProbeConstraint, PSY.ThermalStandard, meta)
        lb = constraints[key("lb")]
        ub = constraints[key("ub")]
        for t in IOM.get_time_steps(container)
            out = t in 3:5
            @test JuMP.normalized_rhs(ub[name, t]) ==
                  (out ? 0.0 : limits.max)
            @test JuMP.normalized_rhs(lb[name, t]) ==
                  (out ? 0.0 : limits.min)
        end
        # The next collection type needs a fresh constraint container.
        delete!(constraints, key("lb"))
        delete!(constraints, key("ub"))
    end
end

@testset "Component statuses come from the injector and HVDC schedules only" begin
    sys = _sys_with_hvdc_tie_out(3:5)
    unit = first(_sorted(PSY.ThermalStandard, sys))
    other = last(_sorted(PSY.ThermalStandard, sys))
    _schedule_outage!(sys, unit, _out_at(2:2))
    model = _built_model(_hvdc_template(PTDFNetworkModel, HVDCTwoTerminalLossless), sys)
    container = _container(model)
    thermal = IOM.get_component_statuses(container, PSY.ThermalStandard)
    @test thermal isa IOM.ComponentStatusArray
    # Built once per container: every builder reuses the same name lookup.
    @test IOM.get_component_statuses(container, PSY.ThermalStandard) === thermal
    @test IOM.get_component_status(thermal, PSY.get_name(unit), 2) == 0.0
    @test IOM.get_component_status(thermal, PSY.get_name(unit), 1) == 1.0
    @test IOM.get_component_status(thermal, PSY.get_name(other), 2) == 1.0
    hvdc = IOM.get_component_statuses(container, PSY.TwoTerminalGenericHVDCLine)
    @test IOM.get_component_status(hvdc, "hvdc_tie", 3) == 0.0
    @test IOM.get_component_status(hvdc, "hvdc_tie", 2) == 1.0
    @test IOM.get_component_statuses(container, PSY.PowerLoad) isa IOM.AllComponentsActive
    @test IOM.get_component_statuses(container, PSY.Line) isa IOM.AllComponentsActive
end

@testset "Status vectors require steps starting at 1" begin
    @test isnothing(POM._check_steps_start_at_one(1:24))
    @test_throws ArgumentError POM._check_steps_start_at_one(2:24)
end

# A compact unit commitment model with a semicontinuous feedforward commits through its own
# `OnVariable`; the feedforward parameter serves only formulations without commitment.
function _compact_uc_objective(; feedforward, fuel = false)
    sys = _c_sys5_uc()
    if fuel
        unit = PSY.get_component(PSY.ThermalStandard, sys, "Brighton")
        cost = PSY.get_operation_cost(unit)
        PSY.set_operation_cost!(
            unit,
            PSY.ThermalGenerationCost(;
                variable_operation_cost = PSY.FuelCurve(;
                    value_curve = PSY.LinearCurve(17.0),
                    fuel_units = PSY.MMBtu,
                    fuel_cost = 2.5,
                ),
                fixed = PSY.get_fixed(cost),
                start_up = PSY.get_start_up(cost),
                shut_down = PSY.get_shut_down(cost),
            ),
        )
    end
    device_model = DeviceModel(ThermalStandard, ThermalCompactUnitCommitment)
    feedforward && attach_feedforward!(
        device_model,
        SemiContinuousFeedforward(;
            component_type = ThermalStandard,
            source = OnVariable,
            affected_values = [PowerAboveMinimumVariable],
        ),
    )
    model = DecisionModel(MockOperationProblem, CopperPlateNetworkModel, sys)
    mock_construct_device!(model, device_model)
    return sys, IOM.get_optimization_container(model)
end

@testset "Compact unit commitment with a feedforward prices its own commitment" begin
    _, plain = _compact_uc_objective(; feedforward = false)
    sys, container = _compact_uc_objective(; feedforward = true)
    @test IOM.has_container_key(container, OnStatusParameter, PSY.ThermalStandard)
    objective(c) = c.objective_function.invariant_terms
    on = IOM.get_variable(container, OnVariable, PSY.ThermalStandard)
    on_plain = IOM.get_variable(plain, OnVariable, PSY.ThermalStandard)
    for name in axes(on, 1), t in axes(on, 2)
        coefficient = JuMP.coefficient(objective(container), on[name, t])
        @test coefficient == JuMP.coefficient(objective(plain), on_plain[name, t])
    end
    @test any(!iszero, (JuMP.coefficient(objective(container), v) for v in on.data))
    @test JuMP.constant(objective(container)) == JuMP.constant(objective(plain))
    unit = PSY.get_component(PSY.ThermalStandard, sys, "Brighton")
    pmin = POM.min_active_power_values(container, unit)
    terms = POM._min_power_series(container, ThermalCompactUnitCommitment, unit)
    for t in axes(on, 2)
        @test JuMP.coefficient(terms[t], on["Brighton", t]) ≈ pmin[t]
    end
end

@testset "Compact unit commitment with a feedforward burns fuel on its own commitment" begin
    _, plain = _compact_uc_objective(; feedforward = false, fuel = true)
    sys, container = _compact_uc_objective(; feedforward = true, fuel = true)
    fuel(c) = IOM.get_expression(c, POM.FuelConsumptionExpression, PSY.ThermalStandard)
    on = IOM.get_variable(container, OnVariable, PSY.ThermalStandard)
    on_plain = IOM.get_variable(plain, OnVariable, PSY.ThermalStandard)
    param = IOM.get_parameter_array(container, OnStatusParameter, PSY.ThermalStandard)
    unit = PSY.get_component(PSY.ThermalStandard, sys, "Brighton")
    pmin = POM.min_active_power_values(container, unit)
    @test any(!iszero, pmin)
    for t in axes(on, 2)
        expression = fuel(container)["Brighton", t]
        # The minimum-power term `Pmin * u` is on the unit's own commitment.
        @test JuMP.coefficient(expression, on["Brighton", t]) ≈
              JuMP.coefficient(fuel(plain)["Brighton", t], on_plain["Brighton", t])
        @test iszero(pmin[t]) || !iszero(JuMP.coefficient(expression, on["Brighton", t]))
        @test JuMP.constant(expression) == JuMP.constant(fuel(plain)["Brighton", t])
        param["Brighton", t] isa JuMP.VariableRef &&
            @test iszero(JuMP.coefficient(expression, param["Brighton", t]))
    end
end
