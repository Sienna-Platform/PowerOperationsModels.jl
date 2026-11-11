@testset "PlantModel template slot" begin
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    @test isempty(get_plant_models(template))
    set_plant_model!(template, CombinedCycleBlock, SharedHRSGHeatBalance)
    @test !isempty(template)
    model = get_plant_models(template)[:CombinedCycleBlock]
    @test model isa PlantModel{CombinedCycleBlock, SharedHRSGHeatBalance}
    @test IOM.get_attribute(model, "subtract_electrical_output") === true
    @test_throws ArgumentError PlantModel(PSY.PowerPlant, SharedHRSGHeatBalance)
    @test_logs (:warn, r"Overwriting") set_plant_model!(
        template, CombinedCycleBlock, SharedHRSGHeatBalance)
    @test occursin("Plant Models", sprint(show, MIME"text/plain"(), template))
end

@testset "Combined cycle fixture and heat equivalent" begin
    @test POM.electrical_heat_equivalent(u"MMBtu") ≈ 3.41212822 atol = 1e-7
    @test POM.electrical_heat_equivalent(u"MMBtu") ≈ CC_KAPPA
    @test POM.electrical_heat_equivalent(u"GJ") ≈ 3.6
    @test_throws Exception POM.electrical_heat_equivalent(u"kg")
    for (layout, n_ct, n_ca, n_hrsg) in
        ((:one_by_one, 1, 1, 1), (:one_by_two, 1, 2, 1), (:two_by_one, 2, 1, 2))
        sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
        cc = add_combined_cycle_block!(sys; layout = layout)
        @test length(cc.cts) == n_ct && length(cc.cas) == n_ca
        @test length(PSY.get_hrsg_ct_map(cc.block)) == n_hrsg
        @test length(PSY.get_hrsg_ca_map(cc.block)) == n_hrsg
    end
end

@testset "heat_line" begin
    F(p) = p <= 140 ? 860 + 9.0 * (p - 80) : 1400 + 10.0 * (p - 140)
    pw = IS.PiecewisePointCurve([(80.0, 860.0), (140.0, 1400.0), (200.0, 2000.0)])
    hi = POM.heat_line(pw, :max_load)
    lo = POM.heat_line(pw, :min_load)
    @test hi.slope ≈ 10.0 && hi.intercept ≈ 0.0
    @test lo.slope ≈ 9.0 && lo.intercept ≈ 140.0
    for p in 80.0:20.0:200.0, l in (hi, lo)
        @test l.intercept + l.slope * p <= F(p) + 1e-9      # never above the curve
    end
    @test POM.heat_line(IS.LinearCurve(9.5, 100.0), :max_load) ==
          (intercept = 100.0, slope = 9.5)
    @test POM.heat_line(IS.LinearCurve(9.5, 100.0), :exact) ==
          (intercept = 100.0, slope = 9.5)
    @test POM.heat_line(
        IS.PiecewiseIncrementalCurve(860.0, [80.0, 140.0, 200.0], [9.0, 10.0]),
        :max_load,
    ).slope ≈ 10.0
    @test_throws ArgumentError POM.heat_line(pw, :exact)
    @test_throws ArgumentError POM.heat_line(IS.QuadraticCurve(0.01, 9.5, 100.0), :max_load)
    concave = IS.PiecewisePointCurve([(80.0, 860.0), (140.0, 1460.0), (200.0, 2000.0)])
    @test_throws ArgumentError POM.heat_line(concave, :max_load)
    @test_throws ArgumentError POM.heat_line(pw, :mid_load)
end

# Heat the HRSG recovers from a CT at `p` MW with the linear fixture curve, in MMBtu/h.
_cc_pool(p; eta = CC_ETA) =
    eta * ((CC_CT_LINE.slope - CC_KAPPA) * p + CC_CT_LINE.intercept)
_st1_power(heat) = (heat - CC_ST1_LINE.intercept) / CC_ST1_LINE.slope

