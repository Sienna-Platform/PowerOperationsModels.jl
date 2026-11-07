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
