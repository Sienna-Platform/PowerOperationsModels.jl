import PowerNetworkMatrices as PNM

# `case11_network_reductions` under RadialReduction + DegreeTwoReduction exercises every
# reduction shape the native formulations must handle:
#   - radial:            "1-8-i_1" absorbed entirely (bus 8 -> 1), no arc entry
#   - series chain:      arc (1,2) = "1-6-i_1" + "6-7-i_1" + "7-2-i_1"
#   - cross-type chain:  arc (1,5) = Line "1-9-i_1" + Transformer2W "9-5-i_1"
#   - parallel:          arc (1,4) = "1-4-i_1" ∥ "1-4-i_2" -> entry "1-4-i_double_circuit"
#   - parallel-in-chain: arc (2,3) = "10-3-i_1" + ("2-10-i_1" ∥ "2-10-i_2")
#   - direct:            arc (4,5) = "4-5-i_1"
# Distinct reduced arcs across both branch types: (1,2), (1,4), (1,5), (2,3), (3,4), (4,5).
const CASE11_DISTINCT_REDUCED_ARCS = 6

function _case11_with_forecast()
    sys = PSB.build_system(PSITestSystems, "case11_network_reductions")
    dummy_data = Dict(
        DateTime("2020-01-01T08:00:00") => [5.0, 6, 7, 7, 7],
        DateTime("2020-01-01T08:30:00") => [9.0, 9, 9, 9, 8],
        DateTime("2020-01-01T09:00:00") => [6.0, 6, 5, 5, 4],
    )
    dummy_forecast = Deterministic("max_active_power", dummy_data, Dates.Minute(5))
    load = first(get_components(StandardLoad, sys))
    add_time_series!(sys, load, dummy_forecast)
    return sys
end

function _solve_case11_native(
    network_formulation,
    optimizer;
    reduce::Bool = false,
    reduce_radial_branches::Bool = reduce,
    reduce_degree_two_branches::Bool = reduce,
)
    sys = _case11_with_forecast()
    net = NetworkModel(
        network_formulation;
        reduce_radial_branches = reduce_radial_branches,
        reduce_degree_two_branches = reduce_degree_two_branches,
    )
    template = get_thermal_dispatch_template_network(net)
    model = DecisionModel(template, sys; optimizer = optimizer)
    build_status = build!(
        model;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.Error,
    )
    return model, build_status
end

# Branch-axis names of one POM.NetworkFlowConstraint container, asserting every entry is
# assigned (no #undef holes from skipped branches). Missing container -> empty axis
# (e.g. every arc of that type was claimed by the other branch type's constructor).
function _assigned_flow_constraint_axis(container, key)
    constraints = IOM.get_constraints(container)
    if !haskey(constraints, key)
        return String[]
    end
    cons = constraints[key]
    for idx in eachindex(cons.data)
        @test isassigned(cons.data, idx)
    end
    return collect(axes(cons)[1])
end

