const ZIP_SPLIT = (constant = 0.5, impedance = 0.3, current = 0.2)

# Component base equals system base here, so CU values equal SU values.
# Each PowerLoad becomes a StandardLoad with the same totals, split into ZIP parts.
function _zip_load_system()
    sys = build_system(PSITestSystems, "c_sys5")
    for load in collect(get_components(PowerLoad, sys))
        p = PSY.get_max_active_power(load, u"CU")
        q = PSY.get_max_reactive_power(load, u"CU")
        zip_load = StandardLoad(;
            name = PSY.get_name(load),
            available = true,
            bus = PSY.get_bus(load),
            base_power = PSY.get_base_power(load),
            max_constant_active_power = ZIP_SPLIT.constant * p,
            max_impedance_active_power = ZIP_SPLIT.impedance * p,
            max_current_active_power = ZIP_SPLIT.current * p,
            max_constant_reactive_power = ZIP_SPLIT.constant * q,
            max_impedance_reactive_power = ZIP_SPLIT.impedance * q,
            max_current_reactive_power = ZIP_SPLIT.current * q,
            input_basis = u"CU",
        )
        add_component!(sys, zip_load)
        copy_time_series!(zip_load, load)
        PSY.remove_component!(sys, load)
    end
    return sys
end

function _zip_template(network_formulation)
    template = PowerOperationsProblemTemplate(NetworkModel(network_formulation))
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    set_device_model!(template, StandardLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranch)
    set_device_model!(template, TwoWindingTransformer, StaticBranch)
    return template
end

function _solve_zip_model(sys, network_formulation)
    model = DecisionModel(
        _zip_template(network_formulation),
        sys;
        optimizer = ipopt_optimizer,
        horizon = Dates.Hour(1),
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    return model
end

# Voltage magnitude of each bus at the first time step, by bus name.
function _bus_voltage_magnitudes(res, ::Type{ACPNetworkModel})
    vm = read_variable(res, "VoltageMagnitude__ACBus"; table_format = TableFormat.WIDE)
    return Dict(n => vm[1, n] for n in names(vm) if n != "DateTime")
end

function _bus_voltage_magnitudes(res, ::Type{ACRNetworkModel})
    vr = read_variable(res, "VoltageReal__ACBus"; table_format = TableFormat.WIDE)
    vi = read_variable(res, "VoltageImaginary__ACBus"; table_format = TableFormat.WIDE)
    return Dict(n => hypot(vr[1, n], vi[1, n]) for n in names(vr) if n != "DateTime")
end

# Fix each load at its first-step ZIP parts and each generator at its dispatch, then solve
# the power flow. Its PQ-bus voltages must equal the OPF voltages.
function _power_flow_voltages(sys, model, res, magnitudes)
    container = IOM.get_optimization_container(model)
    for name in ("P", "Q")
        parameter =
            name == "P" ? ActivePowerTimeSeriesParameter :
            ReactivePowerTimeSeriesParameter
        param_container = IOM.get_parameter(container, parameter, StandardLoad)
        row_of = IOM.get_row_aggregation(IOM.get_attributes(param_container)).row_of
        for load in get_components(StandardLoad, sys)
            demand = -IOM.get_row_aggregate_refs(param_container, row_of[get_name(load)])[1]
            if name == "P"
                set_constant_active_power!(load, ZIP_SPLIT.constant * demand * u"SU")
                set_impedance_active_power!(load, ZIP_SPLIT.impedance * demand * u"SU")
                set_current_active_power!(load, ZIP_SPLIT.current * demand * u"SU")
            else
                set_constant_reactive_power!(load, ZIP_SPLIT.constant * demand * u"SU")
                set_impedance_reactive_power!(load, ZIP_SPLIT.impedance * demand * u"SU")
                set_current_reactive_power!(load, ZIP_SPLIT.current * demand * u"SU")
            end
        end
    end
    base_power = IOM.get_model_base_power(res)
    p = read_variable(res, "ActivePowerVariable__ThermalStandard";
        table_format = TableFormat.WIDE)
    for gen in get_components(ThermalStandard, sys)
        set_active_power!(gen, p[1, get_name(gen)] / base_power * u"SU")
    end
    for bus in get_components(ACBus, sys)
        set_magnitude!(bus, magnitudes[get_name(bus)] * u"CU")
    end
    results = PFS.solve_power_flow(PFS.ACPowerFlow(), sys)
    return results["bus_results"]
end

function _bus_voltage_angles(res, ::Type{ACPNetworkModel})
    va = read_variable(res, "VoltageAngle__ACBus"; table_format = TableFormat.WIDE)
    return Dict(n => va[1, n] for n in names(va) if n != "DateTime")
end

function _bus_voltage_angles(res, ::Type{ACRNetworkModel})
    vr = read_variable(res, "VoltageReal__ACBus"; table_format = TableFormat.WIDE)
    vi = read_variable(res, "VoltageImaginary__ACBus"; table_format = TableFormat.WIDE)
    return Dict(n => atan(vi[1, n], vr[1, n]) for n in names(vr) if n != "DateTime")
end

@testset "ZIP load parts depend on voltage in AC network models (c_sys5)" begin
    for network_formulation in (ACPNetworkModel, ACRNetworkModel)
        sys = _zip_load_system()
        model = _solve_zip_model(sys, network_formulation)
        res = IOM.OptimizationProblemOutputs(model)
        magnitudes = _bus_voltage_magnitudes(res, network_formulation)
        angles = _bus_voltage_angles(res, network_formulation)

        bus_results = _power_flow_voltages(sys, model, res, magnitudes)
        number_to_name =
            Dict(PSY.get_number(b) => get_name(b) for b in get_components(ACBus, sys))
        for row in eachrow(bus_results)
            name = number_to_name[row.bus_number]
            @test row.Vm ≈ magnitudes[name] atol = 1e-5
            @test row.θ ≈ angles[name] atol = 1e-5
        end
    end
end
