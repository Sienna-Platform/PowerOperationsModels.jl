const DC_NETWORK_MODELS_FOR_TESTING = [PTDFNetworkModel, DCPNetworkModel]

_rating(d::PSY.TwoWindingTransformer) = PSY.get_rating(PSY.get_circuit(d), u"SU")
_rating(d) = PSY.get_rating(d, u"SU")

@testset "Build warns when a Line sets an operational flow limit at its rating" begin
    system = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(Line, system, "1")
    limit = PSY.get_rating(line, u"SU")
    PSY.set_operational_flow_limit!(
        line,
        (
            from_to = (min = 0.0 * u"SU", max = limit * u"SU"),
            to_from = (min = 0.0 * u"SU", max = limit * u"SU"),
        ),
    )
    template = get_thermal_dispatch_template_network(NetworkModel(DCPNetworkModel))
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    log = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin(
        "1 Line components have a directional limit at or above the rating: 1",
        log,
    )
end

@testset "DC Power Flow Models Monitored Line Flow Constraints and Static Unbounded" begin
    system = PSB.build_system(PSITestSystems, "c_sys5_ml")
    limits = PSY.get_operational_flow_limit(PSY.get_component(Line, system, "1"), u"SU")
    for model in DC_NETWORK_MODELS_FOR_TESTING
        template = get_thermal_dispatch_template_network(
            NetworkModel(model),
        )
        set_device_model!(template, DeviceModel(Line, StaticBranchBounds))
        model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
        @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test check_variable_bounded(model_m, FlowActivePowerVariable, Line)

        @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        @test check_flow_variable_values(
            model_m,
            FlowActivePowerVariable,
            Line,
            "1",
            limits.from_to.max,
        )
    end
end

@testset "AC Power Flow Monitored Line Flow Constraints" begin
    system = PSB.build_system(PSITestSystems, "c_sys5_ml")
    limits = PSY.get_operational_flow_limit(PSY.get_component(Line, system, "1"), u"SU")
    template = get_thermal_dispatch_template_network(ACPNetworkModel)
    set_device_model!(template, DeviceModel(Line, StaticBranchBounds))
    model_m = DecisionModel(template, system; optimizer = ipopt_optimizer)
    @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    @test check_variable_bounded(model_m, FlowActivePowerFromToVariable, Line)
    @test check_variable_bounded(model_m, FlowReactivePowerFromToVariable, Line)

    @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test check_flow_variable_values(
        model_m,
        FlowActivePowerFromToVariable,
        FlowReactivePowerFromToVariable,
        Line,
        "1",
        0.0,
        limits.from_to.max,
    )
end

@testset "DC Power Flow Models Monitored Line Flow Constraints and Static with inequalities" begin
    system = PSB.build_system(PSITestSystems, "c_sys5_ml")
    set_rating!(PSY.get_component(Line, system, "2"), 1.5 * u"SU")
    for model in DC_NETWORK_MODELS_FOR_TESTING
        template = get_thermal_dispatch_template_network(
            NetworkModel(model),
        )
        set_device_model!(template, DeviceModel(Line, StaticBranch))
        model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
        @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT

        @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        @test check_flow_variable_values(model_m, FlowActivePowerVariable, Line, "2", 1.5)
    end
end

@testset "DC Power Flow Models Monitored Line Flow Constraints and Static with Bounds" begin
    system = PSB.build_system(PSITestSystems, "c_sys5_ml")
    set_rating!(PSY.get_component(Line, system, "2"), 1.5 * u"SU")
    for model in DC_NETWORK_MODELS_FOR_TESTING
        template = get_thermal_dispatch_template_network(NetworkModel(model))
        set_device_model!(template, DeviceModel(Line, StaticBranchBounds))
        model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
        @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT

        @test check_variable_bounded(model_m, FlowActivePowerVariable, Line)

        @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        @test check_flow_variable_values(model_m, FlowActivePowerVariable, Line, "2", 1.5)
    end

    # Test the addition of slacks
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, DeviceModel(Line, StaticBranchBounds; use_slacks = true))
    model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    @test check_variable_bounded(model_m, FlowActivePowerVariable, Line)
    @test !check_variable_bounded(model_m, FlowActivePowerSlackLowerBound, Line)
    @test !check_variable_bounded(model_m, FlowActivePowerSlackUpperBound, Line)

    @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

# Independent oracle: each end cap is the line rating, tightened by that end's rating.
function _hvdc_end_caps_su(hvdc)
    rating = PSY.get_rating(hvdc, u"SU")
    return (
        from = min(rating, PSY.get_rating_from(hvdc, u"SU")),
        to = min(rating, PSY.get_rating_to(hvdc, u"SU")),
    )
end

