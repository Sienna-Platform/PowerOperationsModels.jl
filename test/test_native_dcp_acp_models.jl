import PowerNetworkMatrices as PNM

# build! routes log records emitted inside build_model! to the model's internal
# file logger (operation_problem.log), so they are NOT visible to @test_logs at
# the call site. To assert (or rule out) the REF-less pin warning we read it.
function _build_log_contains(output_dir, needle)
    logf = joinpath(output_dir, "operation_problem.log")
    isfile(logf) || return false
    return occursin(needle, read(logf, String))
end

@testset "native DCPNetworkModel builds and solves (c_sys5)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(DCPNetworkModel))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    out = mktempdir(; cleanup = true)
    @test build!(model; output_dir = out) == IOM.ModelBuildStatus.BUILT
    # Real REF present (nodeD): pinned silently, no spurious REF-less warning.
    @test !_build_log_contains(out, "no ACBusTypes.REF bus")
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # --- DC ohm-law physics check ---
    # The native DCP NetworkFlowConstraint enforces (in per-unit):
    #   p_pu == -b * (va_from - va_to)
    # where b = imag(get_series_admittance(line, PSY.SU)).
    # read_variable returns FlowActivePowerVariable in natural units (MW);
    # VoltageAngle is unitless (radians, no conversion). Divide flow by base_power.
    res = IOM.OptimizationProblemOutputs(model)
    base_power = IOM.get_model_base_power(res)
    pflow =
        read_variable(res, "FlowActivePowerVariable__Line"; table_format = TableFormat.WIDE)
    va = read_variable(res, "VoltageAngle__ACBus"; table_format = TableFormat.WIDE)
    line = first(PSY.get_components(PSY.Line, sys))
    b = imag(PSY.get_series_admittance(line, PSY.SU))
    fr = PSY.get_name(PSY.get_from(PSY.get_arc(line)))
    to = PSY.get_name(PSY.get_to(PSY.get_arc(line)))
    lname = PSY.get_name(line)
    # Row 1 = first time step; columns are component names.
    # Compare both sides in per-unit: divide MW output by base_power.
    @test isapprox(pflow[1, lname] / base_power, -b * (va[1, fr] - va[1, to]); atol = 1e-6)
end

@testset "native ACPNetworkModel builds and solves (c_sys5)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # --- ACP voltage-magnitude physics check ---
    # The native ACP model enforces bus voltage magnitude within PSY.get_voltage_limits(bus)
    # bounds (per-unit, unitless). Assert the solved vm stays in bounds for every bus.
    res = IOM.OptimizationProblemOutputs(model)
    vm = read_variable(res, "VoltageMagnitude__ACBus"; table_format = TableFormat.WIDE)
    for bus in PSY.get_components(PSY.ACBus, sys)
        lim = PSY.get_voltage_limits(bus)
        bname = PSY.get_name(bus)
        v = vm[1, bname]
        @test lim.min - 1e-6 <= v <= lim.max + 1e-6
    end
end

@testset "native DCPNetworkModel solves under network reduction (c_sys14)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys14")
    net = NetworkModel(
        DCPNetworkModel;
        reduce_radial_branches = true,
        reduce_degree_two_branches = true,
    )
    template = get_thermal_dispatch_template_network(net)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "native ACPNetworkModel solves under network reduction (c_sys14)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys14")
    net = NetworkModel(
        ACPNetworkModel;
        reduce_radial_branches = true,
        reduce_degree_two_branches = true,
    )
    template = get_thermal_dispatch_template_network(net)
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "native DCP pins PNM's reference for a REF-less system (no warn, non-degenerate)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    for b in PSY.get_components(PSY.ACBus, sys)
        if PSY.get_bustype(b) == PSY.ACBusTypes.REF
            PSY.set_bustype!(b, PSY.ACBusTypes.PV)
        end
    end
    template = get_thermal_dispatch_template_network(NetworkModel(DCPNetworkModel))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    out = mktempdir(; cleanup = true)
    @test build!(model; output_dir = out) == IOM.ModelBuildStatus.BUILT
    # No ACBusTypes.REF bus exists, yet PNM still assigns each subnetwork a
    # reference (the subnetwork_axes key). The model pins THAT bus directly — no
    # re-derivation by bustype, no arbitrary-slack fallback, no warning.
    @test !_build_log_contains(out, "no ACBusTypes.REF bus")
    container = IOM.get_optimization_container(model)
    ref_cons =
        IOM.get_constraint(container, IOM.ConstraintKey(ReferenceBusConstraint, PSY.ACBus))
    @test !isempty(ref_cons)  # a reference WAS pinned (island not skipped)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    # The pinned reference (PNM's subnetwork key) has angle 0 -> unique, non-degenerate.
    res = IOM.OptimizationProblemOutputs(model)
    va = read_variable(res, "VoltageAngle__ACBus"; table_format = TableFormat.WIDE)
    num_to_name =
        Dict(
            PSY.get_number(b) => PSY.get_name(b) for b in PSY.get_components(PSY.ACBus, sys)
        )
    for k in axes(ref_cons, 1)
        @test isapprox(va[1, num_to_name[k]], 0.0; atol = 1e-8)
    end
