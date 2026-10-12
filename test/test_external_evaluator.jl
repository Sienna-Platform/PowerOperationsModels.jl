struct CountingEvaluator <: IOM.AbstractEvaluator end

mutable struct CountingEvaluationData <: IOM.AbstractEvaluationData
    n_init::Int
    n_eval::Int
    solved::Bool
end

IOM.initialize_evaluation_data(::CountingEvaluator, container, sys) =
    CountingEvaluationData(1, 0, false)

function IOM.evaluate!(d::CountingEvaluationData, container, sys)
    d.n_eval += 1
    d.solved = true
    return
end

function IOM.reset!(d::CountingEvaluationData)
    d.solved = false
    return
end

struct CountingAux <: IOM.AuxVariableType end
IOM.is_from_evaluator(::Type{CountingAux}) = true

function IOM.add_evaluator_aux_variables!(
    container::IOM.OptimizationContainer,
    T::DataType,
    ::CountingEvaluationData,
    sys::PSY.System,
)
    names = [PSY.get_name(b) for b in PSY.get_components(PSY.ACBus, sys)]
    IOM.add_aux_variable_container!(
        container,
        CountingAux,
        PSY.ACBus,
        names,
        IOM.get_time_steps(container),
    )
    IOM.bind_aux_variable!(container, T, IOM.AuxVarKey(CountingAux, PSY.ACBus))
    return
end

# The only method for CountingAux: power flow data reaching it is a MethodError.
function IOM.calculate_aux_variable_value!(
    container::IOM.OptimizationContainer,
    key::IOM.AuxVarKey{CountingAux, PSY.ACBus},
    ::PSY.System,
    data::CountingEvaluationData,
)
    IOM.get_aux_variable(container, key) .= data.n_eval
    return
end

function _build_and_solve_external(system, template)
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    return model
end

function _external_template(evaluations)
    return get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = evaluations,
    )
end

@testset "Evaluators live on the template" begin
    ec = IOM.EvaluationContainer()
    IOM.add_evaluator!(ec, CountingEvaluator, CountingEvaluator())
    template = PowerOperationsProblemTemplate(
        NetworkModel(PTDFNetworkModel);
        evaluations = ec,
    )
    @test IOM.get_evaluations(template) === ec
    @test !hasfield(NetworkModel, :evaluations)

    replacement = IOM.EvaluationContainer()
    IOM.set_evaluations!(template, replacement)
    @test IOM.get_evaluations(template) === replacement
    @test isempty(IOM.get_evaluations(PowerOperationsProblemTemplate()))
end

@testset "Evaluator that is not a power flow" begin
    ec = IOM.EvaluationContainer()
    IOM.add_evaluator!(ec, CountingEvaluator, CountingEvaluator())
    model = _build_and_solve_external(
        build_system(PSITestSystems, "c_sys5_uc"),
        _external_template(ec),
    )
    container = get_optimization_container(model)
    data = only(values(get_evaluation_data(container)))
    @test typeof(data) === CountingEvaluationData
    @test data.n_init == 1
    @test data.n_eval == 1
    @test data.solved
end

@testset "Evaluator that is not a power flow, next to a power flow" begin
    ec = power_flow_evaluations(ACPowerFlow())
    IOM.add_evaluator!(ec, CountingEvaluator, CountingEvaluator())
    container = get_optimization_container(
        _build_and_solve_external(
            build_system(PSITestSystems, "c_sys5_uc"),
            _external_template(ec),
        ),
    )
    evaluation_data = get_evaluation_data(container)
    @test length(evaluation_data) == 2
    @test evaluation_data[CountingEvaluator].n_eval == 1
    counting_key = IOM.AuxVarKey(CountingAux, PSY.ACBus)
    @test all(==(1.0), lookup_value(container, counting_key))
    @test IOM.get_bound_aux_var_keys(container, CountingEvaluator) == [counting_key]

    reference = get_optimization_container(
        _build_and_solve_external(
            build_system(PSITestSystems, "c_sys5_uc"),
            _external_template(power_flow_evaluations(ACPowerFlow())),
        ),
    )
    key = AuxVarKey(POM.PowerFlowBranchActivePowerFromTo, Line)
    # Repeated AC power flow solves differ at round-off, so compare with a tolerance.
    @test all(
        isapprox.(lookup_value(container, key), lookup_value(reference, key); atol = 1e-9),
    )
end

_is_factorized(::PNM.VirtualPTDF) = true
_is_factorized(::PNM.VirtualMODF) = true
_is_factorized(::Any) = false

_uses_klu(::PNM.VirtualPTDF{<:Any, <:Any, <:PNM.KLUWrapper.KLULinSolveCache}) = true
_uses_klu(::PNM.VirtualMODF{<:Any, <:Any, <:PNM.KLUWrapper.KLULinSolveCache}) = true
_uses_klu(::Any) = false

struct NetworkMatrixProbe <: IOM.AuxVariableType end

const PROBED_NETWORK_MATRIX = Ref{Any}(nothing)

function IOM.calculate_aux_variable_value!(
    ::IOM.OptimizationContainer,
    ::IOM.AuxVarKey{NetworkMatrixProbe, ThermalStandard},
    ::PSY.System,
    context::POM.PowerSolveContext,
)
    PROBED_NETWORK_MATRIX[] = IOM.get_network_matrix(get_network_model(context))
    return
end

