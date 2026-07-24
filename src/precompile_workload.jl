# Executes build!/solve! at precompile time, so this file must stay the last
# include of the module: the IOM method imports after the main include block
# (set_status! etc.) have to be evaluated first.

function _build_precompile_system()
    sys = PSY.System(100.0; time_series_in_memory = true)
    # One area per bus so the AreaPTDF template has a non-degenerate area graph.
    area1 = PSY.Area(; name = "area1")
    area2 = PSY.Area(; name = "area2")
    PSY.add_component!(sys, area1)
    PSY.add_component!(sys, area2)
    bus1 = PSY.ACBus(;
        number = 1,
        name = "bus1",
        available = true,
        bustype = PSY.ACBusTypes.REF,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (0.9, 1.1),
        base_voltage = 230.0,
        area = area1,
    )
    bus2 = PSY.ACBus(;
        number = 2,
        name = "bus2",
        available = true,
        bustype = PSY.ACBusTypes.PV,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (0.9, 1.1),
        base_voltage = 230.0,
        area = area2,
    )
    PSY.add_component!(sys, bus1)
    PSY.add_component!(sys, bus2)
    arc = PSY.Arc(; from = bus1, to = bus2)
    PSY.add_component!(sys, arc)
    line = PSY.Line(;
        name = "line1",
        available = true,
        active_power_flow = 0.0,
        reactive_power_flow = 0.0,
        arc = arc,
        r = 0.01,
        x = 0.05,
        b = (from = 0.0, to = 0.0),
        rating = 5.0,
        angle_limits = (min = -1.57, max = 1.57),
    )
    PSY.add_component!(sys, line)
    thermal1 = PSY.ThermalStandard(;
        name = "thermal1",
        available = true,
        status = true,
        bus = bus1,
        active_power = 0.5,
        reactive_power = 0.0,
        rating = 1.0,
        active_power_limits = (min = 0.2, max = 1.0),
        reactive_power_limits = nothing,
        # Must stay below |max - min| / 60 (pu/min at hourly resolution) or
        # _get_ramp_constraint_devices drops the device and no RampConstraint
        # is compiled. Same logic for thermal2.
        ramp_limits = (up = 0.005, down = 0.005),
        operation_cost = PSY.ThermalGenerationCost(;
            variable = PSY.CostCurve(PSY.LinearCurve(20.0)),
            fixed = 1.0,
            start_up = 100.0,
            shut_down = 50.0,
        ),
        base_power = 100.0,
        time_limits = (up = 2.0, down = 2.0),
    )
    thermal2 = PSY.ThermalStandard(;
        name = "thermal2",
        available = true,
        status = true,
        bus = bus2,
        active_power = 0.5,
        reactive_power = 0.0,
        rating = 1.0,
        active_power_limits = (min = 0.1, max = 0.8),
        reactive_power_limits = nothing,
        ramp_limits = (up = 0.006, down = 0.006),
        operation_cost = PSY.ThermalGenerationCost(;
            variable = PSY.CostCurve(PSY.QuadraticCurve(5.0, 15.0, 0.0)),
            fixed = 0.5,
            start_up = 80.0,
            shut_down = 40.0,
        ),
        base_power = 100.0,
        time_limits = (up = 2.0, down = 2.0),
    )
    PSY.add_component!(sys, thermal1)
    PSY.add_component!(sys, thermal2)
    renewable = PSY.RenewableDispatch(;
        name = "renewable1",
        available = true,
        bus = bus2,
        active_power = 0.0,
        reactive_power = 0.0,
        rating = 1.2,
        prime_mover_type = PSY.PrimeMovers.WT,
        reactive_power_limits = nothing,
        power_factor = 1.0,
        operation_cost = PSY.RenewableGenerationCost(nothing),
        base_power = 100.0,
    )
    PSY.add_component!(sys, renewable)
    load = PSY.PowerLoad(;
        name = "load1",
        available = true,
        bus = bus2,
        active_power = 1.0,
        reactive_power = 0.0,
        base_power = 100.0,
        max_active_power = 1.0,
        max_reactive_power = 0.0,
    )
    PSY.add_component!(sys, load)

    horizon_count = 24
    initial_time = Dates.DateTime("2024-01-01T00:00:00")
    load_data = Dict(
        initial_time =>
            [0.6 + 0.4 * abs(sin(pi * t / 12)) for t in 1:horizon_count],
    )
    re_data = Dict(
        initial_time =>
            [0.5 + 0.5 * abs(cos(pi * t / 12)) for t in 1:horizon_count],
    )
    PSY.add_time_series!(
        sys,
        load,
        PSY.Deterministic(;
            name = "max_active_power",
            data = load_data,
            resolution = Dates.Hour(1),
        ),
    )
    PSY.add_time_series!(
        sys,
        renewable,
        PSY.Deterministic(;
            name = "max_active_power",
            data = re_data,
            resolution = Dates.Hour(1),
        ),
    )
    return sys
