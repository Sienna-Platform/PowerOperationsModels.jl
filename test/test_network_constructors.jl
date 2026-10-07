function add_load_time_series_data!(sys)
    # Fractions of each load's max_active_power, not absolute power, so total
    # demand stays under generation capacity across every timestep.
    profile = Dict(
        DateTime("2020-01-01T08:00:00") => [0.5, 0.6, 0.7, 0.7, 0.7],
        DateTime("2020-01-01T08:30:00") => [0.9, 0.9, 0.9, 0.9, 0.8],
        DateTime("2020-01-01T09:00:00") => [0.6, 0.6, 0.5, 0.5, 0.4],
    )
    resolution = Dates.Minute(5)
    forecast = Deterministic("max_active_power", profile, resolution)
    add_time_series!(sys, collect(get_components(StandardLoad, sys)), forecast)
    return sys
end

function _reduced_ptdf_duals_template()
    sys = build_system(PSITestSystems, "case11_network_reductions")
    add_load_time_series_data!(sys)
    nr = NetworkReduction[RadialReduction(), DegreeTwoReduction()]

    template = PowerOperationsProblemTemplate(
        NetworkModel(PTDFNetworkModel;
            network_source = SystemNetworkSource(nr),
            duals = [CopperPlateBalanceConstraint],
            use_slacks = false),
    )
    # Mirror the filter shape from issue #1594: a voltage threshold that selects
    # all lines in this all-230 kV system. The filter is registered (so the
    # filter_function code path runs) but does not exclude any branch from a
    # series chain, so reductions still drop lines from the constraint axis.
    set_device_model!(
        template,
        DeviceModel(
            Line,
            StaticBranch;
            duals = [FlowRateConstraint],
            attributes = Dict(
                "filter_function" =>
                    x -> PSY.get_base_voltage(PSY.get_from(PSY.get_arc(x))) >= 230.0,
            ),
        ),
    )
    set_device_model!(template, TwoWindingTransformer, StaticBranch)
    return sys, template
end

# Regression test for PSI #1594
@testset "FlowRateConstraint duals with branch filter and network reductions" begin
    sys, template = _reduced_ptdf_duals_template()
    ps_model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = get_optimization_container(ps_model)
    # The unfiltered Line set has 12 entries; full reduction leaves 6 entries
    # in the constraint axis. The dual container must use the same 6 entries.
    for meta in ("lb", "ub")
        cons_key = ConstraintKey(FlowRateConstraint, Line, meta)
        cons = get_constraint(container, cons_key)
        dual = get_duals(container)[cons_key]
        @test axes(dual)[1] == axes(cons)[1]
        @test length(axes(cons)[1]) <
              length(collect(get_components(Line, sys)))
        @test "4-5-i_1" in axes(cons)[1]
    end
end

# Companion to the build-only test above: the same reduced-PTDF setup, but
# solved end-to-end so the process_duals broadcast actually runs, not just the
# build-time axis check.
@testset "FlowRateConstraint duals with network reductions solved end-to-end" begin
    sys, template = _reduced_ptdf_duals_template()
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, StandardLoad, StaticPowerLoad)

    ps_model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(ps_model)
    line_names = collect(get_name.(get_components(Line, sys)))
    for meta in ("lb", "ub")
        cons_key = ConstraintKey(FlowRateConstraint, Line, meta)
        cons = get_constraint(container, cons_key)
        dual = get_duals(container)[cons_key]
        @test axes(dual)[1] == axes(cons)[1]
        @test length(axes(cons)[1]) < length(line_names)
    end

    res = IOM.OptimizationProblemOutputs(ps_model)
    for meta in ("lb", "ub")
        cons_key = ConstraintKey(FlowRateConstraint, Line, meta)
        cons_axis = axes(get_constraint(container, cons_key))[1]
        duals_df = read_dual(res, cons_key; table_format = TableFormat.WIDE)
        dual_names = String.([c for c in propertynames(duals_df) if c != :DateTime])
        @test Set(dual_names) == Set(cons_axis)
        @test length(dual_names) < length(line_names)
        dual_values = Matrix(duals_df[:, propertynames(duals_df) .!= :DateTime])
        @test all(isfinite, dual_values)
    end
end

