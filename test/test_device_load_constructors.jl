test_path = mktempdir()

@testset "MotorLoad AreaBalanceNetworkModel" begin
    c_sys = PSB.build_system(PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(c_sys, Hour(24), Hour(1))
    template = get_thermal_dispatch_template_network(NetworkModel(AreaBalanceNetworkModel))
    set_device_model!(template, AreaInterchange, StaticBranch)
    ps_model =
        DecisionModel(template, c_sys; resolution = Hour(1), optimizer = HiGHS_optimizer)

    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "AreaBalance subnetwork topology check fires only above one subnetwork" begin
    c_sys = PSB.build_system(PSISystems, "two_area_pjm_DA")
    area_map = PSY.get_aggregation_topology_mapping(PSY.Area, c_sys)
    buses = [
        PSY.get_number(b) for b in first(values(area_map)) if
        PSY.get_bustype(b) != PSY.ACBusTypes.ISOLATED
    ]
    @test length(buses) > 1

    # A single subnetwork is the normal case for AreaBalance and must not warn: the
    # network model now always populates at least one, where it used to be empty.
    single = Dict(first(buses) => Set(buses))
    @test_logs min_level = Logging.Warn POM._verify_area_subnetwork_topology(
        c_sys,
        single,
    )

    # Two subnetworks with one Area straddling both is the condition the check exists
    # to reject, and it still throws.
    split_at = length(buses) ÷ 2
    straddling = Dict(
        buses[1] => Set(buses[1:split_at]),
        buses[split_at + 1] => Set(buses[(split_at + 1):end]),
    )
    @test_throws IS.ConflictingInputsError POM._verify_area_subnetwork_topology(
        c_sys,
        straddling,
    )
end

@testset "AreaInterchange with a network model that reduces branches" begin
    # AreaInterchange <: PSY.Branch but connects Areas, not buses; it has no
    # arc. Building this with a network model that actually performs radial and
    # degree-two reduction exercises the bus-protection loops in
    # instantiate_network_model.jl that call _push_component_buses!.
    c_sys = PSB.build_system(PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(c_sys, Hour(24), Hour(1))
    network = NetworkModel(
        DCPNetworkModel;
        network_source = SystemNetworkSource(
            PNM.RadialReduction(),
            PNM.DegreeTwoReduction(),
        ),
    )
    template = get_thermal_dispatch_template_network(network)
    set_device_model!(template, AreaInterchange, StaticBranch)
    ps_model =
        DecisionModel(template, c_sys; resolution = Hour(1), optimizer = HiGHS_optimizer)

    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
end

function _two_area_ac_interchange_system(; include_reverse_tie = true)
    sys = PSB.build_system(PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(sys, Hour(24), Hour(1))
    # Retire mid-cost capacity in Area2 so the optimum imports over the ties and the
    # inter-area lines carry enough flow for their losses to be visible.
    set_available!(get_component(ThermalStandard, sys, "Solitude_2"), false)
    if include_reverse_tie
        # A second tie oriented Area2 -> Area1 exercises the reversed map key: its
        # from-area boundary is the branch's to terminal.
        bus_d2 = get_component(ACBus, sys, "Bus_nodeD_2")
        bus_d1 = get_component(ACBus, sys, "Bus_nodeD_1")
        arc = Arc(; from = bus_d2, to = bus_d1)
        add_component!(sys, arc)
        line = Line(;
            name = "reverse_tie",
            available = true,
            active_power_flow = 0.0,
            reactive_power_flow = 0.0,
            arc = arc,
            r = 0.003,
            x = 0.03,
            b = (from = 0.0, to = 0.0),
            rating = 10.0,
            angle_limits = (min = -1.57, max = 1.57),
            input_basis = u"CU",
        )
        add_component!(sys, line)
    end
    return sys
end

function _add_inter_area_hvdc_tie!(sys)
    bus_from = get_component(ACBus, sys, "Bus_nodeC_1")
    bus_to = get_component(ACBus, sys, "Bus_nodeC_2")
    arc = first(
        PSY.get_components(
            x -> PSY.get_from(x) == bus_from && PSY.get_to(x) == bus_to, Arc, sys,
        ),
    )
    hvdc = TwoTerminalGenericHVDCLine(;
        name = "hvdc_tie",
        available = true,
        active_power_flow = 0.0,
        rating = 2.0,
        rating_from = 2.0,
        rating_to = 2.0,
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        arc = arc,
        loss = PSY.LossCurve(LinearCurve(0.05, 0.01), PSY.CU),
        input_basis = u"CU",
    )
    add_component!(sys, hvdc)
    return
end

@testset "AreaInterchange StaticBranch measures the from-area boundary flow on AC networks" begin
    for (net, run_solve) in (
        (ACPNetworkModel, true),
        (ACRNetworkModel, false),
        (IVRNetworkModel, false),
        (LPACCNetworkModel, false),
    )
        sys = _two_area_ac_interchange_system()
        template = get_thermal_dispatch_template_network(NetworkModel(net))
        set_device_model!(template, AreaInterchange, StaticBranch)
        model = DecisionModel(
            template,
            sys;
            optimizer = ipopt_optimizer,
            store_variable_names = true,
        )
        @test build!(
            model;
            output_dir = mktempdir(; cleanup = true),
            console_level = Logging.Error,
        ) == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        t1 = first(IOM.get_time_steps(container))
        ex = IOM.get_variable(container, FlowActivePowerVariable, AreaInterchange)
        pft_ml = IOM.get_variable(container, FlowActivePowerFromToVariable, Line)
        ptf_ml = IOM.get_variable(container, FlowActivePowerToFromVariable, Line)
        pft_l = IOM.get_variable(container, FlowActivePowerFromToVariable, Line)
        ptf_l = IOM.get_variable(container, FlowActivePowerToFromVariable, Line)
        con_ub =
            IOM.get_constraint(
                container,
                POM.LineFlowBoundConstraint,
                AreaInterchange,
                "ub",
            )
        con_lb =
            IOM.get_constraint(
                container,
                POM.LineFlowBoundConstraint,
                AreaInterchange,
                "lb",
            )
        for con in (con_ub["1_2", t1], con_lb["1_2", t1])
            # inter_area_line is oriented Area1 -> Area2: metered at its from terminal
            @test JuMP.normalized_coefficient(con, pft_ml["inter_area_line", t1]) == 1.0
            @test JuMP.normalized_coefficient(con, ptf_ml["inter_area_line", t1]) == 0.0
            # reverse_tie is oriented Area2 -> Area1: metered at its to terminal
            @test JuMP.normalized_coefficient(con, ptf_l["reverse_tie", t1]) == 1.0
            @test JuMP.normalized_coefficient(con, pft_l["reverse_tie", t1]) == 0.0
            @test JuMP.normalized_coefficient(con, ex["1_2", t1]) == -1.0
        end
        if run_solve
            @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
            time_steps = IOM.get_time_steps(container)
            t_star = argmax([abs(JuMP.value(ex["1_2", t])) for t in time_steps])
            @test abs(JuMP.value(ex["1_2", t_star])) > 0.1
            ft_ia = JuMP.value(pft_ml["inter_area_line", t_star])
            tf_ia = JuMP.value(ptf_ml["inter_area_line", t_star])
            ft_rev = JuMP.value(pft_l["reverse_tie", t_star])
            tf_rev = JuMP.value(ptf_l["reverse_tie", t_star])
            # AC ties are lossy: the two directional flows are not mirror images
            loss_ia = ft_ia + tf_ia
            loss_rev = ft_rev + tf_rev
            @test loss_ia > 1e-6
            @test loss_rev > 1e-6
            measured_export = ft_ia + tf_rev
            far_end_arrival = -(tf_ia + ft_rev)
            # The exchange variable reads the sending-side (lossy) measurement, so it
            # equals the from-area export and is strictly greater than what arrives at
            # the far end — by the tie-line losses. Both are independent solved values.
            @test isapprox(JuMP.value(ex["1_2", t_star]), measured_export; atol = 1e-6)
            @test !isapprox(JuMP.value(ex["1_2", t_star]), far_end_arrival; atol = 1e-4)
            @test JuMP.value(ex["1_2", t_star]) - far_end_arrival > 1e-6
        end
    end
end

@testset "AreaInterchange StaticBranch includes HVDC tie lines on AC networks" begin
    # Directional-flow HVDC formulation: the tie is metered like the AC lines, at the
    # terminal on the interchange's from-area side. Binaries preclude an Ipopt solve,
    # so assert at the coefficient level.
    sys = _two_area_ac_interchange_system(; include_reverse_tie = false)
    _add_inter_area_hvdc_tie!(sys)
    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    set_device_model!(template, AreaInterchange, StaticBranch)
    set_device_model!(template, TwoTerminalGenericHVDCLine, HVDCTwoTerminalDispatch)
    model = DecisionModel(
        template,
        sys;
        optimizer = ipopt_optimizer,
        store_variable_names = true,
    )
    @test build!(
        model;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.Error,
    ) == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    t1 = first(IOM.get_time_steps(container))
    pft_dc = IOM.get_variable(
        container, FlowActivePowerFromToVariable, TwoTerminalGenericHVDCLine,
    )
    ptf_dc = IOM.get_variable(
        container, FlowActivePowerToFromVariable, TwoTerminalGenericHVDCLine,
    )
    con_ub =
        IOM.get_constraint(container, POM.LineFlowBoundConstraint, AreaInterchange, "ub")
    c = con_ub["1_2", t1]
    @test JuMP.normalized_coefficient(c, pft_dc["hvdc_tie", t1]) == 1.0
    @test JuMP.normalized_coefficient(c, ptf_dc["hvdc_tie", t1]) == 0.0

    # Single-signed-flow HVDC formulation (lossless): the flow variable is positive
    # from -> to, so it enters with the interchange direction multiplier.
    sys_ll = _two_area_ac_interchange_system(; include_reverse_tie = false)
    _add_inter_area_hvdc_tie!(sys_ll)
    template_ll = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    set_device_model!(template_ll, AreaInterchange, StaticBranch)
    model_ll = DecisionModel(
        template_ll,
        sys_ll;
        optimizer = ipopt_optimizer,
        store_variable_names = true,
    )
    @test build!(
        model_ll;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.Error,
    ) == IOM.ModelBuildStatus.BUILT
    container_ll = IOM.get_optimization_container(model_ll)
    flow_dc = IOM.get_variable(
        container_ll, FlowActivePowerVariable, TwoTerminalGenericHVDCLine,
    )
    ex_ll = IOM.get_variable(container_ll, FlowActivePowerVariable, AreaInterchange)
    pft_ml_ll =
        IOM.get_variable(container_ll, FlowActivePowerFromToVariable, Line)
    con_ub_ll = IOM.get_constraint(
        container_ll, POM.LineFlowBoundConstraint, AreaInterchange, "ub",
    )
    c_ll = con_ub_ll["1_2", t1]
    @test JuMP.normalized_coefficient(c_ll, flow_dc["hvdc_tie", t1]) == 1.0
    @test JuMP.normalized_coefficient(c_ll, ex_ll["1_2", t1]) == -1.0
    @test solve!(model_ll) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    time_steps_ll = IOM.get_time_steps(container_ll)
    t_star = argmax([abs(JuMP.value(ex_ll["1_2", t])) for t in time_steps_ll])
    @test abs(JuMP.value(ex_ll["1_2", t_star])) > 0.1
    @test isapprox(
        JuMP.value(ex_ll["1_2", t_star]),
        JuMP.value(pft_ml_ll["inter_area_line", t_star]) +
        JuMP.value(flow_dc["hvdc_tie", t_star]);
        atol = 1e-6,
    )
end

@testset "AreaInterchange StaticBranch includes a PWL-loss HVDC tie on AC networks" begin
    # Piecewise-loss formulation: each terminal is its own injection variable
    # (`HVDCActivePowerReceived{From,To}Variable`), both metered with coefficient -1.0
    # (injection convention). hvdc_tie sits on the same Bus_nodeC_1 -> Bus_nodeC_2 arc as
    # the directional-flow testset above, which established that arc matches the
    # interchange's own (Area1 -> Area2) orientation, so metering picks the from-terminal
    # received variable.
    sys = _two_area_ac_interchange_system(; include_reverse_tie = false)
    _add_inter_area_hvdc_tie!(sys)
    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    set_device_model!(template, AreaInterchange, StaticBranch)
    set_device_model!(template, TwoTerminalGenericHVDCLine, HVDCTwoTerminalPiecewiseLoss)
    model = DecisionModel(
        template,
        sys;
        optimizer = ipopt_optimizer,
        store_variable_names = true,
    )
    @test build!(
        model;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.Error,
    ) == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    t1 = first(IOM.get_time_steps(container))
    received_from = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedFromVariable, TwoTerminalGenericHVDCLine,
    )
    con_ub =
        IOM.get_constraint(container, POM.LineFlowBoundConstraint, AreaInterchange, "ub")
    c = con_ub["1_2", t1]
    @test JuMP.normalized_coefficient(c, received_from["hvdc_tie", t1]) == -1.0
end

function _add_intra_area_hvdc_line!(sys)
    bus_from = get_component(ACBus, sys, "Bus_nodeA_1")
    bus_to = get_component(ACBus, sys, "Bus_nodeB_1")
    arc = first(
        PSY.get_components(
            x -> PSY.get_from(x) == bus_from && PSY.get_to(x) == bus_to, Arc, sys,
        ),
    )
    hvdc = TwoTerminalGenericHVDCLine(;
        name = "hvdc_intra",
        available = true,
        active_power_flow = 0.0,
        rating = 2.0,
        rating_from = 2.0,
        rating_to = 2.0,
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        arc = arc,
        loss = PSY.LossCurve(LinearCurve(0.05, 0.01), PSY.CU),
        input_basis = u"CU",
    )
    add_component!(sys, hvdc)
    return
end

@testset "AreaInterchange StaticBranch includes HVDC tie lines on PTDF networks" begin
    # On PTDF every HVDC flow variable already appears in the interchange constraint
    # indirectly, through the AC tie's PTDFBranchFlow expression (its nodal injections
    # times the tie's PTDF row). The interchange metering must add exactly +1.0 on top
    # of that network response for the inter-area tie's measured variable — matching
    # the AC-network convention — and add nothing for any other HVDC variable.
    _direct_metering(con, expr, v) =
        JuMP.normalized_coefficient(con, v) - JuMP.coefficient(expr, v)

    # Directional-flow HVDC formulation: the tie is metered at the terminal on the
    # interchange's from-area side, matching the AC-network path.
    sys = _two_area_ac_interchange_system(; include_reverse_tie = false)
    _add_inter_area_hvdc_tie!(sys)
    _add_intra_area_hvdc_line!(sys)
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, AreaInterchange, StaticBranch)
    set_device_model!(template, TwoTerminalGenericHVDCLine, HVDCTwoTerminalDispatch)
    model = DecisionModel(
        template,
        sys;
        optimizer = HiGHS_optimizer,
        store_variable_names = true,
    )
    @test build!(
        model;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.Error,
    ) == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    t1 = first(IOM.get_time_steps(container))
    ex = IOM.get_variable(container, FlowActivePowerVariable, AreaInterchange)
    pft_dc = IOM.get_variable(
        container, FlowActivePowerFromToVariable, TwoTerminalGenericHVDCLine,
    )
    ptf_dc = IOM.get_variable(
        container, FlowActivePowerToFromVariable, TwoTerminalGenericHVDCLine,
    )
    ptdf_ml = IOM.get_expression(container, POM.PTDFBranchFlow, Line)
    ac_tie = ptdf_ml["inter_area_line", t1]
    con_ub =
        IOM.get_constraint(container, POM.LineFlowBoundConstraint, AreaInterchange, "ub")
    con_lb =
        IOM.get_constraint(container, POM.LineFlowBoundConstraint, AreaInterchange, "lb")
    for con in (con_ub["1_2", t1], con_lb["1_2", t1])
        # hvdc_tie is oriented Area1 -> Area2: same +1.0 from-terminal metering the AC
        # networks give it
        @test isapprox(
            _direct_metering(con, ac_tie, pft_dc["hvdc_tie", t1]), 1.0; atol = 1e-9,
        )
        @test isapprox(
            _direct_metering(con, ac_tie, ptf_dc["hvdc_tie", t1]), 0.0; atol = 1e-9,
        )
        # hvdc_intra stays inside Area1 and must not be metered
        @test isapprox(
            _direct_metering(con, ac_tie, pft_dc["hvdc_intra", t1]), 0.0; atol = 1e-9,
        )
        @test isapprox(
            _direct_metering(con, ac_tie, ptf_dc["hvdc_intra", t1]), 0.0; atol = 1e-9,
        )
        @test JuMP.normalized_coefficient(con, ex["1_2", t1]) == -1.0
    end

    # Single-signed-flow HVDC formulation (lossless): the flow variable is positive
    # from -> to, so it enters with the interchange direction multiplier.
    sys_ll = _two_area_ac_interchange_system(; include_reverse_tie = false)
    _add_inter_area_hvdc_tie!(sys_ll)
    _add_intra_area_hvdc_line!(sys_ll)
    template_ll = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template_ll, AreaInterchange, StaticBranch)
    model_ll = DecisionModel(
        template_ll,
        sys_ll;
        optimizer = HiGHS_optimizer,
        store_variable_names = true,
    )
    @test build!(
        model_ll;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.Error,
    ) == IOM.ModelBuildStatus.BUILT
    container_ll = IOM.get_optimization_container(model_ll)
    t1_ll = first(IOM.get_time_steps(container_ll))
    flow_dc = IOM.get_variable(
        container_ll, FlowActivePowerVariable, TwoTerminalGenericHVDCLine,
    )
    ex_ll = IOM.get_variable(container_ll, FlowActivePowerVariable, AreaInterchange)
    ptdf_flow_ml = IOM.get_expression(container_ll, POM.PTDFBranchFlow, Line)
    ac_tie_ll = ptdf_flow_ml["inter_area_line", t1_ll]
    con_ub_ll = IOM.get_constraint(
        container_ll, POM.LineFlowBoundConstraint, AreaInterchange, "ub",
    )
    c_ll = con_ub_ll["1_2", t1_ll]
    @test isapprox(
        _direct_metering(c_ll, ac_tie_ll, flow_dc["hvdc_tie", t1_ll]), 1.0; atol = 1e-9,
    )
    @test isapprox(
        _direct_metering(c_ll, ac_tie_ll, flow_dc["hvdc_intra", t1_ll]), 0.0;
        atol = 1e-9,
    )
    @test JuMP.normalized_coefficient(c_ll, ex_ll["1_2", t1_ll]) == -1.0
    @test solve!(model_ll) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    time_steps_ll = IOM.get_time_steps(container_ll)
    t_star = argmax([abs(JuMP.value(ex_ll["1_2", t])) for t in time_steps_ll])
    @test abs(JuMP.value(ex_ll["1_2", t_star])) > 0.1
    # The interchange variable is bound by the AC tie's PTDF flow plus the HVDC tie flow
    @test isapprox(
        JuMP.value(ex_ll["1_2", t_star]),
        JuMP.value(ptdf_flow_ml["inter_area_line", t_star]) +
        JuMP.value(flow_dc["hvdc_tie", t_star]);
        atol = 1e-6,
    )

    # AreaPTDF exercises the StaticBranchUnbounded interchange stage
    sys_ap = _two_area_ac_interchange_system(; include_reverse_tie = false)
    _add_inter_area_hvdc_tie!(sys_ap)
    _add_intra_area_hvdc_line!(sys_ap)
    template_ap =
        get_thermal_dispatch_template_network(NetworkModel(AreaPTDFNetworkModel))
    set_device_model!(template_ap, AreaInterchange, StaticBranchUnbounded)
    model_ap = DecisionModel(
        template_ap,
        sys_ap;
        optimizer = HiGHS_optimizer,
        store_variable_names = true,
    )
    @test build!(
        model_ap;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.Error,
    ) == IOM.ModelBuildStatus.BUILT
    container_ap = IOM.get_optimization_container(model_ap)
    t1_ap = first(IOM.get_time_steps(container_ap))
    flow_dc_ap = IOM.get_variable(
        container_ap, FlowActivePowerVariable, TwoTerminalGenericHVDCLine,
    )
    ex_ap = IOM.get_variable(container_ap, FlowActivePowerVariable, AreaInterchange)
    ptdf_ml_ap = IOM.get_expression(container_ap, POM.PTDFBranchFlow, Line)
    ac_tie_ap = ptdf_ml_ap["inter_area_line", t1_ap]
    con_ub_ap = IOM.get_constraint(
        container_ap, POM.LineFlowBoundConstraint, AreaInterchange, "ub",
    )
    c_ap = con_ub_ap["1_2", t1_ap]
    @test isapprox(
        _direct_metering(c_ap, ac_tie_ap, flow_dc_ap["hvdc_tie", t1_ap]), 1.0;
        atol = 1e-9,
    )
    @test isapprox(
        _direct_metering(c_ap, ac_tie_ap, flow_dc_ap["hvdc_intra", t1_ap]), 0.0;
        atol = 1e-9,
    )
    @test JuMP.normalized_coefficient(c_ap, ex_ap["1_2", t1_ap]) == -1.0
