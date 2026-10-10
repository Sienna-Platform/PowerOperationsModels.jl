@testset "parameter store: the store round-trips through a file with its catalog" begin
    store = IS.Store(; in_memory = true)
    key = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    stamps = collect(range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24))
    array = JuMP.Containers.DenseAxisArray(
        reshape(collect(1.0:24.0), 1, 24), ["Solitude"], 1:24,
    )
    POM.write_parameter_array!(store, key, array, first(stamps), Dates.Hour(1))

    dir = mktempdir(; cleanup = true)
    path = joinpath(dir, "time_series.h5")
    IS.serialize(store, path)
    IS.close!(store)
    @test isfile(path)
    @test isfile(path * ".sqlite")

    reopened = IS.open_infrastore_store(path)
    @test IS.get_num_time_series(reopened) == 1
    back = POM.read_parameter_array(reopened, key)
    @test TimeSeries.values(back["Solitude"]) == collect(1.0:24.0)
    IS.close!(reopened)
end

@testset "parameter store: only component-owned rows export as document rows" begin
    store = IS.Store(; in_memory = true)
    ta = TimeSeries.TimeArray(
        range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24),
        collect(1.0:24.0),
    )
    key = IS.add_time_series!(
        store, 7, "ThermalStandard",
        IS.get_owner_category(IS.InfrastructureSystemsComponent),
        PSY.SingleTimeSeries("fuel_cost", ta),
    )
    pkey = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    POM.write_parameter_array!(
        store, pkey,
        JuMP.Containers.DenseAxisArray(
            reshape(collect(1.0:24.0), 1, 24),
            ["Solitude"],
            1:24,
        ),
        Dates.DateTime(2024, 1, 1),
        Dates.Hour(1),
    )

    @test IS.get_num_time_series(store) == 2
    rows = POM.parameter_association_rows(store)
    @test length(rows) == 1
    row = only(rows).value
    @test row.name == "fuel_cost"
    @test row.owner_id == 7
    @test row.association_id == IS.get_association_id(key)
    # The property the whole design rests on: the uri names an array this store holds.
    @test occursin(r"^[0-9a-f]{64}$", row.uri)
    IS.close!(store)
end

@testset "parameter store: document rows are identical after persist and reopen" begin
    store = IS.Store(; in_memory = true)
    ta = TimeSeries.TimeArray(
        range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24),
        collect(1.0:24.0),
    )
    IS.add_time_series!(
        store, 7, "ThermalStandard",
        IS.get_owner_category(IS.InfrastructureSystemsComponent),
        PSY.SingleTimeSeries("fuel_cost", ta),
    )
    pkey = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    POM.write_parameter_array!(
        store, pkey,
        JuMP.Containers.DenseAxisArray(
            reshape(collect(1.0:24.0), 1, 24),
            ["Solitude"],
            1:24,
        ),
        Dates.DateTime(2024, 1, 1),
        Dates.Hour(1),
    )
    before = POM.parameter_association_rows(store)

    dir = mktempdir(; cleanup = true)
    path = joinpath(dir, "time_series.h5")
    IS.serialize(store, path)
    IS.close!(store)

    reopened = IS.open_infrastore_store(path)
    # The reopened store holds every row, including the undeclared one ...
    @test IS.get_num_time_series(reopened) == 2
    # ... and the catalog's row for the declared series matches what was exported before,
    # field for field. This is what PowerSystems' import checks on load.
    all_rows = IS.openapi_time_series_association_rows(reopened)
    declared = only(before).value
    matching = filter(r -> r.value.association_id == declared.association_id, all_rows)
    @test length(matching) == 1
    after = only(matching).value
    @test after.name == declared.name
    @test after.owner_id == declared.owner_id
    @test after.uri == declared.uri
    IS.close!(reopened)
end

@testset "write_outputs_system_bundle!: the bundle loads with PSY.from_file" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    store = IS.Store(; in_memory = true)
    gen = first(get_components(PSY.ThermalStandard, sys))
    ta = TimeSeries.TimeArray(
        range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 24),
        collect(1.0:24.0),
    )
    IS.add_time_series!(
        store, IS.get_id(gen), "ThermalStandard",
        IS.get_owner_category(IS.InfrastructureSystemsComponent),
        PSY.SingleTimeSeries("fuel_cost", ta),
    )
    # A synthetic owner, not a component id: the sidecar's catalog is authoritative, so any
    # row under a real component's owner id would read back as that component's own series.
    # An undeclared parameter array must live under an owner no component ever has.
    IS.add_time_series!(
        store, POM.PARAMETER_ROW_OWNER_ID, POM.PARAMETER_ROW_OWNER_TYPE,
        IS.get_owner_category(IS.InfrastructureSystemsComponent),
        PSY.SingleTimeSeries("undeclared", ta),
    )
    @test IS.get_num_time_series(store) == 2

    dir = mktempdir(; cleanup = true)
    bundle = joinpath(dir, "system-test")
    POM.write_outputs_system_bundle!(sys, store, Dict{Int64, Int64}(), bundle)
    IS.close!(store)

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