@testset "DC Power Flow Models for TwoTerminalGenericHVDCLine  with with Line Flow Constraints, TwoWindingTransformer Unbounded" begin
    ratelimit_constraint_keys = [
        IOM.ConstraintKey(FlowRateConstraint, TwoWindingTransformer, "ub"),
        IOM.ConstraintKey(FlowRateConstraint, TwoWindingTransformer, "lb"),
    ]

    system = PSB.build_system(PSITestSystems, "c_sys14_dc")
    hvdc_line = PSY.get_component(TwoTerminalGenericHVDCLine, system, "DCLine3")
    caps = _hvdc_end_caps_su(hvdc_line)
    limits_min = min(-caps.from, -caps.to)
    limits_max = min(caps.from, caps.to)

    tap_transformer = PSY.get_component(TwoWindingTransformer, system, "Trans3")
    rate_limit = _rating(tap_transformer)

    transformer = PSY.get_component(TwoWindingTransformer, system, "Trans4")
    rate_limit2w = _rating(transformer)

    for model in DC_NETWORK_MODELS_FOR_TESTING
        template = get_template_dispatch_with_network(
            NetworkModel(model),
        )
        set_device_model!(template, TwoTerminalGenericHVDCLine, HVDCTwoTerminalLossless)
        set_device_model!(template, DeviceModel(TwoWindingTransformer, StaticBranch))
        model_m = DecisionModel(template, system; optimizer = ipopt_optimizer)
        @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT

        psi_constraint_test(model_m, ratelimit_constraint_keys)

        @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

        @test check_flow_variable_values(
            model_m,
            FlowActivePowerVariable,
            TwoTerminalGenericHVDCLine,
            "DCLine3",
            limits_min,
            limits_max,
        )
        @test check_flow_variable_values(
            model_m,
            FlowActivePowerVariable,
            TwoWindingTransformer,
            "Trans3",
            -rate_limit,
            rate_limit,
        )
        @test check_flow_variable_values(
            model_m,
            FlowActivePowerVariable,
            TwoWindingTransformer,
            "Trans4",
            -rate_limit2w,
            rate_limit2w,
        )
    end
end

@testset "DC Power Flow Models for Unbounded TwoTerminalGenericHVDCLine , and StaticBranchBounds for TwoWindingTransformer" begin
    system = PSB.build_system(PSITestSystems, "c_sys14_dc")
    hvdc_line = PSY.get_component(TwoTerminalGenericHVDCLine, system, "DCLine3")
    caps = _hvdc_end_caps_su(hvdc_line)
    limits_min = min(-caps.from, -caps.to)
    limits_max = min(caps.from, caps.to)

    tap_transformer = PSY.get_component(TwoWindingTransformer, system, "Trans3")
    rate_limit = _rating(tap_transformer)

    transformer = PSY.get_component(TwoWindingTransformer, system, "Trans4")
    rate_limit2w = _rating(transformer)

    for model in DC_NETWORK_MODELS_FOR_TESTING
        template = get_template_dispatch_with_network(
            NetworkModel(model),
        )
        set_device_model!(
            template,
            DeviceModel(TwoTerminalGenericHVDCLine, HVDCTwoTerminalUnbounded),
        )
        set_device_model!(template, DeviceModel(TwoWindingTransformer, StaticBranchBounds))
        model_m = DecisionModel(template, system; optimizer = ipopt_optimizer)
        @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT

        @test check_variable_unbounded(
            model_m,
            FlowActivePowerVariable,
            TwoTerminalGenericHVDCLine,
        )
        @test check_variable_bounded(
            model_m,
            FlowActivePowerVariable,
            TwoWindingTransformer,
        )

        @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

        @test check_flow_variable_values(
            model_m,
            FlowActivePowerVariable,
            TwoTerminalGenericHVDCLine,
            "DCLine3",
            limits_min,
            limits_max,
        )
        @test check_flow_variable_values(
            model_m,
            FlowActivePowerVariable,
            TwoWindingTransformer,
            "Trans3",
            -rate_limit,
            rate_limit,
        )
        @test check_flow_variable_values(
            model_m,
            FlowActivePowerVariable,
            TwoWindingTransformer,
            "Trans4",
            -rate_limit2w,
            rate_limit2w,
        )
    end
end

