# The deleted PowerModels bridge translated every TwoTerminalHVDC into a PM dcline wired
# into the bus balances of all AC formulations. These tests pin the native replacements:
# every native nodal network model must give the HVDC formulations a real construct path
# (flow variables present and wired into the nodal balances), and template validation must
# reject formulation/network pairs that have no native construct path instead of silently
# building nothing.

# c_sys5 with Line "1" replaced by an HVDC tie on the same arc, so the DC line carries
# real transfer in the economic dispatch.
function _c_sys5_with_hvdc_tie()
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(Line, sys, "1")
    arc = PSY.get_arc(line)
    PSY.remove_component!(sys, line)
    hvdc = TwoTerminalGenericHVDCLine(;
        name = "hvdc_tie",
        available = true,
        active_power_flow = 0.0,
        active_power_limits_from = (min = -2.0, max = 2.0),
        active_power_limits_to = (min = -2.0, max = 2.0),
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        arc = arc,
        loss = LinearCurve(0.0),
    )
    PSY.add_component!(sys, hvdc)
    from_no = PSY.get_number(PSY.get_from(arc))
    to_no = PSY.get_number(PSY.get_to(arc))
    return sys, from_no, to_no
end

# Asymmetric from/to and min/max limits: a from<->to (or min<->max) getter swap in
# get_variable_lower_bound/get_variable_upper_bound would fail these bounds checks, unlike
# with the symmetric limits in _c_sys5_with_hvdc_tie().
function _c_sys5_with_asymmetric_hvdc_tie()
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(Line, sys, "1")
    arc = PSY.get_arc(line)
    PSY.remove_component!(sys, line)
    hvdc = TwoTerminalGenericHVDCLine(;
        name = "hvdc_tie",
        available = true,
        active_power_flow = 0.0,
        active_power_limits_from = (min = -2.0, max = 2.0),
        active_power_limits_to = (min = -2.0, max = 2.0),
        reactive_power_limits_from = (min = -0.4, max = 0.9),
        reactive_power_limits_to = (min = -0.7, max = 0.3),
        arc = arc,
        loss = LinearCurve(0.0),
    )
    PSY.add_component!(sys, hvdc)
    from_no = PSY.get_number(PSY.get_from(arc))
    to_no = PSY.get_number(PSY.get_to(arc))
    return sys, from_no, to_no
end

# Neither constructor sets reactive_power_limits_from/to: both default to (min = 0.0, max = 0.0).
function _no_reactive_hvdc(::Type{TwoTerminalVSCLine}, arc)
    return TwoTerminalVSCLine(;
        name = "hvdc_no_q",
        available = true,
        arc = arc,
        active_power_flow = 0.0,
        rating = 2.0,
        active_power_limits_from = (min = -2.0, max = 2.0),
        active_power_limits_to = (min = -2.0, max = 2.0),
    )
end

function _no_reactive_hvdc(::Type{TwoTerminalLCCLine}, arc)
    return TwoTerminalLCCLine(;
        name = "hvdc_no_q",
        available = true,
        arc = arc,
        active_power_flow = 0.0,
        r = 0.01,
        transfer_setpoint = 1.0,
        scheduled_dc_voltage = 500.0,
        rectifier_bridges = 1,
        rectifier_delay_angle_limits = (min = 0.0, max = 1.5),
        rectifier_rc = 0.01,
        rectifier_xc = 0.01,
        rectifier_base_voltage = 500.0,
        inverter_bridges = 1,
        inverter_extinction_angle_limits = (min = 0.0, max = 1.5),
        inverter_rc = 0.01,
        inverter_xc = 0.01,
        inverter_base_voltage = 500.0,
        active_power_limits_from = (min = -2.0, max = 2.0),
        active_power_limits_to = (min = -2.0, max = 2.0),
    )
end

function _build_hvdc_model(
    network_formulation,
    hvdc_formulation,
    optimizer;
    sys_builder = _c_sys5_with_hvdc_tie,
)
    sys, from_no, to_no = sys_builder()
    template = get_thermal_dispatch_template_network(NetworkModel(network_formulation))
    set_device_model!(
        template, DeviceModel(TwoTerminalGenericHVDCLine, hvdc_formulation),
    )
    model = DecisionModel(template, sys; optimizer = optimizer)
    build_status = build!(
        model;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.Error,
    )
    return model, build_status, from_no, to_no