end

@testset "AreaInterchange StaticBranchUnbounded includes a PWL-loss HVDC tie on AreaPTDF networks" begin
    # Piecewise-loss formulation: each terminal is its own injection variable
    # (`HVDCActivePowerReceived{From,To}Variable`), metered like every other HVDC
    # family on the PTDF path - directly, on top of whatever coefficient the tie's
    # nodal injection already contributes to the monitored AC tie's own PTDFBranchFlow
    # expression. hvdc_tie sits on the same Bus_nodeC_1 -> Bus_nodeC_2 arc as the
    # directional-flow, lossless, and AreaPTDF testsets above, all keyed with the
    # interchange's own (Area1 -> Area2) orientation, so metering picks the
    # from-terminal received variable at coefficient -1.0 (injection convention).
    _direct_metering(con, expr, v) =
        JuMP.normalized_coefficient(con, v) - JuMP.coefficient(expr, v)

    sys = _two_area_ac_interchange_system(; include_reverse_tie = false)
    _add_inter_area_hvdc_tie!(sys)
    template = get_thermal_dispatch_template_network(NetworkModel(AreaPTDFNetworkModel))
    set_device_model!(template, AreaInterchange, StaticBranchUnbounded)
    set_device_model!(template, TwoTerminalGenericHVDCLine, HVDCTwoTerminalPiecewiseLoss)
    model = DecisionModel(
        template,
        sys;
        optimizer = HiGHS_optimizer,
        store_variable_names = true,
    )
    @test build!(
        model;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.Error,
    ) == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    received_from = IOM.get_variable(
        container, POM.HVDCActivePowerReceivedFromVariable, TwoTerminalGenericHVDCLine,
    )
    ptdf_ml = IOM.get_expression(container, POM.PTDFBranchFlow, Line)
    con_ub =
        IOM.get_constraint(container, POM.LineFlowBoundConstraint, AreaInterchange, "ub")
    for t in IOM.get_time_steps(container)
        ac_tie = ptdf_ml["inter_area_line", t]
        c = con_ub["1_2", t]
        @test isapprox(
            _direct_metering(c, ac_tie, received_from["hvdc_tie", t]), -1.0; atol = 1e-9,
        )
    end
