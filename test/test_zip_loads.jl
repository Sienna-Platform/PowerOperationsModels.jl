const ZIP_SPLIT = (constant = 0.5, impedance = 0.3, current = 0.2)

# CU equals SU here. Each PowerLoad becomes a StandardLoad with the same totals.
function _zip_load_system(split = ZIP_SPLIT)
    sys = build_system(PSITestSystems, "c_sys5")
    for load in collect(get_components(PowerLoad, sys))
        p = PSY.get_max_active_power(load, u"CU")
        q = PSY.get_max_reactive_power(load, u"CU")
        zip_load = StandardLoad(;
            name = PSY.get_name(load),
            available = true,
            bus = PSY.get_bus(load),
            base_power = PSY.get_base_power(load),
            max_constant_active_power = split.constant * p,
            max_impedance_active_power = split.impedance * p,
            max_current_active_power = split.current * p,
            max_constant_reactive_power = split.constant * q,
            max_impedance_reactive_power = split.impedance * q,
            max_current_reactive_power = split.current * q,
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

function _bus_voltages(res, ::Type{ACPNetworkModel})
    vm = read_variable(res, "VoltageMagnitude__ACBus"; table_format = TableFormat.WIDE)
    va = read_variable(res, "VoltageAngle__ACBus"; table_format = TableFormat.WIDE)
    bus_names = [n for n in names(vm) if n != "DateTime"]
    return Dict(n => vm[1, n] for n in bus_names), Dict(n => va[1, n] for n in bus_names)
end

function _bus_voltages(res, ::Type{<:Union{ACRNetworkModel, IVRNetworkModel}})
    vr = read_variable(res, "VoltageReal__ACBus"; table_format = TableFormat.WIDE)
    vi = read_variable(res, "VoltageImaginary__ACBus"; table_format = TableFormat.WIDE)
    bus_names = [n for n in names(vr) if n != "DateTime"]
    return Dict(n => hypot(vr[1, n], vi[1, n]) for n in bus_names),
    Dict(n => atan(vi[1, n], vr[1, n]) for n in bus_names)
end

function _set_zip_parts!(load, ::Type{ActivePowerTimeSeriesParameter}, demand)
    set_constant_active_power!(load, ZIP_SPLIT.constant * demand * u"SU")
    set_impedance_active_power!(load, ZIP_SPLIT.impedance * demand * u"SU")
    set_current_active_power!(load, ZIP_SPLIT.current * demand * u"SU")
    return
end

function _set_zip_parts!(load, ::Type{ReactivePowerTimeSeriesParameter}, demand)
    set_constant_reactive_power!(load, ZIP_SPLIT.constant * demand * u"SU")
    set_impedance_reactive_power!(load, ZIP_SPLIT.impedance * demand * u"SU")
    set_current_reactive_power!(load, ZIP_SPLIT.current * demand * u"SU")
    return
end

# Fix loads and generators at the OPF solution; the power flow voltages must match.
function _power_flow_voltages(sys, model, res, magnitudes)
    container = IOM.get_optimization_container(model)
    for parameter in (ActivePowerTimeSeriesParameter, ReactivePowerTimeSeriesParameter)
        param_container = IOM.get_parameter(container, parameter, StandardLoad)
        row_of = IOM.get_row_aggregation(IOM.get_attributes(param_container)).row_of
        for load in get_components(StandardLoad, sys)
            refs, coefficient =
                IOM.get_row_aggregate_refs(param_container, row_of[get_name(load)])
            demand = -coefficient * refs[1]
            _set_zip_parts!(load, parameter, demand)
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

# Generation per bus number in the OPF solution, in MW or MVAr.
function _opf_bus_generation(sys, res, variable_name)
    values = read_variable(res, variable_name; table_format = TableFormat.WIDE)
    by_bus = Dict(PSY.get_number(b) => 0.0 for b in get_components(ACBus, sys))
    for gen in get_components(ThermalStandard, sys)
        by_bus[PSY.get_number(PSY.get_bus(gen))] += values[1, get_name(gen)]
    end
    return by_bus
end

# Each load's consumption output is P0 * (c + z*V^2 + i*V) at its solved bus voltage.
function _test_zip_load_outputs(sys, res, magnitudes, split)
    for (output, parameter) in (
        (
            "ZipLoadActivePower__StandardLoad",
            "ActivePowerTimeSeriesParameter__StandardLoad",
        ),
        (
            "ZipLoadReactivePower__StandardLoad",
            "ReactivePowerTimeSeriesParameter__StandardLoad",
        ),
    )
        consumption = read_aux_variable(res, output; table_format = TableFormat.WIDE)
        injection = read_parameter(res, parameter; table_format = TableFormat.WIDE)
        for load in get_components(StandardLoad, sys)
            name = get_name(load)
            v = magnitudes[get_name(PSY.get_bus(load))]
            factor = split.constant + split.impedance * v^2 + split.current * v
            @test consumption[1, name] ≈ -injection[1, name] * factor atol = 1e-6
        end
    end
    return
end

function _build_log(model)
    return read(joinpath(IOM.get_output_dir(model), "operation_problem.log"), String)
end

@testset "ZIP load parts depend on voltage in AC network models (c_sys5)" begin
    for network_formulation in (ACPNetworkModel, ACRNetworkModel, IVRNetworkModel)
        sys = _zip_load_system()
        model = _solve_zip_model(sys, network_formulation)
        res = IOM.OptimizationProblemOutputs(model)
        magnitudes, angles = _bus_voltages(res, network_formulation)
        _test_zip_load_outputs(sys, res, magnitudes, ZIP_SPLIT)

        # Constant power gives other voltages.
        @test maximum(abs(v - 1.0) for v in values(magnitudes)) > 1e-2
        constant_split = (constant = 1.0, impedance = 0.0, current = 0.0)
        constant_sys = _zip_load_system(constant_split)
        constant_model = _solve_zip_model(constant_sys, network_formulation)
        constant_res = IOM.OptimizationProblemOutputs(constant_model)
        constant_magnitudes, _ = _bus_voltages(constant_res, network_formulation)
        # Constant power loads consume P0.
        _test_zip_load_outputs(
            constant_sys,
            constant_res,
            constant_magnitudes,
            constant_split,
        )
        @test maximum(
            abs(magnitudes[n] - constant_magnitudes[n]) for n in keys(magnitudes)
        ) >
              1e-4

        bus_results = _power_flow_voltages(sys, model, res, magnitudes)
        number_to_name =
            Dict(PSY.get_number(b) => get_name(b) for b in get_components(ACBus, sys))
        for row in eachrow(bus_results)
            name = number_to_name[row.bus_number]
            @test row.Vm ≈ magnitudes[name] atol = 1e-5
            @test row.θ ≈ angles[name] atol = 1e-5
        end
        # The slack P and the PV Q absorb a wrong load term, so compare them too.
        p_opf = _opf_bus_generation(sys, res, "ActivePowerVariable__ThermalStandard")
        q_opf = _opf_bus_generation(sys, res, "ReactivePowerVariable__ThermalStandard")
        for row in eachrow(bus_results)
            @test row.P_gen ≈ p_opf[row.bus_number] atol = 1e-3
            @test row.Q_gen ≈ q_opf[row.bus_number] atol = 1e-3
        end
    end
end

@testset "ZIP loads in a recurrent build under ACP (c_sys5)" begin
    sys = _zip_load_system()
    model = DecisionModel(
        _zip_template(ACPNetworkModel),
        sys;
        optimizer = ipopt_optimizer,
        horizon = Dates.Hour(1),
    )
    container = IOM.get_optimization_container(model)
    container.built_for_recurrent_solves = true
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    jump_model = IOM.get_jump_model(container)
    before = JuMP.objective_value(jump_model)

    param_container =
        IOM.get_parameter(container, ActivePowerTimeSeriesParameter, StandardLoad)
    row_of = IOM.get_row_aggregation(IOM.get_attributes(param_container)).row_of
    # Rows can share a series parameter, so halve each parameter once.
    refs = unique(
        first(IOM.get_row_aggregate_refs(param_container, key))[t] for
        key in values(row_of) for t in IOM.get_time_steps(container)
    )
    for ref in refs
        JuMP.fix(ref, 0.5 * JuMP.fix_value(ref); force = true)
    end
    JuMP.optimize!(jump_model)
    @test JuMP.termination_status(jump_model) in
          (JuMP.MOI.LOCALLY_SOLVED, JuMP.MOI.OPTIMAL)
    @test JuMP.objective_value(jump_model) < before
end

@testset "Loads that stay constant power log one warning" begin
    sys = _zip_load_system()
    model = DecisionModel(
        _zip_template(LPACCNetworkModel),
        sys;
        optimizer = ipopt_optimizer,
        horizon = Dates.Hour(1),
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    log = _build_log(model)
    @test all(occursin(name, log) for name in ("Bus2", "Bus3", "Bus4"))
    @test count("stay constant power", log) == 1

    model = DecisionModel(
        _zip_template(DCPNetworkModel),
        _zip_load_system();
        optimizer = HiGHS_optimizer,
        horizon = Dates.Hour(1),
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test !occursin("stay constant power", _build_log(model))
end
