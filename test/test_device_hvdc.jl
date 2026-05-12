@testset "HVDC System Tests" begin
    sys_5 = build_system(PSISystems, "sys10_pjm_ac_dc")
    template_uc = OperationsProblemTemplate(NetworkModel(
        DCPPowerModel,
        #use_slacks=true,
        #PTDF_matrix=PTDF(sys_5),
        #duals=[CopperPlateBalanceConstraint],
    ))

    set_device_model!(template_uc, ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template_uc, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template_uc, PowerLoad, StaticPowerLoad)
    set_device_model!(template_uc, DeviceModel(Line, StaticBranch))
    set_device_model!(template_uc, DeviceModel(InterconnectingConverter, LosslessConverter))
    set_device_model!(template_uc, DeviceModel(TModelHVDCLine, LosslessLine))
    set_hvdc_network_model!(template_uc, TransportHVDCNetworkModel)
    model = DecisionModel(template_uc, sys_5; name = "UC", optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
    moi_tests(model, 1656, 288, 1248, 528, 888, true)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    template_uc = OperationsProblemTemplate(NetworkModel(
        PTDFPowerModel;
        #use_slacks=true,
        PTDF_matrix = PTDF(sys_5),
        #duals=[CopperPlateBalanceConstraint],
    ))

    set_device_model!(template_uc, ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template_uc, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template_uc, PowerLoad, StaticPowerLoad)
    set_device_model!(template_uc, DeviceModel(Line, StaticBranch))
    set_device_model!(template_uc, DeviceModel(InterconnectingConverter, LosslessConverter))
    set_device_model!(template_uc, DeviceModel(TModelHVDCLine, LosslessLine))
    set_hvdc_network_model!(template_uc, TransportHVDCNetworkModel)
    model = DecisionModel(template_uc, sys_5; name = "UC", optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
    moi_tests(model, 1128, 0, 1248, 528, 384, true)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

function _generate_test_hvdc_sys()
    sys = build_system(PSISystems, "sys10_pjm_ac_dc"; force_build = true)
    th_names_2 = ["Alta-2", "Sundance-2", "Park City-2", "Solitude-2", "Brighton-2"]
    for th_name in th_names_2
        g = PSY.get_component(PSY.ThermalStandard, sys, th_name)
        op_cost = g.operation_cost
        val_curve = op_cost.variable.value_curve
        new_prop_term = get_proportional_term(val_curve) * 2.0
        if g.name == "Park City-2"
            new_prop_term = new_prop_term + 5.0
        end
        new_quad_cost = QuadraticCurve(
            get_quadratic_term(val_curve),
            new_prop_term,
            get_constant_term(val_curve),
        )
        new_op_cost = ThermalGenerationCost(
            CostCurve(
                new_quad_cost,
                op_cost.variable.power_units,
                op_cost.variable.vom_cost,
            ),
            op_cost.fixed,
            op_cost.start_up,
            op_cost.shut_down,
        )
        set_operation_cost!(g, new_op_cost)
    end

    for ipc in get_components(InterconnectingConverter, sys)
        new_dc_loss = QuadraticCurve(0.01, 0.01, 0.0)
        set_loss_function!(ipc, new_dc_loss)
        set_max_dc_current!(ipc, 2.0)
    end
    return sys
end

@testset "HVDC System with Transport Network" begin
    sys = _generate_test_hvdc_sys()
    template = OperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, TModelHVDCLine, LosslessLine)
    set_device_model!(template, InterconnectingConverter, LosslessConverter)
    set_hvdc_network_model!(template, TransportHVDCNetworkModel)
    model =
        DecisionModel(
            template,
            sys;
            store_variable_names = true,
            optimizer = HiGHS_optimizer,
        )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "HVDC System with Losses Network (Bin2QuadraticLossConverter)" begin
    sys = _generate_test_hvdc_sys()
    template = OperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, TModelHVDCLine, DCLossyLine)
    ipc_model = DeviceModel(
        InterconnectingConverter,
        Bin2QuadraticLossConverter,
    )
    set_device_model!(template, ipc_model)
    set_hvdc_network_model!(template, VoltageDispatchHVDCNetworkModel)
    model =
        DecisionModel(
            template,
            sys;
            store_variable_names = true,
            optimizer = HiGHS_optimizer,
        )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "HVDC System with Losses Network (QuadraticLossConverter NLP)" begin
    sys = _generate_test_hvdc_sys()
    template = OperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, TModelHVDCLine, DCLossyLine)
    ipc_model = DeviceModel(
        InterconnectingConverter,
        QuadraticLossConverter,
    )
    set_device_model!(template, ipc_model)
    set_hvdc_network_model!(template, VoltageDispatchHVDCNetworkModel)
    model =
        DecisionModel(
            template,
            sys;
            store_variable_names = true,
            optimizer = ipopt_optimizer,
        )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "HVDC Bin2 vs NLP QuadraticLossConverter agreement" begin
    function _build_and_solve(formulation, optimizer)
        sys = _generate_test_hvdc_sys()
        template = OperationsProblemTemplate()
        set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
        set_device_model!(template, PowerLoad, StaticPowerLoad)
        set_device_model!(template, DeviceModel(Line, StaticBranch))
        set_device_model!(template, TModelHVDCLine, DCLossyLine)
        set_device_model!(
            template,
            DeviceModel(
                InterconnectingConverter,
                formulation;
                attributes = Dict("use_linear_loss" => false),
            ),
        )
        set_hvdc_network_model!(template, VoltageDispatchHVDCNetworkModel)
        model = DecisionModel(
            template,
            sys;
            store_variable_names = true,
            optimizer = optimizer,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        return model
    end

    bin2_model = _build_and_solve(Bin2QuadraticLossConverter, HiGHS_optimizer)
    nlp_model = _build_and_solve(QuadraticLossConverter, ipopt_optimizer)

    bin2_obj = IOM.get_objective_value(OptimizationProblemOutputs(bin2_model))
    nlp_obj = IOM.get_objective_value(OptimizationProblemOutputs(nlp_model))

    # Bin2 is a relaxation/PWL approximation of the exact NLP. The two objectives
    # should agree to within a few percent on this small system.
    @test isapprox(bin2_obj, nlp_obj; rtol = 0.05)
end

@testset "HVDC linear-loss warning when all converters have b=0" begin
    sys = _generate_test_hvdc_sys()
    for ipc in get_components(InterconnectingConverter, sys)
        set_loss_function!(ipc, QuadraticCurve(0.01, 0.0, 0.0))
    end
    template = OperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, TModelHVDCLine, DCLossyLine)
    set_device_model!(
        template,
        DeviceModel(InterconnectingConverter, Bin2QuadraticLossConverter),
    )
    set_hvdc_network_model!(template, VoltageDispatchHVDCNetworkModel)
    model = DecisionModel(
        template,
        sys;
        store_variable_names = true,
        optimizer = HiGHS_optimizer,
    )
    # `build!` wraps its body in `Logging.with_logger(file_logger)`, which masks
    # any `TestLogger` set up by `@test_logs`. The warning we want lands in the
    # per-build log file instead, so read it back from there.
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    log_path = joinpath(output_dir, IOM.PROBLEM_LOG_FILENAME)
    @test occursin(r"linear[_ ]loss"i, read(log_path, String))
