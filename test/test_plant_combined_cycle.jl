# `SharedHRSGHeatBalance` on the shared-HRSG 1x2 example of `add_combined_cycle_block!`: one
# combustion turbine (CT1, 10 GJ/MWh, no intercept) feeding two steam turbines on different
# buses, in GJ. With η = 0.82 and κ = 3.6 GJ/MWh the HRSG recovers 0.82 · 6.4 = 5.248 GJ/h per
# MW of CT output. PSY's document export cannot serialize a FuelCurve in GJ, so every model is
# built with `system_to_file = false`.

const CC_KAPPA_GJ = 3.6
const CC_RECOVERED_HEAT_PER_MW = CC_HRSG_EFFICIENCY * (CC_CT_HEAT_RATE - CC_KAPPA_GJ)
const CC_BASE_POWER = 100.0
const CC_POOL_NAME = "CC1__hrsg1"

function _cc_template(
    network;
    formulation = ThermalStandardUnitCommitment,
    plant = true,
    duals = DataType[],
    attributes = Dict{String, Any}(),
)
    template = PowerOperationsProblemTemplate(network)
    set_device_model!(template, ThermalStandard, formulation)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranch)
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

function _cc_system(; kwargs...)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    add_combined_cycle_block!(sys; kwargs...)
    return sys
end

_cc_decision_model(template, sys) = DecisionModel(
    template, sys;
    optimizer = HiGHS_optimizer, store_variable_names = true, system_to_file = false,
)

function _cc_model(template, sys; output_dir = mktempdir(; cleanup = true))
    model = _cc_decision_model(template, sys)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    return model
end

_cc_variable(model, ::Type{T}) where {T} =
    IOM.get_variable(IOM.get_optimization_container(model), T, ThermalStandard)
_cc_constraint(model, ::Type{T}) where {T} =
    IOM.get_constraint(IOM.get_optimization_container(model), T, PSY.ThermalGen)
_cc_time_steps(model) = IOM.get_time_steps(IOM.get_optimization_container(model))

function _fix_thermal!(model, ::Type{T}, name::String, value::Float64, time_steps) where {T}
    variable = _cc_variable(model, T)
    for t in time_steps
        JuMP.fix(variable[name, t], value; force = true)
    end
    return
end

_wide(res, key) = read_variable(res, key; table_format = TableFormat.WIDE)

_st1_heat(p, u) = CC_ST1_CURVE.slope * p + CC_ST1_CURVE.intercept * u
_st2_heat(p, u) = CC_ST2_CURVE.slope * p + CC_ST2_CURVE.intercept * u

function _solve_and_read(model)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    res = IOM.OptimizationProblemOutputs(model)
    return (
        q = _wide(res, "HRSGHeatAllocationVariable__ThermalStandard"),
        p = _wide(res, "ActivePowerVariable__ThermalStandard"),
        u = _wide(res, "OnVariable__ThermalStandard"),
        res = res,
    )
end

@testset "PlantModel template slot" begin
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    @test isempty(template)
    set_plant_model!(template, CombinedCycleBlock, SharedHRSGHeatBalance)
    @test !isempty(template)
    plant_models = get_plant_models(template)
    @test collect(keys(plant_models)) == [:CombinedCycleBlock]
    model = plant_models[:CombinedCycleBlock]
    @test POM.get_component_type(model) == CombinedCycleBlock
    @test IOM.get_formulation(model) == SharedHRSGHeatBalance
    @test IOM.get_attribute(model, POM.SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE) == true
    @test isempty(IOM.get_duals(model))
    @test_throws ArgumentError PlantModel(PSY.PowerPlant, SharedHRSGHeatBalance)
    @test_throws ArgumentError PlantModel(CombinedCycleBlock, AbstractPlantFormulation)
    @test occursin("Plant Models", sprint(show, MIME("text/plain"), template))

    # A plant model whose attribute type is absent from the system is dropped at validation.
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    model = _cc_model(_cc_template(CopperPlateNetworkModel), sys)
    @test isempty(get_plant_models(IOM.get_template(model)))
end