end

@testset "StaticPowerLoad" begin
    models = [StaticPowerLoad, PowerLoadDispatch, PowerLoadInterruption]
    c_sys5_il = PSB.build_system(PSITestSystems, "c_sys5_il")
    networks = [DCPNetworkModel, ACPNetworkModel]
    for m in models, n in networks
        device_model = DeviceModel(PowerLoad, m)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        mock_construct_device!(model, device_model)
        moi_tests(model, 0, 0, 0, 0, 0, false)
        psi_checkobjfun_test(model, GAEVF)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        mock_construct_device!(model, device_model; add_event_model = true)
        moi_tests(model, 0, 0, 0, 0, 0, false)
    end
end

@testset "PowerLoadDispatch DC- PF" begin
    models = [PowerLoadDispatch]
    c_sys5_il = PSB.build_system(PSITestSystems, "c_sys5_il")
    networks = [DCPNetworkModel]
    for m in models, n in networks
        device_model = DeviceModel(InterruptiblePowerLoad, m)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        mock_construct_device!(model, device_model)
        moi_tests(model, 24, 0, 24, 0, 0, false)
        psi_checkobjfun_test(model, GAEVF)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        mock_construct_device!(model, device_model; add_event_model = true)
        moi_tests(model, 24, 0, 48, 0, 0, false)
    end