@testset "native DCP reduction: one corridor per reduced arc, exact parity" begin
    model_red, status_red =
        _solve_case11_native(DCPNetworkModel, HiGHS_optimizer; reduce = true)
    @test status_red == IOM.ModelBuildStatus.BUILT
    @test solve!(model_red) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(model_red)

    # Ohm's law built exactly once per reduced arc, across both branch types.
    n_flow_cons =
        length(
            _assigned_flow_constraint_axis(
                container, IOM.ConstraintKey(POM.NetworkFlowConstraint, Line),
            ),
        ) + length(
            _assigned_flow_constraint_axis(
                container, IOM.ConstraintKey(POM.NetworkFlowConstraint, Transformer2W),
            ),
        )
    @test n_flow_cons == CASE11_DISTINCT_REDUCED_ARCS

    # The radially-absorbed branch must not appear anywhere.
    pvar_line = IOM.get_variable(container, FlowActivePowerVariable, Line)
    @test !("1-8-i_1" in axes(pvar_line)[1])

    # Members of one reduced arc share the same underlying JuMP variable.
    t1 = first(IOM.get_time_steps(container))
    @test pvar_line["1-6-i_1", t1] === pvar_line["6-7-i_1", t1]
    @test pvar_line["6-7-i_1", t1] === pvar_line["7-2-i_1", t1]
    # Parallel members enter under the equivalent entry name.
    @test "1-4-i_double_circuit" in axes(pvar_line)[1]
    @test !("1-4-i_1" in axes(pvar_line)[1])
    # Cross-type chain: the Line segment and the Transformer2W segment alias one variable.
    pvar_xfmr = IOM.get_variable(container, FlowActivePowerVariable, Transformer2W)
    @test pvar_line["1-9-i_1", t1] === pvar_xfmr["9-5-i_1", t1]

    # DC power flow is exactly invariant under radial + degree-two reduction, so the
    # reduced and unreduced problems must agree to solver tolerance.
    model_full, status_full =
        _solve_case11_native(DCPNetworkModel, HiGHS_optimizer; reduce = false)
    @test status_full == IOM.ModelBuildStatus.BUILT
    @test solve!(model_full) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    obj_red = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_red))
    obj_full = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_full))
    @test isapprox(obj_red, obj_full; rtol = 1e-6)

    # The direct (un-reduced) line carries the same flow in both problems.
    res_red = IOM.OptimizationProblemOutputs(model_red)
    res_full = IOM.OptimizationProblemOutputs(model_full)
    pf_red = read_variable(
        res_red, "FlowActivePowerVariable__Line"; table_format = TableFormat.WIDE,
    )
    pf_full = read_variable(
        res_full, "FlowActivePowerVariable__Line"; table_format = TableFormat.WIDE,
    )
    @test isapprox(pf_red[1, "4-5-i_1"], pf_full[1, "4-5-i_1"]; atol = 1e-4)
end

@testset "native DCP reduction: radial-only and degree-two-only isolated" begin
    # Each reduction kind alone must change the branch-variable topology in its own way:
    # radial reduction absorbs the radial leaf but leaves the degree-two series chain as
    # distinct variables, and degree-two reduction does the opposite. These structural
    # checks discriminate a broken single-kind reduction; the objective-parity assertions
    # below are exact (DC flow is invariant under either kind) but not discriminating on
    # this system, so they are a secondary guard.
    model_both, status_both =
        _solve_case11_native(DCPNetworkModel, HiGHS_optimizer; reduce = true)
    @test status_both == IOM.ModelBuildStatus.BUILT
    @test solve!(model_both) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    obj_both = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_both))

    model_none, status_none =
        _solve_case11_native(DCPNetworkModel, HiGHS_optimizer; reduce = false)
    @test status_none == IOM.ModelBuildStatus.BUILT
    @test solve!(model_none) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    obj_none = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_none))

    # Radial-only: the radial leaf "1-8-i_1" is absorbed, but with degree-two reduction
    # OFF the (1,2) series-chain segments stay three DISTINCT flow variables.
    model_rad, status_rad = _solve_case11_native(
        DCPNetworkModel, HiGHS_optimizer;
        reduce_radial_branches = true, reduce_degree_two_branches = false,
    )
    @test status_rad == IOM.ModelBuildStatus.BUILT
    @test solve!(model_rad) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    container_rad = IOM.get_optimization_container(model_rad)
    pvar_rad = IOM.get_variable(container_rad, FlowActivePowerVariable, Line)
    t1_rad = first(IOM.get_time_steps(container_rad))
    @test !("1-8-i_1" in axes(pvar_rad)[1])
    @test "1-6-i_1" in axes(pvar_rad)[1]
    @test "6-7-i_1" in axes(pvar_rad)[1]
    @test "7-2-i_1" in axes(pvar_rad)[1]
    @test pvar_rad["1-6-i_1", t1_rad] !== pvar_rad["6-7-i_1", t1_rad]
    @test pvar_rad["6-7-i_1", t1_rad] !== pvar_rad["7-2-i_1", t1_rad]
    obj_rad = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_rad))
    @test isapprox(obj_rad, obj_both; rtol = 1e-6)
    @test isapprox(obj_rad, obj_none; rtol = 1e-6)

    # Degree-two-only: with radial reduction OFF the radial leaf "1-8-i_1" is STILL
    # present, and the series chain IS aliased to a single flow variable.
    model_deg, status_deg = _solve_case11_native(
        DCPNetworkModel, HiGHS_optimizer;
        reduce_radial_branches = false, reduce_degree_two_branches = true,
    )
    @test status_deg == IOM.ModelBuildStatus.BUILT
    @test solve!(model_deg) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    container_deg = IOM.get_optimization_container(model_deg)
    pvar_deg = IOM.get_variable(container_deg, FlowActivePowerVariable, Line)
    t1_deg = first(IOM.get_time_steps(container_deg))
    @test "1-8-i_1" in axes(pvar_deg)[1]
    @test pvar_deg["1-6-i_1", t1_deg] === pvar_deg["6-7-i_1", t1_deg]
    @test pvar_deg["6-7-i_1", t1_deg] === pvar_deg["7-2-i_1", t1_deg]
    obj_deg = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_deg))
    @test isapprox(obj_deg, obj_both; rtol = 1e-6)
    @test isapprox(obj_deg, obj_none; rtol = 1e-6)
