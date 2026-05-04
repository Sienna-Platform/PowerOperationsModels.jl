# Native ACP network formulation. Provides bus voltage magnitude + angle
# variables, slack-bus pinning (vm + va), and active+reactive nodal balance.
# Branch flow variables, rate limits, and AC power flow constraints are added
# by the branch device construction path (Phase F).
#
# Convention: variables/constraints indexed by ACBus use bus NAME (String) — see dcp_model.jl.
# add_variables!(VoltageAngle, ...) for ACPPowerModel is defined in dcp_model.jl
# via a Union dispatch shared with DCPPowerModel (identical implementation).

function add_variables!(
    container::OptimizationContainer,
    ::Type{VoltageMagnitude},
    sys::PSY.System,
    network_model::NetworkModel{ACPPowerModel},
)
    time_steps = get_time_steps(container)
    bus_names = [name for (name, _) in _bus_name_number_pairs(sys, network_model)]
    bus_by_name = Dict{String, PSY.ACBus}(
        PSY.get_name(b) => b for b in PSY.get_components(PSY.ACBus, sys)
    )

    var = add_variable_container!(
        container,
        VoltageMagnitude,
        PSY.ACBus,
        bus_names,
        time_steps,
    )

    for name in bus_names
        bus = bus_by_name[name]
        vlim = PSY.get_voltage_limits(bus)
        v0 = PSY.get_magnitude(bus)
        for t in time_steps
            var[name, t] = JuMP.@variable(
                get_jump_model(container),
                base_name = "VoltageMagnitude_ACBus_{$(name), $(t)}",
                lower_bound = vlim.min,
                upper_bound = vlim.max,
                start = v0,
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{ReferenceBusConstraint},
    sys::PSY.System,
    network_model::NetworkModel{ACPPowerModel},
)
    time_steps = get_time_steps(container)
    va = get_variable(container, VoltageAngle, PSY.ACBus)
    vm = get_variable(container, VoltageMagnitude, PSY.ACBus)
    subnets = network_model.subnetworks
    subnet_keys = collect(keys(subnets))

    cons_va = add_constraints_container!(
        container,
        ReferenceBusConstraint,
        PSY.ACBus,
        subnet_keys,
        time_steps;
        meta = "va",
    )
    cons_vm = add_constraints_container!(
        container,
        ReferenceBusConstraint,
        PSY.ACBus,
        subnet_keys,
        time_steps;
        meta = "vm",
    )

    for k in subnet_keys
        bus_set = subnets[k]
        ref = _find_reference_bus(sys, bus_set)
        # Skip subnetworks without an AC reference bus (e.g. an isolated DC-side
        # island connected through HVDC converters).
        ref === nothing && continue
        ref_name = ref.name
        v_set = ref.v
        for t in time_steps
            cons_va[k, t] =
                JuMP.@constraint(get_jump_model(container), va[ref_name, t] == 0.0)
            cons_vm[k, t] =
                JuMP.@constraint(get_jump_model(container), vm[ref_name, t] == v_set)
        end
    end
    return
end

"""
Returns `(name::String, v::Float64)` for the reference bus belonging to the
given bus-number set, or `nothing` if no such bus exists. Function-barrier
helper so the caller sees a clean union return rather than a local re-bound
across branches.
"""
function _find_reference_bus(
    sys::PSY.System,
    bus_set,
)::Union{Nothing, NamedTuple{(:name, :v), Tuple{String, Float64}}}
    for b in PSY.get_components(PSY.ACBus, sys)
        if PSY.get_number(b) in bus_set && PSY.get_bustype(b) == PSY.ACBusTypes.REF
            return (name = PSY.get_name(b), v = PSY.get_magnitude(b))
        end
    end
    return nothing
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{NodalBalanceActiveConstraint},
    sys::PSY.System,
    network_model::NetworkModel{ACPPowerModel},
)
    time_steps = get_time_steps(container)
    expressions = get_expression(container, ActivePowerBalance, PSY.ACBus)
    pairs = _bus_name_number_pairs(sys, network_model)
    bus_names = [name for (name, _) in pairs]

    cons = add_constraints_container!(
        container,
        NodalBalanceActiveConstraint,
        PSY.ACBus,
        bus_names,
        time_steps,
    )

    for (name, bus_no) in pairs, t in time_steps
        cons[name, t] = JuMP.@constraint(
            get_jump_model(container),
            expressions[bus_no, t] == 0.0,
        )
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{NodalBalanceReactiveConstraint},
    sys::PSY.System,
    network_model::NetworkModel{ACPPowerModel},
)
    time_steps = get_time_steps(container)
    expressions = get_expression(container, ReactivePowerBalance, PSY.ACBus)
    pairs = _bus_name_number_pairs(sys, network_model)
    bus_names = [name for (name, _) in pairs]

    cons = add_constraints_container!(
        container,
        NodalBalanceReactiveConstraint,
        PSY.ACBus,
        bus_names,
        time_steps,
    )

    for (name, bus_no) in pairs, t in time_steps
        cons[name, t] = JuMP.@constraint(
            get_jump_model(container),
            expressions[bus_no, t] == 0.0,
        )
    end
    return
end
