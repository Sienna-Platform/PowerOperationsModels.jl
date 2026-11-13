# ZIP loads have constant power, constant impedance (|V|^2) and constant current (|V|) parts,
# given at 1.0 pu voltage. ACP, ACR and IVR with `StaticPowerLoad` model the last two as
# voltage dependent. All other cases use constant power.
const ZipLoad = Union{PSY.StandardLoad, PSY.InterruptibleStandardLoad}

function has_voltage_dependent_load(d::ZipLoad)
    return any(
        U -> any(!iszero, zip_load_parts(U, d)[2:3]),
        (ActivePowerTimeSeriesParameter, ReactivePowerTimeSeriesParameter),
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

const ZIP_PARTS_RELATIVE_TOLERANCE = 1e-9

# Share of each ZIP part in the total of the `max_*` parts. `zip_load_parts` has the order
# (power, impedance, current). The result names each part, so no caller maps by position.
function zip_fractions(::Type{U}, d::ZipLoad) where {U <: TimeSeriesParameter}
    constant, impedance, current = zip_load_parts(U, d)
    total = constant + impedance + current
    scale = abs(constant) + abs(impedance) + abs(current)
    if abs(total) <= ZIP_PARTS_RELATIVE_TOLERANCE * scale || iszero(scale)
        error(
            "Load $(PSY.get_name(d)) has ZIP parts $((constant, impedance, current)) that " *
            "sum to zero. The ZIP fractions are undefined.",
        )
    end
    return (
        constant_power = constant / total,
        constant_current = current / total,
        constant_impedance = impedance / total,
    )
end

# Splits `value` into the three ZIP amounts. A load with no parts and a zero value has zero
# amounts.
function split_zip_value(
    ::Type{U},
    d::ZipLoad,
    value::Float64,
) where {U <: TimeSeriesParameter}
    if all(iszero, zip_load_parts(U, d)) && iszero(value)
        return (constant_power = 0.0, constant_current = 0.0, constant_impedance = 0.0)
    end
    fractions = zip_fractions(U, d)
    return (
        constant_power = value * fractions.constant_power,
        constant_current = value * fractions.constant_current,
        constant_impedance = value * fractions.constant_impedance,
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
    impedance_fraction::Float64
    current_fraction::Float64
    injection::Vector{JuMP.AffExpr}
end

zip_impedance_fraction(term::ZipLoadTerm) = term.impedance_fraction
zip_current_fraction(term::ZipLoadTerm) = term.current_fraction

const ZIP_LOAD_TERMS_ATTRIBUTE = "zip_load_terms"
const ZIP_UNMODELED_ATTRIBUTE = "zip_unmodeled_loads"

# Terms per parameter type, then per bus number.
function _zip_load_terms(network_model::NetworkModel)
    return get!(
        get_attributes(network_model),
        ZIP_LOAD_TERMS_ATTRIBUTE,
        Dict{DataType, Dict{Int, Vector{ZipLoadTerm}}}(),
    )::Dict{DataType, Dict{Int, Vector{ZipLoadTerm}}}
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

# Buses with a constant-current part in their active or reactive ZIP terms.
function zip_current_bus_numbers(network_model::NetworkModel)
    buses = Set{Int}()
    for by_bus in values(_zip_load_terms(network_model)), (bus, terms) in by_bus
        if any(term -> !iszero(zip_current_fraction(term)), terms)
            push!(buses, bus)
        end
    end
    return buses
end

function zip_load_terms_by_bus(
    network_model::NetworkModel,
    ::Type{U},
) where {U <: TimeSeriesParameter}
    return get(Dict{Int, Vector{ZipLoadTerm}}, _zip_load_terms(network_model), U)
end

# Networks without a voltage variable have no variables to fetch.
_zip_voltage_variables(::OptimizationContainer, ::NetworkModel) = ()

# Sum of `injection * fraction` over the loads of one bus, as a coefficient for the balance.
function zip_fraction_sum(terms::Vector{ZipLoadTerm}, t::Int, fraction::F) where {F}
    total = zero(JuMP.AffExpr)
    for term in terms
        JuMP.add_to_expression!(total, fraction(term), term.injection[t])
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

function record_zip_load_term!(
    ::NetworkModel,
    ::Type{<:TimeSeriesParameter},
    ::PSY.ElectricLoad,
    _,
)
    return
end

function record_zip_load_term!(
    network_model::NetworkModel{N},
    ::Type{U},
    d::ZipLoad,
    injection::AbstractVector,
) where {
    N <: AbstractNetworkModel,
    U <: Union{ActivePowerTimeSeriesParameter, ReactivePowerTimeSeriesParameter},
}
    _record_zip_load_term!(zip_load_support(N), network_model, U, d, injection)
    return
end

# |V| = 1 here: the balance expression is exact.
function _record_zip_load_term!(::NoVoltageZip, ::NetworkModel, ::Type, ::ZipLoad, _)
    return
end

function _record_zip_load_term!(
    ::ConstantPowerZip,
    network_model::NetworkModel,
    ::Type,
    d::ZipLoad,
    _,
)
    record_unmodeled_zip_load!(network_model, d)
    return
end

function _record_zip_load_term!(
    ::VoltageDependentZip,
    network_model::NetworkModel,
    ::Type{U},
    d::ZipLoad,
    injection::AbstractVector,
) where {U <: TimeSeriesParameter}
    _, impedance, current = zip_load_parts(U, d)
    if iszero(impedance) && iszero(current)
        return
    end
    fractions = zip_fractions(U, d)
    bus_number = PNM.get_mapped_bus_number(
        get_network_reduction(network_model),
        PSY.get_bus(d),
    )
    by_bus = get!(Dict{Int, Vector{ZipLoadTerm}}, _zip_load_terms(network_model), U)
    push!(
        get!(Vector{ZipLoadTerm}, by_bus, bus_number),
        ZipLoadTerm(
            fractions.constant_impedance,
            fractions.constant_current,
            injection,
        ),
    )
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
    network_model::NetworkModel{N},
    d::ZipLoad,
) where {N <: AbstractNetworkModel}
    _record_unmodeled_zip_load!(zip_load_support(N), network_model, d)
    return
end

function _record_unmodeled_zip_load!(::NoVoltageZip, ::NetworkModel, ::ZipLoad)
    return
end

function _record_unmodeled_zip_load!(
    ::ZipLoadSupport,
    network_model::NetworkModel,
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
    ::NetworkModel{N},
) where {N <: AbstractNetworkModel}
    _add_zip_load_outputs!(zip_load_support(N), container, devices, model)
    return
end

function _add_zip_load_outputs!(
    ::ZipLoadSupport,
    ::OptimizationContainer,
    ::Vector{<:ZipLoad},
    ::DeviceModel,
)
    return
end

function _add_zip_load_outputs!(
    ::VoltageDependentZip,
    container::OptimizationContainer,
    devices::Vector{<:ZipLoad},
    model::DeviceModel,
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
