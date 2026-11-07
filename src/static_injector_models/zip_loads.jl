# `StandardLoad` and `InterruptibleStandardLoad` split their demand into constant power,
# constant impedance (P_Z |V|^2) and constant current (P_I |V|) parts, given at 1.0 pu voltage.
#
# Scope. Under `StaticPowerLoad`, ACPNetworkModel, ACRNetworkModel and IVRNetworkModel model the
# impedance and current parts as voltage dependent. One forecast (`max_active_power`) scales all
# three parts equally. The fractions of each part come from the `max_*` fields, so at forecast
# value 1.0 the load equals the PowerFlows.jl ZIP load. Every other case is constant power.
# DC, PTDF, CopperPlate and AreaBalance models have |V| = 1, so constant power is exact there.
# LPACCNetworkModel, and loads under a controllable formulation, stay constant power and log
# one warning per build.
const ZipLoad = Union{PSY.StandardLoad, PSY.InterruptibleStandardLoad}

has_voltage_dependent_load(::PSY.ElectricLoad) = false

function has_voltage_dependent_load(d::ZipLoad)
    return !(
        iszero(PSY.get_max_impedance_active_power(d, u"SU")) &&
        iszero(PSY.get_max_current_active_power(d, u"SU")) &&
        iszero(PSY.get_max_impedance_reactive_power(d, u"SU")) &&
        iszero(PSY.get_max_current_reactive_power(d, u"SU"))
    )
end

# Whether a network model splits voltage-dependent loads into their own aggregation rows.
abstract type ZipRowPolicy end
struct KeepZipLoadsAggregated <: ZipRowPolicy end
struct SplitZipLoads <: ZipRowPolicy end

zip_row_policy(::NetworkModel) = KeepZipLoadsAggregated()
zip_row_policy(
    ::NetworkModel{<:Union{ACPNetworkModel, ACRNetworkModel, IVRNetworkModel}},
) = SplitZipLoads()

# Row key of a load in the aggregated time-series parameter. Under `SplitZipLoads` a
# voltage-dependent load keeps its own row, so its series stays available per load.
function aggregation_row(d::PSY.ElectricLoad, ::Int, ::ZipRowPolicy)
    return PSY.get_number(PSY.get_bus(d))
end

function aggregation_row(d::ZipLoad, index::Int, ::SplitZipLoads)
    if has_voltage_dependent_load(d)
        return -index
    end
    return PSY.get_number(PSY.get_bus(d))
end

# (constant power, constant impedance, constant current) maximum demand, system base.
function zip_load_parts(::Type{ActivePowerTimeSeriesParameter}, d::ZipLoad)
    return (
        PSY.get_max_constant_active_power(d, u"SU"),
        PSY.get_max_impedance_active_power(d, u"SU"),
        PSY.get_max_current_active_power(d, u"SU"),
    )
end

function zip_load_parts(::Type{ReactivePowerTimeSeriesParameter}, d::ZipLoad)
    return (
        PSY.get_max_constant_reactive_power(d, u"SU"),
        PSY.get_max_impedance_reactive_power(d, u"SU"),
        PSY.get_max_current_reactive_power(d, u"SU"),
    )
end

# PSY defines no `get_max_reactive_power` for these loads: the total is the sum of the parts.
function get_multiplier_value(
    ::Type{ReactivePowerTimeSeriesParameter},
    d::ZipLoad,
    ::Type{StaticPowerLoad},
)
    return -sum(zip_load_parts(ReactivePowerTimeSeriesParameter, d))
end

"""
Voltage-dependent part of one load at one balance row. `injection[t]` is the signed injection
at 1.0 pu voltage, already in the balance expression. The balance constraint adds, per bus,
`sum(injection * impedance_fraction) * (|V|^2 - 1) + sum(injection * current_fraction) * (|V| - 1)`.
"""
struct ZipLoadTerm{V <: AbstractVector}
    bus_number::Int
    impedance_fraction::Float64
    current_fraction::Float64
    injection::V
end

const ZIP_LOAD_TERMS_ATTRIBUTE = "zip_load_terms"
const ZIP_UNMODELED_ATTRIBUTE = "zip_unmodeled_loads"

function _zip_load_terms(network_model::NetworkModel)
    return get!(
        get_attributes(network_model),
        ZIP_LOAD_TERMS_ATTRIBUTE,
        Dict{DataType, Vector{ZipLoadTerm}}(),
    )::Dict{DataType, Vector{ZipLoadTerm}}
end

