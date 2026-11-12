# A combined cycle plant from WECC data, modeled two ways on a test system: as the logical
# units of the 2036 ADS production cost case, and as the CTs and steam turbine of the power
# flow case. The physical units follow the WECC split: each ADS chunk (one CT plus its share
# of the steam turbine) gives its unfired fuel to the CT, read at CT output `x / (1 + f)`.

# Luna Energy Facility, a 2x1 with duct firing. Each chunk: minimum output and fuel, then
# incremental blocks (MW, MMBtu/MWh). `ct_mw` is the PSS/E capacity of one CT.
const WECC_LUNA = (
    chunks = 2,
    min_mw = 137.5,
    min_fuel = 1085.187,
    blocks = [(34.333, 5.266), (34.334, 6.173), (34.333, 7.08), (59.5, 10.017)],
    ct_mw = 147.8,
    start_up = 35212.95,
    fuel_price = 3.44,
    eta = 0.80,
)
"The plant with every MW and fuel rate times `k`; heat rates and prices stay."
wecc_scale(plant, k::Real) = merge(
    plant,
    (;
        min_mw = k * plant.min_mw,
        min_fuel = k * plant.min_fuel,
        blocks = [(k * w, h) for (w, h) in plant.blocks],
        ct_mw = k * plant.ct_mw,
        start_up = k * plant.start_up,
    ),
)
# A trailing block this much steeper than the one before it is duct firing.
# The steam turbine's minimum, as a share of the steam one CT gives at its own minimum. Below
# one because the last-segment exhaust line reads less heat at CT minimum than the curve.
const WECC_STEAM_MIN_SHARE = 0.75
const WECC_DUCT_STEP = 1.25

"The WECC split of one chunk: the CT curve, the steam it implies and its duct firing."
function wecc_split(plant)
    blocks = plant.blocks
    # Position in `2:n` of the last steep block, which is the index of the block before it.
    last_unfired =
        findlast(i -> blocks[i][2] >= WECC_DUCT_STEP * blocks[i - 1][2], 2:length(blocks))
    unfired = isnothing(last_unfired) ? blocks : blocks[1:last_unfired]
    duct = isnothing(last_unfired) ? eltype(blocks)[] : blocks[(last_unfired + 1):end]
    unfired_max = plant.min_mw + sum(first, unfired)
    f = (unfired_max - plant.ct_mw) / plant.ct_mw
    ct_points = [(plant.min_mw / (1 + f), plant.min_fuel)]
    for (width, heat_rate) in unfired
        x, fuel = last(ct_points)
        push!(ct_points, (x + width / (1 + f), fuel + width * heat_rate))
    end
    duct_mw = sum(first, duct; init = 0.0)
    kappa = POM.electrical_heat_equivalent(u"MMBtu")
    recovered(point) = plant.eta * (point[2] - kappa * point[1])
    return (;
        ct_points,
        steam_ratio = f,
        steam_min = f * first(ct_points)[1],
        steam_max = f * last(ct_points)[1],
        heat_min = recovered(first(ct_points)),
        heat_max = recovered(last(ct_points)),
        duct_mw,
        duct_heat_rate = duct_mw > 0 ? sum(w * h for (w, h) in duct) / duct_mw : 0.0,
    )
end

"""
The steam line `heat = a * power + b` and the heat loss per HRSG, in MMBtu/h, under one of:

  - `:chord`: through one CT at minimum and every CT at full load,
  - `:zero`: through zero and every CT at full load,
  - `:hrsg_loss`: through zero, with the offset moved to each HRSG. Slope and loss are set
    against the CT's last-segment exhaust line, which makes steam `f` times CT output at
    every load, as ADS has it.
"""
function wecc_steam_line(plant, split, kind::Symbol)
    n = plant.chunks
    if kind == :chord
        a = (n * split.heat_max - split.heat_min) / (n * split.steam_max - split.steam_min)
        return (a = a, b = split.heat_min - a * split.steam_min, loss = 0.0)
    elseif kind == :zero
        return (a = split.heat_max / split.steam_max, b = 0.0, loss = 0.0)
    elseif kind == :hrsg_loss
        (x1, f1), (x2, f2) = split.ct_points[(end - 1):end]
        slope = (f2 - f1) / (x2 - x1)
        kappa = POM.electrical_heat_equivalent(u"MMBtu")
        a = plant.eta * (slope - kappa) / split.steam_ratio
        return (a = a, b = 0.0, loss = plant.eta * (f2 - slope * x2))
    end
    throw(ArgumentError("unknown steam line $(kind)"))