@testset "write_outputs_system_bundle!: a time-series cost resolves in the restored System" begin
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
    store = IS.Store(; in_memory = true)
    new_key = IS.add_time_series!(
        store, IS.get_id(gen), "ThermalStandard",
        IS.get_owner_category(IS.InfrastructureSystemsComponent),
        PSY.SingleTimeSeries("fuel_cost", fuel),
    )
    key_map = Dict(IS.get_association_id(original_key) => IS.get_association_id(new_key))

    dir = mktempdir(; cleanup = true)
    bundle = joinpath(dir, "system-test")
    POM.write_outputs_system_bundle!(sys, store, key_map, bundle)
    IS.close!(store)

    restored = PSY.from_file(bundle; time_series_read_only = true)
    gen2 = get_component(PSY.ThermalStandard, restored, PSY.get_name(gen))
    # Design 3 got this far and failed here: the cost held a key for a series the System did
    # not have. It must now resolve to the parameter values.
    cost_ts = PSY.get_fuel_cost(gen2)
    @test TimeSeries.values(cost_ts) == collect(3.0:0.5:14.5)
end

const _BUNDLE_T0 = Dates.DateTime(2024, 1, 1)

function _bundle_step_curves(scale::Float64)
    return [
        IS.PiecewiseStepData([0.0, 10.0, 20.0], [scale + h, 2.0 * scale + h]) for h in 1:24
    ]
end

function _bundle_forecast!(sys, component, name, values)
    key = PSY.add_time_series!(
        sys,
        component,
        PSY.Deterministic(;
            name = name, data = Dict(_BUNDLE_T0 => values), resolution = Dates.Hour(1),
        ),
    )
    return key
end

# Copies the costs of `sys` into a store, writes the bundle and restores it.
function _bundle_round_trip(sys)
    windows = POM.RunWindows(_BUNDLE_T0, 1, 24, Dates.Hour(1), Dates.Hour(24))
    store = IS.Store(; in_memory = true)
    key_map = POM.copy_cost_time_series!(store, sys, windows)
    bundle = joinpath(mktempdir(; cleanup = true), "system-test")
    POM.write_outputs_system_bundle!(sys, store, key_map, bundle)
    IS.close!(store)
    return key_map, PSY.from_file(bundle; time_series_read_only = true)
end

@testset "write_outputs_system_bundle!: a time-series GroupReserve demand curve is copied" begin
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5"))
    group = PSY.GroupReserve{PSY.ReserveUp}(;
        name = "UP_GROUP", available = true, requirement = 0.0,
        contributing_services = PSY.Service[],
    )
    PSY.add_service!(sys, group)
    expected = _bundle_step_curves(5.0)
    key = _bundle_forecast!(sys, group, "variable_cost", expected)
    PSY.set_variable!(group, PSY.make_market_bid_ts_curve(key, nothing, IS.NaturalUnit()))

    @test POM._cost_time_series_keys(group) == [key]
    key_map, restored = _bundle_round_trip(sys)
    @test haskey(key_map, IS.get_association_id(key))
    group2 = PSY.get_component(PSY.GroupReserve{PSY.ReserveUp}, restored, "UP_GROUP")
    key2 = IS.get_time_series_key(PSY.get_value_curve(PSY.get_variable(group2)))
    @test IS.get_data(PSY.get_time_series(group2, key2))[_BUNDLE_T0] == expected
end

