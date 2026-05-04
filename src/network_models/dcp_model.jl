# Native DCP network formulation. Provides bus voltage angle variables,
# slack-bus pinning, and active-power nodal balance. Branch flow variables,
# rate limits, and ohms are added by the branch device construction path
# (see ac_transmission_models/AC_branches.jl and branch_constructor.jl).
#
# Convention: variables and constraints indexed by ACBus use bus NAME (String)
# axes — matches the bridge convention and IOM's dual-extraction logic.
# System-balance expressions (ActivePowerBalance) are indexed by bus NUMBER
# (Int) per make_system_expressions.jl, so internal lookups translate names↔numbers.

function _bus_name_number_pairs(
    sys::PSY.System,
    network_model::NetworkModel{<:Union{DCPPowerModel, ACPPowerModel}},
)
    network_reduction = get_network_reduction(network_model)
    if isempty(network_reduction)
        buses = collect(get_available_components(network_model, PSY.ACBus, sys))
        return Tuple{String, Int}[(PSY.get_name(b), PSY.get_number(b)) for b in buses]
    else
        bus_numbers = collect(keys(PNM.get_bus_reduction_map(network_reduction)))
        bus_by_no = Dict{Int, PSY.ACBus}(
            PSY.get_number(b) => b for b in PSY.get_components(PSY.ACBus, sys)
        )
        return Tuple{String, Int}[(PSY.get_name(bus_by_no[n]), n) for n in bus_numbers]
    end
end

# Shared between DCPPowerModel and ACPPowerModel — both put VoltageAngle on every
# bus axis with no bounds. Slack-bus pinning is applied by ReferenceBusConstraint.
function add_variables!(
    container::OptimizationContainer,
    ::Type{VoltageAngle},
    sys::PSY.System,
    network_model::NetworkModel{<:Union{DCPPowerModel, ACPPowerModel}},
)
    time_steps = get_time_steps(container)
    bus_names = [name for (name, _) in _bus_name_number_pairs(sys, network_model)]

    var = add_variable_container!(
        container,
        VoltageAngle,
        PSY.ACBus,
        bus_names,
        time_steps,
    )

    for name in bus_names, t in time_steps
        var[name, t] = JuMP.@variable(
            get_jump_model(container),
            base_name = "VoltageAngle_ACBus_{$(name), $(t)}",
        )
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{ReferenceBusConstraint},
    sys::PSY.System,
    network_model::NetworkModel{DCPPowerModel},
)
    time_steps = get_time_steps(container)
    va = get_variable(container, VoltageAngle, PSY.ACBus)
    subnets = network_model.subnetworks
    subnet_keys = collect(keys(subnets))

    cons = add_constraints_container!(
        container,
        ReferenceBusConstraint,
        PSY.ACBus,
        subnet_keys,
        time_steps,
    )

    for k in subnet_keys
        bus_set = subnets[k]
        ref_name = _find_reference_bus_name(sys, bus_set)
        # Skip subnetworks without an AC reference bus (e.g. an isolated DC-side
        # island connected through HVDC converters). Throwing here would break
        # multi-island HVDC systems that the bridge implementation accepted.
        ref_name === nothing && continue
        for t in time_steps
            cons[k, t] =
                JuMP.@constraint(get_jump_model(container), va[ref_name, t] == 0.0)
        end
    end
    return
end

"""
Returns the NAME of the reference bus belonging to the given bus-number set,
or `nothing` if no such reference bus exists in `sys`. Function-barrier helper
so callers see a clean `Union{Nothing, String}` return type instead of a local
variable re-bound across branches.
"""
function _find_reference_bus_name(sys::PSY.System, bus_set)::Union{Nothing, String}
    for b in PSY.get_components(PSY.ACBus, sys)
        if PSY.get_number(b) in bus_set && PSY.get_bustype(b) == PSY.ACBusTypes.REF
            return PSY.get_name(b)
        end
    end
    return nothing
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{NodalBalanceActiveConstraint},
    sys::PSY.System,
    network_model::NetworkModel{DCPPowerModel},
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
