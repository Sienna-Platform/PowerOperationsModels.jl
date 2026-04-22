"""Helper: build c_sys5 with SingleTimeSeries attached (required for EmulationModel)."""
function _build_emulation_system()
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    init_time = DateTime("2024-01-01")
    for load in get_components(PowerLoad, sys)
        tstamps = collect(range(init_time; length = 24, step = Hour(1)))
        data = TimeArray(tstamps, fill(get_active_power(load), 24))
        ts = SingleTimeSeries(; name = "max_active_power", data = data)
        add_time_series!(sys, load, ts)
    end
    return sys
end

@testset "EmulationModel Build" begin
    sys = _build_emulation_system()
    template = get_thermal_dispatch_template_network(CopperPlatePowerModel)
    model = EmulationModel(
        template,
        sys;
        optimizer = HiGHS_optimizer,
        resolution = Hour(1),
        initialize_model = false,
    )
    @test build!(model; executions = 1, output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test IOM.get_status(model) == IOM.ModelBuildStatus.BUILT
end
