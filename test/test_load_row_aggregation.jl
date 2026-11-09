# Two static loads with different series share bus 2, so a recurrent build sums their
# series into one parameter. A third load on bus 2 has no series and keeps the fallback.
# A load alone on bus 1 shares the series of load Bus3, so both buses share its parameter.
function _static_load(name, max_active_power, bus)
    return PowerLoad(;
        name = name,
        available = true,
        bus = bus,
        active_power = max_active_power,
        reactive_power = 0.1,
        base_power = 100.0,
        max_active_power = max_active_power,
        max_reactive_power = 0.1,
        input_basis = u"CU",
    )
end

function _shared_bus_load_system()
    sys = build_system(
        PSITestSystems,
        "c_sys5_uc";
        add_single_time_series = true,
        force_build = true,
    )
    load = get_component(PowerLoad, sys, "Bus2")
    bus = PSY.get_bus(load)
    twin = _static_load("Bus2_twin", 0.5, bus)
    add_component!(sys, twin)
    series = PSY.get_time_series_array(SingleTimeSeries, load, "max_active_power")
    add_time_series!(
        sys,
        twin,
        SingleTimeSeries(
            "max_active_power",
            TimeArray(TimeSeries.timestamp(series), reverse(TimeSeries.values(series))),
        ),
    )
    flat = _static_load("Bus2_flat", 0.2, bus)
    add_component!(sys, flat)
    bus3_load = get_component(PowerLoad, sys, "Bus3")
    bus1 = only(b for b in get_components(PSY.ACBus, sys) if PSY.get_number(b) == 1)
    bus1_load = _static_load("Bus1_shared", 0.3, bus1)
    add_component!(sys, bus1_load)
    copy_time_series!(bus1_load, bus3_load)
    transform_single_time_series!(sys, Hour(24), Hour(24))
    return sys, load, twin, bus1_load, bus3_load
end

function _build_shared_bus_model(sys; recurrent)
    template = PowerOperationsProblemTemplate(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranch)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    IOM.get_optimization_container(model).built_for_recurrent_solves = recurrent
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    return model
end

_fixed_terms(expr) = count(JuMP.is_fixed, keys(expr.terms))
_fixed_term(expr) = only((v, c) for (v, c) in expr.terms if JuMP.is_fixed(v))

@testset "Static loads on one bus share one balance parameter" begin
    sys, load, twin, bus1_load, bus3_load = _shared_bus_load_system()
    recurrent = _build_shared_bus_model(sys; recurrent = true)
    single = _build_shared_bus_model(sys; recurrent = false)
    container = IOM.get_optimization_container(recurrent)
    bus_number = PSY.get_number(PSY.get_bus(load))

    balance = IOM.get_expression(container, ActivePowerBalance, PSY.ACBus)
    for t in IOM.get_time_steps(container)
        @test _fixed_terms(balance[bus_number, t]) == 1
    end

    param_container =
        IOM.get_parameter(container, ActivePowerTimeSeriesParameter, PowerLoad)
    refs, coefficient = IOM.get_row_aggregate_refs(param_container, bus_number)
    @test coefficient == 1.0
    multiplier = IOM.get_multiplier_array(param_container)
    expected = zeros(length(IOM.get_time_steps(container)))
    for name in (PSY.get_name(load), PSY.get_name(twin))
        values = collect(IOM.get_parameter_column_values(param_container, name))
        for t in eachindex(expected)
            expected[t] += values[t] * multiplier[name, t]
        end
    end
    @test JuMP.fix_value.(collect(refs)) ≈ expected
    @test !(
        collect(IOM.get_parameter_column_values(param_container, PSY.get_name(load))) ≈
        collect(IOM.get_parameter_column_values(param_container, PSY.get_name(twin)))
    )
    for t in IOM.get_time_steps(container)
        @test JuMP.constant(balance[bus_number, t]) ≈ -0.2
    end
    @test_throws ErrorException IOM.get_parameter_column_refs(
        param_container,
        PSY.get_name(twin),
    )

    # Bus 2 sums two series; buses 1 and 3 share the Bus3 series; bus 4 has its own.
    jump_model = IOM.get_jump_model(container)
    time_steps = IOM.get_time_steps(container)
    @test count(JuMP.is_fixed, JuMP.all_variables(jump_model)) == 3 * length(time_steps)
    for t in time_steps
        terms = map((bus1_load, bus3_load)) do l
            v, c = _fixed_term(balance[PSY.get_number(PSY.get_bus(l)), t])
            name = PSY.get_name(l)
            value = IOM.get_parameter_column_values(param_container, name)[t]
            @test c * JuMP.fix_value(v) ≈ value * multiplier[name, t]
            return v
        end
        @test terms[1] == terms[2]
    end

    @test JuMP.objective_value(jump_model) ≈
          JuMP.objective_value(
        IOM.get_jump_model(IOM.get_optimization_container(single)),
    )
end
