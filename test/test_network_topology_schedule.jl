@testset "The build stores a schedule that follows the branch statuses" begin
    sys = _c_sys5_uc()
    line = first(_sorted(PSY.Line, sys))
    _schedule_outage!(sys, line, "maint", h -> h in 3:5 ? 1.0 : 0.0)
    model = _ptdf_model(sys)
    ts = POM.get_topology_schedule(IOM.get_network_model(IOM.get_template(model)))
    @test ts isa PNM.TopologySchedule
    @test PNM.get_topology_index(ts, 1) == 0
    @test PNM.get_topology_index(ts, 3) != 0
    @test PNM.get_topology_index(ts, 3) == PNM.get_topology_index(ts, 5)
    @test PNM.get_topology_index(ts, 6) == 0
    arc = (PSY.get_number(PSY.get_from(PSY.get_arc(line))),
        PSY.get_number(PSY.get_to(PSY.get_arc(line))))
    @test PNM.is_arc_out(ts, arc, 4)
end

@testset "A rebuild replaces the schedule from the refreshed statuses" begin
    sys = _c_sys5_uc()
    line = first(_sorted(PSY.Line, sys))
    _schedule_outage!(sys, line, "maint", h -> h in 3:5 ? 1.0 : 0.0)
    model = _ptdf_model(sys)
    container = IOM.get_optimization_container(model)
    status = IOM.get_parameter_array(container, POM.BranchStatusParameter, PSY.Line)
    status[PSY.get_name(line), :] .= 1.0
    IOM.set_rebuild_model!(IOM.get_settings(container), true)
    IOM.reset_optimization_model!(container)
    POM.build_problem!(container, IOM.get_template(model), sys)
    ts = POM.get_topology_schedule(IOM.get_network_model(IOM.get_template(model)))
    @test all(PNM.get_topology_index(ts, t) == 0 for t in IOM.get_time_steps(container))
end

@testset "An initialization model builds with the schedule" begin
    sys = _c_sys5_uc()
    line = first(_sorted(PSY.Line, sys))
    _schedule_outage!(sys, line, "maint", h -> h in 1:2 ? 1.0 : 0.0)
    template = get_template_basic_uc_simulation()
    set_network_model!(template, NetworkModel(PTDFNetworkModel))
    model =
        DecisionModel(template, sys; optimizer = HiGHS_optimizer, initialize_model = true)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    ts = POM.get_topology_schedule(IOM.get_network_model(IOM.get_template(model)))
    @test PNM.get_topology_index(ts, 1) != 0
end

# The bus with the fewest incident lines among buses that carry both a generator and a load,
# so cutting its lines isolates an island with injectors of both kinds.
function _island_bus(sys)
    degree(b) = count(
        l -> b in (PSY.get_from(PSY.get_arc(l)), PSY.get_to(PSY.get_arc(l))),
        PSY.get_components(PSY.Line, sys),
    )
    on_bus(T, b) = filter(d -> PSY.get_bus(d) == b, _sorted(T, sys))
    candidates = filter(
        b ->
            PSY.get_bustype(b) != PSY.ACBusTypes.REF &&
                !isempty(on_bus(PSY.ThermalStandard, b)) &&
                !isempty(on_bus(PSY.PowerLoad, b)),
        sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number),
    )
    bus = argmin(degree, candidates)
    lines = filter(
        l -> bus in (PSY.get_from(PSY.get_arc(l)), PSY.get_to(PSY.get_arc(l))),
        _sorted(PSY.Line, sys),
    )
    return bus, lines, on_bus(PSY.ThermalStandard, bus), on_bus(PSY.PowerLoad, bus)
end

function _isolated_bus_sys(; gen_steps = nothing, load_steps = nothing)
    sys = _c_sys5_uc()
    bus, lines, gens, loads = _island_bus(sys)
    for l in lines
        _schedule_outage!(sys, l, "out_$(PSY.get_name(l))", h -> h in 3:5 ? 1.0 : 0.0)
    end
    for (devices, steps) in ((gens, gen_steps), (loads, load_steps))
        isnothing(steps) && continue
        for d in devices
            _schedule_outage!(sys, d, "out_$(PSY.get_name(d))", h -> h in steps ? 1.0 : 0.0)
        end
    end
    return sys, bus, lines, gens, loads
end

function _build_ptdf(sys)
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    status = build!(model; output_dir = output_dir)
    # The log prints the build error's repr, which escapes quotes and newlines.
    log = unescape_string(read(joinpath(output_dir, "operation_problem.log"), String))
    return model, status, log
end

@testset "Isolating a bus with injectors in service fails the build" begin
    sys, bus, _, gens, loads = _isolated_bus_sys()
    _, status, log = _build_ptdf(sys)
    @test status == IOM.ModelBuildStatus.FAILED
    @test occursin("Islands are not modeled", log)
    @test occursin("Island [$(PSY.get_number(bus))]", log)
    for d in vcat(gens, loads)
        @test occursin("$(nameof(typeof(d))) \"$(PSY.get_name(d))\" at steps 3-5", log)
    end
end

@testset "Isolating a bus with its injectors out builds" begin
    sys, _, _, _, _ = _isolated_bus_sys(; gen_steps = 3:5, load_steps = 3:5)
    _, status, _ = _build_ptdf(sys)
    @test status == IOM.ModelBuildStatus.BUILT
end

