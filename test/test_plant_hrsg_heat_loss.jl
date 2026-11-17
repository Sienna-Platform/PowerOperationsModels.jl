# Row of HRSG 1 at t = 1 and the variables of CT1, from a block with `heat_loss`.
function _pool_row(heat_loss)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    add_wecc_physical_block!(sys, LUNA_QUARTER; heat_loss)
    model = _cc_model(_cc_template(), sys)
    return (
        row = _cc_constraint(model, HRSGHeatAllocationConstraint)["cc__hrsg1", 1],
        u = _cc_variable(model, OnVariable)["CT1", 1],
        p = _cc_variable(model, ActivePowerVariable)["CT1", 1],
    )
end

@testset "The heat loss sits on each CT's commitment in the pool row" begin
    plain = _pool_row(0.0)
    lossy = _pool_row(12.5)
    @test JuMP.normalized_coefficient(lossy.row, lossy.u) -
          JuMP.normalized_coefficient(plain.row, plain.u) ≈ 12.5
    @test JuMP.normalized_coefficient(lossy.row, lossy.p) ==
          JuMP.normalized_coefficient(plain.row, plain.p)
end

@testset "A block with no loss set builds the rows of plan 4" begin
    eta = 0.7
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    cc = add_combined_cycle_block!(sys; layout = :one_by_one, eta)
    @test PSY.get_hrsg_heat_loss(cc.block) == 0.0
    model = _cc_model(_cc_template(), sys)
    row = _cc_constraint(model, HRSGHeatAllocationConstraint)["cc__hrsg1", 1]
    u = _cc_variable(model, OnVariable)["CT1", 1]
    b =
        POM.heat_line(
            POM.heat_value_curve(POM.fuel_cost_curve(cc.cts[1])),
            :max_load,
        ).intercept
    @test JuMP.normalized_coefficient(row, u) ≈ -eta * b
end

# The loss is a constructor field, so the block is replaced by one with the new loss.
function _replace_loss!(sys, plant, x)
    old = plant.block
    for d in (plant.cts..., plant.ca)
        PSY.remove_supplemental_attribute!(sys, d, old)
    end
    block = PSY.CombinedCycleBlock(;
        name = PSY.get_name(old),
        configuration = PSY.get_configuration(old),
        heat_recovery_to_steam_factor = PSY.get_heat_recovery_to_steam_factor(old),
        hrsg_heat_loss = x,
    )
    for (i, ct) in enumerate(plant.cts)
        PSY.add_supplemental_attribute!(sys, ct, block; hrsg_number = i)
        PSY.add_supplemental_attribute!(sys, plant.ca, block; hrsg_number = i)
    end
    return
end

@testset "The heat loss is validated" begin
    set_loss(x) = (sys, plant) -> _replace_loss!(sys, plant, x)
    for x in (-1.0, NaN)
        @test_throws ArgumentError PSY.CombinedCycleBlock(;
            name = "cc",
            configuration = PSY.CombinedCycleConfiguration.SingleShaftCombustionSteam,
            hrsg_heat_loss = x)
    end
    @test rejects_template(set_loss(Inf), "hrsg_heat_loss", "CT1")
    @test rejects_template(set_loss(1.0e6), "hrsg_heat_loss", "CT1")
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    add_wecc_physical_block!(sys, LUNA_QUARTER; steam = :hrsg_loss)
    @test _validate_dual_fuel(sys) === nothing
end

# The CT's recovered heat at minimum output, in MMBtu/h, from the fixture in natural units.
function _ct_limits()
    ct_points = wecc_split(LUNA_QUARTER).ct_points
    (x1, f1), (x2, f2) = ct_points[(end - 1):end]
    slope = (f2 - f1) / (x2 - x1)
    b = f2 - slope * x2
    p_min = first(first(ct_points))
    kappa = POM.electrical_heat_equivalent(u"MMBtu")
    eta = LUNA_QUARTER.eta
    return (at_min = eta * ((slope - kappa) * p_min + b), at_zero = eta * b)
end

@testset "The per-CT rule is in MMBtu/h, right at its limit" begin
    limit = _ct_limits().at_min
    @test limit ≈ 140.69 atol = 0.01
    set_loss(x) = (sys, plant) -> _replace_loss!(sys, plant, x)
    @test rejects_template(set_loss(limit + 1.0), "hrsg_heat_loss", "CT1")
    @test !rejects_template(set_loss(limit - 1.0), "hrsg_heat_loss")
end

@testset "Without a commitment variable the CT's minimum is zero under ThermalDispatchNoMin" begin
    lim = _ct_limits()
    loss = (lim.at_zero + lim.at_min) / 2
    @test 0.0 < lim.at_zero < loss < lim.at_min
    function validate(formulation)
        sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
        add_wecc_physical_block!(sys, LUNA_QUARTER; heat_loss = loss)
        template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
        set_device_model!(template, ThermalStandard, formulation)
        set_device_model!(template, PowerLoad, StaticPowerLoad)
        set_plant_model!(template, CombinedCycleBlock, SharedHRSGHeatBalance)
        return Logging.with_logger(Logging.ConsoleLogger(stderr, Logging.Error)) do
            POM.validate_template(
                DecisionModel(template, sys; optimizer = HiGHS_optimizer))
        end
    end
    err = try
        validate(ThermalDispatchNoMin)
    catch e
        e
    end
    @test err isa IS.ConflictingInputsError
    @test occursin("hrsg_heat_loss", sprint(showerror, err))
    @test occursin("CT1", sprint(showerror, err))
    @test validate(ThermalStandardUnitCommitment) === nothing
end