@testset "HVDCTwoTerminalLossless values check between network models" begin
    # Test to compare lossless models with lossless formulation
    sys_5 = build_system(PSITestSystems, "c_sys5_uc")

    line = get_component(Line, sys_5, "1")
    remove_component!(sys_5, line)

    hvdc = TwoTerminalGenericHVDCLine(;
        name = get_name(line),
        available = true,
        active_power_flow = 0.0,
        rating = 3.0,
        rating_from = 0.5,
        rating_to = 3.0,
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        arc = get_arc(line),
        loss = PSY.LossCurve(LinearCurve(0.0), PSY.CU),
        input_basis = u"CU",
    )

    add_component!(sys_5, hvdc)
    # Congest nodeA -> nodeE so every hour pushes the HVDC to its `from` cap, nodeB ->
    # nodeA. A binding cap gives one optimal flow, so both networks must return it.
    set_rating!(get_component(Line, sys_5, "3"), 0.5 * u"SU")
    expected_flow = -PSY.get_rating_from(hvdc, u"NU")

    template_uc = PowerOperationsProblemTemplate(
        NetworkModel(PTDFNetworkModel),
    )

    set_device_model!(template_uc, ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template_uc, RenewableDispatch, FixedOutput)
    set_device_model!(template_uc, PowerLoad, StaticPowerLoad)
    set_device_model!(template_uc, DeviceModel(Line, StaticBranch))
    set_device_model!(
        template_uc,
        DeviceModel(TwoTerminalGenericHVDCLine, HVDCTwoTerminalLossless),
    )

    model = DecisionModel(
        template_uc,
        sys_5;
        name = "UC",
        optimizer = HiGHS_optimizer,
    )
    build!(model; output_dir = mktempdir())

    solve!(model)

    ptdf_vars =
        read_variables(OptimizationProblemOutputs(model); table_format = TableFormat.WIDE)
    ptdf_values = ptdf_vars["FlowActivePowerVariable__TwoTerminalGenericHVDCLine"]
    ptdf_objective = IOM.get_optimization_container(model).optimizer_stats.objective_value

    set_network_model!(template_uc, NetworkModel(DCPNetworkModel))
    model = DecisionModel(
        template_uc,
        sys_5;
        name = "UC",
        optimizer = HiGHS_optimizer,
    )
    solve!(model; output_dir = mktempdir())
    dcp_vars =
        read_variables(OptimizationProblemOutputs(model); table_format = TableFormat.WIDE)
    dcp_values = dcp_vars["FlowActivePowerVariable__TwoTerminalGenericHVDCLine"]
    dcp_objective =
        IOM.get_optimization_container(model).optimizer_stats.objective_value
    @test isapprox(dcp_objective, ptdf_objective; atol = 0.1)
    @test all(isapprox.(ptdf_values[!, "1"], expected_flow; atol = 1e-3))
    @test all(isapprox.(dcp_values[!, "1"], expected_flow; atol = 1e-3))
end

@testset "HVDCDispatch Model Tests" begin
    # Test to compare lossless models with lossless formulation
    sys_5 = build_system(PSITestSystems, "c_sys5_uc")
    # Revert to previous rating before data change to prevent different optimal solutions for the lossless model and lossless formulation:
    PSY.set_rating!(PSY.get_component(PSY.Line, sys_5, "6"), 2.0 * u"SU")

    line = get_component(Line, sys_5, "1")
    remove_component!(sys_5, line)

    hvdc = TwoTerminalGenericHVDCLine(;
        name = get_name(line),
        available = true,
        active_power_flow = 0.0,
        rating = 2.0,
        rating_from = 2.0,
        rating_to = 2.0,
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        arc = get_arc(line),
        loss = PSY.LossCurve(LinearCurve(0.0), PSY.CU),
        input_basis = u"CU",
    )

    add_component!(sys_5, hvdc)
    for net_model in DC_NETWORK_MODELS_FOR_TESTING
        @testset "$net_model" begin
            PSY.set_loss!(hvdc, PSY.LossCurve(PSY.LinearCurve(0.0), PSY.CU))
            template_uc = PowerOperationsProblemTemplate(
                NetworkModel(net_model; use_slacks = true),
            )

            set_device_model!(template_uc, ThermalStandard, ThermalBasicUnitCommitment)
            set_device_model!(template_uc, RenewableDispatch, FixedOutput)
            set_device_model!(template_uc, PowerLoad, StaticPowerLoad)
            set_device_model!(template_uc, DeviceModel(Line, StaticBranchBounds))
            set_device_model!(
                template_uc,
                DeviceModel(TwoTerminalGenericHVDCLine, HVDCTwoTerminalLossless),
            )

            model_ref = DecisionModel(
                template_uc,
                sys_5;
                name = "UC",
                optimizer = HiGHS_optimizer,
                store_variable_names = true,
            )

            solve!(model_ref; output_dir = mktempdir())
            ref_vars = read_variables(
                OptimizationProblemOutputs(model_ref);
                table_format = TableFormat.WIDE,
            )
            ref_values = ref_vars["FlowActivePowerVariable__Line"]
            hvdc_ref_values =
                ref_vars["FlowActivePowerVariable__TwoTerminalGenericHVDCLine"]
            ref_objective = model_ref.internal.container.optimizer_stats.objective_value
            ref_total_gen = sum(
                sum.(
                    eachrow(
                        DataFrames.select(
                            ref_vars["ActivePowerVariable__ThermalStandard"],
                            Not(:DateTime),
                        ),
                    )
                ),
            )
            set_device_model!(
                template_uc,
                DeviceModel(TwoTerminalGenericHVDCLine, HVDCTwoTerminalDispatch),
            )

            model = DecisionModel(
                template_uc,
                sys_5;
                name = "UC",
                optimizer = HiGHS_optimizer,
            )

            solve!(model; output_dir = mktempdir())
            no_loss_vars = read_variables(
                OptimizationProblemOutputs(model);
                table_format = TableFormat.WIDE,
            )
            no_loss_values = no_loss_vars["FlowActivePowerVariable__Line"]
            hvdc_ft_no_loss_values =
                no_loss_vars["FlowActivePowerFromToVariable__TwoTerminalGenericHVDCLine"]
            hvdc_tf_no_loss_values =
                no_loss_vars["FlowActivePowerToFromVariable__TwoTerminalGenericHVDCLine"]
            no_loss_objective =
                IOM.get_optimization_container(model).optimizer_stats.objective_value
            no_loss_total_gen = sum(
                sum.(
                    eachrow(
                        DataFrames.select(
                            no_loss_vars["ActivePowerVariable__ThermalStandard"],
                            Not(:DateTime),
                        ),
                    ),
                ),
            )

            @test isapprox(no_loss_objective, ref_objective; atol = 0.1)

            for col in names(ref_values)
                if typeof(ref_values[1, col]) == DateTime
                    continue
                end
                test_result =
                    all(isapprox.(ref_values[!, col], no_loss_values[!, col]; atol = 0.1))
                @test test_result
                test_result || break
            end

            @test all(
                isapprox.(
                    hvdc_ft_no_loss_values[!, "1"],
                    -hvdc_tf_no_loss_values[!, "1"];
                    atol = 1e-3,
                ),
            )

            @test isapprox(no_loss_total_gen, ref_total_gen; atol = 0.1)

            PSY.set_loss!(hvdc, PSY.LossCurve(PSY.LinearCurve(0.005, 0.1), PSY.CU))

            model_wl = DecisionModel(
                template_uc,
                sys_5;
                name = "UC",
                optimizer = HiGHS_optimizer,
            )

            solve!(model_wl; output_dir = mktempdir())
            dispatch_vars = read_variables(
                OptimizationProblemOutputs(model_wl);
                table_format = TableFormat.WIDE,
            )
            dispatch_values_ft =
                dispatch_vars["FlowActivePowerFromToVariable__TwoTerminalGenericHVDCLine"]
            dispatch_values_tf =
                dispatch_vars["FlowActivePowerToFromVariable__TwoTerminalGenericHVDCLine"]
            wl_total_gen = sum(
                sum.(
                    eachrow(
                        DataFrames.select(
                            dispatch_vars["ActivePowerVariable__ThermalStandard"],
                            Not(:DateTime),
                        ),
                    ),
                ),
            )
            dispatch_objective = model_wl.internal.container.optimizer_stats.objective_value

            # Note: for this test data the system does better by allowing more losses so
            # the total cost is lower.
            @test wl_total_gen > no_loss_total_gen

            for col in names(dispatch_values_tf)
                test_result = all(dispatch_values_tf[!, col] .<= dispatch_values_ft[!, col])
                @test test_result
                test_result || break
            end
        end
    end
