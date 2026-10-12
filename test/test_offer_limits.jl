# Opt-in device-model attributes over offer data that spans services: linked reserve offer
# blocks are sold once ("linked_reserve_offers"), and energy plus upward reserve awards stay
# within the top of the energy offer curve ("energy_offer_cap").

const _OL_INIT_TIMES = [DateTime("2024-01-01T00:00:00"), DateTime("2024-01-02T00:00:00")]
const _OL_UNIT = "Brighton"  # c_sys5_uc: 300 to 600 MW

_ol_curve(x, y) = make_market_bid_curve(x, y, 0.0; power_units = IS.NaturalUnit())

_ol_offer_ts(name, x, y) = Deterministic(
    name,
    Dict(it => [IS.PiecewiseStepData(x, y) for _ in 1:24] for it in _OL_INIT_TIMES),
    Hour(1),
)

# c_sys5_uc where `_OL_UNIT` offers energy at 1 $/MWh up to `energy_top` MW (its pmax when
# `nothing`) and alone supplies each service: `up`/`down` map a name to (breakpoints MW,
# prices). Every service values 100 MW at 1000 $/MW; `offline` adds one offline service.
function _ol_system(; up = [], down = [], energy_top = nothing, offline = false)
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5_uc"))
    g = get_component(ThermalStandard, sys, _OL_UNIT)
    top = something(energy_top, PSY.get_max_active_power(g, u"NU"))
    set_operation_cost!(
        g,
        MarketBidCost(;
            minimum_energy_offer = LinearCurve(0.0),
            start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
            shut_down = LinearCurve(0.0),
            incremental_offer_curves = _ol_curve([0.0, top], [1.0]),
        ),
    )
    demand = _ol_curve([0.0, 100.0], [1000.0])
    services = vcat(
        [(OnlineReserve{ReserveUp}, name, x, y) for (name, (x, y)) in up],
        [(OnlineReserve{ReserveDown}, name, x, y) for (name, (x, y)) in down],
    )
    for (S, name, x, y) in services
        service = S(;
            name = name, available = true, time_frame = 10.0, requirement = 0.0,
            variable = demand,
        )
        add_service!(sys, service, PSY.Device[g])
        PSY.set_service_bid!(sys, g, service, _ol_offer_ts(name, x, y), IS.NaturalUnit())
    end
    if offline
        service = OfflineReserve(;
            name = "OFF_UP", available = true, time_frame = 30.0, variable = demand,
        )
        add_service!(sys, service, PSY.Device[g])
        PSY.set_service_bid!(
            sys, g, service, _ol_offer_ts("OFF_UP", [0.0, 50.0], [1.0]), IS.NaturalUnit(),
        )
    end
    return sys, g
end

const _OL_SERVICE_TYPES =
    (OnlineReserve{ReserveUp}, OnlineReserve{ReserveDown}, OfflineReserve)

function _ol_template(
    attributes;
    sys,
    formulation = ThermalBasicUnitCommitment,
    duals = DataType[],
    service_types = _OL_SERVICE_TYPES,
)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(
        template, DeviceModel(ThermalStandard, formulation; attributes, duals),
    )
    for S in service_types
        isempty(get_components(S, sys)) && continue
        set_service_model!(template, ServiceModel(S, StepwiseCostReserve))
    end
    return template
end

