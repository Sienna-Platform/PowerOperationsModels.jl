# The DualFuelCurve fixtures of the InfrastructureSystems tests, with MW and fuel scaled by
# 0.15 so they fit unit "Alta" of c_sys5_uc (20 to 40 MW). Heat rates stay.
const DUAL_FUEL_SCALE = 0.15

stacked_curve() = PSY.DualFuelCurve(;
    first_fuel_curve = PSY.LinearCurve(9.89, DUAL_FUEL_SCALE * 113.0),
    second_fuel_curve = PSY.PiecewiseIncrementalCurve(
        nothing, DUAL_FUEL_SCALE .* [185.4, 304.4], [10.017]),
    fuel_units = u"MMBtu", second_fuel_cost = 3.44)

blended_curve(; share = 0.3, first_price = 3.0, second_price = 5.0) = PSY.DualFuelCurve(;
    first_fuel_curve = PSY.PiecewisePointCurve(
        [DUAL_FUEL_SCALE .* p for p in ((100.0, 900.0), (200.0, 1700.0), (300.0, 2700.0))]),
    second_fuel_curve = PSY.PiecewisePointCurve(
        [DUAL_FUEL_SCALE .* p for p in ((100.0, 950.0), (250.0, 2225.0), (300.0, 2725.0))]),
    fuel_units = u"MMBtu", first_fuel_cost = first_price,
    second_fuel_cost = second_price,
    second_fuel_share = share)

function set_unit_variable_cost!(sys::PSY.System, name::String, curve)
    gen = PSY.get_component(PSY.ThermalGen, sys, name)
    PSY.set_variable_operation_cost!(PSY.get_operation_cost(gen), curve)
    return gen
end

# c_sys5_uc with the quarter-size Luna block, after `change!(sys, plant)`.
function _dual_fuel_system(change! = (sys, plant) -> nothing)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    plant = add_wecc_physical_block!(sys, LUNA_QUARTER)
    change!(sys, plant)
    return sys
end

# Warnings off: copper plate leaves the system's lines unmodeled.
_validate_dual_fuel(sys; plant = true) =
    Logging.with_logger(Logging.ConsoleLogger(stderr, Logging.Error)) do
        POM.validate_template(
            DecisionModel(_cc_template(; plant), sys; optimizer = HiGHS_optimizer))
    end

function rejects_template(change!, messages::String...; plant = true)
    sys = _dual_fuel_system(change!)
    err = try
        _validate_dual_fuel(sys; plant)
        nothing
    catch e
        e
    end
    return err isa IS.ConflictingInputsError &&
           all(m -> occursin(m, sprint(showerror, err)), messages)
end
