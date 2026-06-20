# Time-varying ORDC. Adapted from PowerSimulations.jl PR #1629 to the psy6 data model,
# where a time-varying ORDC is a `ReserveDemandTimeSeriesCurve` whose `variable` is a
# `CostCurve{TimeSeriesPiecewiseIncrementalCurve}` (rather than a `ReserveDemandCurve`
# carrying a bare `TimeSeriesKey`). The multi-step Simulation scenario from that PR is
# omitted: the Simulation framework is not yet available in the IOM/POM split.

# Build a time-varying ORDC (`ReserveDemandTimeSeriesCurve`) from the system's existing
# static ORDC baseline curve, backing it with a deterministic cost-curve forecast.
function _add_ts_ordc!(
    sys,
    name::String,
    static_ordc;
    incrs_x = (0.0, 0.0, 0.0),
    incrs_y = (0.0, 0.0, 0.0),
    create_extra_tranches = false,
)
    baseline_curve = PSY.get_variable(static_ordc)
    power_units = PSY.get_power_units(baseline_curve)
    fd = PSY.get_function_data(PSY.get_value_curve(baseline_curve))

    # Construct with a stub TS curve so the component can be added; the real forecast is
    # attached and set below.
    stub = stub_ts_offer_curve(; power_units = power_units)
    ordc_ts = ReserveDemandTimeSeriesCurve{ReserveUp}(
        stub,
        name,
        true,
        PSY.get_time_frame(static_ordc),
    )
    add_service!(sys, ordc_ts, get_components(ThermalStandard, sys))

    pwl_ts = make_deterministic_ts(
        sys,
        "variable_cost",
        fd,
        incrs_x,
        incrs_y;
        override_min_x = 0.0,
        override_max_x = last(get_x_coords(fd)),
        create_extra_tranches = create_extra_tranches,
    )
    pwl_key = add_time_series!(sys, ordc_ts, pwl_ts)
    PSY.set_variable!(ordc_ts, PSY.make_market_bid_ts_curve(pwl_key, nothing, power_units))
    return ordc_ts
end

@testset "Test ORDC time series (build)" begin
    c_sys5_uc = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_reserves = true)
    static_ordc = first(get_components(PSY.ReserveDemandCurve, c_sys5_uc))
    _add_ts_ordc!(c_sys5_uc, "ORDC_TS", static_ordc)

    template = get_thermal_standard_uc_template()
    set_service_model!(
        template,
        ServiceModel(VariableReserve{ReserveUp}, RangeReserve, "Reserve1"),
    )
    set_service_model!(
        template,
        ServiceModel(VariableReserve{ReserveUp}, RangeReserve, "Reserve11"),
    )
    set_service_model!(
        template,
        ServiceModel(VariableReserve{ReserveDown}, RangeReserve, "Reserve2"),
    )
    set_service_model!(
        template,
        ServiceModel(
            ReserveDemandTimeSeriesCurve{ReserveUp},
            StepwiseCostReserve,
            "ORDC_TS",
        ),
    )
    model = DecisionModel(
        template,
        c_sys5_uc;
        store_variable_names = true,
        optimizer = HiGHS_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
end

@testset "Test ORDC time series (build & solve)" begin
    c_sys5_uc = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_reserves = true)
    static_ordc = first(get_components(PSY.ReserveDemandCurve, c_sys5_uc))
    # Two time-varying ORDCs with different per-timestep tranche counts to exercise the
    # tranche-axis padding and per-service (meta-keyed) parameter containers.
    _add_ts_ordc!(
        c_sys5_uc,
        "ORDC_TS1",
        static_ordc;
        incrs_x = (0.03, 0.13, 0.07),
        incrs_y = (0.03, 0.13, 0.07),
        create_extra_tranches = true,
    )
    _add_ts_ordc!(
        c_sys5_uc,
        "ORDC_TS2",
        static_ordc;
        incrs_x = (0.03, 0.13, 0.07),
        incrs_y = (0.02, 0.14, 0.08),
        create_extra_tranches = true,
    )

    template = PowerOperationsProblemTemplate(
        NetworkModel(CopperPlatePowerModel; use_slacks = true),
    )
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_service_model!(
        template,
        ServiceModel(VariableReserve{ReserveUp}, RangeReserve, "Reserve1"),
    )
    set_service_model!(
        template,
        ServiceModel(VariableReserve{ReserveDown}, RangeReserve, "Reserve2"),
    )
    set_service_model!(
        template,
        ServiceModel(
            ReserveDemandTimeSeriesCurve{ReserveUp},
            StepwiseCostReserve,
            "ORDC_TS1",
        ),
    )
    set_service_model!(
        template,
        ServiceModel(
            ReserveDemandTimeSeriesCurve{ReserveUp},
            StepwiseCostReserve,
            "ORDC_TS2",
        ),
    )
    model = DecisionModel(
        template,
        c_sys5_uc;
        name = "UC",
        store_variable_names = true,
        optimizer = HiGHS_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end