end

@testset "DC Power Flow Models for TwoTerminalGenericHVDCLine  Dispatch and TwoWindingTransformer Unbounded" begin
    ratelimit_constraint_keys = [
        IOM.ConstraintKey(FlowRateConstraint, Line, "ub"),
        IOM.ConstraintKey(FlowRateConstraint, Line, "lb"),
        IOM.ConstraintKey(FlowRateConstraint, TwoWindingTransformer, "ub"),
        IOM.ConstraintKey(FlowRateConstraint, TwoWindingTransformer, "lb"),
        IOM.ConstraintKey(FlowRateConstraint, TwoTerminalGenericHVDCLine, "ub"),
        IOM.ConstraintKey(FlowRateConstraint, TwoTerminalGenericHVDCLine, "lb"),
    ]

    system = PSB.build_system(PSITestSystems, "c_sys14_dc")

    hvdc_line = PSY.get_component(TwoTerminalGenericHVDCLine, system, "DCLine3")
    caps = _hvdc_end_caps_su(hvdc_line)
    limits_min = min(-caps.from, -caps.to)
    limits_max = min(caps.from, caps.to)

    tap_transformer = PSY.get_component(TwoWindingTransformer, system, "Trans3")
    rate_limit = _rating(tap_transformer)

    transformer = PSY.get_component(TwoWindingTransformer, system, "Trans4")
    rate_limit2w = _rating(transformer)

    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel),
    )
    set_device_model!(template, DeviceModel(TwoWindingTransformer, StaticBranch))
    set_device_model!(
        template,
        DeviceModel(TwoTerminalGenericHVDCLine, HVDCTwoTerminalLossless),
    )
    model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    psi_constraint_test(model_m, ratelimit_constraint_keys)

    @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    @test check_flow_variable_values(
        model_m,
        FlowActivePowerVariable,
        TwoTerminalGenericHVDCLine,
        "DCLine3",
        limits_max,
    )
    @test check_flow_variable_values(
        model_m,
        FlowActivePowerVariable,
        TwoWindingTransformer,
        "Trans3",
        rate_limit,
    )
    @test check_flow_variable_values(
        model_m,
        FlowActivePowerVariable,
        TwoWindingTransformer,
        "Trans4",
        rate_limit2w,
    )
end