end

function _add_wecc_thermal!(
    sys,
    name,
    prime_mover,
    limits,
    variable_cost,
    start_up;
    ext = Dict{String, Any}(),
)
    gen = PSY.ThermalStandard(;
        name = name,
        available = true,
        status = PSY.OperationalStates.ONLINE,
        bus = PSY.get_component(PSY.ACBus, sys, "nodeA"),
        active_power = limits.min,
        reactive_power = 0.0,
        rating = limits.max,
        active_power_limits = limits,
        reactive_power_limits = (min = -0.5 * limits.max, max = 0.5 * limits.max),
        ramp_limits = (up = limits.max, down = limits.max),
        time_limits = nothing,
        operation_cost = PSY.ThermalGenerationCost(;
            variable_operation_cost = variable_cost,
            fixed = 0.0,
            start_up = start_up,
            shut_down = 0.0,
        ),
        base_power = 100.0,
        prime_mover_type = prime_mover,
        fuel = PSY.ThermalFuels.NATURAL_GAS,
        input_basis = u"NU",
        ext = ext,
    )
    PSY.add_component!(sys, gen)
    return gen
end

"The plant as ADS has it: one thermal unit per chunk, `CC_1a`, `CC_1b`, and so on."
function add_wecc_logical_units!(sys::PSY.System, plant = WECC_LUNA)
    x = cumsum(vcat(plant.min_mw, first.(plant.blocks)))
    curve = PSY.PiecewiseIncrementalCurve(plant.min_fuel, x, last.(plant.blocks))
    return [
        _add_wecc_thermal!(sys, "CC_1$(letter)", PSY.PrimeMovers.CC,
            (min = first(x), max = last(x)),
            PSY.FuelCurve(curve, u"MMBtu", plant.fuel_price), plant.start_up)
        for letter in ('a':'z')[1:(plant.chunks)]
    ]
end

"""
The plant as the power flow case has it: one CT per chunk and one steam turbine that carries
a `TwoTierFuelCurve`, recovered heat first and duct firing above it. Returns
`(; block, cts, ca, split, line)`.
"""
function add_wecc_physical_block!(
    sys::PSY.System,
    plant = WECC_LUNA;
    steam::Symbol = :chord,
)
    split = wecc_split(plant)
    line = wecc_steam_line(plant, split, steam)
    n = plant.chunks
    cts = [
        _add_wecc_thermal!(sys, "CT$(i)", PSY.PrimeMovers.CT,
            (min = first(split.ct_points)[1], max = last(split.ct_points)[1]),
            PSY.FuelCurve(
                PSY.PiecewisePointCurve(split.ct_points),
                u"MMBtu",
                plant.fuel_price,
            ),
            plant.start_up; ext = Dict{String, Any}("hrsg_heat_loss" => line.loss))
        for i in 1:n
    ]
    threshold = n * split.steam_max
    ca = _add_wecc_thermal!(sys, "ST1", PSY.PrimeMovers.CA,
        (min = WECC_STEAM_MIN_SHARE * split.steam_min, max = threshold + n * split.duct_mw),
        PSY.TwoTierFuelCurve(;
            first_tier_curve = PSY.LinearCurve(line.a, line.b),
            second_tier_curve = PSY.LinearCurve(split.duct_heat_rate),
            tier_threshold = threshold,
            fuel_units = u"MMBtu",
            second_tier_fuel_cost = plant.fuel_price,
        ), 0.0)
    block = PSY.CombinedCycleBlock(;
        name = "cc",
        configuration = PSY.CombinedCycleConfiguration.SeparateShaftCombustionSteam,
        heat_recovery_to_steam_factor = plant.eta,
    )
    for (i, ct) in enumerate(cts)
        PSY.add_supplemental_attribute!(sys, ct, block; hrsg_number = i)
        PSY.add_supplemental_attribute!(sys, ca, block; hrsg_number = i)
    end
    return (; block, cts, ca, split, line)
end
