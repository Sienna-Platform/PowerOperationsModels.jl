@testset "pf_aux_var_types enumerates every PowerFlowAuxVariableType" begin
    # Registration walks these tuples, not the type tree, so a type missing from them
    # would silently never register.
    branch_types = POM.pf_aux_var_types(PSY.ACBranch)
    bus_types = POM.pf_aux_var_types(PSY.ACBus)
    declared = union(Set(branch_types), Set(bus_types))
    defined = Set(IS.get_all_concrete_subtypes(POM.PowerFlowAuxVariableType))

    @test setdiff(defined, declared) == Set{DataType}()   # a type nothing would register
    @test setdiff(declared, defined) == Set{DataType}()   # a stale/removed entry
    # No type may be claimed as both branch- and bus-indexed.
    @test isempty(intersect(Set(branch_types), Set(bus_types)))
    # Tuples, not vectors: compile-time resolution depends on it.
    @test branch_types isa Tuple
    @test bus_types isa Tuple
end

@testset "AC Power Flow in the loop with headroom-proportional slack" begin
    system = build_system(PSITestSystems, "c_sys5_uc")

    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(
            ACPowerFlow(;
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
    pf_e_data = only(values(get_evaluation_data(container)))
    data = get_inner_data(pf_e_data)

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
            p_setpoint = result_data[comp_name, t]

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
        NetworkModel(PTDFNetworkModel; use_slacks = true);
        evaluations = power_flow_evaluations(
            ACPowerFlow(;
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
    pf_e_data = only(values(get_evaluation_data(container)))
    data = get_inner_data(pf_e_data)
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
    re_gen.base_power = get_base_power(re_gen, u"NU") / 2

    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel; use_slacks = true);
        evaluations = power_flow_evaluations(
            ACPowerFlow(;
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
    pf_e_data = only(values(get_evaluation_data(container)))
    data = get_inner_data(pf_e_data)
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
        p_setpoint = var_values[re_name, t]
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

@testset "Headroom proportional slack counts committed units only" begin
    # c_sys5_uc decommits units in some hours under unit commitment.
    system = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(
            ACPowerFlow(;
                distribute_slack_proportional_to_headroom = true,
                correct_bustypes = true,
            ),
        ),
    )
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    data = get_inner_data(only(values(get_evaluation_data(container))))
    computed_gspf = PFS.get_computed_gspf(data)
    on = lookup_value(container, VariableKey(OnVariable, ThermalStandard))
    p = lookup_value(container, VariableKey(ActivePowerVariable, ThermalStandard))

    n_off = 0
    for t in get_time_steps(container), name in axes(on, 1)
        entry = get(computed_gspf[t], (ThermalStandard, name), 0.0)
        if iszero(on[name, t])
            n_off += 1
            @test iszero(entry)
        else
            comp = get_component(ThermalStandard, system, name)
            p_max = PFS.get_active_power_limits_for_power_flow(comp).max
            @test isapprox(entry, max(p_max - p[name, t], 0.0); atol = 1e-10)
        end
    end
    @test n_off > 0
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
    #    system = buid_system(PSITestSystems, "c_sys5_uc")
    #
    #    line = get_component(Line, system, "1")
    #    arc = get_arc(line)
    #
    #    ps = PhaseShiftingTransformer(;
    #        name = get_name(line),
    #        available = true,
    #        active_power_flow = 0.0,
    #        reactive_power_flow = 0.0,
    #        r = get_r(line, u"SU"),
    #        x = get_x(line, u"SU"),
    #        primary_shunt = 0.0,
    #        tap = 1.0,
    #        α = 0.0,
    #        rating = get_rating(line, u"SU"),
    #        arc = arc,
    #        base_power = get_base_power(system, u"NU"),
    #    )
    #    add_component!(system, ps)
    #    remove_component!(system, line)
    #
    #    template = get_template_dispatch_with_network(
    #        NetworkModel(PTDFNetworkModel; network_matrix = PTDF(system));
    #        evaluations = power_flow_evaluations(ACPowerFlow()),
    #    )
    #    set_device_model!(template, DeviceModel(PhaseShiftingTransformer, PhaseAngleControl))
    #    model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    #    @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
    #          ModelBuildStatus.BUILT
    #    @test solve!(model_m) == RunStatus.SUCCESSFULLY_FINALIZED
    #
    #    container = get_optimization_container(model_m)
    #    pf_e_data = only(values(get_evaluation_data(container)))
    #    data = get_inner_data(pf_e_data)
    #    bus_lookup = PFS.get_bus_lookup(data)
    #
    #    flow_key = VariableKey(FlowActivePowerVariable, PhaseShiftingTransformer)
    #    flow_values = lookup_value(container, flow_key)
    #    line_name = get_name(line)
    #    line_flows =
    #        [flow_values[line_name, t] for t in 1:length(get_time_steps(container))]
    #
    #    # The PhaseShiftingTransformer flow contributes to the "to"-bus active power injection.
    #    # Both sides are in per-unit; lookup_value returns solved values in the model unit
    #    # system rather than the natural-unit conversion that `read_variables(...; WIDE)`
    #    # performs in PSI.
    #    @test isapprox(
    #        data.bus_active_power_injections[bus_lookup[get_number(get_to(arc))], :],
    #        line_flows;
    #        atol = 1e-9,
    #        rtol = 0,
    #    )
end

@testset "AC Power Flow in the loop with parallel lines" begin
    original_line_flow, parallel_line_flow = zero(ComplexF64), zero(ComplexF64)
    for replace_line in (true, false)
        system = build_system(PSITestSystems, "c_sys5_uc")
        line = get_component(Line, system, "1")
        if replace_line
            original_impedance = get_r(line, u"SU") + im * get_x(line, u"SU")
            original_shunt = get_b(line, u"SU")
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
                    rating = get_rating(line, u"SU"),
                    input_basis = u"CU",
                )
                add_component!(system, l)
            end
            remove_component!(system, line)
        end

        template = get_template_dispatch_with_network(
            NetworkModel(PTDFNetworkModel);
            evaluations = power_flow_evaluations(ACPowerFlow()),
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
    bs = PSY.DiscreteControlledACBranch(;
        name = get_name(line),
        available = true,
        active_power_flow = 0.0,
        reactive_power_flow = 0.0,
        arc = get_arc(line),
        r = 0.0,
        x = 0.0,
        rating = get_rating(line, u"SU"),
        discrete_branch_type = PSY.DiscreteControlledBranchType.BREAKER,
        branch_status = PSY.DiscreteControlledBranchStatus.CLOSED,
        input_basis = u"CU",
    )
    add_component!(system, bs)
    remove_component!(system, line)
    # Set lines 3 and 6 to identical impedance so they're truly parallel
    line3 = get_component(Line, system, "3")
    line6 = get_component(Line, system, "6")
    PSY.set_r!(line3, PSY.get_r(line6, u"SU") * u"SU")
    PSY.set_x!(line3, PSY.get_x(line6, u"SU") * u"SU")

    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(ACPowerFlow()),
    )
    model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model_m) == RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "HVDCs with DC PF in the loop" begin
    for hvdc_type in (TwoTerminalGenericHVDCLine,)
        sys = build_system(PSISystems, "2Area 5 Bus System")

        template_uc = PowerOperationsProblemTemplate(
            NetworkModel(PTDFNetworkModel);
            evaluations = power_flow_evaluations(DCPowerFlow()),
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
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(ACPowerFlow()),
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

@testset "A power flow is bound only to the aux vars it provides" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(ACPowerFlow()),
    )
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)

    # IOM.get_entry_type extracts the type parameter from an AuxVarKey.
    supported_key = AuxVarKey(POM.PowerFlowBranchActivePowerLoss, Line)
    @test IOM.get_entry_type(supported_key) === POM.PowerFlowBranchActivePowerLoss

    # Default ACPowerFlow() has `calculate_loss_factors = false`, so
    # `PowerFlowLossFactors` is not in `bus_aux_vars(pf_data)`: the container has no
    # such aux var, and the evaluator is not bound to it.
    T = only(keys(get_evaluation_data(container)))
    bound = IOM.get_bound_aux_var_keys(container, T)
    unsupported_key = AuxVarKey(POM.PowerFlowLossFactors, PSY.ACBus)
    @test supported_key in bound
    @test unsupported_key ∉ bound
    @test !haskey(IOM.get_aux_variables(container), unsupported_key)
end

# Regression for issue #1623 ("PowerFlow in the loop mismatch with Sources"), ported from
# PowerSimulations.jl PR #1631. Parameters store the ALREADY-SIGNED nodal contribution
# (`param_array .* multiplier_array`), identical to what `add_to_expression!` adds to the
# system balance. The PF-in-the-loop injection writer must NOT re-apply the category sign
# (which would double-flip imports). When that happens the PF injection at the affected bus
# is wrong, so `PowerFlowBranchActivePowerFromTo` disagrees with the optimization's
# `PTDFBranchFlow`. These two testsets drive a `FixedOutput` device — whose
# `ActivePowerTimeSeriesParameter` is fed into the PF data through the pre-signed
# (`ParameterKey`) path — and assert the two branch-flow quantities agree.
@testset "PF in the loop matches optimization with FixedOutput parameter path (DC, issue #1623)" begin
    system = build_system(PSITestSystems, "c_sys5_uc_re")

    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel; use_slacks = true);
        evaluations = power_flow_evaluations(DCPowerFlow()),
    )
    # FixedOutput renewables emit `ActivePowerTimeSeriesParameter`, exercising the
    # pre-signed `ParameterKey` injection path in the PF-in-the-loop writer.
    set_device_model!(template, RenewableDispatch, FixedOutput)

    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    ptdf_flow = IOM.get_expression(container, POM.PTDFBranchFlow, Line)
    ft_aux = lookup_value(container, AuxVarKey(POM.PowerFlowBranchActivePowerFromTo, Line))

    n_time_steps = length(get_time_steps(container))
    for line_name in axes(ptdf_flow, 1)
        for t in 1:n_time_steps
            @test isapprox(
                JuMP.value(ptdf_flow[line_name, t]),
                ft_aux[line_name, t];
                atol = 1e-3,
            )
        end
    end
