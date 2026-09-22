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

@testset "write_results_system_bundle!: the bundle loads with PSY.from_file" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    store = POM.ParameterTimeSeriesStore()
    gen = first(get_components(PSY.ThermalStandard, sys))
    ta = TimeSeries.TimeArray(
        range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24),
        collect(1.0:24.0),
    )
    POM.write_parameter_series!(
        store, IS.get_id(gen), "ThermalStandard", "fuel_cost", ta; in_document = true,
    )
    # A synthetic owner, not a component id: the sidecar's catalog is authoritative, so any
    # row under a real component's owner id would read back as that component's own series.
    # An undeclared parameter array must live under an owner no component ever has.
    POM.write_parameter_series!(store, -1, "OptimizationParameter", "undeclared", ta)
    @test IS.get_num_time_series(store.store) == 2

    dir = mktempdir(; cleanup = true)
    bundle = joinpath(dir, "system-test")
    POM.write_results_system_bundle!(sys, store, Dict{Int64, Int64}(), bundle)
    POM.close_parameter_store!(store)

    @test isfile(joinpath(bundle, PSY.SYSTEM_DOCUMENT_FILE))
    @test isfile(joinpath(bundle, PSY.TIME_SERIES_FILE))
    @test isfile(joinpath(bundle, PSY.TIME_SERIES_FILE * ".sqlite"))

    # The payoff: the ordinary loader, no bespoke reader. The sidecar's catalog holds a row
    # the document does not declare; PowerSystems' import tolerates that, and it stays out of
    # gen2's own view because it was never written under gen2's owner id.
    restored = PSY.from_file(bundle; time_series_read_only = true)
    gen2 = get_component(PSY.ThermalStandard, restored, PSY.get_name(gen))
    @test !isnothing(gen2)
    @test PSY.get_time_series_values(PSY.SingleTimeSeries, gen2, "fuel_cost") ==
          collect(1.0:24.0)
    @test !PSY.has_time_series(gen2, PSY.SingleTimeSeries, "undeclared")
end

@testset "write_results_system_bundle!: a time-series cost resolves in the restored System" begin
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5"))
    gen = first(get_components(PSY.ThermalStandard, sys))
    stamps = range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24)
    fuel = TimeSeries.TimeArray(stamps, collect(3.0:0.5:14.5))
    PSY.add_time_series!(sys, gen, PSY.SingleTimeSeries(; name = "fuel_cost", data = fuel))
    original_key = IS.get_time_series_key(
        only(
            IS.list_time_series_metadata(
                IS.get_data_store(sys.data); owner_id = IS.get_id(gen),
                name = "fuel_cost",
            ),
        ),
    )
    PSY.set_operation_cost!(
        gen,
        PSY.ThermalGenerationCost(
            PSY.FuelCurve(PSY.LinearCurve(1.0), original_key), 0.0, 0.0, 0.0,
        ),
    )

    # The parameter store holds the realized fuel cost; the cost key must be remapped to it.
    store = POM.ParameterTimeSeriesStore()
    new_key = POM.write_parameter_series!(
        store, IS.get_id(gen), "ThermalStandard", "fuel_cost", fuel; in_document = true,
    )
    key_map = Dict(IS.get_association_id(original_key) => IS.get_association_id(new_key))

    dir = mktempdir(; cleanup = true)
    bundle = joinpath(dir, "system-test")
    POM.write_results_system_bundle!(sys, store, key_map, bundle)
    POM.close_parameter_store!(store)

    restored = PSY.from_file(bundle; time_series_read_only = true)
    gen2 = get_component(PSY.ThermalStandard, restored, PSY.get_name(gen))
    # Design 3 got this far and failed here: the cost held a key for a series the System did
    # not have. It must now resolve to the parameter values.
    cost_ts = PSY.get_fuel_cost(gen2)
    @test TimeSeries.values(cost_ts) == collect(3.0:0.5:14.5)
end

@testset "parameter arrays round-trip under the synthetic owner" begin
    store = POM.ParameterTimeSeriesStore()
    key = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    labels = ["Solitude", "Park City"]
    stamps = collect(range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 4))
    array = JuMP.Containers.DenseAxisArray(
        [1.0 2.0 3.0 4.0; 10.0 20.0 30.0 40.0], labels, 1:4,
    )
    POM.write_parameter_array!(store, key, array, stamps)

    back = POM.read_parameter_array(store, key)
    @test Set(keys(back)) == Set(labels)
    @test TimeSeries.values(back["Solitude"]) == [1.0, 2.0, 3.0, 4.0]
    @test TimeSeries.timestamp(back["Park City"]) == stamps
    # Parameter rows are not document rows.
    @test isempty(POM.parameter_association_rows(store))
    # A different parameter with the same labels does not collide.
    other = IOM.ParameterKey(POM.FuelCostParameter, PSY.ThermalStandard)
    POM.write_parameter_array!(store, other, array .* 2, stamps)
    @test TimeSeries.values(POM.read_parameter_array(store, other)["Solitude"]) ==
          [2.0, 4.0, 6.0, 8.0]
    POM.close_parameter_store!(store)
