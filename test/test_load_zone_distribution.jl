const LZ_ATTRIBUTES = Dict{String, Any}("load_zone_distribution" => true)

# A `distribution_factor` matrix: column j is bus `labels[j]`, with one factor per step
# (`columns[j]` a vector) or a constant (`columns[j]` a number), on the forecast parameters
# of the system's load forecasts unless `resolution` is given.
_factor_column(c::Real, horizon) = fill(Float64(c), horizon)
_factor_column(c::AbstractVector, _) = Vector{Float64}(c)

_load_forecast(sys) = PSY.get_time_series(
    PSY.Deterministic, first(PSY.get_components(PSY.PowerLoad, sys)), "max_active_power",
)
_factor_horizon(sys) = length(first(values(PSY.get_data(_load_forecast(sys)))))

function _factor_matrix(sys, labels, columns; resolution = nothing, axis = "bus")
    existing = _load_forecast(sys)
    horizon = _factor_horizon(sys)
    window = hcat([_factor_column(c, horizon) for c in columns]...)
    data = SortedDict(ts => copy(window) for ts in keys(PSY.get_data(existing)))
    return PSY.Deterministic(;
        name = POM.DISTRIBUTION_FACTOR_TS_NAME,
        data = data,
        resolution = something(resolution, PSY.get_resolution(existing)),
        value_axes = [IS.TimeSeriesAxis(axis, labels)],
    )
end

_add_factor_matrix!(sys, location, labels, columns; kwargs...) =
    PSY.add_time_series!(sys, location, _factor_matrix(sys, labels, columns; kwargs...))

# The zonal load as a fraction of the zone's peak, one value per step.
_zone_load_fraction(horizon) = [0.3 + 0.1 * (t % 4) for t in 1:horizon]

function _add_zone_load!(sys, zone)
    existing = _load_forecast(sys)
    fraction = _zone_load_fraction(_factor_horizon(sys))
    data = SortedDict(ts => copy(fraction) for ts in keys(PSY.get_data(existing)))
    PSY.add_time_series!(
        sys,
        zone,
        PSY.Deterministic(;
            name = POM.LOAD_ZONE_LOAD_TS_NAME,
            data = data,
            resolution = PSY.get_resolution(existing),
        ),
    )
    return fraction
end

# c_sys5_uc with a two-bus load zone "LZ1" carrying a zonal load series and constant 0.6/0.4
# factors in one matrix owned by the zone.
function _build_zone_system(; with_factors = true)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    zone = PSY.LoadZone(;
        name = "LZ1",
        peak_active_power = 2.0,
        peak_reactive_power = 3.0,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, zone)
    buses = sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number)
    zone_buses = buses[1:2]
    for b in zone_buses
        PSY.set_load_zone!(b, zone)
    end
    _add_zone_load!(sys, zone)
    if with_factors
        _add_factor_matrix!(sys, zone, PSY.get_number.(zone_buses), [0.6, 0.4])
    end
    return sys, zone, zone_buses
end

function _build_lz_model(sys, network_model; solve = false)
    template = get_thermal_dispatch_template_network(network_model)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    if solve
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    end
    return model
end

function _build_factor_model(sys, network_model = nothing)
    if network_model === nothing
        network_model = NetworkModel(PTDFNetworkModel; attributes = LZ_ATTRIBUTES)
    end
    model = _build_lz_model(sys, network_model)
    return get_optimization_container(model), get_network_model(IOM.get_template(model))
end

# The change of each row of `T`'s balance when the zonal load is on, for `network`.
function _zone_load_delta(sys, network, T; solve = false, kwargs...)
    off = _build_lz_model(sys, NetworkModel(network; kwargs...))
    on = _build_lz_model(
        sys, NetworkModel(network; attributes = LZ_ATTRIBUTES, kwargs...); solve,
    )
    e_off = IOM.get_expression(get_optimization_container(off), ActivePowerBalance, T)
    e_on = IOM.get_expression(get_optimization_container(on), ActivePowerBalance, T)
    return Dict(
        (k, t) => JuMP.constant(e_on[k, t]) - JuMP.constant(e_off[k, t]) for
        k in axes(e_on)[1], t in axes(e_on)[2]
    )
end

_steps(delta) = sort!(unique(last.(collect(keys(delta)))))

