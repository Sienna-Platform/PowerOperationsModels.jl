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

function _build_hvdc_model(network_formulation, hvdc_formulation, optimizer)
    sys, from_no, to_no = _c_sys5_with_hvdc_tie()
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