end

@testset "native ACP reduction: one corridor per reduced arc, exact parity" begin
    model_red, status_red =
        _solve_case11_native(ACPNetworkModel, ipopt_optimizer; reduce = true)
    @test status_red == IOM.ModelBuildStatus.BUILT
    @test solve!(model_red) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(model_red)

    # Four directional Ohm's-law constraints (p_ft/q_ft/p_tf/q_tf) per reduced arc,
    # each built exactly once across both branch types.
    for meta in ("p_ft", "q_ft", "p_tf", "q_tf")
        n =
            length(
                _assigned_flow_constraint_axis(
                    container, IOM.ConstraintKey(POM.NetworkFlowConstraint, Line, meta),
                ),
            ) + length(
                _assigned_flow_constraint_axis(
                    container,
                    IOM.ConstraintKey(POM.NetworkFlowConstraint, Transformer2W, meta),
                ),
            )
        @test n == CASE11_DISTINCT_REDUCED_ARCS
    end

    # Directional flow variables alias per reduced arc, including across types.
    t1 = first(IOM.get_time_steps(container))
    pft_line = IOM.get_variable(container, FlowActivePowerFromToVariable, Line)
    @test !("1-8-i_1" in axes(pft_line)[1])
    @test pft_line["1-6-i_1", t1] === pft_line["6-7-i_1", t1]
    @test pft_line["6-7-i_1", t1] === pft_line["7-2-i_1", t1]
    @test "1-4-i_double_circuit" in axes(pft_line)[1]
    pft_xfmr = IOM.get_variable(container, FlowActivePowerFromToVariable, Transformer2W)
    @test pft_line["1-9-i_1", t1] === pft_xfmr["9-5-i_1", t1]

    # The PNM series/parallel equivalents are exact two-port reductions, so the AC
    # solution (and objective) must match the unreduced problem.
    model_full, status_full =
        _solve_case11_native(ACPNetworkModel, ipopt_optimizer; reduce = false)
    @test status_full == IOM.ModelBuildStatus.BUILT
    @test solve!(model_full) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    obj_red = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_red))
    obj_full = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_full))
    @test isapprox(obj_red, obj_full; rtol = 1e-5)
end

@testset "native ACR/IVR/LPACC reduction: build, solve, ACP-oracle parity" begin
    model_acp, acp_status =
        _solve_case11_native(ACPNetworkModel, ipopt_optimizer; reduce = true)
    @test acp_status == IOM.ModelBuildStatus.BUILT
    @test solve!(model_acp) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    acp_obj = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_acp))

    # ACR and IVR are exact reformulations of ACP, so their reduced solves must match the
    # reduced ACP objective.
    for formulation in (ACRNetworkModel, IVRNetworkModel)
        model, status = _solve_case11_native(formulation, ipopt_optimizer; reduce = true)
        @test status == IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        obj = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model))
        @test isapprox(obj, acp_obj; rtol = 1e-4)
    end

    # LPACC is a linear approximation with a large gap to ACP on this system, so its
    # oracle is its own un-reduced solve. The corridor-level cosine relaxation is not
    # identical to the per-segment one, hence a small (observed ~0.6%) tolerance.
    model_lpacc_red, lpacc_red_status =
        _solve_case11_native(LPACCNetworkModel, ipopt_optimizer; reduce = true)
    @test lpacc_red_status == IOM.ModelBuildStatus.BUILT
    @test solve!(model_lpacc_red) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    model_lpacc_full, lpacc_full_status =
        _solve_case11_native(LPACCNetworkModel, ipopt_optimizer; reduce = false)
    @test lpacc_full_status == IOM.ModelBuildStatus.BUILT
    @test solve!(model_lpacc_full) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    lpacc_red_obj =
        IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_lpacc_red))
    lpacc_full_obj =
        IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_lpacc_full))
    @test isapprox(lpacc_red_obj, lpacc_full_obj; rtol = 2e-2)