# Buses numbered up to `last_in_first` sit in area "LZ_A1"; the rest sit in "LZ_A2".
function _set_two_areas!(sys, last_in_first)
    areas = [
        PSY.Area(; name = "LZ_A$(i)", peak_active_power = 0.0,
            peak_reactive_power = 0.0,
            input_basis = u"CU")
        for i in 1:2
    ]
    PSY.add_components!(sys, areas)
    for b in PSY.get_components(PSY.ACBus, sys)
        if PSY.get_number(b) <= last_in_first
            PSY.set_area!(b, areas[1])
        else
            PSY.set_area!(b, areas[2])
        end
    end
    return
end

@testset "Load zone distribution core types" begin
    @test DistributionFactorParameter <: IOM.LeftHandSideTimeSeriesParameter
    @test POM.DISTRIBUTION_FACTOR_TS_NAME == "distribution_factor"
    @test POM.LOAD_ZONE_DISTRIBUTION_ATTRIBUTE == "load_zone_distribution"
end

@testset "get_distribution_factors" begin
    sys, zone, zone_buses = _build_zone_system()
    n1 = PSY.get_number(zone_buses[1])
    n2 = PSY.get_number(zone_buses[2])
    zone2 = PSY.LoadZone(;
        name = "LZ2",
        peak_active_power = 5.0,
        peak_reactive_power = 1.0,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, zone2)
    buses = sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number)
    b3, b4 = buses[3], buses[4]
    PSY.set_load_zone!(b3, zone2)
    PSY.set_load_zone!(b4, zone2)
    _add_zone_load!(sys, zone2)
    _add_factor_matrix!(sys, zone2, [PSY.get_number(b4)], [1.0])
    container, network_model = _build_factor_model(sys)
    time_steps = get_time_steps(container)
    t1 = first(time_steps)

    factors = get_distribution_factors(container, sys, zone)
    @test sort(collect(axes(factors)[1])) == sort([n1, n2])
    @test all(factors[n1, t] == 0.6 for t in time_steps)
    @test all(factors[n2, t] == 0.4 for t in time_steps)

    # The series labels are the buses that carry factors: a member without a column gets none.
    zf = get_distribution_factors(container, sys, zone2)
    @test collect(axes(zf)[1]) == [PSY.get_number(b4)]
    @test zf[PSY.get_number(b4), t1] == 1.0

    @test POM.assert_numeric_distribution_factors(container) === nothing
end

@testset "get_member_buses drops unavailable members" begin
    sys, zone, zone_buses = _build_zone_system()
    PSY.set_available!(zone_buses[1], false)
    @test POM.get_member_buses(sys, zone) == [zone_buses[2]]
end

@testset "Hourly factors land on each time step" begin
    sys, zone, zone_buses = _build_zone_system(; with_factors = false)
    n1, n2 = PSY.get_number.(zone_buses)
    first_bus = [0.1 * (t % 5) for t in 1:_factor_horizon(sys)]
    _add_factor_matrix!(sys, zone, [n1, n2], [first_bus, 1.0 .- first_bus])
    container, network_model = _build_factor_model(sys)
    zf = get_distribution_factors(container, sys, zone)
    @test all(zf[n1, t] ≈ first_bus[t] for t in get_time_steps(container))
    @test all(zf[n2, t] ≈ 1.0 - first_bus[t] for t in get_time_steps(container))
end

@testset "A nonzero share on an unavailable member is an error" begin
    sys, zone, zone_buses = _build_zone_system()
    # After the build: the network matrices reject an unavailable bus with live lines.
    container, network_model = _build_factor_model(sys)
    PSY.set_available!(zone_buses[1], false)
    @test_throws "unavailable bus $(PSY.get_number(zone_buses[1]))" get_distribution_factors(
        container, sys, zone,
    )
end

@testset "A factor column for a bus outside the zone is an error" begin
    sys, _, _ = _build_zone_system()
    container, _ = _build_factor_model(sys)
    buses = sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number)
    # A zone's members are the buses that name it; bus 4 names no zone.
    zone = PSY.LoadZone(;
        name = "LZ_PART",
        peak_active_power = 1.0,
        peak_reactive_power = 0.0,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, zone)
    PSY.set_load_zone!(buses[3], zone)
    _add_factor_matrix!(sys, zone, PSY.get_number.(buses[3:4]), [0.5, 0.5])
    @test_throws ArgumentError POM._factor_bus_labels(
        container,
        zone,
        POM._buses_by_number(sys),
    )
