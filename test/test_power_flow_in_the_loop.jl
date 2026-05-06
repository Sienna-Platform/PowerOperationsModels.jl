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