end

@testset "native NFA reduction: one corridor per reduced arc, build and solve" begin
    # NFA has no Ohm's law, only rating-bounded FlowActivePowerVariable and nodal
    # balance, so the flow-rate constraint (not NetworkFlowConstraint) is the corridor
    # to check: one lb/ub pair per reduced arc, shared across both branch types.
    model_red, status_red =
        _solve_case11_native(NFANetworkModel, HiGHS_optimizer; reduce = true)
    @test status_red == IOM.ModelBuildStatus.BUILT
    @test solve!(model_red) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(model_red)
    n_lb =
        length(
            _assigned_flow_constraint_axis(
                container, IOM.ConstraintKey(POM.FlowRateConstraint, Line, "lb"),
            ),
        ) + length(
            _assigned_flow_constraint_axis(
                container, IOM.ConstraintKey(POM.FlowRateConstraint, Transformer2W, "lb"),
            ),
        )
    @test n_lb == CASE11_DISTINCT_REDUCED_ARCS

    pvar_line = IOM.get_variable(container, FlowActivePowerVariable, Line)
    @test !("1-8-i_1" in axes(pvar_line)[1])
    t1 = first(IOM.get_time_steps(container))
    @test pvar_line["1-6-i_1", t1] === pvar_line["6-7-i_1", t1]
    @test pvar_line["6-7-i_1", t1] === pvar_line["7-2-i_1", t1]
    @test "1-4-i_double_circuit" in axes(pvar_line)[1]

    model_full, status_full =
        _solve_case11_native(NFANetworkModel, HiGHS_optimizer; reduce = false)
    @test status_full == IOM.ModelBuildStatus.BUILT
    @test solve!(model_full) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    obj_red = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_red))
    obj_full = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_full))
    @test isapprox(obj_red, obj_full; rtol = 1e-6)
end

@testset "native DCPLL reduction: one corridor per reduced arc, build and solve" begin
    # DCPLL keeps DCP's Ohm's law on p_fr (NetworkFlowConstraint) plus a quadratic
    # loss-coupling constraint (NetworkLossConstraint); both must appear exactly once
    # per reduced arc.
    model_red, status_red =
        _solve_case11_native(DCPLLNetworkModel, ipopt_optimizer; reduce = true)
    @test status_red == IOM.ModelBuildStatus.BUILT
    @test solve!(model_red) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(model_red)
    n_flow =
        length(
            _assigned_flow_constraint_axis(
                container, IOM.ConstraintKey(POM.NetworkFlowConstraint, Line),
            ),
        ) + length(
            _assigned_flow_constraint_axis(
                container, IOM.ConstraintKey(POM.NetworkFlowConstraint, Transformer2W),
            ),
        )
    @test n_flow == CASE11_DISTINCT_REDUCED_ARCS
    n_loss =
        length(
            _assigned_flow_constraint_axis(
                container, IOM.ConstraintKey(POM.NetworkLossConstraint, Line),
            ),
        ) + length(
            _assigned_flow_constraint_axis(
                container, IOM.ConstraintKey(POM.NetworkLossConstraint, Transformer2W),
            ),
        )
    @test n_loss == CASE11_DISTINCT_REDUCED_ARCS

    pft_line = IOM.get_variable(container, FlowActivePowerFromToVariable, Line)
    @test !("1-8-i_1" in axes(pft_line)[1])
    t1 = first(IOM.get_time_steps(container))
    @test pft_line["1-6-i_1", t1] === pft_line["6-7-i_1", t1]
    @test pft_line["6-7-i_1", t1] === pft_line["7-2-i_1", t1]
    @test "1-4-i_double_circuit" in axes(pft_line)[1]
    pft_xfmr = IOM.get_variable(container, FlowActivePowerFromToVariable, Transformer2W)
    @test pft_line["1-9-i_1", t1] === pft_xfmr["9-5-i_1", t1]

    # DCPLL's quadratic loss term makes reduction only approximately loss-preserving
    # (the reduced and unreduced corridors integrate the loss differently), so the two
    # objectives agree only to a loose tolerance, both being near-zero on this system.
    model_full, status_full =
        _solve_case11_native(DCPLLNetworkModel, ipopt_optimizer; reduce = false)
    @test status_full == IOM.ModelBuildStatus.BUILT
    @test solve!(model_full) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    obj_red = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_red))
    obj_full = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model_full))
    @test isapprox(obj_red, obj_full; atol = 1e-4)
