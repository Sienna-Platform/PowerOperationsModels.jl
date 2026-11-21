function _instantiated_network(sys, network)
    template = get_thermal_dispatch_template_network(network)
    set_device_model!(template, PSY.DiscreteControlledACBranch, StaticBranch)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return IOM.get_network_model(IOM.get_template(model))
end

@testset "A scheduled open switch is in the base network" begin
    sys, switch = _sys_with_scheduled_switch()
    nm = _instantiated_network(sys, NetworkModel(PTDFNetworkModel))
    catalog = POM.get_branch_catalog(nm)
    @test haskey(PNM.get_name_to_arc_map(catalog, PSY.DiscreteControlledACBranch), "tie") ||
          haskey(
        PNM.get_component_to_reduction_name_map(catalog, PSY.DiscreteControlledACBranch),
        "tie",
    )
    @test POM.get_topology_matrix(nm) isa PNM.VirtualMODF
    @test "tie" in PNM.get_closed_switches(
        PNM.get_reductions(POM.get_reduction(IOM.get_network_data(nm))),
    )
end

@testset "No schedules: no topology matrix" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_forecasts = true)
    nm = _instantiated_network(sys, NetworkModel(PTDFNetworkModel))
    @test !POM.has_topology_schedule(nm)
    @test_throws r"no topology schedule" POM.get_topology_matrix(nm)
    @test_throws r"no topology schedule" POM.get_topology_sequence(nm)
end

@testset "A scheduled network has a topology schedule and a sequence after the build" begin
    sys, _ = _sys_with_scheduled_switch()
    nm = _instantiated_network(sys, NetworkModel(PTDFNetworkModel))
    @test POM.has_topology_schedule(nm)
    @test POM.get_topology_sequence(nm) isa PNM.TopologySequence
end

function _c_sys5_factor_core()
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    ybus =
        POM._build_ybus(POM.SystemNetworkSource(), sys, Int[], POM._NO_SCHEDULED_TOPOLOGY)
    return sys, ybus, PNM.VirtualFactorCore(ybus; system_uuid = PSY.get_system_uuid(sys))
end

_unregistered_modf(core, sys) =
    PNM.VirtualMODF(core, sys; automatically_register_outages = false)

@testset "The topology sequence errors until it is set and after it is reset" begin
    sys, ybus, core = _c_sys5_factor_core()
    matrix = _unregistered_modf(core, sys)
    nd = POM.PTDFNetworkData(
        PNM.VirtualPTDF(core),
        PNM.get_branch_catalog(core),
        POM.TopologySchedule(matrix),
    )
    @test POM.has_topology_schedule(nd)
    @test POM.get_topology_matrix(nd) === matrix
    @test_throws r"topology sequence has not been set" POM.get_topology_sequence(nd)
    ts = PNM.TopologySequence(matrix, sys, [Set{PSY.Component}()])
    POM.set_topology_sequence!(nd, ts)
    @test POM.get_topology_sequence(nd) === ts
    POM.reset_topology_sequence!(nd)
    @test_throws r"topology sequence has not been set" POM.get_topology_sequence(nd)
end

@testset "The topology matrix and the contingency matrix share one factorization" begin
    sys, ybus, core = _c_sys5_factor_core()
    contingency_matrix = _unregistered_modf(core, sys)
    catalog = PNM.get_branch_catalog(core)
    ptdf = PNM.VirtualPTDF(core)
    nd = POM.PTDFNetworkData(
        ptdf,
        contingency_matrix,
        catalog,
        POM.TopologySchedule(contingency_matrix),
    )
    @test POM.get_topology_matrix(nd) === POM.get_network_data_contingency_matrix(nd)
    @test_throws ArgumentError POM.PTDFNetworkData(
        ptdf,
        contingency_matrix,
        catalog,
        POM.TopologySchedule(_unregistered_modf(core, sys)),
    )
    @test_throws ArgumentError POM.DCPNetworkData(
        ybus,
        contingency_matrix,
        catalog,
        POM.TopologySchedule(_unregistered_modf(core, sys)),
    )
end

@testset "DCP with schedules gets a topology matrix" begin
    sys, _ = _sys_with_scheduled_switch()
    nm = _instantiated_network(sys, NetworkModel(DCPNetworkModel))
    @test POM.get_topology_matrix(nm) isa PNM.VirtualMODF
end

