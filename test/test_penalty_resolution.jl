# Slack penalties are per pu-hour, like device costs: each objective term multiplies the
# penalty by the step length in hours. Hourly models keep the exact constant.

const _RESOLUTIONS = (("c_sys5_uc", Dates.Hour(1)), ("c_sys5_ed", Dates.Minute(5)))

# Step length in hours, computed apart from POM's helper.
_step_hours(step::Dates.Period) = Dates.value(Dates.Millisecond(step)) / 3_600_000

function _expected_cost(cost::Float64, step::Dates.Period, dt::Float64)
    if step == Dates.Hour(1)
        return cost
    end
    return cost * dt
end

# Every thermal capped at zero, so the balance slack carries the whole load.
function _balance_slack_model(sys_name::String)
    sys = PSB.build_system(PSITestSystems, sys_name)
    for g in PSY.get_components(PSY.ThermalStandard, sys)
        PSY.set_active_power_limits!(g, (min = 0.0 * u"SU", max = 0.0 * u"SU"))
    end
    net = NetworkModel(
        CopperPlateNetworkModel;
        use_slacks = true,
        duals = [CopperPlateBalanceConstraint],
    )
    model = DecisionModel(
        get_thermal_dispatch_template_network(net), sys; optimizer = HiGHS_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

# Lines rated near zero, so physics forces flow onto the slacks.
function _capped_branch_model(sys_name::String)
    sys = PSB.build_system(PSITestSystems, sys_name)
    foreach(l -> PSY.set_rating!(l, 1e-3 * u"SU"), PSY.get_components(PSY.Line, sys))
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            StaticBranch;
            use_slacks = true,
            duals = [FlowRateConstraint],
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

@testset "Balance slack penalty is per hour at any resolution" begin
    for (sys_name, step) in _RESOLUTIONS
        model = _balance_slack_model(sys_name)
        container = IOM.get_optimization_container(model)
        @test IOM.get_resolution(container) == Dates.Millisecond(step)
        dt = _step_hours(step)
        @test POM._hours_per_step(container) == dt
        obj = JuMP.objective_function(IOM.get_jump_model(container))
        expected = _expected_cost(POM.BALANCE_SLACK_COST, step, dt)
        for S in (SystemBalanceSlackUp, SystemBalanceSlackDown)
            slack = IOM.get_variable(container, S, PSY.System)
            @test all(JuMP.coefficient(obj, v) == expected for v in slack)
        end
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        up = IOM.get_variable(container, SystemBalanceSlackUp, PSY.System)
        @test all(JuMP.value(v) > 1e-6 for v in up)
        balance = IOM.get_constraint(container, CopperPlateBalanceConstraint, PSY.System)
        @test all(abs(JuMP.dual(c)) / dt ≈ POM.BALANCE_SLACK_COST for c in balance)
    end
end

@testset "A capped branch row reads its per-hour slack cost" begin
    cost = POM.CONSTRAINT_VIOLATION_SLACK_COST
    for (sys_name, step) in _RESOLUTIONS
        model = _capped_branch_model(sys_name)
        container = IOM.get_optimization_container(model)
        dt = _step_hours(step)
        @test POM._hours_per_step(container) == dt
        obj = JuMP.objective_function(IOM.get_jump_model(container))
        slack = IOM.get_variable(container, FlowActivePowerSlackUpperBound, PSY.Line)
        @test all(JuMP.coefficient(obj, v) == _expected_cost(cost, step, dt) for v in slack)
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        ub = IOM.get_constraint(container, FlowRateConstraint, PSY.Line, "ub")
        active = [
            (n, t) for n in axes(slack, 1), t in axes(slack, 2) if
            JuMP.value(slack[n, t]) > 1e-6
        ]
        @test !isempty(active)
        @test all(abs(JuMP.dual(ub[n, t])) / dt ≈ cost for (n, t) in active)
    end
end

@testset "Reserve and interface slack penalties are per hour" begin
    # Hour(2) covers a multi-hour step, where penalties grow by dt.
    for (sys_name, step) in (_RESOLUTIONS..., ("c_sys5_uc", Dates.Hour(2)))
        sys = PSB.build_system(PSITestSystems, sys_name)
        container = build_test_container(sys, 1:2; resolution = step)
        dt = _step_hours(step)
        @test POM._hours_per_step(container) == dt

        R = PSY.OnlineReserve{PSY.ReserveUp}
        POM.add_reserve_slacks!(container, R, ["R1"])
        @test obj_coef(container, ReserveRequirementSlack, R, "R1", 2) ==
              _expected_cost(POM.SERVICES_SLACK_COST, step, dt)

        interface = PSY.TransmissionInterface(;
            name = "i1",
            available = true,
            active_power_flow_limits = (min = -1.0, max = 1.0),
            violation_penalty = 750.0,
            input_basis = u"CU",
        )
        POM.transmission_interface_slacks!(container, [interface])
        for S in (InterfaceFlowSlackUp, InterfaceFlowSlackDown)
            @test obj_coef(container, S, PSY.TransmissionInterface, "i1", 1) ==
                  _expected_cost(750.0, step, dt)
        end
    end
end

@testset "Feedforward bound slack penalty is per hour" begin
    for (sys_name, step) in (("c_sys5", Dates.Hour(1)), ("c_sys5_ed", Dates.Minute(5)))
        device_model = DeviceModel(PSY.ThermalStandard, ThermalStandardDispatch)
        attach_feedforward!(
            device_model,
            UpperBoundFeedforward(;
                component_type = PSY.ThermalStandard,
                source = ActivePowerVariable,
                affected_values = [ActivePowerVariable],
                add_slacks = true,
            ),
        )
        sys = PSB.build_system(PSITestSystems, sys_name)
        model = DecisionModel(MockOperationProblem, DCPNetworkModel, sys)
        mock_construct_device!(model, device_model; built_for_recurrent_solves = true)
        container = IOM.get_optimization_container(model)
        @test IOM.get_resolution(container) == Dates.Millisecond(step)
        dt = _step_hours(step)
        @test POM._hours_per_step(container) == dt
        slack = IOM.get_variable(
            container,
            UpperBoundFeedForwardSlack,
            PSY.ThermalStandard,
            "$(nameof(ActivePowerVariable))",
        )
        obj = JuMP.objective_function(IOM.get_jump_model(container))
        expected = _expected_cost(POM.BALANCE_SLACK_COST, step, dt)
        @test all(get(obj.terms, v, 0.0) == expected for v in slack)
    end
end