@testset "SharedHRSGHeatBalance builds and solves on $(network)" for (network, _) in
                                                                     NETWORKS_FOR_TESTING
    sys = _cc_system()
    model = _cc_model(_cc_template(network), sys)
    out = _solve_and_read(model)
    @test names(out.q) == ["DateTime", "ST1__hrsg1", "ST2__hrsg1"]
    for row in 1:nrow(out.q)
        pool = CC_RECOVERED_HEAT_PER_MW * out.p[row, "CT1"]
        q1 = out.q[row, "ST1__hrsg1"]
        q2 = out.q[row, "ST2__hrsg1"]
        @test q1 ≈ _st1_heat(out.p[row, "ST1"], out.u[row, "ST1"]) atol = 1e-4
        @test q2 ≈ _st2_heat(out.p[row, "ST2"], out.u[row, "ST2"]) atol = 1e-4
        @test q1 + q2 <= pool + 1e-4
        @test out.u[row, "ST1"] <= out.u[row, "CT1"] + 1e-6
        @test out.u[row, "ST2"] <= out.u[row, "CT1"] + 1e-6
    end
end

@testset "SharedHRSGHeatBalance rows" begin
    sys = _cc_system()
    model = _cc_model(_cc_template(CopperPlateNetworkModel), sys)
    p = _cc_variable(model, ActivePowerVariable)
    u = _cc_variable(model, OnVariable)
    q = _cc_variable(model, HRSGHeatAllocationVariable)
    pool = _cc_constraint(model, HRSGHeatAllocationConstraint)
    draw = _cc_constraint(model, HRSGHeatDrawConstraint)
    link = _cc_constraint(model, CombinedCycleCommitmentConstraint)
    @test axes(q)[1] == ["ST1__hrsg1", "ST2__hrsg1"]
    @test axes(pool)[1] == [CC_POOL_NAME]
    @test axes(draw)[1] == ["CC1__hrsg1__ST1", "CC1__hrsg1__ST2"]
    @test axes(link)[1] == ["CC1__hrsg1__ST1", "CC1__hrsg1__ST2"]
    for t in _cc_time_steps(model)
        @test JuMP.lower_bound(q["ST1__hrsg1", t]) == 0.0
        # Σ q − η (a_g − κ) p_g − η b_g u_g ≤ 0, with p in system base.
        row = JuMP.constraint_object(pool[CC_POOL_NAME, t])
        @test row.set == MOI.LessThan(0.0)
        @test JuMP.coefficient(row.func, p["CT1", t]) ≈
              -CC_RECOVERED_HEAT_PER_MW * CC_BASE_POWER
        @test JuMP.coefficient(row.func, u["CT1", t]) == 0.0
        @test JuMP.coefficient(row.func, q["ST1__hrsg1", t]) == 1.0
        @test JuMP.coefficient(row.func, q["ST2__hrsg1", t]) == 1.0
        @test JuMP.coefficient(row.func, p["ST1", t]) == 0.0
        # q_s − a_s p_s − b_s u_s = 0
        row = JuMP.constraint_object(draw["CC1__hrsg1__ST1", t])
        @test row.set == MOI.EqualTo(0.0)
        @test JuMP.coefficient(row.func, q["ST1__hrsg1", t]) == 1.0
        @test JuMP.coefficient(row.func, p["ST1", t]) ≈ -CC_ST1_CURVE.slope * CC_BASE_POWER
        @test JuMP.coefficient(row.func, u["ST1", t]) ≈ -CC_ST1_CURVE.intercept
        row = JuMP.constraint_object(draw["CC1__hrsg1__ST2", t])
        @test JuMP.coefficient(row.func, p["ST2", t]) ≈ -CC_ST2_CURVE.slope * CC_BASE_POWER
        @test JuMP.coefficient(row.func, u["ST2", t]) ≈ -CC_ST2_CURVE.intercept
        # u_s − Σ u_g ≤ 0
        row = JuMP.constraint_object(link["CC1__hrsg1__ST2", t])
        @test row.set == MOI.LessThan(0.0)
        @test JuMP.coefficient(row.func, u["ST2", t]) == 1.0
        @test JuMP.coefficient(row.func, u["CT1", t]) == -1.0
    end

    # Without the electrical-output subtraction the pool is η times the fuel input.
    model = _cc_model(
        _cc_template(
            CopperPlateNetworkModel;
            attributes = Dict{String, Any}(
                POM.SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE => false,
            ),
        ),
        _cc_system(),
    )
    row = JuMP.constraint_object(
        _cc_constraint(model, HRSGHeatAllocationConstraint)[CC_POOL_NAME, 1],
    )
    @test JuMP.coefficient(row.func, _cc_variable(model, ActivePowerVariable)["CT1", 1]) ≈
          -CC_HRSG_EFFICIENCY * CC_CT_HEAT_RATE * CC_BASE_POWER
