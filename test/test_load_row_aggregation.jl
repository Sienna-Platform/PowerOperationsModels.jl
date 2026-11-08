# Two static loads with different series share bus 2, so a recurrent build sums their
# series into one parameter. A third load on bus 2 has no series and keeps the fallback.
function _bus2_load(name, max_active_power, bus)
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
    twin = _bus2_load("Bus2_twin", 0.5, bus)
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
    flat = _bus2_load("Bus2_flat", 0.2, bus)
    add_component!(sys, flat)
    transform_single_time_series!(sys, Hour(24), Hour(24))
    return sys, load, twin
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

@testset "Static loads on one bus share one balance parameter" begin
    sys, load, twin = _shared_bus_load_system()
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
    refs = IOM.get_row_aggregate_refs(param_container, bus_number)
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

    @test JuMP.objective_value(IOM.get_jump_model(container)) ≈
          JuMP.objective_value(
        IOM.get_jump_model(IOM.get_optimization_container(single)),
    )
end