end

##############################################################################
################ Two-Terminal VSC HVDC tests #################################
##############################################################################

# Build a small AC test system and replace an AC line with a TwoTerminalVSCLine
# so we have a concrete VSC device to exercise the formulation against.
function _generate_test_vsc_sys(;
    g = 50.0,
    rating_from = 2.0,
    rating_to = 2.0,
    loss_a = 0.01,
    loss_b = 0.0,
    loss_c = 0.0,
)
    sys = build_system(PSITestSystems, "c_sys5_uc"; force_build = true)
    line = get_component(Line, sys, "1")
    remove_component!(sys, line)

    vsc = TwoTerminalVSCLine(;
        name = get_name(line),
        available = true,
        arc = get_arc(line),
        active_power_flow = 0.0,
        rating = max(rating_from, rating_to),
        active_power_limits_from = (min = -rating_from, max = rating_from),
        active_power_limits_to = (min = -rating_to, max = rating_to),
        g = g,
        dc_current = 0.0,
        reactive_power_from = 0.0,
        dc_voltage_control_from = true,
        ac_voltage_control_from = true,
        dc_setpoint_from = 0.0,
        ac_setpoint_from = 1.0,
        converter_loss_from = QuadraticCurve(loss_a, loss_b, loss_c),
        max_dc_current_from = 5.0,
        rating_from = rating_from,
        reactive_power_limits_from = (min = -rating_from, max = rating_from),
        power_factor_weighting_fraction_from = 1.0,
        voltage_limits_from = (min = 0.95, max = 1.05),
        reactive_power_to = 0.0,
        dc_voltage_control_to = true,
        ac_voltage_control_to = true,
        dc_setpoint_to = 0.0,
        ac_setpoint_to = 1.0,
        converter_loss_to = QuadraticCurve(loss_a, loss_b, loss_c),
        max_dc_current_to = 5.0,
        rating_to = rating_to,
        reactive_power_limits_to = (min = -rating_to, max = rating_to),
        power_factor_weighting_fraction_to = 1.0,
        voltage_limits_to = (min = 0.95, max = 1.05),
    )
    add_component!(sys, vsc)
    return sys