end

@testset "native ACP pins PNM's reference for a REF-less system (no warn, vm+va)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    for b in PSY.get_components(PSY.ACBus, sys)
        if PSY.get_bustype(b) == PSY.ACBusTypes.REF
            PSY.set_bustype!(b, PSY.ACBusTypes.PV)
        end
    end
    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    out = mktempdir(; cleanup = true)
    @test build!(model; output_dir = out) == IOM.ModelBuildStatus.BUILT
    @test !_build_log_contains(out, "no ACBusTypes.REF bus")
    container = IOM.get_optimization_container(model)
    ref_cons = IOM.get_constraint(
        container,
        IOM.ConstraintKey(ReferenceBusConstraint, PSY.ACBus, "va"),
    )
    @test !isempty(ref_cons)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    res = IOM.OptimizationProblemOutputs(model)
    va = read_variable(res, "VoltageAngle__ACBus"; table_format = TableFormat.WIDE)
    num_to_name =
        Dict(
            PSY.get_number(b) => PSY.get_name(b) for b in PSY.get_components(PSY.ACBus, sys)
        )
    for k in axes(ref_cons, 1)
        @test isapprox(va[1, num_to_name[k]], 0.0; atol = 1e-8)
    end
end

@testset "reduced arc admittance uses PNM series equivalent, not original branch" begin
    # `case11_network_reductions` is purpose-built to produce series arcs under the
    # radial + degree-two reduction (c_sys5/c_sys14 yield no reducible chains).
    # The reduction data is built exactly as POM's `instantiate_network_model!` does
    # (PNM.Ybus with RadialReduction + DegreeTwoReduction), so the same
    # NetworkReductionData the build path stores on the network model is exercised
    # directly here without depending on time-series/forecast data.
    sys = PSB.build_system(PSITestSystems, "case11_network_reductions")
    ybus = PNM.Ybus(
        sys;
        network_reductions = PNM.NetworkReduction[
            PNM.RadialReduction(),
            PNM.DegreeTwoReduction(),
        ],
    )
    nr = deepcopy(PNM.get_network_reduction_data(ybus))
    @test !isempty(nr)

    series_map = PNM.get_series_branch_map(nr)
    @test !isempty(series_map)  # degree-2 reduction produces series arcs

    (from_no, to_no), chain = first(series_map)
    resolved = PNM.reduced_arc_admittance(nr, from_no, to_no)
    @test resolved !== nothing
    expected = PNM.branch_admittance(chain, nr)
    @test isapprox(resolved.b, expected.b; atol = 1e-9)

    # Non-triviality: the series equivalent is the MERGED admittance of the chain, so
    # it must differ from any single constituent branch's own admittance. This is the
    # whole point of leveraging PNM — the old native path used a single branch's value
    # for the reduced arc, which is wrong.
    members = collect(chain)
    @test length(members) >= 2
    member_b = PNM.branch_admittance(members[1]).b
    @test !isapprox(resolved.b, member_b; rtol = 1e-3)

    # Reversed-orientation arc exercises the `_reverse_admittance` path: series b is
    # symmetric, from/to shunts swap, and any phase shift negates.
    if !haskey(series_map, (to_no, from_no))
        reversed = PNM.reduced_arc_admittance(nr, to_no, from_no)
        @test reversed !== nothing
        @test isapprox(reversed.b, resolved.b; atol = 1e-9)
        @test isapprox(reversed.b_fr, resolved.b_to; atol = 1e-9)
        @test isapprox(reversed.shift, -resolved.shift; atol = 1e-12)
    end

    # A direct (un-reduced) arc resolves to `nothing` — the caller falls back to the
    # branch's own admittance.
    @test PNM.reduced_arc_admittance(nr, -1, -2) === nothing
end