end

@testset "HVDCTwoTerminalUnbounded wired into native nodal balances" begin
    for (network_formulation, optimizer) in (
        (DCPNetworkModel, HiGHS_optimizer),
        (NFANetworkModel, HiGHS_optimizer),
        (DCPLLNetworkModel, ipopt_optimizer),
        (ACPNetworkModel, ipopt_optimizer),
        (ACRNetworkModel, ipopt_optimizer),
        (IVRNetworkModel, ipopt_optimizer),
        (LPACCNetworkModel, ipopt_optimizer),
    )
        model, build_status, from_no, to_no =
            _build_hvdc_model(network_formulation, HVDCTwoTerminalUnbounded, optimizer)
        @test build_status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)

        # The DC tie's flow variable must exist and enter the active-power balances:
        # -1 at the from bus (power leaves), +1 at the to bus.
        pvar =
            IOM.get_variable(container, FlowActivePowerVariable, TwoTerminalGenericHVDCLine)
        @test "hvdc_tie" in axes(pvar)[1]
        t1 = first(IOM.get_time_steps(container))
        balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
        @test JuMP.coefficient(balance[from_no, t1], pvar["hvdc_tie", t1]) == -1.0
        @test JuMP.coefficient(balance[to_no, t1], pvar["hvdc_tie", t1]) == 1.0

        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    end
end

@testset "HVDCTwoTerminalUnbounded reactive wiring under native AC formulations" begin
    for network_formulation in
        (ACPNetworkModel, ACRNetworkModel, IVRNetworkModel, LPACCNetworkModel)
        model, build_status, from_no, to_no = _build_hvdc_model(
            network_formulation, HVDCTwoTerminalUnbounded, ipopt_optimizer,
        )
        @test build_status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        qft = IOM.get_variable(
            container, FlowReactivePowerFromToVariable, TwoTerminalGenericHVDCLine,
        )
        qtf = IOM.get_variable(
            container, FlowReactivePowerToFromVariable, TwoTerminalGenericHVDCLine,
        )
        t1 = first(IOM.get_time_steps(container))
        reactive = IOM.get_expression(container, POM.ReactivePowerBalance, PSY.ACBus)
        @test JuMP.coefficient(reactive[from_no, t1], qft["hvdc_tie", t1]) == -1.0
        @test JuMP.coefficient(reactive[to_no, t1], qtf["hvdc_tie", t1]) == -1.0

        # HVDCTwoTerminalUnbounded means "no flow constraints": its reactive flows stay free,
        # matching its free FlowActivePowerVariable.
        v_qft = qft["hvdc_tie", t1]
        v_qtf = qtf["hvdc_tie", t1]
        @test !JuMP.has_lower_bound(v_qft)
        @test !JuMP.has_upper_bound(v_qft)
        @test !JuMP.has_lower_bound(v_qtf)
        @test !JuMP.has_upper_bound(v_qtf)
    end
end

@testset "HVDCTwoTerminalLossless reactive bounds respect from/to and min/max wiring" begin
    model, build_status, _, _ = _build_hvdc_model(
        ACPNetworkModel,
        HVDCTwoTerminalLossless,
        ipopt_optimizer;
        sys_builder = _c_sys5_with_asymmetric_hvdc_tie,
    )
    @test build_status == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    qft = IOM.get_variable(
        container, FlowReactivePowerFromToVariable, TwoTerminalGenericHVDCLine,
    )
    qtf = IOM.get_variable(
        container, FlowReactivePowerToFromVariable, TwoTerminalGenericHVDCLine,
    )
    t1 = first(IOM.get_time_steps(container))
    v_qft = qft["hvdc_tie", t1]
    v_qtf = qtf["hvdc_tie", t1]
    @test JuMP.lower_bound(v_qft) == -0.4
    @test JuMP.upper_bound(v_qft) == 0.9
    @test JuMP.lower_bound(v_qtf) == -0.7
    @test JuMP.upper_bound(v_qtf) == 0.3
end