end

@testset "Available heat follows the CT output" begin
    @test POM.electrical_heat_equivalent(u"GJ") ≈ CC_KAPPA_GJ
    @test POM.electrical_heat_equivalent(u"MMBtu") ≈ 3.412 atol = 1e-3
    # The reference note's table rounds the recovered heat to 420, 630, 840 and 1050 GJ/h. With
    # ST2 held off and the CT fixed, the free ST1 takes the whole pool up to its curve cap in
    # every hour that needs it; at 80 MW the heat cap is below the 60 MW rating.
    for (ct_mw, note_heat) in
        ((80.0, 420.0), (120.0, 630.0), (160.0, 840.0), (200.0, 1050.0))
        pool = CC_RECOVERED_HEAT_PER_MW * ct_mw
        @test pool ≈ note_heat atol = 0.5
        model = _cc_model(_cc_template(CopperPlateNetworkModel), _cc_system())
        time_steps = _cc_time_steps(model)
        _fix_thermal!(model, OnVariable, "CT1", 1.0, time_steps)
        _fix_thermal!(model, ActivePowerVariable, "CT1", ct_mw / CC_BASE_POWER, time_steps)
        _fix_thermal!(model, OnVariable, "ST2", 0.0, time_steps)
        out = _solve_and_read(model)
        cap = min(60.0, (pool - CC_ST1_CURVE.intercept) / CC_ST1_CURVE.slope)
        @test all(out.p[:, "ST1"] .<= cap + 1e-3)
        @test maximum(out.p[:, "ST1"]) ≈ cap atol = 1e-3
        @test all(
            isapprox.(
                out.q[:, "ST1__hrsg1"],
                _st1_heat.(out.p[:, "ST1"], 1.0);
                atol = 1e-2,
            ),
        )
        @test all(iszero, out.q[:, "ST2__hrsg1"])
    end
end

@testset "A steam turbine is off when its CT is off" begin
    model = _cc_model(_cc_template(CopperPlateNetworkModel), _cc_system())
    off = 1:4
    _fix_thermal!(model, OnVariable, "CT1", 0.0, off)
    out = _solve_and_read(model)
    for t in off, st in ("ST1", "ST2")
        @test out.u[t, st] ≈ 0.0 atol = 1e-6
        @test out.p[t, st] ≈ 0.0 atol = 1e-6
        @test out.q[t, "$(st)__hrsg1"] ≈ 0.0 atol = 1e-6
    end
    for row in 1:nrow(out.q)
        @test out.q[row, "ST1__hrsg1"] ≈ _st1_heat(out.p[row, "ST1"], out.u[row, "ST1"]) atol =
            1e-4
        @test out.q[row, "ST2__hrsg1"] ≈ _st2_heat(out.p[row, "ST2"], out.u[row, "ST2"]) atol =
            1e-4
        @test out.q[row, "ST1__hrsg1"] + out.q[row, "ST2__hrsg1"] <=
              CC_RECOVERED_HEAT_PER_MW * out.p[row, "CT1"] + 1e-4
    end
end

@testset "Steam turbines share one heat pool" begin
    # CT at 80 MW recovers 419.84 GJ/h; both STs at full load would need 824 GJ/h, so the pool
    # binds and the two outputs trade off.
    model = _cc_model(_cc_template(CopperPlateNetworkModel), _cc_system())
    time_steps = _cc_time_steps(model)
    _fix_thermal!(model, OnVariable, "CT1", 1.0, time_steps)
    _fix_thermal!(model, ActivePowerVariable, "CT1", 0.8, time_steps)
    _fix_thermal!(model, OnVariable, "ST1", 1.0, time_steps)
    _fix_thermal!(model, OnVariable, "ST2", 1.0, time_steps)
    out = _solve_and_read(model)
    pool = CC_RECOVERED_HEAT_PER_MW * 80.0
    for row in 1:nrow(out.q)
        p1 = out.p[row, "ST1"]
        p2 = out.p[row, "ST2"]
        @test _st1_heat(p1, 1.0) + _st2_heat(p2, 1.0) ≈ pool atol = 1e-3
        @test p1 + p2 < 100.0 - 1e-3
        @test 20.0 - 1e-6 <= p1 <= 60.0 + 1e-6
        @test 15.0 - 1e-6 <= p2 <= 40.0 + 1e-6
    end
