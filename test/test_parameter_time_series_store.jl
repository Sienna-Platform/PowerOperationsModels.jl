@testset "ParameterTimeSeriesStore: a written series reads back identically" begin
    store = POM.ParameterTimeSeriesStore()
    stamps = range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24)
    ta = TimeSeries.TimeArray(stamps, collect(1.0:24.0))
    key = POM.write_parameter_series!(store, 7, "ThermalStandard", "fuel_cost", ta)
    @test key isa IS.TimeSeriesKey

    back = POM.read_parameter_series(store, 7, "fuel_cost")
    @test TimeSeries.values(back) == collect(1.0:24.0)
    @test TimeSeries.timestamp(back) == collect(stamps)
    POM.close_parameter_store!(store)
end

@testset "ParameterTimeSeriesStore: the store round-trips through a file with its catalog" begin
    store = POM.ParameterTimeSeriesStore()
    ta = TimeSeries.TimeArray(
        range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24),
        collect(1.0:24.0),
    )
    POM.write_parameter_series!(store, 7, "ThermalStandard", "fuel_cost", ta)

    dir = mktempdir(; cleanup = true)
    path = joinpath(dir, "time_series.h5")
    POM.persist_parameter_store!(store, path)
    POM.close_parameter_store!(store)
    @test isfile(path)
    @test isfile(path * ".sqlite")

    reopened = POM.open_parameter_store(path)
    @test IS.get_num_time_series(reopened.store) == 1
    back = POM.read_parameter_series(reopened, 7, "fuel_cost")
    @test TimeSeries.values(back) == collect(1.0:24.0)
    POM.close_parameter_store!(reopened)
end