end

@testset "voltage-coupled device at a reduction-absorbed bus fails with a clear error" begin
    # PNM absorbs bus 8 (radial) even with a shunt attached; the shunt's q == b·v²
    # constraint needs the local voltage, which has no variables after the reduction.
    sys = _case11_with_forecast()
    bus8 = first(b for b in get_components(ACBus, sys) if PSY.get_number(b) == 8)
    shunt = PSY.SwitchedAdmittance(;
        name = "sh8",
        available = true,
        bus = bus8,
        Y = 0.0 + 0.1im,
        number_of_steps = [5],
        Y_increase = [0.0 + 0.02im],
    )
    PSY.add_component!(sys, shunt)
    net = NetworkModel(
        ACPNetworkModel;
        reduce_radial_branches = true,
        reduce_degree_two_branches = true,
    )
    template = get_thermal_dispatch_template_network(net)
    set_device_model!(
        template, DeviceModel(PSY.SwitchedAdmittance, ShuntSusceptanceDispatch),
    )
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    out = mktempdir(; cleanup = true)
    @test build!(model; output_dir = out, console_level = Logging.Error) ==
          IOM.ModelBuildStatus.FAILED
    log = read(joinpath(out, "operation_problem.log"), String)
    @test occursin("absorbed by a network reduction", log)
end

@testset "PhaseAngleControl branch absorbed by a network reduction fails with a clear error" begin
    # "1-6-i_1" is one segment of the (1,2) series chain, so under reduction it has no
    # direct-branch entry of its own — the same _validate_controlled_branch_not_reduced
    # gate exercised above for VoltageControlTap also covers PhaseAngleControl.
    sys = _case11_with_forecast()
    line = PSY.get_component(Line, sys, "1-6-i_1")
    arc = PSY.get_arc(line)
    ps = PSY.PhaseShiftingTransformer(;
        name = PSY.get_name(line),
        available = true,
        active_power_flow = 0.0,
        reactive_power_flow = 0.0,
        r = PSY.get_r(line, PSY.SU),
        x = PSY.get_x(line, PSY.SU),
        primary_shunt = 0.0,
        tap = 1.0,
        α = 0.0,
        phase_angle_limits = (min = -1.5, max = 1.5),
        rating = PSY.get_rating(line, PSY.SU),
        arc = arc,
        base_power = PSY.get_base_power(sys, PSY.NU),
    )
    PSY.add_component!(sys, ps)
    PSY.remove_component!(sys, line)

    net = NetworkModel(
        DCPNetworkModel;
        reduce_radial_branches = true,
        reduce_degree_two_branches = true,
    )
    template = get_thermal_dispatch_template_network(net)
    set_device_model!(
        template, DeviceModel(PSY.PhaseShiftingTransformer, PhaseAngleControl),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    out = mktempdir(; cleanup = true)
    @test build!(model; output_dir = out, console_level = Logging.Error) ==
          IOM.ModelBuildStatus.FAILED
    log = read(joinpath(out, "operation_problem.log"), String)
    @test occursin("absorbed by a network reduction", log)
end

@testset "tap regulated-bus resolution errors for non-retained bus numbers" begin
    sys = PSB.build_system(PSITestSystems, "c_sys14")
    tr = PSY.get_component(PSY.TapTransformer, sys, "Trans1")
    PSY.set_regulated_bus_number!(tr, 999)
    geom = POM._branch_geometry(tr)
    number_to_name = Dict(1 => "Bus 1")
    @test_throws ErrorException POM._tap_regulated_bus_name(tr, geom, number_to_name)
    bus_by_number = Dict(1 => PSY.get_from(PSY.get_arc(tr)))
    @test_throws ErrorException POM._tap_regulated_bus(tr, bus_by_number)
end