end

@testset "Factor series must be one [time step, bus] matrix" begin
    sys, zone, zone_buses = _build_zone_system()
    container, _ = _build_factor_model(sys)
    n1, n2 = PSY.get_number.(zone_buses)
    # IS rejects repeated labels when the series is built, so POM never sees them.
    @test_throws ArgumentError _factor_matrix(sys, [n1, n1], [0.5, 0.5])
    zone2 = PSY.LoadZone(;
        name = "LZ_AXES",
        peak_active_power = 1.0,
        peak_reactive_power = 0.0,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, zone2)
    _add_factor_matrix!(sys, zone2, ["a", "b"], [0.5, 0.5])
    @test_throws ArgumentError POM._factor_bus_labels(
        container,
        zone2,
        POM._buses_by_number(sys),
    )
    zone3 = PSY.LoadZone(;
        name = "LZ_NODE",
        peak_active_power = 1.0,
        peak_reactive_power = 0.0,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, zone3)
    _add_factor_matrix!(sys, zone3, [n1, n2], [0.5, 0.5]; axis = "node")
    @test_throws ArgumentError POM._factor_bus_labels(
        container,
        zone3,
        POM._buses_by_number(sys),
    )
    # A second series on the same zone is ambiguous.
    PSY.add_time_series!(
        sys, zone, _factor_matrix(sys, [n1, n2], [0.1, 0.9]);
        features = Dict("year" => 2030),
    )
    @test_throws ArgumentError POM._factor_bus_labels(
        container,
        zone,
        POM._buses_by_number(sys),
    )
end

@testset "A factor window at another resolution is an error" begin
    sys, zone, zone_buses = _build_zone_system()
    container, _ = _build_factor_model(sys)
    zone2 = PSY.LoadZone(;
        name = "LZ_RES",
        peak_active_power = 1.0,
        peak_reactive_power = 0.0,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, zone2)
    _add_factor_matrix!(
        sys, zone2, PSY.get_number.(zone_buses), [0.5, 0.5]; resolution = Minute(30),
    )
    @test_throws IS.ConflictingInputsError POM._factor_bus_labels(
        container,
        zone2,
        POM._buses_by_number(sys),
    )
end

@testset "A same-name factor series of another resolution is not the model's series" begin
    sys, zone, zone_buses = _build_zone_system()
    container, _ = _build_factor_model(sys)
    numbers = PSY.get_number.(zone_buses)
    PSY.add_time_series!(
        sys, zone, _factor_matrix(sys, numbers, [0.1, 0.9]; resolution = Minute(30));
        features = Dict("year" => 2030),
    )
    ts_type = POM.get_default_time_series_type(container)
    @test POM.has_distribution_factors(container, zone, ts_type)
    @test POM._factor_bus_labels(container, zone, POM._buses_by_number(sys)) ==
          sort(numbers)
end

# `_build_zone_system` plus bus 99, a zone member on a radial line from the zone's first bus;
# the factors are 0.5, 0.4 and 0.1.
function _build_leaf_zone_system()
    sys, zone, zone_buses = _build_zone_system(; with_factors = false)
    leaf = PSY.ACBus(;
        input_basis = u"CU",
        number = 99, name = "leaf", available = true, bustype = PSY.ACBusTypes.PQ,
        angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = PSY.get_base_voltage(zone_buses[1]),
        area = PSY.get_area(zone_buses[1]), load_zone = zone,
    )
    PSY.add_component!(sys, leaf)
    arc = PSY.Arc(; from = zone_buses[1], to = leaf)
    PSY.add_component!(sys, arc)
    line = PSY.Line(;
        name = "leaf_line", available = true, active_power_flow = 0.0,
        reactive_power_flow = 0.0, arc = arc,
        r = 0.001, x = 0.01, b = (from = 0.0, to = 0.0), rating = 1.0,
        angle_limits = (min = -1.0, max = 1.0), input_basis = u"CU",
    )
    PSY.add_component!(sys, line)
    _add_factor_matrix!(sys, zone, [PSY.get_number.(zone_buses); 99], [0.5, 0.4, 0.1])
    return sys, zone, zone_buses, leaf
end

const RADIAL = SystemNetworkSource(PNM.RadialReduction())