end

@testset "PF in the loop matches optimization with FixedOutput parameter path (AC, issue #1623)" begin
    system = build_system(PSITestSystems, "c_sys5_uc_re")

    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel; use_slacks = true);
        evaluations = power_flow_evaluations(ACPowerFlow()),
    )
    set_device_model!(template, RenewableDispatch, FixedOutput)

    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    ptdf_flow = IOM.get_expression(container, POM.PTDFBranchFlow, Line)
    ft_aux = lookup_value(container, AuxVarKey(POM.PowerFlowBranchActivePowerFromTo, Line))

    # The DC PTDFBranchFlow is lossless while the AC PowerFlowBranchActivePowerFromTo carries
    # AC losses (and the optimization's slacks may be placed differently than the AC power
    # flow redistributes them), so on this PU-scale system the two agree only to within a few
    # MW. A double-counted parameter sign at nodeC would instead shift the affected flows by
    # ~0.6 PU (≈60 MW) — far above this band — so an absolute tolerance of 0.05 PU confirms
    # agreement while still catching the bug.
    n_time_steps = length(get_time_steps(container))
    for line_name in axes(ptdf_flow, 1)
        for t in 1:n_time_steps
            @test isapprox(
                JuMP.value(ptdf_flow[line_name, t]),
                ft_aux[line_name, t];
                atol = 0.05,
            )
        end
    end
end

# `lookup_value` returns raw JuMP values in the model (system-base, PU) unit system, and
# `bus_hvdc_net_power` is likewise PU, so the HVDC comparisons below are PU-vs-PU (no base
# conversion). HVDC injections live in PowerFlows' dedicated `bus_hvdc_net_power` channel,
# not the generic `bus_active_power_injections`.
_pf_hvdc_data(container) =
    get_inner_data(only(values(get_evaluation_data(container))))
function _hvdc_flow(container, V, name)
    vals = lookup_value(container, VariableKey(V, TwoTerminalGenericHVDCLine))
    return [JuMP.value(vals[name, t]) for t in 1:length(get_time_steps(container))]
end

