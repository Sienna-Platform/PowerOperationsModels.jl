function get_copied_line(
    line::PSY.Line,
)
    copied_line = Line(;
        name = PSY.get_name(line) * "_copy",
        available = PSY.get_available(line),
        active_power_flow = PSY.get_active_power_flow(line, u"SU"),
        reactive_power_flow = PSY.get_reactive_power_flow(line, u"SU"),
        arc = PSY.get_arc(line),
        r = PSY.get_r(line, u"SU"),
        x = PSY.get_x(line, u"SU"),
        b = PSY.get_b(line, u"SU"),
        rating = PSY.get_rating(line, u"SU"),
        angle_limits = PSY.get_angle_limits(line),
        rating_b = PSY.get_rating_b(line, u"SU"),
        rating_c = PSY.get_rating_c(line, u"SU"),
        g = PSY.get_g(line, u"SU"),
        services = PSY.get_services(line),
        ext = PSY.get_ext(line),
        input_basis = u"CU",
    )
    return copied_line
end

function get_copied_bus(
    bus::PSY.ACBus,
)
    copied_bus = ACBus(;
        input_basis = u"CU",
        number = PSY.get_number(bus) + 1000, #Add 1000 to avoid name conflicts
        name = PSY.get_name(bus) * "_copy",
        available = PSY.get_available(bus),
        bustype = ACBusTypes.PQ,
        angle = PSY.get_angle(bus),
        magnitude = PSY.get_magnitude(bus, u"CU"),
        voltage_limits = PSY.get_voltage_limits(bus, u"CU"),
        base_voltage = PSY.get_base_voltage(bus),
        area = PSY.get_area(bus),
        load_zone = PSY.get_load_zone(bus),
    )
    return copied_bus
end

function add_equivalent_ac_transmission_with_series_parallel_circuits!(
    sys::System,
    ac_transmission::PSY.Line,
    ::Type{T},
) where {T <: PSY.Line}

    #Create intermediate Bus
    old_arc = PSY.get_arc(ac_transmission)
    original_bus_to = PSY.get_to(old_arc)
    original_bus_from = PSY.get_from(old_arc)
    intermediate_bus = get_copied_bus(original_bus_to)
    add_component!(sys, intermediate_bus)

    #Remove old arc
    remove_component!(sys, old_arc)

    #add new Arcs
    arc1 = Arc(; from = original_bus_from, to = intermediate_bus)
    arc2 = Arc(; from = intermediate_bus, to = original_bus_to)
    add_component!(sys, arc1)
    add_component!(sys, arc2)
    #Update Arc original Line
    set_arc!(ac_transmission, arc1)

    #make Parallel circuits
    original_rating = PSY.get_rating(ac_transmission, u"SU")
    original_r = PSY.get_r(ac_transmission, u"SU")
    original_x = PSY.get_x(ac_transmission, u"SU")
    rating_new_parallel = PSY.get_rating(ac_transmission, u"SU") / 2
    new_r_parallel = PSY.get_r(ac_transmission, u"SU") * 2
    new_x_parallel = PSY.get_x(ac_transmission, u"SU") * 2
    ac_transmission_copy_parallel = get_copied_line(ac_transmission)
    # Attach the parallel copy before any system-base (u"SU") access on it,
    # including copying it below (get_copied_line reads u"SU" quantities) and the
    # setters further down: resolving a u"SU" quantity needs the system base
    # power, only reachable once the component is attached to the system.
    add_component!(sys, ac_transmission_copy_parallel)
    ac_transmission_copy_series = get_copied_line(ac_transmission_copy_parallel)

    set_rating!(ac_transmission, rating_new_parallel * u"SU")
    set_rating!(ac_transmission_copy_parallel, rating_new_parallel * u"SU")
    set_r!(ac_transmission, original_r * u"SU")
    set_r!(ac_transmission_copy_parallel, new_r_parallel * u"SU")
    set_x!(ac_transmission, new_x_parallel * u"SU")
    set_x!(ac_transmission_copy_parallel, new_x_parallel * u"SU")

    #Add new series Line with same parameters
    set_arc!(ac_transmission_copy_series, arc2)
    add_component!(sys, ac_transmission_copy_series)
    set_x!(ac_transmission_copy_series, 1e-9 * u"SU")
    set_r!(ac_transmission_copy_series, 1e-9 * u"SU")
end

function add_equivalent_ac_transmission_with_parallel_circuits!(
    sys::System,
    ac_transmission::PSY.Line,
    ::Type{T},
) where {T <: PSY.Line}
    rating_new = PSY.get_rating(ac_transmission, u"SU") / 2
    x_new = PSY.get_x(ac_transmission, u"SU") * 2
    r_new = PSY.get_r(ac_transmission, u"SU") * 2
    ac_transmission_copy_parallel = get_copied_line(ac_transmission)
    # Attach the copy before setting system-base (u"SU") values: resolving a
    # u"SU" quantity needs the system base power, which is only reachable once
    # the component is attached to the system.
    add_component!(sys, ac_transmission_copy_parallel)

    #Set ratings the half so the case remains equivalent to the original
    set_rating!(ac_transmission, rating_new * u"SU")
    set_rating!(ac_transmission_copy_parallel, rating_new * u"SU")
    set_x!(ac_transmission, x_new * u"SU")
    set_x!(ac_transmission_copy_parallel, x_new * u"SU")
    set_r!(ac_transmission, r_new * u"SU")
    set_r!(ac_transmission_copy_parallel, r_new * u"SU")
end