@testset "A reduced member bus's share lands on its retained bus" begin
    sys, zone, zone_buses, leaf = _build_leaf_zone_system()
    n1, n2 = PSY.get_number.(zone_buses)
    container, network_model = _build_factor_model(
        sys,
        NetworkModel(PTDFNetworkModel; network_source = RADIAL, attributes = LZ_ATTRIBUTES),
    )
    @test PNM.get_mapped_bus_number(get_network_reduction(network_model), leaf) == n1
    factors = get_distribution_factors(container, sys, zone)
    @test collect(axes(factors)[1]) == [n1, n2, 99]
    @test all(factors[99, t] ≈ 0.1 for t in get_time_steps(container))
    load =
        -PSY.get_peak_active_power(zone, u"SU") .* _zone_load_fraction(_factor_horizon(sys))
    delta = _zone_load_delta(sys, PTDFNetworkModel, PSY.ACBus; network_source = RADIAL)
    @test all(delta[(n1, t)] ≈ 0.6 * load[t] for t in _steps(delta))
    @test all(delta[(n2, t)] ≈ 0.4 * load[t] for t in _steps(delta))
end

# `_build_zone_system` plus bus 99, a zone member between buses 1 and 3 (no line joins them
# directly) on two lines and with no injection, so a degree-two reduction can remove it. With
# `factor_on_mid`, the factors are 0.5, 0.4 and 0.1; without, 0.6 and 0.4 on buses 1 and 2.
function _build_mid_bus_zone_system(; factor_on_mid::Bool)
    sys, zone, zone_buses = _build_zone_system(; with_factors = false)
    first_bus = zone_buses[1]
    far_bus = PSY.get_bus(sys, 3)
    mid = PSY.ACBus(;
        input_basis = u"CU",
        number = 99, name = "mid", available = true, bustype = PSY.ACBusTypes.PQ,
        angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = PSY.get_base_voltage(first_bus),
        area = PSY.get_area(first_bus), load_zone = zone,
    )
    PSY.add_component!(sys, mid)
    for (name, from, to) in (("mid_a", first_bus, mid), ("mid_b", mid, far_bus))
        arc = PSY.Arc(; from = from, to = to)
        PSY.add_component!(sys, arc)
        line = PSY.Line(;
            name = name, available = true, active_power_flow = 0.0,
            reactive_power_flow = 0.0, arc = arc,
            r = 0.001, x = 0.01, b = (from = 0.0, to = 0.0), rating = 1.0,
            angle_limits = (min = -1.0, max = 1.0), input_basis = u"CU",
        )
        PSY.add_component!(sys, line)
    end
    if factor_on_mid
        _add_factor_matrix!(sys, zone, [PSY.get_number.(zone_buses); 99], [0.5, 0.4, 0.1])
    else
        _add_factor_matrix!(sys, zone, PSY.get_number.(zone_buses), [0.6, 0.4])
    end
    return sys, zone
end

const DEGREE_TWO = SystemNetworkSource(PNM.DegreeTwoReduction())

@testset "A degree-two reduction keeps a bus with a distribution factor" begin
    sys, zone = _build_mid_bus_zone_system(; factor_on_mid = true)
    container, network_model = _build_factor_model(
        sys,
        NetworkModel(
            PTDFNetworkModel; network_source = DEGREE_TWO, attributes = LZ_ATTRIBUTES,
        ),
    )
    @test 99 ∉ PNM.get_removed_buses(get_network_reduction(network_model))
    balance = IOM.get_expression(container, ActivePowerBalance, PSY.ACBus)
    load =
        -PSY.get_peak_active_power(zone, u"SU") .* _zone_load_fraction(_factor_horizon(sys))
    @test all(
        JuMP.constant(balance[99, t]) ≈ 0.1 * load[t] for t in get_time_steps(container)
    )

    sys, _ = _build_mid_bus_zone_system(; factor_on_mid = false)
    _, network_model = _build_factor_model(
        sys,
        NetworkModel(
            PTDFNetworkModel; network_source = DEGREE_TWO, attributes = LZ_ATTRIBUTES,
        ),
    )
    @test 99 in PNM.get_removed_buses(get_network_reduction(network_model))
end