@testset "DC PF in the loop uses optimized HVDC flow, not the stale system seed" begin
    # PowerFlows seeds bus_hvdc_net_power from the stored flow and the DC solve never
    # repopulates it, so PSI must send the optimized flow in for DC. Seed a stale flow, then
    # assert the channel tracks the per-timestep optimized flow (from = -flow, to = +flow,
    # lossless).
    sys = build_system(PSISystems, "2Area 5 Bus System")
    hvdc = only(get_components(TwoTerminalGenericHVDCLine, sys))
    from = get_from(get_arc(hvdc))
    to = get_to(get_arc(hvdc))
    set_loss!(hvdc, PSY.LossCurve(LinearCurve(0.0), PSY.CU))
    set_active_power_flow!(hvdc, 0.5 * u"SU")   # a stale system seed the optimization won't reproduce

    template = PowerOperationsProblemTemplate(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(DCPowerFlow()),
    )
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(
        template,
        DeviceModel(TwoTerminalGenericHVDCLine, HVDCTwoTerminalLossless),
    )
    model = DecisionModel(template, sys; name = "UC", optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    flow = _hvdc_flow(container, FlowActivePowerVariable, get_name(hvdc))
    data = _pf_hvdc_data(container)
    bus_lookup = PFS.get_bus_lookup(data)

    @test isapprox(
        data.bus_hvdc_net_power[bus_lookup[get_number(to)], :],
        flow;
        atol = 1e-6,
        rtol = 0,
    )
    @test isapprox(
        data.bus_hvdc_net_power[bus_lookup[get_number(from)], :],
        -1 .* flow;
        atol = 1e-6,
        rtol = 0,
    )
    # sanity: the optimized flow actually populates the channel (the fix does something)
    @test any(abs.(flow) .> 1e-4)
end

# Shared RTS setup for the AC-PF-in-the-loop HVDC tests: isolate the HVDC line buses (remove
# their injectors, retype the surrounding buses) and build a PTDF UC with an AC power-flow
# evaluation. `loss`/`stored_flow`, when given, overwrite the HVDC line's loss curve / stored
# flow. RTS is used because AC PF needs a single connected AC network containing the HVDC line
# (the small "2Area 5 Bus System" is two AC islands joined only by the DC line).
# TODO replace RTS with something smaller, so these test cases don't take so long.
function _build_rts_hvdc_acpf_model(hvdc_formulation; loss = nothing, stored_flow = nothing)
    sys = build_system(PSISystems, "RTS_GMLC_DA_sys")
    hvdc = only(get_components(TwoTerminalGenericHVDCLine, sys))
    from = get_from(get_arc(hvdc))
    to = get_to(get_arc(hvdc))
    isnothing(loss) || set_loss!(hvdc, loss)
    isnothing(stored_flow) || set_active_power_flow!(hvdc, stored_flow * u"SU")
    # remove components that impact total bus power at the HVDC line buses.
    injectors = collect(
        get_components(
            x -> get_number(get_bus(x)) ∈ (get_number(from), get_number(to)),
            StaticInjection,
            sys,
        ),
    )
    foreach(x -> remove_component!(sys, x), injectors)
    for bus_name in ("Chifa", "Arne")
        set_bustype!(get_component(PSY.ACBus, sys, bus_name), PSY.ACBusTypes.PQ)
    end
    set_bustype!(get_component(ACBus, sys, "Arthur"), ACBusTypes.REF)
    template = PowerOperationsProblemTemplate(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(ACPowerFlow()),
    )
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(
        template,
        DeviceModel(TwoTerminalGenericHVDCLine, hvdc_formulation),
    )
    model = DecisionModel(template, sys; name = "UC", optimizer = HiGHS_optimizer)
    return (; model, sys, hvdc, from, to)
end

@testset "generic HVDC with AC PF in the loop" begin
    (; model, sys, hvdc, from, to) = _build_rts_hvdc_acpf_model(HVDCTwoTerminalDispatch)
    @test build!(model; output_dir = mktempdir()) == ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    name = get_name(hvdc)
    from_to = _hvdc_flow(container, FlowActivePowerFromToVariable, name)
    to_from = _hvdc_flow(container, FlowActivePowerToFromVariable, name)
    data = _pf_hvdc_data(container)
    bus_lookup = PFS.get_bus_lookup(data)

    @test isapprox(
        data.bus_hvdc_net_power[bus_lookup[get_number(from)], :],
        -1 .* from_to;
        atol = 1e-9,
        rtol = 0,
    )
    @test all(data.bus_active_power_injections[bus_lookup[get_number(from)], :] .== 0.0)
    @test isapprox(
        data.bus_hvdc_net_power[bus_lookup[get_number(to)], :],
        -1 .* to_from;
        atol = 1e-9,
        rtol = 0,
    )
    @test all(data.bus_active_power_injections[bus_lookup[get_number(to)], :] .== 0.0)
end

@testset "lossless HVDC with AC PF in the loop" begin
    # HVDCTwoTerminalLossless exposes a single FlowActivePowerVariable (positive from->to); the
    # PF input-map falls back to it for both injection categories, so the to-bus must be +flow.
    # Regression for #1631 (was -flow, the directional FlowActivePowerToFromVariable convention).
    (; model, sys, hvdc, from, to) = _build_rts_hvdc_acpf_model(HVDCTwoTerminalLossless)
    @test build!(model; output_dir = mktempdir()) == ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    flow = _hvdc_flow(container, FlowActivePowerVariable, get_name(hvdc))
    data = _pf_hvdc_data(container)
    bus_lookup = PFS.get_bus_lookup(data)

    @test isapprox(
        data.bus_hvdc_net_power[bus_lookup[get_number(from)], :],
        -1 .* flow;
        atol = 1e-9,
        rtol = 0,
    )
    @test isapprox(
        data.bus_hvdc_net_power[bus_lookup[get_number(to)], :],
        flow;
        atol = 1e-9,
        rtol = 0,
    )
    @test all(data.bus_active_power_injections[bus_lookup[get_number(from)], :] .== 0.0)
    @test all(data.bus_active_power_injections[bus_lookup[get_number(to)], :] .== 0.0)
end

@testset "HVDC bus_hvdc_net_power is not double-counted (issue #1635)" begin
    # PSI must zero the construction-time HVDC seed before writing the optimized flow, else the
    # stale value stacks on top. Set an unreproducible stored flow (a deliberately large 0.5 pu
    # that would be obvious if it leaked), assert the channel holds only the optimized flow.
    (; model, sys, hvdc, from, to) = _build_rts_hvdc_acpf_model(
        HVDCTwoTerminalLossless; loss = PSY.LossCurve(LinearCurve(0.0), PSY.CU),
        stored_flow = 0.5)
    @test build!(model; output_dir = mktempdir()) == ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    flow = _hvdc_flow(container, FlowActivePowerVariable, get_name(hvdc))
    data = _pf_hvdc_data(container)
    bus_lookup = PFS.get_bus_lookup(data)

    # bus_hvdc_net_power must equal ONLY the optimized flow (the stale seed was cleared).
    @test isapprox(
        data.bus_hvdc_net_power[bus_lookup[get_number(to)], :],
        flow;
        atol = 1e-9,
        rtol = 0,
    )
end

@testset "AC Power Flow in the loop: Fast Decoupled (FDNR) matches Newton-Raphson" begin
    function pf_data_for(pf_eval)
        system = build_system(PSITestSystems, "c_sys5_uc")
        template = get_template_dispatch_with_network(
            NetworkModel(PTDFNetworkModel);
            evaluations = power_flow_evaluations(pf_eval),
        )
        model_m = DecisionModel(template, system; optimizer = HiGHS_optimizer)
        @test build!(model_m; output_dir = mktempdir(; cleanup = true)) ==
              ModelBuildStatus.BUILT
        @test solve!(model_m) == RunStatus.SUCCESSFULLY_FINALIZED
        container = get_optimization_container(model_m)
        return get_inner_data(only(values(get_evaluation_data(container))))
    end

    # Newton-Raphson reference (default `ACPolarPowerFlow` solver).
    nr_data = pf_data_for(ACPolarPowerFlow())
    @test all(PFS.get_converged(nr_data))
    # The FD solver tag does not change the container type: read-back uses the identical path.
    @test nr_data isa PFS.ACPowerFlowData

    # label => evaluator. Each must converge through the loop and match the NR reference.
    # Pure B′/B″ FD defaults to a loose 1e-3 tolerance (it converges only linearly), so those
    # evaluators are tightened to 1e-6. Compare at 10× that: the residual left at 1e-6 shows up
    # directly in the injections.
    fd_params = PFS.SolutionParameters(; tol = 1e-6)
    fd_evaluators = [
        "FDNR default (FDDecoupled/XB)" =>
            ACPolarPowerFlow{PFS.FastDecoupledACPowerFlow}(;
                solution_parameters = fd_params,
            ),
        "FDDecoupled/BX scheme" =>
            ACPolarPowerFlow{
                PFS.FastDecoupledACPowerFlow{PFS.FDDecoupled, PFS.FDSchemeBX},
            }(;
                solution_parameters = fd_params,
            ),
        "FDFixedJacobian (polar)" =>
            ACPolarPowerFlow{PFS.FastDecoupledFixed}(),
        "FastDecoupledXB alias" =>
            ACPolarPowerFlow{PFS.FastDecoupledXB}(; solution_parameters = fd_params),
        "FDNR handoff -> NewtonRaphson" =>
            ACPolarPowerFlow{PFS.FastDecoupledACPowerFlow}(;
                solution_parameters = PFS.SolutionParameters(;
                    handoff_solver = PFS.NewtonRaphsonACPowerFlow,
                    handoff_tol = 1e-3,
                ),
            ),
    ]

    for (label, pf_eval) in fd_evaluators
        @testset "$label" begin
            fd_data = pf_data_for(pf_eval)
            @test all(PFS.get_converged(fd_data))
            @test isapprox(fd_data.bus_magnitude, nr_data.bus_magnitude;
                atol = 1e-5, rtol = 0)
            @test isapprox(fd_data.bus_angles, nr_data.bus_angles;
                atol = 1e-5, rtol = 0)
            @test isapprox(
                fd_data.bus_active_power_injections,
                nr_data.bus_active_power_injections;
                atol = 1e-5, rtol = 0,
            )
            @test isapprox(
                fd_data.bus_reactive_power_injections,
                nr_data.bus_reactive_power_injections;
                atol = 1e-5, rtol = 0,
            )
        end
    end

    # `FDFixedJacobian` is formulation-agnostic: it must also work on the rectangular
    # formulation and recover the same physical state as the polar Newton-Raphson reference.
    @testset "FDFixedJacobian on rectangular formulation" begin
        rect_fd_data = pf_data_for(ACRectangularPowerFlow{PFS.FastDecoupledFixed}())
        @test all(PFS.get_converged(rect_fd_data))
        @test isapprox(rect_fd_data.bus_magnitude, nr_data.bus_magnitude;
            atol = 1e-6, rtol = 0)
        @test isapprox(rect_fd_data.bus_angles, nr_data.bus_angles;
            atol = 1e-6, rtol = 0)
    end

    # The classic `FDDecoupled` variant (B′/B″ half-iterations) is polar-only; PowerFlows
    # rejects it on the rectangular formulation at construction.
    @testset "FDDecoupled rejected on rectangular formulation" begin
        @test_throws ArgumentError ACRectangularPowerFlow{PFS.FastDecoupledXB}()
    end
end

@testset "PF evaluator reports convergence (issue #305)" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(ACPowerFlow(; correct_bustypes = true)),
    )
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    pf_e_data = only(values(get_evaluation_data(container)))

    # `is_solved` tracks what PowerFlows reported, instead of always `true`.
    @test is_solved(pf_e_data) == all(PFS.get_converged(get_inner_data(pf_e_data)))
    @test is_solved(pf_e_data)

    IOM.reset!(pf_e_data)
    @test !is_solved(pf_e_data)
