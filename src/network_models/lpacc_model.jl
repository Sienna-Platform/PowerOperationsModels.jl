# Native LPACC (linear-programming AC, cold-start) network formulation. Provides bus
# voltage-angle (va) and voltage-magnitude-deviation (phi = |V| - 1) variables, slack-bus
# angle pinning (va_ref == 0), voltage-deviation bounds, and active+reactive nodal balance.
#
# The bus-pair cosine variable (cs), the convex cosine relaxation, and the LPAC-linearized
# branch power flows are added by the branch device construction path (AC_branches.jl and
# branch_constructor.jl).
#
# Convention: variables/constraints indexed by ACBus use bus NAME (String) — see dcp_model.jl.
# add_variables!(VoltageAngle, ...) and add_constraints!(ReferenceBusConstraint, ...) for
# LPACCNetworkModel are defined in dcp_model.jl via Union dispatch shared with DCP/DCPLL
# (identical implementation). _bus_name_number_pairs / _retained_number_to_name /
# _bus_by_number / _bus_by_name are defined in dcp_model.jl (same module scope).

function add_variables!(
    container::OptimizationContainer,
    ::Type{VoltageDeviation},
    sys::PSY.System,
    network_model::NetworkModel{LPACCNetworkModel},
)
    _add_bounded_bus_voltage_variable!(
        container, VoltageDeviation, sys, network_model,
        bus -> begin
            # bus voltage limits are already per-unit
            vlim = PSY.get_voltage_limits(bus)
            return (vlim.min - 1.0, vlim.max - 1.0, 0.0)
        end,
    )
    return
end
