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
    network_model::NetworkModel{
        <:Union{
            DCPNetworkModel,
            ACPNetworkModel,
            ACRNetworkModel,
            NFANetworkModel,
            DCPLLNetworkModel,
            LPACCNetworkModel,
            IVRNetworkModel,
        },
    },
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

# Cached retained-bus number→name map for this (sys, network_model). Built once
# from _bus_name_number_pairs so per-device lookups don't rebuild Dicts (perf).
function _retained_number_to_name(sys::PSY.System, network_model)
    return Dict{Int, String}(
        no => name for (name, no) in _bus_name_number_pairs(sys, network_model)
    )
end

# Shared between DCPNetworkModel and ACPNetworkModel — both put VoltageAngle on every
# bus axis with no bounds. Slack-bus pinning is applied by ReferenceBusConstraint.
function add_variables!(
    container::OptimizationContainer,
    ::Type{VoltageAngle},
    sys::PSY.System,
    network_model::NetworkModel{
        <:Union{DCPNetworkModel, ACPNetworkModel, DCPLLNetworkModel, LPACCNetworkModel},
    },
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
    network_model::NetworkModel{
        <:Union{DCPNetworkModel, DCPLLNetworkModel, LPACCNetworkModel},
    },
)
    time_steps = get_time_steps(container)
    va = get_variable(container, VoltageAngle, PSY.ACBus)
    number_to_name = _retained_number_to_name(sys, network_model)
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
        # `k` is the reference bus number already assigned by PNM (the
        # `subnetwork_axes` key; under network reduction PNM reassigns a retained
        # bus as the key when the original REF is removed). Pin its angle directly
        # so the model's slack matches PNM's subnetwork reference by construction.
        ref_name = number_to_name[k]
        for t in time_steps
            cons[k, t] =
                JuMP.@constraint(get_jump_model(container), va[ref_name, t] == 0.0)
        end
    end
    return
end

# Number→bus map built ONCE per constraint-builder call. Lets the reference-bus
# and arbitrary-pin helpers iterate the (typically small) subnetwork bus-number
# set instead of rescanning all `PSY.ACBus` components per subnetwork, avoiding an
# O(buses × subnetworks) scan.
function _bus_by_number(sys::PSY.System)
    return Dict{Int, PSY.ACBus}(
        PSY.get_number(b) => b for b in PSY.get_components(PSY.ACBus, sys)
    )
end

# Name→bus map built once per call site; complements _bus_by_number.
function _bus_by_name(sys::PSY.System)
    return Dict{String, PSY.ACBus}(
        PSY.get_name(b) => b for b in PSY.get_components(PSY.ACBus, sys)
    )
end

# Shared skeleton for a bounded per-bus voltage variable (VoltageReal / VoltageImaginary
# / VoltageDeviation). `bounds(bus) -> (lower, upper, start)` supplies the per-bus bounds
# and warm start; everything else (axis, container, iteration) is identical.
function _add_bounded_bus_voltage_variable!(
    container::OptimizationContainer,
    ::Type{T},
    sys::PSY.System,
    network_model,
    bounds,
) where {T}
    time_steps = get_time_steps(container)
    bus_names = [name for (name, _) in _bus_name_number_pairs(sys, network_model)]
    bus_by_name = _bus_by_name(sys)

    var = add_variable_container!(container, T, PSY.ACBus, bus_names, time_steps)

    for name in bus_names
        lower, upper, start = bounds(bus_by_name[name])
        for t in time_steps
            var[name, t] = JuMP.@variable(
                get_jump_model(container),
                base_name = "$(nameof(T))_ACBus_{$(name), $(t)}",
                lower_bound = lower,
                upper_bound = upper,
                start = start,
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{NodalBalanceActiveConstraint},
    sys::PSY.System,
    network_model::NetworkModel{
        <:Union{
            DCPNetworkModel,
            ACPNetworkModel,
            ACRNetworkModel,
            NFANetworkModel,
            DCPLLNetworkModel,
            LPACCNetworkModel,
            IVRNetworkModel,
        },
    },
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
    network_model::NetworkModel{
        <:Union{ACPNetworkModel, ACRNetworkModel, LPACCNetworkModel, IVRNetworkModel},
    },
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