function _zip_unmodeled_loads(network_model::NetworkModel)
    return get!(
        get_attributes(network_model),
        ZIP_UNMODELED_ATTRIBUTE,
        Set{String}(),
    )::Set{String}
end

# Drop terms and names left by a build that failed before the reactive balance.
function reset_zip_load_state!(network_model::NetworkModel)
    empty!(_zip_load_terms(network_model))
    empty!(_zip_unmodeled_loads(network_model))
    return
end

# The reactive balance is the last consumer of the recorded terms. It logs the loads that
# stay constant power, once per build, then clears the state.
function finish_zip_load_state!(network_model::NetworkModel)
    names = sort!(collect(_zip_unmodeled_loads(network_model)))
    if !isempty(names)
        @warn "$(length(names)) load(s) have constant impedance or constant current parts " *
              "that the network or load formulation does not model as voltage dependent. " *
              "They stay constant power: $(join(names, ", "))."
    end
    reset_zip_load_state!(network_model)
    return
end

const NO_ZIP_LOAD_TERMS = ZipLoadTerm[]

function zip_load_terms_by_bus(
    network_model::NetworkModel,
    ::Type{U},
) where {U <: TimeSeriesParameter}
    by_bus = Dict{Int, Vector{ZipLoadTerm}}()
    for term in get(_zip_load_terms(network_model), U, NO_ZIP_LOAD_TERMS)
        push!(get!(by_bus, term.bus_number, ZipLoadTerm[]), term)
    end
    return by_bus
end

function zip_impedance_sum(terms::Vector{ZipLoadTerm}, t::Int)
    total = 0.0
    for term in terms
        total = total + term.injection[t] * term.impedance_fraction
    end
    return total
end

function zip_current_sum(terms::Vector{ZipLoadTerm}, t::Int)
    total = 0.0
    for term in terms
        total = total + term.injection[t] * term.current_fraction
    end
    return total
end

# Networks whose voltage variables could carry a voltage-dependent load term.
const _ZipModeledNetworks = Union{ACPNetworkModel, ACRNetworkModel, IVRNetworkModel}
const _ZipVoltageAwareNetworks = Union{_ZipModeledNetworks, LPACCNetworkModel}

# DC, PTDF, copper-plate and area models have no voltage variable: |V| = 1, so the constant
# injection already in the balance is exact and nothing is recorded.
function record_zip_load_term!(
    ::NetworkModel,
    ::Type{<:TimeSeriesParameter},
    ::PSY.ElectricLoad,
    _,
)
    return
end

function record_zip_load_term!(
    network_model::NetworkModel{<:_ZipModeledNetworks},
    ::Type{U},
    d::ZipLoad,
    injection::AbstractVector,
) where {U <: Union{ActivePowerTimeSeriesParameter, ReactivePowerTimeSeriesParameter}}
    constant, impedance, current = zip_load_parts(U, d)
    if iszero(impedance) && iszero(current)
        return
    end
    total = constant + impedance + current
    if iszero(total)
        error(
            "Load $(PSY.get_name(d)) has voltage-dependent parts that sum to zero " *
            "with the constant part. The ZIP fractions are undefined.",
        )
    end
    bus_number = PNM.get_mapped_bus_number(
        get_network_reduction(network_model),
        PSY.get_bus(d),
    )
    push!(
        get!(_zip_load_terms(network_model), U, ZipLoadTerm[]),
        ZipLoadTerm(bus_number, impedance / total, current / total, injection),
    )
    return
end

# LPACC has a voltage variable but no |V|^2 and |V| terms: the load stays constant power.
function record_zip_load_term!(
    network_model::NetworkModel{LPACCNetworkModel},
    ::Type{<:TimeSeriesParameter},
    d::ZipLoad,
    _,
)
    record_unmodeled_zip_load!(network_model, d)
    return
end

# Loads under a controllable formulation, or any load with a voltage-aware network, stay
# constant power. No-op for networks with |V| = 1.
function record_unmodeled_zip_loads!(network_model::NetworkModel, devices)
    for d in devices
        record_unmodeled_zip_load!(network_model, d)
    end
    return
end

function record_unmodeled_zip_load!(::NetworkModel, ::PSY.Component)
    return
end

function record_unmodeled_zip_load!(
    network_model::NetworkModel{<:_ZipVoltageAwareNetworks},
    d::ZipLoad,
)
    if has_voltage_dependent_load(d)
        push!(_zip_unmodeled_loads(network_model), PSY.get_name(d))
    end
    return
end
