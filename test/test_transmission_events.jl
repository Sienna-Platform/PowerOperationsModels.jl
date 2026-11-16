struct MockTransmissionOutage <: AbstractEventCondition end
POM.get_initial_parameter_value(
    ::Type{AvailableStatusParameter},
    ::PSY.Line,
    ::EventModel{PSY.FixedForcedOutage, MockTransmissionOutage},
) = 0.0

# Line "1" runs nodeA -> nodeB.
function test_open_line_decoupled(::Type{DCPNetworkModel}, container, outaged)
    va = IOM.get_variable(container, VoltageAngle, PSY.ACBus)
    ohms = IOM.get_constraint(container, POM.NetworkFlowConstraint, PSY.Line)
    time_steps = IOM.get_time_steps(container)
    for t in time_steps
        row = JuMP.constraint_object(ohms[outaged, t])
        @test JuMP.coefficient(row.func, va["nodeA", t]) == 0.0
        @test JuMP.coefficient(row.func, va["nodeB", t]) == 0.0
    end
    # The open line must not tie its terminal angles together.
    @test any(
        abs(JuMP.value(va["nodeA", t]) - JuMP.value(va["nodeB", t])) > 1e-4 for
        t in time_steps
    )
end

function test_open_line_decoupled(::Type{PTDFNetworkModel}, container, outaged)
    # The post-outage (MODF) flow of the open line carries no injection.
    flow_expr = IOM.get_expression(container, POM.PTDFBranchFlow, PSY.Line)
    for t in IOM.get_time_steps(container)
        @test all(c -> abs(c) <= 1e-8, values(flow_expr[outaged, t].terms))
    end
end

@testset "A line outage on c_sys5 matches the system without the line" begin
    for network_model in (DCPNetworkModel, PTDFNetworkModel)
        # Line "1" (nodeA -> nodeB) is not a bridge and carries flow the dispatch relies on.
        # Its angle limits are opened in every system because event lines may not carry an
        # angle-difference constraint.
        outaged = "1"
        function line_template()
            template = get_thermal_dispatch_template_network(NetworkModel(network_model))
            set_device_model!(template, Line, StaticBranchBounds)
            return template
        end
        function c_sys5_open_angles()
            sys = PSB.build_system(PSITestSystems, "c_sys5")
            PSY.set_angle_limits!(
                PSY.get_component(PSY.Line, sys, outaged),
                (min = -π, max = π),
            )
            return sys
        end
        function build_and_solve(template, sys)
            model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
            @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
                  IOM.ModelBuildStatus.BUILT
            container = IOM.get_optimization_container(model)
            jm = IOM.get_jump_model(container)
            JuMP.optimize!(jm)
            @test JuMP.termination_status(jm) == MOI.OPTIMAL
            return container, JuMP.objective_value(jm)
        end
        function build_with_line_event(condition)
            sys = c_sys5_open_angles()
            attach_fixed_forced_outage!(sys, PSY.get_component(PSY.Line, sys, outaged))
            event = EventModel(
                PSY.FixedForcedOutage,
                condition;
                timeseries_mapping = Dict{Symbol, Union{String, Nothing}}(
                    :outage_status => "outage_profile",
                ),
            )
            template = line_template()
            set_event_model!(template, event)
            fill_event_model!(event, sys)
            return build_and_solve(template, sys)
        end

        _, cost_intact = build_and_solve(line_template(), c_sys5_open_angles())
        sys_removed = c_sys5_open_angles()
        PSY.remove_component!(
            sys_removed,
            PSY.get_component(PSY.Line, sys_removed, outaged),
        )
        _, cost_removed = build_and_solve(line_template(), sys_removed)
        @test !isapprox(cost_removed, cost_intact; rtol = 1e-3)

        # "Available line matches the intact system" begin
        _, cost = build_with_line_event(ContinuousCondition())
        @test cost ≈ cost_intact rtol = 1e-6

        # "Open line matches the system without it" begin
        container, cost = build_with_line_event(MockTransmissionOutage())
        @test cost ≈ cost_removed rtol = 1e-6

        flow = IOM.get_variable(container, FlowActivePowerVariable, PSY.Line)
        for t in IOM.get_time_steps(container)
            @test abs(JuMP.value(flow[outaged, t])) <= 1e-6
        end
        test_open_line_decoupled(network_model, container, outaged)
    end
end

# c_sys5 lines: 1 A-B, 2 A-D, 3 A-E, 4 B-C, 5 C-D, 6 D-E. Generation sits at A, C, D and E;
# load at B, C and D.