@testset "write_outputs_system_bundle!: a time-series PointToPointBid spread bid resolves" begin
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5"))
    buses = collect(PSY.get_components(PSY.ACBus, sys))
    hub = PSY.TradingHub(; name = "hub", buses = buses[1:2])
    PSY.add_component!(sys, hub)
    ptp = PSY.PointToPointBid(;
        name = "ptp", available = true, from = buses[1], to = hub,
        max_active_power = 50.0,
        spread_bid = PSY.MarketBidCost(nothing),
        price_limits = (min = -50.0, max = 50.0),
    )
    PSY.add_component!(sys, ptp)
    expected = _bundle_step_curves(7.0)
    key = _bundle_forecast!(sys, ptp, "variable_cost incremental", expected)
    decr_key =
        _bundle_forecast!(sys, ptp, "variable_cost decremental", _bundle_step_curves(3.0))
    linear = [IS.LinearFunctionData(1.0 + h, 0.0) for h in 1:24]
    meo_key = _bundle_forecast!(sys, ptp, "minimum_energy_offer", linear)
    sd_key = _bundle_forecast!(sys, ptp, "shut_down", linear)
    su_key = _bundle_forecast!(sys, ptp, "start_up", fill((1.0, 2.0, 3.0), 24))
    PSY.set_spread_bid!(
        ptp,
        PSY.MarketBidTimeSeriesCost(;
            minimum_energy_offer = PSY.TimeSeriesLinearCurve(meo_key),
            start_up = su_key,
            shut_down = PSY.TimeSeriesLinearCurve(sd_key),
            incremental_offer_curves = PSY.make_market_bid_ts_curve(key),
            decremental_offer_curves = PSY.make_market_bid_ts_curve(decr_key),
        ),
    )

    key_map, restored = _bundle_round_trip(sys)
    @test haskey(key_map, IS.get_association_id(key))
    @test length(key_map) == 5
    ptp2 = PSY.get_component(PSY.PointToPointBid, restored, "ptp")
    key2 = IS.get_time_series_key(
        PSY.get_value_curve(PSY.get_incremental_offer_curves(PSY.get_spread_bid(ptp2))),
    )
    ts = PSY.get_time_series(ptp2, key2)
    @test IS.get_data(ts)[_BUNDLE_T0] == expected
end

@testset "write_outputs_system_bundle!: a time-series HydroReservoir head_to_volume_factor resolves" begin
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5"))
    reservoir = PSY.HydroReservoir(;
        name = "res", available = true, storage_level_limits = (min = 0.0, max = 100.0),
        initial_level = 0.5, spillage_limits = nothing, inflow = 1.0, outflow = 1.0,
        level_targets = 0.5, intake_elevation = 10.0,
        head_to_volume_factor = IS.LinearFunctionData(0.0),
    )
    PSY.add_component!(sys, reservoir)
    expected = [IS.LinearFunctionData(1.0 + h, 0.0) for h in 1:24]
    key = _bundle_forecast!(sys, reservoir, "head_to_volume", expected)
    PSY.set_head_to_volume_factor!(reservoir, IS.TimeSeriesLinearFunctionData(key))

    key_map, restored = _bundle_round_trip(sys)
    @test haskey(key_map, IS.get_association_id(key))
    reservoir2 = PSY.get_component(PSY.HydroReservoir, restored, "res")
    key2 = IS.get_time_series_key(PSY.get_head_to_volume_factor(reservoir2))
    ts = PSY.get_time_series(reservoir2, key2)
    @test IS.get_data(ts)[_BUNDLE_T0] == expected
end

@testset "parameter arrays round-trip under the synthetic owner" begin
    store = IS.Store(; in_memory = true)
    key = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    labels = ["Solitude", "Park City"]
    stamps = collect(range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 4))
    array = JuMP.Containers.DenseAxisArray(
        [1.0 2.0 3.0 4.0; 10.0 20.0 30.0 40.0], labels, 1:4,
    )
    POM.write_parameter_array!(store, key, array, first(stamps), Dates.Hour(1))

    back = POM.read_parameter_array(store, key)
    @test Set(keys(back)) == Set(labels)
    @test TimeSeries.values(back["Solitude"]) == [1.0, 2.0, 3.0, 4.0]
    @test TimeSeries.timestamp(back["Park City"]) == stamps
    # Parameter rows are not document rows.
    @test isempty(POM.parameter_association_rows(store))
    # A different parameter with the same labels does not collide.
    other = IOM.ParameterKey(POM.FuelCostParameter, PSY.ThermalStandard)
    POM.write_parameter_array!(store, other, array .* 2, first(stamps), Dates.Hour(1))
    @test TimeSeries.values(POM.read_parameter_array(store, other)["Solitude"]) ==
          [2.0, 4.0, 6.0, 8.0]
    IS.close!(store)
end

