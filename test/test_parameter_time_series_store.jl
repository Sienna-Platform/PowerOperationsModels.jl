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

@testset "ParameterTimeSeriesStore: only document-declared series export rows" begin
    store = POM.ParameterTimeSeriesStore()
    ta = TimeSeries.TimeArray(
        range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24),
        collect(1.0:24.0),
    )
    key = POM.write_parameter_series!(
        store, 7, "ThermalStandard", "fuel_cost", ta; in_document = true,
    )
    POM.write_parameter_series!(store, 7, "ThermalStandard", "feedforward_bound", ta)

    @test IS.get_num_time_series(store.store) == 2
    rows = POM.parameter_association_rows(store)
    @test length(rows) == 1
    row = POM._unwrap_oneof(only(rows))
    @test row.name == "fuel_cost"
    @test row.owner_id == 7
    @test row.association_id == IS.get_association_id(key)
    # The property the whole design rests on: the uri names an array this store holds.
    @test occursin(r"^[0-9a-f]{64}$", row.uri)
    POM.close_parameter_store!(store)
end

@testset "ParameterTimeSeriesStore: document rows are identical after persist and reopen" begin
    store = POM.ParameterTimeSeriesStore()
    ta = TimeSeries.TimeArray(
        range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24),
        collect(1.0:24.0),
    )
    POM.write_parameter_series!(
        store, 7, "ThermalStandard", "fuel_cost", ta; in_document = true,
    )
    POM.write_parameter_series!(store, 7, "ThermalStandard", "feedforward_bound", ta)
    before = POM.parameter_association_rows(store)

    dir = mktempdir(; cleanup = true)
    path = joinpath(dir, "time_series.h5")
    POM.persist_parameter_store!(store, path)
    POM.close_parameter_store!(store)

    reopened = POM.open_parameter_store(path)
    # The reopened store holds every row, including the undeclared one ...
    @test IS.get_num_time_series(reopened.store) == 2
    # ... and the catalog's row for the declared series matches what was exported before,
    # field for field. This is what PowerSystems' import checks on load.
    all_rows = IS.openapi_time_series_association_rows(reopened.store)
    declared = POM._unwrap_oneof(only(before))
    matching = filter(
        r -> POM._unwrap_oneof(r).association_id == declared.association_id,
        all_rows,
    )
    @test length(matching) == 1
    after = POM._unwrap_oneof(only(matching))
    @test after.name == declared.name
    @test after.owner_id == declared.owner_id
    @test after.uri == declared.uri
    POM.close_parameter_store!(reopened)
end