@testset "DC Power Flow Models for phase-shifting TwoWindingTransformer and Line" begin
    #     system = build_system(PSITestSystems, "c_sys5_uc")
    #
    #     line = get_component(Line, system, "1")
    #
    #     ps = TwoWindingTransformer(;
    #         name = get_name(line),
    #         available = true,
    #         active_power_flow = 0.0,
    #         reactive_power_flow = 0.0,
    #         r = get_r(line, u"SU"),
    #         x = get_r(line, u"SU"),
    #         primary_shunt = 0.0,
    #         tap = 1.0,
    #         α = 0.0,
    #         rating = get_rating(line, u"SU"),
    #         arc = get_arc(line),
    #         base_power = get_base_power(system, u"NU"),
    #     )
    #
    #     add_component!(system, ps)
    #     remove_component!(system, line)
    #
    #     template = get_template_dispatch_with_network(
    #         NetworkModel(PTDFNetworkModel),
    #     )
    #     set_device_model!(template, DeviceModel(TwoWindingTransformer, PhaseAngleControl))
    #     model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    #     @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
    #           IOM.ModelBuildStatus.BUILT
    #
    #     @test check_variable_unbounded(
    #         model_m,
    #         FlowActivePowerVariable,
    #         TwoWindingTransformer,
    #     )
    #
    #     @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    #
    #     @test check_flow_variable_values(
    #         model_m,
    #         FlowActivePowerVariable,
    #         TwoWindingTransformer,
    #         "1",
    #         get_rating(ps, u"SU"),
    #     )
    #
    #     @test check_flow_variable_values(
    #         model_m,
    #         PhaseShifterAngle,
    #         TwoWindingTransformer,
    #         "1",
    #         -π / 2,
    #         π / 2,
    #     )
end

@testset "AC Power Flow Models for TwoTerminalGenericHVDCLine  Flow Constraints and TwoWindingTransformer Unbounded" begin
    ratelimit_constraint_keys = [
        IOM.ConstraintKey(FlowRateConstraintFromTo, TwoWindingTransformer),
        IOM.ConstraintKey(FlowRateConstraintToFrom, TwoWindingTransformer),
        IOM.ConstraintKey(FlowRateConstraint, TwoTerminalGenericHVDCLine, "ub"),
        IOM.ConstraintKey(FlowRateConstraint, TwoTerminalGenericHVDCLine, "lb"),
    ]

    system = PSB.build_system(PSITestSystems, "c_sys14_dc")

    hvdc_line = PSY.get_component(TwoTerminalGenericHVDCLine, system, "DCLine3")
    caps = _hvdc_end_caps_su(hvdc_line)
    limits_min = min(-caps.from, -caps.to)
    limits_max = min(caps.from, caps.to)

    tap_transformer = PSY.get_component(TwoWindingTransformer, system, "Trans3")
    rate_limit = _rating(tap_transformer)

    transformer = PSY.get_component(TwoWindingTransformer, system, "Trans4")
    rate_limit2w = _rating(transformer)

    template = get_template_dispatch_with_network(ACPNetworkModel)
    set_device_model!(template, TwoWindingTransformer, StaticBranchBounds)
    set_device_model!(
        template,
        DeviceModel(TwoTerminalGenericHVDCLine, HVDCTwoTerminalLossless),
    )
    model_m = DecisionModel(template, system; optimizer = ipopt_optimizer)
    @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test check_variable_bounded(
        model_m,
        FlowActivePowerFromToVariable,
        TwoWindingTransformer,
    )
    @test check_variable_bounded(
        model_m,
        FlowReactivePowerFromToVariable,
        TwoWindingTransformer,
    )
    @test check_variable_bounded(
        model_m,
        FlowActivePowerToFromVariable,
        TwoWindingTransformer,
    )
    @test check_variable_bounded(
        model_m,
        FlowReactivePowerToFromVariable,
        TwoWindingTransformer,
    )

    psi_constraint_test(model_m, ratelimit_constraint_keys)

    @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    @test check_flow_variable_values(
        model_m,
        FlowActivePowerVariable,
        FlowReactivePowerToFromVariable,
        TwoTerminalGenericHVDCLine,
        "DCLine3",
        limits_max,
    )
    @test check_flow_variable_values(
        model_m,
        FlowActivePowerFromToVariable,
        FlowReactivePowerFromToVariable,
        TwoWindingTransformer,
        "Trans3",
        rate_limit,
    )
    @test check_flow_variable_values(
        model_m,
        FlowActivePowerToFromVariable,
        FlowReactivePowerToFromVariable,
        TwoWindingTransformer,
        "Trans4",
        rate_limit2w,
    )
end