end

function _build_vsc_model(formulation, network, optimizer; sys = _generate_test_vsc_sys())
    template = OperationsProblemTemplate(NetworkModel(network))
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, DeviceModel(TwoTerminalVSCLine, formulation))
    return DecisionModel(
        template, sys; store_variable_names = true, optimizer = optimizer,
    )
end

@testset "HVDC Two-Terminal VSC (Bin2) on DCP" begin
    model = _build_vsc_model(HVDCTwoTerminalVSCBin2, DCPPowerModel, HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "HVDC Two-Terminal VSC (NLP) on DCP" begin
    model = _build_vsc_model(HVDCTwoTerminalVSC, DCPPowerModel, ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "HVDC Two-Terminal VSC on AC (NLP)" begin
    model = _build_vsc_model(HVDCTwoTerminalVSC, ACPPowerModel, ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "HVDC VSC Bin2 vs NLP objective agreement" begin
    function _solve(formulation, optimizer)
        sys = _generate_test_vsc_sys()
        model = _build_vsc_model(formulation, DCPPowerModel, optimizer; sys = sys)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        return IOM.get_optimization_container(model).optimizer_stats.objective_value
    end
    bin2_obj = _solve(HVDCTwoTerminalVSCBin2, HiGHS_optimizer)
    nlp_obj = _solve(HVDCTwoTerminalVSC, ipopt_optimizer)
    # Bin2 PWL-approximates the same physics — objectives should agree closely.
    @test isapprox(bin2_obj, nlp_obj; rtol = 0.05)
end

@testset "HVDC VSC: higher cable resistance increases cost" begin
    # Smaller g => larger R = 1/g => more losses => optimum should not improve.
    function _solve_with_g(g_value)
        sys = _generate_test_vsc_sys(; g = g_value)
        model = _build_vsc_model(
            HVDCTwoTerminalVSCBin2, DCPPowerModel, HiGHS_optimizer; sys = sys,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        return IOM.get_optimization_container(model).optimizer_stats.objective_value
    end
    low_R_obj = _solve_with_g(100.0)   # large g, small R
    high_R_obj = _solve_with_g(20.0)   # smaller g, larger R
    @test high_R_obj >= low_R_obj - 1e-6
end

@testset "HVDC VSC: tighter PQ rating raises cost on AC" begin
    function _solve_with_rating(s)
        sys = _generate_test_vsc_sys(; rating_from = s, rating_to = s)
        model = _build_vsc_model(
            HVDCTwoTerminalVSC, ACPPowerModel, ipopt_optimizer; sys = sys,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        return IOM.get_optimization_container(model).optimizer_stats.objective_value
    end
    looser = _solve_with_rating(2.0)
    tighter = _solve_with_rating(1.0)
    @test tighter >= looser - 1e-6
end
