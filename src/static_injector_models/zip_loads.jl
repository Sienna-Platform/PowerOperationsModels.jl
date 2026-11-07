# `StandardLoad` and `InterruptibleStandardLoad` split their demand into constant power,
# constant impedance (P_Z |V|^2) and constant current (P_I |V|) parts, given at 1.0 pu voltage.
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

# Row key of a load in the aggregated time-series parameter. A voltage-dependent load keeps its
# own row, so its series stays available per load.
aggregation_row(d::PSY.ElectricLoad, ::Int) = PSY.get_number(PSY.get_bus(d))

function aggregation_row(d::ZipLoad, index::Int)
    if has_voltage_dependent_load(d)
        return -index
    end
    return PSY.get_number(PSY.get_bus(d))
end

# (constant power, constant impedance, constant current) maximum demand, system base.
zip_load_parts(::Type{ActivePowerTimeSeriesParameter}, d::ZipLoad) = (
    PSY.get_max_constant_active_power(d, u"SU"),
    PSY.get_max_impedance_active_power(d, u"SU"),
    PSY.get_max_current_active_power(d, u"SU"),
)
zip_load_parts(::Type{ReactivePowerTimeSeriesParameter}, d::ZipLoad) = (
    PSY.get_max_constant_reactive_power(d, u"SU"),
    PSY.get_max_impedance_reactive_power(d, u"SU"),
    PSY.get_max_current_reactive_power(d, u"SU"),
)

# PSY defines no `get_max_reactive_power` for these loads: the total is the sum of the parts.
get_multiplier_value(
    ::Type{ReactivePowerTimeSeriesParameter},
    d::ZipLoad,
    ::Type{StaticPowerLoad},
) =
    -sum(zip_load_parts(ReactivePowerTimeSeriesParameter, d))

"""
Voltage-dependent part of one load at one balance row. `injection[t]` is the signed injection
at 1.0 pu voltage, already in the balance expression. The balance constraint adds
`injection[t] * (impedance_fraction * (|V|^2 - 1) + current_fraction * (|V| - 1))`.
"""
struct ZipLoadTerm
    bus_number::Int
    impedance_fraction::Float64
    current_fraction::Float64
    injection::AbstractVector
end

const ZIP_LOAD_TERMS_ATTRIBUTE = "zip_load_terms"

function _zip_load_terms(network_model::NetworkModel)
    return get!(
        get_attributes(network_model),
        ZIP_LOAD_TERMS_ATTRIBUTE,
        Dict{DataType, Vector{ZipLoadTerm}}(),
    )::Dict{DataType, Vector{ZipLoadTerm}}
end

function clear_zip_load_terms!(network_model::NetworkModel)
    empty!(_zip_load_terms(network_model))
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

# DC, PTDF, copper-plate and area models have no voltage variable: |V| = 1, so the constant
# injection already in the balance is exact.
record_zip_load_term!(
    ::NetworkModel,
    ::Type{<:TimeSeriesParameter},
    ::PSY.ElectricLoad,
    _,
) =
    nothing

function record_zip_load_term!(
    network_model::NetworkModel{<:Union{ACPNetworkModel, ACRNetworkModel, IVRNetworkModel}},
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
