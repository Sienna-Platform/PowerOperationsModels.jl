@testset "HVDC System Tests" begin
    sys_5 = build_system(PSISystems, "sys10_pjm_ac_dc")
    template_uc = PowerOperationsProblemTemplate(NetworkModel(
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

    template_uc = PowerOperationsProblemTemplate(
        NetworkModel(
            PTDFPowerModel;
            #use_slacks=true,
            PTDF_matrix = PTDF(sys_5),
            #duals=[CopperPlateBalanceConstraint],
        ),
    )

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
                PSY.get_power_units(op_cost.variable),
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
    template = PowerOperationsProblemTemplate()
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

@testset "HVDC MILP vs NLP QuadraticLossConverter agreement" begin
    # Build the single QuadraticLossConverter both ways — MILP via a linearizing
    # bilinear scheme and exact (NLP) via the default "none" scheme — on the same
    # system; compare objective values (Rodrigo's "same order of magnitude" ask
    # from PR #103).
    function _build_and_solve(sys, converter_model, optimizer)
        template = PowerOperationsProblemTemplate()
        set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
        set_device_model!(template, PowerLoad, StaticPowerLoad)
        set_device_model!(template, DeviceModel(Line, StaticBranch))
        set_device_model!(template, TModelHVDCLine, DCLossyLine)
        set_device_model!(template, converter_model)
        set_hvdc_network_model!(template, VoltageDispatchHVDCNetworkModel)
        model = DecisionModel(
            template, sys;
            store_variable_names = true, optimizer = optimizer,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        return model
    end

    sys = _generate_test_hvdc_sys()
    milp_model = _build_and_solve(
        sys,
        DeviceModel(
            InterconnectingConverter, QuadraticLossConverter;
            attributes = Dict("bilinear_approximation" => "bin2"),
        ),
        HiGHS_optimizer,
    )
    nlp_model = _build_and_solve(
        sys,
        DeviceModel(InterconnectingConverter, QuadraticLossConverter),
        ipopt_optimizer,
    )

    # Objective is the right level of strictness for "same order of magnitude"
    # (Rodrigo's ask on the PR #103 review). Per-converter or system-total
    # current/power comparisons fail unpredictably on this fixture because the
    # MT-HVDC fleet carries essentially no power either way (the loss term
    # drives it toward zero on both sides), so the MILP's SOS2 PWL surrogate
    # vs the NLP's exact bilinear leave residuals at very different
    # magnitudes — both still tiny in absolute terms, just not within a
    # rtol-comparable factor of each other.
    milp_obj = IOM.get_objective_value(OptimizationProblemOutputs(milp_model))
    nlp_obj = IOM.get_objective_value(OptimizationProblemOutputs(nlp_model))
    @test isapprox(milp_obj, nlp_obj; rtol = 0.05)
end

@testset "HVDC CurrentAbsoluteValueVariable matches |ConverterCurrent| at MILP optimum" begin
    # Direct evidence that the binary-free LP abs-value formulation is tight:
    # the loss objective drives abs_i down to exactly |i| at the optimum.
    sys = _generate_test_hvdc_sys()
    template = PowerOperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, TModelHVDCLine, DCLossyLine)
    set_device_model!(
        template,
        DeviceModel(
            InterconnectingConverter, QuadraticLossConverter;
            attributes = Dict("bilinear_approximation" => "bin2"),
        ),
    )
    set_hvdc_network_model!(template, VoltageDispatchHVDCNetworkModel)
    model = DecisionModel(
        template, sys;
        store_variable_names = true, optimizer = HiGHS_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(model)
    i_vals =
        JuMP.value.(
            IOM.get_variable(container, ConverterCurrent, InterconnectingConverter).data,
        )
    abs_i_vals =
        JuMP.value.(
            IOM.get_variable(
                container,
                CurrentAbsoluteValueVariable,
                InterconnectingConverter,
            ).data,
        )
    @test isapprox(abs_i_vals, abs.(i_vals); atol = 1e-6)
end

@testset "Converter loss: attribute → IOM config bridge" begin
    # Pure config construction — no solver or system required.
    v_bounds = [IOM.MinMax((min = 0.9, max = 1.05))]
    i_bounds = [IOM.MinMax((min = -2.0, max = 2.0))]
    # The formulation defaults to the exact "none" scheme, so default the helper
    # to a linearizing scheme ("bin2") to exercise the MILP bridge; overrides win.
    milp_dm(overrides...) = DeviceModel(
        InterconnectingConverter, QuadraticLossConverter;
        attributes = Dict{String, Any}("bilinear_approximation" => "bin2", overrides...),
    )
    cfgs(dm) = POM._build_converter_configs(
        QuadraticLossConverter, dm, v_bounds, i_bounds,
    )

    # Squares-based schemes: the standalone loss-I² quad config is reused as the
    # bilinear's inner quad (===), and the inner quad type follows the method.
    quad, bilin = cfgs(milp_dm())  # bin2 / solver_sos2 defaults
    @test bilin isa IOM.Bin2Config{IOM.SolverSOS2QuadConfig}
    @test quad === bilin.quad_config
    quad, bilin = cfgs(milp_dm("bilinear_quadratic_method" => "nmdt"))
    @test bilin isa IOM.Bin2Config{IOM.NMDTQuadConfig}
    @test quad === bilin.quad_config
    quad, bilin = cfgs(
        milp_dm(
            "bilinear_approximation" => "hybs",
            "bilinear_quadratic_method" => "sawtooth",
        ),
    )
    @test bilin isa IOM.HybSConfig{IOM.SawtoothQuadConfig}
    @test quad === bilin.quad_config

    # Discretization-based schemes: the bilinear builds no I², so the loss I²
    # quad is sized on its own (type follows the quad method).
    quad, bilin = cfgs(milp_dm("bilinear_approximation" => "nmdt"))
    @test bilin isa IOM.NMDTBilinearConfig
    @test quad isa IOM.SolverSOS2QuadConfig
    quad, bilin = cfgs(milp_dm("bilinear_approximation" => "dnmdt"))
    @test bilin isa IOM.DNMDTBilinearConfig
    @test quad isa IOM.SolverSOS2QuadConfig

    # "none" (the default scheme) keeps both terms exact.
    quad, bilin = cfgs(milp_dm("bilinear_approximation" => "none"))
    @test quad isa IOM.NoQuadApproxConfig
    @test bilin isa IOM.NoBilinearApproxConfig

    # Tighter relative tolerance ⇒ deeper discretization, for the bin2 inner quad
    # and the standalone nmdt loss quad alike.
    loose, _ = cfgs(milp_dm("bilinear_relative_tolerance" => 1e-1))
    tight, _ = cfgs(milp_dm("bilinear_relative_tolerance" => 1e-4))
    @test tight.depth > loose.depth
    loose_n, _ = cfgs(
        milp_dm(
            "bilinear_approximation" => "nmdt", "bilinear_relative_tolerance" => 1e-1),
    )
    tight_n, _ = cfgs(
        milp_dm(
            "bilinear_approximation" => "nmdt", "bilinear_relative_tolerance" => 1e-4),
    )
    @test tight_n.depth > loose_n.depth

    # A relative tolerance and the equivalent absolute tolerance size identically.
    scale = POM._max_abs(v_bounds) * POM._max_abs(i_bounds)
    rel_cfg, _ = cfgs(milp_dm("bilinear_relative_tolerance" => 0.05))
    abs_cfg, _ = cfgs(
        milp_dm(
            "bilinear_relative_tolerance" => nothing,
            "bilinear_absolute_tolerance" => 0.05 * scale),
    )
    @test rel_cfg.depth == abs_cfg.depth

    # Error cases bubble up from the shared bridge.
    @test_throws ErrorException cfgs(milp_dm("bilinear_approximation" => "foo"))
    @test_throws ErrorException cfgs(milp_dm("bilinear_quadratic_method" => "foo"))
    # HybS needs a one-sided-over inner quad: nmdt/dnmdt rejected.
    @test_throws ErrorException cfgs(
        milp_dm(
            "bilinear_approximation" => "hybs", "bilinear_quadratic_method" => "nmdt"),
    )
    @test_throws ArgumentError cfgs(milp_dm("bilinear_relative_tolerance" => 0.0))
    @test_throws ArgumentError cfgs(milp_dm("bilinear_relative_tolerance" => Inf))
    # Both tolerances unset → error.
    @test_throws ArgumentError cfgs(
        milp_dm(
            "bilinear_relative_tolerance" => nothing,
            "bilinear_absolute_tolerance" => nothing),
    )

    # The VSC formulation uses the same bridge (spot check) and keeps
    # use_octagon among its defaults.
    vsc_dm = DeviceModel(
        TwoTerminalVSCLine, HVDCTwoTerminalVSC;
        attributes = Dict("bilinear_approximation" => "bin2"),
    )
    @test IOM.get_attribute(vsc_dm, "use_octagon") == true
    quad, bilin = POM._build_converter_configs(
        HVDCTwoTerminalVSC, vsc_dm, v_bounds, i_bounds,
    )
    @test bilin isa IOM.Bin2Config{IOM.SolverSOS2QuadConfig}
    @test quad === bilin.quad_config
end

@testset "QuadraticLossConverter builds under every bilinear scheme" begin
    sys = _generate_test_hvdc_sys()
    for scheme in ("bin2", "hybs", "nmdt", "dnmdt")
        template = PowerOperationsProblemTemplate()
        set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
        set_device_model!(template, PowerLoad, StaticPowerLoad)
        set_device_model!(template, DeviceModel(Line, StaticBranch))
        set_device_model!(template, TModelHVDCLine, DCLossyLine)
        set_device_model!(
            template,
            DeviceModel(
                InterconnectingConverter, QuadraticLossConverter;
                attributes = Dict{String, Any}("bilinear_approximation" => scheme),
            ),
        )
        set_hvdc_network_model!(template, VoltageDispatchHVDCNetworkModel)
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
    end
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

function _build_vsc_model(
    converter_model::DeviceModel,
    network,
    optimizer;
    sys = _generate_test_vsc_sys(),
)
    template = PowerOperationsProblemTemplate(NetworkModel(network))
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, converter_model)
    return DecisionModel(
        template, sys; store_variable_names = true, optimizer = optimizer,
    )
end

# A single HVDCTwoTerminalVSC formulation, switched between MILP and exact (NLP)
# via the "bilinear_approximation" attribute ("bin2" vs the default "none").
_vsc_milp(attrs...) = DeviceModel(
    TwoTerminalVSCLine, HVDCTwoTerminalVSC;
    attributes = Dict{String, Any}("bilinear_approximation" => "bin2", attrs...),
)
_vsc_nlp() = DeviceModel(TwoTerminalVSCLine, HVDCTwoTerminalVSC)  # default "none"

# Standalone build+solve smoke tests for each (scheme, network) combo are
# covered by the agreement / property tests further down:
#   - exact (NLP) on DCP → "HVDC VSC LP vs NLP objective agreement"
#   - MILP on DCP        → same agreement test + cable-resistance test
#   - exact (NLP) on AC  → "HVDC VSC: tighter PQ rating raises cost on AC"
# The MILP scheme on ACPPowerModel is omitted: HiGHS can't solve the ACP
# network's trig (cos/sin) branch ohms-law constraints, and no MINLP solver
# with trigonometric support is wired into the test deps.
#
# TODO: Re-add an `octagon vs box-only` LP property test once an MINLP solver
# with trig support is available. The previous version of that test ran on
# `DCPPowerModel`, which never adds `HVDCVSCApparentPowerLimitConstraint`
# (active-power-only networks carry no reactive power, so `_add_vsc_pq_capability!`
# is a no-op there), so it asserted the same model against itself.

@testset "HVDC VSC LP vs NLP objective agreement" begin
    # On a DC network the PQ disk constraint is inactive (no reactive
    # variables exist), so the LP and NLP differ only by the i² loss model
    # (SOS2 PWL vs exact). For a smooth convex loss curve the two should agree
    # within a few percent.
    function _solve(converter_model, optimizer)
        sys = _generate_test_vsc_sys()
        model = _build_vsc_model(converter_model, DCPPowerModel, optimizer; sys = sys)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        return IOM.get_optimization_container(model).optimizer_stats.objective_value
    end
    lp_obj = _solve(_vsc_milp(), HiGHS_optimizer)
    nlp_obj = _solve(_vsc_nlp(), ipopt_optimizer)
    @test isapprox(lp_obj, nlp_obj; rtol = 0.05)
end

@testset "HVDCTwoTerminalVSC builds under every bilinear scheme" begin
    sys = _generate_test_vsc_sys()
    for scheme in ("bin2", "hybs", "nmdt", "dnmdt")
        template = PowerOperationsProblemTemplate(NetworkModel(DCPPowerModel))
        set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
        set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
        set_device_model!(template, PowerLoad, StaticPowerLoad)
        set_device_model!(template, DeviceModel(Line, StaticBranch))
        set_device_model!(
            template,
            DeviceModel(
                TwoTerminalVSCLine, HVDCTwoTerminalVSC;
                attributes = Dict{String, Any}("bilinear_approximation" => scheme),
            ),
        )
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
    end
end

@testset "HVDC VSC: higher cable resistance increases cost" begin
    # Smaller g => larger R = 1/g => more losses => optimum should not improve.
    function _solve_with_g(g_value)
        sys = _generate_test_vsc_sys(; g = g_value)
        model = _build_vsc_model(
            _vsc_milp(), DCPPowerModel, HiGHS_optimizer; sys = sys,
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
            _vsc_nlp(), ACPPowerModel, ipopt_optimizer; sys = sys,
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