@testset "Security-constrained models share their contingency matrix" begin
    sys, switch = _sys_with_scheduled_switch()
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    # The switch rates its arc once the parallel line trips.
    PSY.set_rating!(switch, PSY.get_rating(line, u"SU") * u"SU")
    PSY.set_rating_b!(switch, nothing)
    PSY.set_rating_c!(switch, nothing)
    PSY.add_supplemental_attribute!(
        sys,
        line,
        PSY.FixedForcedOutage(; outage_status = 1.0, monitored_components = [line]),
    )
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, PSY.Line, SecurityConstrainedStaticBranch)
    set_device_model!(template, PSY.DiscreteControlledACBranch, StaticBranch)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    nm = IOM.get_network_model(IOM.get_template(model))
    @test POM.get_topology_matrix(nm) === IOM.get_contingency_matrix(nm)
end

@testset "A prebuilt source without the scheduled switch is rejected" begin
    sys, _ = _sys_with_scheduled_switch()
    source = PrebuiltMatrixSource(PNM.VirtualPTDF(sys))
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; network_source = source),
    )
    set_device_model!(template, PSY.DiscreteControlledACBranch, StaticBranch)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED
    log = read(joinpath(output_dir, IOM.PROBLEM_LOG_FILENAME), String)
    @test occursin("topology_schedule_components", log)
end

# "tie" is open at `_OUT_STEPS` and closed at the other steps, which serve as the control.
@testset "A prebuilt source built with the schedules is accepted and replayed" begin
    pattern = h -> Float64(!(h in _OUT_STEPS))
    sys, _ = _sys_with_scheduled_switch(pattern)
    sched = POM.topology_schedule_components(sys)
    ybus = PNM.Ybus(
        sys;
        closed_switches = sched.closed_switches,
        scheduled_branches = sched.scheduled_branches,
    )
    source = PrebuiltMatrixSource(PNM.VirtualPTDF(PNM.VirtualFactorCore(ybus)))
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; network_source = source),
    )
    set_device_model!(template, PSY.DiscreteControlledACBranch, StaticBranch)
    model = _ptdf_model(sys; template = template)
    nm = _network_model(model)
    @test POM.get_topology_matrix(nm) isa PNM.VirtualMODF
    open_by_step = [t in _OUT_STEPS for t in 1:_n_steps(model)]
    make_reference = function (open)
        ref_sys, switch = _sys_with_scheduled_switch(pattern)
        if open
            PSY.set_available!(switch, false)
        else
            PSY.set_branch_status!(switch, PSY.DiscreteControlledBranchStatus.CLOSED)
        end
        return ref_sys
    end
    _check_flows_against_references(model, open_by_step, make_reference)
    reduction = PNM.get_network_reduction_data(ybus)
    scheduled_buses = Set{Int}()
    for branch in sched.scheduled_branches
        POM._push_component_buses!(scheduled_buses, branch)
    end
    @test !isempty(scheduled_buses)
    @test issubset(scheduled_buses, POM._source_irreducible_buses(reduction))
end

@testset "Distributed slack with branch schedules is rejected" begin
    sys, _ = _sys_with_scheduled_switch()
    sched = POM.topology_schedule_components(sys)
    ybus = PNM.Ybus(
        sys;
        closed_switches = sched.closed_switches,
        scheduled_branches = sched.scheduled_branches,
    )
    buses = PNM.get_bus_axis(ybus)
    slack = Dict(b => 1.0 / length(buses) for b in buses)
    source = PrebuiltMatrixSource(
        PNM.VirtualPTDF(PNM.VirtualFactorCore(ybus); dist_slack = slack),
    )
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; network_source = source),
    )
    set_device_model!(template, PSY.DiscreteControlledACBranch, StaticBranch)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED
    log = read(joinpath(output_dir, IOM.PROBLEM_LOG_FILENAME), String)
    @test occursin("distributed slack", log)
end

# c_sys5_uc with a bus "island" reached only through the open switch "tie", whose switching
# schedule closes it at every step. Without the switch the bus is a second subnetwork.
function _sys_with_scheduled_tie(; with_switch = true)
    sys = _c_sys5_uc()
    anchor = first(sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number))
    island = PSY.ACBus(;
        number = 99,
        name = "island",
        available = true,
        bustype = PSY.ACBusTypes.PQ,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = PSY.get_base_voltage(anchor),
        area = PSY.get_area(anchor),
        load_zone = PSY.get_load_zone(anchor),
        input_basis = u"CU",
    )
    PSY.add_component!(sys, island)
    with_switch || return sys
    arc = PSY.Arc(; from = anchor, to = island)
    PSY.add_component!(sys, arc)
    switch = _add_open_switch!(sys, "tie", arc)
    _attach_forecast_schedule!(sys, switch, POM.BRANCH_STATUS_SCHEDULE, h -> 1.0)
    return sys