@testset "An injector out for part of the isolation is reported at the other steps" begin
    sys, bus, _, gens, loads = _isolated_bus_sys(; gen_steps = 3:4, load_steps = 3:5)
    _, status, log = _build_ptdf(sys)
    @test status == IOM.ModelBuildStatus.FAILED
    @test occursin("Island [$(PSY.get_number(bus))]", log)
    for g in gens
        @test occursin(
            Regex("ThermalStandard \"$(PSY.get_name(g))\" at steps 5(?![\\d-])"),
            log,
        )
    end
    for l in loads
        @test !occursin("\"$(PSY.get_name(l))\"", log)
    end
end

# Without the island's load, the minimum generation of the other units exceeds the demand at
# the low-load steps, which no dispatch can meet. The island's own units keep their minimum,
# so their outage still has to lift it.
function _zero_min_generation_outside!(sys, island_gens)
    island = Set(PSY.get_name.(island_gens))
    for g in PSY.get_components(PSY.ThermalStandard, sys)
        PSY.get_name(g) in island && continue
        limits = PSY.get_active_power_limits(g, u"SU")
        PSY.set_active_power_limits!(g, (min = 0.0 * u"SU", max = limits.max * u"SU"))
    end
    return
end

@testset "An isolated bus with its injectors out matches a rebuild without them" begin
    sys, _, lines, gens, loads = _isolated_bus_sys(; gen_steps = 3:5, load_steps = 3:5)
    @test all(g -> PSY.get_active_power_limits(g, u"SU").min > 0.0, gens)
    _zero_min_generation_outside!(sys, gens)
    model, status, _ = _build_ptdf(sys)
    @test status == IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    ref_sys = _c_sys5_uc()
    _zero_min_generation_outside!(ref_sys, gens)
    for (T, ds) in ((PSY.Line, lines), (PSY.ThermalStandard, gens), (PSY.PowerLoad, loads))
        for d in ds
            PSY.set_available!(PSY.get_component(T, ref_sys, PSY.get_name(d)), false)
        end
    end
    ref, ref_status, _ = _build_ptdf(ref_sys)
    @test ref_status == IOM.ModelBuildStatus.BUILT
    @test solve!(ref) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    flows(m) =
        JuMP.value.(
            IOM.get_expression(
                IOM.get_optimization_container(m),
                POM.PTDFBranchFlow,
                PSY.Line,
            ))
    dispatches(m) =
        JuMP.value.(
            IOM.get_variable(
                IOM.get_optimization_container(m),
                POM.ActivePowerVariable,
                PSY.ThermalStandard,
            ))
    flow, ref_flow = flows(model), flows(ref)
    dispatch, ref_dispatch = dispatches(model), dispatches(ref)
    island = Set(PSY.get_name.(lines))
    flows_match = all(
        isapprox(flow[n, t], ref_flow[n, t]; atol = 1e-5) for
        n in axes(ref_flow, 1), t in 3:5
    )
    island_flows_zero =
        all(isapprox(flow[n, t], 0.0; atol = 1e-5) for n in island, t in 3:5)
    dispatch_match =
        all(
            isapprox(dispatch[n, t], ref_dispatch[n, t]; atol = 1e-5) for
            n in axes(ref_dispatch, 1), t in 3:5
        ) && all(
            isapprox(dispatch[PSY.get_name(g), t], 0.0; atol = 1e-5) for g in gens,
            t in 3:5
        )
    @test island_flows_zero
    @test dispatch_match
    @test flows_match
end

@testset "The island message names reduced buses and injectors that cannot be scheduled" begin
    reduction = PNM.NetworkReductionData(;
        bus_reduction_map = Dict(3 => Set([3, 7, 8]), 4 => Set([4])),
    )
    violations = POM._IslandViolations(
        [3, 4] => Dict(
            POM._IsolatedInjector(("ThermalStandard", "g", true)) => [3, 4, 5],
            POM._IsolatedInjector(("HybridSystem", "h", false)) => [4],
        ),
    )
    message = POM._island_violation_message(violations, reduction)
    @test occursin("Island [3, 4] (with the buses reduced into it: [7, 8]): ", message)
    @test occursin("HybridSystem \"h\" at steps 4 (cannot carry a PlannedOutage)", message)
    @test occursin("ThermalStandard \"g\" at steps 3-5", message)
    @test !occursin("\"g\" at steps 3-5 (cannot", message)
    @test occursin("must be made unavailable", message)
    unreduced = PNM.NetworkReductionData(; bus_reduction_map = Dict(3 => Set([3])))
    @test occursin(
        "Island [3]: ",
        POM._island_violation_message(
            POM._IslandViolations([3] => Dict(first(violations)[2])),
            unreduced,
        ),
    )
end

@testset "A network model without topology refuses a topology schedule" begin
    sys = _c_sys5_uc()
    line = first(_sorted(PSY.Line, sys))
    _schedule_outage!(sys, line, "maint", _out_at(3:5))
    ts = POM.get_topology_schedule(_network_model(_ptdf_model(sys)))
    copper_plate = _built_model(
        get_thermal_dispatch_template_network(NetworkModel(CopperPlateNetworkModel)),
        sys,
    )
    @test_throws r"CopperPlateNetworkModel holds no network topology" POM.set_topology_schedule!(
        _network_model(copper_plate),
        ts,
        POM._PostContingencyNetworks(),
    )
end
