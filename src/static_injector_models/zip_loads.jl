# ZIP loads have constant power, constant impedance (|V|^2) and constant current (|V|) parts,
# given at 1.0 pu voltage. ACP, ACR and IVR with `StaticPowerLoad` model the last two as
# voltage dependent. All other cases use constant power.
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

# How a network model assigns static loads to aggregation rows.
abstract type ZipRowPolicy end
struct KeepZipLoadsAggregated <: ZipRowPolicy end
struct SplitZipLoads <: ZipRowPolicy end

zip_row_policy(::NetworkModel) = KeepZipLoadsAggregated()
zip_row_policy(
    ::NetworkModel{<:Union{ACPNetworkModel, ACRNetworkModel, IVRNetworkModel}},
) = SplitZipLoads()

# Voltage-dependent loads under `SplitZipLoads` get their own row.
function aggregation_row(d::PSY.ElectricLoad, ::Int, ::ZipRowPolicy)
    return PSY.get_number(PSY.get_bus(d))
end

function aggregation_row(d::ZipLoad, index::Int, ::SplitZipLoads)
    if has_voltage_dependent_load(d)
        return -index
    end
    return PSY.get_number(PSY.get_bus(d))
end

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

# PSY has no `get_max_reactive_power` for these loads.
function get_multiplier_value(
    ::Type{ReactivePowerTimeSeriesParameter},
    d::ZipLoad,
    ::Type{StaticPowerLoad},
)
    return -sum(zip_load_parts(ReactivePowerTimeSeriesParameter, d))
end

# Voltage-dependent fractions of one load. `injection[t]` is its signed injection at 1.0 pu voltage.
struct ZipLoadTerm
    bus_number::Int
    impedance_fraction::Float64
    current_fraction::Float64
    injection::Vector{JuMP.AffExpr}
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

# Clear the recorded terms and names.
function reset_zip_load_state!(network_model::NetworkModel)
    empty!(_zip_load_terms(network_model))
    empty!(_zip_unmodeled_loads(network_model))
    return
end

# Warn about loads that stay constant power, then clear the state.
function finish_zip_load_state!(network_model::NetworkModel)
    names = sort!(collect(_zip_unmodeled_loads(network_model)))
    if !isempty(names)
        @warn "Loads with constant impedance or current parts stay constant power: $(join(names, ", "))."
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

# Networks without a voltage variable have no variables to fetch.
function _zip_voltage_variables(
    ::OptimizationContainer,
    ::NetworkModel,
    ::Dict{Int, Vector{ZipLoadTerm}},
)
    return ()
end

struct ImpedancePart end
struct CurrentPart end
zip_fraction(term::ZipLoadTerm, ::ImpedancePart) = term.impedance_fraction
zip_fraction(term::ZipLoadTerm, ::CurrentPart) = term.current_fraction

# Sum of `injection * fraction` over the loads of one bus, as a coefficient for the balance.
function zip_fraction_sum(terms::Vector{ZipLoadTerm}, t::Int, part)
    total = zero(JuMP.AffExpr)
    for term in terms
        JuMP.add_to_expression!(total, zip_fraction(term, part), term.injection[t])
    end
    return _constant_if_fixed(total)
end

# A sum of fixed values stays a number, so the balance keeps its quadratic form.
function _constant_if_fixed(total::JuMP.AffExpr)
    if isempty(total.terms)
        return total.constant
    end
    return total
end

function _zip_injection(injection::AbstractVector)
    values = Vector{JuMP.AffExpr}(undef, length(injection))
    for (t, x) in enumerate(injection)
        values[t] = JuMP.add_to_expression!(zero(JuMP.AffExpr), x)
    end
    return values
end

const _ZipModeledNetworks = Union{ACPNetworkModel, ACRNetworkModel, IVRNetworkModel}
const _ZipVoltageAwareNetworks = Union{_ZipModeledNetworks, LPACCNetworkModel}

# |V| = 1 here: the balance expression is exact.
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
        ZipLoadTerm(
            bus_number,
            impedance / total,
            current / total,
            _zip_injection(injection),
        ),
    )
    return
end

# LPACC has no |V|^2 and |V| terms.
function record_zip_load_term!(
    network_model::NetworkModel{LPACCNetworkModel},
    ::Type{<:TimeSeriesParameter},
    d::ZipLoad,
    _,
)
    record_unmodeled_zip_load!(network_model, d)
    return
end

# Warn only for networks that have voltage variables.
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
