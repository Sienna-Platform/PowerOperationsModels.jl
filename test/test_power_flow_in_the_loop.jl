@testset "AC Power Flow in the loop with headroom-proportional slack" begin
    system = build_system(PSITestSystems, "c_sys5_uc")

    template = get_template_dispatch_with_network(
        NetworkModel(
            PTDFPowerModel;
            PTDF_matrix = PTDF(system),
            power_flow_evaluation = ACPowerFlow(;
                distribute_slack_proportional_to_headroom = true,
                correct_bustypes = true,
            ),
        ),
    )
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    pf_e_data = only(get_power_flow_evaluation_data(container))
    data = get_power_flow_data(pf_e_data)

    computed_gspf = PFS.get_computed_gspf(data)
    n_time_steps = length(get_time_steps(container))
    bus_lookup = PFS.get_bus_lookup(data)

    # Headroom factors should be populated for every time step
    @test length(computed_gspf) == n_time_steps
    @test all(!isempty(d) for d in computed_gspf)
    @test all(all(v > 0.0 for v in values(d)) for d in computed_gspf)

    # bus_active_power_range should equal the sum of generator headroom per bus per time step
    for t in 1:n_time_steps
        bus_headroom_check = zeros(size(data.bus_active_power_range, 1))
        for ((comp_type, comp_name), headroom) in computed_gspf[t]
            comp = get_component(comp_type, system, comp_name)
            bus_number = get_number(get_bus(comp))
            bus_ix = bus_lookup[bus_number]
            bus_headroom_check[bus_ix] += headroom
        end
        @test isapprox(
            data.bus_active_power_range[:, t],
            bus_headroom_check;
            atol = 1e-10,
        )
    end

    # bus_slack_participation_factors should match bus_active_power_range at participating buses
    bus_slack_pf = PFS.get_bus_slack_participation_factors(data)
    for t in 1:n_time_steps
        for bus_ix in axes(data.bus_active_power_range, 1)
            R_k = data.bus_active_power_range[bus_ix, t]
            if R_k > 0.0
                @test bus_slack_pf[bus_ix, t] == R_k
            end
        end
    end

    # Independently recompute expected headroom from optimization results and system
    # limits, then verify it matches computed_gspf exactly. NOTE: c_sys5_uc thermals
    # have fixed active power limits (no ActivePowerTimeSeriesParameter), so this
    # exercises the static P_max path. The time-varying P_max path is exercised in
    # the third testset below.
    for t in 1:n_time_steps
        for ((comp_type, comp_name), headroom) in computed_gspf[t]
            comp = get_component(comp_type, system, comp_name)
            p_max_sys = PFS.get_active_power_limits_for_power_flow(comp).max

            var_key = VariableKey(ActivePowerVariable, comp_type)
            result_data = lookup_value(container, var_key)
            p_setpoint = JuMP.value(result_data[comp_name, t])

            expected_headroom = p_max_sys - p_setpoint
            @test expected_headroom > 0.0
            @test isapprox(headroom, expected_headroom; atol = 1e-10)
        end
    end
end

@testset "Headroom proportional slack excludes FixedOutput generators" begin
    # c_sys5_uc_re has renewables at PV/REF buses, so they would normally participate
    # in headroom slack. Setting them to FixedOutput should exclude them.
    system = build_system(PSITestSystems, "c_sys5_uc_re")

    template = get_template_dispatch_with_network(
        NetworkModel(
            PTDFPowerModel;
            PTDF_matrix = PTDF(system),
            use_slacks = true,
            power_flow_evaluation = ACPowerFlow(;
                distribute_slack_proportional_to_headroom = true,
                correct_bustypes = true,
            ),
        ),
    )
    set_device_model!(template, RenewableDispatch, FixedOutput)

    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    pf_e_data = only(get_power_flow_evaluation_data(container))
    data = get_power_flow_data(pf_e_data)
    computed_gspf = PFS.get_computed_gspf(data)

    # The renewable is at a PV bus but uses FixedOutput, so it must not appear in the
    # headroom factors — only ThermalStandard generators should participate.
    for t in 1:length(get_time_steps(container))
        for ((comp_type, _), _) in computed_gspf[t]
            @test comp_type <: ThermalStandard
        end
    end
end