end

@testset "PowerLoadDispatch AC- PF" begin
    models = [PowerLoadDispatch]
    c_sys5_il = PSB.build_system(PSITestSystems, "c_sys5_il")
    networks = [ACPNetworkModel]
    for m in models, n in networks
        device_model = DeviceModel(InterruptiblePowerLoad, m)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        mock_construct_device!(model, device_model)
        moi_tests(model, 48, 0, 24, 0, 24, false)
        psi_checkobjfun_test(model, GAEVF)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        mock_construct_device!(model, device_model; add_event_model = true)
        moi_tests(model, 48, 0, 48, 0, 24, false, 24)
    end
end

@testset "PowerLoadDispatch constant power factor uses Q/P = q_max/p_max" begin
    c_sys5_il = PSB.build_system(PSITestSystems, "c_sys5_il")
    load = get_component(InterruptiblePowerLoad, c_sys5_il, "IloadBus4")
    set_max_reactive_power!(load, 0.75 * get_max_active_power(load, u"SU") * u"SU")
    device_model = DeviceModel(InterruptiblePowerLoad, PowerLoadDispatch)
    model = DecisionModel(MockOperationProblem, ACPNetworkModel, c_sys5_il)
    mock_construct_device!(model, device_model)
    container = IOM.get_optimization_container(model)
    p = IOM.get_variable(container, ActivePowerVariable, InterruptiblePowerLoad)
    cons = IOM.get_constraint(
        container,
        POM.ReactivePowerVariableLimitsConstraint,
        InterruptiblePowerLoad,
    )
    @test JuMP.normalized_coefficient(cons["IloadBus4", 1], p["IloadBus4", 1]) ≈ -0.75
end

