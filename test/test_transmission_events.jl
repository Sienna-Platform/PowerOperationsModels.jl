# c_sys5 lines: 1 A-B, 2 A-D, 3 A-E, 4 B-C, 5 C-D, 6 D-E. Generation sits at A, C, D and E;
# load at B, C and D.

const LINE_OUTAGE_NETWORKS = (DCPNetworkModel, PTDFNetworkModel)

function line_outage_template(network_model)
    template = get_thermal_dispatch_template_network(NetworkModel(network_model))
    set_device_model!(template, Line, StaticBranchBounds)
    return template
end

c_sys5() = PSB.build_system(PSITestSystems, "c_sys5")

# c_sys5 with line `parallel_to` split into two parallel circuits.
function c_sys5_with_parallel_circuit(parallel_to)
    sys = c_sys5()
    add_equivalent_ac_transmission_with_parallel_circuits!(
        sys,
        PSY.get_component(PSY.Line, sys, parallel_to),
        PSY.Line,
    )
    return sys
end

horizon_steps(sys) =
    Int(PSY.get_forecast_horizon(sys) / first(PSY.get_time_series_resolutions(sys)))

# An `outage_status` series: 1 (out) through step `until`, 0 after. Outages in a simulation
# window are always in effect from its first step.
outage_status(sys; until = horizon_steps(sys)) =
    [t <= until ? 1.0 : 0.0 for t in 1:horizon_steps(sys)]

lines_out_at(outages, t) =
    Set{String}(name for (names, status) in outages if isone(status[t]) for name in names)

function build_line_model(template, sys; rebuild_model = false)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, rebuild_model)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

function solve_line_model!(container)
    jm = IOM.get_jump_model(container)
    JuMP.optimize!(jm)
    return JuMP.termination_status(jm)
end

function solve_with_outages(network_model, sys, outages)
    for (names, status) in outages
        lines = [PSY.get_component(PSY.Line, sys, name) for name in names]
        outage = attach_fixed_forced_outage!(sys, first(lines); outage_profile = status)
        for line in lines[2:end]
            PSY.add_supplemental_attribute!(sys, line, outage)
        end
    end
    template = line_outage_template(network_model)
    event = fixed_outage_event()
    set_event_model!(template, event)
    fill_event_model!(event, sys)
    model = build_line_model(template, sys; rebuild_model = true)
    container = IOM.get_optimization_container(model)
    # As a simulation does: write the status parameters, then rebuild the model on them.
    available = IOM.get_parameter_array(container, AvailableStatusParameter(), PSY.Line)
    names, steps = axes(available)
    for t in steps
        out = lines_out_at(outages, t)
        for name in names
            available[name, t] = name in out ? 0.0 : 1.0
        end
    end
    IOM.reset_optimization_model!(container)
    POM.build_problem!(container, IOM.get_template(model), sys)
    return container, solve_line_model!(container)
end

function solve_with_removal(network_model, sys, names)
    for name in names
        PSY.remove_component!(sys, PSY.get_component(PSY.Line, sys, name))
    end
    model = build_line_model(line_outage_template(network_model), sys)
    container = IOM.get_optimization_container(model)
    return container, solve_line_model!(container)
end

function test_matches_reference(container, reference, t, out)
    p = IOM.get_variable(container, ActivePowerVariable, PSY.ThermalStandard)
    p_ref = IOM.get_variable(reference, ActivePowerVariable, PSY.ThermalStandard)
    for name in axes(p)[1]
        @test JuMP.value(p[name, t]) ≈ JuMP.value(p_ref[name, t]) atol = 1e-6
    end
    flow = IOM.get_variable(container, FlowActivePowerVariable, PSY.Line)
    flow_ref = IOM.get_variable(reference, FlowActivePowerVariable, PSY.Line)
    for name in axes(flow)[1]
        if name in out
            @test abs(JuMP.value(flow[name, t])) <= 1e-6
        elseif name in axes(flow_ref)[1]
            @test JuMP.value(flow[name, t]) ≈ JuMP.value(flow_ref[name, t]) atol = 1e-6
        end
    end
    return
end