@testset "Headroom proportional slack with time-varying active power limits" begin
    # c_sys5_uc_re has renewables at PV/REF buses with time series data.
    system = build_system(PSITestSystems, "c_sys5_uc_re")
    re_gen = first(get_components(RenewableDispatch, system))
    re_name = get_name(re_gen)
    # Force device_base != system_base so the unit-handling path is exercised. If
    # headroom ever silently re-introduces a `* device_base / system_base` factor,
    # the recomputed expected_headroom below will mismatch by 0.5×, failing the
    # assertion.
    PSY.set_units_base_system!(system, "SYSTEM_BASE")
    PSY.set_base_power!(re_gen, get_base_power(re_gen) / 2)

    template = get_template_dispatch_with_network(
        NetworkModel(
            PTDFPowerModel;
            PTDF_matrix = PTDF(system),
            use_slacks = true,
            power_flow_evaluation = ACPowerFlow(;
                distribute_slack_proportional_to_headroom = true,
                correct_bustypes = true,
            ),
        ),
    )
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)

    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    pf_e_data = only(get_power_flow_evaluation_data(container))
    data = get_power_flow_data(pf_e_data)
    computed_gspf = PFS.get_computed_gspf(data)
    n_time_steps = length(get_time_steps(container))

    # Verify the renewable's headroom uses min(static_limit, ts_param) at each time step
    re_type = typeof(re_gen)
    p_max_static = PFS.get_active_power_limits_for_power_flow(re_gen).max

    var_key = VariableKey(ActivePowerVariable, re_type)
    var_values = lookup_value(container, var_key)
    ts_key = ParameterKey(ActivePowerTimeSeriesParameter, re_type)
    ts_values = lookup_value(container, ts_key)

    for t in 1:n_time_steps
        p_setpoint = JuMP.value(var_values[re_name, t])
        p_max_ts = ts_values[re_name, t]
        p_max_t = min(p_max_static, p_max_ts)
        expected_headroom = p_max_t - p_setpoint

        entry = get(computed_gspf[t], (re_type, re_name), nothing)
        if expected_headroom > 0.0
            @test entry !== nothing
            @test isapprox(entry, expected_headroom; atol = 1e-10)
        else
            @test entry === nothing
        end
    end

    # The time series should cause P_max to vary, producing different headroom across steps
    re_ts_vals = [ts_values[re_name, t] for t in 1:n_time_steps]
    @test !all(isapprox.(re_ts_vals, re_ts_vals[1]; atol = 1e-10))
end

# -----------------------------------------------------------------------------
# Baseline PFitL coverage (ported from PowerSimulations.jl test file lines 1-548).
# These exercise the regular non-headroom paths through the migrated code:
#   - PhaseShiftingTransformer in PFitL
#   - Parallel-line aggregation
#   - Breaker-switch (DiscreteControlledACBranch)
#   - HVDCs with DC PowerFlow
#   - Line active power loss aux variable
# -----------------------------------------------------------------------------

@testset "AC Power Flow in the loop for PhaseShiftingTransformer" begin
    system = build_system(PSITestSystems, "c_sys5_uc")

    line = get_component(Line, system, "1")
    arc = get_arc(line)
    remove_component!(system, line)

    ps = PhaseShiftingTransformer(;
        name = get_name(line),
        available = true,
        active_power_flow = 0.0,
        reactive_power_flow = 0.0,
        r = get_r(line),
        x = get_x(line),
        primary_shunt = 0.0,
        tap = 1.0,
        α = 0.0,
        rating = get_rating(line),
        arc = arc,
        base_power = get_base_power(system),
    )
    add_component!(system, ps)

    template = get_template_dispatch_with_network(
        NetworkModel(
            PTDFPowerModel;
            PTDF_matrix = PTDF(system),
            power_flow_evaluation = ACPowerFlow(),
        ),
    )
    set_device_model!(template, DeviceModel(PhaseShiftingTransformer, PhaseAngleControl))
    model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model_m) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model_m)
    pf_e_data = only(get_power_flow_evaluation_data(container))
    data = get_power_flow_data(pf_e_data)
    bus_lookup = PFS.get_bus_lookup(data)

    flow_key = VariableKey(FlowActivePowerVariable, PhaseShiftingTransformer)
    flow_values = lookup_value(container, flow_key)
    line_name = get_name(line)
    line_flows =
        [JuMP.value(flow_values[line_name, t]) for t in 1:length(get_time_steps(container))]

    # The PhaseShiftingTransformer flow contributes to the "to"-bus active power injection.
    # Both sides are in per-unit; lookup_value returns raw JuMP values in the model unit
    # system rather than the natural-unit conversion that `read_variables(...; WIDE)`
    # performs in PSI.
    @test isapprox(
        data.bus_active_power_injections[bus_lookup[get_number(get_to(arc))], :],
        line_flows;
        atol = 1e-9,
        rtol = 0,
    )
end

