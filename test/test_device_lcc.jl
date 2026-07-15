function _sys5_with_lcc()
    sys5 = build_system(PSISystems, "2Area 5 Bus System")
    hvdc = first(get_components(TwoTerminalGenericHVDCLine, sys5))
    lcc = TwoTerminalLCCLine(;
        name = "lcc",
        available = true,
        arc = hvdc.arc,
        active_power_flow = 0.1,
        r = 0.000189,
        transfer_setpoint = -100.0,
        scheduled_dc_voltage = 7.5,
        rectifier_bridges = 2,
        rectifier_delay_angle_limits = (min = 0.31590, max = 1.570),
        rectifier_rc = 2.6465e-5,
        rectifier_xc = 0.001092,
        rectifier_base_voltage = 230.0,
        inverter_bridges = 2,
        inverter_extinction_angle_limits = (min = 0.3037, max = 1.57076),
        inverter_rc = 2.6465e-5,
        inverter_xc = 0.001072,
        inverter_base_voltage = 230.0,
        power_mode = true,
        switch_mode_voltage = 0.0,
        compounding_resistance = 0.0,
        min_compounding_voltage = 0.0,
        rectifier_transformer_ratio = 0.09772,
        rectifier_tap_setting = 1.0,
        rectifier_tap_limits = (min = 1, max = 1),
        rectifier_tap_step = 0.00624,
        rectifier_delay_angle = 0.31590,
        rectifier_capacitor_reactance = 0.1,
        inverter_transformer_ratio = 0.07134,
        inverter_tap_setting = 1.0,
        inverter_tap_limits = (min = 1, max = 1),
        inverter_tap_step = 0.00625,
        inverter_extinction_angle = 0.31416,
        inverter_capacitor_reactance = 0.0,
        active_power_limits_from = (min = -3.0, max = 3.0),
        active_power_limits_to = (min = -3.0, max = 3.0),
        reactive_power_limits_from = (min = -3.0, max = 3.0),
        reactive_power_limits_to = (min = -3.0, max = 3.0),
    )

    add_component!(sys5, lcc)
    remove_component!(sys5, hvdc)
    return sys5
end

function _solve_lcc_model(network_formulation)
    sys5 = _sys5_with_lcc()
    template = get_thermal_dispatch_template_network(
        NetworkModel(
            network_formulation;
            use_slacks = false,
        ),
    )
    set_device_model!(template, TwoTerminalLCCLine, HVDCTwoTerminalLCC)
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    model = DecisionModel(
        template,
        sys5;
        optimizer = optimizer_with_attributes(Ipopt.Optimizer),
        horizon = Hour(2),
    )
    build_status = build!(model; output_dir = mktempdir(; cleanup = true))
    return model, build_status
end

# LCC needs an AC voltage-magnitude term: the bus VoltageMagnitude under ACP, the
# per-terminal RegulatedVoltageMagnitude aux under ACR/IVR. All three are exact AC
# formulations, so their optima must agree.
@testset "LCC HVDC System Tests" begin
    objectives = Dict{Any, Float64}()
    for network_formulation in (ACPNetworkModel, ACRNetworkModel, IVRNetworkModel)
        model, build_status = _solve_lcc_model(network_formulation)
        @test build_status == IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        container = IOM.get_optimization_container(model)
        objectives[network_formulation] =
            JuMP.objective_value(IOM.get_jump_model(container))
    end
    @test isapprox(
        objectives[ACRNetworkModel], objectives[ACPNetworkModel]; rtol = 1e-6,
    )
    @test isapprox(
        objectives[IVRNetworkModel], objectives[ACPNetworkModel]; rtol = 1e-6,
    )
end

# LPACC carries the voltage magnitude as 1 + VoltageDeviation, so the LCC converter
# equations build against it. The reactive consumption is the point of the formulation:
# assert at the coefficient level that both terminal reactive variables enter
# ReactivePowerBalance as loads and both active variables enter ActivePowerBalance.
@testset "LCC HVDC on LPACC" begin
    model, build_status = _solve_lcc_model(LPACCNetworkModel)
    @test build_status == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    sys = IOM.get_system(model)
    lcc = first(get_components(TwoTerminalLCCLine, sys))
    name = get_name(lcc)
    arc = get_arc(lcc)
    from_no = get_number(get_from(arc))
    to_no = get_number(get_to(arc))

    p_from = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedFromVariable, TwoTerminalLCCLine,
    )
    p_to = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedToVariable, TwoTerminalLCCLine,
    )
    q_from = IOM.get_variable(
        container, POM.HVDCReactivePowerReceivedFromVariable, TwoTerminalLCCLine,
    )
    q_to = IOM.get_variable(
        container, POM.HVDCReactivePowerReceivedToVariable, TwoTerminalLCCLine,
    )
    p_expr = IOM.get_expression(container, ActivePowerBalance, ACBus)
    q_expr = IOM.get_expression(container, ReactivePowerBalance, ACBus)
    for t in IOM.get_time_steps(container)
        @test JuMP.coefficient(p_expr[from_no, t], p_from[name, t]) == -1.0
        @test JuMP.coefficient(p_expr[to_no, t], p_to[name, t]) == 1.0
        @test JuMP.coefficient(q_expr[from_no, t], q_from[name, t]) == -1.0
        @test JuMP.coefficient(q_expr[to_no, t], q_to[name, t]) == -1.0
    end

    # The LCC's free optimum on this system is zero DC current (no economic driver),
    # so the reactive variables would sit at zero and prove nothing. Force the line to
    # carry current: the converter power-calculation constraints then make both
    # terminals draw strictly positive reactive power, confirming the reactive term is
    # physically coupled and not a dangling free variable.
    idc = IOM.get_variable(
        container, POM.DCLineCurrentFlowVariable, TwoTerminalLCCLine,
    )
    for t in IOM.get_time_steps(container)
        JuMP.fix(idc[name, t], 0.5; force = true)
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    for t in IOM.get_time_steps(container)
        @test JuMP.value(q_from[name, t]) > 1e-3
        @test JuMP.value(q_to[name, t]) > 1e-3
    end
end

# An LCC's defining feature is reactive consumption; networks without a reactive
# balance must be rejected at template validation rather than failing deep in build!.
@testset "LCC HVDC gated on reactive-less networks" begin
    sys5 = _sys5_with_lcc()
    for network_formulation in
        (CopperPlateNetworkModel, PTDFNetworkModel, DCPNetworkModel, NFANetworkModel)
        template = get_thermal_dispatch_template_network(
            NetworkModel(network_formulation),
        )
        set_device_model!(template, TwoTerminalLCCLine, HVDCTwoTerminalLCC)
        set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
        model = DecisionModel(template, sys5; optimizer = HiGHS_optimizer)
        @test_throws IS.ConflictingInputsError POM.validate_template(model)
    end
end
