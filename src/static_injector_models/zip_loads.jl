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

# Outputs with each load's consumption at the solved voltage.
add_zip_load_outputs!(::OptimizationContainer, _, ::DeviceModel, ::NetworkModel) = nothing

function add_zip_load_outputs!(
    container::OptimizationContainer,
    devices::Vector{<:ZipLoad},
    model::DeviceModel,
    ::NetworkModel{<:_ZipModeledNetworks},
)
    names = get_time_series_names(model)
    if haskey(names, ActivePowerTimeSeriesParameter)
        add_variables!(container, ZipLoadActivePower, devices, StaticPowerLoad)
    end
    if haskey(names, ReactivePowerTimeSeriesParameter)
        add_variables!(container, ZipLoadReactivePower, devices, StaticPowerLoad)
    end
    return
end

_zip_parameter(::Type{ZipLoadActivePower}) = ActivePowerTimeSeriesParameter
_zip_parameter(::Type{ZipLoadReactivePower}) = ReactivePowerTimeSeriesParameter

function calculate_aux_variable_value!(
    container::OptimizationContainer,
    ::AuxVarKey{T, D},
    system::PSY.System,
    context::PowerSolveContext,
) where {T <: Union{ZipLoadActivePower, ZipLoadReactivePower}, D <: ZipLoad}
    network_model = get_network_model(context)
    U = _zip_parameter(T)
    pairs = _bus_name_number_pairs(system, network_model)
    bus_names = Dict{Int, String}(n => name for (name, n) in pairs)
    _calculate_zip_load_consumption!(
        get_aux_variable(container, T, D),
        U,
        IOM.calculate_parameter_values(get_parameter(container, U, D)),
        _solved_voltage_magnitude(container, network_model),
        bus_names,
        get_network_reduction(network_model),
        system,
        D,
    )
    return
end

# Function barrier: the containers above are not inferable.
function _calculate_zip_load_consumption!(
    consumption::DenseAxisArray{Float64, 2},
    ::Type{U},
    injection::DenseAxisArray{Float64, 2},
    voltage::DenseAxisArray{Float64, 2},
    bus_names::Dict{Int, String},
    reduction::PNM.NetworkReductionData,
    system::PSY.System,
    ::Type{D},
) where {U <: TimeSeriesParameter, D <: ZipLoad}
    has_series = Set{String}(axes(injection, 1))
    for name in axes(consumption, 1)
        d = PSY.get_component(D, system, name)
        constant, impedance, current = zip_load_parts(U, d)
        total = constant + impedance + current
        if iszero(total) # A load with no parts consumes nothing; avoid 0/0.
            total = 1.0
        end
        bus = bus_names[PNM.get_mapped_bus_number(reduction, PSY.get_bus(d))]
        for t in axes(consumption, 2)
            # Loads without the time series use 1.0, as in the balance.
            p0 = if name in has_series
                -injection[name, t]
            else
                -get_multiplier_value(U, d, StaticPowerLoad)
            end
            v = voltage[bus, t]
            factor = (constant + impedance * v^2 + current * v) / total
            consumption[name, t] = p0 * factor
        end
    end
    return
end