@testset "HVDCTwoTerminalLossless reactive power is bounded under native AC formulations" begin
    for network_formulation in
        (ACPNetworkModel, ACRNetworkModel, IVRNetworkModel, LPACCNetworkModel)
        model, build_status, _, _ = _build_hvdc_model(
            network_formulation, HVDCTwoTerminalLossless, ipopt_optimizer,
        )
        @test build_status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        qft = IOM.get_variable(
            container, FlowReactivePowerFromToVariable, TwoTerminalGenericHVDCLine,
        )
        qtf = IOM.get_variable(
            container, FlowReactivePowerToFromVariable, TwoTerminalGenericHVDCLine,
        )
        t1 = first(IOM.get_time_steps(container))
        v_qft = qft["hvdc_tie", t1]
        v_qtf = qtf["hvdc_tie", t1]
        @test JuMP.has_lower_bound(v_qft)
        @test JuMP.has_upper_bound(v_qft)
        @test JuMP.has_lower_bound(v_qtf)
        @test JuMP.has_upper_bound(v_qtf)
        @test JuMP.lower_bound(v_qft) == -1.0
        @test JuMP.upper_bound(v_qft) == 1.0
        @test JuMP.lower_bound(v_qtf) == -1.0
        @test JuMP.upper_bound(v_qtf) == 1.0
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    end
end

# PSY.TwoTerminalVSCLine and PSY.TwoTerminalLCCLine default both reactive limit pairs to
# (min = 0.0, max = 0.0), and HVDCTwoTerminalLossless bounds the reactive flow variables by
# those limits: the terminals are pinned to zero reactive power, which can silently turn a
# previously feasible AC model infeasible. The build must name the device in a warning.
@testset "HVDCTwoTerminalLossless warns on degenerate HVDC reactive limits" begin
    for hvdc_type in (TwoTerminalVSCLine, TwoTerminalLCCLine)
        sys = PSB.build_system(PSITestSystems, "c_sys5")
        line = PSY.get_component(Line, sys, "1")
        arc = PSY.get_arc(line)
        PSY.remove_component!(sys, line)
        hvdc = _no_reactive_hvdc(hvdc_type, arc)
        PSY.add_component!(sys, hvdc)

        template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
        set_device_model!(template, DeviceModel(hvdc_type, HVDCTwoTerminalLossless))
        model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
        output_dir = mktempdir(; cleanup = true)
        @test build!(model; output_dir = output_dir, console_level = Logging.Error) ==
              IOM.ModelBuildStatus.BUILT

        log_contents = read(joinpath(output_dir, "operation_problem.log"), String)
        @test occursin("$hvdc_type \"hvdc_no_q\"", log_contents)
        @test occursin("(min = 0.0, max = 0.0)", log_contents)
        @test occursin("neither inject nor absorb reactive power", log_contents)
        @test occursin("infeasible", log_contents)

        # The zero limits really are the bounds the warning is about.
        container = IOM.get_optimization_container(model)
        qft = IOM.get_variable(container, FlowReactivePowerFromToVariable, hvdc_type)
        t1 = first(IOM.get_time_steps(container))
        @test JuMP.lower_bound(qft["hvdc_no_q", t1]) == 0.0
        @test JuMP.upper_bound(qft["hvdc_no_q", t1]) == 0.0
    end
end

@testset "HVDCTwoTerminalLossless builds and solves under native NFA and DCPLL" begin
    for (network_formulation, optimizer) in
        ((NFANetworkModel, HiGHS_optimizer), (DCPLLNetworkModel, ipopt_optimizer))
        model, build_status, from_no, to_no =
            _build_hvdc_model(network_formulation, HVDCTwoTerminalLossless, optimizer)
        @test build_status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        pvar =
            IOM.get_variable(container, FlowActivePowerVariable, TwoTerminalGenericHVDCLine)
        t1 = first(IOM.get_time_steps(container))
        balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
        @test JuMP.coefficient(balance[from_no, t1], pvar["hvdc_tie", t1]) == -1.0
        @test JuMP.coefficient(balance[to_no, t1], pvar["hvdc_tie", t1]) == 1.0
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    end
end

