include(joinpath(@__DIR__, "test_utils", "wecc_combined_cycle.jl"))

function _duct_template()
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_plant_model!(template, CombinedCycleBlock, SharedHRSGHeatBalance)
    return template
end

function _duct_model(sys)
    model = DecisionModel(
        _duct_template(), sys;
        optimizer = HiGHS_optimizer, store_variable_names = true, system_to_file = false,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

_duct_var(model, ::Type{T}) where {T} =
    IOM.get_variable(IOM.get_optimization_container(model), T, ThermalStandard)

# Fix a unit's commitment and, when on, its output in MW, in every step.
function _fix_mw!(model, name::String, mw::Union{Nothing, Float64})
    c = IOM.get_optimization_container(model)
    u, p = _duct_var(model, OnVariable), _duct_var(model, ActivePowerVariable)
    for t in IOM.get_time_steps(c)
        JuMP.fix(u[name, t], isnothing(mw) ? 0.0 : 1.0; force = true)
        isnothing(mw) ||
            JuMP.fix(p[name, t], mw / IOM.get_model_base_power(c); force = true)
    end
    return
end

# Luna at a quarter of its size, so the five-bus system can hold any fixed operating point.
const LUNA_QUARTER = wecc_scale(WECC_LUNA, 0.25)

# Duct firing in MW at the first step with the CTs and the steam turbine fixed, or
# `nothing` when the model is infeasible.
function _duct_mw(; cts, steam_mw, kwargs...)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    plant = add_wecc_physical_block!(sys, LUNA_QUARTER; kwargs...)
    model = _duct_model(sys)
    for (i, mw) in enumerate(cts)
        _fix_mw!(model, "CT$(i)", mw)
    end
    _fix_mw!(model, "ST1", steam_mw(plant))
    solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED || return nothing
    base = IOM.get_model_base_power(IOM.get_optimization_container(model))
    return JuMP.value(_duct_var(model, DuctFiringPowerVariable)["ST1", 1]) * base
end

@testset "WECC split of Luna" begin
    split = wecc_split(WECC_LUNA)
    @test split.steam_ratio ≈ 0.627 atol = 1e-3
    @test split.steam_max ≈ 92.7 atol = 0.05
    @test first(split.ct_points)[1] ≈ 84.5 atol = 0.05
    @test last(split.ct_points)[2] ≈ 1721.0 atol = 0.5
    @test split.duct_mw == 59.5 && split.duct_heat_rate == 10.017
    quarter = wecc_split(LUNA_QUARTER)
    @test quarter.steam_ratio ≈ split.steam_ratio
    @test quarter.heat_max ≈ split.heat_max / 4
end

@testset "A two-tier steam turbine builds with its duct firing rows" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    plant = add_wecc_physical_block!(sys, LUNA_QUARTER)
    model = _duct_model(sys)
    c = IOM.get_optimization_container(model)
    @test axes(_duct_var(model, DuctFiringPowerVariable))[1] == ["ST1"]
    @test IOM.has_container_key(c, DuctFiringLimitConstraint, PSY.ThermalGen)
    # Duct fuel is priced at heat rate times fuel price, per MWh.
    d = _duct_var(model, DuctFiringPowerVariable)["ST1", 1]
    price = JuMP.coefficient(JuMP.objective_function(IOM.get_jump_model(c)), d)
    @test price ≈ 10.017 * WECC_LUNA.fuel_price * IOM.get_model_base_power(c)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "Duct firing covers only what CT heat cannot" begin
    full = LUNA_QUARTER.ct_mw
    duct = wecc_split(LUNA_QUARTER).duct_mw
    # Both CTs at full load make the unfired steam; anything above it is duct firing.
    @test _duct_mw(; cts = (full, full), steam_mw = p -> 2 * p.split.steam_max) ≈ 0.0 atol =
        1e-3
    @test _duct_mw(; cts = (full, full), steam_mw = p -> 2 * p.split.steam_max + 10.0) ≈
          10.0 atol =
        1e-3
    @test _duct_mw(; cts = (full, full), steam_mw = p -> 2 * (p.split.steam_max + duct)) ≈
          2 * duct atol = 1e-3
    # Below full CT load the heat falls short of the unfired maximum, so ducts fill the gap.
    low = first(wecc_split(LUNA_QUARTER).ct_points)[1]
    @test _duct_mw(; cts = (low, low), steam_mw = p -> 2 * p.split.steam_max) > 1.0
end

@testset "A 2x1 on one CT fires half its ducts" begin
    full = LUNA_QUARTER.ct_mw
    duct = wecc_split(LUNA_QUARTER).duct_mw
    one_ct = (; cts = (full, nothing), steam = :hrsg_loss)
    @test _duct_mw(; one_ct..., steam_mw = p -> p.split.steam_max + duct) ≈ duct atol = 1e-3
    @test _duct_mw(; one_ct..., steam_mw = p -> p.split.steam_max + duct + 2.0) === nothing
end

@testset "A heat loss per HRSG reproduces the ADS steam with one or two CTs" begin
    split = wecc_split(LUNA_QUARTER)
    low, full = first(split.ct_points)[1], last(split.ct_points)[1]
    # Free steam runs to the heat on hand; with no duct firing that is the ADS steam.
    for (cts, ads_steam) in (
        ((full, nothing), split.steam_max),
        ((low, nothing), split.steam_min),
        ((full, full), 2 * split.steam_max),
        ((low, low), 2 * split.steam_min),
    )
        @test _duct_mw(; cts, steam = :hrsg_loss, steam_mw = p -> ads_steam) ≈ 0.0 atol =
            0.05
        @test _duct_mw(; cts, steam = :hrsg_loss, steam_mw = p -> ads_steam + 1.0) ≈ 1.0 atol =
            0.05
    end
end

@testset "Two-tier validation" begin
    function rejected(change!, message)
        sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
        plant = add_wecc_physical_block!(sys, LUNA_QUARTER)
        change!(plant)
        err = try
            POM.validate_template(
                DecisionModel(_duct_template(), sys; optimizer = HiGHS_optimizer))
            nothing
        catch e
            e
        end
        return err isa IS.ConflictingInputsError &&
               occursin(message, sprint(showerror, err))
    end
    two_tier(; kw...) =
        PSY.TwoTierFuelCurve(; first_tier_curve = PSY.LinearCurve(9.0, 5.0),
            second_tier_curve = PSY.LinearCurve(10.0), tier_threshold = 40.0,
            fuel_units = u"MMBtu", second_tier_fuel_cost = 3.0, kw...)
    set_cost!(gen, cost) = PSY.set_operation_cost!(gen,
        PSY.ThermalGenerationCost(; variable_operation_cost = cost, fixed = 0.0,
            start_up = 0.0, shut_down = 0.0))
    @test rejected(
        p -> set_cost!(p.ca, two_tier(; first_tier_fuel_cost = 1.0)),
        "prices its first tier",
    )
    @test rejected(
        p -> set_cost!(p.ca, two_tier(; tier_threshold = 500.0)),
        "tier threshold",
    )
    @test rejected(p -> set_cost!(p.cts[1], two_tier()), "needs a FuelCurve")
    @test rejected(
        p -> set_cost!(
            p.ca,
            two_tier(;
                second_tier_curve = PSY.PiecewiseIncrementalCurve(
                    0.0,
                    [40.0, 50.0, 60.0],
                    [9.5, 10.5],
                )),
        ),
        "linear second tier")
end