@testset "Test Line and Monitored Line models with slacks" begin
    system = PSB.build_system(PSITestSystems, "c_sys5_ml")
    # This rating (0.247479) was previously inferred in PSY.check_component after setting the rating to 0.0 in the tests
    set_rating!(PSY.get_component(Line, system, "2"), 0.247479 * u"SU")
    for (model, optimizer) in NETWORKS_FOR_TESTING
        # CopperPlate no-ops branch construction, so slack variables won't exist
        model == CopperPlateNetworkModel && continue
        template = get_thermal_dispatch_template_network(
            NetworkModel(model; use_slacks = true),
        )
        set_device_model!(template, DeviceModel(Line, StaticBranch; use_slacks = true))
        model_m = DecisionModel(template, system; optimizer = optimizer)
        @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        outputs = OptimizationProblemOutputs(model_m)
        vars = read_variable(
            outputs,
            "FlowActivePowerSlackUpperBound__Line";
            table_format = TableFormat.WIDE,
        )
        # some relaxations will find a solution with 0.0 slack
        @test sum(vars[!, "2"]) >= -1e-6
    end

    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; use_slacks = true),
    )
    set_device_model!(template, DeviceModel(Line, StaticBranchBounds; use_slacks = true))
    model_m = DecisionModel(template, system; optimizer = fast_ipopt_optimizer)
    @test build!(
        model_m;
        console_level = Logging.AboveMaxLevel,
        output_dir = mktempdir(; cleanup = true),
    ) == IOM.ModelBuildStatus.BUILT

    @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    outputs = OptimizationProblemOutputs(model_m)
    vars = read_variable(
        outputs,
        "FlowActivePowerSlackUpperBound__Line";
        table_format = TableFormat.WIDE,
    )
    # some relaxations will find a solution with 0.0 slack
    @test sum(vars[!, "2"]) >= -1e-6

    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; use_slacks = true),
    )
    set_device_model!(template, DeviceModel(Line, StaticBranch; use_slacks = true))
    model_m = DecisionModel(template, system; optimizer = fast_ipopt_optimizer)
    @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    outputs = OptimizationProblemOutputs(model_m)
    vars = read_variable(
        outputs,
        "FlowActivePowerSlackUpperBound__Line";
        table_format = TableFormat.WIDE,
    )
    # some relaxations will find a solution with 0.0 slack
    @test sum(vars[!, "2"]) >= -1e-6
end

@testset "Three Winding Transformer Test - Basic Setup and Model" begin
    # Start with the base system
    system = PSB.build_system(PSITestSystems, "c_sys5_ml")
    busD = PSY.get_component(ACBus, system, "nodeD")
    # Create a new bus for the tertiary winding (connected via transformer to Bus 4)
    new_bus1 = ACBus(;
        input_basis = u"CU",
        number = 101,
        name = "Bus3WT_1",
        available = true,
        bustype = ACBusTypes.PQ,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.95, max = 1.05),
        base_voltage = 230.0,
        area = PSY.get_area(busD),
        load_zone = PSY.get_load_zone(busD),
    )
    PSY.add_component!(system, new_bus1)

    new_bus2 = ACBus(;
        input_basis = u"CU",
        number = 102,
        name = "Bus3WT_2",
        available = true,
        bustype = ACBusTypes.PQ,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.95, max = 1.05),
        base_voltage = 230.0,
        area = PSY.get_area(busD),
        load_zone = PSY.get_load_zone(busD),
    )
    PSY.add_component!(system, new_bus2)

    # Add a new load at the new bus
    new_load = PowerLoad(;
        name = "Load_Bus3WT",
        available = true,
        bus = new_bus1,
        active_power = 0.5,
        reactive_power = 0.1,
        base_power = 100.0,
        max_active_power = 0.5,
        max_reactive_power = 0.1,
        input_basis = u"CU",
    )
    PSY.add_component!(system, new_load)

    # Add a new generator at the new bus to provide power
    new_gen = ThermalStandard(;
        name = "Gen_Bus100",
        available = true,
        status = PSY.OperationalStates.ONLINE,
        bus = new_bus2,
        active_power = 0.4,
        reactive_power = 0.0,
        rating = 0.5,
        prime_mover_type = PrimeMovers.ST,
        fuel = ThermalFuels.COAL,
        active_power_limits = (min = 0.0, max = 0.5),
        reactive_power_limits = (min = -0.3, max = 0.3),
        ramp_limits = (up = 0.5, down = 0.5),
        operation_cost = ThermalGenerationCost(;
            variable_operation_cost = CostCurve(LinearCurve(0.0)),
            start_up = 0.0,
            shut_down = 0.0,
            fixed = 0.0,
        ),
        base_power = 100.0,
        time_limits = nothing,
        input_basis = u"CU",
    )
    PSY.add_component!(system, new_gen)

    # Create a star bus for the ThreeWindingTransformer
    star_bus = ACBus(;
        input_basis = u"CU",
        number = 103,
        name = "Star_Bus_T3W",
        available = true,
        bustype = ACBusTypes.PQ,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.95, max = 1.05),
        base_voltage = 230.0,
        area = PSY.get_area(busD),
        load_zone = PSY.get_load_zone(busD),
    )
    PSY.add_component!(system, star_bus)

    # Each circuit carries its own terminal-to-star arc, star-leg impedance and rating.
    transformer3w = PSY.ThreeWindingTransformer(;
        name = "ThreeWindingTransformer_busD",
        primary_circuit = PSY.TransformerCircuit(;
            available = true,
            arc = Arc(; from = busD, to = star_bus),
            r = 0.01,
            x = 0.1,
            rating = 1.0,
            base_power = 100.0,
            input_basis = u"CU",
        ),
        secondary_circuit = PSY.TransformerCircuit(;
            available = true,
            arc = Arc(; from = new_bus1, to = star_bus),
            r = 0.01,
            x = 0.1,
            rating = 1.0,
            base_power = 100.0,
            input_basis = u"CU",
        ),
        tertiary_circuit = PSY.TransformerCircuit(;
            available = true,
            arc = Arc(; from = new_bus2, to = star_bus),
            r = 0.01,
            x = 0.1,
            rating = 0.5,
            base_power = 100.0,
            input_basis = u"CU",
        ),
        star_bus = star_bus,
        input_basis = u"CU",
    )
    PSY.add_component!(system, transformer3w)

    # Add ThreeWindingTransformer device model when available
    # Test with DC Power Flow Model
    for net_model in DC_NETWORK_MODELS_FOR_TESTING
        template = get_template_dispatch_with_network(
            NetworkModel(net_model),
        )
        # Set device model for ThreeWindingTransformer
        set_device_model!(template, DeviceModel(ThreeWindingTransformer, StaticBranch))

        model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
        @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT

        @test solve!(model_m) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

        # Test flow constraints
        transformer = PSY.get_component(
            ThreeWindingTransformer,
            system,
            "ThreeWindingTransformer_busD",
        )
        @test check_flow_variable_values(
            model_m,
            FlowActivePowerVariable,
            ThreeWindingTransformer,
            "ThreeWindingTransformer_busD_winding_3",
            PSY.get_rating(PSY.get_tertiary_circuit(transformer), u"SU"),
        )
    end

    template_ac = get_thermal_dispatch_template_network(ACPNetworkModel)
    set_device_model!(template_ac, DeviceModel(ThreeWindingTransformer, StaticBranch))
    model_ac = DecisionModel(template_ac, system; optimizer = ipopt_optimizer)
    @test build!(model_ac; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model_ac) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