# Under the AC natives the loss-modeling HVDC formulations are active-power-only
# injectors: the directional active variables enter the nodal ActivePowerBalance and
# nothing enters ReactivePowerBalance. Both formulations carry binary loss-model
# variables and every AC native has nonlinear/quadratic network constraints, so these
# are build-and-wiring checks (an MINLP solver is out of test scope); the DC-native
# testset below covers solves.
@testset "HVDCTwoTerminalDispatch under native AC formulations is active-power-only" begin
    for network_formulation in
        (ACPNetworkModel, ACRNetworkModel, IVRNetworkModel, LPACCNetworkModel)
        model, build_status, from_no, to_no =
            _build_hvdc_model(network_formulation, HVDCTwoTerminalDispatch, ipopt_optimizer)
        @test build_status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        pft = IOM.get_variable(
            container, FlowActivePowerFromToVariable, TwoTerminalGenericHVDCLine,
        )
        ptf = IOM.get_variable(
            container, FlowActivePowerToFromVariable, TwoTerminalGenericHVDCLine,
        )
        t1 = first(IOM.get_time_steps(container))
        balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
        @test JuMP.coefficient(balance[from_no, t1], pft["hvdc_tie", t1]) == -1.0
        @test JuMP.coefficient(balance[to_no, t1], ptf["hvdc_tie", t1]) == -1.0
        reactive = IOM.get_expression(container, POM.ReactivePowerBalance, PSY.ACBus)
        @test JuMP.coefficient(reactive[from_no, t1], pft["hvdc_tie", t1]) == 0.0
        @test JuMP.coefficient(reactive[to_no, t1], ptf["hvdc_tie", t1]) == 0.0
        @test !IOM.has_container_key(
            container, FlowReactivePowerFromToVariable, TwoTerminalGenericHVDCLine,
        )
        @test !IOM.has_container_key(
            container, FlowReactivePowerToFromVariable, TwoTerminalGenericHVDCLine,
        )
    end
end

@testset "HVDCTwoTerminalPiecewiseLoss under native AC formulations is active-power-only" begin
    for network_formulation in
        (ACPNetworkModel, ACRNetworkModel, IVRNetworkModel, LPACCNetworkModel)
        model, build_status, from_no, to_no = _build_hvdc_model(
            network_formulation, HVDCTwoTerminalPiecewiseLoss, ipopt_optimizer,
        )
        @test build_status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        prf = IOM.get_variable(
            container,
            POM.HVDCActivePowerReceivedFromVariable,
            TwoTerminalGenericHVDCLine,
        )
        prt = IOM.get_variable(
            container,
            POM.HVDCActivePowerReceivedToVariable,
            TwoTerminalGenericHVDCLine,
        )
        t1 = first(IOM.get_time_steps(container))
        balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
        @test JuMP.coefficient(balance[from_no, t1], prf["hvdc_tie", t1]) == 1.0
        @test JuMP.coefficient(balance[to_no, t1], prt["hvdc_tie", t1]) == 1.0
        reactive = IOM.get_expression(container, POM.ReactivePowerBalance, PSY.ACBus)
        @test JuMP.coefficient(reactive[from_no, t1], prf["hvdc_tie", t1]) == 0.0
        @test JuMP.coefficient(reactive[to_no, t1], prt["hvdc_tie", t1]) == 0.0
    end
end

# The DC natives share the Dispatch nodal wiring path with the AC natives.
@testset "HVDCTwoTerminalDispatch wired into the DC-native nodal balances" begin
    for (network_formulation, optimizer) in
        ((DCPNetworkModel, HiGHS_optimizer), (NFANetworkModel, HiGHS_optimizer))
        model, build_status, from_no, to_no =
            _build_hvdc_model(network_formulation, HVDCTwoTerminalDispatch, optimizer)
        @test build_status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        pft = IOM.get_variable(
            container, FlowActivePowerFromToVariable, TwoTerminalGenericHVDCLine,
        )
        ptf = IOM.get_variable(
            container, FlowActivePowerToFromVariable, TwoTerminalGenericHVDCLine,
        )
        t1 = first(IOM.get_time_steps(container))
        balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
        @test JuMP.coefficient(balance[from_no, t1], pft["hvdc_tie", t1]) == -1.0
        @test JuMP.coefficient(balance[to_no, t1], ptf["hvdc_tie", t1]) == -1.0
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    end
end