function _cc_template(;
    formulation = ThermalStandardUnitCommitment,
    plant = true,
    duals = DataType[],
    attributes = Dict{String, Any}(),
)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, formulation)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    if plant
        set_plant_model!(
            template,
            PlantModel(
                CombinedCycleBlock, SharedHRSGHeatBalance;
                duals = duals, attributes = attributes,
            ),
        )
    end
    return template
end

function _cc_system(; system = "c_sys5_uc", kwargs...)
    sys = PSB.build_system(PSITestSystems, system)
    cc = add_combined_cycle_block!(sys; kwargs...)
    return sys, cc
end

function _cc_model(template, sys)
    model = DecisionModel(
        template, sys;
        optimizer = HiGHS_optimizer, store_variable_names = true,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

_cc_variable(model, ::Type{T}) where {T} =
    IOM.get_variable(IOM.get_optimization_container(model), T, ThermalStandard)
_cc_constraint(model, ::Type{T}) where {T} =
    IOM.get_constraint(IOM.get_optimization_container(model), T, PSY.ThermalGen)
_cc_time_steps(model) = IOM.get_time_steps(IOM.get_optimization_container(model))
_cc_base_power(model) =
    IOM.get_model_base_power(IOM.get_optimization_container(model))

# Fix a unit's commitment and, when on, its output in MW, in every step.
function _fix_unit!(model, name::String, on::Bool, mw::Float64 = 0.0)
    u = _cc_variable(model, OnVariable)
    p = _cc_variable(model, ActivePowerVariable)
    for t in _cc_time_steps(model)
        JuMP.fix(u[name, t], on ? 1.0 : 0.0; force = true)
        on && JuMP.fix(p[name, t], mw / _cc_base_power(model); force = true)
    end
    return
end

function _solve_and_read(model)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    res = IOM.OptimizationProblemOutputs(model)
    wide(key) = read_variable(res, key; table_format = TableFormat.WIDE)
    return (
        q = wide("HRSGHeatAllocationVariable__ThermalStandard"),
        p = wide("ActivePowerVariable__ThermalStandard"),
    )
end

@testset "SharedHRSGHeatBalance builds and solves: $(formulation), $(layout)" for formulation in
                                                                                  (
        ThermalStandardUnitCommitment, ThermalBasicUnitCommitment,
        ThermalStandardDispatch, ThermalBasicDispatch,
    ),
    layout in (:one_by_one, :one_by_two, :two_by_one)

    # `c_sys5_uc` cannot hold every unit at minimum output, so dispatch runs use `c_sys5`.
    system = formulation <: POM.AbstractThermalUnitCommitment ? "c_sys5_uc" : "c_sys5"
    sys, _ = _cc_system(; system = system, layout = layout)
    model = _cc_model(_cc_template(; formulation = formulation), sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "SharedHRSGHeatBalance row coefficients" begin
    sys, _ = _cc_system(; layout = :one_by_one)
    model = _cc_model(_cc_template(), sys)
    bp = _cc_base_power(model)
    p = _cc_variable(model, ActivePowerVariable)
    on = _cc_variable(model, OnVariable)
    q = _cc_variable(model, HRSGHeatAllocationVariable)
    pool = _cc_constraint(model, HRSGHeatAllocationConstraint)
    draw = _cc_constraint(model, HRSGHeatDrawConstraint)
    link = _cc_constraint(model, CombinedCycleCommitmentConstraint)
    @test axes(q)[1] == ["ST1__hrsg1"]
    @test axes(pool)[1] == ["cc__hrsg1"]
    @test axes(draw)[1] == ["ST1"]
    @test axes(link)[1] == ["ST1"]
    @test JuMP.lower_bound(q["ST1__hrsg1", 1]) == 0.0
    @test JuMP.normalized_coefficient(pool["cc__hrsg1", 1], q["ST1__hrsg1", 1]) ≈ 1.0
    @test JuMP.normalized_coefficient(pool["cc__hrsg1", 1], p["CT1", 1]) ≈
          -CC_ETA * (9.5 - CC_KAPPA) * bp
    @test JuMP.normalized_coefficient(pool["cc__hrsg1", 1], on["CT1", 1]) ≈ -CC_ETA * 100.0
    @test JuMP.normalized_rhs(pool["cc__hrsg1", 1]) == 0.0
    @test JuMP.normalized_coefficient(draw["ST1", 1], q["ST1__hrsg1", 1]) ≈ 1.0
    @test JuMP.normalized_coefficient(draw["ST1", 1], p["ST1", 1]) ≈ -7.5 * bp
    @test JuMP.normalized_coefficient(draw["ST1", 1], on["ST1", 1]) ≈ -30.0
    @test JuMP.normalized_coefficient(link["ST1", 1], on["ST1", 1]) ≈ 1.0
    @test JuMP.normalized_coefficient(link["ST1", 1], on["CT1", 1]) ≈ -1.0

    # κ drops out when the block factor already nets the electrical output.
    model = _cc_model(
        _cc_template(;
            attributes = Dict{String, Any}("subtract_electrical_output" => false),
        ),
        sys,
    )
    @test JuMP.normalized_coefficient(
        _cc_constraint(model, HRSGHeatAllocationConstraint)["cc__hrsg1", 1],
        _cc_variable(model, ActivePowerVariable)["CT1", 1],
    ) ≈ -CC_ETA * 9.5 * bp
end

@testset "Steam follows the heat its CT makes" begin
    # η = 0.5 so the pool, not the steam unit's limit, binds at low CT output.
    for ct_mw in (80.0, 120.0, 200.0)
        sys, _ = _cc_system(; layout = :one_by_one, eta = 0.5)
        model = _cc_model(_cc_template(), sys)
        _fix_unit!(model, "CT1", true, ct_mw)
        out = _solve_and_read(model)
        # Free steam runs up to the heat on hand, unless a low-load step curtails it.
        available = min(60.0, _st1_power(_cc_pool(ct_mw; eta = 0.5)))
        @test all(out.p[!, "ST1"] .<= available + 1e-3)
        @test maximum(out.p[!, "ST1"]) ≈ available atol = 1e-3
    end
end

@testset "Steam is off when its CT is off" begin
    sys, _ = _cc_system(; layout = :one_by_one)
    model = _cc_model(_cc_template(), sys)
    _fix_unit!(model, "CT1", false)
    out = _solve_and_read(model)
    @test all(iszero, out.p[!, "ST1"])
end

@testset "Two steam units share one HRSG" begin
    sys, _ = _cc_system(; layout = :one_by_two)
    model = _cc_model(_cc_template(), sys)
    _fix_unit!(model, "CT1", true, 80.0)
    on = _cc_variable(model, OnVariable)
    for t in _cc_time_steps(model), name in ("ST1", "ST2")
        JuMP.fix(on[name, t], 1.0; force = true)
    end
    out = _solve_and_read(model)
    draw =
        7.5 .* out.p[!, "ST1"] .+ 30.0 .+ 8.0 .* out.p[!, "ST2"] .+ 24.0
    @test all(isapprox.(draw, _cc_pool(80.0); atol = 1e-2))
    @test all(out.p[!, "ST2"] .>= 15.0 - 1e-6)
end

@testset "A 2x1 runs on one CT" begin
    sys, _ = _cc_system(; layout = :two_by_one, eta = 0.5)
    model = _cc_model(_cc_template(), sys)
    @test axes(_cc_constraint(model, HRSGHeatDrawConstraint))[1] == ["ST1"]
    _fix_unit!(model, "CT1", true, 80.0)
    _fix_unit!(model, "CT2", false)
    out = _solve_and_read(model)
    @test all(
        isapprox.(out.p[!, "ST1"], _st1_power(_cc_pool(80.0; eta = 0.5)); atol = 1e-3),
    )
    @test all(x -> abs(x) < 1e-6, out.q[!, "ST1__hrsg2"])

    model = _cc_model(_cc_template(), sys)
    _fix_unit!(model, "CT1", true, 80.0)
    _fix_unit!(model, "CT2", true, 80.0)
    out = _solve_and_read(model)
    @test all(isapprox.(out.p[!, "ST1"], 60.0; atol = 1e-3))
end

@testset "An unavailable CT is left out" begin
    sys, cc = _cc_system(; layout = :two_by_one, eta = 0.5)
    PSY.set_available!(cc.cts[2], false)
    model = _cc_model(_cc_template(), sys)
    pool = _cc_constraint(model, HRSGHeatAllocationConstraint)
    q = _cc_variable(model, HRSGHeatAllocationVariable)
    row = JuMP.constraint_object(pool["cc__hrsg2", 1])
    @test length(JuMP.linear_terms(row.func)) == 1
    @test JuMP.coefficient(row.func, q["ST1__hrsg2", 1]) ≈ 1.0
    _fix_unit!(model, "CT1", true, 80.0)
    out = _solve_and_read(model)
    @test all(
        isapprox.(out.p[!, "ST1"], _st1_power(_cc_pool(80.0; eta = 0.5)); atol = 1e-3),
    )
end

@testset "A must-run CT contributes its no-load heat as a constant" begin
    sys, cc = _cc_system(; layout = :one_by_one)
    PSY.set_commitment_mode!(cc.cts[1], PSY.CommitmentModes.MUST_RUN)
    model = _cc_model(_cc_template(), sys)
    on = _cc_variable(model, OnVariable)
    @test !("CT1" in axes(on)[1])
    pool = _cc_constraint(model, HRSGHeatAllocationConstraint)
    @test JuMP.normalized_rhs(pool["cc__hrsg1", 1]) ≈ CC_ETA * 100.0
    # A CT that is always on makes the commitment link redundant, so no row is built.
    @test !IOM.has_container_key(
        IOM.get_optimization_container(model),
        CombinedCycleCommitmentConstraint, PSY.ThermalGen)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "Exhaust line of a piecewise CT curve" begin
    sys, _ = _cc_system(; layout = :one_by_one, ct_curve = :piecewise)
    for (mode, slope, intercept) in (("max_load", 10.0, 0.0), ("min_load", 9.0, 140.0))
        model = _cc_model(
            _cc_template(; attributes = Dict{String, Any}("exhaust_line" => mode)), sys,
        )
        bp = _cc_base_power(model)
        pool = _cc_constraint(model, HRSGHeatAllocationConstraint)
        @test JuMP.normalized_coefficient(
            pool["cc__hrsg1", 1], _cc_variable(model, ActivePowerVariable)["CT1", 1]) ≈
              -CC_ETA * (slope - CC_KAPPA) * bp
        @test JuMP.normalized_coefficient(
            pool["cc__hrsg1", 1], _cc_variable(model, OnVariable)["CT1", 1]) ≈
              -CC_ETA * intercept atol = 1e-9
    end
    model = _cc_model(_cc_template(), sys)
    @test JuMP.normalized_coefficient(
        _cc_constraint(model, HRSGHeatAllocationConstraint)["cc__hrsg1", 1],
        _cc_variable(model, ActivePowerVariable)["CT1", 1],
    ) ≈ -CC_ETA * (10.0 - CC_KAPPA) * _cc_base_power(model)
end

struct NoPathPlantFormulation <: POM.AbstractPlantFormulation end

_validate(template, sys) =
    POM.validate_template(DecisionModel(template, sys; optimizer = HiGHS_optimizer))

function _assert_rejected(template, sys, message::String)
    err = try
        _validate(template, sys)
        nothing
    catch e
        e
    end
    @test err isa IS.ConflictingInputsError
    @test occursin(message, sprint(showerror, err))
    return
end

function _set_variable_cost!(gen, variable_cost)
    PSY.set_operation_cost!(
        gen,
        PSY.ThermalGenerationCost(;
            variable_operation_cost = variable_cost,
            fixed = 0.0, start_up = 0.0, shut_down = 0.0,
        ),
    )
    return
end

_fuel(curve; units = u"MMBtu", price = 0.0) = PSY.FuelCurve(curve, units, price)

@testset "SharedHRSGHeatBalance template validation" begin
    @test _validate(_cc_template(), first(_cc_system(; layout = :two_by_one))) === nothing

    # Each case changes a valid 1x1 system or template and names the error it must raise.
    data_cases = [
        ("heat_recovery_to_steam_factor", (sys, cc) -> nothing, (; eta = 0.0)),
        ("at least one CT and one CA",
            (sys, cc) -> PSY.remove_supplemental_attribute!(sys, cc.cts[1], cc.block),
            (;)),
        ("lists member id",
            (sys, cc) -> push!(PSY.get_hrsg_ct_map(cc.block)[1], 987654), (;)),
        ("more than one HRSG",
            (sys, cc) -> begin
                PSY.add_supplemental_attribute!(sys, cc.cts[1], cc.block; hrsg_number = 2)
                PSY.add_supplemental_attribute!(sys, cc.cas[1], cc.block; hrsg_number = 2)
            end, (;)),
        ("mixes fuel units",
            (sys, cc) -> _set_variable_cost!(
                cc.cas[1], _fuel(PSY.LinearCurve(7.5, 30.0); units = u"GJ")), (;)),
        ("needs a FuelCurve",
            (sys, cc) -> _set_variable_cost!(
                cc.cts[1], PSY.CostCurve(PSY.LinearCurve(20.0))), (;)),
        ("linear",
            (sys, cc) -> _set_variable_cost!(
                cc.cas[1],
                _fuel(
                    PSY.PiecewisePointCurve([(20.0, 180.0), (40.0, 330.0), (60.0, 500.0)]),
                ),
            ), (;)),
        ("convex",
            (sys, cc) -> _set_variable_cost!(
                cc.cts[1], _fuel(PSY.QuadraticCurve(0.01, 9.5, 100.0); price = 3.0),
            ), (;)),
        ("convex",
            (sys, cc) -> _set_variable_cost!(
                cc.cts[1],
                _fuel(
                    PSY.PiecewisePointCurve(
                        [(80.0, 860.0), (140.0, 1460.0), (200.0, 2000.0)]);
                    price = 3.0),
            ), (;)),
        ("exhaust heat",
            (sys, cc) -> _set_variable_cost!(
                cc.cts[1], _fuel(PSY.LinearCurve(3.0, 100.0); price = 3.0)), (;)),
        ("exhaust heat",
            (sys, cc) -> _set_variable_cost!(
                cc.cts[1], _fuel(PSY.LinearCurve(9.5, -1000.0); price = 3.0)), (;)),
        ("fuel_cost = 0.0",
            (sys, cc) -> _set_variable_cost!(
                cc.cas[1], _fuel(PSY.LinearCurve(7.5, 30.0); price = 2.0)), (;)),
    ]
    for (message, change!, kwargs) in data_cases
        sys, cc = _cc_system(; layout = :one_by_one, kwargs...)
        change!(sys, cc)
        _assert_rejected(_cc_template(), sys, message)
    end

    sys, cc = _cc_system(; layout = :one_by_one)
    other = PSY.CombinedCycleBlock(;
        name = "other",
        configuration = PSY.CombinedCycleConfiguration.SeparateShaftCombustionSteam,
        heat_recovery_to_steam_factor = CC_ETA,
    )
    for gen in (cc.cts[1], cc.cas[1])
        PSY.add_supplemental_attribute!(sys, gen, other; hrsg_number = 1)
    end
    _assert_rejected(_cc_template(), sys, "one block per device")

    sys, _ = _cc_system(; layout = :one_by_one)
    for (key, value) in
        (("subtract_electrical_output", "yes"), ("exhaust_line", "mid_load"))
        template = _cc_template(; attributes = Dict{String, Any}(key => value))
        _assert_rejected(template, sys, key)
    end

    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_plant_model!(template, CombinedCycleBlock, SharedHRSGHeatBalance)
    _assert_rejected(template, sys, "no DeviceModel")

    template = _cc_template(; plant = false)
    set_plant_model!(template, PlantModel(CombinedCycleBlock, NoPathPlantFormulation))
    _assert_rejected(template, sys, "has no construct path")

    # A member that is not available is not checked.
    sys, cc = _cc_system(; layout = :two_by_one)
    _set_variable_cost!(cc.cts[2], PSY.CostCurve(PSY.LinearCurve(20.0)))
    PSY.set_available!(cc.cts[2], false)
    @test _validate(_cc_template(), sys) === nothing
end

@testset "A block without a plant model" begin
    sys, cc = _cc_system(; layout = :one_by_one)
    _assert_rejected(_cc_template(; plant = false), sys, "free energy")

    _set_variable_cost!(cc.cas[1], _fuel(PSY.LinearCurve(7.5, 30.0); price = 2.0))
    model = DecisionModel(_cc_template(; plant = false), sys; optimizer = HiGHS_optimizer)
    @test_logs (:warn, r"independent thermal units") match_mode = :any POM.validate_template(
        model)
end

@testset "A steam unit that sells reserve gets a warning" begin
    sys, cc = _cc_system(; layout = :one_by_one)
    add_reserve_product_without_requirement_time_series!(sys, "R1", "Up", [cc.cas[1]])
    template = _cc_template()
    set_service_model!(template, ServiceModel(OnlineReserve{ReserveUp}, RangeReserve))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test_logs (:warn, r"reserve") match_mode = :any POM.validate_template(model)
end

@testset "A member with an offer curve cost" begin
    sys, cc = _cc_system(; layout = :one_by_one)
    PSY.set_operation_cost!(cc.cas[1], PSY.MarketBidCost(nothing))
    _assert_rejected(_cc_template(), sys, "needs a FuelCurve")
    model = DecisionModel(_cc_template(; plant = false), sys; optimizer = HiGHS_optimizer)
    @test_logs (:warn, r"independent thermal units") match_mode = :any POM.validate_template(
        model)
end

@testset "SharedHRSGHeatBalance under compact formulations: $(formulation), $(layout)" for formulation in
                                                                                           (
        ThermalCompactUnitCommitment, ThermalBasicCompactUnitCommitment,
        ThermalCompactDispatch,
    ),
    layout in (:one_by_one, :one_by_two, :two_by_one)

    system = formulation <: POM.AbstractThermalUnitCommitment ? "c_sys5_uc" : "c_sys5"
    sys, _ = _cc_system(; system = system, layout = layout)
    model = _cc_model(_cc_template(; formulation = formulation), sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "Compact formulations: rows on power above minimum" begin
    sys, _ = _cc_system(; layout = :one_by_one)
    model = _cc_model(_cc_template(; formulation = ThermalCompactUnitCommitment), sys)
    bp = _cc_base_power(model)
    dp = _cc_variable(model, PowerAboveMinimumVariable)
    on = _cc_variable(model, OnVariable)
    pool = _cc_constraint(model, HRSGHeatAllocationConstraint)
    draw = _cc_constraint(model, HRSGHeatDrawConstraint)
    @test JuMP.normalized_coefficient(pool["cc__hrsg1", 1], dp["CT1", 1]) ≈
          -CC_ETA * (9.5 - CC_KAPPA) * bp
    @test JuMP.normalized_coefficient(pool["cc__hrsg1", 1], on["CT1", 1]) ≈
          -CC_ETA * ((9.5 - CC_KAPPA) * 80.0 + 100.0)
    @test JuMP.normalized_coefficient(draw["ST1", 1], dp["ST1", 1]) ≈ -7.5 * bp
    @test JuMP.normalized_coefficient(draw["ST1", 1], on["ST1", 1]) ≈ -(7.5 * 20.0 + 30.0)
end

@testset "A block of ThermalMultiStart units" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_pglib")
    ct = PSY.get_component(ThermalMultiStart, sys, "101_CT_1")
    ca = PSY.get_component(ThermalMultiStart, sys, "115_STEAM_1")
    for (gen, prime_mover, curve, price) in (
        (ct, PSY.PrimeMovers.CT, PSY.LinearCurve(9.5, 10.0), 3.0),
        (ca, PSY.PrimeMovers.CA, PSY.LinearCurve(7.5, 3.0), 0.0),
    )
        PSY.set_prime_mover_type!(gen, prime_mover)
        old = PSY.get_operation_cost(gen)
        PSY.set_operation_cost!(
            gen,
            PSY.ThermalGenerationCost(;
                variable_operation_cost = _fuel(curve; price = price),
                fixed = PSY.get_fixed(old),
                start_up = PSY.get_start_up(old),
                shut_down = PSY.get_shut_down(old),
            ),
        )
    end
    block = PSY.CombinedCycleBlock(;
        name = "cc",
        configuration = PSY.CombinedCycleConfiguration.SeparateShaftCombustionSteam,
        heat_recovery_to_steam_factor = CC_ETA,
    )
    PSY.add_supplemental_attribute!(sys, ct, block; hrsg_number = 1)
    PSY.add_supplemental_attribute!(sys, ca, block; hrsg_number = 1)
    template = _cc_template()
    set_device_model!(template, ThermalMultiStart, ThermalMultiStartUnitCommitment)
    model = _cc_model(template, sys)
    container = IOM.get_optimization_container(model)
    bp = _cc_base_power(model)
    q = IOM.get_variable(container, HRSGHeatAllocationVariable, ThermalMultiStart)
    @test axes(q)[1] == ["115_STEAM_1__hrsg1"]
    dp = IOM.get_variable(container, PowerAboveMinimumVariable, ThermalMultiStart)
    pool = _cc_constraint(model, HRSGHeatAllocationConstraint)
    @test JuMP.normalized_coefficient(pool["cc__hrsg1", 1], dp["101_CT_1", 1]) ≈
          -CC_ETA * (9.5 - CC_KAPPA) * bp
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "HRSGHeatAllocationConstraint duals" begin
    sys, _ = _cc_system(; system = "c_sys5", layout = :one_by_one, eta = 0.5)
    template = _cc_template(;
        formulation = ThermalStandardDispatch, duals = [HRSGHeatAllocationConstraint])
    model = _cc_model(template, sys)
    out = _solve_and_read(model)
    duals = read_dual(
        IOM.OptimizationProblemOutputs(model),
        "HRSGHeatAllocationConstraint__ThermalGen";
        table_format = TableFormat.WIDE)
    price = duals[!, "cc__hrsg1"]
    # JuMP's convention: the dual of a `<=` row in a minimization is not positive.
    @test all(isfinite, price)
    @test all(price .<= 1e-9)
    @test any(price .< -1e-6)
    slack =
        _cc_pool.(out.p[!, "CT1"]; eta = 0.5) .-
        (7.5 .* out.p[!, "ST1"] .+ 30.0)
    @test all(abs.(price[slack .> 1e-4]) .< 1e-9)

    # A dual on a row the formulation did not build fails the build.
    template = _cc_template(;
        formulation = ThermalStandardDispatch,
        duals = [CombinedCycleCommitmentConstraint])
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    out_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = out_dir, console_level = Logging.AboveMaxLevel) ==
          IOM.ModelBuildStatus.FAILED
    @test occursin(
        "No constraint of type CombinedCycleCommitmentConstraint is stored",
        read(joinpath(out_dir, "operation_problem.log"), String),
    )
end

function _initial_condition(model, ::Type{T}, name::String) where {T}
    container = IOM.get_optimization_container(model)
    for (key, conditions) in IOM.get_initial_conditions(container), ic in conditions
        IOM.get_entry_type(key) === T || continue
        PSY.get_name(IOM.get_component(ic)) == name || continue
        return IOM.jump_value(IOM.get_condition(ic))
    end
    return error("no $(T) initial condition for $(name)")
end

@testset "The initial conditions model carries the plant rows" begin
    sys, _ = _cc_system(; layout = :one_by_one)
    model = _cc_model(_cc_template(), sys)
    bp = _cc_base_power(model)
    ct_on = _initial_condition(model, POM.DeviceStatus, "CT1")
    st_on = _initial_condition(model, POM.DeviceStatus, "ST1")
    ct_mw = _initial_condition(model, POM.DevicePower, "CT1") * bp
    st_mw = _initial_condition(model, POM.DevicePower, "ST1") * bp
    @test st_on <= ct_on + 1e-6
    @test 7.5 * st_mw + 30.0 * st_on <= ct_on * _cc_pool(ct_mw) + 1e-3
end

@testset "A must-run CT under a commitment feedforward" begin
    sys, cc = _cc_system(; system = "c_sys5", layout = :one_by_one)
    PSY.set_commitment_mode!(cc.cts[1], PSY.CommitmentModes.MUST_RUN)
    thermal_model = DeviceModel(ThermalStandard, ThermalStandardDispatch)
    attach_feedforward!(
        thermal_model,
        SemiContinuousFeedforward(;
            component_type = ThermalStandard,
            source = OnVariable,
            affected_values = [ActivePowerVariable],
        ),
    )
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, thermal_model)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_plant_model!(template, CombinedCycleBlock, SharedHRSGHeatBalance)
    model = _cc_model(template, sys)
    pool = _cc_constraint(model, HRSGHeatAllocationConstraint)
    @test JuMP.normalized_rhs(pool["cc__hrsg1", 1]) ≈ CC_ETA * 100.0
end

@testset "A CT the device model filters out is left out" begin
    sys, _ = _cc_system(; layout = :one_by_one)
    thermal_model = DeviceModel(
        ThermalStandard, ThermalStandardUnitCommitment;
        attributes = Dict{String, Any}(
            "device_filter" =>
                make_selector(x -> PSY.get_name(x) != "CT1", ThermalStandard),
        ),
    )
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, thermal_model)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_plant_model!(template, CombinedCycleBlock, SharedHRSGHeatBalance)
    model = _cc_model(template, sys)
    row = JuMP.constraint_object(
        _cc_constraint(model, HRSGHeatAllocationConstraint)["cc__hrsg1", 1])
    @test length(JuMP.linear_terms(row.func)) == 1
end

@testset "Members need a thermal formulation" begin
    sys, _ = _cc_system(; layout = :one_by_one)
    _assert_rejected(_cc_template(; formulation = FixedOutput), sys, "thermal dispatch")
    # Without a plant model, FixedOutput steam is not dispatched on cost: no guard.
    @test _validate(_cc_template(; formulation = FixedOutput, plant = false), sys) ===
          nothing
end

@testset "A steam unit that is always on needs an available CT" begin
    sys, cc = _cc_system(; system = "c_sys5", layout = :one_by_one)
    PSY.set_available!(cc.cts[1], false)
    model = DecisionModel(
        _cc_template(; formulation = ThermalStandardDispatch), sys;
        optimizer = HiGHS_optimizer)
    out_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = out_dir, console_level = Logging.AboveMaxLevel) ==
          IOM.ModelBuildStatus.FAILED
    @test occursin(
        "no CT to draw heat from",
        read(joinpath(out_dir, "operation_problem.log"), String),
    )
end