function _ol_model(sys; attributes = Dict{String, Any}(), kwargs...)
    template = _ol_template(attributes; sys, kwargs...)
    model = DecisionModel(
        template, sys; optimizer = HiGHS_optimizer, store_variable_names = true,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

# Commit `_OL_UNIT` in every step and solve: the rows under test bind only while it runs.
function _ol_solve!(model)
    container = get_optimization_container(model)
    on = IOM.get_variable(container, OnVariable, ThermalStandard)
    for t in axes(on)[2]
        JuMP.fix(on[_OL_UNIT, t], 1.0; force = true)
    end
    return solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

# A `reserve_offer_links` series for `g`, the same in every step: `rows[b]` holds block b's
# step in each service of `products` (0: not in it).
function _ol_add_links!(
    sys, g, products, rows;
    resolution = Hour(1), steps = 24, axis_names = ("block", "product"),
)
    window = permutedims(hcat(rows...))
    data = Dict(
        it => repeat(reshape(window, 1, size(window)...), steps) for it in _OL_INIT_TIMES
    )
    ts = Deterministic(;
        name = POM.RESERVE_OFFER_LINKS_TS_NAME,
        data = data,
        resolution = resolution,
        value_axes = [
            IS.TimeSeriesAxis(axis_names[1], collect(1:length(rows))),
            IS.TimeSeriesAxis(axis_names[2], products),
        ],
    )
    PSY.add_time_series!(sys, g, ts)
    return
end

_ol_blk(c) = IOM.get_variable(c, POM.PiecewiseLinearBlockReserveOffer, ThermalStandard)
_ol_award(c, S = OnlineReserve{ReserveUp}) =
    IOM.get_variable(
        c,
        ActivePowerReserveVariable,
        IOM.ComponentPairKey{ThermalStandard, S},
    )
_ol_keys(container) = sort!(IOM.encode_key.(IOM.get_constraint_keys(container)))
_ol_rows(c, T) = sort!(collect(keys(IOM.get_constraint(c, T, ThermalStandard).data)))

const _OL_TWO_SERVICES =
    ["UP_A" => ([0.0, 10.0, 30.0], [5.0, 7.0]), "UP_B" => ([0.0, 10.0], [6.0])]

@testset "Offer limits are off by default: model unchanged, links ignored with a warning" begin
    plain_sys, _ = _ol_system(; up = _OL_TWO_SERVICES)
    plain = _ol_model(plain_sys)
    sys, g = _ol_system(; up = _OL_TWO_SERVICES)
    _ol_add_links!(sys, g, ["UP_A", "UP_B"], [[1, 1], [2, 0]])
    model = _ol_model(sys; attributes = Dict{String, Any}("energy_offer_cap" => false))
    # `build!` logs through its own logger, so the warning is read from the problem log.
    log_of(m) = read(joinpath(IOM.get_output_dir(m), IOM.PROBLEM_LOG_FILENAME), String)
    @test occursin(r"carry reserve_offer_links series .* ignored", log_of(model))
    @test !occursin("reserve_offer_links", log_of(plain))
    c0 = get_optimization_container(plain)
    c1 = get_optimization_container(model)
    jm0, jm1 = IOM.get_jump_model(c0), IOM.get_jump_model(c1)
    @test _ol_keys(c1) == _ol_keys(c0)
    @test JuMP.num_constraints(jm1; count_variable_in_set_constraints = true) ==
          JuMP.num_constraints(jm0; count_variable_in_set_constraints = true)
    @test string(JuMP.objective_function(jm1)) == string(JuMP.objective_function(jm0))
    # Unlinked, block 1 clears in both services: 10 + 20 MW of UP_A and 10 MW of UP_B.
    @test _ol_solve!(model)
    award = _ol_award(c1)
    base = IOM.get_model_base_power(c1)
    for t in 1:24
        total =
            JuMP.value(award[("UP_A", _OL_UNIT, t)]) +
            JuMP.value(award[("UP_B", _OL_UNIT, t)])
        @test isapprox(base * total, 40.0; atol = 1e-6)
    end
end

@testset "Offer limits need rebuild_model = true" begin
    sys, _ = _ol_system(; up = _OL_TWO_SERVICES)
    container = get_optimization_container(_ol_model(sys))
    @test POM._require_rebuild_model(container, POM.LINKED_RESERVE_OFFERS_KEY) === nothing
    container.built_for_recurrent_solves = true
    @test_throws ErrorException POM._require_rebuild_model(
        container, POM.LINKED_RESERVE_OFFERS_KEY,
    )
end

const _OL_LINKED = Dict{String, Any}("linked_reserve_offers" => true)

@testset "Linked reserve offers: a block linked into two services is sold once" begin
    sys, g = _ol_system(; up = _OL_TWO_SERVICES)
    # Block 1 (10 MW) is step 1 of both curves, block 2 (20 MW) step 2 of UP_A only, block 3
    # pads. Products run in the reverse of the order the offers were attached.
    _ol_add_links!(sys, g, ["UP_B", "UP_A"], [[1, 1], [0, 2], [0, 0]])
    model = _ol_model(sys; attributes = _OL_LINKED)
    c = get_optimization_container(model)
    rows = IOM.get_constraint(c, POM.LinkedReserveOfferConstraint, ThermalStandard)
    blk = _ol_blk(c)
    base = IOM.get_model_base_power(c)
    @test _ol_rows(c, POM.LinkedReserveOfferConstraint) == [(_OL_UNIT, 1, t) for t in 1:24]
    for t in 1:24
        row = rows[(_OL_UNIT, 1, t)]
        @test JuMP.normalized_coefficient(row, blk[("UP_A", _OL_UNIT, 1, t)]) == 1.0
        @test JuMP.normalized_coefficient(row, blk[("UP_B", _OL_UNIT, 1, t)]) == 1.0
        @test JuMP.normalized_coefficient(row, blk[("UP_A", _OL_UNIT, 2, t)]) == 0.0
        @test JuMP.normalized_rhs(row) ≈ 10.0 / base
    end
    @test _ol_solve!(model)
    award = _ol_award(c)
    for t in 1:24
        a = JuMP.value(award[("UP_A", _OL_UNIT, t)])
        b = JuMP.value(award[("UP_B", _OL_UNIT, t)])
        @test isapprox(base * (a + b), 30.0; atol = 1e-6)
        linked =
            JuMP.value(blk[("UP_A", _OL_UNIT, 1, t)]) +
            JuMP.value(blk[("UP_B", _OL_UNIT, 1, t)])
        @test isapprox(base * linked, 10.0; atol = 1e-6)
    end
end

@testset "Linked reserve offers: linked steps of different widths take the smallest" begin
    sys, g = _ol_system(;
        up = ["UP_A" => ([0.0, 10.0], [5.0]), "UP_B" => ([0.0, 8.0], [6.0])],
    )
    _ol_add_links!(sys, g, ["UP_A", "UP_B"], [[1, 1]])
    c = get_optimization_container(_ol_model(sys; attributes = _OL_LINKED))
    rows = IOM.get_constraint(c, POM.LinkedReserveOfferConstraint, ThermalStandard)
    base = IOM.get_model_base_power(c)
    @test all(JuMP.normalized_rhs(rows[(_OL_UNIT, 1, t)]) ≈ 8.0 / base for t in 1:24)
end

@testset "Linked reserve offers: a service the model does not price is skipped" begin
    sys, g = _ol_system(;
        up = ["UP_A" => ([0.0, 10.0], [5.0])], down = ["DN_A" => ([0.0, 10.0], [6.0])],
    )
    _ol_add_links!(sys, g, ["UP_A", "DN_A"], [[1, 1]])
    c = get_optimization_container(
        _ol_model(
            sys; attributes = _OL_LINKED, service_types = (OnlineReserve{ReserveUp},),
        ),
    )
    @test isempty(_ol_rows(c, POM.LinkedReserveOfferConstraint))
end

@testset "Linked reserve offers: bad links are errors" begin
    sys, g = _ol_system(; up = _OL_TWO_SERVICES)
    model = _ol_model(sys)  # no links yet: a container for the validator
    c = get_optimization_container(model)
    _ol_add_links!(sys, g, ["UP_A", "UP_B"], [[1, 1]]; axis_names = ("blocks", "product"))
    @test_throws ArgumentError POM._links_value_axes(c, g)
    sys2, g2 = _ol_system(; up = _OL_TWO_SERVICES)
    _ol_add_links!(sys2, g2, ["UP_A", "UP_B"], [[1, 1]]; resolution = Minute(30))
    @test_throws IS.ConflictingInputsError POM._links_value_axes(c, g2)

    # Product not offered and a step past the curve fail the build with the message logged.
    for (products, rows, message) in (
        (["UP_A", "UP_X"], [[1, 1]], "not among its ancillary_service_offers"),
        (["UP_A", "UP_B"], [[3, 1]], "links to step 3"),
    )
        sys3, g3 = _ol_system(; up = _OL_TWO_SERVICES)
        _ol_add_links!(sys3, g3, products, rows)
        dir = mktempdir(; cleanup = true)
        model3 = DecisionModel(
            _ol_template(_OL_LINKED; sys = sys3), sys3; optimizer = HiGHS_optimizer,
        )
        @test build!(model3; output_dir = dir, console_level = Logging.AboveMaxLevel) ==
              IOM.ModelBuildStatus.FAILED
        @test occursin(message, read(joinpath(dir, IOM.PROBLEM_LOG_FILENAME), String))
    end
end

const _OL_CAP = Dict{String, Any}("energy_offer_cap" => true)
const _OL_ONE_SERVICE = ["UP_A" => ([0.0, 100.0], [5.0])]

_ol_energy(c, t) =
    JuMP.value(IOM.get_variable(c, ActivePowerVariable, ThermalStandard)[_OL_UNIT, t]) +
    JuMP.value(_ol_award(c)[("UP_A", _OL_UNIT, t)])

@testset "Energy offer cap: energy plus up awards stop at a curve top below pmax" begin
    sys, _ = _ol_system(; up = _OL_ONE_SERVICE, energy_top = 400.0)
    model = _ol_model(sys; attributes = _OL_CAP)
    c = get_optimization_container(model)
    base = IOM.get_model_base_power(c)
    @test _ol_rows(c, POM.EnergyOfferCapConstraint) == [(_OL_UNIT, t) for t in 1:24]
    row =
        IOM.get_constraint(c, POM.EnergyOfferCapConstraint, ThermalStandard)[(_OL_UNIT, 1)]
    p = IOM.get_variable(c, ActivePowerVariable, ThermalStandard)
    @test JuMP.normalized_coefficient(row, p[_OL_UNIT, 1]) == 1.0
    @test JuMP.normalized_coefficient(row, _ol_award(c)[("UP_A", _OL_UNIT, 1)]) == 1.0
    @test JuMP.normalized_rhs(row) ≈ 400.0 / base
    @test _ol_solve!(model)
    @test all(isapprox(base * _ol_energy(c, t), 400.0; atol = 1e-6) for t in 1:24)
    # Without the cap the unit sells its 100 MW of reserve on top of cheap energy.
    free = _ol_model(sys)
    @test _ol_solve!(free)
    @test any(
        base * _ol_energy(get_optimization_container(free), t) > 400.0 + 1e-3 for
        t in 1:24
    )
end

@testset "Energy offer cap: no row when the curve tops at pmax" begin
    sys, _ = _ol_system(; up = _OL_ONE_SERVICE)
    c = get_optimization_container(_ol_model(sys; attributes = _OL_CAP))
    @test isempty(_ol_rows(c, POM.EnergyOfferCapConstraint))
end

@testset "Energy offer cap: no row in a step whose curve offers no energy" begin
    sys, g = _ol_system(; up = _OL_ONE_SERVICE, energy_top = 400.0)
    curves = [IS.PiecewiseStepData([0.0, 400.0], [1.0]) for _ in 1:24]
    curves[1] = IS.PiecewiseStepData([0.0, 0.0], [1.0])
    key, initial_key = map(
        ((name, v),) -> PSY.add_time_series!(
            sys, g,
            Deterministic(name, Dict(it => v for it in _OL_INIT_TIMES), Hour(1)),
        ),
        (("incremental_offer_curves", curves), ("initial_input", zeros(24))),
    )
    set_operation_cost!(
        g,
        to_market_bid_ts_cost(
            sys, g, get_operation_cost(g);
            new_incremental_offer_curves = make_market_bid_ts_curve(
                key, initial_key, IS.NaturalUnit(),
            ),
        ),
    )
    c = get_optimization_container(_ol_model(sys; attributes = _OL_CAP))
    rows = IOM.get_constraint(c, POM.EnergyOfferCapConstraint, ThermalStandard)
    @test _ol_rows(c, POM.EnergyOfferCapConstraint) == [(_OL_UNIT, t) for t in 2:24]
    @test JuMP.normalized_rhs(rows[(_OL_UNIT, 2)]) ≈
          400.0 / IOM.get_model_base_power(c)
end

@testset "Energy offer cap: compact UC adds pmin times the commitment" begin
    sys, g = _ol_system(; up = _OL_ONE_SERVICE, energy_top = 400.0)
    model = _ol_model(
        sys; formulation = ThermalBasicCompactUnitCommitment, attributes = _OL_CAP,
    )
    c = get_optimization_container(model)
    base = IOM.get_model_base_power(c)
    row =
        IOM.get_constraint(c, POM.EnergyOfferCapConstraint, ThermalStandard)[(_OL_UNIT, 1)]
    above = IOM.get_variable(c, PowerAboveMinimumVariable, ThermalStandard)
    on = IOM.get_variable(c, OnVariable, ThermalStandard)
    pmin = PSY.get_active_power_limits(g, u"SU").min
    @test JuMP.normalized_coefficient(row, above[_OL_UNIT, 1]) == 1.0
    @test JuMP.normalized_coefficient(row, on[_OL_UNIT, 1]) ≈ pmin
    @test JuMP.normalized_rhs(row) ≈ 400.0 / base
    @test _ol_solve!(model)
    award = _ol_award(c)
    for t in 1:24
        energy =
            JuMP.value(above[_OL_UNIT, t]) + pmin +
            JuMP.value(award[("UP_A", _OL_UNIT, t)])
        @test isapprox(base * energy, 400.0; atol = 1e-6)
    end
end

@testset "Energy offer cap: offline and down awards stay out" begin
    sys, _ = _ol_system(;
        up = _OL_ONE_SERVICE, down = ["DN_A" => ([0.0, 50.0], [1.0])],
        energy_top = 400.0, offline = true,
    )
    c = get_optimization_container(_ol_model(sys; attributes = _OL_CAP))
    row =
        IOM.get_constraint(c, POM.EnergyOfferCapConstraint, ThermalStandard)[(_OL_UNIT, 1)]
    @test JuMP.normalized_coefficient(row, _ol_award(c)[("UP_A", _OL_UNIT, 1)]) == 1.0
    off = _ol_award(c, OfflineReserve)
    down = _ol_award(c, OnlineReserve{ReserveDown})
    @test JuMP.normalized_coefficient(row, off[("OFF_UP", _OL_UNIT, 1)]) == 0.0
    @test JuMP.normalized_coefficient(row, down[("DN_A", _OL_UNIT, 1)]) == 0.0
end

@testset "Energy offer cap: only thermal formulations take it" begin
    sys, _ = _ol_system(; up = _OL_ONE_SERVICE, energy_top = 400.0)
    c = get_optimization_container(_ol_model(sys))
    loads = DeviceModel(PowerLoad, StaticPowerLoad; attributes = _OL_CAP)
    @test_throws ArgumentError POM.add_energy_offer_cap_constraints!(c, sys, loads)
end

@testset "Offer limits: duals listed on the device model cover every row" begin
    sys, g = _ol_system(; up = _OL_TWO_SERVICES, energy_top = 400.0)
    _ol_add_links!(sys, g, ["UP_A", "UP_B"], [[1, 1], [2, 0]])
    types = [POM.LinkedReserveOfferConstraint, POM.EnergyOfferCapConstraint]
    model = _ol_model(sys; attributes = merge(_OL_LINKED, _OL_CAP), duals = types)
    c = get_optimization_container(model)
    for T in types
        dual = IOM.get_duals(c)[IOM.ConstraintKey(T, ThermalStandard)]
        @test !isempty(dual.data)
        @test sort!(collect(keys(dual.data))) == _ol_rows(c, T)
    end
    @test _ol_solve!(model)
    res = IOM.OptimizationProblemOutputs(model)
    names = IOM.list_dual_names(res)
    @test any(occursin("LinkedReserveOfferConstraint", n) for n in names)
    @test any(occursin("EnergyOfferCapConstraint", n) for n in names)
end

@testset "Links reach the model through ReserveOfferLinkParameter" begin
    sys, g = _ol_system(; up = _OL_TWO_SERVICES)
    _ol_add_links!(sys, g, ["UP_A", "UP_B"], [[1, 1], [2, 0]])
    model = _ol_model(sys; attributes = _OL_LINKED)
    c = get_optimization_container(model)
    key = IOM.ParameterKey(POM.ReserveOfferLinkParameter, ThermalStandard)
    links = IOM.get_lhs_parameter_values(c, key, _OL_UNIT, POM._links_value_axes(c, g))
    @test size(links) == (2, 2, 24)
    @test links[:, :, 1] == [1.0 1.0; 2.0 0.0]
    @test _ol_rows(c, POM.LinkedReserveOfferConstraint) == [(_OL_UNIT, 1, t) for t in 1:24]
end

@testset "Links keep multiplier 1.0" begin
    # One formulation per family method that scales time-series parameters by capacity.
    for (sys_name, D, F) in (
        ("c_sys5_re", PSY.RenewableDispatch, RenewableFullDispatch),
        ("c_sys5_re", PSY.RenewableDispatch, FixedOutput),
        ("c_sys5_uc", PSY.PowerLoad, StaticPowerLoad),
        ("c_sys5_il", PSY.InterruptiblePowerLoad, PowerLoadInterruption),
        ("c_sys5_hy", PSY.HydroDispatch, HydroDispatchRunOfRiver),
        ("c_sys5_hy", PSY.HydroDispatch, FixedOutput),
        ("c_sys5_uc", PSY.ThermalStandard, FixedOutput),
        ("c_sys5_uc", PSY.ThermalStandard, ThermalBasicUnitCommitment),
    )
        device = first(PSY.get_components(D, PSB.build_system(PSITestSystems, sys_name)))
        @test POM.get_multiplier_value(POM.ReserveOfferLinkParameter, device, F) == 1.0
    end
end

@testset "Links round trip through the outputs bundle as Int64" begin
    sys, g = _ol_system(; up = _OL_TWO_SERVICES)
    _ol_add_links!(sys, g, ["UP_A", "UP_B"], [[1, 1], [2, 0]])
    model = _ol_model(sys; attributes = _OL_LINKED)
    container = IOM.get_optimization_container(model)
    windows = POM.run_windows(model)
    store = POM.ParameterTimeSeriesStore()
    key_map = POM.copy_cost_time_series!(store, sys, windows)
    POM.write_model_inputs!(store, sys, container, windows)
    bundle = joinpath(mktempdir(; cleanup = true), "system-test")
    @test_logs (:info, r"Serialized") POM.write_outputs_system_bundle!(
        sys, store, key_map, bundle,
    )
    POM.close_parameter_store!(store)
    restored = PSY.from_file(bundle; time_series_read_only = true)
    g2 = get_component(ThermalStandard, restored, _OL_UNIT)
    got = PSY.get_time_series(PSY.Deterministic, g2, POM.RESERVE_OFFER_LINKS_TS_NAME)
    window = only(values(PSY.get_data(got)))
    @test eltype(window) == Int64
    @test window[1, :, :] == [1 1; 2 0]
    @test [a.name for a in IS.get_value_axes(got)] == ["block", "product"]
    IS.close!(IS.get_data_store(restored.data))
end
