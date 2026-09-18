_to_is_interval(interval::Dates.Millisecond) =
    interval == UNSET_INTERVAL ? nothing : interval

_to_is_resolution(resolution::Dates.Millisecond) =
    resolution == UNSET_RESOLUTION ? nothing : resolution

function get_available_reservoirs(sys::PSY.System)
    # Materialized: the build path hands this straight to the `Vector`-typed builders.
    return collect(
        PSY.get_components(
            x -> (PSY.get_available(x)),
            PSY.HydroReservoir,
            sys,
        ),
    )
end

function get_available_turbines(
    d::PSY.HydroReservoir,
    ::Type{U},
) where {U <: Union{TotalHydroPowerReservoirIncoming, TotalHydroFlowRateReservoirIncoming}}
    return filter(
        x -> PSY.get_available(x) && isa(x, PSY.HydroTurbine),
        PSY.get_upstream_turbines(d),
    )
end

function get_available_turbines(
    d::PSY.HydroReservoir,
    ::Type{U},
) where {U <: Union{TotalHydroPowerReservoirOutgoing, TotalHydroFlowRateReservoirOutgoing}}
    return filter(
        x -> PSY.get_available(x) && isa(x, PSY.HydroTurbine),
        PSY.get_downstream_turbines(d),
    )
end

_negated_rating(rating::Float64) = -rating
_negated_rating(::Nothing) = nothing

# PowerSystems #1783 replaced `must_run::Bool` with `commitment_mode` and the Bool `status`
# with `OperationalStates`. Only MUST_RUN forces a unit on; SELF_SCHEDULED and RELIABILITY
# stay committable. `HydroTurbine` carries the field too but had no `must_run` before.
_is_must_run(::PSY.Component) = false
_is_must_run(d::PSY.ThermalGen) = PSY.get_commitment_mode(d) == PSY.CommitmentModes.MUST_RUN
_is_must_run(d::PSY.HydroPumpTurbine) =
    PSY.get_commitment_mode(d) == PSY.CommitmentModes.MUST_RUN

"""
    is_online(d) -> Bool

Whether `d` is on at the start of the horizon: its `status` is ONLINE or STARTUP. The
initial conditions and the `OnVariable` warm start read this instead of the raw enum.
"""
function is_online(d::PSY.Component)
    status = PSY.get_status(d)
    return status == PSY.OperationalStates.ONLINE || status == PSY.OperationalStates.STARTUP
end

# IOM's own callers (start-up costs, ramps) read the predicate POM's formulations use.
IOM.get_must_run(c::PSY.Component) = _is_must_run(c)