@testset "has_parameter_rows reports presence and honors extra_features" begin
    store = IS.Store(; in_memory = true)
    key = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    labels = ["Solitude", "Park City"]
    stamps = collect(range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 4))
    array = JuMP.Containers.DenseAxisArray(
        [1.0 2.0 3.0 4.0; 10.0 20.0 30.0 40.0], labels, 1:4,
    )
    @test !POM.has_parameter_rows(store, key)

    POM.write_parameter_array!(
        store, key, array, first(stamps), Dates.Hour(1);
        extra_features = Dict{String, Any}("model" => "UC"),
    )
    @test POM.has_parameter_rows(store, key; extra_features = Dict("model" => "UC"))
    @test !POM.has_parameter_rows(store, key; extra_features = Dict("model" => "ED"))
    IS.close!(store)
end

@testset "3-D parameter arrays round-trip with time as the last axis" begin
    store = IS.Store(; in_memory = true)
    key = IOM.ParameterKey(
        POM.IncrementalPiecewiseLinearBreakpointParameter, PSY.ThermalStandard,
    )
    array = JuMP.Containers.DenseAxisArray(
        rand(2, 3, 4), ["a", "b"], ["seg1", "seg2", "seg3"], 1:4,
    )
    stamps = collect(range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 4))
    POM.write_parameter_array!(store, key, array, first(stamps), Dates.Hour(1))

    back = POM.read_parameter_array(
        store, key; extra_features = Dict("axis2" => "seg2"),
    )
    @test TimeSeries.values(back["a"]) == array["a", "seg2", :]
    @test TimeSeries.timestamp(back["a"]) == stamps
    IS.close!(store)
end

@testset "parameter_slice_labels finds axis2 for a 3-D parameter, empty for a 2-D one" begin
    store = IS.Store(; in_memory = true)
    key = IOM.ParameterKey(
        POM.IncrementalPiecewiseLinearBreakpointParameter, PSY.ThermalStandard,
    )
    array = JuMP.Containers.DenseAxisArray(
        rand(2, 3, 4), ["a", "b"], ["seg1", "seg2", "seg3"], 1:4,
    )
    stamps = collect(range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 4))
    POM.write_parameter_array!(store, key, array, first(stamps), Dates.Hour(1))
    @test POM.parameter_slice_labels(store, key) == ["seg1", "seg2", "seg3"]
    @test POM.parameter_slice_labels(
        store, key; extra_features = Dict{String, Any}("model" => "UC"),
    ) == String[]

    other = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    array_2d = JuMP.Containers.DenseAxisArray(
        [1.0 2.0 3.0 4.0; 10.0 20.0 30.0 40.0], ["a", "b"], 1:4,
    )
    POM.write_parameter_array!(store, other, array_2d, first(stamps), Dates.Hour(1))
    @test isempty(POM.parameter_slice_labels(store, other))
    IS.close!(store)
end

@testset "write_parameter_array! errors on a single-point array (IS's own floor)" begin
    store = IS.Store(; in_memory = true)
    key = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    labels = ["Solitude", "Park City"]
    stamps = [Dates.DateTime(2024, 1, 1)]
    array = JuMP.Containers.DenseAxisArray(reshape([1.0, 10.0], 2, 1), labels, 1:1)
    @test_throws ArgumentError POM.write_parameter_array!(
        store, key, array, first(stamps), Dates.Hour(1),
    )
    IS.close!(store)
end