# DCPLL's PWL loss segments plus quadratic branch losses make the combined problem an
# MINLP, out of test scope: build+wiring only there, solve under DCP/NFA (both MILP).
@testset "HVDCTwoTerminalPiecewiseLoss wired into the DC-native nodal balances" begin
    for (network_formulation, optimizer, run_solve) in (
        (DCPNetworkModel, HiGHS_optimizer, true),
        (NFANetworkModel, HiGHS_optimizer, true),
        (DCPLLNetworkModel, ipopt_optimizer, false),
    )
        model, build_status, from_no, to_no = _build_hvdc_model(
            network_formulation, HVDCTwoTerminalPiecewiseLoss, optimizer,
        )
        @test build_status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        prf = IOM.get_variable(
            container,
            POM.HVDCActivePowerReceivedFromVariable,
            TwoTerminalGenericHVDCLine,
        )
        prt = IOM.get_variable(
            container,
            POM.HVDCActivePowerReceivedToVariable,
            TwoTerminalGenericHVDCLine,
        )
        t1 = first(IOM.get_time_steps(container))
        balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
        @test JuMP.coefficient(balance[from_no, t1], prf["hvdc_tie", t1]) == 1.0
        @test JuMP.coefficient(balance[to_no, t1], prt["hvdc_tie", t1]) == 1.0
        if run_solve
            @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        end
    end
end

@testset "HVDCTwoTerminalUnbounded builds under CopperPlateNetworkModel" begin
    model, build_status, _, _ =
        _build_hvdc_model(
            CopperPlateNetworkModel,
            HVDCTwoTerminalUnbounded,
            HiGHS_optimizer,
        )
    @test build_status == IOM.ModelBuildStatus.BUILT
end

# Same tie as _c_sys5_with_hvdc_tie but with a real loss model, so the loss-modeling
# formulations have nonzero coefficients to pin down.
function _c_sys5_with_lossy_hvdc_tie()
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(Line, sys, "1")
    arc = PSY.get_arc(line)
    PSY.remove_component!(sys, line)
    hvdc = TwoTerminalGenericHVDCLine(;
        name = "hvdc_tie",
        available = true,
        active_power_flow = 0.0,
        active_power_limits_from = (min = -2.0, max = 2.0),
        active_power_limits_to = (min = -2.0, max = 2.0),
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        arc = arc,
        loss = LinearCurve(0.05, 0.01),
    )
    PSY.add_component!(sys, hvdc)
    from_no = PSY.get_number(PSY.get_from(arc))
    to_no = PSY.get_number(PSY.get_to(arc))
    return sys, from_no, to_no
end

# Hand-derived sparse PWL breakpoint parameters for loss = LinearCurve(0.05, 0.01)
# with symmetric +/-2.0 limits: P_max = 2.0, l1 = 0.05, l0 = 0.01.
# ft: [-P_max - l0, -l0, 0.0, P_max * (1 - l1)]; tf is the reverse-direction mirror.
const _HVDC_PWL_FT_PARAMS = [-2.01, -0.01, 0.0, 1.9]
const _HVDC_PWL_TF_PARAMS = [1.9, 0.0, -0.01, -2.01]

# The HVDCFlowCalculationConstraint containers ("ft"/"tf"/"bin") must exist, be
# populated, and carry the hand-derived PWL coefficients. Dropping this constraint is a
# pure relaxation (the model still builds and solves), so container existence alone is
# not enough: pin the coefficients.
function _assert_hvdc_flow_calculation_constraints(container)
    t1 = first(IOM.get_time_steps(container))
    prf = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedFromVariable, TwoTerminalGenericHVDCLine,
    )
    prt = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedToVariable, TwoTerminalGenericHVDCLine,
    )
    pwl = IOM.get_variable(
        container, POM.HVDCPiecewiseLossVariable, TwoTerminalGenericHVDCLine,
    )
    bin = IOM.get_variable(
        container, POM.HVDCPiecewiseBinaryLossVariable, TwoTerminalGenericHVDCLine,
    )
    for (meta, received, params) in (
        ("ft", prf, _HVDC_PWL_FT_PARAMS),
        ("tf", prt, _HVDC_PWL_TF_PARAMS),
    )
        con = IOM.get_constraint(
            container, POM.HVDCFlowCalculationConstraint, TwoTerminalGenericHVDCLine,
            meta,
        )
        @test !isempty(con)
        c = con["hvdc_tie", t1]
        @test JuMP.normalized_coefficient(c, received["hvdc_tie", t1]) == 1.0
        for ix in 1:3
            @test JuMP.normalized_coefficient(c, bin["hvdc_tie", ix, t1]) ≈ -params[ix]
            @test JuMP.normalized_coefficient(c, pwl["hvdc_tie", ix, t1]) ≈
                  -(params[ix + 1] - params[ix])
        end
    end
    bin_con = IOM.get_constraint(
        container, POM.HVDCFlowCalculationConstraint, TwoTerminalGenericHVDCLine, "bin",
    )
    @test !isempty(bin_con)
    bc = bin_con["hvdc_tie", t1]
    for ix in 1:3
        @test JuMP.normalized_coefficient(bc, bin["hvdc_tie", ix, t1]) == 1.0
    end
    @test JuMP.normalized_rhs(bc) == 1.0
    @test JuMP.is_fixed(pwl["hvdc_tie", 2, t1])
    return