@testset "AreaPTDF: a reduced member bus's share lands in its own area" begin
    sys, zone, _, leaf = _build_leaf_zone_system()
    _set_two_areas!(sys, 5)
    @test PSY.get_name(PSY.get_area(leaf)) == "LZ_A2"
    load =
        -PSY.get_peak_active_power(zone, u"SU") .* _zone_load_fraction(_factor_horizon(sys))
    delta = _zone_load_delta(sys, AreaPTDFNetworkModel, PSY.Area; network_source = RADIAL)
    @test all(delta[("LZ_A1", t)] ≈ 0.9 * load[t] for t in _steps(delta))
    @test all(delta[("LZ_A2", t)] ≈ 0.1 * load[t] for t in _steps(delta))
end

@testset "Factors reach the model through DistributionFactorParameter" begin
    sys, _, _ = _build_zone_system()
    container, _ = _build_factor_model(sys)
    key = IOM.ParameterKey(DistributionFactorParameter, PSY.LoadZone)
    pc = IOM.get_parameter(container, key)
    @test eltype(IOM.get_parameter_array(pc)) == Float64
    values = IOM.get_lhs_parameter_values(container, key, "LZ1")
    @test size(values, 1) == 2
    @test all(values[:, t] == [0.6, 0.4] for t in get_time_steps(container))
end

# Balance rows of an expression as numbers, for a build with the zonal load on or off.
function _balance_constants(container, T, name_axis)
    expr = IOM.get_expression(container, ActivePowerBalance, T)
    ts = get_time_steps(container)
    return Dict((n, t) => JuMP.constant(expr[n, t]) for n in name_axis, t in ts)
end

@testset "PTDF: the zonal load enters the nodal balance as -factor * peak * load" begin
    sys, zone, zone_buses = _build_zone_system()
    n1, n2 = PSY.get_number.(zone_buses)
    peak = PSY.get_peak_active_power(zone, u"SU")
    fraction = _zone_load_fraction(_factor_horizon(sys))

    off = _build_lz_model(sys, NetworkModel(PTDFNetworkModel))
    on = _build_lz_model(
        sys, NetworkModel(PTDFNetworkModel; attributes = LZ_ATTRIBUTES); solve = true,
    )
    c_off = get_optimization_container(off)
    c_on = get_optimization_container(on)
    nodal_off = IOM.get_expression(c_off, ActivePowerBalance, PSY.ACBus)
    nodal_on = IOM.get_expression(c_on, ActivePowerBalance, PSY.ACBus)
    for t in get_time_steps(c_on)
        for (n, factor) in ((n1, 0.6), (n2, 0.4))
            @test JuMP.constant(nodal_on[n, t]) - JuMP.constant(nodal_off[n, t]) ≈
                  -factor * peak * fraction[t]
        end
        for n in axes(nodal_on)[1]
            n in (n1, n2) && continue
            @test JuMP.constant(nodal_on[n, t]) == JuMP.constant(nodal_off[n, t])
        end
    end

    # Independent reference: PTDF times the realized nodal injections reproduces every flow.
    ptdf = PNM.PTDF(sys)
    flows = IOM.get_expression(c_on, PTDFBranchFlow, PSY.Line)
    bus_numbers = collect(axes(nodal_on)[1])
    t1 = first(get_time_steps(c_on))
    injections = [JuMP.value(nodal_on[n, t1]) for n in bus_numbers]
    for lname in axes(flows)[1]
        expected = sum(ptdf[lname, n] * injections[i] for (i, n) in enumerate(bus_numbers))
        @test isapprox(JuMP.value(flows[lname, t1]), expected; atol = 1e-6)
    end
end

@testset "CopperPlate: the system balance gets the zonal total, with no factors" begin
    for with_factors in (true, false)
        sys, zone, _ = _build_zone_system(; with_factors = with_factors)
        peak = PSY.get_peak_active_power(zone, u"SU")
        fraction = _zone_load_fraction(_factor_horizon(sys))
        off = _build_lz_model(sys, NetworkModel(CopperPlateNetworkModel))
        on = _build_lz_model(
            sys, NetworkModel(CopperPlateNetworkModel; attributes = LZ_ATTRIBUTES),
        )
        c_on = get_optimization_container(on)
        sys_off = IOM.get_expression(
            get_optimization_container(off), ActivePowerBalance, PSY.System,
        )
        sys_on = IOM.get_expression(c_on, ActivePowerBalance, PSY.System)
        rows = axes(sys_on)[1]
        for t in get_time_steps(c_on)
            @test sum(
                JuMP.constant(sys_on[k, t]) - JuMP.constant(sys_off[k, t]) for k in rows
            ) ≈ -peak * fraction[t]
        end
    end