@testset "PowerLoadDispatch AC- PF with MarketBidCost Invalid" begin
    models = [PowerLoadDispatch]
    c_sys5_il = PSB.build_system(PSITestSystems, "c_sys5_il")
    iloadbus4 = get_component(InterruptiblePowerLoad, c_sys5_il, "IloadBus4")
    set_operation_cost!(
        iloadbus4,
        MarketBidCost(;
            minimum_energy_offer = LinearCurve(0.0),
            start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
            shut_down = LinearCurve(0.0),
            incremental_offer_curves = make_market_bid_curve(
                [0.0, 100.0, 200.0, 300.0, 400.0, 500.0, 600.0],
                [25.0, 25.5, 26.0, 27.0, 28.0, 30.0],
                0.0,
            ),
        ),
    )
    networks = [ACPNetworkModel]
    for m in models, n in networks
        device_model = DeviceModel(InterruptiblePowerLoad, m)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        @test_throws ArgumentError mock_construct_device!(model, device_model)
    end
end

@testset "PowerLoadDispatch AC- PF with MarketBidCost" begin
    c_sys5_il = PSB.build_system(PSITestSystems, "c_sys5_il")
    iloadbus4 = get_component(InterruptiblePowerLoad, c_sys5_il, "IloadBus4")
    set_operation_cost!(
        iloadbus4,
        MarketBidCost(;
            minimum_energy_offer = LinearCurve(0.0),
            start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
            shut_down = LinearCurve(0.0),
            decremental_offer_curves = make_market_bid_curve(
                [0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0],
                [90.0, 85.0, 75.0, 70.0, 60.0, 50.0, 45.0, 40.0, 30.0, 25.0],
                0.0,
            ),
        ),
    )
    template = PowerOperationsProblemTemplate(NetworkModel(CopperPlateNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, InterruptiblePowerLoad, PowerLoadDispatch)
    model = DecisionModel(template,
        c_sys5_il;
        name = "UC_fixed_market_bid_cost",
        optimizer = HiGHS_optimizer,
        optimizer_solve_log_print = true)
    @test build!(model; output_dir = test_path) == IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    outputs = OptimizationProblemOutputs(model)
    expr = read_expression(
        outputs,
        "ProductionCostExpression__InterruptiblePowerLoad";
        table_format = TableFormat.WIDE,
    )
    p_l = read_variable(
        outputs,
        "ActivePowerVariable__InterruptiblePowerLoad";
        table_format = TableFormat.WIDE,
    )
    index = findfirst(row -> isapprox(100, row; atol = 1e-6), p_l.IloadBus4)
    calculated_cost = expr[index, "IloadBus4"][1]
    @test isapprox(-5700, calculated_cost; atol = 1)
end

@testset "PowerLoadInterruption DC- PF" begin
    models = [PowerLoadInterruption]
    c_sys5_il = PSB.build_system(PSITestSystems, "c_sys5_il")
    networks = [DCPNetworkModel]
    for m in models, n in networks
        device_model = DeviceModel(InterruptiblePowerLoad, m)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        mock_construct_device!(model, device_model)
        moi_tests(model, 48, 0, 48, 0, 0, true)
        psi_checkobjfun_test(model, GAEVF)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        mock_construct_device!(model, device_model; add_event_model = true)
        moi_tests(model, 48, 0, 72, 0, 0, true)
    end
end

@testset "PowerLoadInterruption AC- PF" begin
    models = [PowerLoadInterruption]
    c_sys5_il = PSB.build_system(PSITestSystems, "c_sys5_il")
    networks = [ACPNetworkModel]
    for m in models, n in networks
        device_model = DeviceModel(InterruptiblePowerLoad, m)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        mock_construct_device!(model, device_model)
        moi_tests(model, 72, 0, 48, 0, 24, true)
        psi_checkobjfun_test(model, GAEVF)
        model = DecisionModel(MockOperationProblem, n, c_sys5_il)
        mock_construct_device!(model, device_model; add_event_model = true)
        moi_tests(model, 72, 0, 72, 0, 24, true, 24)
    end
end

@testset "Loads without TimeSeries" begin
    sys = build_system(PSITestSystems, "c_sys5_uc"; force_build = true)
    load = get_component(PowerLoad, sys, "Bus2")
    remove_time_series!(sys, Deterministic, load, "max_active_power")

    networks = [CopperPlateNetworkModel, PTDFNetworkModel, DCPNetworkModel, ACPNetworkModel]
    solvers = [HiGHS_optimizer, HiGHS_optimizer, HiGHS_optimizer, ipopt_optimizer]
    for (ix, net) in enumerate(networks)
        template = PowerOperationsProblemTemplate(
            NetworkModel(
                net;
            ),
        )
        set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
        set_device_model!(template, PowerLoad, StaticPowerLoad)
        set_device_model!(template, Line, StaticBranch)

        model = DecisionModel(
            template,
            sys;
            name = "UC",
            store_variable_names = true,
            optimizer = solvers[ix],
        )

        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    end
end

@testset "Loads with MotorLoad" begin
    sys = build_system(PSITestSystems, "c_sys5_uc"; force_build = true)
    load = get_component(PowerLoad, sys, "Bus2")

    mload = MotorLoad(;
        name = "MotorLoadBus2",
        available = true,
        bus = load.bus,
        active_power = load.active_power / 10.0,
        reactive_power = load.reactive_power / 10.0,
        base_power = load.base_power,
        rating = load.max_active_power / 10.0,
        max_active_power = load.max_active_power / 10.0,
        reactive_power_limits = nothing,
        input_basis = u"CU",
    )
    add_component!(sys, mload)

    networks = [CopperPlateNetworkModel, PTDFNetworkModel, DCPNetworkModel, ACPNetworkModel]
    solvers = [HiGHS_optimizer, HiGHS_optimizer, HiGHS_optimizer, ipopt_optimizer]
    for (ix, net) in enumerate(networks)
        template = PowerOperationsProblemTemplate(
            NetworkModel(
                net;
            ),
        )
        set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
        set_device_model!(template, PowerLoad, StaticPowerLoad)
        set_device_model!(template, MotorLoad, StaticPowerLoad)
        set_device_model!(template, Line, StaticBranch)

        model = DecisionModel(
            template,
            sys;
            name = "UC",
            store_variable_names = true,
            optimizer = solvers[ix],
        )

        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    end
end

@testset "PowerLoadShift with NonAnticipativityConstraint" begin
    c_sys5_il =
        PSB.build_system(PSITestSystems, "c_sys5_il"; add_single_time_series = true)
    il_load = first(PSY.get_components(InterruptiblePowerLoad, c_sys5_il))

    shiftable_load = ShiftablePowerLoad(;
        name = "shiftable_load",
        available = true,
        bus = PSY.get_bus(il_load),
        active_power = PSY.get_active_power(il_load, u"SU"),
        active_power_limits = (min = 0.0, max = PSY.get_active_power(il_load, u"SU")),
        reactive_power = PSY.get_reactive_power(il_load, u"SU"),
        max_active_power = PSY.get_max_active_power(il_load, u"SU"),
        max_reactive_power = PSY.get_max_reactive_power(il_load, u"SU"),
        base_power = PSY.get_base_power(il_load, u"NU"),
        load_balance_time_horizon = 1,
        operation_cost = LoadCost(;
            variable_operation_cost = CostCurve(
                LinearCurve(0.0),
                PSY.NU,
                LinearCurve(1.0),
            ),
            fixed = 0.0,
        ),
        input_basis = u"CU",
    )
    PSY.add_component!(c_sys5_il, shiftable_load)
    PSY.set_available!(il_load, false)
    PSY.copy_time_series!(shiftable_load, il_load)

    tstamps = TimeSeries.timestamp(
        PSY.get_time_series_array(SingleTimeSeries, shiftable_load, "max_active_power"),
    )
    n = length(tstamps)
    up_vals = ones(n)
    down_vals = ones(n)

    PSY.add_time_series!(
        c_sys5_il,
        shiftable_load,
        SingleTimeSeries(
            "shift_up_max_active_power",
            TimeArray(tstamps, up_vals),
        ),
    )
    PSY.add_time_series!(
        c_sys5_il,
        shiftable_load,
        SingleTimeSeries(
            "shift_down_max_active_power",
            TimeArray(tstamps, down_vals),
        ),
    )

    PSY.transform_single_time_series!(c_sys5_il, Hour(24), Hour(24))

    template = PowerOperationsProblemTemplate(
        NetworkModel(
            CopperPlateNetworkModel;
            duals = [CopperPlateBalanceConstraint],
        ),
    )
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(
        template,
        DeviceModel(
            ShiftablePowerLoad,
            PowerLoadShift;
            attributes = Dict{String, Any}("additional_balance_interval" => Hour(12)),
        ),
    )

    model = DecisionModel(
        template,
        c_sys5_il;
        name = "UC_shiftable",
        store_variable_names = true,
        optimizer = HiGHS_optimizer,
    )

    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT

    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    results = OptimizationProblemOutputs(model)
    up = read_variable(
        results,
        "ShiftUpActivePowerVariable__ShiftablePowerLoad";
        table_format = TableFormat.WIDE,
    )
    dn = read_variable(
        results,
        "ShiftDownActivePowerVariable__ShiftablePowerLoad";
        table_format = TableFormat.WIDE,
    )

    # Verify the non-anticipativity constraint holds in the solution:
    # the running sum of (shift_down - shift_up) must be >= 0 at every time step.
    @test all(
        cumsum(dn[!, "shiftable_load"] .- up[!, "shiftable_load"]) .>= -1e-6,
    )
end

function _build_shiftable_load_system()
    c_sys5_il =
        PSB.build_system(PSITestSystems, "c_sys5_il"; add_single_time_series = true)

    # AreaBalanceNetworkModel/AreaPTDFNetworkModel require at least one Area; c_sys5_il
    # ships with none.
    area = PSY.Area(; name = "area1", input_basis = u"CU")
    PSY.add_component!(c_sys5_il, area)
    for bus in PSY.get_components(PSY.ACBus, c_sys5_il)
        PSY.set_area!(bus, area)
    end

    il_load = first(PSY.get_components(InterruptiblePowerLoad, c_sys5_il))

    shiftable_load = ShiftablePowerLoad(;
        name = "shiftable_load",
        available = true,
        bus = PSY.get_bus(il_load),
        active_power = PSY.get_active_power(il_load, u"SU"),
        active_power_limits = (min = 0.0, max = PSY.get_active_power(il_load, u"SU")),
        reactive_power = PSY.get_reactive_power(il_load, u"SU"),
        max_active_power = PSY.get_max_active_power(il_load, u"SU"),
        max_reactive_power = PSY.get_max_reactive_power(il_load, u"SU"),
        base_power = PSY.get_base_power(il_load, u"NU"),
        load_balance_time_horizon = 1,
        operation_cost = LoadCost(;
            variable_operation_cost = CostCurve(
                LinearCurve(0.0),
                PSY.NU,
                LinearCurve(1.0),
            ),
            fixed = 0.0,
        ),
        input_basis = u"CU",
    )
    PSY.add_component!(c_sys5_il, shiftable_load)
    PSY.set_available!(il_load, false)
    PSY.copy_time_series!(shiftable_load, il_load)

    tstamps = TimeSeries.timestamp(
        PSY.get_time_series_array(SingleTimeSeries, shiftable_load, "max_active_power"),
    )
    n = length(tstamps)
    PSY.add_time_series!(
        c_sys5_il,
        shiftable_load,
        SingleTimeSeries(
            "shift_up_max_active_power",
            TimeArray(tstamps, ones(n)),
        ),
    )
    PSY.add_time_series!(
        c_sys5_il,
        shiftable_load,
        SingleTimeSeries(
            "shift_down_max_active_power",
            TimeArray(tstamps, ones(n)),
        ),
    )
    PSY.transform_single_time_series!(c_sys5_il, Hour(24), Hour(24))
    return c_sys5_il, shiftable_load
end

# Mirrors _balance_expression_targets: CopperPlate keys ActivePowerBalance by the system
# reference bus, AreaBalance by area name, and every other network model (PTDF/AreaPTDF
# included, which also carry a nodal ACBus entry) by the device's bus number.
_shiftable_load_balance_row(
    network_model::NetworkModel{CopperPlateNetworkModel},
    container,
    bus,
) = (
    IOM.get_expression(container, ActivePowerBalance, PSY.System),
    POM.get_reference_bus(network_model, bus),
)
_shiftable_load_balance_row(
    ::NetworkModel{AreaBalanceNetworkModel},
    container,
    bus,
) = (
    IOM.get_expression(container, ActivePowerBalance, PSY.Area),
    PSY.get_name(PSY.get_area(bus)),
)
_shiftable_load_balance_row(::NetworkModel, container, bus) =
    (IOM.get_expression(container, ActivePowerBalance, PSY.ACBus), PSY.get_number(bus))

@testset "PowerLoadShift wires RealizedShiftedLoad into ActivePowerBalance on every network model" begin
    networks = [
        (CopperPlateNetworkModel, HiGHS_optimizer),
        (PTDFNetworkModel, HiGHS_optimizer),
        (AreaPTDFNetworkModel, HiGHS_optimizer),
        (AreaBalanceNetworkModel, HiGHS_optimizer),
        (NFANetworkModel, HiGHS_optimizer),
        (DCPNetworkModel, HiGHS_optimizer),
        (DCPLLNetworkModel, ipopt_optimizer),
        (ACPNetworkModel, ipopt_optimizer),
        (ACRNetworkModel, ipopt_optimizer),
        (IVRNetworkModel, ipopt_optimizer),
        (LPACCNetworkModel, ipopt_optimizer),
    ]

    sys, shiftable_load = _build_shiftable_load_system()
    for (network_formulation, optimizer) in networks
        template =
            get_thermal_dispatch_template_network(NetworkModel(network_formulation))
        set_device_model!(template, ShiftablePowerLoad, PowerLoadShift)

        model = DecisionModel(template, sys; optimizer = optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT

        container = IOM.get_optimization_container(model)
        network_model = IOM.get_network_model(IOM.get_template(model))
        bus = PSY.get_bus(shiftable_load)
        balance, row = _shiftable_load_balance_row(network_model, container, bus)
        t1 = first(IOM.get_time_steps(container))
        up_var = IOM.get_variable(container, ShiftUpActivePowerVariable, ShiftablePowerLoad)
        dn_var =
            IOM.get_variable(container, ShiftDownActivePowerVariable, ShiftablePowerLoad)

        @test JuMP.coefficient(balance[row, t1], up_var["shiftable_load", t1]) == -1.0
        @test JuMP.coefficient(balance[row, t1], dn_var["shiftable_load", t1]) == 1.0

        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    end
end

@testset "Unoffered controllable load: pinned at zero, up-reserve range from its limits" begin
    for formulation in (PowerLoadDispatch, PowerLoadInterruption)
        sys = PSB.build_system(PSITestSystems, "c_sys5_il"; add_reserves = true)
        load = get_component(InterruptiblePowerLoad, sys, "IloadBus4")
        # Empty bid: a zero-valued cost curve → costless.
        PSY.set_operation_cost!(
            load,
            PSY.LoadCost(; variable_operation_cost = zero(PSY.CostCurve), fixed = 0.0),
        )
        @test POM._is_costless_offer(PSY.get_operation_cost(load))

        template = get_thermal_dispatch_template_network()
        set_device_model!(template, InterruptiblePowerLoad, formulation)
        set_service_model!(template, ServiceModel(OnlineReserve{ReserveUp}, RangeReserve))
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT

        container = get_optimization_container(model)
        p = IOM.get_variable(container, ActivePowerVariable, InterruptiblePowerLoad)
        name = PSY.get_name(load)
        objective = JuMP.objective_function(get_jump_model(container))
        for t in get_time_steps(container)
            @test JuMP.upper_bound(p[name, t]) == 0.0
            @test JuMP.lower_bound(p[name, t]) == 0.0
            @test JuMP.coefficient(objective, p[name, t]) == 0.0
        end
        # Its limits still set the up-reserve range: the shed range is anchored on the
        # constant max_active_power, not on the pinned energy variable.
        r = IOM.get_variable(
            container,
            ActivePowerReserveVariable,
            IOM.ComponentPairKey{InterruptiblePowerLoad, OnlineReserve{ReserveUp}},
        )
        t1 = first(get_time_steps(container))
        @test ("Reserve7", name, t1) in eachindex(r)
        pmax = PSY.get_max_active_power(load, u"SU")
        lb = IOM.get_expression(
            container, ActivePowerRangeExpressionLB, InterruptiblePowerLoad,
        )
        @test JuMP.constant(lb[name, t1]) == pmax
        @test JuMP.coefficient(lb[name, t1], p[name, t1]) == 0.0
        @test JuMP.coefficient(lb[name, t1], r[("Reserve7", name, t1)]) == -1.0
    end
end

@testset "Unoffered controllable load rejects a ReserveDown service model" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_il"; add_reserves = true)
    load = get_component(InterruptiblePowerLoad, sys, "IloadBus4")
    PSY.set_operation_cost!(
        load,
        PSY.LoadCost(; variable_operation_cost = zero(PSY.CostCurve), fixed = 0.0),
    )
    template = get_thermal_dispatch_template_network()
    set_device_model!(template, InterruptiblePowerLoad, PowerLoadDispatch)
    set_service_model!(template, ServiceModel(OnlineReserve{ReserveDown}, RangeReserve))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED
    log_contents = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("an unoffered load is pinned at zero", log_contents)
    @test occursin("ConflictingInputsError", log_contents)
    @test_throws IS.ConflictingInputsError POM._validate_unoffered_no_reserve_down(
        POM.get_device_models(IOM.get_template(model))[:InterruptiblePowerLoad],
        [load],
    )
end

function _set_costless!(load; fixed = 0.0)
    PSY.set_operation_cost!(
        load,
        PSY.LoadCost(; variable_operation_cost = zero(PSY.CostCurve), fixed = fixed),
    )
    return
end

function _add_second_load!(sys, load_a, name)
    load_b = PSY.InterruptiblePowerLoad(;
        name = name,
        available = true,
        bus = PSY.get_bus(load_a),
        active_power = PSY.get_active_power(load_a, u"SU"),
        reactive_power = PSY.get_reactive_power(load_a, u"SU"),
        max_active_power = PSY.get_max_active_power(load_a, u"SU"),
        max_reactive_power = PSY.get_max_reactive_power(load_a, u"SU"),
        base_power = PSY.get_base_power(load_a),
        operation_cost = deepcopy(PSY.get_operation_cost(load_a)),
        input_basis = u"CU",
    )
    PSY.add_component!(sys, load_b)
    PSY.copy_time_series!(load_b, load_a)
    return load_b
end

@testset "ReserveDown check fails only for an unoffered contributor" begin
    # Reserve8 (ReserveDown) contains only the priced IloadBus4.
    sys = PSB.build_system(PSITestSystems, "c_sys5_il"; add_reserves = true)
    load_a = get_component(InterruptiblePowerLoad, sys, "IloadBus4")
    load_b = _add_second_load!(sys, load_a, "IL_B")
    _set_costless!(load_b)
    template = get_thermal_dispatch_template_network()
    set_device_model!(template, InterruptiblePowerLoad, PowerLoadDispatch)
    set_service_model!(template, ServiceModel(OnlineReserve{ReserveDown}, RangeReserve))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    # The unoffered load joins the ReserveDown service: the build fails.
    PSY.add_service!(
        load_b,
        get_component(OnlineReserve{ReserveDown}, sys, "Reserve8"),
        sys,
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED
    log_contents = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("IL_B", log_contents)
end

# Maximize the total up award of the unoffered load. Returns the award per time step.
function _max_up_award(container, name)
    r = IOM.get_variable(
        container,
        ActivePowerReserveVariable,
        IOM.ComponentPairKey{InterruptiblePowerLoad, OnlineReserve{ReserveUp}},
    )
    jm = get_jump_model(container)
    JuMP.@objective(jm, Max, sum(r[i] for i in eachindex(r)))
    JuMP.set_optimizer(jm, HiGHS.Optimizer)
    JuMP.set_silent(jm)
    JuMP.optimize!(jm)
    @test JuMP.termination_status(jm) == MOI.OPTIMAL
    return [
        sum(JuMP.value(r[i]) for i in eachindex(r) if last(i) == t) for
        t in get_time_steps(container)
    ]
end

function _build_unoffered_up_model(formulation; outage = false, fixed = 0.0)
    sys = PSB.build_system(PSITestSystems, "c_sys5_il"; add_reserves = true)
    load = get_component(InterruptiblePowerLoad, sys, "IloadBus4")
    _set_costless!(load; fixed = fixed)
    template = get_thermal_dispatch_template_network()
    set_device_model!(template, InterruptiblePowerLoad, formulation)
    set_service_model!(
        template,
        ServiceModel(OnlineReserve{ReserveUp}, RangeReserve; use_slacks = true),
    )
    if outage
        model, status, _ =
            build_outage_model(sys, load; template = template, recurrent = true)
    else
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        status = build!(model; output_dir = mktempdir(; cleanup = true))
    end
    @test status == IOM.ModelBuildStatus.BUILT
    return get_optimization_container(model), load
end

@testset "Unoffered load in an outage sells no up-reserve" begin
    for formulation in (PowerLoadDispatch, PowerLoadInterruption)
        container, load = _build_unoffered_up_model(formulation; outage = true)
        status = IOM.get_parameter_array(
            container, AvailableStatusParameter(), InterruptiblePowerLoad,
        )
        for idx in eachindex(status)
            JuMP.fix(status[idx], 1.0; force = true)
        end
        @test sum(_max_up_award(container, PSY.get_name(load))) > 1e-3
        for idx in eachindex(status)
            JuMP.fix(status[idx], 0.0; force = true)
        end
        @test all(abs.(_max_up_award(container, PSY.get_name(load))) .<= 1e-6)
    end
end

@testset "Unoffered load up-reserve is capped by its forecast" begin
    for formulation in (PowerLoadDispatch, PowerLoadInterruption)
        container, load = _build_unoffered_up_model(formulation)
        name = PSY.get_name(load)
        pmax = PSY.get_max_active_power(load, u"SU")
        param =
            IOM.get_parameter(
                container,
                ActivePowerTimeSeriesParameter,
                InterruptiblePowerLoad,
            )
        cap =
            IOM.get_multiplier_array(param)[name, :] .*
            IOM.get_parameter_column_values(param, name)
        @test any(cap .< pmax - 1e-3)
        awards = _max_up_award(container, name)
        @test isapprox(awards, collect(cap); atol = 1e-6)
    end
end

@testset "Unoffered PowerLoadInterruption: on = 0 gives a zero up award" begin
    container, load = _build_unoffered_up_model(PowerLoadInterruption)
    name = PSY.get_name(load)
    on = IOM.get_variable(container, OnVariable, InterruptiblePowerLoad)
    for t in get_time_steps(container)
        JuMP.fix(on[name, t], 0.0; force = true)
    end
    @test all(abs.(_max_up_award(container, name)) .<= 1e-6)
end

@testset "Unoffered PowerLoadInterruption keeps its fixed cost on OnVariable" begin
    container, load = _build_unoffered_up_model(PowerLoadInterruption; fixed = 5.0)
    name = PSY.get_name(load)
    on = IOM.get_variable(container, OnVariable, InterruptiblePowerLoad)
    objective = JuMP.objective_function(get_jump_model(container))
    t1 = first(get_time_steps(container))
    @test !iszero(JuMP.coefficient(objective, on[name, t1]))
end

@testset "Unoffered controllable load with forecast and up-reserve solves" begin
    for formulation in (PowerLoadDispatch, PowerLoadInterruption)
        sys = PSB.build_system(PSITestSystems, "c_sys5_il"; add_reserves = true)
        load = get_component(InterruptiblePowerLoad, sys, "IloadBus4")
        PSY.set_operation_cost!(
            load,
            PSY.LoadCost(; variable_operation_cost = zero(PSY.CostCurve), fixed = 0.0),
        )
        template = get_thermal_dispatch_template_network()
        set_device_model!(template, InterruptiblePowerLoad, formulation)
        set_service_model!(
            template,
            ServiceModel(OnlineReserve{ReserveUp}, RangeReserve; use_slacks = true),
        )
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        container = get_optimization_container(model)
        name = PSY.get_name(load)
        pmax = PSY.get_max_active_power(load, u"SU")
        p = IOM.get_variable(container, ActivePowerVariable, InterruptiblePowerLoad)
        r = IOM.get_variable(
            container,
            ActivePowerReserveVariable,
            IOM.ComponentPairKey{InterruptiblePowerLoad, OnlineReserve{ReserveUp}},
        )
        for t in get_time_steps(container)
            @test JuMP.value(p[name, t]) == 0.0
            award = JuMP.value(r[("Reserve7", name, t)])
            @test -1e-6 <= award <= pmax + 1e-6
        end
    end
end

@testset "Priced controllable load keeps economic dispatch bounds" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_il"; add_reserves = true)
    load = get_component(InterruptiblePowerLoad, sys, "IloadBus4")
    @test !POM._is_costless_offer(PSY.get_operation_cost(load))
    template = get_thermal_dispatch_template_network()
    set_device_model!(template, InterruptiblePowerLoad, PowerLoadDispatch)
    set_service_model!(template, ServiceModel(OnlineReserve{ReserveUp}, RangeReserve))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = get_optimization_container(model)
    p = IOM.get_variable(container, ActivePowerVariable, InterruptiblePowerLoad)
    name = PSY.get_name(load)
    t1 = first(get_time_steps(container))
    @test JuMP.upper_bound(p[name, t1]) == PSY.get_max_active_power(load, u"SU")
    lb = IOM.get_expression(container, ActivePowerRangeExpressionLB, InterruptiblePowerLoad)
    @test JuMP.coefficient(lb[name, t1], p[name, t1]) == 1.0
    @test JuMP.constant(lb[name, t1]) == 0.0
end

@testset "Unoffered PowerLoadDispatch load without services: upper bound 0, no objective term" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_il")
    load = get_component(InterruptiblePowerLoad, sys, "IloadBus4")
    PSY.set_operation_cost!(
        load,
        PSY.LoadCost(; variable_operation_cost = zero(PSY.CostCurve), fixed = 0.0),
    )
    template = get_thermal_dispatch_template_network()
    set_device_model!(template, InterruptiblePowerLoad, PowerLoadDispatch)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = get_optimization_container(model)
    p = IOM.get_variable(container, ActivePowerVariable, InterruptiblePowerLoad)
    name = PSY.get_name(load)
    objective = JuMP.objective_function(get_jump_model(container))
    for t in get_time_steps(container)
        @test JuMP.upper_bound(p[name, t]) == 0.0
        @test JuMP.coefficient(objective, p[name, t]) == 0.0
    end
end