end

@testset "SharedHRSGHeatBalance under a dispatch formulation" begin
    model = _cc_model(
        _cc_template(CopperPlateNetworkModel; formulation = ThermalBasicDispatch),
        _cc_system(),
    )
    container = IOM.get_optimization_container(model)
    @test IOM.has_container_key(container, HRSGHeatAllocationConstraint, PSY.ThermalGen)
    @test IOM.has_container_key(container, HRSGHeatDrawConstraint, PSY.ThermalGen)
    @test !IOM.has_container_key(
        container,
        CombinedCycleCommitmentConstraint,
        PSY.ThermalGen,
    )
    @test !IOM.has_container_key(container, OnVariable, ThermalStandard)
    # Every unit is on, so the intercepts are constants on the right-hand side.
    row = JuMP.constraint_object(
        _cc_constraint(model, HRSGHeatDrawConstraint)["CC1__hrsg1__ST1", 1],
    )
    @test row.set == MOI.EqualTo(CC_ST1_CURVE.intercept)
    @test JuMP.coefficient(row.func, _cc_variable(model, ActivePowerVariable)["ST1", 1]) ≈
          -CC_ST1_CURVE.slope * CC_BASE_POWER

    # With every unit forced on, the fixture's minimum generation exceeds the low-load hours,
    # so the solve uses the relaxed-minimum dispatch. The pool then keeps the CT on: the two
    # intercepts alone need 54 GJ/h, or 10.3 MW of CT output.
    model = _cc_model(
        _cc_template(CopperPlateNetworkModel; formulation = ThermalDispatchNoMin),
        _cc_system(),
    )
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    res = IOM.OptimizationProblemOutputs(model)
    q = _wide(res, "HRSGHeatAllocationVariable__ThermalStandard")
    p = _wide(res, "ActivePowerVariable__ThermalStandard")
    for row in 1:nrow(q)
        @test q[row, "ST1__hrsg1"] ≈ _st1_heat(p[row, "ST1"], 1.0) atol = 1e-4
        @test q[row, "ST2__hrsg1"] ≈ _st2_heat(p[row, "ST2"], 1.0) atol = 1e-4
        @test q[row, "ST1__hrsg1"] + q[row, "ST2__hrsg1"] <=
              CC_RECOVERED_HEAT_PER_MW * p[row, "CT1"] + 1e-4
        @test p[row, "CT1"] >=
              (CC_ST1_CURVE.intercept + CC_ST2_CURVE.intercept) / CC_RECOVERED_HEAT_PER_MW -
              1e-3
    end
end

@testset "HRSGHeatAllocationConstraint duals" begin
    model = _cc_model(
        _cc_template(CopperPlateNetworkModel; duals = [HRSGHeatAllocationConstraint]),
        _cc_system(),
    )
    out = _solve_and_read(model)
    duals = read_dual(
        out.res, "HRSGHeatAllocationConstraint__ThermalGen";
        table_format = TableFormat.WIDE)
    @test names(duals) == ["DateTime", CC_POOL_NAME]
    @test all(isfinite, duals[:, CC_POOL_NAME])
    # JuMP's convention: the dual of a `≤` row in a minimization is nonpositive. Its magnitude
    # is the value of one more fuel unit of recovered heat: in hour 1 the heat cap on ST1 binds
    # and a GJ displaces 1/7.5 MWh of the 14 $/MWh marginal unit.
    @test all(duals[:, CC_POOL_NAME] .<= 1e-9)
    @test duals[1, CC_POOL_NAME] ≈ -14.0 / CC_ST1_CURVE.slope atol = 1e-6

    # A dual on a row the formulation did not build is an error at build time.
    out_dir = mktempdir(; cleanup = true)
    model = _cc_decision_model(
        _cc_template(
            CopperPlateNetworkModel;
            formulation = ThermalBasicDispatch,
            duals = [CombinedCycleCommitmentConstraint],
        ),
        _cc_system(),
    )
    @test build!(model; output_dir = out_dir, console_level = Logging.AboveMaxLevel) ==
          IOM.ModelBuildStatus.FAILED
    @test occursin(
        "No constraint of type CombinedCycleCommitmentConstraint is stored",
        read(joinpath(out_dir, "operation_problem.log"), String),
    )
end