# Adds a parallel TwoWindingTransformer copy of a Line, so PNM builds a
# MixedBranchesParallel. Mirrors the former MonitoredLine helper: both members get half
# the rating, the Line gets twice its r and x, and the copy keeps the original r and x.
function add_equivalent_ac_transmission_with_parallel_circuits!(
    sys::System,
    ac_transmission::PSY.Line,
    ::Type{T},
    ::Type{PSY.TwoWindingTransformer},
) where {T <: PSY.Line}
    rating_new = PSY.get_rating(ac_transmission, u"SU") / 2
    r = PSY.get_r(ac_transmission, u"SU")
    x = PSY.get_x(ac_transmission, u"SU")
    ac_transmission_copy = PSY.TwoWindingTransformer(;
        name = PSY.get_name(ac_transmission) * "_copy",
        circuit = PSY.TransformerCircuit(;
            available = PSY.get_available(ac_transmission),
            arc = PSY.get_arc(ac_transmission),
            r = r,
            x = x,
            tap = 1.0,
            α = 0.0,
            rating = rating_new,
            base_power = PSY.get_base_power(sys, u"NU"),
            input_basis = u"CU",
        ),
        magnetizing_shunt = 0.0 + 0.0im,
        shunt_location = PSY.TwoWindingTransformerShuntLocation.PRIMARY,
        input_basis = u"CU",
    )
    set_rating!(ac_transmission, rating_new * u"SU")
    set_x!(ac_transmission, 2 * x * u"SU")
    set_r!(ac_transmission, 2 * r * u"SU")
    add_component!(sys, ac_transmission_copy)
    return
end

function add_reserve_product_without_requirement_time_series!(
    sys::PSY.System,
    name::String,
    direction::String,
    contributing_devices::Union{
        IS.FlattenIteratorWrapper{<:PSY.Generator},
        Vector{<:PSY.Generator},
    },
)
    AS_DIRECTION_MAP = Dict(
        "Up" => ReserveUp,
        "Down" => ReserveDown,
    )
    as_direction = AS_DIRECTION_MAP[direction]
    reserve_instance = OnlineReserve{as_direction}(;
        name = name,
        available = true,
        time_frame = 0.0,
        requirement = 0.0,
        sustained_time = 3600,
        max_output_fraction = 1.0,
        max_participation_factor = 0.25,
        deployed_fraction = 0.0,
    )
    add_service!(sys, reserve_instance, contributing_devices)
end

# PSY holds one setpoint field per controlled quantity. These helpers take one per-unit
# setpoint per side, as the model sees it, and fill the field the mode selects.

# Keyword arguments of one TwoTerminalVSCLine terminal (`side` is "from" or "to"). The AC
# voltage setpoint is per unit of the rated AC voltage, which the caller sets to the bus
# base voltage. Under AC_REACTIVE_POWER the AC setpoint is `reactive_power_<side>` in
# system per unit. The DC voltage setpoint is per unit of `rated_dc_voltage`.
function _vsc_setpoint_kwargs(side, ac_control, ac_setpoint, dc_control, dc_setpoint)
    q_field = Symbol("reactive_power_", side)
    if ac_control == VSCACControlModes.AC_VOLTAGE
        ac = (Symbol("ac_voltage_setpoint_", side) => ac_setpoint, q_field => 0.0)
    else
        # PSY requires power_factor_setpoint_<side> in this mode; POM ignores it.
        ac = (q_field => ac_setpoint, Symbol("power_factor_setpoint_", side) => 1.0)
    end
    if dc_control == VSCDCControlModes.DC_POWER
        dc = (Symbol("dc_power_setpoint_", side) => dc_setpoint,)
    else
        dc = (Symbol("dc_voltage_setpoint_", side) => dc_setpoint,)
    end
    return (; ac..., dc...)
end

# InterconnectingConverter setpoints. PSY holds the voltage setpoints in kV, so the
# per-unit test values scale by the AC and DC bus base voltages. AC_REACTIVE_POWER sets
# power_factor_setpoint 1.0 only so that PSY accepts the data; POM rejects the mode.
function _set_ic_setpoints!(ic, ac_control, ac_setpoint, dc_control, dc_setpoint)
    set_ac_control!(ic, ac_control)
    set_dc_control!(ic, dc_control)
    if ac_control == VSCACControlModes.AC_VOLTAGE
        set_power_factor_setpoint!(ic, nothing)
        set_ac_voltage_setpoint!(ic, ac_setpoint * get_base_voltage(get_bus(ic)))
    else
        set_ac_voltage_setpoint!(ic, nothing)
        set_power_factor_setpoint!(ic, 1.0)
    end
    if dc_control == VSCDCControlModes.DC_POWER
        set_dc_voltage_setpoint!(ic, nothing)
        set_dc_power_setpoint!(ic, dc_setpoint * u"SU")
    else
        set_dc_power_setpoint!(ic, nothing)
        set_dc_voltage_setpoint!(ic, dc_setpoint * get_base_voltage(get_dc_bus(ic)))
    end
    return
end

# Droop gain per unit on (DC bus base voltage, system base) to kV/MW.
_ic_droop_kv_per_mw(ic, droop, sys) =
    droop * get_base_voltage(get_dc_bus(ic)) / get_base_power(sys)

# Build a VoltageControlConverter model whose converters use AC_REACTIVE_POWER and assert
# that template validation rejects it.
function _assert_ic_reactive_power_rejected(template, sys)
    for ic in get_components(InterconnectingConverter, sys)
        @test get_ac_control(ic) == VSCACControlModes.AC_REACTIVE_POWER
    end
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    out = mktempdir(; cleanup = true)
    @test build!(model; output_dir = out, console_level = Logging.Error) ==
          IOM.ModelBuildStatus.FAILED
    log = read(joinpath(out, "operation_problem.log"), String)
    @test occursin(
        "uses AC_REACTIVE_POWER control, which POM does not support for " *
        "InterconnectingConverter. Use the AC_VOLTAGE control mode.",
        log,
    )
    return
end
