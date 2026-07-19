function _make_lcc_line(arc; name = "lcc")
    return TwoTerminalLCCLine(;
        name = name,
        available = true,
        arc = arc,
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
end

function _sys5_with_lcc()
    sys5 = build_system(PSISystems, "2Area 5 Bus System")
    hvdc = first(get_components(TwoTerminalGenericHVDCLine, sys5))
    lcc = _make_lcc_line(hvdc.arc)

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
        container, POM.HVDCRectifierActivePowerVariable, TwoTerminalLCCLine,
    )
    p_to = IOM.get_variable(
        container, POM.HVDCInverterActivePowerVariable, TwoTerminalLCCLine,
    )
    q_from = IOM.get_variable(
        container, POM.HVDCRectifierReactivePowerVariable, TwoTerminalLCCLine,
    )
    q_to = IOM.get_variable(
        container, POM.HVDCInverterReactivePowerVariable, TwoTerminalLCCLine,
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

# `2Area 5 Bus System` (the base of `_sys5_with_lcc`) ships zero `Area` components, so it
# cannot host an inter-area AreaInterchange (verified directly: `get_components(PSY.Area,
# sys)` is empty and its bus `get_area` is `nothing`). Fall back to `two_area_pjm_DA`,
# which ships Area1/Area2 and an AreaInterchange ("1_2") already spanning them, and add
# the LCC onto its existing `Bus_nodeC_1 -> Bus_nodeC_2` arc (an inter-area tie between
# Area1 and Area2). The LCC parameter block is shared via `_make_lcc_line`.
function _two_area_sys_with_lcc_tie()
    sys = build_system(PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(sys, Hour(24), Hour(1))
    bus_from = PSY.get_component(PSY.ACBus, sys, "Bus_nodeC_1")
    bus_to = PSY.get_component(PSY.ACBus, sys, "Bus_nodeC_2")
    existing_arcs = PSY.get_components(
        x -> PSY.get_from(x) == bus_from && PSY.get_to(x) == bus_to, PSY.Arc, sys,
    )
    if isempty(existing_arcs)
        arc = PSY.Arc(; from = bus_from, to = bus_to)
        PSY.add_component!(sys, arc)
    else
        arc = first(existing_arcs)
    end
    lcc = _make_lcc_line(arc)
    PSY.add_component!(sys, lcc)
    return sys
end

# Reproduces the bug fixed by earlier tasks in this plan: `_add_measured_tie_line_flows!`
# (src/area_interchange.jl) previously did not know the LCC's variable set, so metering
# an LCC tie inside an AreaInterchange's LineFlowBoundConstraint died deep in build!.
#
# Orientation check (verified directly against the fixture): the shipped interchange
# "1_2" is keyed (from_area = Area1, to_area = Area2); `Bus_nodeC_1` is in Area1 and
# `Bus_nodeC_2` is in Area2, so the LCC's `Bus_nodeC_1 -> Bus_nodeC_2` arc matches the
# interchange orientation directly (same conclusion the existing directional-HVDC
# testset in `test_device_load_constructors.jl` draws for the same arc). The tie is
# therefore measured at its own from terminal - the rectifier - with coefficient +1.0
# (export = +rectifier draw).
@testset "AreaInterchange meters an LCC tie at the rectifier terminal (ACP)" begin
    sys = _two_area_sys_with_lcc_tie()
    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    set_device_model!(template, TwoTerminalLCCLine, HVDCTwoTerminalLCC)
    set_device_model!(template, AreaInterchange, StaticBranch)

    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    interchange_name =
        PSY.get_name(first(PSY.get_components(PSY.AreaInterchange, sys)))
    container = IOM.get_optimization_container(model)
    con_ub = IOM.get_constraint(
        container, POM.LineFlowBoundConstraint, PSY.AreaInterchange, "ub",
    )
    rect = IOM.get_variable(
        container, POM.HVDCRectifierActivePowerVariable, TwoTerminalLCCLine,
    )
    lcc_name = PSY.get_name(first(get_components(TwoTerminalLCCLine, sys)))
    for t in IOM.get_time_steps(container)
        f = JuMP.constraint_object(con_ub[interchange_name, t]).func
        # Interchange keyed (from_area, to_area) == the LCC arc orientation:
        # measured at the rectifier terminal, export = +rectifier draw.
        @test JuMP.coefficient(f, rect[lcc_name, t]) == 1.0
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

# Mirrors the `reverse_tie` idiom in `test_device_load_constructors.jl`: an arc oriented
# opposite the interchange (Area2 -> Area1, via `Bus_nodeD_2 -> Bus_nodeD_1` - verified:
# `Bus_nodeD_2` is in Area2, `Bus_nodeD_1` is in Area1). The LCC is then measured at its
# own to terminal - the inverter - so the interchange export equals minus the inverter's
# injection.
function _two_area_sys_with_reversed_lcc_tie()
    sys = build_system(PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(sys, Hour(24), Hour(1))
    bus_from = PSY.get_component(PSY.ACBus, sys, "Bus_nodeD_2")
    bus_to = PSY.get_component(PSY.ACBus, sys, "Bus_nodeD_1")
    arc = PSY.Arc(; from = bus_from, to = bus_to)
    PSY.add_component!(sys, arc)
    lcc = _make_lcc_line(arc)
    PSY.add_component!(sys, lcc)
    return sys
end

@testset "AreaInterchange meters an LCC tie at the inverter terminal (reversed orientation, ACP)" begin
    sys = _two_area_sys_with_reversed_lcc_tie()
    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    set_device_model!(template, TwoTerminalLCCLine, HVDCTwoTerminalLCC)
    set_device_model!(template, AreaInterchange, StaticBranch)

    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    interchange_name =
        PSY.get_name(first(PSY.get_components(PSY.AreaInterchange, sys)))
    container = IOM.get_optimization_container(model)
    con_ub = IOM.get_constraint(
        container, POM.LineFlowBoundConstraint, PSY.AreaInterchange, "ub",
    )
    inv = IOM.get_variable(
        container, POM.HVDCInverterActivePowerVariable, TwoTerminalLCCLine,
    )
    lcc_name = PSY.get_name(first(get_components(TwoTerminalLCCLine, sys)))
    for t in IOM.get_time_steps(container)
        f = JuMP.constraint_object(con_ub[interchange_name, t]).func
        @test JuMP.coefficient(f, inv[lcc_name, t]) == -1.0
    end
end