end

@testset "Attribute off: the zonal load is ignored" begin
    sys, _, _ = _build_zone_system(; with_factors = false)
    base = _build_lz_model(sys, NetworkModel(PTDFNetworkModel))
    explicit_off = _build_lz_model(
        sys,
        NetworkModel(
            PTDFNetworkModel;
            attributes = Dict{String, Any}("load_zone_distribution" => false),
        ),
    )
    @test !IOM.has_container_key(
        get_optimization_container(base),
        ActivePowerTimeSeriesParameter,
        PSY.LoadZone,
    )
    nodal_base =
        IOM.get_expression(get_optimization_container(base), ActivePowerBalance, PSY.ACBus)
    nodal_off = IOM.get_expression(
        get_optimization_container(explicit_off), ActivePowerBalance, PSY.ACBus,
    )
    ts = get_time_steps(get_optimization_container(base))
    @test all(
        JuMP.constant(nodal_base[n, t]) == JuMP.constant(nodal_off[n, t]) for
        n in axes(nodal_base)[1], t in ts
    )
end

@testset "A zone without a load series is skipped" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    zone = PSY.LoadZone(;
        name = "LZ_EMPTY",
        peak_active_power = 1.0,
        peak_reactive_power = 0.0,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, zone)
    model = _build_lz_model(sys, NetworkModel(PTDFNetworkModel; attributes = LZ_ATTRIBUTES))
    @test !IOM.has_container_key(
        get_optimization_container(model),
        ActivePowerTimeSeriesParameter,
        PSY.LoadZone,
    )
end

function _build_failure_log(sys, network_model)
    template = get_thermal_dispatch_template_network(network_model)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED
    return read(joinpath(output_dir, "operation_problem.log"), String)
end

@testset "A zone with a load but no factors is an error" begin
    sys, _, _ = _build_zone_system(; with_factors = false)
    log = _build_failure_log(
        sys, NetworkModel(PTDFNetworkModel; attributes = LZ_ATTRIBUTES),
    )
    @test occursin("Load zone LZ1 has no distribution_factor column", log)
end

@testset "Factors that do not sum to one are an error" begin
    sys, zone, zone_buses = _build_zone_system(; with_factors = false)
    _add_factor_matrix!(sys, zone, PSY.get_number.(zone_buses), [0.5, 0.3])
    log = _build_failure_log(
        sys, NetworkModel(PTDFNetworkModel; attributes = LZ_ATTRIBUTES),
    )
    @test occursin("Load zone LZ1: the distribution_factor values sum to 0.8", log)
    # Rounded data within the tolerance passes.
    sys, zone, zone_buses = _build_zone_system(; with_factors = false)
    _add_factor_matrix!(sys, zone, PSY.get_number.(zone_buses), [0.6, 0.39995])
    container, _ = _build_factor_model(sys)
    factors = get_distribution_factors(container, sys, zone)
    @test factors[PSY.get_number(zone_buses[2]), 1] == 0.39995
end

@testset "A zone with a load but no factors builds under CopperPlate" begin
    sys, _, _ = _build_zone_system(; with_factors = false)
    _build_lz_model(sys, NetworkModel(CopperPlateNetworkModel; attributes = LZ_ATTRIBUTES))
end

@testset "AC network formulations reject the attribute" begin
    sys, _, _ = _build_zone_system()
    log = _build_failure_log(
        sys, NetworkModel(ACPNetworkModel; attributes = LZ_ATTRIBUTES),
    )
    @test occursin("does not support the", log)
end

@testset "A non-Bool attribute value is an error" begin
    sys, _, _ = _build_zone_system()
    log = _build_failure_log(
        sys,
        NetworkModel(
            PTDFNetworkModel;
            attributes = Dict{String, Any}("load_zone_distribution" => "true"),
        ),
    )
    @test occursin("must be a Bool", log)
end