@testset "A standalone aux variable reads the template matrix through the solve context" begin
    sys = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(NetworkModel(PTDFNetworkModel))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    IOM.add_variables!(
        get_optimization_container(model),
        NetworkMatrixProbe,
        collect(get_components(ThermalStandard, sys)),
        ThermalBasicDispatch(),
    )
    PROBED_NETWORK_MATRIX[] = nothing
    try
        @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
        @test _is_factorized(PROBED_NETWORK_MATRIX[])
        @test PROBED_NETWORK_MATRIX[] ===
              IOM.get_network_matrix(get_network_model(get_template(model)))
    finally
        PROBED_NETWORK_MATRIX[] = nothing
    end
end

@testset "A rebuild makes new evaluation data and keeps the network data" begin
    sys = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(ACPowerFlow()),
    )
    # A simulation model rebuilds with these settings.
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, rebuild_model = true)
    container = get_optimization_container(model)
    container.built_for_recurrent_solves = true
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED

    key = AuxVarKey(POM.PowerFlowBranchActivePowerFromTo, Line)
    flows = lookup_value(container, key)
    data = only(values(get_evaluation_data(container)))
    network_data = get_network_data(get_network_model(get_template(model)))
    n_bound = length(
        IOM.get_bound_aux_var_keys(container, only(keys(get_evaluation_data(container)))),
    )
    @test n_bound > 0

    IOM.reset_optimization_model!(container)
    POM.build_problem!(container, get_template(model), get_system(model))
    IOM.solve_model!(model)
    @test IOM.get_run_status(model) == RunStatus.SUCCESSFULLY_FINALIZED

    @test only(values(get_evaluation_data(container))) !== data
    @test length(
        IOM.get_bound_aux_var_keys(container, only(keys(get_evaluation_data(container)))),
    ) == n_bound
    @test get_network_data(get_network_model(get_template(model))) === network_data
    @test all(isapprox.(lookup_value(container, key), flows; atol = 1e-9))
end

# A template copy must share the factorized matrices, never copy them. The copy then goes
# out of scope, and a garbage collection runs before the next solve: a copy that owned the
# factorization would free it under the model.
function _test_template_copy_and_gc(model, get_matrix)
    network_model = get_network_model(get_template(model))
    matrix = get_matrix(network_model)
    @test _is_factorized(matrix)
    @test_throws ErrorException deepcopy(get_template(model))
    copied =
        DecisionModel(get_template(model), get_system(model); optimizer = HiGHS_optimizer)
    copied_network_model = get_network_model(get_template(copied))
    @test copied_network_model !== network_model
    @test get_network_data(copied_network_model) === get_network_data(network_model)
    @test IOM.get_network_matrix(copied_network_model) ===
          IOM.get_network_matrix(network_model)
    @test get_matrix(copied_network_model) === matrix
    copied = nothing
    copied_network_model = nothing
    GC.gc()
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    return
end

function _add_line_outages!(sys)
    branches = collect(get_components(PSY.ACTransmission, sys))
    for name in ["1", "2", "3"]
        PSY.add_supplemental_attribute!(
            sys,
            get_component(PSY.ACTransmission, sys, name),
            PSY.FixedForcedOutage(; outage_status = 1.0, monitored_components = branches),
        )
    end
    return
end

function _sc_pf_template(network_model; kwargs...)
    template = get_thermal_dispatch_template_network(network_model; kwargs...)
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
    return template
end

_klu_ptdf_source(sys) = PrebuiltMatrixSource(PNM.VirtualPTDF(sys; linear_solver = "KLU"))

function _copy_case_system_and_template(sc, klu, outages, evaluations)
    sys = build_system(PSITestSystems, sc)
    if outages
        _add_line_outages!(sys)
    end
    network_source = DefaultNetworkSource()
    if klu
        network_source = _klu_ptdf_source(sys)
    end
    network_model = NetworkModel(PTDFNetworkModel; network_source = network_source)
    if outages
        return sys, _sc_pf_template(network_model; evaluations = evaluations)
    end
    return sys, get_template_dispatch_with_network(network_model; evaluations = evaluations)
end

const TEMPLATE_COPY_CASES = [
    ("VirtualPTDF", "c_sys5_uc", false, false, IOM.get_network_matrix),
    ("KLU VirtualPTDF", "c_sys5_uc", true, false, IOM.get_network_matrix),
    ("VirtualMODF", "c_sys5", false, true, IOM.get_contingency_matrix),
    ("KLU VirtualMODF", "c_sys5", true, true, IOM.get_contingency_matrix),
]

@testset "A solved $name model with AC power flow copies its template safely" for (
    name,
    sc,
    klu,
    outages,
    get_matrix,
) in TEMPLATE_COPY_CASES
    sys, template = _copy_case_system_and_template(
        sc,
        klu,
        outages,
        power_flow_evaluations(ACPowerFlow()),
    )
    model = _build_and_solve_external(sys, template)
    matrix = get_matrix(get_network_model(get_template(model)))
    if klu
        @test _uses_klu(matrix)
    end
    if outages
        @test !isempty(PNM.get_registered_contingencies(matrix))
    end
    _test_template_copy_and_gc(model, get_matrix)
end

@testset "Power flows run in registration order" begin
    for evaluators in ((ACPowerFlow(), DCPowerFlow()), (DCPowerFlow(), ACPowerFlow()))
        ec = IOM.EvaluationContainer()
        for ev in evaluators
            IOM.add_evaluator!(ec, typeof(ev), POM.PowerFlowEvaluator(ev))
        end
        container = get_optimization_container(
            _build_and_solve_external(
                build_system(PSITestSystems, "c_sys5_uc"),
                _external_template(ec),
            ),
        )
        @test collect(keys(get_evaluation_data(container))) ==
              collect(map(typeof, evaluators))
    end
end