end

@testset "Non-converged PF NaNs its aux vars without failing the run (issue #305)" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    # Copperplate dispatch + AC power flow over weak transmission: nodeB's 3.0 pu load
    # is fed only by lines "1" and "4", and 0.35 is hand-tuned so off-peak hours
    # converge and peak hours don't.
    for name in ("1", "4")
        set_x!(get_component(Line, system, name), 0.35 * u"SU")
    end
    template = get_thermal_dispatch_template_network(
        NetworkModel(CopperPlateNetworkModel);
        evaluations = power_flow_evaluations(ACPowerFlow(; correct_bustypes = true)),
    )
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    # A power flow that doesn't converge is an error in the log and NaN in the aux
    # vars, not a failed run: the optimization itself solved fine.
    @test solve!(model; console_level = Logging.AboveMaxLevel) ==
          RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    pf_e_data = only(values(get_evaluation_data(container)))
    converged = PFS.get_converged(get_inner_data(pf_e_data))
    # Partial failure, so `all(converged)` is doing real work here.
    @test !all(converged)
    @test any(converged)
    @test !is_solved(pf_e_data)

    # The read-back still runs per time step: NaN where the PF diverged, real values
    # where it converged.
    vm = lookup_value(container, AuxVarKey(POM.PowerFlowVoltageMagnitude, PSY.ACBus))
    for (t, t_converged) in enumerate(converged)
        @test all(t_converged ? isfinite : isnan, vm[:, t])
    end
end

# `PSSEExporter` owns no aux vars at all, and must not keep the AC power flow's from
# being written.
@testset "AC power flow alongside a PSS/E export (issue #308)" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    export_dir = mktempdir(; cleanup = true)
    evaluators = (
        ACPowerFlow(; correct_bustypes = true),
        PSSEExportPowerFlow(:v33, export_dir; overwrite = true),
    )
    evaluations = IOM.EvaluationContainer()
    for ev in evaluators
        IOM.add_evaluator!(evaluations, typeof(ev), POM.PowerFlowEvaluator(ev))
    end
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = evaluations,
    )
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    @test length(get_evaluation_data(container)) == 2
    # The exporter has nothing to converge, and reports solved either way.
    @test all(is_solved, values(get_evaluation_data(container)))
    @test !isempty(readdir(export_dir))

    # The AC evaluator's aux vars are still written.
    vm_key = AuxVarKey(POM.PowerFlowVoltageMagnitude, PSY.ACBus)
    vm = lookup_value(container, vm_key)
    @test all(v -> 0.8 < v < 1.2, vm)
    @test vm_key in IOM.get_bound_aux_var_keys(container, typeof(first(evaluators)))
    @test isempty(IOM.get_bound_aux_var_keys(container, typeof(last(evaluators))))
end

@testset "The PSS/E export System gets the optimized power of each device" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    # A device base that differs from the system base exercises the unit conversion.
    thermal = get_component(ThermalStandard, system, "Brighton")
    thermal.base_power = 50.0
    export_dir = mktempdir(; cleanup = true)
    evaluator = PSSEExportPowerFlow(:v33, export_dir; overwrite = true)
    evaluations = IOM.EvaluationContainer()
    IOM.add_evaluator!(evaluations, typeof(evaluator), POM.PowerFlowEvaluator(evaluator))
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = evaluations,
    )
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    export_system =
        PFS.get_system(get_inner_data(only(values(get_evaluation_data(container)))))
    # The exporter writes one time step at a time, so its System holds the last one.
    last_step = last(get_time_steps(container))
    for (device_type, sign) in ((ThermalStandard, 1.0), (PowerLoad, -1.0))
        contribution = lookup_value(
            container,
            ExpressionKey(POM.ActivePowerBalanceContribution, device_type),
        )
        for name in axes(contribution, 1)
            device = get_component(device_type, export_system, name)
            @test isapprox(
                get_active_power(device, u"SU"),
                sign * contribution[name, last_step];
                atol = 1e-8,
            )
        end
    end

    # A thermal value of zero would hide the unit conversion.
    @test !iszero(
        lookup_value(
            container,
            ExpressionKey(POM.ActivePowerBalanceContribution, ThermalStandard),
        )[
            "Brighton",
            last_step,
        ],
    )
    # A load value of zero would hide the sign.
    load_contribution =
        lookup_value(
            container,
            ExpressionKey(POM.ActivePowerBalanceContribution, PowerLoad),
        )
    @test any(
        name -> -load_contribution[name, last_step] > 1e-3,
        axes(load_contribution, 1),
    )
end

# The exporter System holds the last time step.
function _psse_export_system(container)
    return PFS.get_system(get_inner_data(only(values(get_evaluation_data(container)))))
end

function _psse_export_template(network_model)
    evaluator = PSSEExportPowerFlow(:v33, mktempdir(; cleanup = true); overwrite = true)
    return PowerOperationsProblemTemplate(
        network_model;
        evaluations = power_flow_evaluations(evaluator),
    )
end

function _build_psse_export_model(template, system, optimizer)
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranch)
    return DecisionModel(template, system; optimizer = optimizer)
end

