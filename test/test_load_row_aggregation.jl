# Two static loads share bus 2, so a recurrent build sums their series into one parameter.
function _shared_bus_load_system()
    sys = build_system(PSITestSystems, "c_sys5_uc"; force_build = true)
    load = get_component(PowerLoad, sys, "Bus2")
    twin = PowerLoad(;
        name = "Bus2_twin",
        available = true,
        bus = PSY.get_bus(load),
        active_power = 0.5,
        reactive_power = 0.1,
        base_power = 100.0,
        max_active_power = 0.5,
        max_reactive_power = 0.1,
        input_basis = u"CU",
    )
    add_component!(sys, twin)
    copy_time_series!(twin, load)
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
    load_values = collect(
        IOM.get_parameter_column_values(param_container, PSY.get_name(load)),
    )
    multiplier = IOM.get_multiplier_array(param_container)
    expected = [
        load_values[t] *
        (multiplier[PSY.get_name(load), t] + multiplier[PSY.get_name(twin), t])
        for t in eachindex(load_values)
    ]
    @test JuMP.fix_value.(collect(refs)) ≈ expected
    @test_throws ErrorException IOM.get_parameter_column_refs(
        param_container,
        PSY.get_name(twin),
    )

    @test JuMP.objective_value(IOM.get_jump_model(container)) ≈
          JuMP.objective_value(
        IOM.get_jump_model(IOM.get_optimization_container(single)),
    )
end
