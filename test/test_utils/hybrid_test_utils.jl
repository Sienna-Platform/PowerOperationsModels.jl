# Test fixtures for HybridSystem device tests.
# Ports HybridSystemsSimulations.jl/test/test_utils/function_utils.jl
# (modify_ren_curtailment_cost! and add_hybrid_to_chuhsi_bus!) to PSY 5.3.

"""
Set a flat curtailment penalty on every RenewableDispatch in `sys`. PSY 5.x
RenewableGenerationCost wraps a CostCurve(LinearCurve(...)).
"""
function modify_ren_curtailment_cost!(sys::PSY.System; cost = 15.0)
    for ren in PSY.get_components(PSY.RenewableDispatch, sys)
        PSY.set_operation_cost!(
            ren,
            PSY.RenewableGenerationCost(PSY.CostCurve(PSY.LinearCurve(cost))),
        )
    end
    return
end

"""
Build an EnergyReservoirStorage device sized for hybrid testing. PSY 5.x
constructor; default StorageCost(nothing) is fine for our test (no storage costs
contribute to the objective).
"""
function _build_hybrid_storage(bus::PSY.ACBus, energy_capacity, rating, eff_in, eff_out)
    name = string(PSY.get_number(bus)) * "_BATTERY"
    return PSY.EnergyReservoirStorage(;
        name = name,
        available = true,
        bus = bus,
        prime_mover_type = PSY.PrimeMovers.BA,
        storage_technology_type = PSY.StorageTech.OTHER_CHEM,
        storage_capacity = energy_capacity,
        storage_level_limits = (min = 0.05, max = 1.0),
        initial_storage_capacity_level = 0.5,
        rating = rating,
        active_power = 0.0,
        input_active_power_limits = (min = 0.0, max = rating),
        output_active_power_limits = (min = 0.0, max = rating),
        efficiency = (in = eff_in, out = eff_out),
        reactive_power = 0.0,
        reactive_power_limits = nothing,
        base_power = 100.0,
    )
end

"""
Add a HybridSystem to bus "Chuhsi" of an RTS-GMLC system, composed of:
  - thermal subcomponent: existing "318_CC_1" generator
  - renewable subcomponent: existing "317_WIND_1" generator
  - electric load subcomponent: existing "Clark" load
  - storage subcomponent: a fresh EnergyReservoirStorage built on bus Chuhsi

Mirrors HSS test_utils/function_utils.jl:add_hybrid_to_chuhsi_bus!.
"""
function add_hybrid_to_chuhsi_bus!(sys::PSY.System)
    bus = PSY.get_component(PSY.ACBus, sys, "Chuhsi")
    bus === nothing && error("add_hybrid_to_chuhsi_bus!: bus 'Chuhsi' not found in system")
    bat = _build_hybrid_storage(bus, 4.0, 2.0, 0.93, 0.93)

    # Subcomponents borrowed from adjacent existing components in RTS-GMLC.
    renewable = PSY.get_component(PSY.StaticInjection, sys, "317_WIND_1")
    thermal = PSY.get_component(PSY.StaticInjection, sys, "318_CC_1")
    load = PSY.get_component(PSY.PowerLoad, sys, "Clark")
    for (name, cmp) in (("317_WIND_1", renewable), ("318_CC_1", thermal), ("Clark", load))
        cmp === nothing && error("add_hybrid_to_chuhsi_bus!: component '$name' not found")
    end

    hybrid_name = string(PSY.get_number(bus)) * "_Hybrid"
    hybrid = PSY.HybridSystem(;
        name = hybrid_name,
        available = true,
        status = true,
        bus = bus,
        active_power = 1.0,
        reactive_power = 0.0,
        base_power = 100.0,
        operation_cost = PSY.MarketBidCost(nothing),
        thermal_unit = thermal,
        electric_load = load,
        storage = bat,
        renewable_unit = renewable,
        interconnection_impedance = 0.0 + 0.0im,
        interconnection_rating = nothing,
        input_active_power_limits = (min = 0.0, max = 10.0),
        output_active_power_limits = (min = 0.0, max = 10.0),
        reactive_power_limits = nothing,
    )
    PSY.add_component!(sys, hybrid)
    return hybrid
end