end

function _precompile_uc_template()
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PSY.ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template, PSY.RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PSY.PowerLoad, StaticPowerLoad)
    return template
end

function _build_precompile_model(sys, template, output_dir)
    model = DecisionModel(
        template,
        sys;
        horizon = Dates.Hour(24),
        initialize_model = false,
        store_variable_names = true,
    )
    status = build!(
        model;
        output_dir = output_dir,
        console_level = Logging.Error,
        store_system_in_results = false,
    )
    if status != IOM.ModelBuildStatus.BUILT
        error(
            "precompile workload build failed with status $status; " *
            "see $(joinpath(output_dir, "operation_problem.log"))",
        )
    end
    return model
end

function _precompile_mock_optimizer()
    mock = JuMP.MOI.Utilities.MockOptimizer(JuMP.MOI.Utilities.Model{Float64}())
    JuMP.MOI.Utilities.set_mock_optimize!(
        mock,
        m -> JuMP.MOI.Utilities.mock_optimize!(
            m,
            JuMP.MOI.OPTIMAL,
            (
                JuMP.MOI.FEASIBLE_POINT,
                zeros(JuMP.MOI.get(m, JuMP.MOI.NumberOfVariables())),
            ),
        ),
    )
    return mock
end

function _run_precompile_workload(sys, output_dir)
    return Logging.with_logger(Logging.NullLogger()) do
        uc_dir = mkpath(joinpath(output_dir, "uc_copperplate"))
        model = _build_precompile_model(sys, _precompile_uc_template(), uc_dir)
        run_status = solve!(
            model;
            optimizer = _precompile_mock_optimizer,
            console_level = Logging.Error,
            export_optimization_problem = false,
        )
        if run_status != IOM.RunStatus.SUCCESSFULLY_FINALIZED
            error(
                "precompile workload solve failed with status $run_status; " *
                "see $(joinpath(uc_dir, "operation_problem.log"))",
            )
        end

        template_ed_ptdf = PowerOperationsProblemTemplate(PTDFNetworkModel)
        set_device_model!(template_ed_ptdf, PSY.ThermalStandard, ThermalStandardDispatch)
        set_device_model!(template_ed_ptdf, PSY.RenewableDispatch, RenewableFullDispatch)
        set_device_model!(template_ed_ptdf, PSY.PowerLoad, StaticPowerLoad)
        set_device_model!(template_ed_ptdf, PSY.Line, StaticBranch)
        _build_precompile_model(
            sys,
            template_ed_ptdf,
            mkpath(joinpath(output_dir, "ed_ptdf")),
        )

        template_uc_dcp = PowerOperationsProblemTemplate(DCPNetworkModel)
        set_device_model!(
            template_uc_dcp,
            PSY.ThermalStandard,
            ThermalStandardUnitCommitment,
        )
        set_device_model!(template_uc_dcp, PSY.RenewableDispatch, RenewableFullDispatch)
        set_device_model!(template_uc_dcp, PSY.PowerLoad, StaticPowerLoad)
        set_device_model!(template_uc_dcp, PSY.Line, StaticBranch)
        _build_precompile_model(
            sys,
            template_uc_dcp,
            mkpath(joinpath(output_dir, "uc_dcp")),
        )

        template_ed_areaptdf = PowerOperationsProblemTemplate(AreaPTDFNetworkModel)
        set_device_model!(
            template_ed_areaptdf,
            PSY.ThermalStandard,
            ThermalStandardDispatch,
        )
        set_device_model!(
            template_ed_areaptdf,
            PSY.RenewableDispatch,
            RenewableFullDispatch,
        )
        set_device_model!(template_ed_areaptdf, PSY.PowerLoad, StaticPowerLoad)
        set_device_model!(template_ed_areaptdf, PSY.Line, StaticBranchBounds)
        _build_precompile_model(
            sys,
            template_ed_areaptdf,
            mkpath(joinpath(output_dir, "ed_areaptdf")),
        )
        return nothing
    end
end

PrecompileTools.@setup_workload begin
    PrecompileTools.@compile_workload begin
        _precompile_output_dir = mktempdir()
        try
            _precompile_sys = _build_precompile_system()
            _run_precompile_workload(_precompile_sys, _precompile_output_dir)
        finally
            rm(_precompile_output_dir; force = true, recursive = true)
        end
    end
end