# A bus is "merged away" by the reduction when it appears in a value set of the bus
# reduction map (coalesced into a representative key). The retained representatives
# are the keys; `get_removed_buses` is unrelated to zero-impedance coalescing here.
_bus_merged_away(nrd, b) = any(b in s for s in values(PNM.get_bus_reduction_map(nrd)))

@testset "model_all_branches retains a zero-impedance Line" begin
    function _build_zib_line(model_all_branches)
        sys = PSB.build_system(PSITestSystems, "c_sys5_ml")
        line = PSY.get_component(Line, sys, "1")
        PSY.set_r!(line, 0.0 * u"SU")
        PSY.set_x!(line, 1e-5 * u"SU")
        template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
        set_device_model!(
            template,
            DeviceModel(
                Line,
                StaticBranch;
                attributes = Dict{String, Any}("model_all_branches" => model_all_branches),
            ),
        )
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        status = build!(model; output_dir = mktempdir(; cleanup = true))
        return model, line, status
    end

    for T in (Line, TwoWindingTransformer, ThreeWindingTransformer)
        @test POM.get_attribute(DeviceModel(T, StaticBranch), "model_all_branches") == false
        @test POM.get_attribute(
            DeviceModel(T, StaticBranch), "apply_operational_flow_limits",
        ) == true
    end
    @test POM.get_attribute(
        DeviceModel(TwoTerminalGenericHVDCLine, HVDCTwoTerminalDispatch),
        "apply_operational_flow_limits",
    ) == true
    @test isnothing(
        POM.get_attribute(
            DeviceModel(DiscreteControlledACBranch, StaticBranch), "model_all_branches",
        ),
    )

    model, line, status = _build_zib_line(true)
    @test status == IOM.ModelBuildStatus.BUILT
    arc = PSY.get_arc(line)
    nm = IOM.get_network_model(IOM.get_template(model))
    nrd = PNM.get_network_reduction_data(IOM.get_network_matrix(nm))
    @test !_bus_merged_away(nrd, PSY.get_number(PSY.get_from(arc)))
    @test !_bus_merged_away(nrd, PSY.get_number(PSY.get_to(arc)))
    container = IOM.get_optimization_container(model)
    rows = axes(IOM.get_constraint(container, FlowRateConstraint, Line, "ub"))[1]
    @test "1" in rows

    model_d, line_d, status_d = _build_zib_line(false)
    @test status_d == IOM.ModelBuildStatus.BUILT
    nm_d = IOM.get_network_model(IOM.get_template(model_d))
    nrd_d = PNM.get_network_reduction_data(IOM.get_network_matrix(nm_d))
    @test _bus_merged_away(nrd_d, PSY.get_number(PSY.get_to(PSY.get_arc(line_d))))
end

@testset "Partial reduction warns and names the reduced Line" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_ml")
    line = PSY.get_component(Line, sys, "1")
    PSY.set_r!(line, 0.0 * u"SU")
    PSY.set_x!(line, 1e-5 * u"SU")
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    rows = axes(IOM.get_constraint(container, FlowRateConstraint, Line, "ub"))[1]
    @test !("1" in rows)
    log_contents = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("Line component(s) [\"1\"]", log_contents)
    @test occursin("model_all_branches", log_contents)
end