end

# Net received power prf + prt equals -(loss); any feasible PWL point burns between the
# constant loss (l0 = 0.01) and the max-transfer loss (l0 + l1 * P_max = 0.11).
function _hvdc_net_received(container)
    t1 = first(IOM.get_time_steps(container))
    prf = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedFromVariable, TwoTerminalGenericHVDCLine,
    )
    prt = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedToVariable, TwoTerminalGenericHVDCLine,
    )
    return JuMP.value(prf["hvdc_tie", t1]) + JuMP.value(prt["hvdc_tie", t1])
end

@testset "HVDCFlowCalculationConstraint ties received HVDC flows to the PWL loss segments" begin
    for network_formulation in (PTDFNetworkModel, DCPNetworkModel, NFANetworkModel)
        model, build_status, _, _ = _build_hvdc_model(
            network_formulation,
            HVDCTwoTerminalPiecewiseLoss,
            HiGHS_optimizer;
            sys_builder = _c_sys5_with_lossy_hvdc_tie,
        )
        @test build_status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        _assert_hvdc_flow_calculation_constraints(container)
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        net = _hvdc_net_received(container)
        @test -0.11 - 1e-6 <= net <= -0.01 + 1e-6
    end
end

@testset "HVDCTwoTerminalPiecewiseLoss builds, wires losses, and solves under CopperPlateNetworkModel" begin
    model, build_status, from_no, to_no = _build_hvdc_model(
        CopperPlateNetworkModel,
        HVDCTwoTerminalPiecewiseLoss,
        HiGHS_optimizer;
        sys_builder = _c_sys5_with_lossy_hvdc_tie,
    )
    @test build_status == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    network_model = IOM.get_network_model(IOM.get_template(model))
    sys = IOM.get_system(model)
    bus_from = first(
        PSY.get_components(b -> PSY.get_number(b) == from_no, PSY.ACBus, sys),
    )
    bus_to = first(PSY.get_components(b -> PSY.get_number(b) == to_no, PSY.ACBus, sys))
    ref = POM.get_reference_bus(network_model, bus_from)
    @test POM.get_reference_bus(network_model, bus_to) == ref

    # Both terminals sit in the single system balance, so each received variable enters
    # the same row with +1.0 and the line's net contribution is -(losses).
    t1 = first(IOM.get_time_steps(container))
    prf = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedFromVariable, TwoTerminalGenericHVDCLine,
    )
    prt = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedToVariable, TwoTerminalGenericHVDCLine,
    )
    sys_balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.System)
    @test JuMP.coefficient(sys_balance[ref, t1], prf["hvdc_tie", t1]) == 1.0
    @test JuMP.coefficient(sys_balance[ref, t1], prt["hvdc_tie", t1]) == 1.0

    _assert_hvdc_flow_calculation_constraints(container)

    # Transfers relieve nothing inside one copper plate, so the optimum idles the line
    # at the zero-transfer breakpoint and burns exactly the constant loss.
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test isapprox(_hvdc_net_received(container), -0.01; atol = 1e-6)
end

function _two_area_sys_with_lossy_hvdc_tie()
    sys = PSB.build_system(PSB.PSISystems, "two_area_pjm_DA")
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
    hvdc = TwoTerminalGenericHVDCLine(;
        name = "hvdc_tie",
        available = true,
        active_power_flow = 0.0,
        active_power_limits_from = (min = -2.0, max = 2.0),
        active_power_limits_to = (min = -2.0, max = 2.0),
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        arc = arc,
        loss = LinearCurve(0.05, 0.01),
    )
    PSY.add_component!(sys, hvdc)
    return sys
end