@testset "AC Power Flow in the loop with parallel lines" begin
    original_line_flow, parallel_line_flow = zero(ComplexF64), zero(ComplexF64)
    for replace_line in (true, false)
        system = build_system(PSITestSystems, "c_sys5_uc")
        line = get_component(Line, system, "1")
        if replace_line
            original_impedance = get_r(line) + im * get_x(line)
            original_shunt = get_b(line)
            remove_component!(system, line)
            split_impedance = original_impedance * 2
            split_shunt = (from = 0.5 * original_shunt.from, to = 0.5 * original_shunt.to)
            for i in 1:2
                l = Line(;
                    name = get_name(line) * "_$i",
                    available = true,
                    active_power_flow = 0.0,
                    reactive_power_flow = 0.0,
                    arc = get_arc(line),
                    r = real(split_impedance),
                    x = imag(split_impedance),
                    b = split_shunt,
                    angle_limits = get_angle_limits(line),
                    rating = get_rating(line),
                )
                add_component!(system, l)
            end
        end

        template = get_template_dispatch_with_network(
            NetworkModel(
                PTDFPowerModel;
                PTDF_matrix = PTDF(system),
                power_flow_evaluation = ACPowerFlow(),
            ),
        )
        model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
        @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
              ModelBuildStatus.BUILT
        @test solve!(model_m) == RunStatus.SUCCESSFULLY_FINALIZED

        container = get_optimization_container(model_m)
        ft_key = AuxVarKey(POM.PowerFlowBranchActivePowerFromTo, Line)
        rt_key = AuxVarKey(POM.PowerFlowBranchReactivePowerFromTo, Line)
        active_ft = lookup_value(container, ft_key)
        reactive_ft = lookup_value(container, rt_key)

        name = replace_line ? "$(get_name(line))_1" : get_name(line)
        flow = active_ft[name, 1] + im * reactive_ft[name, 1]
        if replace_line
            parallel_line_flow = flow
        else
            original_line_flow = flow
        end
    end

    # Two parallel lines with double the impedance each should each carry half of the
    # original line's flow.
    @test isapprox(2 * parallel_line_flow, original_line_flow; atol = 1e-3)
end

@testset "AC Power Flow in the loop with a breaker-switch" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    line = get_component(Line, system, "2")
    remove_component!(system, line)
    bs = PSY.DiscreteControlledACBranch(;
        name = get_name(line),
        available = true,
        active_power_flow = 0.0,
        reactive_power_flow = 0.0,
        arc = get_arc(line),
        r = 0.0,
        x = 0.0,
        rating = get_rating(line),
        discrete_branch_type = PSY.DiscreteControlledBranchType.BREAKER,
        branch_status = PSY.DiscreteControlledBranchStatus.CLOSED,
    )
    add_component!(system, bs)
    # Set lines 3 and 6 to identical impedance so they're truly parallel
    line3 = get_component(Line, system, "3")
    line6 = get_component(Line, system, "6")
    PSY.set_r!(line3, PSY.get_r(line6))
    PSY.set_x!(line3, PSY.get_x(line6))

    template = get_template_dispatch_with_network(
        NetworkModel(
            PTDFPowerModel;
            PTDF_matrix = PTDF(system),
            power_flow_evaluation = ACPowerFlow(),
        ),
    )
    model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model_m) == RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "HVDCs with DC PF in the loop" begin
    for hvdc_type in (TwoTerminalGenericHVDCLine,)
        sys = build_system(PSISystems, "2Area 5 Bus System")

        template_uc = OperationsProblemTemplate(
            NetworkModel(PTDFPowerModel; power_flow_evaluation = DCPowerFlow()),
        )
        set_device_model!(template_uc, ThermalStandard, ThermalBasicUnitCommitment)
        set_device_model!(template_uc, RenewableDispatch, RenewableFullDispatch)
        set_device_model!(template_uc, PowerLoad, StaticPowerLoad)
        set_device_model!(template_uc, DeviceModel(Line, StaticBranch))
        set_device_model!(template_uc, DeviceModel(hvdc_type, HVDCTwoTerminalDispatch))

        model = DecisionModel(template_uc, sys; name = "UC", optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir()) == ModelBuildStatus.BUILT
        @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    end
end

@testset "AC Power Flow line active power loss auxiliary variable" begin
    system = build_system(PSITestSystems, "c_sys5_uc")

    template = get_template_dispatch_with_network(
        NetworkModel(
            PTDFPowerModel;
            PTDF_matrix = PTDF(system),
            power_flow_evaluation = ACPowerFlow(),
        ),
    )
    model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model_m) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model_m)
    ft_key = AuxVarKey(POM.PowerFlowBranchActivePowerFromTo, Line)
    tf_key = AuxVarKey(POM.PowerFlowBranchActivePowerToFrom, Line)
    loss_key = AuxVarKey(POM.PowerFlowBranchActivePowerLoss, Line)
    active_ft = lookup_value(container, ft_key)
    active_tf = lookup_value(container, tf_key)
    active_loss = lookup_value(container, loss_key)

    n_time_steps = length(get_time_steps(container))
    for line_name in axes(active_loss, 1)
        ft_vals = [active_ft[line_name, t] for t in 1:n_time_steps]
        tf_vals = [active_tf[line_name, t] for t in 1:n_time_steps]
        loss_vals = [active_loss[line_name, t] for t in 1:n_time_steps]
        @test isapprox(loss_vals, ft_vals .+ tf_vals; atol = 1e-9)
    end
end
