function _add_cu_probe!(sys, device, name, quantity_kind)
    initial_time = first(PSY.get_forecast_initial_times(sys))
    stamps = collect(range(initial_time; step = Hour(1), length = 24))
    PSY.add_time_series!(
        sys,
        device,
        PSY.SingleTimeSeries(
            name,
            TimeArray(stamps, ones(24));
            quantity_kind = quantity_kind,
            per_unit_of = "base_power",
        ),
    )
    return IS.get_time_series_metadata(PSY.SingleTimeSeries, device, name)
end

function _zip_load_on_bus2(sys; active_parts, reactive_parts)
    load = get_component(PowerLoad, sys, "Bus2")
    zip_load = StandardLoad(;
        name = "zip_bus2",
        available = true,
        bus = PSY.get_bus(load),
        base_power = PSY.get_base_power(load),
        max_constant_active_power = active_parts[1],
        max_impedance_active_power = active_parts[2],
        max_current_active_power = active_parts[3],
        max_constant_reactive_power = reactive_parts[1],
        max_impedance_reactive_power = reactive_parts[2],
        max_current_reactive_power = reactive_parts[3],
        input_basis = u"CU",
    )
    add_component!(sys, zip_load)
    copy_time_series!(zip_load, load)
    PSY.remove_component!(sys, load)
    return zip_load
end

_cu_to_su(sys, d) = PSY.get_base_power(d) / PSY.get_base_power(sys)
_limits_ratio(d) =
    PSY.get_reactive_power_limits(d, u"SU").max / PSY.get_max_active_power(d, u"SU")

@testset "A reactive-labelled series converts as reactive power" begin
    cases = Any[]
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    thermal = first(get_components(ThermalStandard, sys))
    push!(cases, (sys, thermal, FixedOutput, 1.0, _limits_ratio(thermal)))
    load = get_component(PowerLoad, sys, "Bus3")
    load_ratio =
        PSY.get_max_reactive_power(load, u"SU") / PSY.get_max_active_power(load, u"SU")
    push!(cases, (sys, load, StaticPowerLoad, -1.0, load_ratio))

    hy_sys = PSB.build_system(PSITestSystems, "c_sys5_hy")
    hydro = first(get_components(HydroDispatch, hy_sys))
    PSY.set_reactive_power_limits!(hydro, (min = -0.2 * u"SU", max = 0.3 * u"SU"))
    push!(cases, (hy_sys, hydro, FixedOutput, 1.0, _limits_ratio(hydro)))

    re_sys = PSB.build_system(PSITestSystems, "c_sys5_re")
    renewable = first(get_components(RenewableDispatch, re_sys))
    pf_ratio = tan(acos(PSY.get_power_factor(renewable)))
    push!(cases, (re_sys, renewable, FixedOutput, 1.0, pf_ratio))

    zip_sys = PSB.build_system(PSITestSystems, "c_sys5")
    zip_load =
        _zip_load_on_bus2(zip_sys; active_parts = (0.5, 0.3, 0.2),
            reactive_parts = (0.1, 0.05, 0.05))
    push!(cases, (zip_sys, zip_load, StaticPowerLoad, -1.0, 0.2 / 1.0))

    for (s, d, F, sign, ratio) in cases
        q_md = _add_cu_probe!(s, d, "q_probe", "reactive_power")
        p_md = _add_cu_probe!(s, d, "p_probe", "active_power")
        @test POM.get_multiplier_value(ReactivePowerTimeSeriesParameter, d, F, q_md) ≈
              sign * _cu_to_su(s, d)
        @test POM.get_multiplier_value(ReactivePowerTimeSeriesParameter, d, F, p_md) ≈
              sign * _cu_to_su(s, d) * ratio
    end
end

# A device type whose every device uses its static value has no parameter.
function _reactive_parameter_names(container, ::Type{D}) where {D}
    IOM.has_container_key(container, ReactivePowerTimeSeriesParameter, D) ||
        return Set{String}()
    param = IOM.get_parameter(container, ReactivePowerTimeSeriesParameter, D)
    return Set(axes(IOM.get_multiplier_array(param))[1])
end

function _reactive_balance_constant(container, bus_number)
    expr = IOM.get_expression(container, POM.ReactivePowerBalance, PSY.ACBus)
    return JuMP.constant(expr[bus_number, 1])
end

@testset "A load with zero active power uses its static reactive power" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    load = get_component(PowerLoad, sys, "Bus3")
    q_max = PSY.get_max_reactive_power(load, u"SU")
    PSY.set_max_active_power!(load, 0.0 * u"SU")
    model = DecisionModel(MockOperationProblem, ACPNetworkModel, sys)
    @test_logs (:warn, r"Bus3.*max_active_power = 0") match_mode = :any mock_construct_device!(
        model,
        DeviceModel(PowerLoad, StaticPowerLoad),
    )
    container = IOM.get_optimization_container(model)
    @test "Bus3" ∉ _reactive_parameter_names(container, PowerLoad)
    @test "Bus2" in _reactive_parameter_names(container, PowerLoad)
    bus = PSY.get_number(PSY.get_bus(load))
    @test _reactive_balance_constant(container, bus) ≈ -q_max
end

@testset "A ZIP load with zero active parts uses its static reactive power" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    zip_load = _zip_load_on_bus2(
        sys;
        active_parts = (0.0, 0.0, 0.0),
        reactive_parts = (0.1, 0.0, 0.0),
    )
    model = DecisionModel(MockOperationProblem, ACPNetworkModel, sys)
    @test_logs (:warn, r"zip_bus2.*max_active_power = 0") match_mode = :any mock_construct_device!(
        model,
        DeviceModel(StandardLoad, StaticPowerLoad),
    )
    container = IOM.get_optimization_container(model)
    @test "zip_bus2" ∉ _reactive_parameter_names(container, StandardLoad)
    bus = PSY.get_number(PSY.get_bus(zip_load))
    @test _reactive_balance_constant(container, bus) ≈
          -PSY.get_max_constant_reactive_power(zip_load, u"SU")
end

@testset "A FixedOutput generator with zero active power uses its static reactive power" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_hy")
    hydro = first(get_components(HydroDispatch, sys))
    PSY.set_reactive_power_limits!(hydro, (min = -0.2 * u"SU", max = 0.3 * u"SU"))
    PSY.set_active_power_limits!(hydro, (min = 0.0 * u"SU", max = 0.0 * u"SU"))
    model = DecisionModel(MockOperationProblem, ACPNetworkModel, sys)
    device_model = DeviceModel(
        HydroDispatch,
        FixedOutput;
        time_series_names = Dict(
            ActivePowerTimeSeriesParameter => "max_active_power",
            ReactivePowerTimeSeriesParameter => "max_active_power",
        ),
    )
    name = PSY.get_name(hydro)
    @test_logs (:warn, Regex("$(name).*max_active_power = 0")) match_mode = :any mock_construct_device!(
        model,
        device_model,
    )
    container = IOM.get_optimization_container(model)
    @test name ∉ _reactive_parameter_names(container, HydroDispatch)
    bus = PSY.get_number(PSY.get_bus(hydro))
    @test _reactive_balance_constant(container, bus) ≈ 0.3
end