function line_outage_template(network_model)
    template = get_thermal_dispatch_template_network(NetworkModel(network_model))
    set_device_model!(template, Line, StaticBranchBounds)
    return template
end

# c_sys5, optionally with a parallel circuit added to `parallel_to`, with the angle limits
# of `open_angles` opened: event lines may not carry an angle-difference constraint, and
# every variant of a comparison gets the same limits.
function line_outage_system(open_angles; parallel_to = nothing)
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    if !isnothing(parallel_to)
        add_equivalent_ac_transmission_with_parallel_circuits!(
            sys,
            PSY.get_component(PSY.Line, sys, parallel_to),
            PSY.Line,
        )
    end
    for name in open_angles
        PSY.set_angle_limits!(PSY.get_component(PSY.Line, sys, name), (min = -π, max = π))
    end
    return sys
end

function remove_lines!(sys, names)
    for name in names
        PSY.remove_component!(sys, PSY.get_component(PSY.Line, sys, name))
    end
    return sys
end

# Each inner collection of `outages` is one `FixedForcedOutage` shared by those lines.
# Every mapped line is open at build.
function open_lines_at_build!(template, sys, outages)
    for group in outages
        lines = [PSY.get_component(PSY.Line, sys, name) for name in group]
        outage = attach_fixed_forced_outage!(sys, first(lines))
        for line in lines[2:end]
            PSY.add_supplemental_attribute!(sys, line, outage)
        end
    end
    event = EventModel(
        PSY.FixedForcedOutage,
        MockTransmissionOutage();
        timeseries_mapping = Dict{Symbol, Union{String, Nothing}}(
            :outage_status => "outage_profile",
        ),
    )
    set_event_model!(template, event)
    fill_event_model!(event, sys)
    return event
end

function build_and_solve_line_model(template, sys)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    jm = IOM.get_jump_model(container)
    JuMP.optimize!(jm)
    return container, JuMP.termination_status(jm)
end

function solved_objective(template, sys)
    container, status = build_and_solve_line_model(template, sys)
    @test status == MOI.OPTIMAL
    return container, JuMP.objective_value(IOM.get_jump_model(container))
end

function test_lines_carry_no_flow(container, names)
    flow = IOM.get_variable(container, FlowActivePowerVariable, PSY.Line)
    for name in names, t in IOM.get_time_steps(container)
        @test abs(JuMP.value(flow[name, t])) <= 1e-6
    end
end

# The load at `bus_name`, in system base, over the forecast horizon.
function load_profile_at(sys, bus_name)
    load = only(
        l for l in PSY.get_components(PSY.PowerLoad, sys) if
        PSY.get_name(PSY.get_bus(l)) == bus_name
    )
    profile = PSY.get_time_series_values(
        PSY.Deterministic,
        load,
        "max_active_power";
        start_time = PSY.get_forecast_initial_timestamp(sys),
    )
    return profile .* PSY.get_max_active_power(load, u"SU")
end

# The model with `outages` open matches the system with those lines removed, and the lines
# carry no flow. `opened` lists every line whose angle limits are opened in all variants.
function test_line_outages_match_removal(
    network_model,
    outages;
    removed = collect(Iterators.flatten(outages)),
    opened = removed,
    parallel_to = nothing,
)
    _, cost_intact = solved_objective(
        line_outage_template(network_model),
        line_outage_system(opened; parallel_to),
    )
    _, cost_removed = solved_objective(
        line_outage_template(network_model),
        remove_lines!(line_outage_system(opened; parallel_to), removed),
    )
    # The removal must matter, or matching it would not show the outage took effect.
    @test !isapprox(cost_removed, cost_intact; rtol = 1e-3)

    sys = line_outage_system(opened; parallel_to)
    template = line_outage_template(network_model)
    event = open_lines_at_build!(template, sys, outages)
    container, cost = solved_objective(template, sys)
    @test cost ≈ cost_removed rtol = 1e-6
    return container, event
end

@testset "Line outages islanding a bus with generation and load - $(network_model)" for network_model in
                                                                                        (
    DCPNetworkModel,
    PTDFNetworkModel,
)
    # Opening lines 4 (B-C) and 5 (C-D) leaves nodeC on its own with Solitude and Bus3,
    # which Solitude can serve.
    islanding = ["4", "5"]
    sys = line_outage_system(islanding)
    template = line_outage_template(network_model)
    open_lines_at_build!(template, sys, [islanding])
    container, status = build_and_solve_line_model(template, sys)
    @test status == MOI.OPTIMAL
    test_lines_carry_no_flow(container, islanding)

    # With nodeC cut off, Solitude must serve exactly the load at nodeC.
    p = IOM.get_variable(container, ActivePowerVariable, PSY.ThermalStandard)
    island_load = load_profile_at(sys, "nodeC")
    for t in IOM.get_time_steps(container)
        @test JuMP.value(p["Solitude", t]) ≈ island_load[t] atol = 1e-6
    end