end

@testset "copy_cost_time_series! copies exactly the keys the costs hold" begin
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5"))
    gen = first(get_components(PSY.ThermalStandard, sys))
    stamps = range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24)
    fuel = TimeSeries.TimeArray(stamps, collect(3.0:0.5:14.5))
    PSY.add_time_series!(sys, gen, PSY.SingleTimeSeries(; name = "fuel_cost", data = fuel))
    key = IS.get_time_series_key(
        only(
            IS.list_time_series_metadata(
                IS.get_data_store(sys.data); owner_id = IS.get_id(gen),
                name = "fuel_cost",
            ),
        ),
    )
    PSY.set_operation_cost!(
        gen,
        PSY.ThermalGenerationCost(PSY.FuelCurve(PSY.LinearCurve(1.0), key), 0.0, 0.0, 0.0),
    )

    store = POM.ParameterTimeSeriesStore()
    key_map = POM.copy_cost_time_series!(store, sys)
    @test length(key_map) == 1
    @test haskey(key_map, IS.get_association_id(key))
    @test IS.get_num_time_series(store.store) == 1      # the load profiles were NOT copied
    @test length(POM.parameter_association_rows(store)) == 1
    POM.close_parameter_store!(store)
end

@testset "parameter windows round-trip as forecasts" begin
    store = POM.ParameterTimeSeriesStore()
    key = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    labels = ["Solitude", "Park City"]
    t0 = Dates.DateTime(2024, 1, 1)
    windows = Dict(
        t0 =>
            JuMP.Containers.DenseAxisArray([1.0 2.0 3.0; 10.0 20.0 30.0], labels, 1:3),
        t0 + Dates.Hour(1) =>
            JuMP.Containers.DenseAxisArray([2.0 3.0 4.0; 20.0 30.0 40.0], labels, 1:3),
    )
    POM.write_parameter_windows!(store, key, windows, Dates.Hour(1), Dates.Hour(1))

    back = POM.read_parameter_windows(store, key)
    @test Set(keys(back)) == Set(labels)
    @test back["Solitude"][t0] == [1.0, 2.0, 3.0]
    @test back["Park City"][t0 + Dates.Hour(1)] == [20.0, 30.0, 40.0]
    @test isempty(POM.parameter_association_rows(store))
    # Distinct features keep two models' rows apart.
    POM.write_parameter_windows!(
        store, key, windows, Dates.Hour(1), Dates.Hour(1);
        extra_features = Dict{String, Any}("model" => "ED"),
    )
    @test length(POM.read_parameter_windows(store, key)) == 2
    @test length(
        POM.read_parameter_windows(
            store, key; extra_features = Dict{String, Any}("model" => "ED"),
        ),
    ) == 2
    POM.close_parameter_store!(store)
end

@testset "a persisted store reopens writable in place" begin
    store = POM.ParameterTimeSeriesStore()
    ta = TimeSeries.TimeArray(
        range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 4),
        collect(1.0:4.0),
    )
    POM.write_parameter_series!(
        store,
        7,
        "ThermalStandard",
        "fuel_cost",
        ta;
        in_document = true,
    )
    dir = mktempdir(; cleanup = true)
    path = joinpath(dir, "time_series.h5")
    POM.persist_parameter_store!(store, path)
    POM.close_parameter_store!(store)

    live = POM.open_parameter_store_writable(path)
    key = IOM.ParameterKey(POM.FuelCostParameter, PSY.ThermalStandard)
    POM.write_parameter_array!(
        live, key, JuMP.Containers.DenseAxisArray([5.0 6.0 7.0 8.0], ["Solitude"], 1:4),
        collect(range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 4)),
    )
    POM.close_parameter_store!(live)

    # The files on disk now hold both rows: no re-persist happened.
    again = POM.open_parameter_store(path)
    @test IS.get_num_time_series(again.store) == 2
    @test TimeSeries.values(POM.read_parameter_array(again, key)["Solitude"]) ==
          [5.0, 6.0, 7.0, 8.0]
    POM.close_parameter_store!(again)
end