@testset "The PSS/E export System splits a ZIP load into its three parts" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    _add_zip_load!(system)
    template = _psse_export_template(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, StandardLoad, StaticPowerLoad)
    model = _build_psse_export_model(template, system, HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    last_step = last(get_time_steps(container))
    total =
        -lookup_value(
            container,
            ExpressionKey(POM.ActivePowerBalanceContribution, StandardLoad),
        )[
            "zip_load",
            last_step,
        ]
    @test !iszero(total)
    load = get_component(StandardLoad, _psse_export_system(container), "zip_load")
    @test get_constant_active_power(load, u"SU") ≈ total * 0.2 / 0.6
    @test get_current_active_power(load, u"SU") ≈ total * 0.1 / 0.6
    @test get_impedance_active_power(load, u"SU") ≈ total * 0.3 / 0.6
    parts_sum =
        get_constant_active_power(load, u"SU") +
        get_current_active_power(load, u"SU") +
        get_impedance_active_power(load, u"SU")
    @test parts_sum ≈ total
end

@testset "A ZIP load whose parts cancel has no split" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    load = _add_zip_load!(system)
    load.max_impedance_active_power = -0.3
    load.max_current_active_power = 0.1
    load.max_constant_active_power = 0.2
    @test_throws ErrorException POM.zip_fractions(POM.ActivePowerTimeSeriesParameter, load)
    load.max_impedance_active_power = -0.1
    load.max_current_active_power = -0.2
    load.max_constant_active_power = 0.3
    @test_throws ErrorException POM.zip_fractions(POM.ActivePowerTimeSeriesParameter, load)
    load.max_impedance_active_power = 0.3
    load.max_current_active_power = 0.1
    load.max_constant_active_power = 0.2
    fractions = POM.zip_fractions(POM.ActivePowerTimeSeriesParameter, load)
    @test fractions.constant_power ≈ 1 / 3
    @test fractions.constant_current ≈ 1 / 6
    @test fractions.constant_impedance ≈ 1 / 2
end

# The PSS/E exporter does not build under an AC network model, so this test calls the System
# writer on the container of an AC model without an evaluator.
@testset "The System writer takes a switched shunt from the susceptance variable" begin
    system = build_system(PSITestSystems, "c_sys5")
    bus = first(get_components(ACBus, system))
    shunt = SwitchedAdmittance(;
        name = "shunt_cap",
        available = true,
        bus = bus,
        number_engaged = [1],
        number_of_steps = [2],
        Y_increase = [0.0 + 0.1im],
    )
    add_component!(system, shunt)
    template = PowerOperationsProblemTemplate(NetworkModel(ACPNetworkModel))
    set_device_model!(template, SwitchedAdmittance, ShuntSusceptanceDispatch)
    model = _build_psse_export_model(template, system, ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    susceptance = lookup_value(
        container,
        VariableKey(POM.ShuntSusceptanceVariable, SwitchedAdmittance),
    )
    ext = Base.get_extension(PowerOperationsModels, :PowerFlowsExt)
    for t in get_time_steps(container)
        ext._write_contribution!(
            container, shunt, ext.PFReactiveQuantity(), 0.0, 100.0, t,
        )
        @test get_solved_admittance(shunt) ≈ susceptance["shunt_cap", t]
    end
end

@testset "The System writer accepts only zero for a field that a type does not have" begin
    system = build_system(PSISystems, "sys10_pjm_ac_dc")
    bus = first(get_components(ACBus, system))
    condenser = SynchronousCondenser(;
        name = "condenser_1",
        available = true,
        bus = bus,
        reactive_power = 0.0,
        rating = 0.5,
        reactive_power_limits = (min = -0.5, max = 0.5),
        base_power = 100.0,
        active_power_losses = 0.0,
        input_basis = u"CU",
    )
    shunt = SwitchedAdmittance(;
        name = "shunt_1",
        available = true,
        bus = bus,
        number_engaged = [1],
        number_of_steps = [2],
        Y_increase = [0.0 + 0.1im],
    )
    facts = FACTSControlDevice(;
        name = "facts_1",
        available = true,
        bus = bus,
        control_mode = PSY.FACTSOperationModes.NML,
        input_basis = u"CU",
    )
    converter = first(get_components(InterconnectingConverter, system))
    ext = Base.get_extension(PowerOperationsModels, :PowerFlowsExt)
    active = ext.PFActiveQuantity()
    reactive = ext.PFReactiveQuantity()
    for (component, quantity) in
        ((condenser, active), (shunt, active), (facts, active), (converter, reactive))
        @test isnothing(ext._set_comp_quantity!(component, quantity, 0.0))
        @test_throws ErrorException ext._set_comp_quantity!(component, quantity, 0.1)
    end
    # The power flow solves the reactive power of a FACTS device, so the writer ignores it.
    @test isnothing(ext._set_comp_quantity!(facts, reactive, 0.1))
end

function _build_pump_model(template)
    system = build_system(
        PSITestSystems,
        "c_sys5_hydro_pump_energy";
        add_single_time_series = true,
    )
    transform_single_time_series!(system, Hour(24), Hour(24))
    pump = first(get_components(HydroPumpTurbine, system))
    set_bustype!(get_bus(pump), ACBusTypes.PV)
    set_device_model!(template, HydroPumpTurbine, HydroPumpEnergyDispatch)
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    container = get_optimization_container(model)
    limits = get_active_power_limits_pump(pump, u"SU")
    pump_power = (limits.min + limits.max) / 2
    pump_variable = IOM.get_variable(container, ActivePowerPumpVariable, HydroPumpTurbine)
    turbine_variable = IOM.get_variable(container, ActivePowerVariable, HydroPumpTurbine)
    # The unit pumps and does not generate, so its net contribution is below its turbine power.
    for t in get_time_steps(container)
        JuMP.fix(pump_variable[get_name(pump), t], pump_power; force = true)
        JuMP.fix(turbine_variable[get_name(pump), t], 0.0; force = true)
    end
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    return model, pump, pump_power
end

@testset "The PSS/E export System writes the turbine and pump power of a pump turbine" begin
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel; use_slacks = true);
        evaluations = power_flow_evaluations(
            PSSEExportPowerFlow(:v33, mktempdir(; cleanup = true); overwrite = true),
        ),
    )
    model, pump, pump_power = _build_pump_model(template)
    container = get_optimization_container(model)
    last_step = last(get_time_steps(container))
    name = get_name(pump)
    turbine = lookup_value(container, VariableKey(ActivePowerVariable, HydroPumpTurbine))
    exported = get_component(HydroPumpTurbine, _psse_export_system(container), name)
    @test pump_power > 1e-3
    @test get_active_power_pump(exported, u"SU") ≈ pump_power
    @test get_active_power(exported, u"SU") ≈ turbine[name, last_step]
end

@testset "Headroom of a pumping pump turbine is its limit minus the turbine power" begin
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel; use_slacks = true);
        evaluations = power_flow_evaluations(
            ACPowerFlow(;
                distribute_slack_proportional_to_headroom = true,
                correct_bustypes = true,
            ),
        ),
    )
    model, pump, pump_power = _build_pump_model(template)
    container = get_optimization_container(model)
    name = get_name(pump)
    turbine = lookup_value(container, VariableKey(ActivePowerVariable, HydroPumpTurbine))
    p_max = PFS.get_active_power_limits_for_power_flow(pump, u"SU").max
    computed_gspf = PFS.get_computed_gspf(
        get_inner_data(only(values(get_evaluation_data(container)))),
    )
    @test pump_power > 1e-3
    for t in get_time_steps(container)
        entry = computed_gspf[t][(HydroPumpTurbine, name)]
        @test entry <= p_max
        @test entry ≈ p_max - turbine[name, t]
    end
end