end

@testset "Line outages islanding a bus with load only are infeasible - $(network_model)" for network_model in
                                                                                             (
    DCPNetworkModel,
    PTDFNetworkModel,
)
    # Opening lines 1 (A-B) and 4 (B-C) leaves nodeB with Bus2's load and no generation.
    islanding = ["1", "4"]
    sys = line_outage_system(islanding)
    template = line_outage_template(network_model)
    open_lines_at_build!(template, sys, [islanding])
    _, status = build_and_solve_line_model(template, sys)
    @test status in (MOI.INFEASIBLE, MOI.INFEASIBLE_OR_UNBOUNDED)
end

@testset "Outage of one circuit of a parallel pair - $(network_model)" for network_model in
                                                                           (
    DCPNetworkModel,
    PTDFNetworkModel,
)
    # Line "1" (A-B) is split into "1" and "1_copy"; the outage takes out "1_copy" only,
    # leaving "1" in service.
    test_line_outages_match_removal(
        network_model,
        [["1_copy"]];
        opened = ["1", "1_copy"],
        parallel_to = "1",
    )
end

@testset "One outage taking out several lines - $(network_model)" for network_model in (
    DCPNetworkModel,
    PTDFNetworkModel,
)
    # A single outage attribute on lines 1 (A-B) and 6 (D-E); the rest stays connected.
    outaged = ["1", "6"]
    container, event = test_line_outages_match_removal(network_model, [outaged])
    @test only(values(get_attribute_device_map(event))) ==
          Dict(PSY.Line => Set(outaged))
    test_lines_carry_no_flow(container, outaged)
end

@testset "Simultaneous outages of separate lines - $(network_model)" for network_model in (
    DCPNetworkModel,
    PTDFNetworkModel,
)
    # Independent outage attributes on lines 2 (A-D) and 4 (B-C), both open at once; the
    # rest stays connected.
    outaged = ["2", "4"]
    container, event =
        test_line_outages_match_removal(network_model, [[n] for n in outaged])
    @test length(get_attribute_device_map(event)) == 2
    @test Set(
        Iterators.flatten(
            devices[PSY.Line] for devices in values(get_attribute_device_map(event))
        ),
    ) == Set(outaged)
    test_lines_carry_no_flow(container, outaged)
end

@testset "An outage lifts the OnVariable lower-bound feedforward" begin
    for network_model in (DCPNetworkModel, PTDFNetworkModel)
        # With `p >= p_min * on`, an upstream commitment forced onto an outaged unit would
        # leave no feasible `p`; the outaged unit must be free to decommit.
        sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
        for g in get_components(ThermalStandard, sys)
            p_max = get_active_power_limits(g, u"SU").max
            set_active_power_limits!(g, (min = 0.2 * p_max * u"SU", max = p_max * u"SU"))
        end
        device_model = DeviceModel(PSY.ThermalStandard, ThermalStandardUnitCommitment)
        attach_feedforward!(
            device_model,
            LowerBoundFeedforward(;
                component_type = PSY.ThermalStandard,
                source = OnVariable,
                affected_values = [OnVariable],
            ),
        )
        container, _ =
            mock_event_container(device_model, network_model; sys, recurrent = true)
        outaged = outaged_name(container, PSY.ThermalStandard)

        committed = IOM.get_parameter_array(
            container,
            LowerBoundValueParameter,
            PSY.ThermalStandard,
        )
        for idx in eachindex(committed)
            JuMP.fix(committed[idx], 1.0; force = true)
        end
        status = IOM.get_parameter_array(
            container,
            AvailableStatusParameter(),
            PSY.ThermalStandard,
        )
        for idx in eachindex(status)
            JuMP.fix(status[idx], 0.0; force = true)
        end

        on = IOM.get_variable(container, OnVariable, PSY.ThermalStandard)
        jm = IOM.get_jump_model(container)
        JuMP.@objective(jm, Min, sum(on))
        JuMP.set_optimizer(jm, HiGHS.Optimizer)
        JuMP.set_silent(jm)
        JuMP.optimize!(jm)
        @test JuMP.termination_status(jm) == MOI.OPTIMAL
        names, time_steps = axes(on)
        for name in names, t in time_steps
            @test JuMP.value(on[name, t]) ≈ (name == outaged ? 0.0 : 1.0) atol = 1e-6
        end
    end
end