@testset "model_all_branches pins every winding of a ThreeWindingTransformer" begin
    sys = _sys5_with_3w()
    t3w = first(PSY.get_components(ThreeWindingTransformer, sys))
    buses = Set{Int}()
    POM._push_component_buses!(buses, t3w)
    for circuit in PSY.get_circuits(t3w)
        arc = PSY.get_arc(circuit)
        @test PSY.get_number(PSY.get_from(arc)) in buses
        @test PSY.get_number(PSY.get_to(arc)) in buses
    end
end

# Guards the system-base assumption behind `branch_rating`/`min_max_flow_limits`
# (AC_branches.jl): POM consumes the PNM rating aggregators as system-base values, while
# `PNM.get_equivalent_rating` reads the device-base (`u"CU"`) rating leaf. For AC branches
# device base equals system base, so the two agree; this locks that invariant so a future
# PSY change introducing a per-branch base surfaces here instead of silently mis-bounding
# branch flows against the system-base `FlowActivePowerVariable` bounds.
@testset "PNM rating aggregators are system base (branch_rating invariant)" begin
    for sysname in ("c_sys5", "c_sys14")
        system = PSB.build_system(PSITestSystems, sysname)
        for branch in PSY.get_components(PSY.ACTransmission, system)
            @test PNM.get_equivalent_rating(branch) == _rating(branch)
        end
    end
end

# Ground-truth for the extracted apparent-power rate-limit RHS math
# (`POM._rate_rhs_squared`). This is the shipped-bug guard: an apparent-power
# constraint `p² + q² ≤ RHS` needs `RHS = rating²`, not a bare `rating`. Locking the
# pure math plus a built-model sample (static and time-series paths) ties every routed
# `@constraint` site to the same hand-checked exponent.
@testset "Apparent-power rate-limit RHS builder (_rate_rhs_squared)" begin
    # --- Pure math: hand-computed ---
    @test POM._rate_rhs_squared(2.0) == 4.0
    @test POM._rate_rhs_squared(0.0) == 0.0
    @test POM._rate_rhs_squared(1.5) == 2.25
    # Time-series path RHS = (param_value * multiplier)²; a product squared.
    param_value = 1.2
    mult = 0.9
    @test POM._rate_rhs_squared(param_value * mult) == (param_value * mult)^2
    @test POM._rate_rhs_squared(param_value * mult) ≈ 1.1664

    # --- Built model, STATIC path: sampled FromTo/ToFrom RHS == builder output ---
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    ac_ft = IOM.get_constraint(container, IOM.ConstraintKey(FlowRateConstraintFromTo, Line))
    ac_tf = IOM.get_constraint(container, IOM.ConstraintKey(FlowRateConstraintToFrom, Line))
    for name in axes(ac_ft, 1)
        line = get_component(Line, sys, name)
        expected = POM._rate_rhs_squared(PSY.get_rating(line, u"SU"))
        for t in axes(ac_ft, 2)
            @test isapprox(JuMP.normalized_rhs(ac_ft[name, t]), expected; rtol = 1e-8)
            @test isapprox(JuMP.normalized_rhs(ac_tf[name, t]), expected; rtol = 1e-8)
        end
    end

    # --- Built model, TIME-SERIES path: sampled RHS == builder(param * mult) ---
    sys_ts = PSB.build_system(PSITestSystems, "c_sys5")
    branches_with_rating_ts = ["1", "2", "6"]
    rating_factors = vcat([fill(x, 6) for x in [0.99, 0.98, 1.0, 0.95]]...)
    add_branch_rating_time_series_to_system!(
        sys_ts,
        branches_with_rating_ts,
        2,
        rating_factors;
        initial_date = "2024-01-01",
    )
    template_ts = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    set_device_model!(
        template_ts,
        DeviceModel(
            Line,
            StaticBranch;
            time_series_names = Dict(BranchRatingTimeSeriesParameter => "branch_rating"),
        ),
    )
    model_ts = DecisionModel(template_ts, sys_ts; optimizer = ipopt_optimizer)
    @test build!(model_ts; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container_ts = IOM.get_optimization_container(model_ts)
    @test IOM.has_container_key(container_ts, BranchRatingTimeSeriesParameter, Line)
    ac_ft_ts =
        IOM.get_constraint(container_ts, IOM.ConstraintKey(FlowRateConstraintFromTo, Line))
    # TS RHS = builder(rating * rating_factor[t]); `param * mult` = static_rating *
    # rating_factor, so the builder output must equal the sampled squared RHS.
    n_rating = length(rating_factors)
    for name in branches_with_rating_ts
        static_rating = PSY.get_rating(get_component(Line, sys_ts, name), u"SU")
        for (i, t) in enumerate(axes(ac_ft_ts, 2))
            rating_t = static_rating * rating_factors[mod1(i, n_rating)]
            expected = POM._rate_rhs_squared(rating_t)
            @test isapprox(JuMP.normalized_rhs(ac_ft_ts[name, t]), expected; rtol = 1e-6)
        end
    end
    # RHS must actually vary with the time series (factors cross a boundary at t=7).
    @test !isapprox(
        JuMP.normalized_rhs(ac_ft_ts[first(branches_with_rating_ts), 1]),
        JuMP.normalized_rhs(ac_ft_ts[first(branches_with_rating_ts), 7]);
        atol = 1e-6,
    )
end
