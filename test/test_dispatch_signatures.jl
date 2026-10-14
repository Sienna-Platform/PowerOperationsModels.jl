# POM dispatches key types and formulations on `::Type{T}`. A method that takes an
# instance where callers pass a type never runs.
const _KEY_ROOTS = (
    IS.Optimization.VariableType,
    IS.Optimization.ConstraintType,
    IS.Optimization.ExpressionType,
    IS.Optimization.ParameterType,
    IS.Optimization.AuxVariableType,
    IOM.AbstractDeviceFormulation,
    IOM.AbstractServiceFormulation,
)

# Functions whose callers pass instances on purpose. `requires_initialization` is an
# IOM interface. The initial-condition helpers move to types in a follow-up PR.
const _INSTANCE_ALLOWED = Set{Symbol}([
    :requires_initialization,
    :initial_condition_default,
    :initial_condition_variable,
    :initial_conditions!,
    :get_initial_conditions_value,
    :add_initial_condition!,
])

struct _UnmappedTSParameter <: IOM.TimeSeriesParameter end

_upper_bound(p::TypeVar) = p.ub
_upper_bound(p) = p

# A `Type{…}` argument follows the type convention, so it does not count.
_is_instance_key(p) = false
function _is_instance_key(p::Type)
    p === Union{} && return false
    p <: Type && return false
    for root in _KEY_ROOTS
        p <: root && return true
    end
    return false
end

_function_or_nothing(f::Function) = f
_function_or_nothing(_) = nothing

function _instance_key_arguments(m::Method)
    hits = Type[]
    for p in Base.unwrap_unionall(m.sig).parameters[2:end]
        ub = _upper_bound(p)
        _is_instance_key(ub) && push!(hits, ub)
    end
    return hits
end

_scan_methods!(offenders, seen, ::Nothing) = nothing
function _scan_methods!(offenders, seen, f::Function)
    for m in methods(f)
        m in seen && continue
        push!(seen, m)
        parentmodule(m) === POM || continue
        m.name in _INSTANCE_ALLOWED && continue
        hits = _instance_key_arguments(m)
        isempty(hits) && continue
        push!(offenders, "$(m.name) at $(m.file):$(m.line) takes $(join(hits, ", "))")
    end
    return
end

function _pom_methods_with_instance_keys()
    offenders = String[]
    seen = Set{Method}()
    for mod in (POM, IOM), name in names(mod; all = true)
        isdefined(mod, name) || continue
        _scan_methods!(offenders, seen, _function_or_nothing(getfield(mod, name)))
    end
    return offenders
end

@testset "No POM method takes an instance of a key type or formulation" begin
    offenders = _pom_methods_with_instance_keys()
    @test isempty(offenders)
    isempty(offenders) || @info "Instance-typed methods" offenders
end

@testset "Cost hooks take the component type where IOM passes a type" begin
    for m in methods(IOM.variable_cost)
        parentmodule(m) === POM || continue
        component_arg = _upper_bound(Base.unwrap_unionall(m.sig).parameters[4])
        @test component_arg <: Type
    end
end

@testset "A time-series parameter with no multiplier method is an error" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    g = first(PSY.get_components(PSY.ThermalStandard, sys))
    @test_throws r"_UnmappedTSParameter" POM.get_multiplier_value(
        _UnmappedTSParameter, g, ThermalBasicDispatch,
    )
end
