function _hybrid_with_probe_series(labels)
    sys = PSB.build_system(PSB.PSITestSystems, "test_RTS_GMLC_sys")
    hybrid = add_hybrid_to_chuhsi_bus!(sys)
    initial_time = only(PSY.get_forecast_initial_times(sys))
    stamps = collect(range(initial_time; step = Hour(1), length = 24))
    PSY.add_time_series!(
        sys,
        hybrid,
        PSY.SingleTimeSeries("label_probe", TimeArray(stamps, ones(24)); labels...),
    )
    md = IS.get_time_series_metadata(PSY.SingleTimeSeries, hybrid, "label_probe")
    return sys, hybrid, md
end

const _HYBRID_SUBCOMPONENT_PARAMETERS = (
    POM.HybridRenewableActivePowerTimeSeriesParameter,
    POM.HybridElectricLoadTimeSeriesParameter,
)

@testset "Hybrid subcomponent series in component base raise an error" begin
    _, hybrid, md = _hybrid_with_probe_series(PSB.component_base("active_power"))
    for P in _HYBRID_SUBCOMPONENT_PARAMETERS,
        F in (POM.HybridDispatchWithReserves, POM.FixedOutput)

        @test_throws ErrorException POM.get_multiplier_value(P, hybrid, F, md)
    end
end

@testset "Hybrid subcomponent series in MW convert to system base" begin
    sys, hybrid, md = _hybrid_with_probe_series(PSB.natural_units("active_power", "MW"))
    expected = 1.0 / PSY.get_base_power(sys)
    for P in _HYBRID_SUBCOMPONENT_PARAMETERS,
        F in (POM.HybridDispatchWithReserves, POM.FixedOutput)

        @test POM.get_multiplier_value(P, hybrid, F, md) ≈ expected
    end
end