@testset "CopperPlate: a zone that spans subnetworks is an error" begin
    sys, zone, zone_buses = _build_zone_system(; with_factors = false)
    model = _build_lz_model(
        sys, NetworkModel(CopperPlateNetworkModel; attributes = LZ_ATTRIBUTES),
    )
    container = get_optimization_container(model)
    network_model = get_network_model(IOM.get_template(model))
    network_model.bus_area_map =
        Dict{IS.InfrastructureSystemsComponent, Int}(
            zone_buses[1] => 1, zone_buses[2] => 2,
        )
    load = IOM.get_parameter(container, ActivePowerTimeSeriesParameter, PSY.LoadZone)
    err = try
        POM._write_zone_load!(
            container, network_model, zone, POM._buses_by_number(sys), zone_buses,
            Dict{String, Vector{Int}}(), IOM.get_parameter_column_refs(load, "LZ1"),
            IOM.get_multiplier_array(load), "LZ1",
        )
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("LZ1", err.msg) && occursin("[1, 2]", err.msg)
end

@testset "DCP: the zonal load enters the nodal balance" begin
    sys, zone, zone_buses = _build_zone_system()
    peak = PSY.get_peak_active_power(zone, u"SU")
    fraction = _zone_load_fraction(_factor_horizon(sys))
    off = _build_lz_model(sys, NetworkModel(DCPNetworkModel))
    on = _build_lz_model(sys, NetworkModel(DCPNetworkModel; attributes = LZ_ATTRIBUTES))
    nodal_off = IOM.get_expression(
        get_optimization_container(off), ActivePowerBalance, PSY.ACBus,
    )
    nodal_on = IOM.get_expression(
        get_optimization_container(on), ActivePowerBalance, PSY.ACBus,
    )
    for t in get_time_steps(get_optimization_container(on))
        for (b, factor) in zip(zone_buses, (0.6, 0.4))
            n = PSY.get_number(b)
            @test JuMP.constant(nodal_on[n, t]) - JuMP.constant(nodal_off[n, t]) ≈
                  -factor * peak * fraction[t]
        end
    end
end

@testset "AreaBalance: a one-area zone writes its total, with or without factors" begin
    for with_factors in (true, false)
        sys, zone, _ = _build_zone_system(; with_factors = with_factors)
        _set_two_areas!(sys, 2)
        load =
            -PSY.get_peak_active_power(zone, u"SU") .*
            _zone_load_fraction(_factor_horizon(sys))
        delta = _zone_load_delta(sys, AreaBalanceNetworkModel, PSY.Area)
        @test all(delta[("LZ_A1", t)] ≈ load[t] for t in _steps(delta))
        @test all(iszero(delta[("LZ_A2", t)]) for t in _steps(delta))
    end
end

@testset "AreaBalance: a zone that spans areas splits its load with factors" begin
    sys, zone, _ = _build_zone_system()
    _set_two_areas!(sys, 1)
    load =
        -PSY.get_peak_active_power(zone, u"SU") .* _zone_load_fraction(_factor_horizon(sys))
    delta = _zone_load_delta(sys, AreaBalanceNetworkModel, PSY.Area)
    @test all(delta[("LZ_A1", t)] ≈ 0.6 * load[t] for t in _steps(delta))
    @test all(delta[("LZ_A2", t)] ≈ 0.4 * load[t] for t in _steps(delta))
end

@testset "AreaBalance: a zone that spans areas without factors is an error" begin
    sys, _, _ = _build_zone_system(; with_factors = false)
    _set_two_areas!(sys, 1)
    log = _build_failure_log(
        sys, NetworkModel(AreaBalanceNetworkModel; attributes = LZ_ATTRIBUTES),
    )
    @test occursin("Load zone LZ1 has no distribution_factor column", log)
end

@testset "PTDF: a one-bus zone needs no factors" begin
    sys, zone, zone_buses = _build_zone_system(; with_factors = false)
    PSY.set_load_zone!(zone_buses[2], nothing)
    n1, n2 = PSY.get_number.(zone_buses)
    load =
        -PSY.get_peak_active_power(zone, u"SU") .* _zone_load_fraction(_factor_horizon(sys))
    delta = _zone_load_delta(sys, PTDFNetworkModel, PSY.ACBus)
    @test all(delta[(n1, t)] ≈ load[t] for t in _steps(delta))
    @test all(iszero(delta[(n2, t)]) for t in _steps(delta))
end

@testset "Factors under recurrent solves turn on rebuild_model with a warning" begin
    sys, _, _ = _build_zone_system()
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; attributes = LZ_ATTRIBUTES),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, rebuild_model = false)
    IOM.get_optimization_container(model).built_for_recurrent_solves = true
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    @test IOM.get_rebuild_model(IOM.get_settings(model))
    log = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("LZ1 carries a DistributionFactorParameter", log)