_validate(template, sys) = POM.validate_template(_cc_decision_model(template, sys))

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

@testset "SharedHRSGHeatBalance template validation" begin
    template = _cc_template(CopperPlateNetworkModel)
    @test _validate(template, _cc_system()) === nothing

    _assert_rejected(
        template,
        _cc_system(; st_fuel_cost = 2.0),
        "must carry `fuel_cost = 0.0`",
    )
    _assert_rejected(
        _cc_template(CopperPlateNetworkModel; formulation = ThermalCompactUnitCommitment),
        _cc_system(),
        "compact formulation",
    )
    _assert_rejected(
        _cc_template(CopperPlateNetworkModel; formulation = FixedOutput),
        _cc_system(),
        "needs a thermal dispatch or unit commitment formulation",
    )
    _assert_rejected(
        template,
        _cc_system(; ct_heat_rate = 3.0),
        "exhaust heat would be negative",
    )
    _assert_rejected(template, _cc_system(; efficiency = 0.0), "must be positive")
    _assert_rejected(
        _cc_template(
            CopperPlateNetworkModel;
            attributes = Dict{String, Any}(
                POM.SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE => "yes",
            ),
        ),
        _cc_system(),
        "must be a Bool",
    )
    # `η · fuel_in` accepts a heat rate below κ.
    @test _validate(
        _cc_template(
            CopperPlateNetworkModel;
            attributes = Dict{String, Any}(
                POM.SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE => false,
            ),
        ),
        _cc_system(; ct_heat_rate = 3.0),
    ) === nothing

    # An HRSG with a CA but no CT.
    sys = _cc_system()
    block = only(get_supplemental_attributes(CombinedCycleBlock, sys))
    st2 = get_component(ThermalStandard, sys, "ST2")
    remove_supplemental_attribute!(sys, st2, block)
    add_supplemental_attribute!(sys, st2, block; hrsg_number = 2)
    _assert_rejected(template, sys, "must have at least one CT and one CA")

    # Mixed fuel units across the block.
    sys = _cc_system()
    st2 = get_component(ThermalStandard, sys, "ST2")
    set_operation_cost!(
        st2,
        ThermalGenerationCost(;
            variable_operation_cost = FuelCurve(LinearCurve(8.0, 24.0), PSY.MMBtu, 0.0),
            fixed = 0.0, start_up = 0.0, shut_down = 0.0,
        ),
    )
    _assert_rejected(template, sys, "mixes fuel units")

    # A member without a DeviceModel, and an unavailable member.
    no_thermal = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(no_thermal, PowerLoad, StaticPowerLoad)
    set_plant_model!(no_thermal, CombinedCycleBlock, SharedHRSGHeatBalance)
    _assert_rejected(no_thermal, _cc_system(), "has no DeviceModel for")
    sys = _cc_system()
    set_available!(get_component(ThermalStandard, sys, "ST1"), false)
    _assert_rejected(template, sys, "is not available")

    # A plant model with no construct path for its attribute type.
    sys = _cc_system()
    plant = ThermalPowerPlant(; name = "plant")
    add_supplemental_attribute!(
        sys, get_component(ThermalStandard, sys, "Alta"), plant; shaft_number = 1)
    bad = _cc_template(CopperPlateNetworkModel; plant = false)
    set_plant_model!(bad, PlantModel(ThermalPowerPlant, SharedHRSGHeatBalance))
    _assert_rejected(bad, sys, "has no construct path")
end

@testset "A block without a plant model" begin
    # Zero-priced steam turbines would be free energy: the build errors.
    template = _cc_template(CopperPlateNetworkModel; plant = false)
    _assert_rejected(template, _cc_system(), "would dispatch as free energy")

    # Priced steam turbines build as independent units, with a warning in the build log.
    out_dir = mktempdir(; cleanup = true)
    model = _cc_decision_model(template, _cc_system(; st_fuel_cost = 2.0))
    @test build!(model; output_dir = out_dir, console_level = Logging.AboveMaxLevel) ==
          IOM.ModelBuildStatus.BUILT
    @test occursin(
        "CombinedCycleBlock \"CC1\" has no PlantModel in the template",
        read(joinpath(out_dir, "operation_problem.log"), String),
    )
    container = IOM.get_optimization_container(model)
    @test !IOM.has_container_key(container, HRSGHeatAllocationConstraint, PSY.ThermalGen)
end