@testset "Transformer3W _winding_admittance star-arc decomposition" begin
    # Unit test the per-winding admittance helper against a real PNM
    # `ThreeWindingTransformerWinding`: for a winding with series impedance R + jX the
    # helper must return the series admittance 1/(R + jX), the winding's PNM shunt on the
    # from/to sides, no phase shift, and (here) a unit tap. R/X are read back through PNM
    # so the assertion is robust to per-unit base conversions.
    sys = PSB.build_system(PSITestSystems, "c_sys5_ml")
    busD = PSY.get_component(PSY.ACBus, sys, "nodeD")
    star_bus = PSY.ACBus(;
        number = 103,
        name = "Star_Bus_T3W",
        available = true,
        bustype = PSY.ACBusTypes.PQ,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.95, max = 1.05),
        base_voltage = 230.0,
        area = PSY.get_area(busD),
        load_zone = PSY.get_load_zone(busD),
    )
    PSY.add_component!(sys, star_bus)
    sec_bus = PSY.ACBus(;
        number = 101,
        name = "Bus3WT_1",
        available = true,
        bustype = PSY.ACBusTypes.PQ,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.95, max = 1.05),
        base_voltage = 230.0,
        area = PSY.get_area(busD),
        load_zone = PSY.get_load_zone(busD),
    )
    PSY.add_component!(sys, sec_bus)
    ter_bus = PSY.ACBus(;
        number = 102,
        name = "Bus3WT_2",
        available = true,
        bustype = PSY.ACBusTypes.PQ,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.95, max = 1.05),
        base_voltage = 230.0,
        area = PSY.get_area(busD),
        load_zone = PSY.get_load_zone(busD),
    )
    PSY.add_component!(sys, ter_bus)
    transformer3w = PSY.Transformer3W(;
        name = "Transformer3W_busD",
        available = true,
        primary_star_arc = PSY.Arc(; from = busD, to = star_bus),
        secondary_star_arc = PSY.Arc(; from = sec_bus, to = star_bus),
        tertiary_star_arc = PSY.Arc(; from = ter_bus, to = star_bus),
        star_bus = star_bus,
        active_power_flow_primary = 0.0,
        reactive_power_flow_primary = 0.0,
        active_power_flow_secondary = 0.0,
        reactive_power_flow_secondary = 0.0,
        active_power_flow_tertiary = 0.0,
        reactive_power_flow_tertiary = 0.0,
        r_primary = 0.01,
        x_primary = 0.1,
        r_secondary = 0.01,
        x_secondary = 0.1,
        r_tertiary = 0.01,
        x_tertiary = 0.1,
        r_12 = 0.01,
        x_12 = 0.1,
        r_23 = 0.01,
        x_23 = 0.1,
        r_13 = 0.01,
        x_13 = 0.1,
        base_power_12 = 100.0,
        base_power_23 = 100.0,
        base_power_13 = 100.0,
        rating = nothing,
        rating_primary = 1.0,
        rating_secondary = 1.0,
        rating_tertiary = 0.5,
    )
    PSY.add_component!(sys, transformer3w)

    w = PNM.ThreeWindingTransformerWinding(transformer3w, 1)
    adm = PNM.winding_admittance(w)

    r = PNM.get_equivalent_r(w)
    x = PNM.get_equivalent_x(w)
    y = inv(complex(r, x))
    @test isapprox(adm.g, real(y); atol = 1e-12)
    @test isapprox(adm.b, imag(y); atol = 1e-12)

    b_sh = PNM.get_equivalent_b(w)
    @test adm.g_fr == 0.0
    @test adm.b_fr == b_sh.from
    @test adm.g_to == 0.0
    @test adm.b_to == b_sh.to
    @test adm.tap == 1.0
end

@testset "native AC rate limits reject a zero-rating branch at build" begin
    # MATPOWER's rateA = 0 means "unlimited"; p² + q² ≤ 0 would silently pin the branch
    # to zero flow (deleting it from the network). Reject it loudly, matching the IVR
    # current-rating behavior.
    for network_formulation in (ACPNetworkModel, ACRNetworkModel, LPACCNetworkModel)
        sys = PSB.build_system(PSITestSystems, "c_sys5")
        PSY.set_rating!(PSY.get_component(Line, sys, "1"), 0.0 * PSY.SU)
        template = get_thermal_dispatch_template_network(NetworkModel(network_formulation))
        model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
        out = mktempdir(; cleanup = true)
        @test build!(model; output_dir = out, console_level = Logging.Error) ==
              IOM.ModelBuildStatus.FAILED
        log = read(joinpath(out, "operation_problem.log"), String)
        @test occursin("zero rating", log)
    end
end