end

@testset "A factor series of another time series type is rejected" begin
    # Attached as a SingleTimeSeries only, which the DecisionModel does not read.
    sys, zone, zone_buses = _build_zone_system(; with_factors = false)
    forecast = _load_forecast(sys)
    PSY.add_time_series!(
        sys,
        zone,
        PSY.SingleTimeSeries(
            POM.DISTRIBUTION_FACTOR_TS_NAME,
            first(keys(PSY.get_data(forecast))),
            PSY.get_resolution(forecast),
            repeat([0.6 0.4], 48, 1);
            value_axes = [IS.TimeSeriesAxis("bus", PSY.get_number.(zone_buses))],
        ),
    )
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; attributes = LZ_ATTRIBUTES),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test_throws IS.ConflictingInputsError POM.validate_template(model)
end

@testset "A zonal load of another time series type is rejected" begin
    # The DecisionModel reads forecasts; the zone's load exists only as a static series.
    sys, zone, _ = _build_zone_system(; with_factors = false)
    forecast = _load_forecast(sys)
    PSY.remove_time_series!(sys, PSY.Deterministic, zone, POM.LOAD_ZONE_LOAD_TS_NAME)
    first_stamp = first(keys(PSY.get_data(forecast)))
    stamps = range(first_stamp; step = PSY.get_resolution(forecast), length = 48)
    PSY.add_time_series!(
        sys, zone,
        PSY.SingleTimeSeries(;
            name = POM.LOAD_ZONE_LOAD_TS_NAME,
            data = TimeArray(collect(stamps), fill(0.5, 48)),
        ),
    )
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; attributes = LZ_ATTRIBUTES),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test_throws IS.ConflictingInputsError POM.validate_template(model)
end

# c_sys5_uc with static series only, and the zone "LZ1" with a static load and 0.6/0.4
# factors, as an EmulationModel reads them.
function _build_static_zone_system()
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_single_time_series = true)
    PSY.remove_time_series!(sys, PSY.Deterministic)
    load = PSY.get_time_series(
        PSY.SingleTimeSeries, first(PSY.get_components(PSY.PowerLoad, sys)),
        "max_active_power",
    )
    stamps = TimeSeries.timestamp(PSY.get_data(load))
    zone = PSY.LoadZone(;
        name = "LZ1",
        peak_active_power = 2.0,
        peak_reactive_power = 3.0,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, zone)
    zone_buses =
        sort!(collect(PSY.get_components(PSY.ACBus, sys)); by = PSY.get_number)[1:2]
    for b in zone_buses
        PSY.set_load_zone!(b, zone)
    end
    PSY.add_time_series!(
        sys, zone,
        PSY.SingleTimeSeries(;
            name = POM.LOAD_ZONE_LOAD_TS_NAME,
            data = TimeArray(stamps, fill(0.5, length(stamps))),
        ),
    )
    PSY.add_time_series!(
        sys, zone,
        PSY.SingleTimeSeries(
            POM.DISTRIBUTION_FACTOR_TS_NAME, first(stamps), PSY.get_resolution(load),
            repeat([0.6 0.4], length(stamps), 1);
            value_axes = [IS.TimeSeriesAxis("bus", PSY.get_number.(zone_buses))],
        ),
    )
    return sys, zone, zone_buses
end

@testset "EmulationModel: the zonal load enters the nodal balance" begin
    sys, zone, zone_buses = _build_static_zone_system()
    peak = PSY.get_peak_active_power(zone, u"SU")
    nodal = Dict()
    for attributes in (Dict{String, Any}(), LZ_ATTRIBUTES)
        template = get_thermal_dispatch_template_network(
            NetworkModel(PTDFNetworkModel; attributes = attributes),
        )
        # Numeric parameters in both builds; the factors switch it on anyway.
        model = EmulationModel(
            template, sys; optimizer = HiGHS_optimizer, rebuild_model = true,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        nodal[attributes] = IOM.get_expression(
            get_optimization_container(model), ActivePowerBalance, PSY.ACBus,
        )
    end
    for (b, factor) in zip(zone_buses, (0.6, 0.4))
        n = PSY.get_number(b)
        @test JuMP.constant(nodal[LZ_ATTRIBUTES][n, 1]) -
              JuMP.constant(nodal[Dict{String, Any}()][n, 1]) ≈ -factor * peak * 0.5
    end
end