end

@testset "CopperPlate keeps a scheduled switch open, as its data says" begin
    for network in (CopperPlateNetworkModel,)
        template = get_thermal_dispatch_template_network(NetworkModel(network))
        model =
            DecisionModel(template, _sys_with_scheduled_tie(); optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        reference = DecisionModel(
            get_thermal_dispatch_template_network(NetworkModel(network)),
            _sys_with_scheduled_tie(; with_switch = false);
            optimizer = HiGHS_optimizer,
        )
        @test build!(reference; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        subnetworks(m) = IOM.get_subnetworks(IOM.get_network_model(IOM.get_template(m)))
        @test length(subnetworks(reference)) == 2
        @test subnetworks(model) == subnetworks(reference)
        nm = IOM.get_network_model(IOM.get_template(model))
        @test isempty(
            PNM.get_closed_switches(
                PNM.get_reductions(POM.get_reduction(IOM.get_network_data(nm))),
            ),
        )
    end
end

# two_area_pjm_DA with a bus "island" reached only through the open switch "tie", whose
# switching schedule closes it at every step.
function _two_area_with_scheduled_tie(; with_switch = true)
    sys = PSB.build_system(PSISystems, "two_area_pjm_DA")
    _add_island_bus!(sys; with_switch)
    transform_single_time_series!(sys, Hour(24), Hour(1))
    return sys
end

function _add_island_bus!(sys; with_switch)
    anchor = first(sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number))
    island_area = PSY.Area("island_area", 0.0, 0.0, 0.0)
    PSY.add_component!(sys, island_area)
    island = PSY.ACBus(;
        number = 9999,
        name = "island",
        available = true,
        bustype = PSY.ACBusTypes.PQ,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = PSY.get_base_voltage(anchor),
        area = island_area,
        load_zone = PSY.get_load_zone(anchor),
        input_basis = u"CU",
    )
    PSY.add_component!(sys, island)
    with_switch || return sys
    arc = PSY.Arc(; from = anchor, to = island)
    PSY.add_component!(sys, arc)
    switch = _add_open_switch!(sys, "tie", arc)
    reference = first(PSY.get_time_series_multiple(sys))
    length_series = length(IS.get_data(reference))
    status = TimeSeries.TimeArray(
        range(
            IS.get_initial_timestamp(reference);
            length = length_series,
            step = IS.get_resolution(reference),
        ),
        ones(length_series),
    )
    PSY.add_time_series!(
        sys,
        switch,
        PSY.SingleTimeSeries(; name = POM.BRANCH_STATUS_SCHEDULE, data = status),
    )
    return sys
end

@testset "AreaBalance keeps a scheduled switch open, as its data says" begin
    function build_area_balance(sys)
        template = get_thermal_dispatch_template_network(
            NetworkModel(AreaBalanceNetworkModel),
        )
        set_device_model!(template, PSY.AreaInterchange, StaticBranch)
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_network_model(IOM.get_template(model))
    end
    nm = build_area_balance(_two_area_with_scheduled_tie())
    reference = build_area_balance(_two_area_with_scheduled_tie(; with_switch = false))
    @test length(IOM.get_subnetworks(reference)) == 2
    @test IOM.get_subnetworks(nm) == IOM.get_subnetworks(reference)
    @test isempty(
        PNM.get_closed_switches(
            PNM.get_reductions(POM.get_reduction(IOM.get_network_data(nm))),
        ),
    )
end

@testset "A prebuilt source closing a switch with no schedule is rejected" begin
    sys, tie = _sys_with_scheduled_switch()
    spare = _add_open_switch!(sys, "spare", PSY.get_arc(tie))
    sched = POM.topology_schedule_components(sys)
    @test PSY.get_name.(sched.closed_switches) == ["tie"]
    ybus = PNM.Ybus(
        sys;
        closed_switches = [tie, spare],
        scheduled_branches = sched.scheduled_branches,
    )
    source = PrebuiltMatrixSource(PNM.VirtualPTDF(PNM.VirtualFactorCore(ybus)))
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; network_source = source),
    )
    set_device_model!(template, PSY.DiscreteControlledACBranch, StaticBranch)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED
    log = read(joinpath(output_dir, IOM.PROBLEM_LOG_FILENAME), String)
    @test occursin("without a branch status schedule", log)
    @test occursin("spare", log)
end