# At every time step the outage model matches a fresh `build_sys()` with that step's
# outaged lines removed: the same dispatch, the same flows on surviving lines, and no flow
# on the outaged ones.
function test_outages_match_removal(network_model, build_sys, outages)
    container, termination = solve_with_outages(network_model, build_sys(), outages)
    @test termination == MOI.OPTIMAL
    steps = IOM.get_time_steps(container)
    references = Dict(
        out => solve_with_removal(network_model, build_sys(), out) for
        out in unique(lines_out_at(outages, t) for t in steps)
    )
    for (reference, termination) in values(references)
        @test termination == MOI.OPTIMAL
    end
    for t in steps
        out = lines_out_at(outages, t)
        test_matches_reference(container, first(references[out]), t, out)
    end
    return container
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

@testset "Line outage that never occurs" begin
    for network_model in LINE_OUTAGE_NETWORKS
        status = zeros(horizon_steps(c_sys5()))
        test_outages_match_removal(network_model, c_sys5, [(["1"], status)])
    end
end

@testset "Line outage over the whole horizon" begin
    for network_model in LINE_OUTAGE_NETWORKS
        status = outage_status(c_sys5())
        test_outages_match_removal(network_model, c_sys5, [(["1"], status)])
    end
end

@testset "Line outage ending mid-horizon" begin
    for network_model in LINE_OUTAGE_NETWORKS
        status = outage_status(c_sys5(); until = 12)
        test_outages_match_removal(network_model, c_sys5, [(["1"], status)])
    end
end

@testset "Outage of one circuit of a parallel pair" begin
    for network_model in LINE_OUTAGE_NETWORKS
        # Line "1" (A-B) is split into "1" and "1_copy"; the outage takes out "1_copy"
        # only, leaving "1" in service.
        build_sys = () -> c_sys5_with_parallel_circuit("1")
        status = outage_status(build_sys(); until = 8)
        test_outages_match_removal(network_model, build_sys, [(["1_copy"], status)])
    end
end

@testset "One outage taking out several lines" begin
    for network_model in LINE_OUTAGE_NETWORKS
        # A single outage attribute on lines 1 (A-B) and 6 (D-E); the rest stays connected.
        outaged = ["1", "6"]
        status = outage_status(c_sys5(); until = 8)
        test_outages_match_removal(network_model, c_sys5, [(outaged, status)])
    end
end

@testset "Staggered outages of separate lines" begin
    for network_model in LINE_OUTAGE_NETWORKS
        # Independent outage attributes on lines 2 (A-D) and 4 (B-C) ending at steps 8 and
        # 16, so the network passes through {2, 4}, {4} and {} out of service.
        sys = c_sys5()
        test_outages_match_removal(
            network_model,
            c_sys5,
            [(["2"], outage_status(sys; until = 8)), (["4"], outage_status(sys; until = 16))],
        )
    end
end

@testset "Line outages islanding a bus with generation and load" begin
    for network_model in LINE_OUTAGE_NETWORKS
        # Opening lines 4 (B-C) and 5 (C-D) through step 8 leaves nodeC on its own with
        # Solitude and Bus3, which Solitude can serve.
        sys = c_sys5()
        islanding = ["4", "5"]
        status = outage_status(sys; until = 8)
        container, termination =
            solve_with_outages(network_model, sys, [(islanding, status)])
        @test termination == MOI.OPTIMAL
        flow = IOM.get_variable(container, FlowActivePowerVariable, PSY.Line)
        p = IOM.get_variable(container, ActivePowerVariable, PSY.ThermalStandard)
        island_load = load_profile_at(sys, "nodeC")
        for t in IOM.get_time_steps(container)
            isone(status[t]) || continue
            for name in islanding
                @test abs(JuMP.value(flow[name, t])) <= 1e-6
            end
            @test JuMP.value(p["Solitude", t]) ≈ island_load[t] atol = 1e-6
        end
    end
end

@testset "Line outages islanding a bus with load only are infeasible" begin
    for network_model in LINE_OUTAGE_NETWORKS
        # Opening lines 1 (A-B) and 4 (B-C) leaves nodeB with Bus2's load and no generation.
        sys = c_sys5()
        _, termination =
            solve_with_outages(network_model, sys, [(["1", "4"], outage_status(sys))])
        @test termination in (MOI.INFEASIBLE, MOI.INFEASIBLE_OR_UNBOUNDED)
    end
end

@testset "An outage lifts the OnVariable lower-bound feedforward" begin
    for network_model in LINE_OUTAGE_NETWORKS
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
            mock_event_container(device_model, network_model; sys)
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