@testset "HVDCTwoTerminalPiecewiseLoss is a genuine inter-area interchange under AreaBalanceNetworkModel" begin
    sys = _two_area_sys_with_lossy_hvdc_tie()
    template = get_thermal_dispatch_template_network(NetworkModel(AreaBalanceNetworkModel))
    set_device_model!(
        template, DeviceModel(TwoTerminalGenericHVDCLine, HVDCTwoTerminalPiecewiseLoss),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(
        model;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.Error,
    ) == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)

    # Each received terminal enters its own area's balance with +1.0 and must not leak
    # into the other area's row.
    t1 = first(IOM.get_time_steps(container))
    prf = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedFromVariable, TwoTerminalGenericHVDCLine,
    )
    prt = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedToVariable, TwoTerminalGenericHVDCLine,
    )
    area_balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.Area)
    @test JuMP.coefficient(area_balance["Area1", t1], prf["hvdc_tie", t1]) == 1.0
    @test JuMP.coefficient(area_balance["Area2", t1], prt["hvdc_tie", t1]) == 1.0
    @test JuMP.coefficient(area_balance["Area1", t1], prt["hvdc_tie", t1]) == 0.0
    @test JuMP.coefficient(area_balance["Area2", t1], prf["hvdc_tie", t1]) == 0.0

    _assert_hvdc_flow_calculation_constraints(container)

    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    net = _hvdc_net_received(container)
    @test -0.11 - 1e-6 <= net <= -0.01 + 1e-6
end

# HVDCTwoTerminalDispatch on the nodal networks carries losses through the
# HVDCPowerBalance coupling (ft + tf == losses) with both directional flows entering
# their own terminal balances. The HVDCLosses variable itself must NOT enter the nodal
# balance: that direct route exists only on the aggregated CopperPlate/PTDF/Area
# balances, where the terminal flows cannot carry the loss.
@testset "HVDCTwoTerminalDispatch losses enter the nodal balances through the flow coupling" begin
    for (network_formulation, optimizer, run_solve) in (
        (DCPNetworkModel, HiGHS_optimizer, true),
        (ACPNetworkModel, ipopt_optimizer, false),
    )
        model, build_status, from_no, to_no = _build_hvdc_model(
            network_formulation,
            HVDCTwoTerminalDispatch,
            optimizer;
            sys_builder = _c_sys5_with_lossy_hvdc_tie,
        )
        @test build_status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        t1 = first(IOM.get_time_steps(container))
        pft = IOM.get_variable(
            container, FlowActivePowerFromToVariable, TwoTerminalGenericHVDCLine,
        )
        ptf = IOM.get_variable(
            container, FlowActivePowerToFromVariable, TwoTerminalGenericHVDCLine,
        )
        losses = IOM.get_variable(container, POM.HVDCLosses, TwoTerminalGenericHVDCLine)
        balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
        @test JuMP.coefficient(balance[from_no, t1], pft["hvdc_tie", t1]) == -1.0
        @test JuMP.coefficient(balance[to_no, t1], ptf["hvdc_tie", t1]) == -1.0
        @test JuMP.coefficient(balance[from_no, t1], losses["hvdc_tie", t1]) == 0.0
        @test JuMP.coefficient(balance[to_no, t1], losses["hvdc_tie", t1]) == 0.0

        loss_con = IOM.get_constraint(
            container, POM.HVDCPowerBalance, TwoTerminalGenericHVDCLine, "loss",
        )
        @test !isempty(loss_con)
        c = loss_con["hvdc_tie", t1]
        @test JuMP.normalized_coefficient(c, pft["hvdc_tie", t1]) == 1.0
        @test JuMP.normalized_coefficient(c, ptf["hvdc_tie", t1]) == 1.0
        @test JuMP.normalized_coefficient(c, losses["hvdc_tie", t1]) == -1.0
        @test JuMP.normalized_rhs(c) == 0.0
        for meta in ("loss_aux1", "loss_aux2", "loss_aux3", "loss_aux4")
            @test IOM.has_container_key(
                container, POM.HVDCPowerBalance, TwoTerminalGenericHVDCLine, meta,
            )
        end

        if run_solve
            @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
            vft = JuMP.value(pft["hvdc_tie", t1])
            vtf = JuMP.value(ptf["hvdc_tie", t1])
            vloss = JuMP.value(losses["hvdc_tie", t1])
            @test isapprox(vft + vtf, vloss; atol = 1e-8)
            @test isapprox(vloss, 0.01 + 0.05 * max(vft, vtf); atol = 1e-6)
        end
    end
end