_pf_category(::IOM.ExpressionKey{POM.ActivePowerBalanceContribution}) = :active_power
_pf_category(::IOM.ExpressionKey{POM.ReactivePowerBalanceContribution}) = :reactive_power
_pf_category(::IOM.OptimizationContainerKey) = :none

# Input map of the System writer: every contribution row, by device name.
function _system_writer_input_map(container)
    input_map = Dict{Symbol, Dict{IOM.OptimizationContainerKey, Any}}()
    for (key, contribution) in IOM.get_expressions(container)
        category = _pf_category(key)
        if category != :none
            names = Dict(name => name for name in axes(contribution, 1))
            get!(input_map, category, Dict{IOM.OptimizationContainerKey, Any}())[key] =
                names
        end
    end
    return input_map
end

const _PF_INJECTION_ARRAYS = (
    :bus_active_power_injections,
    :bus_reactive_power_injections,
    :bus_active_power_withdrawals,
    :bus_active_power_constant_current_withdrawals,
    :bus_active_power_constant_impedance_withdrawals,
    :bus_reactive_power_withdrawals,
    :bus_reactive_power_constant_current_withdrawals,
    :bus_reactive_power_constant_impedance_withdrawals,
)

# The `PowerFlowData` that POM writes equals the `PowerFlowData` built from a System that holds
# the same values.
@testset "ACP PF in the loop writes the arrays that a System build gives" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    zip_load = _add_zip_load!(system)
    zip_load.max_constant_reactive_power = 0.04
    zip_load.max_current_reactive_power = 0.02
    zip_load.max_impedance_reactive_power = 0.06
    zip_load.constant_reactive_power = 0.04
    zip_load.current_reactive_power = 0.02
    zip_load.impedance_reactive_power = 0.06
    template = PowerOperationsProblemTemplate(
        NetworkModel(ACPNetworkModel);
        evaluations = power_flow_evaluations(ACPowerFlow(; correct_bustypes = true)),
    )
    set_device_model!(template, StandardLoad, StaticPowerLoad)
    model = _build_psse_export_model(template, system, ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    container = get_optimization_container(model)
    data = get_inner_data(only(values(get_evaluation_data(container))))

    last_step = last(get_time_steps(container))
    ext = Base.get_extension(PowerOperationsModels, :PowerFlowsExt)
    ext.update_pf_system!(system, container, _system_writer_input_map(container), last_step)
    expected = PFS.PowerFlowData(ACPowerFlow(; correct_bustypes = true), system)
    for name in _PF_INJECTION_ARRAYS
        written = getproperty(data, name)[:, last_step]
        @test any(!iszero, written) ||
              name == :bus_active_power_constant_current_withdrawals
        # Ipopt leaves bound violations of about 1e-6 in the injections.
        @test written ≈ getproperty(expected, name)[:, 1] atol = 1e-5
    end
    @test any(!iszero, data.bus_reactive_power_constant_impedance_withdrawals)
end

_is_generation_key(
    ::IOM.ExpressionKey{POM.ActivePowerBalanceContribution, <:PSY.Generator},
) = true
_is_generation_key(::IOM.OptimizationContainerKey) = false

function _generation_at_bus(container, system, bus_number, t)
    total = 0.0
    for key in keys(IOM.get_expressions(container))
        if _is_generation_key(key)
            V = IOM.get_component_type(key)
            contribution = lookup_value(container, key)
            for name in axes(contribution, 1)
                if get_number(get_bus(get_component(V, system, name))) == bus_number
                    total += contribution[name, t]
                end
            end
        end
    end
    return total
end

@testset "AC PF in the loop sends the power of a converter once" begin
    system = build_system(PSISystems, "sys10_pjm_ac_dc")
    template = PowerOperationsProblemTemplate(
        NetworkModel(PTDFNetworkModel; use_slacks = true);
        evaluations = power_flow_evaluations(ACPowerFlow(; correct_bustypes = true)),
    )
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, DeviceModel(InterconnectingConverter, LosslessConverter))
    set_device_model!(template, DeviceModel(TModelHVDCLine, LosslessLine))
    set_hvdc_network_model!(template, TransportHVDCNetworkModel)
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer, horizon = Hour(2))
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    container = get_optimization_container(model)
    data = get_inner_data(only(values(get_evaluation_data(container))))
    dcn = PFS.get_dc_network(data)
    converter_power = lookup_value(
        container,
        ExpressionKey(POM.ActivePowerBalanceContribution, InterconnectingConverter),
    )
    n_power_control = 0
    for converter in get_components(InterconnectingConverter, system)
        name = get_name(converter)
        c = only(findall(==(name), dcn.converter_name))
        bus_ix = PFS.get_bus_lookup(data)[get_number(get_bus(converter))]
        for t in get_time_steps(container)
            # The bus injection holds the generators of the bus only.
            generation =
                _generation_at_bus(container, system, get_number(get_bus(converter)), t)
            # The solve sets the injection of the reference bus.
            if PFS.get_bus_type(data)[bus_ix, t] != ACBusTypes.REF
                @test data.bus_active_power_injections[bus_ix, t] ≈ generation atol = 1e-8
            end
            if !iszero(dcn.p_set[c, t])
                n_power_control += 1
                @test dcn.p_set[c, t] ≈ converter_power[name, t]
            end
        end
    end
    @test n_power_control > 0
end

