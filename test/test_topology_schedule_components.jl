# Attaches a 24-hour schedule named `name` to `component`; its values are never read here.
function _add_schedule!(sys, component, name)
    timestamps = collect(
        Dates.DateTime("2024-01-01T00:00:00"):Dates.Hour(1):Dates.DateTime(
            "2024-01-01T23:00:00",
        ),
    )
    PSY.add_time_series!(
        sys,
        component,
        PSY.SingleTimeSeries(name, TimeSeries.TimeArray(timestamps, ones(24))),
    )
    return
end

function _sys_with_schedules()
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5"))
    buses = sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number)
    arc = PSY.Arc(buses[1], buses[3])
    PSY.add_component!(sys, arc)
    switch = PSY.DiscreteControlledACBranch(nothing)
    switch.name = "tie_switch"
    switch.arc = arc
    switch.x = 0.05
    switch.available = true
    switch.branch_status = PSY.DiscreteControlledBranchStatus.OPEN
    PSY.add_component!(sys, switch)
    lines = sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name)
    _add_schedule!(sys, switch, POM.BRANCH_STATUS_SCHEDULE)
    _add_schedule!(sys, lines[1], POM.AVAILABLE_SCHEDULE)
    _add_schedule!(sys, lines[2], POM.AVAILABLE_SCHEDULE)
    return sys, switch, lines
end

_same_components(a, b) = length(a) == length(b) && all(x -> any(y -> y === x, b), a)

@testset "Schedule series names" begin
    @test POM.AVAILABLE_SCHEDULE == "available"
    @test POM.BRANCH_STATUS_SCHEDULE == "branch_status"
end

@testset "Scheduled components, switches and branches" begin
    sys, switch, lines = _sys_with_schedules()
    r = POM.topology_schedule_components(sys)
    @test _same_components(r.components, [switch, lines[1], lines[2]])
    @test r.closed_switches == [switch]
    @test r.scheduled_branches isa Vector{PSY.ACTransmission}
    @test _same_components(r.scheduled_branches, [switch, lines[1], lines[2]])
end

@testset "A switch with both schedule types is still closed" begin
    sys, switch, lines = _sys_with_schedules()
    _add_schedule!(sys, switch, POM.AVAILABLE_SCHEDULE)
    r = POM.topology_schedule_components(sys)
    @test r.closed_switches == [switch]
    @test count(c -> c === switch, r.components) == 1
    @test count(c -> c === switch, r.scheduled_branches) == 1
end

@testset "Unavailable scheduled components are excluded" begin
    sys, switch, lines = _sys_with_schedules()
    PSY.set_available!(switch, false)
    PSY.set_available!(lines[1], false)
    r = POM.topology_schedule_components(sys)
    @test PSY.get_name.(r.components) == [PSY.get_name(lines[2])]
    @test isempty(r.closed_switches)
    @test r.scheduled_branches == [lines[2]]
end

@testset "An availability schedule on a generator is no scheduled branch" begin
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5"))
    gen = first(PSY.get_components(PSY.ThermalStandard, sys))
    _add_schedule!(sys, gen, POM.AVAILABLE_SCHEDULE)
    r = POM.topology_schedule_components(sys)
    @test r.components == [gen]
    @test isempty(r.closed_switches)
    @test isempty(r.scheduled_branches)
end

@testset "No schedules means nothing is scheduled" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    @test isempty(POM.schedule_candidates(sys))
    r = POM.topology_schedule_components(sys)
    @test isempty(r.components)
    @test isempty(r.closed_switches)
    @test isempty(r.scheduled_branches)
end

@testset "A scheduled ThreeWindingTransformer is a scheduled branch" begin
    sys = _sys5_with_3w()
    transformer = PSY.get_component(PSY.ThreeWindingTransformer, sys, T3W_NAME)
    _add_schedule!(sys, transformer, POM.AVAILABLE_SCHEDULE)
    r = POM.topology_schedule_components(sys)
    @test r.components == [transformer]
    @test isempty(r.closed_switches)
    @test r.scheduled_branches == [transformer]
end

@testset "A scheduled two-terminal HVDC line is no scheduled branch" begin
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5"))
    line = first(sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name))
    hvdc = PSY.TwoTerminalGenericHVDCLine(;
        name = "hvdc_tie",
        available = true,
        active_power_flow = 0.0,
        rating = 2.0,
        rating_from = 2.0,
        rating_to = 2.0,
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        arc = PSY.get_arc(line),
        loss = PSY.LossCurve(PSY.LinearCurve(0.05, 0.01), PSY.CU),
        input_basis = u"CU",
    )
    PSY.add_component!(sys, hvdc)
    _add_schedule!(sys, hvdc, POM.AVAILABLE_SCHEDULE)
    r = POM.topology_schedule_components(sys)
    @test r.components == [hvdc]
    @test isempty(r.closed_switches)
    @test isempty(r.scheduled_branches)
end

@testset "A branch_status series on a device other than a switch is rejected" begin
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5"))
    line = first(PSY.get_components(PSY.Line, sys))
    _add_schedule!(sys, line, POM.BRANCH_STATUS_SCHEDULE)
    @test_throws r"Line .* carries a .*branch_status.* time series" POM.topology_schedule_components(
        sys,
    )
end

@testset "Schedule candidates give the same components as a full scan" begin
    sys, switch, lines = _sys_with_schedules()
    candidates = POM.schedule_candidates(sys)
    @test candidates isa Vector{PSY.Device}
    @test POM.topology_schedule_components(sys, candidates) ==
          POM.topology_schedule_components(sys)
    PSY.set_available!(lines[1], false)
    @test any(c -> c === lines[1], POM.schedule_candidates(sys))
    r = POM.topology_schedule_components(sys, candidates)
    @test !any(c -> c === lines[1], r.components)
    @test !any(c -> c === lines[1], r.scheduled_branches)
    @test r == POM.topology_schedule_components(sys)
end

@testset "Schedule candidates reject a branch_status series on a device other than a switch" begin
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5"))
    line = first(PSY.get_components(PSY.Line, sys))
    _add_schedule!(sys, line, POM.BRANCH_STATUS_SCHEDULE)
    @test_throws r"Line .* carries a .*branch_status.* time series" POM.schedule_candidates(
        sys,
    )
end