@testset "parameter_store_from_model warns and skips arrays on a 1-step horizon, but still copies costs" begin
    c_sys5 = deepcopy(PSB.build_system(PSITestSystems, "c_sys5_uc"))
    gen = first(get_components(PSY.ThermalStandard, c_sys5))
    init_time = Dates.DateTime(2024, 1, 1)
    fuel_forecast = PSY.Deterministic(;
        name = "fuel_cost",
        data = Dict(
            init_time => collect(3.0:0.5:14.5),
            init_time + Dates.Hour(24) => collect(4.0:0.5:15.5),
        ),
        resolution = Dates.Hour(1),
        interval = Dates.Hour(24),
    )
    PSY.add_time_series!(c_sys5, gen, fuel_forecast)
    original_key = IS.get_time_series_key(
        only(
            IS.list_time_series_metadata(
                IS.get_data_store(c_sys5.data); owner_id = IS.get_id(gen),
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

    template = get_thermal_standard_uc_template()
    model = DecisionModel(
        template, c_sys5;
        optimizer = HiGHS_optimizer, horizon = Dates.Hour(1), system_to_file = false,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    store, key_map =
        @test_logs (:warn, r"at least two points") POM.parameter_store_from_model(
            model,
        )
    # No parameter array rows were written (they live under the synthetic owner id).
    @test isempty(
        IS.list_time_series_metadata(store; owner_id = POM.PARAMETER_ROW_OWNER_ID),
    )
    # The cost is too short to re-window onto a 1-step run, so it is copied verbatim instead.
    @test IS.get_num_time_series(store) == 1
    @test length(key_map) == 1
    copied_md = only(
        IS.list_time_series_metadata(
            store;
            owner_id = IS.get_id(gen),
            name = "fuel_cost",
        ),
    )
    copied = IS.get_time_series(store, IS.get_time_series_key(copied_md))
    @test sort(collect(keys(IS.get_data(copied)))) ==
          [init_time, init_time + Dates.Hour(24)]
    IS.close!(store)
end

@testset "a 1-step-horizon model with a forecast-backed cost still writes its outputs bundle" begin
    # Exercises the real solve! -> parameter_store_from_model -> write_outputs_system_bundle!
    # path (default system_to_file = true), not a direct call: a dangling association id for
    # the verbatim-copied cost would make PSY.to_openapi's association_id_map remap throw here.
    c_sys5 = deepcopy(PSB.build_system(PSITestSystems, "c_sys5_uc"))
    gen = first(get_components(PSY.ThermalStandard, c_sys5))
    init_time = Dates.DateTime(2024, 1, 1)
    fuel_window_1 = collect(3.0:0.5:14.5)
    fuel_window_2 = collect(4.0:0.5:15.5)
    fuel_forecast = PSY.Deterministic(;
        name = "fuel_cost",
        data = Dict(
            init_time => fuel_window_1,
            init_time + Dates.Hour(24) => fuel_window_2,
        ),
        resolution = Dates.Hour(1),
        interval = Dates.Hour(24),
    )
    PSY.add_time_series!(c_sys5, gen, fuel_forecast)
    original_key = IS.get_time_series_key(
        only(
            IS.list_time_series_metadata(
                IS.get_data_store(c_sys5.data); owner_id = IS.get_id(gen),
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

    template = get_thermal_standard_uc_template()
    output_dir = mktempdir(; cleanup = true)
    model = DecisionModel(
        template, c_sys5;
        optimizer = HiGHS_optimizer, horizon = Dates.Hour(1),
    )
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    sys_dir = joinpath(output_dir, IOM.make_system_dirname(IOM.get_system(model)))
    @test isfile(joinpath(sys_dir, PSY.SYSTEM_DOCUMENT_FILE))

    restored = PSY.from_file(sys_dir; time_series_read_only = true)
    gen2 = get_component(PSY.ThermalStandard, restored, PSY.get_name(gen))
    @test TimeSeries.values(PSY.get_fuel_cost(gen2)) == fuel_window_1
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

    store = IS.Store(; in_memory = true)
    # c_sys5's own max_active_power forecasts: initial 2024-01-01, hourly, 24h windows, 24h
    # interval, 2 windows. The static fuel_cost cost key ignores the grid, so any grid this
    # fixture would itself produce is fine.
    windows =
        POM.RunWindows(Dates.DateTime(2024, 1, 1), 2, 24, Dates.Hour(1), Dates.Hour(24))
    key_map = POM.copy_cost_time_series!(store, sys, windows)
    @test length(key_map) == 1
    @test haskey(key_map, IS.get_association_id(key))
    @test IS.get_num_time_series(store) == 1      # the load profiles were NOT copied
    @test length(POM.parameter_association_rows(store)) == 1
    IS.close!(store)
end

@testset "copy_cost_time_series! re-windows a forecast cost onto the run grid" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    gen = first(get_components(PSY.ThermalStandard, sys))
    t0 = Dates.DateTime(2024, 1, 1)
    # 3 windows, 1-hour interval, 24 steps each; the run below uses every second window
    # and a 12-step horizon (Review Focus 4 and 5).
    data = Dict(t0 + Dates.Hour(k) => collect((1.0 + k):(24.0 + k)) for k in 0:2)
    PSY.add_time_series!(
        sys,
        gen,
        PSY.Deterministic(;
            name = "fuel_cost", data = data, resolution = Dates.Hour(1),
            interval = Dates.Hour(1),
        ),
    )
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
        PSY.ThermalGenerationCost(
            PSY.FuelCurve(PSY.LinearCurve(1.0), key), 0.0, 0.0, 0.0,
        ),
    )

    windows = POM.RunWindows(t0, 2, 12, Dates.Hour(1), Dates.Hour(2))
    @test windows.initial_times == [t0, t0 + Dates.Hour(2)]
    store = IS.Store(; in_memory = true)
    key_map = POM.copy_cost_time_series!(store, sys, windows)
    @test length(key_map) == 1
    copied_md = only(
        IS.list_time_series_metadata(
            store; owner_id = IS.get_id(gen), name = "fuel_cost",
        ),
    )
    copied = IS.get_time_series(store, IS.get_time_series_key(copied_md))
    copied_data = IS.get_data(copied)
    @test sort(collect(keys(copied_data))) == [t0, t0 + Dates.Hour(2)]
    @test copied_data[t0] == collect(1.0:12.0)
    @test copied_data[t0 + Dates.Hour(2)] == collect(3.0:14.0)
    @test IS.get_interval(copied) == Dates.Hour(2)
    IS.close!(store)
end

@testset "copy_cost_time_series! copies a static cost verbatim" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    gen = first(get_components(PSY.ThermalStandard, sys))
    t0 = Dates.DateTime(2024, 1, 1)
    PSY.add_time_series!(
        sys,
        gen,
        PSY.SingleTimeSeries(
            "fuel_cost",
            TimeSeries.TimeArray(
                range(t0; step = Dates.Hour(1), length = 48),
                collect(1.0:48.0),
            ),
        ),
    )
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
        PSY.ThermalGenerationCost(
            PSY.FuelCurve(PSY.LinearCurve(1.0), key), 0.0, 0.0, 0.0,
        ),
    )
    store = IS.Store(; in_memory = true)
    POM.copy_cost_time_series!(
        store,
        sys,
        POM.RunWindows(t0, 1, 24, Dates.Hour(1), Dates.Hour(24)),
    )
    copied_md = only(
        IS.list_time_series_metadata(
            store; owner_id = IS.get_id(gen), name = "fuel_cost",
        ),
    )
    copied_ts = IS.get_time_series(store, IS.get_time_series_key(copied_md))
    back = IS.make_time_array(copied_ts, IS.get_initial_timestamp(copied_ts))
    @test TimeSeries.values(back) == collect(1.0:48.0)
    IS.close!(store)
end

@testset "run_windows: one window at the model's initial time; horizon stands in for an unset interval" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5_uc")
    model = DecisionModel(
        get_thermal_standard_uc_template(),
        c_sys5;
        optimizer = HiGHS_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    windows = POM.run_windows(model)
    container = IOM.get_optimization_container(model)
    @test windows.initial_times == [IOM.get_initial_time(container)]
    @test windows.horizon_count == length(IOM.get_time_steps(container))
    @test windows.resolution == IOM.get_resolution(container)
    @test windows.interval == windows.resolution * windows.horizon_count
end

@testset "parameter windows round-trip as forecasts" begin
    store = IS.Store(; in_memory = true)
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
    IS.close!(store)
end

@testset "a persisted store reopens writable in place" begin
    store = IS.Store(; in_memory = true)
    key1 = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    POM.write_parameter_array!(
        store, key1, JuMP.Containers.DenseAxisArray([1.0 2.0 3.0 4.0], ["Solitude"], 1:4),
        Dates.DateTime(2024, 1, 1),
        Dates.Hour(1),
    )
    dir = mktempdir(; cleanup = true)
    path = joinpath(dir, "time_series.h5")
    IS.serialize(store, path)
    IS.close!(store)

    live = IS.open_infrastore_store(path)
    key2 = IOM.ParameterKey(POM.FuelCostParameter, PSY.ThermalStandard)
    POM.write_parameter_array!(
        live, key2, JuMP.Containers.DenseAxisArray([5.0 6.0 7.0 8.0], ["Solitude"], 1:4),
        Dates.DateTime(2024, 1, 1),
        Dates.Hour(1),
    )
    IS.close!(live)

    # The files on disk now hold both rows: no re-persist happened.
    again = IS.open_infrastore_store(path)
    @test IS.get_num_time_series(again) == 2
    @test TimeSeries.values(POM.read_parameter_array(again, key1)["Solitude"]) ==
          [1.0, 2.0, 3.0, 4.0]
    @test TimeSeries.values(POM.read_parameter_array(again, key2)["Solitude"]) ==
          [5.0, 6.0, 7.0, 8.0]
    IS.close!(again)
end

@testset "parameter_store_of reads a System's own already-open store, no second open" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    store = IS.Store(; in_memory = true)
    key = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.ThermalStandard)
    labels = ["Solitude", "Park City"]
    stamps = collect(range(Dates.DateTime(2024, 1, 1); step = Dates.Hour(1), length = 4))
    array = JuMP.Containers.DenseAxisArray(
        [1.0 2.0 3.0 4.0; 10.0 20.0 30.0 40.0], labels, 1:4,
    )
    POM.write_parameter_array!(store, key, array, first(stamps), Dates.Hour(1))

    dir = mktempdir(; cleanup = true)
    bundle = joinpath(dir, "system-test")
    POM.write_outputs_system_bundle!(sys, store, Dict{Int64, Int64}(), bundle)
    IS.close!(store)

    # `time_series_read_only = true` is exactly what an outputs reader's `get_system!` does;
    # this leaves that same handle open (never closed by this test) and reads the parameter
    # array straight through it via `parameter_store_of`, not a second, independent open.
    restored = PSY.from_file(bundle; time_series_read_only = true)
    borrowed = POM.parameter_store_of(restored)
    back = POM.read_parameter_array(borrowed, key)
    @test Set(keys(back)) == Set(labels)
    @test TimeSeries.values(back["Solitude"]) == [1.0, 2.0, 3.0, 4.0]
end

@testset "write_input_forecast_row!: a component-owned Deterministic with the marker feature; second write is a no-op" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    load = first(get_components(PSY.PowerLoad, sys))
    t0 = Dates.DateTime(2024, 1, 1)
    data = Dict(t0 => collect(0.1:0.1:2.4), t0 + Dates.Hour(24) => collect(0.2:0.1:2.5))
    store = IS.Store(; in_memory = true)
    POM.write_input_forecast_row!(
        store, IS.get_id(load), "PowerLoad", "max_active_power", data, Dates.Hour(1),
        Dates.Hour(24),
    )
    # Review Focus 2: the same (owner, name) again is skipped, not duplicated and not an error.
    POM.write_input_forecast_row!(
        store, IS.get_id(load), "PowerLoad", "max_active_power", data, Dates.Hour(1),
        Dates.Hour(24),
    )
    rows = IS.list_time_series_metadata(
        store;
        owner_id = IS.get_id(load),
        name = "max_active_power",
    )
    @test length(rows) == 1
    @test IS.get_features(only(rows))["source"] == "parameter"
    document_association_ids =
        Set(row.value.association_id for row in POM.parameter_association_rows(store))
    @test IS.get_association_id(IS.get_time_series_key(only(rows))) in
          document_association_ids
    IS.close!(store)
end

@testset "input_series_descriptor resolves labels to owners and warns once for the rest" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5_uc")
    model = DecisionModel(
        get_thermal_standard_uc_template(),
        c_sys5;
        optimizer = HiGHS_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    key = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.PowerLoad)
    pc = IOM.get_parameters(container)[key]
    @test POM.is_input_parameter(pc)
    d = POM.input_series_descriptor(c_sys5, key, pc)
    @test d.name == "max_active_power"
    @test d.time_series_type <: PSY.Deterministic
    @test Set(keys(d.owners)) == Set(PSY.get_name.(get_components(PSY.PowerLoad, c_sys5)))
    # Review Focus 3: a label that is not a component is reported, not fatal.
    IOM.add_component_name!(IOM.get_attributes(pc), "bogus", "deadbeef")
    d2 = @test_logs (:warn, r"bogus") POM.input_series_descriptor(c_sys5, key, pc)
    @test !haskey(d2.owners, "bogus")
    cost_key = IOM.ParameterKey(POM.FuelCostParameter, PSY.ThermalStandard)
    if haskey(IOM.get_parameters(container), cost_key)
        @test !POM.is_input_parameter(IOM.get_parameters(container)[cost_key])
    end
end

@testset "write_model_inputs!: the restored load carries the raw parameter values as its own forecast" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5_uc")
    model = DecisionModel(
        get_thermal_standard_uc_template(),
        c_sys5;
        optimizer = HiGHS_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    windows = POM.run_windows(model)
    store = IS.Store(; in_memory = true)
    key_map = POM.copy_cost_time_series!(store, c_sys5, windows)
    POM.write_model_inputs!(store, c_sys5, container, windows)

    bundle = joinpath(mktempdir(; cleanup = true), "system-test")
    POM.write_outputs_system_bundle!(c_sys5, store, key_map, bundle)
    IS.close!(store)

    restored = PSY.from_file(bundle; time_series_read_only = true)
    load = first(get_components(PSY.PowerLoad, c_sys5))
    load2 = get_component(PSY.PowerLoad, restored, PSY.get_name(load))
    @test PSY.has_time_series(load2)
    key = IOM.ParameterKey(POM.ActivePowerTimeSeriesParameter, PSY.PowerLoad)
    raw = IOM.get_parameter_values(IOM.get_parameters(container)[key])
    got = PSY.get_time_series_values(PSY.Deterministic, load2, "max_active_power")
    @test got == collect(vec(raw[PSY.get_name(load), :]))
    # The raw values are the System's own scaling factors: not multiplied, not sign-flipped.
    @test got == PSY.get_time_series_values(
        PSY.Deterministic, load, "max_active_power";
        start_time = first(windows.initial_times),
    )
    IS.close!(IS.get_data_store(restored.data))
end

@testset "list_input_series returns only marker rows" begin
    store = IS.Store(; in_memory = true)
    t0 = Dates.DateTime(2024, 1, 1)
    POM.write_input_forecast_row!(
        store, 7, "PowerLoad", "max_active_power",
        Dict(t0 => collect(1.0:24.0), t0 + Dates.Hour(24) => collect(2.0:25.0)),
        Dates.Hour(1), Dates.Hour(24),
    )
    # A non-marker row (no INPUT_ROW_FEATURES) must not count as an input series.
    pkey = IOM.ParameterKey(POM.FuelCostParameter, PSY.ThermalStandard)
    POM.write_parameter_array!(
        store, pkey,
        JuMP.Containers.DenseAxisArray(
            reshape(collect(1.0:24.0), 1, 24),
            ["Solitude"],
            1:24,
        ),
        t0,
        Dates.Hour(1),
    )
    rows = POM.list_input_series(store)
    @test length(rows) == 1
    @test IS.get_name(only(rows)) == "max_active_power"
    @test IS.get_owner_id(only(rows)) == 7
    ts = POM.read_input_time_series(store, only(rows))
    @test IS.get_data(ts)[t0] == collect(1.0:24.0)
    IS.close!(store)
end

@testset "a Deterministic and a SingleTimeSeries input row coexist for the same (owner, name)" begin
    store = IS.Store(; in_memory = true)
    t0 = Dates.DateTime(2024, 1, 1)
    POM.write_input_forecast_row!(
        store, 7, "PowerLoad", "max_active_power",
        Dict(t0 => collect(1.0:24.0)), Dates.Hour(1), Dates.Hour(24),
    )
    POM.write_input_series_row!(
        store, 7, "PowerLoad", "max_active_power", collect(1.0:48.0), t0, Dates.Hour(1),
    )
    rows = POM.list_input_series(store)
    @test length(rows) == 2
    # A second write of the same type is a no-op (write-once within a type).
    POM.write_input_forecast_row!(
        store, 7, "PowerLoad", "max_active_power",
        Dict(t0 => collect(2.0:25.0)), Dates.Hour(1), Dates.Hour(24),
    )
    POM.write_input_series_row!(
        store, 7, "PowerLoad", "max_active_power", collect(2.0:49.0), t0, Dates.Hour(1),
    )
    @test length(POM.list_input_series(store)) == 2
    forecast_ts = POM.read_input_time_series(
        store,
        only(filter(md -> IS.get_time_series_type(md) <: PSY.Deterministic, rows)),
    )
    @test IS.get_data(forecast_ts)[t0] == collect(1.0:24.0)
    series_ts = POM.read_input_time_series(
        store,
        only(filter(md -> IS.get_time_series_type(md) <: PSY.SingleTimeSeries, rows)),
    )
    @test TimeSeries.values(IS.get_data(series_ts)) == collect(1.0:48.0)
    IS.close!(store)
end

@testset "3-D parameter windows round-trip as one forecast per axis-2 label" begin
    store = IS.Store(; in_memory = true)
    key = IOM.ParameterKey(
        POM.IncrementalPiecewiseLinearBreakpointParameter, PSY.ThermalStandard,
    )
    t0 = Dates.DateTime(2024, 1, 1)
    windows = Dict(
        t0 + Dates.Hour(k) => JuMP.Containers.DenseAxisArray(
            rand(2, 3, 4), ["a", "b"], ["seg1", "seg2", "seg3"], 1:4,
        ) for k in 0:1
    )
    POM.write_parameter_windows!(store, key, windows, Dates.Hour(1), Dates.Hour(1))
    @test POM.parameter_slice_labels(store, key) == ["seg1", "seg2", "seg3"]
    back = POM.read_parameter_windows(
        store, key; extra_features = Dict{String, Any}("axis2" => "seg2"),
    )
    @test back["b"][t0 + Dates.Hour(1)] == windows[t0 + Dates.Hour(1)]["b", "seg2", :]
    IS.close!(store)
end