@testset "AC PF in the loop writes the susceptance of a modeled shunt" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    bus = get_component(ACBus, system, "nodeC")
    shunt = SwitchedAdmittance(;
        name = "shunt_nodeC",
        available = true,
        bus = bus,
        number_engaged = [1],
        number_of_steps = [2],
        Y_increase = [0.02 + 0.1im],
    )
    add_component!(system, shunt)
    expected_data = PFS.PowerFlowData(ACPowerFlow(; correct_bustypes = true), system)
    bus_ix = PFS.get_bus_lookup(expected_data)[get_number(bus)]
    expected_q = expected_data.bus_reactive_power_constant_impedance_withdrawals[bus_ix, 1]
    expected_p = expected_data.bus_active_power_constant_impedance_withdrawals[bus_ix, 1]
    @test !iszero(expected_q)
    @test !iszero(expected_p)

    template = PowerOperationsProblemTemplate(
        NetworkModel(ACPNetworkModel);
        evaluations = power_flow_evaluations(ACPowerFlow(; correct_bustypes = true)),
    )
    set_device_model!(template, SwitchedAdmittance, ShuntSusceptanceDispatch)
    model = _build_psse_export_model(template, system, ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    container = get_optimization_container(model)
    # The System susceptance is 0.1 p.u. The model value differs, so the test shows which one
    # PowerFlows gets.
    model_b = 0.15
    variable = IOM.get_variable(container, POM.ShuntSusceptanceVariable, SwitchedAdmittance)
    for t in get_time_steps(container)
        JuMP.fix(variable["shunt_nodeC", t], model_b; force = true)
    end
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    data = get_inner_data(only(values(get_evaluation_data(container))))
    for t in get_time_steps(container)
        @test data.bus_reactive_power_constant_impedance_withdrawals[bus_ix, t] ≈
              expected_q * model_b / 0.1
        @test data.bus_active_power_constant_impedance_withdrawals[bus_ix, t] ≈ expected_p
    end
end

# Every DC power flow provides the branch active power flows, and so does the AC power
# flow: the two cannot both write them.
@testset "Power flows that provide the same aux var fail the build" begin
    ac = ACPowerFlow(; correct_bustypes = true)
    for evaluators in ((DCPowerFlow(), ac), (ac, DCPowerFlow()))
        system = build_system(PSITestSystems, "c_sys5_uc")
        evaluations = IOM.EvaluationContainer()
        for ev in evaluators
            IOM.add_evaluator!(evaluations, typeof(ev), POM.PowerFlowEvaluator(ev))
        end
        template = get_template_dispatch_with_network(
            NetworkModel(PTDFNetworkModel);
            evaluations = evaluations,
        )
        model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
        output_dir = mktempdir(; cleanup = true)
        @test build!(
            model;
            output_dir = output_dir,
            console_level = Logging.AboveMaxLevel,
        ) == ModelBuildStatus.FAILED
        log = read(joinpath(output_dir, "operation_problem.log"), String)
        @test occursin("is already bound to $(typeof(first(evaluators)))", log)
        @test occursin("$(typeof(last(evaluators))) cannot also produce it", log)
    end
end

# DC power flow on PTDF reproduces the optimization's PTDF flows exactly when every device
# reaches the PF with the injection it has in the nodal balance.
function _test_dc_pf_matches_ptdf_flows(container)
    ptdf_flow = IOM.get_expression(container, POM.PTDFBranchFlow, Line)
    ft_aux = lookup_value(container, AuxVarKey(POM.PowerFlowBranchActivePowerFromTo, Line))
    for line_name in axes(ptdf_flow, 1), t in get_time_steps(container)
        @test isapprox(JuMP.value(ptdf_flow[line_name, t]), ft_aux[line_name, t];
            atol = 1e-3)
    end
end

function _solve_dc_pf_model(system, template)
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    return get_optimization_container(model)
end

_dc_pf_template() = get_template_dispatch_with_network(
    NetworkModel(PTDFNetworkModel; use_slacks = true);
    evaluations = power_flow_evaluations(DCPowerFlow()),
)

@testset "PF in the loop includes storage in/out power (issue #379)" begin
    system = build_system(PSITestSystems, "c_sys5_bat")
    template = _dc_pf_template()
    set_device_model!(template, EnergyReservoirStorage, StorageDispatchWithReserves)
    container = _solve_dc_pf_model(system, template)

    p_out =
        lookup_value(container, VariableKey(ActivePowerOutVariable, EnergyReservoirStorage))
    p_in =
        lookup_value(container, VariableKey(ActivePowerInVariable, EnergyReservoirStorage))
    # Without a non-zero net storage injection the flow comparison cannot see the bug.
    @test any(abs.(p_out .- p_in) .> 1e-3)
    _test_dc_pf_matches_ptdf_flows(container)
end

@testset "PF in the loop withdraws controllable load consumption (issue #379)" begin
    system = build_system(PSITestSystems, "c_sys5_il")
    # The fixture's willingness to pay is below every generator's cost, so the load would
    # be dispatched to zero and the flow comparison could not see its sign. The load also
    # sits on the reference bus, where DC PF absorbs any mismatch without changing a flow,
    # so move it to a PQ bus.
    for load in get_components(InterruptiblePowerLoad, system)
        set_bus!(load, get_component(ACBus, system, "nodeB"))
        set_operation_cost!(
            load,
            LoadCost(;
                variable_operation_cost = CostCurve(LinearCurve(1000.0)),
                fixed = 0.0,
            ),
        )
    end
    template = _dc_pf_template()
    set_device_model!(template, InterruptiblePowerLoad, PowerLoadDispatch)
    container = _solve_dc_pf_model(system, template)

    p_load =
        lookup_value(container, VariableKey(ActivePowerVariable, InterruptiblePowerLoad))
    @test any(p_load .> 1e-3)
    _test_dc_pf_matches_ptdf_flows(container)
end

@testset "PF in the loop withdraws a motor load (issue #396)" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    _add_motor_load!(system, get_component(PowerLoad, system, "Bus2"))
    template = _dc_pf_template()
    set_device_model!(template, MotorLoad, StaticPowerLoad)
    container = _solve_dc_pf_model(system, template)
    _test_dc_pf_matches_ptdf_flows(container)
end

@testset "PF in the loop withdraws a shifted load (issue #396)" begin
    system = _shiftable_load_system()
    # DC PF absorbs any mismatch at the reference bus, so move the load to a PQ bus.
    set_bus!(
        get_component(ShiftablePowerLoad, system, "shiftable_load"),
        get_component(ACBus, system, "nodeB"),
    )

    template = _dc_pf_template()
    set_device_model!(template, ShiftablePowerLoad, PowerLoadShift)
    container = _solve_dc_pf_model(system, template)
    _test_dc_pf_matches_ptdf_flows(container)
end

@testset "PF in the loop withdraws hydro pump power (issue #396)" begin
    system = build_system(
        PSITestSystems,
        "c_sys5_hydro_pump_energy";
        add_single_time_series = true,
    )
    transform_single_time_series!(system, Hour(24), Hour(24))
    pump = first(get_components(HydroPumpTurbine, system))
    name = get_name(pump)
    @test get_bustype(get_bus(pump)) != ACBusTypes.REF
    template = _dc_pf_template()
    set_device_model!(template, HydroPumpTurbine, HydroPumpEnergyDispatch)
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    container = get_optimization_container(model)

    # Without a pumping time step the flow comparison cannot see the pump withdrawal.
    limits = get_active_power_limits_pump(pump, u"SU")
    pump_power = (limits.min + limits.max) / 2
    pump_variable = IOM.get_variable(container, ActivePowerPumpVariable, HydroPumpTurbine)
    JuMP.fix(pump_variable[name, 1], pump_power; force = true)
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    result = lookup_value(container, VariableKey(ActivePowerPumpVariable, HydroPumpTurbine))
    @test result[name, 1] ≈ pump_power
    @test result[name, 1] > 1e-3
    _test_dc_pf_matches_ptdf_flows(container)
end

@testset "PF in the loop reads compact thermal output" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    template = _dc_pf_template()
    set_device_model!(template, ThermalStandard, ThermalCompactUnitCommitment)
    container = _solve_dc_pf_model(system, template)

    for aux_type in
        (POM.PowerFlowBranchActivePowerFromTo, POM.PowerFlowBranchActivePowerToFrom)
        flows = lookup_value(container, AuxVarKey(aux_type, Line))
        @test all(isfinite, flows)
    end
    _test_dc_pf_matches_ptdf_flows(container)
end

_ac_pf_template() = get_template_dispatch_with_network(
    NetworkModel(PTDFNetworkModel; use_slacks = true);
    evaluations = power_flow_evaluations(ACPowerFlow(; correct_bustypes = true)),
)

@testset "AC PF in the loop keeps the voltage dependence of a ZIP load" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    bus = get_component(ACBus, system, "nodeA")
    zip_load = StandardLoad(;
        name = "zip_load",
        available = true,
        bus = bus,
        base_power = 100.0,
        constant_active_power = 0.2,
        constant_reactive_power = 0.0,
        current_active_power = 0.1,
        current_reactive_power = 0.0,
        impedance_active_power = 0.3,
        impedance_reactive_power = 0.0,
        max_constant_active_power = 0.2,
        max_constant_reactive_power = 0.0,
        max_current_active_power = 0.1,
        max_current_reactive_power = 0.0,
        max_impedance_active_power = 0.3,
        max_impedance_reactive_power = 0.0,
        input_basis = u"CU",
    )
    add_component!(system, zip_load)
    copy_time_series!(zip_load, get_component(PowerLoad, system, "Bus2"))

    template = _ac_pf_template()
    set_device_model!(template, StandardLoad, StaticPowerLoad)
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    container = get_optimization_container(model)

    data = get_inner_data(only(values(get_evaluation_data(container))))
    contribution = lookup_value(
        container,
        ExpressionKey(POM.ActivePowerBalanceContribution, StandardLoad),
    )
    bus_ix = PFS.get_bus_lookup(data)[get_number(bus)]
    for t in get_time_steps(container)
        withdrawal = -contribution["zip_load", t]
        @test !iszero(withdrawal)
        @test data.bus_active_power_withdrawals[bus_ix, t] ≈ withdrawal / 3
        @test data.bus_active_power_constant_current_withdrawals[bus_ix, t] ≈
              withdrawal / 6
        @test data.bus_active_power_constant_impedance_withdrawals[bus_ix, t] ≈
              withdrawal / 2
    end
end

@testset "AC PF in the loop keeps a switched shunt that the optimization does not model" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    bus = get_component(ACBus, system, "nodeC")
    shunt = SwitchedAdmittance(;
        name = "shunt_nodeC",
        available = true,
        bus = bus,
        number_engaged = [3],
        number_of_steps = [4],
        Y_increase = [0.02 + 0.05im],
        voltage_limits = (min = 0.9, max = 1.1),
        control_mode = PSY.SwitchedAdmittanceControlMode.DISCRETE_VOLTAGE,
    )
    add_component!(system, shunt)
    expected_data = PFS.PowerFlowData(ACPowerFlow(; correct_bustypes = true), system)
    bus_ix = PFS.get_bus_lookup(expected_data)[get_number(bus)]
    expected = expected_data.bus_reactive_power_constant_impedance_withdrawals[bus_ix, 1]
    @test !iszero(expected)

    model = DecisionModel(_ac_pf_template(), system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    container = get_optimization_container(model)

    data = get_inner_data(only(values(get_evaluation_data(container))))
    for t in get_time_steps(container)
        @test data.bus_reactive_power_constant_impedance_withdrawals[bus_ix, t] ≈ expected
    end
end

@testset "PF in the loop updates off-area load power per time step" begin
    sys = PSB.build_system(
        PSB.PSISystems,
        "two_area_pjm_DA_off_area_load";
        add_reserves = false,
        force_build = true,
    )
    # Area1 holds the REF bus; Area2 needs its own area slack to be controlled.
    set_bustype!(get_component(ACBus, sys, "Bus_nodeA_2"), PSY.ACBusTypes.SLACK)
    # Area1 owns a load that sits at a bus of Area2. The load has a time series.
    load = get_component(PowerLoad, sys, "Bus2_2")
    set_out_of_area_loads!(get_component(Area, sys, "Area1"), PSY.ElectricLoad[load])
    set_scheduled_net_interchange!(get_component(Area, sys, "Area1"), 30.0u"MW")
    set_scheduled_net_interchange!(get_component(Area, sys, "Area2"), -30.0u"MW")
    transform_single_time_series!(sys, Hour(24), Hour(1))

    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(
            ACPolarPowerFlow(;
                correct_bustypes = true,
                net_interchange_control = true,
                tie_definition = PFS.LinesAndLoads(),
            ),
        ),
    )
    model = DecisionModel(
        template,
        sys;
        resolution = Hour(1),
        optimizer = HiGHS_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    data = get_inner_data(only(values(get_evaluation_data(container))))
    @test PFS.has_off_area_load(data, "Bus2_2")
    @test !PFS.has_off_area_load(data, "Bus3_2")

    bus_ix = PFS.get_bus_lookup(data)[get_number(get_bus(load))]
    record = only(
        r for r in PFS.get_area_interchange_data(data).pristine_off_area_loads if
        r.name == "Bus2_2"
    )
    time_steps = get_time_steps(container)
    # The load changes between time steps, so a stale record would fail this.
    @test length(unique(round.(record.p_constant_power; digits = 8))) > 1
    for t in time_steps
        @test record.p_constant_power[t] ≈ data.bus_active_power_withdrawals[bus_ix, t]
        @test iszero(record.p_constant_current[t])
        @test iszero(record.p_constant_impedance[t])
    end
end

@testset "PF in the loop writes the area schedule per time step" begin
    sys = PSB.build_system(
        PSB.PSISystems,
        "two_area_pjm_DA_off_area_load";
        add_reserves = false,
        force_build = true,
    )
    # Area1 holds the REF bus; Area2 needs its own area slack to be controlled.
    set_bustype!(get_component(ACBus, sys, "Bus_nodeA_2"), PSY.ACBusTypes.SLACK)
    set_scheduled_net_interchange!(get_component(Area, sys, "Area1"), 0.0u"MW")
    set_scheduled_net_interchange!(get_component(Area, sys, "Area2"), 0.0u"MW")
    load_ts = first(get_time_series_multiple(first(get_components(PowerLoad, sys))))
    stamps = TimeSeries.timestamp(get_data(load_ts))
    series_mw = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0]
    values_mw = repeat(series_mw; outer = cld(length(stamps), length(series_mw)))
    for (area_name, sign) in (("Area1", 1.0), ("Area2", -1.0))
        add_time_series!(
            sys,
            get_component(Area, sys, area_name),
            SingleTimeSeries(
                "scheduled_net_interchange",
                TimeArray(stamps, sign .* values_mw[1:length(stamps)]),
            ),
        )
    end
    transform_single_time_series!(sys, Hour(24), Hour(1))

    template = get_template_dispatch_with_network(
        NetworkModel(AreaPTDFNetworkModel);
        evaluations = power_flow_evaluations(
            ACPolarPowerFlow(;
                correct_bustypes = true,
                net_interchange_control = true,
            ),
        ),
    )
    set_device_model!(template, AreaInterchange, StaticBranch)
    model = DecisionModel(
        template,
        sys;
        resolution = Hour(1),
        optimizer = HiGHS_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    container = get_optimization_container(model)
    data = get_inner_data(only(values(get_evaluation_data(container))))
    @test PFS.has_controlled_area(data, "Area2")
    @test !PFS.has_controlled_area(data, "Area1")
    base = get_model_base_power(container)
    area2 = only(
        a for a in PFS.get_area_interchange_data(data).pristine_areas if a.name == "Area2"
    )
    expected = -repeat(series_mw; outer = 4)[1:24] ./ base
    @test length(area2.pdes) == length(expected)
    @test area2.pdes ≈ expected
end

@testset "PF in the loop keeps the condenser losses" begin
    system = build_system(PSITestSystems, "c_sys5_uc")
    bus = get_component(ACBus, system, "nodeA")
    condenser = SynchronousCondenser(;
        name = "condenser_1",
        available = true,
        bus = bus,
        reactive_power = 0.0,
        rating = 0.5,
        reactive_power_limits = (min = -0.5, max = 0.5),
        base_power = 100.0,
        active_power_losses = 0.02,
        input_basis = u"CU",
    )
    add_component!(system, condenser)
    container = _solve_dc_pf_model(system, _dc_pf_template())
    data = get_inner_data(only(values(get_evaluation_data(container))))
    bus_ix = PFS.get_bus_lookup(data)[get_number(bus)]
    losses = get_active_power_losses(condenser, u"SU")
    @test !iszero(losses)
    for t in get_time_steps(container)
        @test data.bus_active_power_withdrawals[bus_ix, t] ≈ losses
    end
end