# No PSB system ships with both Areas and InterconnectingConverters, so the two
# 5-bus halves of sys10_pjm_ac_dc (bridged only by the DC ties) are split into
# two areas. Every converter must enter its Area, AC-bus, and DC-bus
# ActivePowerBalance expressions with the correct signed coefficients.
@testset "AreaPTDFNetworkModel with InterconnectingConverter" begin
    sys = build_system(PSISystems, "sys10_pjm_ac_dc")
    # Double the marginal cost of every Area_2-side thermal unit so the optimum
    # must move power across the DC ties (non-vacuity of the converter wiring).
    for g in get_components(ThermalStandard, sys)
        endswith(get_name(g), "-2") || continue
        op_cost = get_operation_cost(g)
        val_curve = get_value_curve(PSY.get_variable_operation_cost(op_cost))
        new_op_cost = ThermalGenerationCost(
            CostCurve(
                QuadraticCurve(
                    get_quadratic_term(val_curve),
                    2.0 * get_proportional_term(val_curve),
                    get_constant_term(val_curve),
                ),
                get_power_units(PSY.get_variable_operation_cost(op_cost)),
                get_vom_cost(PSY.get_variable_operation_cost(op_cost)),
            ),
            get_fixed(op_cost),
            get_start_up(op_cost),
            get_shut_down(op_cost),
        )
        set_operation_cost!(g, new_op_cost)
    end
    areas = [Area("Area_1", 0.0, 0.0, 0.0), Area("Area_2", 0.0, 0.0, 0.0)]
    for a in areas
        add_component!(sys, a)
    end
    for b in get_components(ACBus, sys)
        if get_number(b) <= 5
            set_area!(b, areas[1])
        else
            set_area!(b, areas[2])
        end
    end

    template = get_thermal_dispatch_template_network(AreaPTDFNetworkModel)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, DeviceModel(InterconnectingConverter, LosslessConverter))
    set_device_model!(template, DeviceModel(TModelHVDCLine, LosslessLine))
    set_hvdc_network_model!(template, TransportHVDCNetworkModel)

    ps_model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = HiGHS_optimizer,
    )
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(ps_model)
    area_expr = IOM.get_expression(container, ActivePowerBalance, Area)
    ac_expr = IOM.get_expression(container, ActivePowerBalance, ACBus)
    dc_expr = IOM.get_expression(container, ActivePowerBalance, DCBus)
    conv = IOM.get_variable(container, ActivePowerVariable, InterconnectingConverter)
    converters = collect(get_components(InterconnectingConverter, sys))
    @test !isempty(converters)
    for ic in converters
        name = get_name(ic)
        bus = get_bus(ic)
        area_name = get_name(get_area(bus))
        bus_no = get_number(bus)
        dc_bus_no = get_number(get_dc_bus(ic))
        for t in (1, size(conv)[2])
            v = conv[name, t]
            @test JuMP.coefficient(area_expr[area_name, t], v) == 1.0
            @test JuMP.coefficient(ac_expr[bus_no, t], v) == 1.0
            @test JuMP.coefficient(dc_expr[dc_bus_no, t], v) == -1.0
        end
    end

    # The two areas exchange power only through the DC ties, so at the optimum the
    # converters must carry a non-zero transfer (non-vacuity of the wiring above).
    p = JuMP.value.(conv)
    @test maximum(abs.(p.data)) > 1e-3
end

@testset "2 Areas area-aggregated duals" begin
    for network_formulation in (
        AreaBalanceNetworkModel,
        AreaPTDFNetworkModel,
    )
        c_sys = PSB.build_system(PSISystems, "two_area_pjm_DA")
        transform_single_time_series!(c_sys, Hour(24), Hour(1))
        template = get_thermal_dispatch_template_network(
            NetworkModel(network_formulation; duals = [CopperPlateBalanceConstraint]),
        )
        set_device_model!(template, AreaInterchange, StaticBranch)
        set_device_model!(template, Line, StaticBranch)
        ps_model =
            DecisionModel(
                template,
                c_sys;
                resolution = Hour(1),
                optimizer = HiGHS_optimizer,
            )

        @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT

        opt_container = IOM.get_optimization_container(ps_model)
        dual_keys = collect(keys(get_duals(opt_container)))
        @test IOM.ConstraintKey(CopperPlateBalanceConstraint, PSY.Area) in dual_keys

        @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

        results = OptimizationProblemOutputs(ps_model)
        area_duals = read_dual(
            results,
            CopperPlateBalanceConstraint,
            PSY.Area;
            table_format = TableFormat.WIDE,
        )
        @test size(area_duals, 1) == 24
        foreach(get_components(Area, c_sys)) do area
            @test get_name(area) in names(area_duals)
            @test all(isfinite, area_duals[!, get_name(area)])
        end
    end
end

function _make_hvdc_area_system(; same_area, loss_factor)
    sys = PSB.build_system(
        PSISystems, "two_area_pjm_DA";
        add_reserves = false, time_series_in_memory = true,
    )
    arc = get_arc(get_component(Line, sys, "inter_area_line"))
    if same_area
        arc = get_arc(
            first(
                l for l in get_components(Line, sys) if
                get_area(get_from(get_arc(l))) == get_area(get_to(get_arc(l)))
            ),
        )
    end
    hvdc = TwoTerminalGenericHVDCLine(;
        name = "test_hvdc",
        available = true,
        active_power_flow = 0.0,
        arc = arc,
        rating = 200.0,
        rating_from = 200.0,
        rating_to = 200.0,
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        loss = PSY.LossCurve(LinearCurve(loss_factor), PSY.CU),
        input_basis = u"CU",
    )
    add_component!(sys, hvdc)
    transform_single_time_series!(sys, Hour(24), Hour(1))
    return sys, hvdc
end

function _hvdc_area_model(sys, network_type, formulation)
    template = PowerOperationsProblemTemplate(NetworkModel(network_type))
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    set_device_model!(template, RenewableDispatch, FixedOutput)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranchUnbounded)
    set_device_model!(template, TwoTerminalGenericHVDCLine, formulation)
    if network_type == AreaPTDFNetworkModel
        set_device_model!(template, AreaInterchange, StaticBranch)
    else
        remove_component!(sys, get_component(AreaInterchange, sys, "1_2"))
    end
    return DecisionModel(template, sys; resolution = Hour(1),
        horizon = Hour(2), optimizer = HiGHS_optimizer)
end

function _hvdc_terminal_variables(container, formulation)
    from_type = FlowActivePowerFromToVariable
    to_type = FlowActivePowerToFromVariable
    if formulation == HVDCTwoTerminalLossless
        from_type = FlowActivePowerVariable
        to_type = FlowActivePowerVariable
    elseif formulation == HVDCTwoTerminalPiecewiseLoss
        from_type = POM.HVDCActivePowerReceivedFromVariable
        to_type = POM.HVDCActivePowerReceivedToVariable
    end
    from = IOM.get_variable(container, from_type, TwoTerminalGenericHVDCLine)
    to = IOM.get_variable(container, to_type, TwoTerminalGenericHVDCLine)
    return from, to
end

@testset "PTDFNetworkModel PWL HVDC losses enter the system row" begin
    sys, _ = _make_hvdc_area_system(; same_area = true, loss_factor = 0.02)
    model = _hvdc_area_model(sys, PTDFNetworkModel, HVDCTwoTerminalPiecewiseLoss)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    from, to = _hvdc_terminal_variables(container, HVDCTwoTerminalPiecewiseLoss)
    sys_expr = IOM.get_expression(container, ActivePowerBalance, PSY.System)
    for t in 1:2
        row = sys_expr[first(axes(sys_expr, 1)), t]
        @test JuMP.coefficient(row, from["test_hvdc", t]) == 1.0
        @test JuMP.coefficient(row, to["test_hvdc", t]) == 1.0
    end
end

@testset "PTDFNetworkModel HVDC fixed transfers and losses" begin
    for formulation in (
            HVDCTwoTerminalLossless,
            HVDCTwoTerminalDispatch,
            HVDCTwoTerminalPiecewiseLoss,
        ), same_area in (false, true)
        loss_factor = 0.02
        if formulation == HVDCTwoTerminalLossless
            loss_factor = 0.0
        end
        from_sign = -1.0
        to_sign = -1.0
        if formulation == HVDCTwoTerminalLossless
            to_sign = 1.0
        elseif formulation == HVDCTwoTerminalPiecewiseLoss
            from_sign = 1.0
            to_sign = 1.0
        end
        sys, _ = _make_hvdc_area_system(; same_area, loss_factor)
        model = _hvdc_area_model(sys, PTDFNetworkModel, formulation)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        from, to = _hvdc_terminal_variables(container, formulation)
        for (t, transfer) in enumerate((0.5, -0.5))
            JuMP.fix(from["test_hvdc", t], -from_sign * transfer; force = true)
        end
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        for (t, transfer) in enumerate((0.5, -0.5))
            from_injection = from_sign * JuMP.value(from["test_hvdc", t])
            to_injection = to_sign * JuMP.value(to["test_hvdc", t])
            @test isapprox(-from_injection, transfer; atol = 1e-8)
            @test isapprox(
                -(from_injection + to_injection),
                loss_factor * max(-from_injection, -to_injection);
                atol = 1e-8,
            )
        end
    end
end

@testset "AreaPTDFNetworkModel HVDC tie with AreaInterchange" begin
    for formulation in (
        HVDCTwoTerminalLossless,
        HVDCTwoTerminalDispatch,
        HVDCTwoTerminalPiecewiseLoss,
    )
        loss_factor = 0.02
        if formulation == HVDCTwoTerminalLossless
            loss_factor = 0.0
        end
        from_sign = -1.0
        if formulation == HVDCTwoTerminalPiecewiseLoss
            from_sign = 1.0
        end
        sys, _ = _make_hvdc_area_system(; same_area = false, loss_factor)
        set_flow_limits!(
            get_component(AreaInterchange, sys, "1_2"),
            (from_to = 20.0u"SU", to_from = 20.0u"SU"),
        )
        model = _hvdc_area_model(sys, AreaPTDFNetworkModel, formulation)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        from, _ = _hvdc_terminal_variables(container, formulation)
        for (t, transfer) in enumerate((0.5, -0.5))
            JuMP.fix(from["test_hvdc", t], -from_sign * transfer; force = true)
        end
        solve!(model)
        status = JuMP.termination_status(IOM.get_jump_model(container))
        if formulation == HVDCTwoTerminalLossless
            @test status == MOI.OPTIMAL
        else
            # Losses in the area balance are not consistent with the interchange metering.
            @test_broken status == MOI.OPTIMAL
        end
    end
end
